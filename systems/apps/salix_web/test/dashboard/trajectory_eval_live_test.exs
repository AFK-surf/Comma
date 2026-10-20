defmodule SalixWeb.Dashboard.TrajectoryEvalLiveTest do
  @moduledoc "Trajectory eval trend page: summary strip, net-issue cards, fallbacks."
  use SystemsClock.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SalixWeb.DashboardEndpoint

  # The chart's x-axis is the selected range, anchored on today, so stub rows
  # must be dated relative to today — hardcoded dates would silently fall out
  # of the window and stop reaching the chart as the calendar moves.
  defmodule Days do
    @moduledoc false
    def ago(n), do: Date.utc_today() |> Date.add(-n) |> Date.to_iso8601()
  end

  defmodule StubQueries do
    import Days, only: [ago: 1]

    def flag_rate_trend(_tenant, _opts) do
      {:ok,
       [
         %{"event_date" => ago(2), "group_id" => "g1", "checks" => 6, "with_issues" => 2},
         %{"event_date" => ago(2), "group_id" => "g2", "checks" => 4, "with_issues" => 1},
         %{"event_date" => ago(1), "group_id" => "g1", "checks" => 5, "with_issues" => 0}
       ]}
    end

    def metric_breakdown(_tenant, _opts) do
      {:ok,
       [
         %{
           "metric" => "tool_loop",
           "event_date" => ago(2),
           "found" => 2,
           "confirmed" => 1,
           "dismissed" => 0,
           "reviewed" => 1
         },
         %{
           "metric" => "tool_loop",
           "event_date" => ago(1),
           "found" => 1,
           "confirmed" => 0,
           "dismissed" => 0,
           "reviewed" => 0
         },
         %{
           "metric" => "confusion",
           "event_date" => ago(2),
           "found" => 1,
           "confirmed" => 0,
           "dismissed" => 1,
           "reviewed" => 1
         }
       ]}
    end

    def judge_confirm_rate(_tenant, _opts) do
      {:ok,
       [
         %{"metric" => "tool_loop", "evaluator_version" => "1", "confirmed" => 3, "total" => 4}
       ]}
    end

    def top_flagged_sessions(_tenant, _opts) do
      {:ok,
       [
         %{
           "salix_agent_id" => "agent-abc",
           "session_id" => "sess-xyz",
           "issues" => 4,
           "dismissed" => 1,
           "last_date" => ago(1)
         }
       ]}
    end
  end

  # A run of two days, a two-day hole, then a single isolated day. Exercises
  # the line breaking across gaps and the lone point that no segment can draw.
  defmodule GappedQueries do
    import Days, only: [ago: 1]

    def flag_rate_trend(_tenant, _opts) do
      {:ok,
       [
         %{"event_date" => ago(6), "group_id" => "g1", "checks" => 4, "with_issues" => 1},
         %{"event_date" => ago(5), "group_id" => "g1", "checks" => 4, "with_issues" => 2},
         %{"event_date" => ago(2), "group_id" => "g1", "checks" => 2, "with_issues" => 1}
       ]}
    end

    def metric_breakdown(_tenant, _opts), do: {:ok, []}
    def judge_confirm_rate(_tenant, _opts), do: {:ok, []}
    def top_flagged_sessions(_tenant, _opts), do: {:ok, []}
  end

  defmodule NotConfiguredQueries do
    def flag_rate_trend(_tenant, _opts), do: {:error, :not_configured}
    def metric_breakdown(_tenant, _opts), do: {:error, :not_configured}
    def judge_confirm_rate(_tenant, _opts), do: {:error, :not_configured}
    def top_flagged_sessions(_tenant, _opts), do: {:error, :not_configured}
  end

  # ClickHouse can serialize UInt64 counts as JSON strings; the page must not
  # crash doing arithmetic on them (regression: e2e string-count bug).
  defmodule StringCountQueries do
    import Days, only: [ago: 1]

    def flag_rate_trend(_tenant, _opts),
      do:
        {:ok,
         [%{"event_date" => ago(1), "group_id" => "g1", "checks" => "4", "with_issues" => "1"}]}

    def metric_breakdown(_tenant, _opts),
      do:
        {:ok,
         [
           %{
             "metric" => "tool_loop",
             "event_date" => ago(1),
             "found" => "3",
             "confirmed" => "1",
             "dismissed" => "1",
             "reviewed" => "2"
           }
         ]}

    def judge_confirm_rate(_tenant, _opts),
      do:
        {:ok,
         [
           %{
             "metric" => "tool_loop",
             "evaluator_version" => "1",
             "confirmed" => "1",
             "total" => "2"
           }
         ]}

    def top_flagged_sessions(_tenant, _opts),
      do:
        {:ok,
         [
           %{
             "salix_agent_id" => "a",
             "session_id" => "s",
             "issues" => "3",
             "dismissed" => "0",
             "last_date" => ago(1)
           }
         ]}
  end

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => "default"})

  defp with_queries(mod) do
    prev = SystemsRuntime.get_env(:salix_web, :trajectory_eval_queries_mod)
    SystemsRuntime.put_env(:salix_web, :trajectory_eval_queries_mod, mod)

    on_exit(fn ->
      if prev,
        do: SystemsRuntime.put_env(:salix_web, :trajectory_eval_queries_mod, prev),
        else: SystemsRuntime.delete_env(:salix_web, :trajectory_eval_queries_mod)
    end)
  end

  test "renders the summary strip and all four cards from query rows" do
    with_queries(StubQueries)

    {:ok, _view, html} = live(authed_conn(), "/dash/trajectory-evals")

    # Summary strip: checks 6+4+5, issues = 4 found − 1 dismissed = 3,
    # judge reviewed 2 of 4. The strip states the identity the cards share.
    assert html =~ "Checks run"
    assert html =~ ">15<"
    assert html =~ "4 found − 1 false alarms"
    assert html =~ "2 of 4"

    # Issue rate chart: per-group rows summed per date (6+4 checks, 2+1 with
    # issues → 30.0%), exact counts carried in the per-day hover tooltip.
    assert html =~ "Issue rate by day"
    assert html =~ "#{Days.ago(2)} · 3 of 10 checks · 30.0%"
    assert html =~ "#{Days.ago(1)} · 0 of 5 checks · 0.0%"
    assert html =~ "<polyline"

    # Days outside the two with rows are gaps, not zeros.
    assert html =~ "#{Days.ago(9)} · no checks ran"

    # Axis rounds up past the 30.0% peak to the next familiar step, anchored at 0.
    assert html =~ ">0%<"
    assert html =~ ">50%<"

    # Issues by type: net counts, dismissed shown muted, hover help present.
    assert html =~ "Issues by type"
    assert html =~ "tool_loop"
    assert html =~ "confusion"
    assert html =~ "+1 false alarm"
    assert html =~ "without making progress"

    # Judge confirm rate with judge-version badge and coverage line.
    assert html =~ "Judge confirm rate"
    assert html =~ "v1"
    assert html =~ "3/4"
    assert html =~ "75.0"

    # Top sessions link into the existing session show page.
    assert html =~ "Sessions with most issues"
    assert html =~ "/dash/agents/agent-abc/sessions/sess-xyz"
  end

  defp count(html, needle), do: html |> String.split(needle) |> length() |> Kernel.-(1)

  # ==================== "Sessions never checked" card ====================

  defmodule TelemetryStub do
    def unconverged_sessions(_tenant, _opts) do
      {:ok,
       [
         %{
           "session_id" => "sess-quiet",
           "salix_agent_id" => "ag-int",
           "last_activity_at" => "2026-07-10 10:00:00",
           "activity_events" => 7
         },
         %{
           "session_id" => "sess-gone",
           "salix_agent_id" => "ag-gone",
           "last_activity_at" => "2026-07-10 10:00:00",
           "activity_events" => 3
         }
       ]}
    end
  end

  defmodule StubAgentControl do
    def get_record("ag-gone"), do: {:error, :not_found}
    def get_record(_id), do: {:ok, %{"runtime_config" => %{"kind" => "internal"}}}
  end
  defmodule TelemetryNotConfigured do
    def unconverged_sessions(_tenant, _opts), do: {:error, :not_configured}
  end

  test "the per-tenant judge toggle writes the tenant setting and persists" do
    with_queries(StubQueries)
    # A fresh tenant so the switch starts at the deployment default and this
    # test's write does not leak into others sharing the fake store.
    tenant = "judge-toggle-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant})

    {:ok, view, html} = live(conn, "/dash/trajectory-evals")
    assert html =~ "LLM judge"
    assert html =~ "Using the deployment default"
    assert html =~ ~s(aria-checked="false")

    html = view |> element("button[phx-click=toggle_judge]") |> render_click()
    assert html =~ "Set for this tenant"
    assert html =~ ~s(aria-checked="true")

    # Persisted in the control-plane store: a fresh mount reflects the override.
    {:ok, _view2, html2} = live(conn, "/dash/trajectory-evals")
    assert html2 =~ "Set for this tenant"
    assert html2 =~ ~s(aria-checked="true")

    # And the runtime seam reads the same value back for this tenant.
    assert Salix.Bindings.AgentTrajectoryEvalSettings.get(tenant) ==
             {:ok, %{"judge_enabled" => true}}
  end

  defp with_judge_providers(map) do
    prev = SystemsRuntime.get_env(:salix_agent, :trajectory_eval_judge_providers)
    SystemsRuntime.put_env(:salix_agent, :trajectory_eval_judge_providers, map)

    on_exit(fn ->
      if prev,
        do: SystemsRuntime.put_env(:salix_agent, :trajectory_eval_judge_providers, prev),
        else: SystemsRuntime.delete_env(:salix_agent, :trajectory_eval_judge_providers)
    end)
  end

  test "the judge-model dropdown offers the allowlist and saves the pick per tenant" do
    with_queries(StubQueries)

    with_judge_providers(%{
      "haiku" => %{label: "Claude Haiku", protocol: "anthropic", model: "h", api_key: "k"},
      "luna" => %{label: "GPT-5.6 Luna", protocol: "chat_completions", model: "l", api_key: "k"}
    })

    tenant = "judge-model-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant})

    {:ok, view, html} = live(conn, "/dash/trajectory-evals")
    assert html =~ "Judge model"
    assert html =~ "GPT-5.6 Luna"
    assert html =~ "Deployment default"
    # The key boundary is stated on screen, not only in a hover tooltip.
    assert html =~ "API keys never pass through this page"

    html =
      view
      |> element("form[phx-change=select_judge_provider]")
      |> render_change(%{"judge_provider" => "luna"})

    # The dropdown now reflects the pick (selected option).
    assert html =~ ~r/<option[^>]*value="luna"[^>]*selected|<option[^>]*selected[^>]*value="luna"/

    # Persisted in the control plane and readable by the runtime seam.
    assert {:ok, %{"judge_provider" => "luna"}} =
             Salix.Control.Tenants.get_config(tenant, "trajectory_eval", %{})

    # Choosing "Deployment default" (empty) clears the per-tenant key.
    view
    |> element("form[phx-change=select_judge_provider]")
    |> render_change(%{"judge_provider" => ""})

    assert {:ok, override} = Salix.Control.Tenants.get_config(tenant, "trajectory_eval", %{})
    refute Map.has_key?(override, "judge_provider")
  end
end
