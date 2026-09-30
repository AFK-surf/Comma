defmodule SalixAnalytics.Sink.ClickHouse do
  @moduledoc """
  ClickHouse analytics sink. Inserts flattened analytics rows into a ClickHouse
  `ReplacingMergeTree`-style table via the HTTP interface: one
  `INSERT INTO {table} FORMAT JSONEachRow` request, one newline-delimited JSON
  object per row (`JSONEachRow`).

  Idempotency is the table's job — every row carries a `dedup` column
  (`SalixAnalytics.Sink.dedup_key/1`, identity `(agent, seq, type, message_id)`).
  Re-posting the same rows with the same `dedup` is safe; a
  `ReplacingMergeTree` ordered by `dedup` collapses them on merge.

  Config (`config :salix_analytics, :clickhouse, ...`, all overridable so tests
  point `base_url` at a mock server):

    * `:base_url`  — ClickHouse HTTP endpoint (default `http://127.0.0.1:8123`)
    * `:table`     — target table (default `salix_analytics.events`)
    * `:database`  — optional `database=` query param
    * `:user` / `:password` — optional basic-auth
  """
  @behaviour SalixAnalytics.Sink

  require Logger
  alias SalixAnalytics.Sink

  @impl true
  def insert([]), do: {:ok, 0}

  def insert(rows) when is_list(rows) do
    cfg = config()

    body =
      rows
      |> Enum.map(&encode_row/1)
      |> Enum.map_join("\n", &Jason.encode!/1)

    query = "INSERT INTO #{cfg.table} FORMAT JSONEachRow"

    case Req.post(cfg.base_url,
           params: params(cfg, query),
           headers: headers(cfg),
           body: body,
           receive_timeout: 30_000,
           retry: :transient
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, length(rows)}

      {:ok, %{status: status, body: resp}} ->
        Logger.error("clickhouse insert #{status}: #{inspect(resp)}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.error("clickhouse transport error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Each row is the flattened event plus its dedup key; nested maps/lists are
  # JSON-encoded into a single `payload` string so the table schema stays flat
  # (ClickHouse JSONEachRow wants scalar columns; the full event is preserved).
  defp encode_row(row) do
    %{
      "dedup" => Sink.dedup_key(row),
      "agent" => row["_agent"],
      "seq" => row["_seq"],
      "type" => row["type"] || row["kind"],
      "message_id" => row["message_id"],
      "payload" => Jason.encode!(row)
    }
  end

  defp params(cfg, query) do
    base = [query: query]
    if cfg.database, do: [{:database, cfg.database} | base], else: base
  end

  defp headers(%{user: user, password: pass}) when is_binary(user) do
    [{"x-clickhouse-user", user}, {"x-clickhouse-key", pass || ""}]
  end

  defp headers(_), do: []

  defp config do
    cfg = Application.get_env(:salix_analytics, :clickhouse, [])

    %{
      base_url: cfg[:base_url] || "http://127.0.0.1:8123",
      table: cfg[:table] || "salix_analytics.events",
      database: cfg[:database],
      user: cfg[:user],
      password: cfg[:password]
    }
  end
end
