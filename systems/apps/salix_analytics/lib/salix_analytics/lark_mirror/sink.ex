defmodule SalixAnalytics.LarkMirror.Sink do
  @moduledoc """
  ClickHouse writer for the Lark message mirror.

  The same narrow Req + JSONEachRow shape as `SalixAnalytics.SlackMirror.Sink`,
  and for the same reason (see that moduledoc and
  `SalixAnalytics.Sink.ClickHouseTyped`).

  ## The layout probe is not a health check

  `lark_messages` is a ReplacingMergeTree created with
  `CREATE TABLE IF NOT EXISTS`. A table precreated with the right columns and a
  different sorting key, partition key, or no `version` engine argument would
  accept every insert and then merge away messages it believes are duplicates,
  or let insertion order decide whether a recalled message comes back.
  `readiness/1` checks the engine family, partition key, sorting key, and the
  `version` argument in `engine_full`, and a confirmed mismatch stops writes.
  An unreachable server is a retryable outage and stays distinguishable.
  """

  require Logger

  @table "lark_messages"
  @engines "'ReplacingMergeTree', 'SharedReplacingMergeTree'"
  @partition_key "cityHash64(tenant_id) % 16"
  @sorting_key "tenant_id, app_id, chat_id, message_id"
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

    case request(cfg, "INSERT INTO #{qualified(cfg)} FORMAT JSONEachRow", body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Confirms the destination is the table this writer was designed for.

  `{:error, {:lark_mirror_table_layout_mismatch, table, what}}` only when the
  server answered and the answer was wrong; an unreachable server is
  `{:error, {:lark_mirror_table_unavailable, table, reason}}`.
  """
  @spec readiness(keyword()) :: :ok | {:error, term()}
  def readiness(opts \\ []) do
    cfg = config(opts)

    checks = [
      {"engine, partition key, or sorting key",
       """
       SELECT count() FROM system.tables
       WHERE database = '#{cfg.database}' AND name = '#{@table}'
         AND engine IN (#{@engines})
         AND partition_key = '#{@partition_key}'
         AND sorting_key = '#{@sorting_key}'
       """, &(String.trim(&1) == "1")},
      {"ReplacingMergeTree version argument",
       """
       SELECT engine_full FROM system.tables
       WHERE database = '#{cfg.database}' AND name = '#{@table}'
       LIMIT 1
       """, &versioned_engine_full?/1}
    ]

    Enum.reduce_while(checks, :ok, fn {what, query, valid?}, :ok ->
      case request(cfg, query, "") do
        {:ok, body} ->
          if body |> to_string() |> valid?.(),
            do: {:cont, :ok},
            else: {:halt, {:error, {:lark_mirror_table_layout_mismatch, qualified(cfg), what}}}

        {:error, reason} ->
          {:halt, {:error, {:lark_mirror_table_unavailable, qualified(cfg), reason}}}
      end
    end)
  end

  @doc false
  def table, do: @table

  defp versioned_engine_full?(body) do
    engine_full = String.trim(body)
    Enum.any?(@versioned_engine_full_patterns, &Regex.match?(&1, engine_full))
  end

  defp qualified(cfg), do: "#{cfg.database}.#{@table}"

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
        # The body can echo message text back on a malformed insert.
        Logger.error("lark mirror clickhouse request #{status} (#{byte_size_of(body)} bytes)")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.error("lark mirror clickhouse transport error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp byte_size_of(body) when is_binary(body), do: byte_size(body)
  defp byte_size_of(_body), do: 0

  defp headers(%{user: user, password: pass}) when is_binary(user) and user != "",
    do: [{"x-clickhouse-user", user}, {"x-clickhouse-key", pass || ""}]

  defp headers(_cfg), do: []

  defp config(opts) do
    cfg = Keyword.merge(SystemsRuntime.get_env(:salix_analytics, :clickhouse, []), opts)
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
