defmodule SalixAnalytics.AgentTelemetryReadBudgetClickHouseTest do
  @moduledoc """
  The request-path boundedness contract, verified on a live server.

  Projections keep the common case cheap, but they cannot bound every case: a
  single session with millions of rows must be read and converged before the
  outer `LIMIT`, so no projection saves it (reviewer's repro read 200k rows /
  ~197 MB to return 500). The guarantee is instead a hard per-query
  read/memory/time budget in `SalixAnalytics.ClickHouseRead`: a query that
  would exceed it aborts and returns `{:error, {:read_over_budget, _}}`, which
  the dashboard surfaces as "narrow the window" — never a hung page or an OOM.

  These tests pin a LOW `read_max_rows` so the ceiling is provably reached by a
  fat session, and prove a small read under the ceiling still succeeds. The
  default production ceilings are generous (a legitimate busy-tenant window
  passes); the mechanism, not the specific number, is what is contracted.
  """
  use ExUnit.Case, async: false

  alias SalixAnalytics.AgentTelemetryQueries, as: Queries
  alias SalixAnalytics.Migrations

  @moduletag :clickhouse

  @clickhouse_url "http://127.0.0.1:8123/"
  @fat_session_rows 200_000
  @row_ceiling 50_000

  setup_all do
    Application.ensure_all_started(:req)

    database = "salix_telemetry_budget_test_#{System.unique_integer([:positive])}"
    prev = Application.get_env(:salix_analytics, :clickhouse)

    clickhouse_query!("DROP DATABASE IF EXISTS #{database}")

    Application.put_env(:salix_analytics, :clickhouse,
      base_url: @clickhouse_url,
      table: "#{database}.events",
      # Pin the row budget low so a fat session provably trips it. Production
      # defaults are far higher; this proves the ceiling is enforced and
      # configurable, not that 50k is the right number.
      read_max_rows: @row_ceiling
    )

    {:ok, _versions} = Migrations.migrate()

    # One tenant/session with far more rows than the ceiling — the case no
    # projection can bound (LIMIT is applied after convergence).
    clickhouse_query!("""
    INSERT INTO #{database}.tool_call_events_v2
      (dedup, source, source_key, version, event_date, metered_at, created_at,
       entrypoint, surface, tenant_id, group_id, actor_type, resource_kind,
       charge_status, tool_name, tool_source, status, duration_ms, started_at,
       async, session_id)
    SELECT '', 'budget_test', concat('k', toString(number)), 1,
           toDate('2026-07-10'), '2026-07-10T10:00:00Z', '2026-07-10T10:00:00Z',
           'tool_call', 'comma', 't-fat', 'g1', 'tool', 'tool_call', 'unattributed',
           'probe', 'builtin', 'completed', 5, toDateTime64('2026-07-10 10:00:00.000', 3),
           false, 'sess-fat'
    FROM numbers(#{@fat_session_rows})
    """)

    on_exit(fn ->
      Application.put_env(:salix_analytics, :clickhouse, prev)
      clickhouse_query!("DROP DATABASE IF EXISTS #{database}")
    end)

    :ok
  end

  test "a fat session's point lookup fails fast with a tagged over-budget result" do
    assert {:error, {:read_over_budget, detail}} =
             Queries.session_trace("t-fat", "sess-fat")

    # The detail carries ClickHouse's limit code (158 TOO_MANY_ROWS here) so
    # operators can tell a budget stop from a real query error.
    assert detail.code == 158
  end

  test "a fat session's windowed read also fails fast rather than scanning it all" do
    window = [from: ~U[2026-07-10 00:00:00Z], to: ~U[2026-07-11 00:00:00Z]]

    assert {:error, {:read_over_budget, _}} = Queries.session_costs(:tool, "t-fat", window)
  end

  test "a read whose whole scan is under the ceiling still succeeds" do
    # Without projections a session lookup scans the whole table, so "small"
    # means the TABLE is under the budget, not the session. Use a fresh tiny
    # database to prove a bounded scan passes.
    small_db = "salix_telemetry_budget_small_#{System.unique_integer([:positive])}"
    prev = Application.get_env(:salix_analytics, :clickhouse)

    on_exit(fn ->
      Application.put_env(:salix_analytics, :clickhouse, prev)
      clickhouse_query!("DROP DATABASE IF EXISTS #{small_db}")
    end)

    Application.put_env(
      :salix_analytics,
      :clickhouse,
      Keyword.merge(prev, base_url: @clickhouse_url, table: "#{small_db}.events")
    )

    {:ok, _} = Migrations.migrate()

    clickhouse_query!("""
    INSERT INTO #{small_db}.tool_call_events_v2
      (dedup, source, source_key, version, event_date, metered_at, created_at,
       entrypoint, surface, tenant_id, group_id, actor_type, resource_kind,
       charge_status, tool_name, tool_source, status, duration_ms, started_at,
       async, session_id)
    SELECT '', 'budget_test', concat('s', toString(number)), 1,
           toDate('2026-07-10'), '2026-07-10T10:00:00Z', '2026-07-10T10:00:00Z',
           'tool_call', 'comma', 't-small', 'g1', 'tool', 'tool_call', 'unattributed',
           'probe', 'builtin', 'completed', 5, toDateTime64('2026-07-10 10:00:00.000', 3),
           false, 'sess-small'
    FROM numbers(5)
    """)

    assert {:ok, rows} = Queries.session_trace("t-small", "sess-small")
    assert length(rows) == 5
  end

  test "over-budget surfaces as a distinct telemetry outcome, not a generic error" do
    handler = {__MODULE__, :telemetry, make_ref()}

    :telemetry.attach(
      handler,
      [:salix, :operation, :stop],
      fn _e, _m, meta, pid -> send(pid, {:outcome, meta.operation, meta.outcome}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, {:read_over_budget, _}} = Queries.session_trace("t-fat", "sess-fat")
    assert_receive {:outcome, "session_trace", "over_budget"}
  end

  defp clickhouse_query!(sql) do
    case Req.post(@clickhouse_url, params: [query: sql], body: "", receive_timeout: 120_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        to_string(body)

      {:ok, %{status: status, body: body}} ->
        raise "ClickHouse query failed with #{status}: #{body}\nSQL:\n#{sql}"

      {:error, reason} ->
        raise "ClickHouse query failed: #{inspect(reason)}\nSQL:\n#{sql}"
    end
  end
end
