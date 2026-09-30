defmodule SalixAnalytics.TrajectoryEvalQueriesTest do
  use ExUnit.Case, async: false

  alias SalixAnalytics.TrajectoryEvalQueries, as: Queries

  defmodule Mock do
    @moduledoc """
    Minimal ClickHouse HTTP stand-in: records each request's query params and
    replies with a canned `{status, body}` set via `respond_with/2`.
    """
    import Plug.Conn
    use Agent

    def start_link(_ \\ []),
      do: Agent.start_link(fn -> %{requests: [], status: 200, body: ""} end, name: __MODULE__)

    def respond_with(status, body),
      do: Agent.update(__MODULE__, &%{&1 | status: status, body: body})

    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))
    def last_request, do: Agent.get(__MODULE__, &List.first(&1.requests))

    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)
      # SQL is sent in the body; param_* bindings in the query string.
      req = Map.put(conn.query_params, "__body", raw)
      Agent.update(__MODULE__, &%{&1 | requests: [req | &1.requests]})
      %{status: status, body: body} = Agent.get(__MODULE__, & &1)
      send_resp(conn, status, body)
    end
  end

  setup do
    start_supervised!(Mock)

    bandit =
      start_supervised!(
        {Bandit, plug: Mock, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: {__MODULE__, :bandit}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    prev = Application.get_env(:salix_analytics, :clickhouse)

    Application.put_env(:salix_analytics, :clickhouse,
      base_url: "http://127.0.0.1:#{port}/",
      table: "test.analytics_events"
    )

    on_exit(fn -> Application.put_env(:salix_analytics, :clickhouse, prev) end)
    :ok
  end

  test "returns {:error, :not_configured} when base_url is absent" do
    Application.put_env(:salix_analytics, :clickhouse, [])

    assert {:error, :not_configured} = Queries.flag_rate_trend("t1")
    assert {:error, :not_configured} = Queries.metric_breakdown("t1")
    assert {:error, :not_configured} = Queries.judge_confirm_rate("t1")
    assert {:error, :not_configured} = Queries.top_flagged_sessions("t1")

    assert {:error, :not_configured} =
             Queries.confirmed_windows("t1",
               after_at: ~U[2026-08-01 00:00:00Z],
               after_key: "",
               snapshot_to: ~U[2026-08-02 00:00:00Z]
             )
  end

  test "flag_rate_trend binds values as native params and decodes JSONEachRow" do
    Mock.respond_with(200, """
    {"event_date":"2026-07-08","group_id":"g1","checks":10,"with_issues":3}
    {"event_date":"2026-07-09","group_id":"g1","checks":4,"with_issues":0}
    """)

    assert {:ok, rows} =
             Queries.flag_rate_trend("tenant-1",
               from: ~D[2026-07-01],
               to: ~D[2026-07-09]
             )

    assert [%{"event_date" => "2026-07-08", "checks" => 10, "with_issues" => 3} | _] = rows
    assert length(rows) == 2

    params = Mock.last_request()
    sql = params["__body"]

    # Values travel as param_* bindings, never inside the SQL text.
    assert params["param_tenant_id"] == "tenant-1"
    assert params["param_from"] == "2026-07-01"
    assert params["param_to"] == "2026-07-09"
    refute sql =~ "tenant-1"

    assert sql =~ "{tenant_id:String}"
    assert sql =~ "FORMAT JSONEachRow"
    assert sql =~ "test.trajectory_eval_events"
    # Collapses to one row per finding first (dup-safe under
    # ReplacingMergeTree), then counts distinct checks via the window key.
    assert sql =~ "GROUP BY wkey, metric"
    assert sql =~ "HAVING has_l1"
    # Net counting: dismissed findings don't make a check count as flagged.
    assert sql =~ "uniqExactIf(wkey, metric != 'clean' AND NOT is_dismissed)"
    # No group filter requested → no group clause, no dangling param.
    refute sql =~ "group_id = {group_id:String}"
    refute Map.has_key?(params, "param_group_id")
  end

  test "metric_breakdown returns judge outcomes alongside found counts" do
    Mock.respond_with(200, """
    {"metric":"tool_loop","event_date":"2026-07-08","found":2,"confirmed":1,"dismissed":0,"reviewed":1}
    """)

    assert {:ok, [row]} = Queries.metric_breakdown("tenant-1")
    assert row["found"] == 2 and row["dismissed"] == 0

    sql = Mock.last_request()["__body"]
    assert sql =~ "countIf(is_dismissed) AS dismissed"
    assert sql =~ "countIf(is_reviewed) AS reviewed"
    assert sql =~ "WHERE metric != 'clean'"
  end

  test "group_id filter adds the bound clause" do
    Mock.respond_with(200, "")

    assert {:ok, []} = Queries.metric_breakdown("tenant-1", group_id: "grp-9")

    params = Mock.last_request()
    assert params["__body"] =~ "AND group_id = {group_id:String}"
    assert params["param_group_id"] == "grp-9"
    refute params["__body"] =~ "grp-9"
  end

  test "judge_confirm_rate targets judge rows and confirmed verdicts" do
    Mock.respond_with(200, """
    {"metric":"tool_loop","evaluator_version":"3","confirmed":2,"total":4}
    """)

    assert {:ok, [row]} = Queries.judge_confirm_rate("tenant-1")
    assert row["confirmed"] == 2 and row["total"] == 4

    sql = Mock.last_request()["__body"]
    assert sql =~ "evaluator = 'judge'"
    assert sql =~ "uniqExactIf(source_key, verdict = 'confirmed')"
    assert sql =~ "GROUP BY metric, evaluator_version"
  end

  test "top_flagged_sessions ranks by net issues and binds the limit" do
    Mock.respond_with(200, """
    {"salix_agent_id":"ag-1","session_id":"sess-1","issues":7,"dismissed":1,"last_date":"2026-07-09"}
    """)

    assert {:ok, [row]} = Queries.top_flagged_sessions("tenant-1", limit: 5)
    assert row["session_id"] == "sess-1"
    assert row["dismissed"] == 1

    params = Mock.last_request()
    assert params["param_limit"] == "5"
    assert params["__body"] =~ "LIMIT {limit:UInt32}"
    assert params["__body"] =~ "countIf(NOT is_dismissed) AS issues"
    assert params["__body"] =~ "ORDER BY issues DESC"
  end

  test "confirmed_windows keyset-pages existing L2 facts and decodes findings" do
    findings =
      Jason.encode!([
        ["confusion", 0.8, "confirmed", "backtracked", Jason.encode!([%{"quote" => "wait"}])]
      ])

    Mock.respond_with(
      200,
      Jason.encode!(%{
        "window_key" => "agent-1:session-1:12",
        "salix_agent_id" => "agent-1",
        "session_id" => "session-1",
        "group_id" => "group-1",
        "outcome" => "final",
        "round_id" => "round-1",
        "window_from" => 10,
        "window_to" => 12,
        "window_messages" => 3,
        "max_confirmed_severity" => 0.8,
        "evaluator_version" => "1",
        "evaluated_at" => "2026-08-01T01:02:03.000000Z",
        "findings_json" => findings
      })
    )

    assert {:ok, [row]} =
             Queries.confirmed_windows("tenant-1",
               after_at: ~U[2026-08-01 00:00:00Z],
               after_key: "agent-0:session-0:1",
               snapshot_to: ~U[2026-08-02 00:00:00Z],
               group_id: "group-1",
               min_severity: 0.7,
               limit: 11
             )

    assert row["findings"] == [
             %{
               "metric" => "confusion",
               "score" => 0.8,
               "verdict" => "confirmed",
               "reason" => "backtracked",
               "evidence" => [%{"quote" => "wait"}]
             }
           ]

    params = Mock.last_request()
    sql = params["__body"]
    assert params["param_tenant_id"] == "tenant-1"
    assert params["param_after_key"] == "agent-0:session-0:1"
    assert params["param_limit"] == "11"
    assert params["param_group_id"] == "group-1"
    assert sql =~ "evaluator = 'judge'"
    assert sql =~ "HAVING verdict = 'confirmed'"
    assert sql =~ "formatDateTime(evaluated_at_raw"
    assert sql =~ "WHERE evaluated_at_raw <= parseDateTime64BestEffort"
    assert sql =~ "ORDER BY evaluated_at_raw ASC, window_key ASC"
    assert sql =~ "LIMIT {limit:UInt32}"
  end

  test "a non-budget error surfaces as a generic http error" do
    Mock.respond_with(500, "Code: 62. DB::Exception: boom")

    assert {:error, {:http, body}} = Queries.flag_rate_trend("tenant-1")
    assert body =~ "boom"
  end

  test "undecodable response lines surface as {:error, {:bad_row, _}}" do
    Mock.respond_with(200, "not json")

    assert {:error, {:bad_row, "not json"}} = Queries.flag_rate_trend("tenant-1")
  end
end
