defmodule SalixAnalytics.SlackMirror.Sink do
  @moduledoc """
  ClickHouse writer for the Slack message mirror.

  Deliberately the same narrow Req + JSONEachRow shape as the other sinks in
  this app rather than a ClickHouse driver: `SalixAnalytics.Sink.ClickHouseTyped`
  records why (the maintained `ch` driver conflicts with the umbrella's Ecto
  version, and the older `clickhouse` client conflicts with the Stripe adapter's
  Hackney). Recheck those before widening this.

  ## The layout probe is not a health check

  `slack_messages` is a ReplacingMergeTree and its migration is
  `CREATE TABLE IF NOT EXISTS`, so a table precreated with the right column
  names and a DIFFERENT sorting key satisfies both the migration and any
  `SELECT ... LIMIT 0`. That is not a failed query — it is the engine merging
  away rows it believes are duplicates, which for this table means silently
  destroying messages.

  One near miss is invisible unless you look for it specifically. A table
  created with `ENGINE = ReplacingMergeTree` — no version argument — has the
  same `system.tables.engine` value as the correct one, the same keys, and a
  `version UInt64` column; only `engine_full` differs. But without the argument
  the engine replaces by INSERTION ORDER, so an out-of-order delivery decides
  the survivor. Reproduced on 24.8: with the argument, a tombstone at v21 beats
  a later-inserted live row at v20; without it, the live row wins and the
  deleted message comes back. `readiness/1` therefore checks `engine_full`, and
  a confirmed mismatch stops writes rather than degrading them. ClickHouse
  Cloud reports the equivalent engine as
  `SharedReplacingMergeTree(internal_path, replica, version)`, so the check
  treats `version` as the final engine argument instead of assuming it is the
  first one.
  """

  require Logger

  @table "slack_messages"
  @engines "'ReplacingMergeTree', 'SharedReplacingMergeTree'"
  @partition_key "toYYYYMM(event_date)"
  @sorting_key "tenant_id, workspace_id, channel_id, message_ts_us"
  @reaction_table "slack_message_reaction_deltas"
  @reaction_sorting_key "tenant_id, workspace_id, channel_id, message_ts_us, user_id, reaction, version"
  @payload_table "slack_message_payloads"
  @payload_sorting_key "tenant_id, workspace_id, channel_id, message_ts_us"
  @pin_table "slack_message_pins"
  @pin_sorting_key "tenant_id, workspace_id, channel_id, message_ts_us"
  @metadata_table "slack_message_metadata"
  @metadata_sorting_key "tenant_id, workspace_id, channel_id, message_ts_us"
  @event_trigger_table "slack_message_event_triggers"
  @event_trigger_sorting_key "tenant_id, workspace_id, channel_id, message_ts_us"
  # `system.tables.engine` is just the family name and reads `ReplacingMergeTree`
  # whether or not the version argument was given, and a `version UInt64` column
  # exists in both shapes too. Only `engine_full` distinguishes them, which is
  # why the probe reads it: see the moduledoc for what the near miss costs.
  @versioned_engine_full_patterns [
    ~r/\AReplacingMergeTree\(version\)(?:\s|\z)/,
    ~r/\ASharedReplacingMergeTree\((?:.*,\s*)?version\)(?:\s|\z)/
  ]

  @doc "Insert one batch of mirror rows."
  @spec write([map()], keyword()) :: :ok | {:error, term()}
  def write(rows, opts \\ [])

  def write([], _opts), do: :ok

  def write(rows, opts) when is_list(rows) do
    cfg = config(opts)
    body = Enum.map_join(rows, "\n", &Jason.encode!/1)

    case request(cfg, "INSERT INTO #{qualified(cfg, @table)} FORMAT JSONEachRow", body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def write_reactions(rows, opts \\ []),
    do: insert_rows(@reaction_table, rows, opts)

  @doc false
  def write_payloads(rows, opts \\ []), do: insert_rows(@payload_table, rows, opts)

  @doc false
  def write_pins(rows, opts \\ []), do: insert_rows(@pin_table, rows, opts)

  @doc false
  def write_metadata(rows, opts \\ []), do: insert_rows(@metadata_table, rows, opts)

  @doc false
  def write_event_triggers(rows, opts \\ []),
    do: insert_rows(@event_trigger_table, rows, opts)

  defp insert_rows(_table, [], _opts), do: :ok

  defp insert_rows(table, rows, opts) when is_list(rows) do
    cfg = config(opts)
    body = Enum.map_join(rows, "\n", &Jason.encode!/1)

    case request(cfg, "INSERT INTO #{qualified(cfg, table)} FORMAT JSONEachRow", body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Confirms the destination is the table this writer was designed for.

  Returns `{:error, {:slack_mirror_table_layout_mismatch, table, what}}` only
  when the server answered and the answer was wrong. An unreachable server is
  `{:error, {:slack_mirror_table_unavailable, ...}}`, which callers must treat
  as a retryable outage, not as a reason to stop writing forever.
  """
  @spec readiness(keyword()) :: :ok | {:error, term()}
  def readiness(opts \\ []) do
    cfg = config(opts)

    readiness(cfg, @table, @sorting_key)
  end

  @doc false
  def reactions_readiness(opts \\ []) do
    cfg = config(opts)

    readiness(cfg, @reaction_table, @reaction_sorting_key)
  end

  @doc false
  def payloads_readiness(opts \\ []),
    do: readiness(config(opts), @payload_table, @payload_sorting_key)

  @doc false
  def pins_readiness(opts \\ []), do: readiness(config(opts), @pin_table, @pin_sorting_key)

  @doc false
  def metadata_readiness(opts \\ []),
    do: readiness(config(opts), @metadata_table, @metadata_sorting_key)

  @doc false
  def event_triggers_readiness(opts \\ []),
    do: readiness(config(opts), @event_trigger_table, @event_trigger_sorting_key)

  defp readiness(cfg, table, sorting_key) do
    checks = [
      {"engine, partition key, or sorting key",
       """
       SELECT count() FROM system.tables
       WHERE database = '#{cfg.database}' AND name = '#{table}'
         AND engine IN (#{@engines})
         AND partition_key = '#{@partition_key}'
         AND sorting_key = '#{sorting_key}'
       """, &single_match?/1},
      {"ReplacingMergeTree version argument",
       """
       SELECT engine_full FROM system.tables
       WHERE database = '#{cfg.database}' AND name = '#{table}'
       LIMIT 1
       """, &versioned_engine_full?/1}
    ]

    Enum.reduce_while(checks, :ok, fn {what, query, valid?}, :ok ->
      case request(cfg, query, "") do
        {:ok, body} ->
          if body |> to_string() |> valid?.(),
            do: {:cont, :ok},
            else:
              {:halt,
               {:error, {:slack_mirror_table_layout_mismatch, qualified(cfg, table), what}}}

        {:error, reason} ->
          {:halt, {:error, {:slack_mirror_table_unavailable, qualified(cfg, table), reason}}}
      end
    end)
  end

  @doc false
  def table, do: @table

  defp single_match?(body), do: String.trim(body) == "1"

  defp versioned_engine_full?(body) do
    engine_full = String.trim(body)
    Enum.any?(@versioned_engine_full_patterns, &Regex.match?(&1, engine_full))
  end

  defp qualified(cfg, table), do: "#{cfg.database}.#{table}"

  defp request(cfg, query, body) do
    case Req.post(cfg.base_url,
           params: [{:database, cfg.database}, {:query, query}],
           headers: headers(cfg),
           body: body,
           receive_timeout: cfg.receive_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        # The body can echo message text back on a malformed insert, so it is
        # summarized rather than logged.
        Logger.error("slack mirror clickhouse request #{status} (#{byte_size_of(body)} bytes)")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.error("slack mirror clickhouse transport error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp byte_size_of(body) when is_binary(body), do: byte_size(body)
  defp byte_size_of(_body), do: 0

  defp headers(%{user: user, password: pass}) when is_binary(user) and user != "",
    do: [{"x-clickhouse-user", user}, {"x-clickhouse-key", pass || ""}]

  defp headers(_cfg), do: []

  defp config(opts) do
    cfg = Keyword.merge(Application.get_env(:salix_analytics, :clickhouse, []), opts)
    table = cfg[:table] || "salix_analytics.events"
    database = cfg[:database] || table |> String.split(".", parts: 2) |> hd()

    %{
      base_url: cfg[:base_url] || "http://127.0.0.1:8123",
      database: database,
      user: cfg[:user],
      password: cfg[:password],
      receive_timeout_ms: cfg[:receive_timeout_ms] || 10_000
    }
  end
end
