defmodule SalixWeb.Dashboard.TrajectoryEvalLiveTest do
  @moduledoc "Trajectory eval trend page: summary strip, net-issue cards, fallbacks."
  use ExUnit.Case, async: false

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
    prev = Application.get_env(:salix_web, :trajectory_eval_queries_mod)
    Application.put_env(:salix_web, :trajectory_eval_queries_mod, mod)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:salix_web, :trajectory_eval_queries_mod, prev),
        else: Application.delete_env(:salix_web, :trajectory_eval_queries_mod)
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

  test "the line breaks across days nothing ran, and never dives to zero" do
    with_queries(GappedQueries)

    {:ok, view, html} = live(authed_conn(), "/dash/trajectory-evals")

    # Two adjacent days join into one segment; the isolated day cannot, so a
    # single polyline is drawn rather than one line bridging the hole.
    assert count(html, "<polyline") == 1
    assert html =~ "#{Days.ago(6)} · 1 of 4 checks · 25.0%"
    assert html =~ "#{Days.ago(2)} · 1 of 2 checks · 50.0%"
    assert html =~ "#{Days.ago(4)} · no checks ran"

    # Up to a month every point carries a dot.
    assert count(html, "data-dot") == 3

    # Past the density limit dots are dropped — except the isolated day, which
    # no line segment can express and would otherwise vanish from the chart.
    wide =
      view
      |> element("form[phx-change=filter]")
      |> render_change(%{"days" => "90", "group_id" => ""})

    assert count(wide, "<polyline") == 1
    assert count(wide, "data-dot") == 1
  end

  defp count(html, needle), do: html |> String.split(needle) |> length() |> Kernel.-(1)

  test "the issue-rate card switches between chart and table" do
    with_queries(StubQueries)

    {:ok, view, html} = live(authed_conn(), "/dash/trajectory-evals")

    # Chart is the default.
    assert html =~ "<polyline"
    refute html =~ "With issues"

    table = view |> element("button[phx-value-view=table]") |> render_click()

    # The table carries the exact per-day counts the chart only shows on hover.
    refute table =~ "<polyline"
    assert table =~ "With issues"
    assert table =~ Days.ago(2)
    assert table =~ ">10<"
    assert table =~ ">3<"
    assert table =~ "30.0"

    # Days nothing ran on stay out of the table, mirroring the chart's gaps.
    refute table =~ Days.ago(9)

    # The choice is view-only: it survives a range change without reloading.
    ranged =
      view
      |> element("form[phx-change=filter]")
      |> render_change(%{"days" => "30", "group_id" => ""})

    assert ranged =~ "Last 30 days"
    assert ranged =~ "With issues"

    back = view |> element("button[phx-value-view=chart]") |> render_click()
    assert back =~ "<polyline"
    refute back =~ "With issues"
  end

  test "renders string-typed ClickHouse counts without crashing" do
    with_queries(StringCountQueries)

    {:ok, _view, html} = live(authed_conn(), "/dash/trajectory-evals")

    assert html =~ "tool_loop"
    # 1/4 checks with issues → 25.0%; judge 1/2 → 50.0%; issues = 3−1 = 2.
    assert html =~ "25.0"
    assert html =~ "50.0"
    assert html =~ "3 found − 1 false alarms"
  end

  test "shows the not-configured empty state without crashing" do
    with_queries(NotConfiguredQueries)

    {:ok, _view, html} = live(authed_conn(), "/dash/trajectory-evals")

    assert html =~ "ClickHouse not configured"
    refute html =~ "Issue rate by day"
  end

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
           "session_id" => "sess-ext",
           "salix_agent_id" => "ag-ext",
           "last_activity_at" => "2026-07-10 10:00:00",
           "activity_events" => 3
         }
       ]}
    end
  end

  defmodule StubAgentControl do
    def get_record("ag-ext"), do: {:ok, %{"runtime_config" => %{"kind" => "external"}}}
    def get_record(_id), do: {:ok, %{"runtime_config" => %{"kind" => "internal"}}}

    defdelegate runtime_kind(agent), to: SalixAgent.Control
  end

  defp with_telemetry(mod) do
    prev_q = Application.get_env(:salix_web, :agent_telemetry_queries_mod)
    prev_a = Application.get_env(:salix_web, :agent_control_mod)
    Application.put_env(:salix_web, :agent_telemetry_queries_mod, mod)
    Application.put_env(:salix_web, :agent_control_mod, StubAgentControl)

    on_exit(fn ->
      restore_env(:agent_telemetry_queries_mod, prev_q)
      restore_env(:agent_control_mod, prev_a)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:salix_web, key)
  defp restore_env(key, value), do: Application.put_env(:salix_web, key, value)

  test "lists internal never-checked sessions and reframes the checks tile" do
    with_queries(StubQueries)
    with_telemetry(TelemetryStub)

    {:ok, _view, html} = live(authed_conn(), "/dash/trajectory-evals")

    assert html =~ "Sessions never checked"
    assert html =~ "cannot include them"

    # Internal sessions only — the external one is dropped, not mislabeled.
    assert html =~ "sess-quiet"
    refute html =~ "sess-ext"
    assert html =~ "/dash/agents/ag-int/sessions/sess-quiet#timeline"
    assert html =~ "see all in Runtime Health →"

    # The Checks-run tile now names its own blind spot.
    assert html =~ "covers finished rounds only"
  end

  defmodule TelemetryNotConfigured do
    def unconverged_sessions(_tenant, _opts), do: {:error, :not_configured}
  end

  test "hides the never-checked card when telemetry tables are unreadable" do
    with_queries(StubQueries)
    with_telemetry(TelemetryNotConfigured)

    {:ok, _view, html} = live(authed_conn(), "/dash/trajectory-evals")

    refute html =~ "Sessions never checked"
    assert html =~ "one per settled round"
  end

  test "the per-tenant judge toggle writes the tenant setting and persists" do
    with_queries(StubQueries)
    # A fresh tenant so the switch starts at the deployment default and this
    # test's write does not leak into others sharing the fake store.
    tenant = "judge-toggle-#{System.unique_integer([:positive])}"

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
    prev = Application.get_env(:salix_agent, :trajectory_eval_judge_providers)
    Application.put_env(:salix_agent, :trajectory_eval_judge_providers, map)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:salix_agent, :trajectory_eval_judge_providers, prev),
        else: Application.delete_env(:salix_agent, :trajectory_eval_judge_providers)
    end)
  end

  test "the judge-model dropdown is hidden when no models are wired" do
    with_queries(StubQueries)
    with_judge_providers(%{})

    {:ok, _view, html} = live(authed_conn(), "/dash/trajectory-evals")

    refute html =~ "Judge model"
  end

  test "the judge-model dropdown offers the allowlist and saves the pick per tenant" do
    with_queries(StubQueries)

    with_judge_providers(%{
      "haiku" => %{label: "Claude Haiku", protocol: "anthropic", model: "h", api_key: "k"},
      "luna" => %{label: "GPT-5.6 Luna", protocol: "chat_completions", model: "l", api_key: "k"}
    })

    tenant = "judge-model-#{System.unique_integer([:positive])}"

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant})

    {:ok, view, html} = live(conn, "/dash/trajectory-evals")
    assert html =~ "Judge model"
    assert html =~ "GPT-5.6 Luna"
    assert html =~ "Deployment default"
    # The key boundary is stated on screen, not only in a hover tooltip — and
    # at AA-readable contrast for text-xs (neutral-400 on white is ~2.5:1).
    assert html =~ "API keys never pass through this page"
    assert html =~ ~s(class="mt-2 text-xs text-neutral-500")
    refute html =~ ~s(class="mt-2 text-xs text-neutral-400")

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

  # A judge_provider that isn't even a name (a JSON object landed in the field)
  # is a broken selection like any other: revoked banner, no 500, no "default"
  # claim — the value itself is described, never rendered raw.
  test "a malformed stored judge_provider renders the revoked state without crashing" do
    with_queries(StubQueries)

    with_judge_providers(%{
      "haiku" => %{label: "Claude Haiku", protocol: "anthropic", model: "h", api_key: "k"}
    })

    tenant = "judge-model-malformed-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Salix.Control.Tenants.update_config(tenant, "trajectory_eval", %{"judge_provider" => %{}})

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant})

    {:ok, _view, html} = live(conn, "/dash/trajectory-evals")
    assert html =~ "(an invalid value) is no longer available"
    assert html =~ "Reset to deployment default"
    refute html =~ "Set for this tenant."
  end

  # The Runner skips the paid judge for a revoked pick, so the page must not
  # claim "Deployment default" — it shows the revoked banner, the stale key,
  # and the ways out (reset, or pick a replacement).
  test "a revoked stored judge_provider shows the paused state and resets" do
    with_queries(StubQueries)

    with_judge_providers(%{
      "haiku" => %{label: "Claude Haiku", protocol: "anthropic", model: "h", api_key: "k"}
    })

    tenant = "judge-model-stale-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Salix.Control.Tenants.update_config(tenant, "trajectory_eval", %{"judge_provider" => "gone"})

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant})

    {:ok, view, html} = live(conn, "/dash/trajectory-evals")
    assert html =~ "(gone) is no longer available"
    assert html =~ "judge is paused for this tenant"
    assert html =~ "Reset to deployment default"
    assert html =~ "Pick a replacement…"
    refute html =~ "Using the deployment default."

    # Reset clears the stored key: the runtime seam agrees, and the page
    # returns to the normal default state.
    html = view |> element("button", "Reset to deployment default") |> render_click()
    assert html =~ "Using the deployment default."
    refute html =~ "is no longer available"

    assert {:ok, override} = Salix.Control.Tenants.get_config(tenant, "trajectory_eval", %{})
    refute Map.has_key?(override, "judge_provider")
  end

  defp with_global_judge_provider(key) do
    prev = Application.get_env(:salix_agent, :trajectory_eval)

    Application.put_env(
      :salix_agent,
      :trajectory_eval,
      Keyword.put(prev || [], :judge_provider, key)
    )

    on_exit(fn ->
      if prev,
        do: Application.put_env(:salix_agent, :trajectory_eval, prev),
        else: Application.delete_env(:salix_agent, :trajectory_eval)
    end)
  end

  # Paired with the Runner: a persisted "" is the dashboard's own spelling of
  # "use the deployment default" — it must render as the default state (the
  # runtime inherits the valid global), never as a revoked/paused pick.
  test "a persisted empty judge_provider renders as the default, not revoked" do
    with_queries(StubQueries)

    with_judge_providers(%{
      "haiku" => %{label: "Claude Haiku", protocol: "anthropic", model: "h", api_key: "k"}
    })

    with_global_judge_provider("haiku")

    tenant = "judge-model-empty-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Salix.Control.Tenants.update_config(tenant, "trajectory_eval", %{"judge_provider" => ""})

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant})

    {:ok, _view, html} = live(conn, "/dash/trajectory-evals")
    assert html =~ "Using the deployment default."
    refute html =~ "is no longer available"
    refute html =~ "Reset to deployment default"
  end

  # Paired with the Runner: an explicit global default that no longer resolves
  # means the runtime is SKIPPING the judge for tenants with no pick of their
  # own — the page must say so, not render a healthy default. Reset is not
  # offered (there is no tenant key to clear; the fix is ops config), but a
  # tenant pick can still shadow the broken default when models exist.
  test "an invalid global judge_provider renders the paused state, without reset" do
    with_queries(StubQueries)

    with_judge_providers(%{
      "haiku" => %{label: "Claude Haiku", protocol: "anthropic", model: "h", api_key: "k"}
    })

    with_global_judge_provider("gone")

    tenant = "judge-model-global-#{System.unique_integer([:positive])}"

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant})

    {:ok, view, html} = live(conn, "/dash/trajectory-evals")
    assert html =~ "deployment default judge model (gone)"
    assert html =~ "judge is paused for this tenant"
    assert html =~ "ops config change"
    refute html =~ "Using the deployment default."
    # No tenant key exists, so reset would be a lie — only a replacement pick.
    refute html =~ "Reset to deployment default"
    assert html =~ "Pick a replacement…"

    # A tenant pick shadows the broken global and returns the page to normal.
    html =
      view
      |> element("form[phx-change=select_judge_provider]")
      |> render_change(%{"judge_provider" => "haiku"})

    assert html =~
             ~r/<option[^>]*value="haiku"[^>]*selected|<option[^>]*selected[^>]*value="haiku"/

    refute html =~ "judge is paused for this tenant"
  end

  # The orphaning case: ops removed the LAST provider. The picker itself has
  # nothing to offer, but the stale override must stay visible and clearable —
  # hiding the whole block would strand the tenant in the skip state forever.
  test "a revoked judge_provider stays visible and resettable with an empty allowlist" do
    with_queries(StubQueries)
    with_judge_providers(%{})

    tenant = "judge-model-orphan-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Salix.Control.Tenants.update_config(tenant, "trajectory_eval", %{
        "judge_provider" => "eu-only"
      })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant})

    {:ok, view, html} = live(conn, "/dash/trajectory-evals")
    assert html =~ "(eu-only) is no longer available"
    assert html =~ "Reset to deployment default"
    # No models to offer, so no replacement picker — reset is the way out.
    refute html =~ "Pick a replacement…"

    view |> element("button", "Reset to deployment default") |> render_click()

    assert {:ok, override} = Salix.Control.Tenants.get_config(tenant, "trajectory_eval", %{})
    refute Map.has_key?(override, "judge_provider")
  end

  test "a malformed stored judge_enabled renders as the deployment default, not on" do
    with_queries(StubQueries)
    tenant = "judge-malformed-#{System.unique_integer([:positive])}"
    # A non-boolean value (e.g. a stringified write) must not read as a tenant
    # override — the runner ignores it too, so the UI must agree it's the default.
    {:ok, _} =
      Salix.Control.Tenants.update_config(tenant, "trajectory_eval", %{"judge_enabled" => "true"})

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant})

    {:ok, _view, html} = live(conn, "/dash/trajectory-evals")
    assert html =~ ~s(aria-checked="false")
    assert html =~ "Using the deployment default"
    refute html =~ "Set for this tenant"
  end
end
