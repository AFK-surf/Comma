defmodule SalixWeb.Dashboard.RuntimeHealthLiveTest do
  @moduledoc """
  Runtime Health pages: reconciling stat strips, trend charts, deploy table,
  the internal-only attention list, tab/filter URL persistence, drills.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SalixWeb.DashboardEndpoint

  # Chart buckets are aligned to the epoch grid, so stub rows must sit on the
  # current hour — hardcoded timestamps would fall out of the moving window.
  defmodule Buckets do
    @moduledoc false
    def hour_start(hours_back \\ 0) do
      unix = div(System.os_time(:second), 3600) * 3600 - hours_back * 3600
      unix |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
    end
  end

  defmodule StubQueries do
    import Buckets, only: [hour_start: 1]

    def run_outcomes(_t, _o),
      do: {:ok, [%{"rounds" => 20, "completed" => 17, "llm_failed" => 2, "actor_failed" => 1}]}

    def round_trends(_t, _o) do
      {:ok,
       [
         %{
           "bucket" => hour_start(1),
           "rounds" => 12,
           "failed" => 1,
           "p50_ms" => 4000.0,
           "p95_ms" => 21_000.0
         },
         %{
           "bucket" => hour_start(0),
           "rounds" => 8,
           "failed" => 2,
           "p50_ms" => 6000.0,
           "p95_ms" => 30_000.0
         }
       ]}
    end

    def unknown_trends(_t, _o) do
      {:ok,
       [
         %{
           "bucket" => hour_start(1),
           "activations" => 6,
           "span_ms" => 120_000,
           "unknown_ms" => 36_000,
           "phase_ms" => 24_000
         },
         %{
           "bucket" => hour_start(0),
           "activations" => 4,
           "span_ms" => 80_000,
           "unknown_ms" => 8_000,
           "phase_ms" => 20_000
         }
       ]}
    end

    # One internal, one external, one unresolvable — only ag-int survives.
    def unconverged_sessions(_t, _o) do
      {:ok,
       [
         %{
           "session_id" => "sess-stuck",
           "salix_agent_id" => "ag-int",
           "last_activity_at" => hour_start(0),
           "activity_events" => 9
         },
         %{
           "session_id" => "sess-ext",
           "salix_agent_id" => "ag-ext",
           "last_activity_at" => hour_start(0),
           "activity_events" => 5
         },
         %{
           "session_id" => "sess-gone",
           "salix_agent_id" => "ag-missing",
           "last_activity_at" => hour_start(0),
           "activity_events" => 2
         }
       ]}
    end

    def error_overview(:tool, _t, _o),
      do: {:ok, [%{"calls" => 900, "errors" => 27, "prev_calls" => 800, "prev_errors" => 8}]}

    def error_overview(:llm, _t, _o),
      do: {:ok, [%{"calls" => 500, "errors" => 5, "prev_calls" => 480, "prev_errors" => 6}]}

    def deploy_rates(:run, _t, _o) do
      {:ok,
       [
         %{"revision" => "revB", "rounds" => 100, "failed" => 8, "last_seen" => hour_start(0)},
         %{"revision" => "revA", "rounds" => 200, "failed" => 6, "last_seen" => hour_start(1)},
         %{"revision" => "revTiny", "rounds" => 3, "failed" => 1, "last_seen" => hour_start(2)}
       ]}
    end

    def deploy_rates(:tool, _t, _o) do
      {:ok,
       [
         %{"revision" => "revB", "calls" => 400, "errors" => 12, "last_seen" => hour_start(0)},
         %{"revision" => "revA", "calls" => 500, "errors" => 5, "last_seen" => hour_start(1)}
       ]}
    end

    def deploy_rates(:llm, _t, _o) do
      {:ok,
       [
         %{"revision" => "revB", "calls" => 250, "errors" => 2, "last_seen" => hour_start(0)},
         %{"revision" => "revA", "calls" => 250, "errors" => 3, "last_seen" => hour_start(1)}
       ]}
    end

    def failed_rounds(_t, _o) do
      {:ok,
       [
         %{
           "salix_agent_id" => "ag-int",
           "session_id" => "sess-fail",
           "round_id" => "r9",
           "status" => "llm_failed",
           "duration_ms" => 31_400,
           "app_revision" => "revB",
           "observed_at" => hour_start(0)
         }
       ]}
    end

    def session_costs(:llm, _t, _o) do
      {:ok,
       [
         %{
           "session_id" => "sess-big",
           "salix_agent_id" => "ag-int",
           "duration_ms" => 580_000,
           "tokens" => 412_000,
           "rounds" => 21,
           "errors" => 2
         }
       ]}
    end

    def session_costs(:tool, _t, _o) do
      {:ok,
       [
         %{
           "session_id" => "sess-big",
           "salix_agent_id" => "ag-int",
           "duration_ms" => 1_325_000,
           "errors" => 1
         }
       ]}
    end

    def tool_rates(_t, _o) do
      {:ok,
       [
         %{
           "tool_name" => "js_run",
           "tool_source" => "js_host",
           "total_calls" => 500,
           "completed_calls" => 470,
           "error_calls" => 25,
           "guidance_calls" => 5,
           "cancelled_calls" => 0,
           "guidance_not_callable" => 0,
           "guidance_not_disclosed" => 0,
           "guidance_invalid_params" => 5,
           "guidance_envelope_misuse" => 0,
           "capped_calls" => 3
         },
         %{
           "tool_name" => "web_fetch",
           "tool_source" => "builtin",
           "total_calls" => 400,
           "completed_calls" => 390,
           "error_calls" => 2,
           "guidance_calls" => 8,
           "cancelled_calls" => 0,
           "guidance_not_callable" => 6,
           "guidance_not_disclosed" => 0,
           "guidance_invalid_params" => 2,
           "guidance_envelope_misuse" => 0,
           "capped_calls" => 0
         }
       ]}
    end

    def tool_latency(_t, _o) do
      {:ok,
       [
         %{
           "tool_name" => "js_run",
           "tool_source" => "js_host",
           "async" => false,
           "total_calls" => 500,
           "p50_ms" => 600.0,
           "p95_ms" => 4200.0
         },
         %{
           "tool_name" => "send_message",
           "tool_source" => "mcp",
           "async" => true,
           "total_calls" => 300,
           "p50_ms" => 3400.0,
           "p95_ms" => 41_000.0
         }
       ]}
    end

    def tool_error_types(_t, "js_run", _o),
      do: {:ok, [%{"error_type" => "exception", "calls" => 20}]}

    def tool_top_sessions(_t, "js_run", _o),
      do: {:ok, [%{"session_id" => "sess-hit", "salix_agent_id" => "ag-int", "calls" => 12}]}

    def llm_overview(_t, _o) do
      {:ok, [%{"calls" => 500, "failed" => 5, "retried" => 21, "p95_first_token_ms" => 2800.0}]}
    end

    def llm_reliability(_t, _o) do
      {:ok,
       [
         %{
           "provider" => "openrouter",
           "model" => "claude-haiku-4.5",
           "entrypoint" => "round",
           "status" => "ok",
           "error_type" => "none",
           "http_status" => nil,
           "calls" => 480,
           "retried" => 18
         },
         %{
           "provider" => "openrouter",
           "model" => "claude-haiku-4.5",
           "entrypoint" => "round",
           "status" => "error",
           "error_type" => "rate_limited",
           "http_status" => 429,
           "calls" => 5,
           "retried" => 3
         }
       ]}
    end

    def llm_speed(_t, _o) do
      {:ok,
       [
         %{
           "provider" => "openrouter",
           "model" => "claude-haiku-4.5",
           "entrypoint" => "round",
           "calls" => 485,
           "p50_ms" => 3100.0,
           "p95_ms" => 9200.0,
           "p95_first_token_ms" => 900.0,
           "streaming_calls" => 400
         }
       ]}
    end

    def llm_trends(_t, _o) do
      {:ok,
       [
         %{
           "bucket" => hour_start(0),
           "provider" => "openrouter",
           "calls" => 200,
           "failed" => 4,
           "p95_first_token_ms" => 950.0
         },
         %{
           "bucket" => hour_start(1),
           "provider" => "openai",
           "calls" => 100,
           "failed" => 0,
           "p95_first_token_ms" => 500.0
         }
       ]}
    end

    # Activity feed. The scope the LiveView asked for is reported to the
    # test (the connected LiveView runs in its own process, so `self()`
    # would be wrong); `:all` adds a second tenant's round.
    def activity_trace(scope, opts) do
      if pid = Process.whereis(:activity_trace_listener),
        do: send(pid, {:activity_trace_scope, scope, opts})

      base = "2026-09-04 10:00:00"
      at = fn ms -> base <> "." <> String.pad_leading(to_string(ms), 3, "0") end

      if opts[:before], do: paged_rows(opts), else: {:ok, first_page(scope, at)}
    end

    # An older page: a feed that fills its row limit with one-call
    # activations, each a second older than the last, all before the cursor.
    defp paged_rows(opts) do
      before_ms = DateTime.to_unix(opts[:before], :millisecond)

      rows =
        for i <- 1..opts[:limit] do
          start = DateTime.from_unix!(before_ms - i * 1_000, :millisecond)

          %{
            "event_kind" => "llm",
            "tenant_id" => "default",
            "group_id" => "g1",
            "salix_agent_id" => "ag-int",
            "session_id" => "sess-old-#{i}",
            "round_id" => "round-old-#{i}",
            "started_at" =>
              Calendar.strftime(start, "%Y-%m-%d %H:%M:%S.%f") |> String.slice(0, 23),
            "duration_ms" => 500,
            "name" => "openrouter",
            "model" => "haiku",
            "status" => "ok",
            "attempts" => 1
          }
        end

      {:ok, rows}
    end

    defp first_page(scope, at) do
      own = [
        %{
          "event_kind" => "llm",
          "tenant_id" => "default",
          "group_id" => "g1",
          "salix_agent_id" => "ag-int",
          "session_id" => "sess-act",
          "round_id" => "round-first-1",
          "started_at" => at.(0),
          "duration_ms" => 300,
          "name" => "openrouter",
          "model" => "claude-haiku-4.5",
          "status" => "ok",
          "attempts" => 1
        },
        %{
          "event_kind" => "tool",
          "tenant_id" => "default",
          "group_id" => "g1",
          "salix_agent_id" => "ag-int",
          "session_id" => "sess-act",
          "round_id" => "round-first-1",
          "started_at" => at.(300),
          "duration_ms" => 100,
          "name" => "web_fetch",
          "detail" => "builtin",
          "status" => "completed",
          "async" => false
        },
        %{
          "event_kind" => "llm",
          "tenant_id" => "default",
          "group_id" => "g1",
          "salix_agent_id" => "ag-int",
          "session_id" => "sess-act",
          "round_id" => "round-second-2",
          "started_at" => at.(600),
          "duration_ms" => 200,
          "name" => "openrouter",
          "model" => "claude-haiku-4.5",
          "status" => "ok",
          "attempts" => 2
        },
        %{
          "event_kind" => "run",
          "tenant_id" => "default",
          "group_id" => "g1",
          "salix_agent_id" => "ag-int",
          "session_id" => "sess-act",
          "round_id" => "round-second-2",
          "started_at" => at.(600),
          "duration_ms" => 400,
          "name" => "agent_run",
          "status" => "completed"
        },
        # Recorded phases: the first round's boundary write and the second
        # round's activation cover most of the wait between the rounds.
        %{
          "event_kind" => "phase",
          "tenant_id" => "default",
          "group_id" => "g1",
          "salix_agent_id" => "ag-int",
          "session_id" => "sess-act",
          "round_id" => "round-first-1",
          "started_at" => at.(400),
          "duration_ms" => 40,
          "name" => "boundary",
          "status" => "ok",
          "activation_key" => "msg-1"
        },
        %{
          "event_kind" => "phase",
          "tenant_id" => "default",
          "group_id" => "g1",
          "salix_agent_id" => "ag-int",
          "session_id" => "sess-act",
          "round_id" => "round-second-2",
          "started_at" => at.(540),
          "duration_ms" => 60,
          "name" => "activation",
          "status" => "ok",
          "activation_key" => "msg-1"
        },
        # An external worker's proxied tool calls: a session, no round.
        %{
          "event_kind" => "tool",
          "tenant_id" => "default",
          "group_id" => "g1",
          "salix_agent_id" => "ag-ext",
          "session_id" => "sess-ext",
          "round_id" => nil,
          "started_at" => at.(700),
          "duration_ms" => 100,
          "name" => "env.exec",
          "detail" => "other",
          "status" => "completed",
          "async" => false
        },
        %{
          "event_kind" => "tool",
          "tenant_id" => "default",
          "group_id" => "g1",
          "salix_agent_id" => "ag-ext",
          "session_id" => "sess-ext",
          "round_id" => nil,
          "started_at" => at.(900),
          "duration_ms" => 50,
          "name" => "im_api.internal.send_message",
          "detail" => "im",
          "status" => "completed",
          "async" => false
        }
      ]

      other =
        if scope == :all do
          [
            %{
              "event_kind" => "llm",
              "tenant_id" => "other-tenant",
              "group_id" => "g9",
              "salix_agent_id" => "ag-other",
              "session_id" => "sess-other",
              "round_id" => "round-other-9",
              "started_at" => at.(50),
              "duration_ms" => 100,
              "name" => "openai",
              "model" => "gpt-test",
              "status" => "error",
              "error_type" => "rate_limited",
              "attempts" => 1
            }
          ]
        else
          []
        end

      own ++ other
    end
  end

  defmodule NotConfiguredQueries do
    def run_outcomes(_t, _o), do: {:error, :not_configured}
    def deploy_rates(_k, _t, _o), do: {:error, :not_configured}
  end

  # A lone bucket has no line segment to ride on; both trend charts must
  # still mark it (regression: sparse data rendered an empty duration chart).
  defmodule SingleBucketQueries do
    import Buckets, only: [hour_start: 1]

    def round_trends(_t, _o) do
      {:ok,
       [
         %{
           "bucket" => hour_start(0),
           "rounds" => 3,
           "failed" => 1,
           "p50_ms" => 4000.0,
           "p95_ms" => 9000.0
         }
       ]}
    end

    defdelegate run_outcomes(t, o), to: SalixWeb.Dashboard.RuntimeHealthLiveTest.StubQueries
    defdelegate unknown_trends(t, o), to: SalixWeb.Dashboard.RuntimeHealthLiveTest.StubQueries

    defdelegate unconverged_sessions(t, o),
      to: SalixWeb.Dashboard.RuntimeHealthLiveTest.StubQueries

    defdelegate error_overview(k, t, o), to: SalixWeb.Dashboard.RuntimeHealthLiveTest.StubQueries
    defdelegate deploy_rates(k, t, o), to: SalixWeb.Dashboard.RuntimeHealthLiveTest.StubQueries
    defdelegate failed_rounds(t, o), to: SalixWeb.Dashboard.RuntimeHealthLiveTest.StubQueries
    defdelegate session_costs(k, t, o), to: SalixWeb.Dashboard.RuntimeHealthLiveTest.StubQueries
  end

  # The runtime reports guard parks and repair failures under their own
  # names. `unnamed` stands for a status this page does not know yet: it has
  # no column of its own, so only `rounds - completed` accounts for it.
  defmodule ParkedOutcomeQueries do
    def run_outcomes(_t, _o) do
      {:ok,
       [
         %{
           "rounds" => 26,
           "completed" => 17,
           "llm_failed" => 2,
           "actor_failed" => 1,
           "repair_failed" => 3,
           "parked" => 1
         }
       ]}
    end

    defdelegate round_trends(t, o), to: SalixWeb.Dashboard.RuntimeHealthLiveTest.StubQueries
    defdelegate unknown_trends(t, o), to: SalixWeb.Dashboard.RuntimeHealthLiveTest.StubQueries

    defdelegate unconverged_sessions(t, o),
      to: SalixWeb.Dashboard.RuntimeHealthLiveTest.StubQueries

    defdelegate error_overview(k, t, o), to: SalixWeb.Dashboard.RuntimeHealthLiveTest.StubQueries
    defdelegate deploy_rates(k, t, o), to: SalixWeb.Dashboard.RuntimeHealthLiveTest.StubQueries
    defdelegate failed_rounds(t, o), to: SalixWeb.Dashboard.RuntimeHealthLiveTest.StubQueries
    defdelegate session_costs(k, t, o), to: SalixWeb.Dashboard.RuntimeHealthLiveTest.StubQueries
  end

  # Agent registry stand-in for internal/external labeling.
  defmodule StubAgentControl do
    def get_record("ag-ext"), do: {:ok, %{"runtime_config" => %{"kind" => "external"}}}
    def get_record("ag-missing"), do: {:error, :not_found}

    def get_record("ag-int"),
      do: {:ok, %{"name" => "Router Bot", "runtime_config" => %{"kind" => "internal"}}}

    def get_record(_id), do: {:ok, %{"runtime_config" => %{"kind" => "internal"}}}

    defdelegate runtime_kind(agent), to: SalixAgent.Control
  end

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => "default"})

  defp with_stubs(queries_mod) do
    prev_q = Application.get_env(:salix_web, :agent_telemetry_queries_mod)
    prev_a = Application.get_env(:salix_web, :agent_control_mod)
    Application.put_env(:salix_web, :agent_telemetry_queries_mod, queries_mod)
    Application.put_env(:salix_web, :agent_control_mod, StubAgentControl)

    on_exit(fn ->
      restore(:agent_telemetry_queries_mod, prev_q)
      restore(:agent_control_mod, prev_a)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:salix_web, key)
  defp restore(key, value), do: Application.put_env(:salix_web, key, value)

  defp with_metering do
    prev = Application.get_env(:salix_agent, :llm_metering_mod)
    Application.put_env(:salix_agent, :llm_metering_mod, SalixAgent.LLMMetering.Noop)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:salix_agent, :llm_metering_mod, prev),
        else: Application.delete_env(:salix_agent, :llm_metering_mod)
    end)
  end

  test "the overview names guard parks and repair failures and still balances" do
    with_stubs(ParkedOutcomeQueries)

    {:ok, view, _} = live(authed_conn(), "/dash/runtime")
    html = render(view)

    # A park is not a crash, so the card cannot be called "Failed" any more.
    assert html =~ "Did not finish"
    assert html =~ "3 no tool call"
    assert html =~ "1 stopped by a guard"

    # 26 - 17 = 9, of which the named counts cover 7. The remaining 2 have no
    # column, and must still be visible rather than silently dropped.
    assert html =~ "(26 = 17 + 9)"
    assert html =~ "2 ended another way"
  end

  test "overview reconciles the strip and filters the attention list to internal sessions" do
    with_stubs(StubQueries)

    {:ok, view, _} = live(authed_conn(), "/dash/runtime")

    html = render(view)

    # Identity line: rounds ended = finished + did not finish. The card
    # counts every ending that is not `completed`, so the identity holds for
    # statuses this page does not name yet.
    assert html =~ "rounds ended = finished + did not finish"
    assert html =~ "(20 = 17 + 3)"
    assert html =~ "2 model failed"
    assert html =~ "1 agent failed"

    # Trends render as SVG with per-bucket hover counts.
    assert html =~ "Rounds failing, over time"
    assert html =~ "<polyline"
    assert html =~ "1 of 12 failed"
    assert html =~ "Round duration trend"
    assert html =~ "p95 30.0s"

    # Unknown-time share rides the same grid: 30% then 10%, labelled as a
    # floor, with the activation count and the recorded-phase share in the
    # hover text.
    assert html =~ "Time nothing accounts for, over time"
    assert html =~ "The share is a floor"
    assert html =~ "unknown at least 30.0% of 2m 0s across 6 activations · recorded phases 20.0%"
    assert html =~ "unknown at least 10.0% of 1m 20s across 4 activations · recorded phases 25.0%"

    # Doorway tiles carry the previous-window comparison; the tool tile got
    # worse (1.0% → 3.0%) so it warns.
    assert html =~ "Tool calls breaking"
    assert html =~ "▲ was 1.0% in the previous window"
    assert html =~ "Model calls failing"

    # Deploy table: reconciling cells, grey low-volume row, regression delta
    # vs the previous deploy (8.0% − 3.0% = +5.0pt).
    assert html =~ "Error rate by deploy"
    assert html =~ "8.0% (8/100)"
    assert html =~ "▲ +5.0pt"
    assert html =~ "too few calls to judge"

    # Attention: the hard failure plus ONLY the internal silent session —
    # the external and unresolvable ones are dropped, and the unaccounted
    # tile counts the same filtered set (1).
    assert html =~ "sess-fail"
    assert html =~ "sess-stuck"
    refute html =~ "sess-ext"
    refute html =~ "sess-gone"
    assert html =~ "never finished"
    assert html =~ "model failed"

    # Session links land on the timeline card.
    assert html =~ "/dash/agents/ag-int/sessions/sess-stuck#timeline"

    # Costs: model + tool time with muted tokens.
    assert html =~ "Slowest and most expensive sessions"
    assert html =~ "sess-big"
    assert html =~ "412.0k"
  end

  test "tools tab reconciles outcomes and drills into a tool" do
    with_stubs(StubQueries)

    {:ok, view, _} = live(authed_conn(), "/dash/runtime/tools")

    html = render(view)

    # Identity: calls = worked + broke + sent back (+ cancelled).
    assert html =~ "calls = worked + broke + sent back (+ cancelled)"
    assert html =~ "(900 = 860 + 27 + 13 + 0)"

    # Scoreboard: worst first, reconciling cells.
    assert html =~ "js_run"
    assert html =~ "25/495"
    # Sent-back reasons in plain language, with the behavior-signals bridge.
    assert html =~ "Wrong parameters"
    assert html =~ "Tool not available to this agent"
    assert html =~ "see behavior signals →"
    assert html =~ "/dash/trajectory-evals"

    # Async latency rows are labeled, never averaged in.
    assert html =~ "async"
    assert html =~ "41.0s"

    # Row click drills into error types + hardest-hit sessions.
    drilled = view |> element("tr[phx-value-tool=js_run]") |> render_click()
    assert drilled =~ "exception"
    assert drilled =~ "sess-hit"
    assert drilled =~ "/dash/agents/ag-int/sessions/sess-hit#timeline"
  end

  test "models tab explains metering-off, then renders reliability when enabled" do
    with_stubs(StubQueries)

    {:ok, view, _} = live(authed_conn(), "/dash/runtime/models")

    off_html = render(view)
    assert off_html =~ "LLM metering not enabled"

    with_metering()
    {:ok, view, _} = live(authed_conn(), "/dash/runtime/models")
    html = render(view)

    assert html =~ "retries fold into one row"
    assert html =~ "First word (p95)"
    assert html =~ "2.8s"

    # Reliability rollup: 485 calls, 5 failed, top failure labeled.
    assert html =~ "claude-haiku-4.5"
    assert html =~ "5/485"
    assert html =~ "rate_limited · 429"

    # Expansion shows the outcome breakdown without a new query.
    expanded =
      view
      |> element("tr[phx-value-key='openrouter/claude-haiku-4.5/round']")
      |> render_click()

    assert expanded =~ "http 429"

    # Per-provider first-word series with legend.
    assert html =~ "First word p95, per provider"
    assert html =~ "openrouter"
    assert html =~ "openai"
  end

  defmodule EmptyActivityQueries do
    defdelegate run_outcomes(t, o), to: StubQueries
    defdelegate deploy_rates(k, t, o), to: StubQueries
    def activity_trace(_scope, _opts), do: {:ok, []}
  end

  defmodule CompactionActivityQueries do
    defdelegate run_outcomes(t, o), to: StubQueries
    defdelegate deploy_rates(k, t, o), to: StubQueries

    def activity_trace(_scope, _opts) do
      shared = %{
        "tenant_id" => "default",
        "group_id" => "g1",
        "salix_agent_id" => "ag-int",
        "session_id" => "compact-session",
        "status" => "ok",
        "model" => "gemini"
      }

      {:ok,
       Enum.map(
         [
           %{
             "event_kind" => "phase",
             "round_id" => "compact-round",
             "name" => "activation",
             "started_at" => "2026-09-04 10:00:00.000",
             "duration_ms" => 20_000
           },
           %{
             "event_kind" => "compaction",
             "round_id" => nil,
             "name" => "gemini",
             "started_at" => "2026-09-04 10:00:02.000",
             "duration_ms" => 16_000
           },
           %{
             "event_kind" => "llm",
             "round_id" => "compact-round",
             "name" => "gemini",
             "started_at" => "2026-09-04 10:00:20.000",
             "duration_ms" => 3_000
           }
         ],
         &Map.merge(shared, &1)
       )}
    end
  end

  defmodule MiniskillActivityQueries do
    defdelegate run_outcomes(t, o), to: StubQueries
    defdelegate deploy_rates(k, t, o), to: StubQueries

    def activity_trace(scope, opts) do
      {:ok, rows} = CompactionActivityQueries.activity_trace(scope, opts)

      row =
        rows
        |> hd()
        |> Map.merge(%{
          "name" => "miniskill",
          "duration_ms" => 600,
          "started_at" => "2026-09-04 10:00:00.100"
        })

      {:ok, [row | rows]}
    end
  end

  test "activity shows the miniskill duration and timing breakdown" do
    with_stubs(MiniskillActivityQueries)
    {:ok, view, _} = live(authed_conn(), "/dash/runtime/activity")
    html = render_async(view)
    assert has_element?(view, ~s([data-phase="miniskill"][title*="600ms"]))
    assert html =~ "Miniskill selection"
    assert html =~ "miniskill selection"
  end

  test "activity identifies compaction without presenting it as an external tool call" do
    with_stubs(CompactionActivityQueries)
    {:ok, view, _} = live(authed_conn(), "/dash/runtime/activity")
    html = render_async(view)
    assert has_element?(view, ~s([data-segment="compaction"][title*="Compaction model call"]))
    assert has_element?(view, ~s([data-segment="compaction"][aria-label*="Provider call only"]))
    refute has_element?(view, ~s([data-lane-kind="session"]))
    assert html =~ "1 round"
    assert html =~ "compaction model calls"
  end

  test "activity calls expose their complete details to keyboard and assistive users" do
    with_stubs(StubQueries)
    {:ok, view, _} = live(authed_conn(), "/dash/runtime/activity")

    assert has_element?(
             view,
             ~s(#activity-scroll[phx-hook="ActivityTooltip"][role="region"][aria-label="Activation timeline"][tabindex="0"])
           )

    assert has_element?(view, ~s([data-segment="tool"][tabindex="0"][aria-label*="web_fetch"]))
    assert has_element?(view, ~s(.act-lane[data-tracks]))
    assert has_element?(view, ~s([data-segment="llm"][data-track]))
    assert has_element?(view, ~s([data-segment="llm"][tabindex="0"][title*="Model call"]))
    assert has_element?(view, ~s([data-lane] a[href="/dash/agents/ag-int"]), "Router Bot")
  end

  test "empty activity keeps its explanation without a focusable empty chart" do
    with_stubs(EmptyActivityQueries)
    {:ok, view, _} = live(authed_conn(), "/dash/runtime/activity?range=3h")
    assert render(view) =~ "No model or tool calls recorded in this window."
    refute has_element?(view, ~s([role="region"][aria-label="Activation timeline"]))
  end

  test "activity tab lays rounds out as lanes with unknown stretches and links continuations" do
    with_stubs(StubQueries)
    Process.register(self(), :activity_trace_listener)

    # The plain-HTTP render paints the frame only; the feed is read once,
    # when the socket connects.
    dead = authed_conn() |> get("/dash/runtime/activity") |> html_response(200)
    assert dead =~ "Loading runtime telemetry"
    refute dead =~ "lane"
    refute_receive {:activity_trace_scope, _, _}

    {:ok, view, _} = live(authed_conn(), "/dash/runtime/activity")

    html = render(view)

    # Default scope is the current tenant.
    assert_receive {:activity_trace_scope, "default", opts}
    refute_receive {:activity_trace_scope, _, _}
    assert opts[:limit] == 4000
    refute html =~ "sess-other"

    # Two lanes: the tool round and its continuation are one activation,
    # laid end to end — llm, tool, between, llm, finishing — and the external
    # worker's session is a lane of its two tool calls.
    assert [_, _] = Regex.scan(~r/data-lane="/, html)
    assert html =~ ~s(data-lane="round-first-1")
    assert html =~ ~s(data-lane-kind="activation")
    assert html =~ "2 rounds"

    segments = Regex.scan(~r/data-segment="(\w+)"/, html) |> Enum.map(&Enum.at(&1, 1))

    assert Enum.sort(segments) ==
             ["between", "llm", "llm", "phase", "phase", "settle", "tool", "tool", "tool"]

    # The external session: striped, counted in tool calls, no rounds and no
    # ending; the role strip separates it from the Router's activation.
    assert html =~ ~s(data-lane="session:sess-ext")
    assert html =~ ~s(data-lane-kind="session")
    assert html =~ "2 tool calls"
    assert html =~ "external worker: tool calls only"
    assert html =~ "Striped lanes are external worker sessions: 1"
    assert html =~ ~s(data-roles="1")
    assert html =~ "External workers"
    assert html =~ "1 session"
    assert html =~ "2 tool calls across 1 agents"
    assert html =~ "1 activation"
    assert html =~ "2 rounds · 2 model calls · 1 tool calls · 1 agents"
    assert html =~ ~s(data-phase="boundary")
    assert html =~ ~s(data-phase="activation")
    assert html =~ "finished"

    # The recorded phases cover 100ms of the 200ms wait; the block text is
    # the duration only and the hover card names the phase.
    assert html =~ ~r/data-segment="between"[^>]*>\s*<span class="act-txt">100ms</
    assert html =~ "Between rounds · 100ms"
    assert html =~ "Closing the round · 40ms"
    assert html =~ "Activation · 60ms"
    assert html =~ "Tool call · web_fetch (builtin)"
    assert html =~ "Finishing, unrecorded · 200ms"

    # Agent name resolved through the registry; lanes link to the session
    # timeline; retries surface in the hover card.
    assert html =~ "Router Bot"
    assert html =~ "/dash/agents/ag-int/sessions/sess-act#timeline"
    assert html =~ "2 attempts"

    # Unknown share: 100ms scheduling wait + 200ms unrecorded finishing out
    # of the 1000ms activation; the 100ms of recorded phases are not unknown.
    assert html =~ "Unknown time"
    assert html =~ "30.0%"
    assert html =~ "10.0% between rounds + 0.0% inside rounds + 20.0% finishing unrecorded"
    assert html =~ "Longest unknown stretch"
    assert html =~ "finishing, in ses sess-act"

    # The breakdown bar and the legend name the recorded phases; the lane
    # was joined by the activation key.
    assert html =~ ~s(data-breakdown="1")
    assert html =~ "activation 6.0%"
    assert html =~ "storing replies and results 4.0%"
    assert html =~ "1 of 1 lanes here"
    assert html =~ "closing the round"
    assert html =~ "picking up a background result"
    assert html =~ "settling background results 0.0%"
    assert html =~ "the fetched sample has 5+ calls"

    # Switching to all tenants re-queries with :all and shows the other
    # tenant's failed model call, labelled.
    html =
      view
      |> element("#runtime-filters")
      |> render_change(%{"range" => "24h", "tenants" => "all"})

    assert_receive {:activity_trace_scope, :all, _opts}
    assert html =~ "tenants=all"
    assert html =~ "sess-other"
    assert html =~ "other-tenant"
    assert html =~ "FAILED: rate_limited"
    assert html =~ "1 failed"
  end

  test "activity lanes open collapsed onto one row, keeping every record" do
    with_stubs(StubQueries)
    {:ok, view, _} = live(authed_conn(), "/dash/runtime/activity")

    html = render(view)

    # Collapsed to begin with, and nothing is dropped: the phases and the
    # unknown stretches are drawn with the calls, every record on track 0,
    # each lane one track tall. The stylesheet stacks calls over phases.
    assert html =~ ~s(data-activity-detail="false")
    assert html =~ ~s(data-lane-detail="false")
    assert html =~ ~s(data-segment="phase")
    assert html =~ ~s(data-segment="llm")
    assert html =~ ~s(data-segment="tool")
    assert html =~ ~s(data-segment="between")
    assert html =~ ~s(data-tracks="1")
    refute html =~ ~s(data-track="1")

    # A block too narrow for its duration label carries no label span at
    # all: an empty one is still an 8px box of side padding.
    refute html =~ ~s(<span class="act-txt"></span>)

    # The lane's own icon button opts that lane out of the page default,
    # giving each record its own track again.
    html = view |> element(~s(button[phx-value-lane="round-first-1"])) |> render_click()
    assert html =~ ~s(data-lane-detail="true")
    assert html =~ ~r/data-track="[1-9][^>]*data-segment="phase"/

    # And the page-level button expands every lane, clearing that choice.
    html = view |> element(~s(button[phx-click="toggle_activity_detail"])) |> render_click()
    assert html =~ ~s(data-activity-detail="true")
    refute html =~ ~s(data-lane-detail="false")
    assert html =~ ~r/data-track="[1-9][^>]*data-segment="phase"/
  end

  test "activity tab pages older activations by cursor, and a filter change drops it" do
    with_stubs(StubQueries)
    Process.register(self(), :activity_trace_listener)

    # The newest page has everything: no pager. (`live/2` renders twice —
    # disconnected, then connected — so each page reports its scope twice.)
    {:ok, view, _} = live(authed_conn(), "/dash/runtime/activity")
    html = render(view)
    assert_receive {:activity_trace_scope, "default", opts}
    refute Keyword.has_key?(opts, :before)
    refute html =~ "data-pager"
    drain_traces()

    # A cursor in the URL becomes the query's `before`, at millisecond
    # precision, and the page says what it is showing.
    before = ~U[2026-09-04 15:33:20.000Z]
    before_ms = DateTime.to_unix(before, :millisecond)
    {:ok, view, _} = live(authed_conn(), "/dash/runtime/activity?before=#{before_ms}")
    html = render(view)
    assert_receive {:activity_trace_scope, "default", opts}
    assert opts[:before] == before
    assert opts[:limit] == 4000
    drain_traces()

    assert html =~ "40 activations that started before"
    # The server renders the UTC text; the BrowserLocalTime hook rewrites it
    # into the viewer's zone from the unix milliseconds on the element.
    assert html =~ ~s(data-local-time-ms="#{before_ms}")
    assert html =~ "2026-09-04 15:33:20 UTC"
    assert html =~ "data-pager"

    # One page deep: "Newer" is the newest page. There is no "Newest" link.
    assert html =~ "← Newer"
    assert html =~ ~s(href="/dash/runtime/activity")
    refute html =~ "Newest"

    # The feed filled its limit, so there is an older page; its cursor is the
    # start of the oldest lane shown (the 40th, 40s before this cursor).
    assert html =~ "the first one on the next page"
    assert html =~ "Older →"
    older = "/dash/runtime/activity?before=#{before_ms - 40_000}&amp;trail=#{before_ms}"
    assert html =~ ~s(href="#{older}")

    # Two pages deep: "Newer" steps back exactly one page (the trail's last
    # cursor); still no "Newest".
    {:ok, _view, deep} =
      live(
        authed_conn(),
        "/dash/runtime/activity?before=#{before_ms - 40_000}&trail=#{before_ms}"
      )

    drain_traces()
    refute deep =~ "Newest"
    assert deep =~ "← Newer"
    assert deep =~ ~s(href="/dash/runtime/activity?before=#{before_ms}")
    refute deep =~ ~s(href="/dash/runtime/activity?before=#{before_ms}&amp;trail=)

    assert deep =~
             ~s(href="/dash/runtime/activity?before=#{before_ms - 80_000}&amp;trail=#{before_ms}.#{before_ms - 40_000}")

    assert [_] = Regex.scan(~r/data-lane="round-old-40"/, html)
    refute html =~ ~s(data-lane="round-old-41")

    # Changing a filter is a fresh query: the cursor is gone.
    view
    |> element("#runtime-filters")
    |> render_change(%{"range" => "3h"})

    assert_patch(view, "/dash/runtime/activity?range=3h")
    assert_receive {:activity_trace_scope, "default", opts}
    refute Keyword.has_key?(opts, :before)
    drain_traces()

    # A malformed cursor means the newest page.
    {:ok, view, _} = live(authed_conn(), "/dash/runtime/activity?before=yesterday")
    html = render(view)
    assert_receive {:activity_trace_scope, "default", opts}
    refute Keyword.has_key?(opts, :before)
    refute html =~ "data-pager"
  end

  defp drain_traces do
    receive do
      {:activity_trace_scope, _, _} -> drain_traces()
    after
      0 -> :ok
    end
  end

  test "filters persist into the URL and across tab switches" do
    with_stubs(StubQueries)

    {:ok, view, _html} = live(authed_conn(), "/dash/runtime")

    view
    |> element("form#runtime-filters")
    |> render_change(%{"range" => "3h", "group" => "", "rev" => "revB"})

    assert_patch(view, "/dash/runtime?range=3h&rev=revB")

    # Tab links carry the current filters along.
    html = render(view)
    assert html =~ "/dash/runtime/tools?range=3h&amp;rev=revB"
  end

  test "a single active bucket still draws marks on both trend charts" do
    with_stubs(SingleBucketQueries)

    {:ok, view, _} = live(authed_conn(), "/dash/runtime")

    html = render(view)

    # One isolated rate dot + p50 and p95 dots on the duration chart.
    dots = html |> String.split("data-dot") |> length() |> Kernel.-(1)
    assert dots >= 3
    assert html =~ "p50 4.0s"
  end

  test "shows the not-configured empty state on every tab" do
    with_stubs(NotConfiguredQueries)

    for path <- [
          "/dash/runtime",
          "/dash/runtime/tools",
          "/dash/runtime/models",
          "/dash/runtime/activity"
        ] do
      {:ok, view, _} = live(authed_conn(), path)
      html = render(view)
      assert html =~ "ClickHouse not configured"
    end
  end
end
