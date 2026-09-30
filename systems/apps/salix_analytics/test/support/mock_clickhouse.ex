defmodule SalixAnalytics.MockClickHouse do
  @moduledoc """
  A tiny Plug impersonating the ClickHouse HTTP interface for tests. It accepts
  ClickHouse HTTP interface for analytics tests. It supports the sink's
  `INSERT ... FORMAT JSONEachRow` shape and the subset of DDL/SELECT/INSERT used
  by `SalixAnalytics.Migrations`.
  """
  import Plug.Conn
  use Agent

  def start_link(_ \\ []) do
    Agent.start_link(
      fn ->
        %{
          rows: %{},
          migrations: %{},
          queries: [],
          reported_engine: "ReplacingMergeTree",
          reported_engine_full: "ReplacingMergeTree(version)"
        }
      end,
      name: __MODULE__
    )
  end

  @doc "All stored rows (deduped by the `dedup` column), insertion order undefined."
  def rows, do: Agent.get(__MODULE__, &Map.values(&1.rows))
  def count, do: Agent.get(__MODULE__, &map_size(&1.rows))
  def migration_versions, do: Agent.get(__MODULE__, &Map.keys(&1.migrations))
  def queries, do: Agent.get(__MODULE__, & &1.queries)

  def report_engine_as(engine) do
    Agent.update(__MODULE__, &%{&1 | reported_engine: engine})
  end

  def report_engine_full_as(engine_full) do
    Agent.update(__MODULE__, &%{&1 | reported_engine_full: engine_full})
  end

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    {:ok, raw, conn} = read_body(conn)
    query = conn.params["query"] || ""

    Agent.update(__MODULE__, fn state ->
      %{state | queries: [query | state.queries]}
    end)

    cond do
      String.contains?(query, "SELECT engine_full FROM system.tables") ->
        engine_full = Agent.get(__MODULE__, & &1.reported_engine_full)
        send_resp(conn, 200, engine_full <> "\n")

      String.contains?(query, "system.tables") and String.contains?(query, "engine") ->
        reported_engine = Agent.get(__MODULE__, & &1.reported_engine)
        engine_matches? = query_accepts_engine?(query, reported_engine)

        if engine_matches? do
          send_resp(conn, 200, "1\n")
        else
          # Migration structural gates use throwIf and fail at query execution;
          # readiness probes consume the zero count directly.
          if String.starts_with?(query, "SELECT throwIf") do
            send_resp(conn, 500, "unexpected engine #{reported_engine}")
          else
            send_resp(conn, 200, "0\n")
          end
        end

      # Other layout probes stand in for a correctly migrated server. Drift
      # rejection is covered against a real ClickHouse.
      String.contains?(query, "system.tables") or String.contains?(query, "system.columns") ->
        send_resp(conn, 200, "1\n")

      String.starts_with?(query, "SELECT version") ->
        body =
          __MODULE__
          |> Agent.get(& &1.migrations)
          |> Enum.sort_by(fn {version, _row} -> version end)
          |> Enum.map_join("\n", fn {version, row} -> "#{version}\t#{row["checksum"]}" end)

        send_resp(conn, 200, body)

      String.contains?(query, "analytics_schema_migrations") and
          String.starts_with?(query, "INSERT INTO") ->
        raw
        |> String.split("\n", trim: true)
        |> Enum.each(fn line ->
          row = Jason.decode!(line)

          Agent.update(__MODULE__, fn state ->
            put_in(state, [:migrations, row["version"]], row)
          end)
        end)

        send_resp(conn, 200, "")

      String.starts_with?(query, "INSERT INTO") ->
        raw
        |> String.split("\n", trim: true)
        |> Enum.each(fn line ->
          row = Jason.decode!(line)

          Agent.update(__MODULE__, fn state ->
            put_in(state, [:rows, row["dedup"]], row)
          end)
        end)

        send_resp(conn, 200, "")

      true ->
        send_resp(conn, 200, "")
    end
  end

  defp query_accepts_engine?(query, engine) do
    String.contains?(query, "engine = '#{engine}'") or
      (String.contains?(query, "engine IN (") and String.contains?(query, "'#{engine}'"))
  end
end
