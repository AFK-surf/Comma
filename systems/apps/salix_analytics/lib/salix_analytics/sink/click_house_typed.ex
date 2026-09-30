defmodule SalixAnalytics.Sink.ClickHouseTyped do
  @moduledoc """
  ClickHouse sink for billing-grade typed usage rows.

  Rows are grouped by their target table and inserted as JSONEachRow. Identity is
  `(source, source_key)` plus `version`, matching the typed usage contract rather
  than the generic transcript analytics dedup key.

  This remains a narrow HTTP sink intentionally. The actively maintained `ch`
  driver currently conflicts with the umbrella's Ecto version, while the older
  `clickhouse` client conflicts with the Stripe adapter's Hackney version. Do
  not expand this into a general ClickHouse client without first rechecking
  those dependencies and preserving the JSONEachRow ingestion contract.
  """

  require Logger

  # The three agent-telemetry kinds write the *_v2 generation (time-partitioned
  # layout, 20260723000001..3). The frozen v1 tables stay readable behind the
  # query seam until a cleanup migration retires them.
  @tables %{
    "llm" => "llm_call_events_v2",
    "tool_call" => "tool_call_events_v2",
    "agent_run" => "agent_run_events_v2",
    "agent_phase" => "agent_phase_events",
    "llm_attempt" => "llm_attempt_events",
    "vm" => "vm_usage_events",
    "storage" => "storage_usage_events",
    "charge" => "billing_charge_events",
    "fee_control" => "fee_control_checks",
    "billing_source" => "billing_source_events",
    "trajectory_eval" => "trajectory_eval_events"
  }

  # Frozen predecessors of the three agent-telemetry tables. Nothing writes
  # them any more, but every seam read still requires them to exist.
  @seam_read_tables ~w(llm_call_events tool_call_events agent_run_events)

  # The full `name type` contract for each `*_v2` table, in column order. This
  # is what a name-only check misses: a precreated table with the right names
  # and order but a wrong type (e.g. `tenant_id UInt64`) passes name checks and
  # then rejects String writes/binds. Kept in lockstep with the migrations'
  # column-order throwIf; the live schema test pins both.
  @v2_column_contracts %{
    "llm_call_events" =>
      "dedup String,source String,source_key String,version UInt64,event_date Date,metered_at String,created_at String,entrypoint String,surface String,billing_account_id String,product_owner_type String,product_owner_id String,tenant_id String,group_id String,actor_type String,resource_kind String,provider Nullable(String),sku Nullable(String),model Nullable(String),status String,charge_status String,prompt_tokens UInt64,completion_tokens UInt64,total_tokens UInt64,cache_read_input_tokens UInt64,cache_write_input_tokens UInt64,quality String,trace_id Nullable(String),request_id Nullable(String),salix_agent_id Nullable(String),session_id Nullable(String),turn_id Nullable(String),round_id Nullable(String),stale Bool,duration_ms Nullable(UInt64),started_at Nullable(DateTime64(3)),first_token_ms Nullable(UInt64),attempts UInt8,response_kind Nullable(String),error_type String,http_status Nullable(UInt16),app_revision Nullable(String),observed_at DateTime64(3),usage_reported Nullable(Bool),prompt_tokens_reported Nullable(Bool),completion_tokens_reported Nullable(Bool),cache_read_tokens_reported Nullable(Bool),reasoning_tokens Nullable(UInt64)",
    "tool_call_events" =>
      "dedup String,source String,source_key String,version UInt64,event_date Date,metered_at String,created_at String,entrypoint String,surface String,tenant_id String,group_id String,actor_type String,resource_kind String,charge_status String,tool_name String,tool_source String,status String,error_type Nullable(String),guidance_reason Nullable(String),duration_ms UInt64,started_at DateTime64(3),args_fingerprint Nullable(String),result_fingerprint Nullable(String),call_index Nullable(UInt64),async Bool,trace_id Nullable(String),request_id Nullable(String),salix_agent_id Nullable(String),session_id Nullable(String),round_id Nullable(String),app_revision Nullable(String),observed_at DateTime64(3)",
    "agent_run_events" =>
      "dedup String,source String,source_key String,version UInt64,event_date Date,metered_at String,created_at String,entrypoint String,surface String,tenant_id String,group_id String,actor_type String,resource_kind String,charge_status String,status String,duration_ms UInt64,started_at DateTime64(3),trace_id Nullable(String),request_id Nullable(String),salix_agent_id Nullable(String),session_id Nullable(String),round_id Nullable(String),app_revision Nullable(String),task_origin Nullable(String),platform Nullable(String),source_schedule_id Nullable(String),observed_at DateTime64(3)"
  }

  @datetime64_fields %{
    "llm" => ~w(started_at),
    "tool_call" => ~w(started_at),
    "agent_run" => ~w(started_at),
    "agent_phase" => ~w(started_at),
    "llm_attempt" => ~w(started_at)
  }

  def insert([]), do: {:ok, 0}

  def insert(rows) when is_list(rows) do
    rows
    |> Enum.group_by(&table_for!/1)
    |> Enum.reduce_while({:ok, 0}, fn {table, table_rows}, {:ok, count} ->
      case insert_table(table, table_rows) do
        {:ok, inserted} -> {:cont, {:ok, count + inserted}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Probe every table a running node depends on.

  This covers BOTH generations of the agent-telemetry tables while the seam
  is open: writes go to `*_v2`, but every seam read still UNIONs frozen v1
  (and `session_trace` always does), so a node missing v1 would report ready
  and then fail dashboard queries with `UNKNOWN_TABLE`. Drop the v1 entries
  in the same change that retires the seam.

  Existence is not enough for the `*_v2` tables. Their migrations are
  `CREATE TABLE IF NOT EXISTS`, so a table precreated with the wrong engine,
  key, or without the materialized instant satisfies both the migration and a
  `SELECT ... LIMIT 0` probe — and then the first real read fails. Those
  tables are checked against their required layout instead.
  """
  def readiness(opts \\ []) do
    cfg = config(opts)

    with :ok <- probe_tables(cfg), do: probe_v2_layout(cfg)
  end

  defp probe_tables(cfg) do
    Enum.reduce_while(readiness_tables(), :ok, fn suffix, :ok ->
      table = qualified_table(cfg, suffix)
      query = "SELECT 1 FROM #{table} LIMIT 0"

      case request(cfg, query, "") do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:typed_table_unavailable, table, reason}}}
      end
    end)
  end

  # Layout, not existence. CREATE TABLE IF NOT EXISTS is a no-op against a
  # precreated table, so a near-miss (right engine/keys but a wrong
  # materialized expression, drifted column order, or an exact-name wrong
  # type) would otherwise pass and fail at the first read. The full column
  # name+type contract is compared, not just names.
  defp probe_v2_layout(cfg) do
    Enum.reduce_while(@seam_read_tables, :ok, fn base, :ok ->
      table = base <> "_v2"

      checks = [
        {"engine, partition key, or sorting key",
         """
         SELECT count() FROM system.tables
         WHERE database = '#{cfg.database}' AND name = '#{table}'
           AND engine IN ('ReplacingMergeTree', 'SharedReplacingMergeTree')
           AND partition_key = 'toYYYYMM(event_date)'
           AND sorting_key = 'event_date, source, source_key'
         """},
        {"materialized observed_at column",
         """
         SELECT count() FROM system.columns
         WHERE database = '#{cfg.database}' AND table = '#{table}'
           AND name = 'observed_at' AND type = 'DateTime64(3)'
           AND default_kind = 'MATERIALIZED'
           AND default_expression = 'parseDateTime64BestEffortOrZero(metered_at, 3, \\'UTC\\')'
         """},
        {"column names and types",
         """
         SELECT toUInt8(
           (SELECT arrayStringConcat(groupArray(concat(name, ' ', type)), ',')
            FROM (SELECT name, type FROM system.columns
                  WHERE database = '#{cfg.database}' AND table = '#{table}'
                  ORDER BY position))
           = '#{Map.fetch!(@v2_column_contracts, base)}')
         """}
      ]

      Enum.reduce_while(checks, {:cont, :ok}, fn {what, query}, _ ->
        case probe_count(cfg, query) do
          {:ok, "1"} ->
            {:cont, {:cont, :ok}}

          {:ok, _mismatch} ->
            {:halt,
             {:halt, {:error, {:typed_table_layout_mismatch, qualified_table(cfg, table), what}}}}

          {:error, reason} ->
            {:halt,
             {:halt, {:error, {:typed_table_unavailable, qualified_table(cfg, table), reason}}}}
        end
      end)
    end)
  end

  defp probe_count(cfg, query) do
    case request(cfg, query, "") do
      {:ok, body} -> {:ok, body |> to_string() |> String.trim()}
      {:error, _} = error -> error
    end
  end

  @doc "Every table a node reads or writes, both seam generations included."
  def readiness_tables do
    (Map.values(@tables) ++ @seam_read_tables) |> Enum.uniq() |> Enum.sort()
  end

  def table_for!(%{"resource_kind" => kind}) do
    case Map.fetch(@tables, to_string(kind)) do
      {:ok, suffix} -> suffix
      :error -> raise ArgumentError, "unknown typed usage resource_kind: #{inspect(kind)}"
    end
  end

  defp insert_table(table_suffix, rows) do
    cfg = config()
    table = qualified_table(cfg, table_suffix)

    body =
      rows
      |> Enum.map(&encode_row/1)
      |> Enum.map_join("\n", &Jason.encode!/1)

    case request(cfg, "INSERT INTO #{table} FORMAT JSONEachRow", body) do
      {:ok, _} -> {:ok, length(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_row(row) do
    row
    |> Map.put_new("version", 1)
    |> Map.put("dedup", typed_dedup_key(row))
    |> normalize_clickhouse_types()
  end

  defp typed_dedup_key(row) do
    Enum.join([row["source"] || "", row["source_key"] || "", row["version"] || 1], "|")
  end

  defp normalize_clickhouse_types(%{"resource_kind" => kind} = row) do
    kind
    |> to_string()
    |> then(&Map.get(@datetime64_fields, &1, []))
    |> Enum.reduce(row, fn field, acc ->
      case Map.fetch(acc, field) do
        {:ok, value} -> Map.put(acc, field, datetime64_value(value))
        :error -> acc
      end
    end)
  end

  defp normalize_clickhouse_types(row), do: row

  defp datetime64_value(nil), do: nil

  defp datetime64_value(%DateTime{} = value),
    do: value |> DateTime.to_naive() |> datetime64_value()

  defp datetime64_value(%NaiveDateTime{} = value) do
    {{year, month, day}, {hour, minute, second}} = NaiveDateTime.to_erl(value)
    {microsecond, _precision} = value.microsecond
    millisecond = div(microsecond, 1_000)

    :io_lib.format(
      "~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B.~3..0B",
      [year, month, day, hour, minute, second, millisecond]
    )
    |> IO.iodata_to_binary()
  end

  defp datetime64_value(value) when is_binary(value) do
    cond do
      String.contains?(value, "T") ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} ->
            datetime64_value(datetime)

          {:error, _} ->
            value
            |> String.replace_suffix("Z", "")
            |> NaiveDateTime.from_iso8601()
            |> case do
              {:ok, naive} -> datetime64_value(naive)
              {:error, _} -> value
            end
        end

      true ->
        value
    end
  end

  defp datetime64_value(value), do: value

  defp request(cfg, query, body) do
    case Req.post(cfg.base_url,
           params: params(cfg, query),
           headers: headers(cfg),
           body: body,
           receive_timeout: cfg.receive_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("typed clickhouse request #{status}: #{inspect(body)}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.error("typed clickhouse transport error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp params(cfg, query) do
    base = [query: query]
    if cfg.database, do: [{:database, cfg.database} | base], else: base
  end

  defp headers(%{user: user, password: pass}) when is_binary(user) and user != "" do
    [{"x-clickhouse-user", user}, {"x-clickhouse-key", pass || ""}]
  end

  defp headers(_), do: []

  defp qualified_table(cfg, suffix), do: "#{cfg.database}.#{suffix}"

  defp config(opts \\ []) do
    cfg = Keyword.merge(Application.get_env(:salix_analytics, :clickhouse, []), opts)
    table = cfg[:table] || "salix_analytics.events"

    database =
      cfg[:typed_database] || cfg[:database] || table |> String.split(".", parts: 2) |> hd()

    %{
      base_url: cfg[:base_url] || "http://127.0.0.1:8123",
      database: database,
      user: cfg[:user],
      password: cfg[:password],
      receive_timeout_ms: cfg[:receive_timeout_ms] || 5_000
    }
  end
end
