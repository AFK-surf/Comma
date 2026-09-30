defmodule SalixAnalytics.AgentTelemetryQueriesTest do
  use ExUnit.Case, async: false

  alias SalixAnalytics.AgentTelemetryQueries, as: Queries

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

    def last_request, do: Agent.get(__MODULE__, &List.first(&1.requests))

    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)
      req = Map.put(conn.query_params, "__body", raw)
      Agent.update(__MODULE__, &%{&1 | requests: [req | &1.requests]})
      %{status: status, body: body} = Agent.get(__MODULE__, & &1)
      send_resp(conn, status, body)
    end
  end

  @from ~U[2026-07-09 12:00:00Z]
  @to ~U[2026-07-10 12:00:00Z]
  @window [from: @from, to: @to]

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

  test "dashboard reads emit a duration/outcome signal under a finite query label" do
    handler = {__MODULE__, :telemetry, make_ref()}

    :telemetry.attach(
      handler,
      [:salix, :operation, :stop],
      fn _event, measurements, metadata, pid -> send(pid, {:signal, measurements, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # The stop event is shared across components; unrelated telemetry must not
    # win the mailbox race for this assertion.
    send(
      self(),
      {:signal, %{duration: 1}, %{component: "salix_store", operation: "get", outcome: "ok"}}
    )

    Mock.respond_with(200, ~s({"rounds":1,"completed":1,"llm_failed":0,"actor_failed":0}\n))
    assert {:ok, [_]} = Queries.run_outcomes("t1", @window)

    assert_receive {:signal, %{duration: duration},
                    %{
                      component: "salix_analytics",
                      operation: "run_outcomes",
                      outcome: "ok"
                    }}

    assert duration > 0

    # A failing query is where the signal earns its keep — the dashboard's
    # only other symptom is an empty panel.
    Mock.respond_with(500, "boom")
    assert {:error, _} = Queries.tool_rates("t1", @window)

    assert_receive {:signal, _measurements, %{operation: "tool_rates", outcome: "error"}}
  end

  test "a failing dashboard read is visible through the catalog's own series" do
    # The documented operator question is "which query family is failing or
    # timing out" (docs/observability.md). Prove the emitted
    # series can answer it: attach the real reporter definitions, force an
    # error, and evaluate the documented label selector against what was
    # actually recorded.
    handler = {__MODULE__, :catalog, make_ref()}

    :telemetry.attach(
      handler,
      [:salix, :operation, :stop],
      fn _e, m, meta, pid ->
        send(pid, {:sample, m, meta})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # Keep unrelated shared-event traffic queued across both expected samples.
    send(
      self(),
      {:sample, %{duration: 1}, %{component: "salix_store", operation: "get", outcome: "ok"}}
    )

    Mock.respond_with(200, ~s({"rounds":1,"completed":1,"llm_failed":0,"actor_failed":0}\n))
    assert {:ok, [_]} = Queries.run_outcomes("t1", @window)
    assert_receive {:sample, _, %{component: "salix_analytics", operation: "run_outcomes"}}

    Mock.respond_with(500, "boom")
    assert {:error, _} = Queries.tool_rates("t1", @window)

    assert_receive {:sample, %{duration: duration},
                    %{
                      component: "salix_analytics",
                      operation: "tool_rates",
                      outcome: "error"
                    } = failing}

    # Exactly the dimensions the documented PromQL groups by, with the
    # component selector the catalog entry uses.
    assert %{component: "salix_analytics", operation: "tool_rates", outcome: "error"} =
             Map.take(failing, [:component, :operation, :outcome])

    assert duration > 0, "the duration series must carry a real observation for the p95 query"

    # And the labels survive the reporter's finite-label normalization, which
    # is what the catalog's `sum by (operation,outcome)` actually reads.
    tags =
      Salix.Telemetry.metrics()
      |> Enum.find(&(&1.name == [:salix, :operations, :total]))
      |> then(& &1.tag_values)
      |> then(& &1.(failing))

    assert tags.component == "salix_analytics"
    assert tags.operation == "tool_rates"
    assert tags.outcome == "error"
  end

  test "the query label comes from a registered finite set" do
    # AGENTS.md: metric labels must be finite. Every family this module emits
    # has to be registered in Salix.Telemetry or it collapses to "other",
    # which would silently merge unrelated queries in the dashboard.
    registered =
      Salix.Telemetry.metrics()
      |> Enum.find(&(&1.name == [:salix, :operations, :total]))
      |> then(& &1.tag_values)
      |> then(fn tag_values ->
        fn operation ->
          tag_values.(%{
            component: "salix_analytics",
            operation: operation,
            surface: "system",
            outcome: "ok"
          }).operation
        end
      end)

    for family <- ~w(run_outcomes tool_rates llm_overview session_trace convergence_drift) do
      assert registered.(family) == family,
             "#{family} is not registered in Salix.Telemetry's finite operation set"
    end

    assert registered.("made_up_family") == "other"
  end

  test "returns {:error, :not_configured} when base_url is absent" do
    Application.put_env(:salix_analytics, :clickhouse, [])

    assert {:error, :not_configured} = Queries.run_outcomes("t1")
    assert {:error, :not_configured} = Queries.unconverged_sessions("t1")
    assert {:error, :not_configured} = Queries.session_trace("t1", "s1")
  end

  test "run_outcomes binds tenant and window, reads the converged seam with normalized time" do
    Mock.respond_with(200, ~s({"rounds":10,"completed":9,"llm_failed":1,"actor_failed":0}\n))

    assert {:ok, [row]} = Queries.run_outcomes("tenant-1", @window)
    assert row["completed"] == 9

    params = Mock.last_request()
    sql = params["__body"]

    # Values travel as param_* bindings, never inside the SQL text.
    assert params["param_tenant_id"] == "tenant-1"
    assert params["param_from"] == "2026-07-09 12:00:00"
    assert params["param_to"] == "2026-07-10 12:00:00"
    refute sql =~ "tenant-1"

    # Seam shape: coarse event_date pruning on v2, per-row parse only on the
    # frozen v1 branch, query-time convergence instead of FINAL.
    refute sql =~ "FINAL"
    assert sql =~ "FROM test.agent_run_events_v2"

    assert sql =~
             "event_date >= toDate({from:DateTime}) - 1 AND event_date <= toDate({to:DateTime}) + 1"

    assert sql =~ "UNION ALL"

    assert sql =~
             "parseDateTime64BestEffortOrNull(metered_at, 3, 'UTC') AS observed_at FROM test.agent_run_events"

    # Convergence orders by the typed INSTANT, never the timestamp text:
    # offset and fractional-second ISO strings are not lexicographically
    # chronological. metered_at survives only as the final deterministic
    # tie-break, and NULLS LAST keeps an unparseable v1 row from winning.
    assert sql =~
             "ORDER BY version DESC, observed_at DESC NULLS LAST, metered_at DESC LIMIT 1 BY source, source_key"

    # tenant_id is pushed into BOTH branches, not left to the outer scope:
    # neither generation's key prunes by tenant, so without this one tenant's
    # dashboard sorts every other tenant's rows for the same dates.
    assert sql =~ "FROM test.agent_run_events_v2 WHERE tenant_id = {tenant_id:String}"
    assert sql =~ "FROM test.agent_run_events WHERE tenant_id = {tenant_id:String}"

    assert sql =~ "observed_at >= {from:DateTime} AND observed_at < {to:DateTime}"
    assert sql =~ "countIf(status = 'llm_failed') AS llm_failed"
  end

  test "the frozen v1 branch is never pruned by a build-time date" do
    Mock.respond_with(200, "")

    # A window years past any plausible cutover still reads both generations:
    # a source-code constant cannot know when an environment's old writers
    # exited, and a wrong guess silently drops rows the old ordinal wrote.
    far_future = [from: ~U[2030-01-01 00:00:00Z], to: ~U[2030-01-02 00:00:00Z]]

    assert {:ok, []} = Queries.run_outcomes("t1", far_future)
    sql = Mock.last_request()["__body"]

    assert sql =~ "FROM test.agent_run_events_v2"
    assert sql =~ "FROM test.agent_run_events WHERE"
  end

  test "round_trends buckets via a bound interval" do
    Mock.respond_with(200, "")

    assert {:ok, []} = Queries.round_trends("t1", @window ++ [bucket_seconds: 600])

    params = Mock.last_request()
    assert params["param_bucket"] == "600"
    assert params["__body"] =~ "toStartOfInterval(observed_at, toIntervalSecond({bucket:UInt32}))"
    assert params["__body"] =~ "quantileTDigest(0.95)(duration_ms) AS p95_ms"
  end

  test "group and app_revision filters add bound clauses" do
    Mock.respond_with(200, "")

    assert {:ok, []} =
             Queries.run_outcomes("t1", @window ++ [group_id: "grp-9", app_revision: "abc1234"])

    params = Mock.last_request()
    assert params["__body"] =~ "AND group_id = {group_id:String}"
    assert params["__body"] =~ "AND app_revision = {rev:String}"
    assert params["param_group_id"] == "grp-9"
    assert params["param_rev"] == "abc1234"
    refute params["__body"] =~ "grp-9"
  end

  test "unconverged_sessions bounds activity, returns agent ids, and keeps the anti-join honest" do
    Mock.respond_with(
      200,
      ~s({"session_id":"s1","salix_agent_id":"ag1","last_activity_at":"2026-07-10 11:00:00","activity_events":12}\n)
    )

    stale_before = ~U[2026-07-10 11:45:00Z]

    assert {:ok, [row]} =
             Queries.unconverged_sessions("t1", @window ++ [stale_before: stale_before, limit: 7])

    assert row["salix_agent_id"] == "ag1"

    params = Mock.last_request()
    sql = params["__body"]

    # The raw acceptance Q5 has no lower bound and no tenant scope — both are
    # required here so ancient/staled-forever sessions and other tenants
    # don't dominate the table.
    assert sql =~ "observed_at >= {from:DateTime}"
    assert params["param_stale_before"] == "2026-07-10 11:45:00"
    assert params["param_limit"] == "7"

    # Agent id comes back so the caller can filter internal-only and link.
    assert sql =~ "anyIf(agent_id, agent_id != '') AS salix_agent_id"

    # The LEFT JOIN anti-join needs NULLs, not zero-defaults.
    assert sql =~ "SETTINGS join_use_nulls = 1"

    assert sql =~
             "terminal.terminal_at IS NULL OR activity.last_activity_at > terminal.terminal_at"

    # Newest silence first — triage-relevant, not ancient history.
    assert sql =~ "ORDER BY activity.last_activity_at DESC"

    # Terminal side is tenant-scoped, seam-read, and lower-bounded only: a
    # terminal later than the window must stay visible, and the verdict-neutral
    # lower bound keeps the v2 scan pruned.
    refute sql =~ "FINAL"

    assert sql =~
             "FROM test.agent_run_events_v2 WHERE tenant_id = {tenant_id:String} AND event_date >= toDate({from:DateTime}) - 1 UNION ALL"

    assert sql =~ "max(observed_at) AS terminal_at"
  end

  test "tool_rates keeps Q1 denizens: outcome counts and guidance reasons" do
    Mock.respond_with(200, "")

    assert {:ok, []} = Queries.tool_rates("t1", @window ++ [tool_source: "mcp"])

    params = Mock.last_request()
    sql = params["__body"]

    assert sql =~ "countIf(status = 'guidance') AS guidance_calls"
    assert sql =~ "countIf(guidance_reason = 'invalid_params') AS guidance_invalid_params"
    assert sql =~ "AND tool_source = {tool_source:String}"
    assert params["param_tool_source"] == "mcp"
    assert sql =~ "GROUP BY tool_name, tool_source"
  end

  test "tool_latency keeps async rows separate" do
    Mock.respond_with(200, "")

    assert {:ok, []} = Queries.tool_latency("t1", @window)
    assert Mock.last_request()["__body"] =~ "GROUP BY tool_name, tool_source, async"
  end

  test "tool drill queries bind the tool name" do
    Mock.respond_with(200, "")

    assert {:ok, []} = Queries.tool_error_types("t1", "web_fetch", @window)
    assert Mock.last_request()["param_tool_name"] == "web_fetch"
    assert Mock.last_request()["__body"] =~ "AND status = 'error'"

    assert {:ok, []} = Queries.tool_top_sessions("t1", "web_fetch", @window)
    sql = Mock.last_request()["__body"]
    assert sql =~ "status IN ('error', 'guidance')"
    assert sql =~ "LIMIT {limit:UInt32}"
  end

  test "error_overview computes current and previous window in one scan" do
    Mock.respond_with(200, ~s({"calls":100,"errors":2,"prev_calls":90,"prev_errors":1}\n))

    assert {:ok, [row]} = Queries.error_overview(:tool, "t1", @window)
    assert row["prev_errors"] == 1

    params = Mock.last_request()
    sql = params["__body"]

    # Previous window = equal length immediately before [from, to).
    assert params["param_prev_from"] == "2026-07-08 12:00:00"
    assert sql =~ "observed_at >= {prev_from:DateTime}"

    # Tool infra denominator: guidance/cancelled are not infra outcomes.
    assert sql =~
             "countIf(status IN ('completed', 'error') AND observed_at >= {from:DateTime}) AS calls"
  end

  test "deploy_rates groups by revision with unknown coalesced" do
    Mock.respond_with(200, "")

    assert {:ok, []} = Queries.deploy_rates(:run, "t1", @window)
    sql = Mock.last_request()["__body"]
    assert sql =~ "coalesce(app_revision, '') AS revision"
    # "not completed" rather than a list of failure names: the runtime also
    # reports guard parks and repair failures, and a deploy that starts
    # parking runs must still show up here.
    assert sql =~ "countIf(status != 'completed') AS failed"
    assert sql =~ "ORDER BY last_seen DESC"

    assert {:ok, []} = Queries.deploy_rates(:tool, "t1", @window)
    assert Mock.last_request()["__body"] =~ "countIf(status IN ('completed', 'error')) AS calls"
  end

  test "llm queries filter by provider/entrypoint and split first-token quantiles" do
    Mock.respond_with(200, "")

    assert {:ok, []} =
             Queries.llm_speed("t1", @window ++ [provider: "openrouter", entrypoint: "round"])

    params = Mock.last_request()
    sql = params["__body"]

    assert params["param_provider"] == "openrouter"
    assert params["param_entrypoint"] == "round"
    assert sql =~ "AND provider = {provider:String}"
    assert sql =~ "AND entrypoint = {entrypoint:String}"
    assert sql =~ "quantileTDigestIf(0.95)(first_token_ms, first_token_ms IS NOT NULL)"
    assert sql =~ "countIf(first_token_ms IS NOT NULL) AS streaming_calls"
  end

  test "llm_reliability groups by outcome for caller-side rollup" do
    Mock.respond_with(200, "")

    assert {:ok, []} = Queries.llm_reliability("t1", @window)

    sql = Mock.last_request()["__body"]
    assert sql =~ "GROUP BY provider, model, entrypoint, status, error_type, http_status"
    assert sql =~ "countIf(attempts > 1) AS retried"
  end

  test "llm_trends keeps the per-provider split" do
    Mock.respond_with(200, "")

    assert {:ok, []} = Queries.llm_trends("t1", @window ++ [bucket_seconds: 3600])
    assert Mock.last_request()["__body"] =~ "GROUP BY bucket, provider"
  end

  test "session_costs sums llm time with tokens and tool time without" do
    Mock.respond_with(200, "")

    assert {:ok, []} = Queries.session_costs(:llm, "t1", @window)
    sql = Mock.last_request()["__body"]
    assert sql =~ "sum(prompt_tokens + completion_tokens) AS tokens"
    assert sql =~ "uniqExact(round_id) AS rounds"
    assert sql =~ "ORDER BY duration_ms DESC"

    assert {:ok, []} = Queries.session_costs(:tool, "t1", @window)
    sql = Mock.last_request()["__body"]
    assert sql =~ "FROM test.tool_call_events_v2"
    assert sql =~ "LIMIT 1 BY source, source_key"
    refute sql =~ "tokens"
  end

  test "session_trace binds tenant + session and carries model on the llm branch" do
    Mock.respond_with(200, "")

    assert {:ok, []} = Queries.session_trace("t1", "sess-9")

    params = Mock.last_request()
    sql = params["__body"]

    assert params["param_tenant_id"] == "t1"
    assert params["param_session_id"] == "sess-9"
    assert params["param_limit"] == "500"

    # Q4 as shipped returned only `provider AS name`; the timeline needs the
    # actual model, and every branch stays tenant-scoped.
    assert sql =~ "provider AS name"
    assert sql =~ ~r/'llm' AS event_kind[\s\S]*?\n\s+model,/
    assert sql =~ "tenant_id = {tenant_id:String} AND session_id = {session_id:String}"
    assert sql =~ "ORDER BY started_at ASC, round_id ASC, call_index ASC, event_kind ASC"
  end

  test "a non-budget error surfaces as a generic http error" do
    Mock.respond_with(500, "Code: 62. DB::Exception: boom")

    assert {:error, {:http, body}} = Queries.run_outcomes("t1")
    assert body =~ "boom"
  end

  test "a budget-limit code surfaces as a tagged over-budget result" do
    # Code 158 = TOO_MANY_ROWS (max_rows_to_read). The query declined to scan
    # further; the dashboard renders this as "narrow the window", not an error.
    Mock.respond_with(
      500,
      "Code: 158. DB::Exception: Limit for rows to read exceeded: would read 1000000 rows"
    )

    assert {:error, {:read_over_budget, detail}} = Queries.run_outcomes("t1")
    assert detail.code == 158
  end
end
