defmodule BridgeForTeamsWeb.Dashboard.OperationsLiveTest do
  @moduledoc """
  LiveView tests for the organization Operations page.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  import Ecto.Query, only: [from: 2]

  alias BridgeForTeams.{Environments, Memberships, Observability, Orgs, Projects, RunChecks}
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.{AuditLog, CheckResult, ObservabilityEvent, OperationRun}

  setup %{conn: conn} do
    %{conn: conn, org: org, user: user} = register_and_log_in_user(%{conn: conn})
    %{conn: conn, org: org, user: user}
  end

  test "renders the Operations overview from the sidebar entry", %{conn: conn, org: org} do
    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/operations")

    assert html =~ "Operations"
    assert html =~ "BFT-wide delivery status, events, checks, runners, and audit for #{org.name}."
    assert html =~ ~s(id="operations-overview")
    assert html =~ ~s(id="operations-loading")
    assert html =~ "Refreshing Operations data"
    assert html =~ "unknown"
    assert html =~ "Why this status?"
    assert html =~ ~s(id="operations-health-reasons")
    assert html =~ "No persisted Operations facts have been observed yet."
    assert html =~ "Operations summarizes the latest persisted BFT signals"
    assert html =~ "Events"
    assert html =~ "Checks"
    assert html =~ "Audit"
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/delivery")
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/events")
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/checks")
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/audit")
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/runners")
  end

  test "ordinary org members cannot open Operations", %{conn: conn, org: org} do
    member = user_fixture(email: "operations-member@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

    assert {:error, {:redirect, %{to: "/orgs"}}} =
             conn
             |> log_in_user(member)
             |> live(~p"/orgs/#{org.slug}/operations")
  end

  test "org admins can open Operations", %{conn: conn, org: org} do
    admin = user_fixture(email: "operations-admin@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, admin.id, "admin")

    {:ok, _view, html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/orgs/#{org.slug}/operations")

    assert html =~ "Operations"
    assert html =~ "BFT-wide delivery status"
  end

  test "renders an actionable error state when Operations facts cannot load", %{
    conn: conn,
    org: org
  } do
    previous = Application.get_env(:bridge_for_teams_web, :operations_observability_load_failure)
    Application.put_env(:bridge_for_teams_web, :operations_observability_load_failure, true)

    on_exit(fn ->
      restore_env(:operations_observability_load_failure, previous)
    end)

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/operations")

    assert html =~ ~s(id="operations-load-error")
    assert html =~ "Operations data could not be loaded"
    assert html =~ "showing the last safe snapshot or unknown state"
    assert html =~ "Retry loading Operations"
    assert html =~ ~s(href="/orgs/#{org.slug}/operations")
    assert html =~ "unknown"
  end

  test "overview renders signal freshness rows with owning tab links", %{conn: conn, org: org} do
    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Fresh Ops", "slug" => "fresh-ops"})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, _runner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "fresh-runner",
               "name" => "Fresh Runner",
               "status" => "online",
               "last_seen_at" => now
             })

    assert {:ok, _check} =
             Observability.create_check_result(%{
               org_id: org.id,
               project_id: project.id,
               check_family: "run_checks",
               surface: "bot",
               subject_type: "project",
               subject_id: project.id,
               status: "ok",
               result: %{gates: [%{gate_id: "bot.ready", label: "Bot ready", status: "ok"}]},
               invocation_id: "fresh-check",
               ran_at: DateTime.add(now, 1, :second)
             })

    assert {:ok, _integration_event} =
             Observability.create_event(%{
               org_id: org.id,
               project_id: project.id,
               domain: "integration",
               resource_type: "feishu_connect",
               source: "salix.im",
               event_type: "feishu.callback.delivered",
               severity: "info",
               summary: "Feishu callback delivered",
               occurred_at: DateTime.add(now, 2, :second)
             })

    assert {:ok, _environment_event} =
             Observability.create_event(%{
               org_id: org.id,
               project_id: project.id,
               environment_id: Ecto.UUID.generate(),
               domain: "device",
               resource_type: "salix_device_connector",
               source: "salix.env",
               event_type: "device.runtime.observed",
               severity: "info",
               summary: "Device runtime observed",
               occurred_at: DateTime.add(now, 3, :second)
             })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/operations")

    assert html =~ ~s(id="operations-freshness")
    assert html =~ "Signal freshness"
    assert html =~ "Latest diagnostic: Feishu callback delivered"
    assert html =~ "Latest check: Bot ready - ok"
    assert html =~ "Fresh Runner heartbeat"
    assert html =~ "Latest device event: Device runtime observed"
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/integrations")
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/checks")
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/runners")
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/events?domain=device")
  end

  test "empty states distinguish uninstalled sources quiet surfaces and filtered misses", %{
    conn: conn,
    org: org
  } do
    {:ok, _view, events_html} = live(conn, ~p"/orgs/#{org.slug}/operations/events")

    assert events_html =~ "No event producers connected yet"
    assert events_html =~ "Create an Agent Swarm or onboard a runner"

    {:ok, _view, filtered_events_html} =
      live(conn, ~p"/orgs/#{org.slug}/operations/events?domain=runner")

    assert filtered_events_html =~ "No events match these filters"
    assert filtered_events_html =~ "Clear the event filters"

    {:ok, _view, checks_html} = live(conn, ~p"/orgs/#{org.slug}/operations/checks")

    assert checks_html =~ "No check targets configured yet"
    assert checks_html =~ "Create an Agent Swarm or configure an integration"

    {:ok, _view, filtered_checks_html} =
      live(conn, ~p"/orgs/#{org.slug}/operations/checks?surface=bot")

    assert filtered_checks_html =~ "No check results match these filters"
    assert filtered_checks_html =~ "Clear the check filters"

    {:ok, _view, audit_html} = live(conn, ~p"/orgs/#{org.slug}/operations/audit")

    assert audit_html =~ "No audit actions recorded yet"
    assert audit_html =~ "Audit is installed"

    {:ok, _view, filtered_audit_html} =
      live(conn, ~p"/orgs/#{org.slug}/operations/audit?action=settings.sso.updated")

    assert filtered_audit_html =~ "No audit actions match these filters"
    assert filtered_audit_html =~ "Clear the audit filters"
  end

  test "renders persisted observability events, checks, and audit records", %{
    conn: conn,
    org: org,
    user: user
  } do
    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Ops Swarm", "slug" => "ops-swarm"})

    {:ok, other_org} = Orgs.create_org(%{"name" => "Other Ops", "slug" => "other-ops"})

    assert {:ok, _event} =
             Observability.create_event(%{
               org_id: org.id,
               project_id: project.id,
               domain: "integration",
               resource_type: "feishu_connect",
               resource_id: "connect_1",
               source: "bft.run_checks",
               event_type: "run_checks.completed",
               severity: "warning",
               status: "needs_manual",
               reason_class: "scope_batch_required",
               summary: "Feishu bot scopes need import",
               evidence: %{app_secret: "super-secret"}
             })

    assert {:ok, _filtered_out_event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "runner",
               resource_type: "mac_mini_provisioner",
               source: "mac_mini.provisioner",
               event_type: "runner.heartbeat",
               severity: "info",
               summary: "Background sync ok"
             })

    assert {:ok, _other_event} =
             Observability.create_event(%{
               org_id: other_org.id,
               domain: "runner",
               resource_type: "mac_mini_provisioner",
               source: "mac_mini.provisioner",
               event_type: "runner.heartbeat",
               severity: "info",
               summary: "Other org runner heartbeat"
             })

    assert {:ok, run} =
             Observability.create_operation_run(%{
               org_id: org.id,
               project_id: project.id,
               run_type: "fin_exec",
               external_run_id: "run_ops_1",
               request_id: "req_run_ops_1",
               status: "failed",
               reason_class: "command_failed",
               duration_ms: 2345,
               evidence: %{command_hash: "sha256:ops", raw_command: "cat /secret"}
             })

    assert {:ok, check} =
             Observability.record_run_checks(
               %{
                 surface: "bot",
                 org_ref: org.id,
                 project_ref: project.id,
                 ran_at: DateTime.utc_now(),
                 gates: [
                   %{
                     gate_id: "bot.scope_batch",
                     label: "Feishu scope batch import",
                     status: :needs_manual,
                     reason_class: :scope_batch_required,
                     next_action: "Import the scope batch JSON",
                     evidence: %{app_secret: "super-secret"}
                   }
                 ]
               },
               ran_by_user_id: user.id,
               invocation_id: "run-checks-ops-1"
             )

    assert {:ok, _linked_event} =
             Observability.create_event(%{
               org_id: org.id,
               project_id: project.id,
               run_record_id: run.id,
               check_result_id: check.id,
               domain: "check",
               resource_type: "run_checks",
               resource_id: check.id,
               source: "bft.dashboard",
               event_type: "run_checks.completed",
               severity: "error",
               status: "fail",
               reason_class: "linked_failure",
               summary: "Linked run and check failure",
               evidence: %{
                 exit_code: 1,
                 request_id: "req_linked_ops_1",
                 raw_command: "cat /secret"
               },
               correlation_id: "req_linked_ops_1"
             })

    assert {:ok, audit} =
             Observability.record_audit(%{
               org_id: org.id,
               actor_user_id: user.id,
               action: "settings.sso.updated",
               resource_type: "sso",
               resource_id: org.id,
               resource_label: "SSO",
               result: "ok",
               request_id: "req_ops_1",
               metadata: %{provider: "feishu", api_key: "super-secret"}
             })

    {:ok, _view, overview_html} = live(conn, ~p"/orgs/#{org.slug}/operations")

    assert overview_html =~ "Recent persisted check snapshots"
    assert overview_html =~ "Recent privileged action records"
    assert overview_html =~ "Recent bounded execution runs failed or were canceled."
    assert overview_html =~ "Recent checks need manual follow-up or were skipped."
    assert overview_html =~ "Feishu bot scopes need import"
    assert overview_html =~ "run_ops_1"
    assert overview_html =~ "command failed"
    assert overview_html =~ ~s(id="operations-overview-checks")
    assert overview_html =~ "Feishu scope batch import - needs manual"
    assert overview_html =~ "View all checks"
    assert overview_html =~ ~s(id="operations-overview-audit")
    assert overview_html =~ "settings.sso.updated"
    assert overview_html =~ "View audit"
    refute overview_html =~ "super-secret"
    refute overview_html =~ "cat /secret"
    refute overview_html =~ "Other org runner heartbeat"

    {:ok, events_view, events_html} = live(conn, ~p"/orgs/#{org.slug}/operations/events")

    assert events_html =~ ~s(id="operations-events")
    assert events_html =~ ~s(id="operations-events-filters")
    assert events_html =~ "run_checks.completed"
    assert events_html =~ "Feishu bot scopes need import"
    assert events_html =~ "audit.settings.sso.updated"
    assert events_html =~ "Audit settings.sso.updated ok for SSO"
    assert events_html =~ "scope batch required"
    assert events_html =~ "Linked run and check failure"
    assert events_html =~ "Evidence"
    assert events_html =~ "exit_code=1"
    assert events_html =~ "request_id=req_linked_ops_1"
    assert events_html =~ "metadata_present=true"

    assert events_html =~
             ~s(href="/orgs/#{org.slug}/operations/runners?run_record_id=#{run.id}")

    assert events_html =~
             ~s(href="/orgs/#{org.slug}/operations/checks?check_result_id=#{check.id}")

    assert events_html =~ ~s(href="/orgs/#{org.slug}/operations/audit?audit_log_id=#{audit.id}")
    refute events_html =~ "super-secret"
    refute events_html =~ "cat /secret"
    refute events_html =~ "Other org runner heartbeat"

    form_filtered_html =
      events_view
      |> form("#operations-events-filters", %{
        "filters" => %{"severity" => "warning", "project_id" => project.id}
      })
      |> render_submit()

    assert form_filtered_html =~ "Feishu bot scopes need import"
    refute form_filtered_html =~ "Background sync ok"

    {:ok, _view, checks_html} = live(conn, ~p"/orgs/#{org.slug}/operations/checks")

    assert checks_html =~ ~s(id="operations-checks")
    assert checks_html =~ ~s(id="operations-checks-filters")
    assert checks_html =~ "Ops Swarm"
    assert checks_html =~ "Feishu scope batch import - needs manual"
    assert checks_html =~ "run-checks-ops-1"
    assert checks_html =~ "check_family=run_checks"
    assert checks_html =~ "gate_count=1"
    assert checks_html =~ "surface=bot"
    refute checks_html =~ "super-secret"

    {:ok, _view, audit_html} = live(conn, ~p"/orgs/#{org.slug}/operations/audit")

    assert audit_html =~ ~s(id="operations-audit")
    assert audit_html =~ ~s(id="operations-audit-filters")
    assert audit_html =~ "settings.sso.updated"
    assert audit_html =~ "SSO"
    assert audit_html =~ "req_ops_1"
    assert audit_html =~ "metadata_present=true"
    assert audit_html =~ "redacted_diff_present=false"
    refute audit_html =~ "super-secret"

    {:ok, _view, runs_html} = live(conn, ~p"/orgs/#{org.slug}/operations/runners")

    assert runs_html =~ ~s(id="operations-runs-table")
    assert runs_html =~ "run_ops_1"
    assert runs_html =~ "Ops Swarm"
    assert runs_html =~ "command_hash=sha256:ops"
    assert runs_html =~ "duration_ms=2345"
    assert runs_html =~ "request_id=req_run_ops_1"
    refute runs_html =~ "cat /secret"

    {:ok, _view, filtered_html} =
      live(conn, "/orgs/#{org.slug}/operations/events?severity=warning&project_id=#{project.id}")

    assert filtered_html =~ ~s(id="operations-active-filters")
    assert filtered_html =~ "project=Ops Swarm"
    assert filtered_html =~ "severity=warning"
    assert filtered_html =~ "Feishu bot scopes need import"
    refute filtered_html =~ "Background sync ok"
  end

  test "event evidence preview uses per-domain allowlists", %{conn: conn, org: org} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, _integration_event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "integration",
               resource_type: "feishu_connect",
               source: "salix.im",
               event_type: "feishu.callback.ignored",
               severity: "warning",
               summary: "Integration evidence contract",
               evidence: %{
                 callback_mode: "event_callback",
                 provider: "feishu",
                 settings_path: "settings/oauth",
                 status: "unavailable",
                 surface: "project_integrations",
                 command_hash: "sha256:integration-must-not-render",
                 raw_payload: "raw integration payload"
               },
               occurred_at: now
             })

    assert {:ok, _runner_event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "runner",
               resource_type: "mac_mini_provisioner",
               source: "mac_mini.provisioner",
               event_type: "runner.status_changed",
               severity: "info",
               summary: "Runner evidence contract",
               evidence: %{
                 callback_mode: "runner-must-not-render",
                 command_hash: "sha256:runner-allowed",
                 install_code_id: "install-code-visible-id",
                 reason_class: "code_already_consumed",
                 release_id: "release-visible",
                 raw_payload: "raw runner payload"
               },
               occurred_at: DateTime.add(now, 1, :second)
             })

    assert {:ok, _conversation_event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "conversation",
               resource_type: "slack_message",
               source: "salix.im",
               event_type: "slack.reply.sent",
               severity: "info",
               summary: "Conversation evidence contract",
               evidence: %{
                 provider: "slack",
                 channel_id: "C-visible",
                 thread_ts: "100.0",
                 message_ts: "100.2",
                 surface: "project_conversations",
                 list_limit: "25",
                 text: "message text must not render",
                 raw_payload: "raw conversation payload"
               },
               occurred_at: DateTime.add(now, 2, :second)
             })

    assert {:ok, _schedule_event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "schedule",
               resource_type: "project_schedule",
               source: "salix.schedule",
               event_type: "schedule.fire.failed",
               severity: "error",
               summary: "Schedule evidence contract",
               evidence: %{
                 stage: "deliver",
                 schedule_id: "sched-visible",
                 salix_agent_id: "agent-visible",
                 surface: "project_schedules",
                 salix_agent_count: "2",
                 prompt: "schedule prompt must not render",
                 raw_payload: "raw schedule payload"
               },
               occurred_at: DateTime.add(now, 3, :second)
             })

    assert {:ok, _sso_event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "sso",
               resource_type: "org_sso_connection",
               source: "bft.dashboard",
               event_type: "sso.login.failed",
               severity: "error",
               summary: "SSO evidence contract",
               evidence: %{
                 provider: "generic_oidc",
                 stage: "callback",
                 request_id: "req-sso-visible",
                 status_code: "401",
                 email: "blocked@example.test",
                 raw_payload: "raw sso payload"
               },
               occurred_at: DateTime.add(now, 4, :second)
             })

    assert {:ok, _org_event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "org",
               resource_type: "salix_tenant",
               source: "salix.control",
               event_type: "salix.reconcile.failed",
               severity: "error",
               summary: "Org evidence contract",
               evidence: %{
                 aggregate: "organization",
                 op: "create_tenant",
                 attempts: "1",
                 reason_class: "conflict",
                 raw_payload: "raw reconcile payload"
               },
               occurred_at: DateTime.add(now, 5, :second)
             })

    assert {:ok, _project_event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "project",
               resource_type: "project_website_index",
               source: "salix.control",
               event_type: "project.websites.unavailable",
               severity: "warning",
               summary: "Project websites evidence contract",
               evidence: %{
                 surface: "project_websites",
                 salix_agent_count: "2",
                 reason_class: "unavailable",
                 url: "https://private-site.example.test",
                 raw_payload: "raw websites payload"
               },
               occurred_at: DateTime.add(now, 6, :second)
             })

    assert {:ok, _agent_event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "agent",
               resource_type: "agent",
               resource_id: "agent-visible-id",
               source: "salix.env",
               event_type: "agent.runtime.degraded",
               severity: "warning",
               summary: "Agent runtime evidence contract",
               evidence: %{
                 device_runtime_id: "device-runtime-visible",
                 connector_run_id: "run-visible",
                 runtime_id: "runtime-visible",
                 device_id: "device-visible",
                 runtime_status: "auth_failed",
                 ready: "false",
                 auth_ready: "false",
                 command: "/usr/local/bin/codex",
                 raw_payload: "raw runtime payload"
               },
               occurred_at: DateTime.add(now, 7, :second)
             })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/events")

    assert html =~ "Integration evidence contract"
    assert html =~ "callback_mode=event_callback"
    assert html =~ "provider=feishu"
    assert html =~ "settings_path=settings/oauth"
    assert html =~ "status=unavailable"
    assert html =~ "surface=project_integrations"
    refute html =~ "sha256:integration-must-not-render"
    refute html =~ "raw integration payload"

    assert html =~ "Runner evidence contract"
    assert html =~ "command_hash=sha256:runner-allowed"
    assert html =~ "install_code_id=install-code-visible-id"
    assert html =~ "reason_class=code_already_consumed"
    assert html =~ "release_id=release-visible"
    refute html =~ "callback_mode=runner-must-not-render"
    refute html =~ "raw runner payload"

    assert html =~ "Conversation evidence contract"
    assert html =~ "provider=slack"
    assert html =~ "channel_id=C-visible"
    assert html =~ "thread_ts=100.0"
    assert html =~ "message_ts=100.2"
    assert html =~ "surface=project_conversations"
    assert html =~ "list_limit=25"
    refute html =~ "message text must not render"
    refute html =~ "raw conversation payload"

    assert html =~ "Schedule evidence contract"
    assert html =~ "stage=deliver"
    assert html =~ "schedule_id=sched-visible"
    assert html =~ "salix_agent_id=agent-visible"
    assert html =~ "surface=project_schedules"
    assert html =~ "salix_agent_count=2"
    refute html =~ "schedule prompt must not render"
    refute html =~ "raw schedule payload"

    assert html =~ "SSO evidence contract"
    assert html =~ "provider=generic_oidc"
    assert html =~ "stage=callback"
    assert html =~ "request_id=req-sso-visible"
    assert html =~ "status_code=401"
    refute html =~ "blocked@example.test"
    refute html =~ "raw sso payload"

    assert html =~ "Org evidence contract"
    assert html =~ "aggregate=organization"
    assert html =~ "op=create_tenant"
    assert html =~ "attempts=1"
    assert html =~ "reason_class=conflict"
    refute html =~ "raw reconcile payload"

    assert html =~ "Project websites evidence contract"
    assert html =~ "surface=project_websites"
    assert html =~ "salix_agent_count=2"
    refute html =~ "https://private-site.example.test"
    refute html =~ "raw websites payload"

    assert html =~ "Agent runtime evidence contract"
    assert html =~ "device_runtime_id=device-runtime-visible"
    assert html =~ "connector_run_id=run-visible"
    assert html =~ "runtime_id=runtime-visible"
    assert html =~ "device_id=device-visible"
    assert html =~ "runtime_status=auth_failed"
    assert html =~ "ready=false"
    assert html =~ "auth_ready=false"
    refute html =~ "/usr/local/bin/codex"
    refute html =~ "raw runtime payload"
  end

  test "checks can filter by nested gate status", %{conn: conn, org: org, user: user} do
    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Gate Filter Ops", "slug" => "gate-filter-ops"})

    assert {:ok, _manual_check} =
             Observability.record_run_checks(
               %{
                 surface: "bot",
                 org_ref: org.id,
                 project_ref: project.id,
                 ran_at: DateTime.utc_now(),
                 gates: [
                   %{
                     gate_id: "bot.scope_batch",
                     label: "Manual gate",
                     status: :needs_manual,
                     next_action: "Import scopes"
                   }
                 ]
               },
               ran_by_user_id: user.id,
               invocation_id: "gate-filter-manual"
             )

    assert {:ok, _failed_check} =
             Observability.record_run_checks(
               %{
                 surface: "bot",
                 org_ref: org.id,
                 project_ref: project.id,
                 ran_at: DateTime.add(DateTime.utc_now(), 1, :second),
                 gates: [
                   %{
                     gate_id: "bot.credentials",
                     label: "Credential gate",
                     status: :fail,
                     next_action: "Fix credentials"
                   }
                 ]
               },
               ran_by_user_id: user.id,
               invocation_id: "gate-filter-fail"
             )

    {:ok, view, html} =
      live(conn, ~p"/orgs/#{org.slug}/operations/checks?gate_status=needs_manual")

    assert html =~ "Gate status"
    assert html =~ "gate_status=needs_manual"
    assert html =~ "Manual gate - needs manual"
    assert html =~ "gate-filter-manual"
    refute html =~ "Credential gate - fail"
    refute html =~ "gate-filter-fail"

    html =
      view
      |> form("#operations-checks-filters", %{
        "filters" => %{"gate_status" => "fail"}
      })
      |> render_submit()

    assert html =~ "gate_status=fail"
    assert html =~ "Credential gate - fail"
    assert html =~ "gate-filter-fail"
    refute html =~ "Manual gate - needs manual"
    refute html =~ "gate-filter-manual"
  end

  test "checks keep optional skipped gates visible without making the summary actionable", %{
    conn: conn,
    org: org,
    user: user
  } do
    {:ok, project} =
      Projects.create_project(org.id, %{
        "name" => "Optional Calendar Ops",
        "slug" => "optional-calendar-ops"
      })

    assert {:ok, check} =
             Observability.record_run_checks_activity(
               RunChecks.to_json_map(%{
                 surface: "bot",
                 org_ref: org.id,
                 project_ref: project.id,
                 ran_at: DateTime.utc_now(),
                 gates: [
                   %{
                     gate_id: "bot.callback",
                     label: "Required callback",
                     status: :ok,
                     required: true
                   },
                   %{
                     gate_id: "bot.calendar",
                     label: "Optional Calendar notification",
                     status: :skipped,
                     reason_class: :calendar_notification_not_configured,
                     required: false
                   }
                 ]
               }),
               ran_by_user_id: user.id,
               request_id: "ops-optional-calendar"
             )

    assert check.status == "ok"
    assert [callback_gate, calendar_gate] = check.result["gates"]
    assert callback_gate["required"] == true
    assert callback_gate["redacted"] == true
    assert calendar_gate["required"] == false
    assert calendar_gate["redacted"] == true

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/checks")

    assert html =~ "Required callback - ok"
    refute html =~ "Optional Calendar notification - skipped"
  end

  test "render allowlist redacts dirty observability text before HTML", %{
    conn: conn,
    org: org,
    user: user
  } do
    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Dirty Render", "slug" => "dirty-render"})

    secret = "sk-testabcdefghijklmnopqrstuvwxyz"
    email = "leaky-admin@example.com"
    now = DateTime.utc_now()

    Repo.insert!(
      ObservabilityEvent.changeset(%ObservabilityEvent{}, %{
        org_id: org.id,
        project_id: project.id,
        domain: "integration",
        resource_type: "feishu_connect",
        resource_id: "dirty-event",
        source: "bft.run_checks",
        event_type: "feishu.callback.ignored",
        severity: "warning",
        status: "ignored",
        reason_class: "token=#{secret}",
        summary: "Callback included #{secret} for #{email}",
        evidence: %{"raw_payload" => secret},
        evidence_size_bytes: 2,
        occurred_at: now
      })
    )

    Repo.insert!(
      OperationRun.changeset(%OperationRun{}, %{
        org_id: org.id,
        project_id: project.id,
        run_type: "fin_exec",
        external_run_id: "run-#{secret}",
        status: "failed",
        reason_class: "authorization=#{secret}",
        evidence: %{"stdout" => "raw #{secret}"},
        evidence_size_bytes: 2,
        started_at: now
      })
    )

    Repo.insert!(
      CheckResult.changeset(%CheckResult{}, %{
        org_id: org.id,
        project_id: project.id,
        check_family: "run_checks",
        surface: "bot",
        subject_type: "project",
        subject_id: project.id,
        status: "fail",
        reason_class: "message=#{secret}",
        result: %{
          "gates" => [
            %{"gate_id" => "bot.dirty", "label" => "Gate #{secret}", "status" => "fail"}
          ]
        },
        result_size_bytes: 2,
        invocation_id: "invoke-#{secret}",
        ran_at: now
      })
    )

    Repo.insert!(
      AuditLog.changeset(%AuditLog{}, %{
        org_id: org.id,
        actor_type: "user",
        actor_user_id: user.id,
        actor_label: email,
        action: "settings.sso.updated",
        resource_type: "sso",
        resource_id: org.id,
        resource_label: "SSO #{secret}",
        result: "ok",
        reason_class: "token=#{secret}",
        request_id: "req-#{secret}",
        metadata: %{"raw" => secret},
        redacted_diff: %{},
        metadata_size_bytes: 2
      })
    )

    for path <- [
          ~p"/orgs/#{org.slug}/operations",
          ~p"/orgs/#{org.slug}/operations/events",
          ~p"/orgs/#{org.slug}/operations/runners",
          ~p"/orgs/#{org.slug}/operations/checks",
          ~p"/orgs/#{org.slug}/operations/audit"
        ] do
      {:ok, _view, html} = live(conn, path)

      assert html =~ "[REDACTED]"
      refute html =~ secret
      refute html =~ email
    end
  end

  test "overview does not render stale runner posture as healthy", %{conn: conn, org: org} do
    {:ok, project} =
      Projects.create_project(org.id, %{
        "name" => "Stale Runner Ops",
        "slug" => "stale-runner-ops"
      })

    assert {:ok, _provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "stale-health-runner",
               "name" => "Stale Health Runner",
               "status" => "online",
               "last_seen_at" => DateTime.add(DateTime.utc_now(), -90, :second)
             })

    assert {:ok, _check} =
             Observability.create_check_result(%{
               org_id: org.id,
               project_id: project.id,
               check_family: "run_checks",
               surface: "bot",
               subject_type: "project",
               subject_id: project.id,
               status: "ok",
               result: %{gates: [%{gate_id: "bot.ok", label: "Bot setup", status: "ok"}]},
               invocation_id: "stale-runner-health-check",
               ran_at: DateTime.utc_now()
             })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/operations")

    assert html =~ "degraded"
    assert html =~ "At least one runner heartbeat is stale or unknown."
    refute html =~ ">healthy<"
  end

  test "overview does not render skipped checks as healthy", %{conn: conn, org: org} do
    {:ok, project} =
      Projects.create_project(org.id, %{
        "name" => "Skipped Check Ops",
        "slug" => "skipped-check-ops"
      })

    assert {:ok, _provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "healthy-runner",
               "name" => "Healthy Runner",
               "status" => "online",
               "last_seen_at" => DateTime.utc_now()
             })

    assert {:ok, _check} =
             Observability.create_check_result(%{
               org_id: org.id,
               project_id: project.id,
               check_family: "run_checks",
               surface: "bot",
               subject_type: "project",
               subject_id: project.id,
               status: "skipped",
               result: %{
                 gates: [%{gate_id: "bot.skipped", label: "Bot setup", status: "skipped"}]
               },
               invocation_id: "skipped-runner-health-check",
               ran_at: DateTime.utc_now()
             })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/operations")

    assert html =~ "degraded"
    assert html =~ "Recent checks need manual follow-up or were skipped."
    refute html =~ ">healthy<"
  end

  test "operations health is independent of event pagination and filters", %{conn: conn, org: org} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, _critical_event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "runner",
               resource_type: "mac_mini_provisioner",
               source: "mac_mini.provisioner",
               event_type: "runner.status_changed",
               severity: "critical",
               summary: "Hidden critical runner failure",
               occurred_at: now
             })

    for index <- 1..26 do
      label = index |> Integer.to_string() |> String.pad_leading(2, "0")

      assert {:ok, _event} =
               Observability.create_event(%{
                 org_id: org.id,
                 domain: "runner",
                 resource_type: "mac_mini_provisioner",
                 source: "mac_mini.provisioner",
                 event_type: "runner.status_changed",
                 severity: "info",
                 summary: "Newer healthy-looking runner event #{label}",
                 occurred_at: DateTime.add(now, index, :second)
               })
    end

    {:ok, _view, overview_html} = live(conn, ~p"/orgs/#{org.slug}/operations")

    assert overview_html =~ "critical"
    assert overview_html =~ "Recent operational events include critical alerts."
    refute overview_html =~ "Hidden critical runner failure"

    {:ok, _view, filtered_html} =
      live(conn, ~p"/orgs/#{org.slug}/operations/events?severity=info")

    assert filtered_html =~ "critical"
    assert filtered_html =~ "severity=info"
    assert filtered_html =~ "Newer healthy-looking runner event 26"
    refute filtered_html =~ "Hidden critical runner failure"
  end

  test "delivery links to owning project pages and filtered events", %{conn: conn, org: org} do
    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Linked Delivery", "slug" => "linked-delivery"})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, _conversation_event} =
             Observability.create_event(%{
               org_id: org.id,
               project_id: project.id,
               conversation_id: Ecto.UUID.generate(),
               domain: "conversation",
               resource_type: "conversation",
               source: "salix.im",
               event_type: "conversation.message.queued",
               severity: "info",
               summary: "Conversation delivery queued",
               occurred_at: now
             })

    assert {:ok, _environment_event} =
             Observability.create_event(%{
               org_id: org.id,
               project_id: project.id,
               environment_id: Ecto.UUID.generate(),
               domain: "device",
               resource_type: "salix_device_connector",
               source: "salix.env",
               event_type: "device.runtime.observed",
               severity: "info",
               summary: "Device runtime observed",
               occurred_at: DateTime.add(now, 1, :second)
             })

    assert {:ok, _integration_event} =
             Observability.create_event(%{
               org_id: org.id,
               project_id: project.id,
               domain: "integration",
               resource_type: "feishu_connect",
               source: "salix.im",
               event_type: "feishu.callback.ignored",
               severity: "warning",
               reason_class: "router_not_ready",
               summary: "Feishu callback ignored",
               occurred_at: DateTime.add(now, 2, :second)
             })

    assert {:ok, _latest_event} =
             Observability.create_event(%{
               org_id: org.id,
               project_id: project.id,
               domain: "project",
               resource_type: "project",
               resource_id: project.id,
               source: "bft.dashboard",
               event_type: "delivery.smoke.failed",
               severity: "error",
               summary: "Delivery smoke failed",
               occurred_at: DateTime.add(now, 3, :second)
             })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/delivery")

    assert html =~ "Linked Delivery"
    assert html =~ "0 agents"
    assert html =~ "No active agents"
    assert html =~ "Feishu callback ignored"
    assert html =~ "Delivery smoke failed"
    assert html =~ "delivery.smoke.failed"
    assert html =~ "degraded"
    assert html =~ "Recent delivery event has errors"
    assert html =~ "needs manual"
    assert html =~ ~s(href="/orgs/#{org.slug}/projects/#{project.id}")
    assert html =~ ~s(id="operations-delivery-detail-#{project.id}")
    assert html =~ "Delivery detail"
    assert html =~ "Open project"
    assert html =~ "Filtered events"
    assert html =~ "Device events"
    assert html =~ "Filtered checks"
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/events?project_id=#{project.id}")
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/checks?project_id=#{project.id}")
    assert html =~ "domain=device"
  end

  test "integrations render failed skipped and manual checks honestly", %{conn: conn, org: org} do
    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Integration Ops", "slug" => "integration-ops"})

    assert {:ok, _feishu_check} =
             Observability.create_check_result(%{
               org_id: org.id,
               project_id: project.id,
               check_family: "run_checks",
               surface: "bot",
               subject_type: "project",
               subject_id: project.id,
               status: "needs_manual",
               reason_class: "scope_batch_required",
               result: %{
                 gates: [
                   %{
                     gate_id: "bot.scope_batch",
                     label: "Feishu scopes",
                     status: "needs_manual"
                   }
                 ],
                 app_secret: "super-secret"
               },
               invocation_id: "integration-bot-check",
               ran_at: DateTime.utc_now()
             })

    assert {:ok, _sso_check} =
             Observability.create_check_result(%{
               org_id: org.id,
               check_family: "run_checks",
               surface: "sso",
               subject_type: "org",
               subject_id: org.id,
               status: "skipped",
               result: %{
                 gates: [
                   %{gate_id: "sso.config", label: "SSO config", status: "skipped"}
                 ]
               },
               invocation_id: "integration-sso-check",
               ran_at: DateTime.add(DateTime.utc_now(), -1, :second)
             })

    assert {:ok, _model_check} =
             Observability.create_check_result(%{
               org_id: org.id,
               check_family: "run_checks",
               surface: "models",
               subject_type: "org",
               subject_id: org.id,
               status: "fail",
               reason_class: "provider_unreachable",
               result: %{
                 gates: [
                   %{gate_id: "models.provider", label: "Model provider", status: "fail"}
                 ],
                 prompt: "raw prompt must not render"
               },
               invocation_id: "integration-model-check",
               ran_at: DateTime.add(DateTime.utc_now(), -2, :second)
             })

    assert {:ok, _event} =
             Observability.create_event(%{
               org_id: org.id,
               project_id: project.id,
               domain: "integration",
               resource_type: "feishu_connect",
               resource_id: "feishu-connect-1",
               source: "bft.run_checks",
               event_type: "feishu.callback.ignored",
               severity: "warning",
               status: "ignored",
               reason_class: "missing_mapping",
               summary: "Feishu callback ignored",
               evidence: %{message_body: "do not render"}
             })

    assert {:ok, _oauth_validation} =
             Observability.record_validation_event(%{
               org_id: org.id,
               surface: "oauth",
               provider: "notion",
               resource_type: "oauth_provider_app",
               resource_id: "notion",
               resource_label: "notion",
               status: "fail",
               reason_class: "bad_request",
               evidence: %{
                 client_secret: "oauth-secret",
                 field_errors: %{provider_error_class: "bad_request"}
               }
             })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/integrations")

    assert html =~ ~s(id="operations-integrations-table")
    assert html =~ "Feishu"
    assert html =~ "needs manual"
    assert html =~ "scope batch required"
    assert html =~ "Feishu scopes - needs manual"
    assert html =~ "Feishu callback ignored"
    assert html =~ "feishu.callback.ignored"
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/checks?surface=bot")
    assert html =~ ~s(href="/orgs/#{org.slug}/projects/#{project.id}")

    assert html =~ "SSO"
    assert html =~ "skipped"
    assert html =~ "SSO config - skipped"
    assert html =~ ~s(href="/orgs/#{org.slug}/settings#sso")

    assert html =~ "Models"
    assert html =~ "fail"
    assert html =~ "provider unreachable"
    assert html =~ "Model provider - fail"
    assert html =~ "OAuth"
    assert html =~ "notion validation failed"
    assert html =~ "oauth.validation.failed"
    refute html =~ "super-secret"
    refute html =~ "oauth-secret"
    refute html =~ "raw prompt must not render"
    refute html =~ "do not render"
  end

  test "integrations use subsystem fact presets beyond the current event page", %{
    conn: conn,
    org: org
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, _event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "integration",
               resource_type: "feishu_connect",
               resource_id: "feishu-connect-preset",
               source: "salix.im",
               event_type: "feishu.callback.ignored",
               severity: "warning",
               status: "ignored",
               reason_class: "missing_mapping",
               summary: "Older Feishu callback ignored",
               occurred_at: now
             })

    for index <- 1..26 do
      assert {:ok, _event} =
               Observability.create_event(%{
                 org_id: org.id,
                 domain: "runner",
                 resource_type: "mac_mini_provisioner",
                 source: "mac_mini.provisioner",
                 event_type: "runner.status_changed",
                 severity: "info",
                 summary: "Newer runner event #{index}",
                 occurred_at: DateTime.add(now, index, :second)
               })
    end

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/integrations")

    assert html =~ ~s(id="operations-integrations-table")
    assert html =~ "Older Feishu callback ignored"
    assert html =~ "feishu.callback.ignored"
    refute html =~ "Newer runner event 26"
  end

  test "events show live device runtime disconnect diagnostics", %{conn: conn, org: org} do
    {:ok, project} =
      Projects.create_project(org.id, %{
        "name" => "Runtime Env Ops",
        "slug" => "runtime-env-ops"
      })

    device_id = SalixStore.Ids.new_device_id()

    assert {:ok, _transport_id, _record} =
             SalixEnv.Registry.connect("nonode@nohost", %{
               "tenant_id" => org.salix_tenant_id,
               "group_id" => project.salix_group_id,
               "device_id" => device_id,
               "connector_id" => "connector-#{System.unique_integer([:positive])}",
               "name" => "Runtime Box",
               "connector_token" => "salix_conn_secret",
               "raw_payload" => "raw provider payload"
             })

    assert {:ok, disconnected} = Environments.disconnect_environment(project.id, device_id)
    assert disconnected["status"] == "disconnected"

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/events?domain=device")

    assert html =~ ~s(id="operations-events")
    assert html =~ "device.runtime.disconnected"
    assert html =~ "Device Runtime Box disconnected"
    refute html =~ "salix_conn_secret"
    refute html =~ "raw provider payload"
  end

  test "paginates the Operations event stream with cursor links", %{conn: conn, org: org} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for index <- 1..26 do
      label = index |> Integer.to_string() |> String.pad_leading(2, "0")

      assert {:ok, _event} =
               Observability.create_event(%{
                 org_id: org.id,
                 domain: "runner",
                 resource_type: "mac_mini_provisioner",
                 source: "mac_mini.provisioner",
                 event_type: "runner.status_changed",
                 severity: "info",
                 summary: "Paged Event #{label}",
                 occurred_at: DateTime.add(now, index, :second)
               })
    end

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/events")

    assert html =~ "Paged Event 26"
    refute html =~ "Paged Event 01"
    assert html =~ "Next page"

    html =
      view
      |> element("a", "Next page")
      |> render_click()

    assert html =~ "Paged Event 01"
    refute html =~ "Paged Event 26"
    refute html =~ "cursor="
  end

  test "paginates the Operations check snapshots with cursor links", %{conn: conn, org: org} do
    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Paged Checks", "slug" => "paged-checks"})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for index <- 1..26 do
      label = index |> Integer.to_string() |> String.pad_leading(2, "0")

      assert {:ok, _check} =
               Observability.create_check_result(%{
                 org_id: org.id,
                 project_id: project.id,
                 check_family: "run_checks",
                 surface: "bot",
                 subject_type: "project",
                 subject_id: project.id,
                 status: "ok",
                 result: %{
                   gates: [
                     %{
                       gate_id: "bot.paged_#{label}",
                       label: "Paged check gate #{label}",
                       status: "ok"
                     }
                   ]
                 },
                 invocation_id: "paged-check-#{label}",
                 ran_at: DateTime.add(now, index, :second)
               })
    end

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/checks")

    assert html =~ "paged-check-26"
    refute html =~ "paged-check-01"
    assert html =~ "Next page"

    html =
      view
      |> element("a", "Next page")
      |> render_click()

    assert html =~ "paged-check-01"
    refute html =~ "paged-check-26"
    refute html =~ "cursor="
  end

  test "paginates the Operations audit records with cursor links", %{
    conn: conn,
    org: org,
    user: user
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for index <- 1..26 do
      label = index |> Integer.to_string() |> String.pad_leading(2, "0")

      assert {:ok, audit} =
               Observability.record_audit(%{
                 org_id: org.id,
                 actor_user_id: user.id,
                 action: "audit.paged_#{label}",
                 resource_type: "project",
                 resource_id: "project-#{label}",
                 resource_label: "Paged Audit #{label}",
                 result: "ok",
                 request_id: "paged-audit-#{label}"
               })

      Repo.update_all(
        from(a in AuditLog, where: a.id == ^audit.id),
        set: [created_at: DateTime.add(now, index, :second)]
      )
    end

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/audit")

    assert html =~ "paged-audit-26"
    refute html =~ "paged-audit-01"
    assert html =~ "Next page"

    html =
      view
      |> element("a", "Next page")
      |> render_click()

    assert html =~ "paged-audit-01"
    refute html =~ "paged-audit-26"
    refute html =~ "cursor="
  end

  test "exports filtered audit logs as bounded redacted CSV", %{
    conn: conn,
    org: org,
    user: user
  } do
    assert {:ok, exported_audit} =
             Observability.record_audit(%{
               org_id: org.id,
               actor_user_id: user.id,
               actor_label: "private-admin@example.com",
               action: "settings.sso.updated",
               resource_type: "sso",
               resource_id: org.id,
               resource_label: "=IMPORTDATA(secret)",
               result: "ok",
               request_id: "req_export_sso",
               metadata: %{"submitted_secret" => "sk-export-secret"},
               redacted_diff: %{"client_secret" => "super-private-diff"}
             })

    assert {:ok, _other_audit} =
             Observability.record_audit(%{
               org_id: org.id,
               actor_user_id: user.id,
               action: "settings.model.updated",
               resource_type: "model_settings",
               resource_id: org.id,
               result: "ok",
               request_id: "req_export_model"
             })

    {:ok, _view, html} =
      live(conn, ~p"/orgs/#{org.slug}/operations/audit?#{%{action: "settings.sso.updated"}}")

    assert html =~
             ~s(href="/orgs/#{org.slug}/operations/audit.csv?action=settings.sso.updated")

    conn =
      get(conn, ~p"/orgs/#{org.slug}/operations/audit.csv", %{
        "action" => "settings.sso.updated"
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/csv"
    assert [content_disposition] = get_resp_header(conn, "content-disposition")
    assert content_disposition =~ ~s(attachment; filename="bft-audit-#{org.slug}.csv")

    csv = response(conn, 200)

    assert csv =~ "audit_id"
    assert csv =~ exported_audit.id
    assert csv =~ "settings.sso.updated"
    assert csv =~ "req_export_sso"
    assert csv =~ "'=IMPORTDATA(secret)"
    refute csv =~ "settings.model.updated"
    refute csv =~ "req_export_model"
    refute csv =~ "audit_log.exported"
    refute csv =~ "private-admin@example.com"
    refute csv =~ "sk-export-secret"
    refute csv =~ "super-private-diff"

    assert [export_audit] =
             Observability.list_audit_logs(org.id, action: "audit_log.exported")

    assert export_audit.actor_user_id == user.id
    assert export_audit.resource_type == "audit_export"
    assert export_audit.resource_id == org.id
    assert export_audit.resource_label == "bft-audit-#{org.slug}.csv"
    assert export_audit.result == "ok"
    assert is_binary(export_audit.request_id)
    assert export_audit.metadata["format"] == "csv"
    assert export_audit.metadata["row_count"] in [1, "1"]
    assert export_audit.metadata["limit"] in [500, "500"]
    assert export_audit.metadata["filter_keys"] == ["action"]
    assert "request_id" in export_audit.metadata["columns"]
    refute inspect(export_audit) =~ "sk-export-secret"
    refute inspect(export_audit) =~ "super-private-diff"

    assert [event] = Observability.list_events(org.id, audit_log_id: export_audit.id)
    assert event.domain == "audit"
    assert event.event_type == "audit.audit_log.exported"
    assert event.correlation_id == export_audit.request_id
  end

  test "paginates recent Operations runs with cursor links", %{conn: conn, org: org} do
    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Paged Runs", "slug" => "paged-runs"})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for index <- 1..26 do
      label = index |> Integer.to_string() |> String.pad_leading(2, "0")

      assert {:ok, run} =
               Observability.create_operation_run(%{
                 org_id: org.id,
                 project_id: project.id,
                 run_type: "fin_exec",
                 external_run_id: "paged-run-#{label}",
                 request_id: "paged-run-request-#{label}",
                 status: "failed",
                 reason_class: "command_failed",
                 duration_ms: 100 + index
               })

      Repo.update_all(
        from(r in OperationRun, where: r.id == ^run.id),
        set: [created_at: DateTime.add(now, index, :second)]
      )
    end

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/runners")

    assert html =~ "paged-run-26"
    refute html =~ "paged-run-01"
    assert html =~ "Next page"

    html =
      view
      |> element("a", "Next page")
      |> render_click()

    assert html =~ "paged-run-01"
    refute html =~ "paged-run-26"
    refute html =~ "cursor="
  end

  test "lists every runner associated with the org", %{conn: conn, org: org} do
    assert {:ok, _provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "lab-mac-mini",
               "name" => "Lab Mac mini",
               "status" => "online",
               "host_identity" => "lab-host",
               "os_summary" => "macOS arm64",
               "version" => "0.1.0",
               "capabilities" => %{
                 "component_versions" => %{
                   "salix-connect" => "2026.06.18",
                   "agent-vmm-host" => "0.3.2"
                 }
               },
               "capacity" => 3,
               "current_connector_count" => 1,
               "last_seen_at" => DateTime.utc_now()
             })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/runners")

    assert html =~ ~s(id="fin-mac-minis")
    assert html =~ "1 runner"
    assert html =~ "Lab Mac mini"
    assert html =~ "lab-mac-mini"
    assert html =~ "online"
    assert html =~ "lab-host"
    assert html =~ "macOS arm64"
    assert html =~ "1 / 3"
    assert html =~ "agent-vmm-host"
    assert html =~ "0.1.0"
    assert html =~ "salix-connect=2026.06.18"
    assert html =~ "agent-vmm-host=0.3.2"
    assert html =~ "Manage in Fin"
    assert html =~ ~s(href="/orgs/#{org.slug}/fin")
  end

  test "cursor paginates the Operations runner fleet", %{conn: conn, org: org} do
    for index <- 1..26 do
      padded = String.pad_leading(to_string(index), 2, "0")

      assert {:ok, _provisioner} =
               Environments.register_mac_mini_provisioner(org.id, %{
                 "stable_id" => "ops-paged-mac-mini-#{padded}",
                 "name" => "Ops Paged Mac mini #{padded}",
                 "status" => "online"
               })
    end

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/runners")

    assert html =~ "26 runners"
    assert html =~ "Showing 25 of 26 runners"
    assert html =~ "Ops Paged Mac mini 01"
    refute html =~ "Ops Paged Mac mini 26"
    assert html =~ "Next runners"
    refute html =~ "First page"

    html =
      view
      |> element("a", "Next runners")
      |> render_click()

    assert html =~ "26 runners"
    assert html =~ "Showing 1 of 26 runners"
    assert html =~ "Ops Paged Mac mini 26"
    refute html =~ "Ops Paged Mac mini 01"
    assert html =~ "First page"
    refute html =~ "Next runners"
  end

  test "shows stale Runners as recently lost", %{conn: conn, org: org} do
    assert {:ok, _provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "stale-mac-mini",
               "name" => "Stale Mac mini",
               "status" => "online",
               "host_identity" => "stale-host",
               "last_seen_at" => DateTime.add(DateTime.utc_now(), -90, :second)
             })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/runners")

    assert html =~ "Stale Mac mini"
    assert html =~ "recently_lost"
    assert html =~ "last reported"
    assert html =~ "online"
    assert html =~ "1m ago"
  end

  test "runner rows show component posture and latest linked diagnostics", %{
    conn: conn,
    org: org
  } do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "diag-mac-mini",
               "name" => "Diagnostics Mac mini",
               "status" => "online",
               "version" => "0.2.0",
               "capabilities" => %{
                 "component_versions" => %{
                   "salix-connect" => "2026.06.22",
                   "agent-vmm-host" => "0.4.0"
                 }
               },
               "capacity" => 2,
               "current_connector_count" => 1,
               "last_seen_at" => DateTime.utc_now()
             })

    environment_id = Ecto.UUID.generate()

    assert {:ok, _run} =
             Observability.create_operation_run(%{
               org_id: org.id,
               runner_type: "mac_mini_provisioner",
               runner_id: provisioner.id,
               environment_id: environment_id,
               run_type: "fin_exec",
               external_run_id: "diag-run-1",
               status: "failed",
               reason_class: "command_failed",
               duration_ms: 420
             })

    assert {:ok, _event} =
             Observability.create_event(%{
               org_id: org.id,
               runner_type: "mac_mini_provisioner",
               runner_id: provisioner.id,
               environment_id: environment_id,
               domain: "device",
               resource_type: "device_provision_request",
               resource_id: environment_id,
               source: "salix.env",
               event_type: "device.provision.failed",
               severity: "error",
               status: "failed",
               reason_class: "provision_failed",
               summary: "Provision failed on runner",
               occurred_at: DateTime.utc_now()
             })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/runners")

    assert html =~ "Diagnostics Mac mini"
    assert html =~ "Runner"
    assert html =~ "version 0.2.0"
    assert html =~ "salix-connect=2026.06.22"
    assert html =~ "agent-vmm-host=0.4.0"
    assert html =~ "Provision failed on runner"
    assert html =~ "device.provision.failed"
    assert html =~ "diag-run-1"
    assert html =~ "command failed"
    assert html =~ ~s(/orgs/#{org.slug}/operations/events?)
    assert html =~ ~s(/orgs/#{org.slug}/operations/runners?)
    assert html =~ "runner_type=mac_mini_provisioner"
    assert html =~ "runner_id=#{provisioner.id}"
  end

  test "refreshes the runner fleet without a page reload", %{conn: conn, org: org} do
    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/operations/runners")

    assert html =~ "No runners connected"

    assert {:ok, _provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "refresh-mac-mini",
               "name" => "Refresh Mac mini",
               "status" => "online",
               "host_identity" => "refresh-host",
               "os_summary" => "macOS arm64",
               "capabilities" => %{"salix_connect" => true},
               "capacity" => 2,
               "current_connector_count" => 0
             })

    send(view.pid, :refresh_operations_runners)
    html = render(view)

    assert html =~ "Refresh Mac mini"
    assert html =~ "refresh-host"
    assert html =~ "0 / 2"
  end

  test "ordinary org members cannot view the audit surface", %{conn: conn, org: org, user: owner} do
    assert {:ok, _audit} =
             Observability.record_audit(%{
               org_id: org.id,
               actor_user_id: owner.id,
               action: "settings.sso.updated",
               resource_type: "sso",
               resource_id: org.id,
               resource_label: "SSO",
               result: "ok",
               request_id: "req_member_denied"
             })

    member = user_fixture(email: "ops-audit-member@example.com")
    {:ok, _membership} = Memberships.put_org_member(org.id, member.id, "member")

    conn = log_in_user(conn, member)

    assert {:error, {:redirect, %{to: "/orgs"}}} =
             live(conn, ~p"/orgs/#{org.slug}/operations/audit")

    assert {:error, {:redirect, %{to: "/orgs"}}} =
             live(conn, ~p"/orgs/#{org.slug}/operations/events")

    conn = get(conn, ~p"/orgs/#{org.slug}/operations/audit.csv")

    assert response(conn, 403) == "forbidden"
  end

  test "redirects users outside the org", %{conn: conn, org: org} do
    outsider = user_fixture(email: "fin-outsider@example.com")
    conn = log_in_user(conn, outsider)

    assert {:error, {:redirect, %{to: "/orgs"}}} = live(conn, ~p"/orgs/#{org.slug}/operations")
  end

  defp restore_env(key, nil), do: Application.delete_env(:bridge_for_teams_web, key)
  defp restore_env(key, value), do: Application.put_env(:bridge_for_teams_web, key, value)
end
