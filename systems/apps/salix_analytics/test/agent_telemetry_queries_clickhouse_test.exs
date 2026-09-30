defmodule SalixAnalytics.AgentTelemetryQueriesClickHouseTest do
  @moduledoc """
  End-to-end verification of AgentTelemetryQueries against a real ClickHouse
  (the Bandit mock cannot catch CH-side syntax/semantics: SETTINGS placement,
  UNION type unification, NaN-vs-null quantile output, join_use_nulls).

  Seeded world, all tenant `t1` group `g1` unless noted:

    * sess-a (agent ag-int): converged — ok LLM call, ok web_fetch, one
      guidance send_message, run terminal `completed` AFTER the activity.
    * sess-b (agent ag-int): stuck — js_run error + failed LLM call
      (429, 3 attempts), NO run terminal.
    * sess-c (agent ag-ext): stuck the same way — the query must return it
      too (internal filtering is the caller's job) with its agent id.
    * sess-d: activity, then run terminal after it — accounted for.
    * sess-e: run terminal `llm_failed` — a hard failure, not unconverged.
  """
  use ExUnit.Case, async: false

  alias SalixAnalytics.AgentTelemetryQueries, as: Queries
  alias SalixAnalytics.Migrations
  alias SalixAnalytics.{AgentPhaseEvent, AgentRunEvent, LLMCallEvent, ToolCallEvent}
  alias SalixAnalytics.Sink.ClickHouseTyped

  @moduletag :clickhouse

  @clickhouse_url "http://127.0.0.1:8123/"

  @from ~U[2026-07-10 09:00:00Z]
  @to ~U[2026-07-10 11:00:00Z]
  @stale_before ~U[2026-07-10 10:30:00Z]
  @window [from: @from, to: @to]

  setup_all do
    Application.ensure_all_started(:req)

    database = "salix_telemetry_q_test_#{System.unique_integer([:positive])}"
    prev = Application.get_env(:salix_analytics, :clickhouse)

    clickhouse_query!("DROP DATABASE IF EXISTS #{database}")

    Application.put_env(:salix_analytics, :clickhouse,
      base_url: @clickhouse_url,
      table: "#{database}.events"
    )

    {:ok, _versions} = Migrations.migrate()
    {:ok, 14} = ClickHouseTyped.insert(seed_rows())

    on_exit(fn ->
      Application.put_env(:salix_analytics, :clickhouse, prev)
      clickhouse_query!("DROP DATABASE IF EXISTS #{database}")
    end)

    :ok
  end

  defp seed_rows do
    [
      # ---- sess-a: converged, healthy ----
      llm("llm:a1", "sess-a", "ag-int", ~U[2026-07-10 10:00:00Z],
        status: "ok",
        duration_ms: 3_000,
        first_token_ms: 400,
        prompt_tokens: 100,
        completion_tokens: 50,
        round_id: "r-a1"
      ),
      tool("tool:a1", "sess-a", "ag-int", ~U[2026-07-10 10:00:10Z],
        tool_name: "web_fetch",
        status: "completed",
        duration_ms: 1_200
      ),
      tool("tool:a2", "sess-a", "ag-int", ~U[2026-07-10 10:01:00Z],
        tool_name: "send_message",
        tool_source: "mcp",
        status: "guidance",
        guidance_reason: "invalid_params",
        duration_ms: 0
      ),
      run("run:a", "sess-a", "ag-int", ~U[2026-07-10 10:01:20Z],
        status: "completed",
        duration_ms: 8_200
      ),
      phase("phase:a1:prepare", "sess-a", "ag-int", ~U[2026-07-10 09:59:59.700Z],
        phase: "prepare",
        duration_ms: 300,
        round_id: "r-a1",
        activation_key: "m1"
      ),
      phase("phase:a1:finalize", "sess-a", "ag-int", ~U[2026-07-10 10:00:03Z],
        phase: "finalize",
        duration_ms: 250,
        round_id: "r-a1",
        activation_key: "m1"
      ),

      # ---- sess-b: stuck internal ----
      tool("tool:b1", "sess-b", "ag-int", ~U[2026-07-10 10:05:00Z],
        tool_name: "js_run",
        tool_source: "js_host",
        status: "error",
        error_type: "exception",
        duration_ms: 800
      ),
      llm("llm:b1", "sess-b", "ag-int", ~U[2026-07-10 10:06:00Z],
        status: "error",
        error_type: "rate_limited",
        http_status: 429,
        attempts: 3,
        duration_ms: 20_000,
        round_id: "r-b1"
      ),

      # ---- sess-c: stuck, external agent ----
      llm("llm:c1", "sess-c", "ag-ext", ~U[2026-07-10 10:05:30Z],
        status: "ok",
        duration_ms: 2_000,
        prompt_tokens: 10,
        completion_tokens: 5,
        round_id: "r-c1"
      ),

      # ---- sess-d: activity, then a terminal covering it ----
      tool("tool:d1", "sess-d", "ag-int", ~U[2026-07-10 10:08:00Z],
        tool_name: "web_fetch",
        status: "completed",
        duration_ms: 500
      ),
      run("run:d", "sess-d", "ag-int", ~U[2026-07-10 10:10:00Z],
        status: "completed",
        duration_ms: 4_000
      ),

      # ---- sess-e: hard failure terminal ----
      run("run:e", "sess-e", "ag-int", ~U[2026-07-10 10:09:00Z],
        status: "llm_failed",
        duration_ms: 31_400
      ),

      # ---- noise: other tenant + outside the window ----
      run("run:x", "sess-x", "ag-int", ~U[2026-07-10 10:00:00Z],
        status: "llm_failed",
        duration_ms: 1,
        tenant_id: "t2"
      ),
      run("run:old", "sess-old", "ag-int", ~U[2026-07-09 01:00:00Z],
        status: "llm_failed",
        duration_ms: 1
      )
    ]
  end

  defp llm(key, session, agent, at, extra) do
    LLMCallEvent.build(
      Map.merge(
        %{
          source: "telemetry_query_test",
          source_key: key,
          entrypoint: "round",
          surface: "comma",
          tenant_id: "t1",
          group_id: "g1",
          actor_type: "system",
          charge_status: "unattributed",
          provider: "openrouter",
          model: "claude-haiku-4.5",
          started_at: at,
          app_revision: "revA",
          salix_agent_id: agent,
          session_id: session
        },
        Map.new(extra)
      )
    )
  end

  defp tool(key, session, agent, at, extra) do
    ToolCallEvent.build(
      Map.merge(
        %{
          source: "telemetry_query_test",
          source_key: key,
          entrypoint: "tool_call",
          surface: "comma",
          tenant_id: "t1",
          group_id: "g1",
          actor_type: "tool",
          tool_source: "builtin",
          started_at: at,
          call_index: 0,
          async: false,
          app_revision: "revA",
          salix_agent_id: agent,
          session_id: session
        },
        Map.new(extra)
      )
    )
  end

  defp run(key, session, agent, at, extra) do
    AgentRunEvent.build(
      Map.merge(
        %{
          source: "telemetry_query_test",
          source_key: key,
          entrypoint: "agent_run",
          surface: "comma",
          tenant_id: "t1",
          group_id: "g1",
          actor_type: "user",
          started_at: at,
          app_revision: "revA",
          salix_agent_id: agent,
          session_id: session,
          round_id: "round-" <> key
        },
        Map.new(extra)
      )
    )
  end

  defp phase(key, session, agent, at, extra) do
    AgentPhaseEvent.build(
      Map.merge(
        %{
          source: "telemetry_query_test",
          source_key: key,
          entrypoint: "agent_phase",
          surface: "comma",
          tenant_id: "t1",
          group_id: "g1",
          actor_type: "user",
          started_at: at,
          app_revision: "revA",
          salix_agent_id: agent,
          session_id: session
        },
        Map.new(extra)
      )
    )
  end

  test "run_outcomes reconciles: rounds = completed + failed" do
    assert {:ok, [row]} = Queries.run_outcomes("t1", @window)

    assert row["rounds"] == 3
    assert row["completed"] == 2
    assert row["llm_failed"] == 1
    assert row["actor_failed"] == 0
  end

  test "run_outcomes counts guard parks and repair failures apart from crashes" do
    # These four statuses all reached ClickHouse as `actor_failed` until the
    # runtime stopped flattening them. Its own tenant AND its own time range:
    # the deployment-wide (:all) reads over @window assert an exact row count.
    park_window = [from: ~U[2026-07-10 12:00:00Z], to: ~U[2026-07-10 12:30:00Z]]

    rows = [
      run("run:p1", "sess-p", "ag-int", ~U[2026-07-10 12:05:00Z],
        status: "runaway_guard_parked",
        duration_ms: 10,
        tenant_id: "park-tenant"
      ),
      run("run:p2", "sess-p", "ag-int", ~U[2026-07-10 12:06:00Z],
        status: "input_round_budget_parked",
        duration_ms: 10,
        tenant_id: "park-tenant"
      ),
      run("run:p3", "sess-p", "ag-int", ~U[2026-07-10 12:07:00Z],
        status: "repair_failed",
        duration_ms: 10,
        tenant_id: "park-tenant"
      ),
      run("run:p4", "sess-p", "ag-int", ~U[2026-07-10 12:08:00Z],
        status: "completed",
        duration_ms: 10,
        tenant_id: "park-tenant"
      )
    ]

    assert {:ok, 4} = ClickHouseTyped.insert(rows)
    assert {:ok, [row]} = Queries.run_outcomes("park-tenant", park_window)

    assert row["rounds"] == 4
    assert row["completed"] == 1
    assert row["parked"] == 2
    assert row["repair_failed"] == 1

    # None of them is a crash.
    assert row["actor_failed"] == 0
    assert row["llm_failed"] == 0

    # The page totals with `rounds - completed`, so every ending stays
    # accounted for even when it has no column of its own.
    assert row["rounds"] - row["completed"] == 3

    # The trend line counts the same three. ExUnit randomizes test order, so
    # this rides in the test that inserted the rows rather than a later one.
    assert {:ok, [trend]} =
             Queries.round_trends("park-tenant", park_window ++ [bucket_seconds: 3600])

    assert trend["rounds"] == 4
    assert trend["failed"] == 3
  end

  test "round_trends buckets and quantiles decode as numbers" do
    assert {:ok, [row]} = Queries.round_trends("t1", @window ++ [bucket_seconds: 3600])

    assert row["bucket"] =~ "2026-07-10 10:00:00"
    assert row["rounds"] == 3
    assert row["failed"] == 1
    assert is_number(row["p50_ms"]) and is_number(row["p95_ms"])
  end

  test "unknown_trends measures the wall clock no row covers per activation bucket" do
    assert {:ok, rows} = Queries.unknown_trends("t1", @window ++ [bucket_seconds: 3600])
    by_bucket = Map.new(rows, &{&1["bucket"], &1})

    # sess-a: its prepare phase starts at 09:59:59.7, so the activation
    # (model round + prepare + finalize, chained by the time heuristic with
    # the run terminal 77s later) buckets at 09:00. The round itself is fully
    # covered; the stretch up to the terminal is not.
    assert %{"activations" => 1, "span_ms" => 88_500, "unknown_ms" => 84_950, "phase_ms" => 550} =
             by_bucket["2026-07-10 09:00:00"]

    # 10:00: sess-b's failed call and sess-c's call (fully covered), plus the
    # terminal-only sess-d and sess-e rounds (fully unknown). No phases.
    assert %{"activations" => 4, "span_ms" => 57_400, "unknown_ms" => 35_400, "phase_ms" => 0} =
             by_bucket["2026-07-10 10:00:00"]

    assert map_size(by_bucket) == 2
  end

  test "failed_rounds returns only non-completed terminals in the window" do
    assert {:ok, [row]} = Queries.failed_rounds("t1", @window)

    assert row["session_id"] == "sess-e"
    assert row["status"] == "llm_failed"
    assert row["app_revision"] == "revA"
  end

  test "unconverged_sessions finds silent sessions with agent ids, newest silence first" do
    assert {:ok, rows} =
             Queries.unconverged_sessions("t1", @window ++ [stale_before: @stale_before])

    assert Enum.map(rows, & &1["session_id"]) == ["sess-b", "sess-c"]

    by_session = Map.new(rows, &{&1["session_id"], &1})
    assert by_session["sess-b"]["salix_agent_id"] == "ag-int"
    assert by_session["sess-c"]["salix_agent_id"] == "ag-ext"
    assert by_session["sess-b"]["activity_events"] == 2
  end

  test "tool_rates reconciles outcomes and guidance reasons, worst first" do
    assert {:ok, rows} = Queries.tool_rates("t1", @window)

    assert [%{"tool_name" => "js_run"} | _] = rows

    by_tool = Map.new(rows, &{&1["tool_name"], &1})
    assert by_tool["web_fetch"]["completed_calls"] == 2
    assert by_tool["js_run"]["error_calls"] == 1
    assert by_tool["send_message"]["guidance_calls"] == 1
    assert by_tool["send_message"]["guidance_invalid_params"] == 1
  end

  test "tool_latency and drill queries agree on the failing tool" do
    assert {:ok, latency} = Queries.tool_latency("t1", @window)
    js = Enum.find(latency, &(&1["tool_name"] == "js_run"))
    assert js["async"] == false
    assert is_number(js["p95_ms"])

    assert {:ok, [%{"error_type" => "exception", "calls" => 1}]} =
             Queries.tool_error_types("t1", "js_run", @window)

    assert {:ok, [row]} = Queries.tool_top_sessions("t1", "js_run", @window)
    assert row["session_id"] == "sess-b"
    assert row["salix_agent_id"] == "ag-int"
  end

  test "llm_overview counts retries and measures first word from streaming calls only" do
    assert {:ok, [row]} = Queries.llm_overview("t1", @window)

    assert row["calls"] == 3
    assert row["failed"] == 1
    assert row["retried"] == 1
    # Only sess-a's call streamed; its 400ms is the whole distribution.
    assert_in_delta row["p95_first_token_ms"], 400.0, 1.0
  end

  test "llm_reliability exposes the outcome split for caller-side rollup" do
    assert {:ok, rows} = Queries.llm_reliability("t1", @window)

    error_row = Enum.find(rows, &(&1["status"] == "error"))
    assert error_row["error_type"] == "rate_limited"
    assert error_row["http_status"] == 429
    assert error_row["calls"] == 1
    assert error_row["retried"] == 1
  end

  test "llm_speed emits null (not NaN) first-word quantiles for non-streaming groups" do
    assert {:ok, rows} = Queries.llm_speed("t1", @window)

    assert [row] = rows
    assert row["provider"] == "openrouter"
    assert row["calls"] == 3
    assert row["streaming_calls"] == 1
    assert is_number(row["p95_first_token_ms"])
  end

  test "llm_trends splits buckets by provider" do
    assert {:ok, [row]} = Queries.llm_trends("t1", @window ++ [bucket_seconds: 3600])

    assert row["provider"] == "openrouter"
    assert row["calls"] == 3
    assert row["failed"] == 1
  end

  test "error_overview scans current and previous windows in one pass" do
    assert {:ok, [tool_row]} = Queries.error_overview(:tool, "t1", @window)
    # Infra denominator: 2 completed + 1 error; guidance is excluded.
    assert tool_row["calls"] == 3
    assert tool_row["errors"] == 1
    assert tool_row["prev_calls"] == 0

    assert {:ok, [llm_row]} = Queries.error_overview(:llm, "t1", @window)
    assert llm_row["calls"] == 3
    assert llm_row["errors"] == 1
  end

  test "deploy_rates groups by revision" do
    assert {:ok, [row]} = Queries.deploy_rates(:run, "t1", @window)
    assert row["revision"] == "revA"
    assert row["rounds"] == 3
    assert row["failed"] == 1

    assert {:ok, [tool_row]} = Queries.deploy_rates(:tool, "t1", @window)
    assert tool_row["calls"] == 3
    assert tool_row["errors"] == 1
  end

  test "session_costs ranks sessions by summed duration" do
    assert {:ok, rows} = Queries.session_costs(:llm, "t1", @window)
    assert [%{"session_id" => "sess-b"} | _] = rows

    a = Enum.find(rows, &(&1["session_id"] == "sess-a"))
    assert a["tokens"] == 150
    assert a["rounds"] == 1

    assert {:ok, [top | _]} = Queries.session_costs(:tool, "t1", @window)
    assert top["session_id"] == "sess-a"
    assert top["duration_ms"] == 1_200
  end

  test "session_trace returns one ordered mixed stream, tenant-scoped, with model" do
    assert {:ok, rows} = Queries.session_trace("t1", "sess-a")

    assert Enum.map(rows, & &1["event_kind"]) == ["llm", "tool", "tool", "run"]

    [llm_row, tool_row, guidance_row, run_row] = rows
    assert llm_row["model"] == "claude-haiku-4.5"
    assert llm_row["name"] == "openrouter"
    assert is_number(llm_row["first_token_ms"])
    assert tool_row["name"] == "web_fetch"
    assert guidance_row["guidance_reason"] == "invalid_params"
    assert run_row["status"] == "completed"

    # Another tenant sees nothing.
    assert {:ok, []} = Queries.session_trace("t2", "sess-a")
  end

  test "activity_trace identifies historical round-less compaction calls" do
    # The seeded table is shared by every test in this module. Keep this row
    # outside @window so the deployment-wide (:all) count below stays exact.
    row =
      llm("compaction:label", "compaction-session", "ag-int", ~U[2026-07-10 12:00:02Z],
        tenant_id: "compaction-tenant",
        entrypoint: "compaction",
        duration_ms: 16_044,
        status: "ok"
      )

    compaction_window = [from: ~U[2026-07-10 11:30:00Z], to: ~U[2026-07-10 12:30:00Z]]

    assert {:ok, 1} = ClickHouseTyped.insert([row])
    assert {:ok, [call]} = Queries.activity_trace("compaction-tenant", compaction_window)
    assert call["event_kind"] == "compaction"
    assert call["round_id"] in [nil, ""]
    assert call["duration_ms"] == 16_044
  end

  test "activity_trace feeds every call in the window newest first, per tenant or for all" do
    assert {:ok, rows} = Queries.activity_trace("t1", @window)

    # All three kinds, with the identity columns a cross-session lane needs;
    # t2's run and the out-of-window run are absent.
    kinds = rows |> Enum.map(& &1["event_kind"]) |> Enum.frequencies()
    assert kinds == %{"llm" => 3, "tool" => 4, "run" => 3, "phase" => 2}

    # Phase rows carry the phase name and the activation key; the other
    # kinds carry no key.
    phases = Enum.filter(rows, &(&1["event_kind"] == "phase"))
    assert Enum.map(phases, & &1["name"]) |> Enum.sort() == ["finalize", "prepare"]
    assert Enum.all?(phases, &(&1["activation_key"] == "m1" and &1["round_id"] == "r-a1"))
    assert Enum.all?(rows -- phases, &is_nil(&1["activation_key"]))
    assert Enum.all?(rows, &(&1["tenant_id"] == "t1" and is_binary(&1["session_id"])))
    refute Enum.any?(rows, &(&1["session_id"] in ["sess-x", "sess-old"]))

    starts = Enum.map(rows, & &1["started_at"])
    assert starts == Enum.sort(starts, :desc)

    llm = Enum.find(rows, &(&1["session_id"] == "sess-b" and &1["event_kind"] == "llm"))
    assert llm["model"] == "claude-haiku-4.5"
    assert llm["attempts"] == 3
    assert llm["error_type"] == "rate_limited"
    assert llm["round_id"] == "r-b1"

    tool = Enum.find(rows, &(&1["name"] == "send_message"))
    assert tool["guidance_reason"] == "invalid_params"
    assert tool["detail"] == "mcp"

    # The deployment-wide read adds t2's window row and honours the limit.
    assert {:ok, all_rows} = Queries.activity_trace(:all, @window)
    assert length(all_rows) == length(rows) + 1
    assert Enum.any?(all_rows, &(&1["tenant_id"] == "t2"))

    assert {:ok, capped} = Queries.activity_trace(:all, @window ++ [limit: 2])
    assert length(capped) == 2

    # The paging cursor cuts on a round's earliest started_at, strictly, at
    # millisecond precision, and returns whole rounds: r-a1 starts with its
    # prepare phase at 09:59:59.700 and its finalize (10:00:03) rides along.
    page = fn before ->
      {:ok, rows} = Queries.activity_trace("t1", @window ++ [before: before])
      rows |> Enum.map(&{&1["event_kind"], &1["name"]}) |> Enum.sort()
    end

    whole_round = [{"llm", "openrouter"}, {"phase", "finalize"}, {"phase", "prepare"}]
    assert page.(~U[2026-07-10 10:00:03.100Z]) == whole_round
    assert page.(~U[2026-07-10 10:00:00.000Z]) == whole_round
    assert page.(~U[2026-07-10 09:59:59.701Z]) == whole_round
    assert page.(~U[2026-07-10 09:59:59.700Z]) == []
    assert page.(~U[2026-07-10 09:00:00Z]) == []

    # A call with no round pages by its own started_at: sess-a's two
    # round-less tool calls (10:00:10 and 10:01:00) come one at a time,
    # not as one unit keyed to the earlier of them.
    assert page.(~U[2026-07-10 10:00:30Z]) == Enum.sort(whole_round ++ [{"tool", "web_fetch"}])

    assert page.(~U[2026-07-10 10:01:00.001Z]) ==
             Enum.sort(whole_round ++ [{"tool", "web_fetch"}, {"tool", "send_message"}])
  end

  defp clickhouse_query!(sql) do
    case Req.post(@clickhouse_url, params: [query: sql], body: "", receive_timeout: 30_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        to_string(body)

      {:ok, %{status: status, body: body}} ->
        raise "ClickHouse query failed with #{status}: #{body}\nSQL:\n#{sql}"

      {:error, reason} ->
        raise "ClickHouse query failed: #{inspect(reason)}\nSQL:\n#{sql}"
    end
  end
end
