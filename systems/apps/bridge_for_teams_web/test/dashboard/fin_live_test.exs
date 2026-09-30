defmodule BridgeForTeamsWeb.Dashboard.FinLiveTest do
  @moduledoc """
  LiveView tests for the organization Fin page.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  import Ecto.Query

  alias BridgeForTeams.{
    Accounts,
    Auth,
    Environments,
    Memberships,
    Observability,
    Projects
  }

  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.{ApiKey, EnvironmentProvisionRequest, MacMiniInstallCode}

  setup %{conn: conn} do
    %{conn: conn, org: org, user: user} = register_and_log_in_user(%{conn: conn})
    %{conn: conn, org: org, user: user}
  end

  test "renders the Fin sidebar page empty state", %{conn: conn, org: org} do
    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/fin")

    assert html =~ "Fin"
    assert html =~ "Manage the runner fleet that executes work for #{org.name}"
    assert html =~ ~s(id="fin-mac-minis-empty")
    assert html =~ "No runners connected"
    assert html =~ "Add runner"
    assert html =~ "0 runners"
    refute html =~ ~s(id="fin-fleet-summary")
    refute html =~ "Open diagnostics"
    assert html =~ ~s(href="/orgs/#{org.slug}/fin")
    assert html =~ ~s(phx-click="open-runner-onboarding")
    refute html =~ ~s(id="fin-runner-credentials")
  end

  test "lists every runner associated with the org", %{conn: conn, org: org} do
    assert {:ok, provisioner} =
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

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/fin")

    assert html =~ ~s(id="fin-mac-minis")
    assert html =~ "1 runner"
    assert html =~ "Lab Mac mini"
    assert html =~ "lab-mac-mini"
    assert html =~ "online"
    assert html =~ "Capacity"
    assert html =~ "Connectors"

    toggle_html = render(element(view, "#fin-runner-toggle-#{provisioner.id}"))
    assert toggle_html =~ ~s(aria-expanded="false")
    refute toggle_html =~ "aria-label="
    assert toggle_html =~ "Expand Lab Mac mini"
    refute toggle_html =~ "<div"
    refute toggle_html =~ "<h3"

    assert has_element?(
             view,
             "#fin-runner-#{provisioner.id} > header > h3"
           )

    html = expand_runner(view, provisioner.id)

    assert render(element(view, "#fin-runner-toggle-#{provisioner.id}")) =~
             ~s(aria-expanded="true")

    assert html =~ "lab-host"
    assert html =~ "macOS arm64"
    assert html =~ "1 / 3"
    assert html =~ "Heartbeat, host, version, and capacity for every registered machine."
    refute html =~ "Heartbeat, host, runtime, and capacity for every registered machine."
    assert html =~ "Version"
    refute html =~ "Execution"
    assert html =~ "0.1.0"
    assert html =~ "salix-connect=2026.06.18"
    assert html =~ "agent-vmm-host=0.3.2"
    refute html =~ "Diagnostics"
    refute html =~ ~s(runner_type=mac_mini_provisioner)

    assert has_element?(
             view,
             ~s(#fin-runner-#{provisioner.id} > header button[phx-click="request-remove-runner"])
           )
  end

  test "lists each runner's connectors with their Agent Swarms", %{conn: conn, org: org} do
    assert {:ok, runner} = register_runner(org.id, "connector-runner", "Connector Runner")

    assert {:ok, support_project} =
             Projects.create_project(org.id, %{
               "name" => "Customer Support",
               "slug" => "customer-support"
             })

    assert {:ok, sales_project} =
             Projects.create_project(org.id, %{
               "name" => "Sales",
               "slug" => "sales"
             })

    assert {:ok, support_request} =
             Environments.create_device_provision_request(support_project.id, %{
               "provisioner_id" => runner.id,
               "name" => "Support connector",
               "alias" => "support-prod"
             })

    assert {:ok, _connected} =
             Environments.update_device_provision_request_status(support_request, "connected", %{
               "connector_run_id" => "connector-run-support-prod"
             })

    assert {:ok, sales_request} =
             Environments.create_device_provision_request(sales_project.id, %{
               "provisioner_id" => runner.id,
               "name" => "Sales connector",
               "alias" => "sales-prod"
             })

    assert {:ok, _connected} =
             Environments.update_device_provision_request_status(sales_request, "connected", %{
               "connector_run_id" => "connector-run-sales-prod"
             })

    assert {:ok, retired_request} =
             Environments.create_device_provision_request(sales_project.id, %{
               "provisioner_id" => runner.id,
               "name" => "Retired connector",
               "alias" => "sales-retired"
             })

    assert {:ok, _stopped} =
             Environments.update_device_provision_request_status(retired_request, "stopped")

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/fin")

    toggle_html = render(element(view, "#fin-runner-toggle-#{runner.id}"))
    assert toggle_html =~ ~s(aria-expanded="false")
    assert toggle_html =~ "Provisioning"
    assert toggle_html =~ "2 connected"
    assert toggle_html =~ "1 stopped"

    html = expand_runner(view, runner.id)

    assert html =~ ~s(id="fin-runner-connectors-#{runner.id}")
    assert html =~ ~s(id="fin-runner-connector-#{support_request.id}")
    assert html =~ ~s(id="fin-runner-connector-#{sales_request.id}")

    runner_connectors_html =
      view
      |> element("#fin-runner-connectors-#{runner.id}")
      |> render()

    assert runner_connectors_html =~ "support-prod"
    refute runner_connectors_html =~ "connector-run-support-prod"
    assert runner_connectors_html =~ "Provisioning"
    assert runner_connectors_html =~ "Agent Swarm"
    refute runner_connectors_html =~ ">Group<"
    assert runner_connectors_html =~ "Customer Support"

    assert runner_connectors_html =~
             ~s(href="/orgs/#{org.slug}/projects/#{support_project.id}")

    refute runner_connectors_html =~ support_project.salix_group_id
    assert runner_connectors_html =~ "sales-prod"
    refute runner_connectors_html =~ "connector-run-sales-prod"
    assert runner_connectors_html =~ "Sales"
    assert runner_connectors_html =~ ~s(href="/orgs/#{org.slug}/projects/#{sales_project.id}")
    refute runner_connectors_html =~ sales_project.salix_group_id
    assert runner_connectors_html =~ "connected"
    assert runner_connectors_html =~ "sales-retired"
    assert runner_connectors_html =~ "stopped"

    assert {:ok, _new_request} =
             Environments.create_device_provision_request(support_project.id, %{
               "provisioner_id" => runner.id,
               "name" => "New connector",
               "alias" => "support-new"
             })

    send(view.pid, :refresh_fin_mac_minis)
    refreshed_html = render(view)
    assert refreshed_html =~ "1 pending"
    assert refreshed_html =~ "support-new"
  end

  test "shows every connector provisioning state in the aggregate and details", %{
    conn: conn,
    org: org
  } do
    assert {:ok, runner} = register_runner(org.id, "all-state-runner", "All State Runner")

    assert {:ok, project} =
             Projects.create_project(org.id, %{
               "name" => "All State Agent Swarm",
               "slug" => "all-state-agent-swarm"
             })

    labels = %{
      "pending" => "pending",
      "preflight" => "preflight",
      "preflight_complete" => "preflight complete",
      "starting_connector" => "starting connector",
      "waiting_for_attach" => "waiting for connector attach",
      "connected" => "connected",
      "stop_requested" => "stop requested",
      "stopping" => "stopping",
      "stopped" => "stopped",
      "failed" => "failed"
    }

    now = DateTime.utc_now()

    rows =
      for status <- EnvironmentProvisionRequest.statuses() do
        %{
          id: Ecto.UUID.generate(),
          org_id: org.id,
          project_id: project.id,
          provisioner_id: runner.id,
          salix_group_id: project.salix_group_id,
          name: "#{status} connector",
          env_alias: "all-state-#{status}",
          status: status,
          spec: %{},
          progress: %{},
          created_at: now,
          updated_at: now
        }
      end

    {10, nil} = Repo.insert_all(EnvironmentProvisionRequest, rows)

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/fin")
    toggle_html = render(element(view, "#fin-runner-toggle-#{runner.id}"))

    for status <- EnvironmentProvisionRequest.statuses() do
      assert toggle_html =~ "1 #{Map.fetch!(labels, status)}"
    end

    details_html = expand_runner(view, runner.id)

    for status <- EnvironmentProvisionRequest.statuses() do
      assert details_html =~ "all-state-#{status}"
      assert details_html =~ Map.fetch!(labels, status)
    end
  end

  test "keeps the expanded runner connector page across refreshes", %{
    conn: conn,
    org: org,
    user: user
  } do
    assert {:ok, runner} = register_runner(org.id, "paged-connector-runner", "Paged Runner")

    assert {:ok, project} =
             Projects.create_project(org.id, %{
               "name" => "Paged Agent Swarm",
               "slug" => "paged-agent-swarm"
             })

    now = DateTime.utc_now()

    rows =
      for index <- 1..51 do
        padded_index = String.pad_leading(to_string(index), 3, "0")

        %{
          id: Ecto.UUID.generate(),
          org_id: org.id,
          project_id: project.id,
          provisioner_id: runner.id,
          salix_group_id: project.salix_group_id,
          name: "Paged connector #{padded_index}",
          env_alias: "paged-connector-#{padded_index}",
          status: "pending",
          spec: %{},
          progress: %{},
          created_at: now,
          updated_at: now
        }
      end

    {51, nil} = Repo.insert_all(EnvironmentProvisionRequest, rows)

    first_page =
      Environments.page_runner_connector_assignments(org.id, runner.id, user.id)

    second_page =
      Environments.page_runner_connector_assignments(org.id, runner.id, user.id,
        after: first_page.next_cursor
      )

    first_alias = hd(first_page.entries).env_alias
    second_alias = hd(second_page.entries).env_alias

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/fin")
    html = expand_runner(view, runner.id)
    assert html =~ first_alias
    refute html =~ second_alias
    assert html =~ "Next connectors"

    html =
      view
      |> element(~s(button[phx-click="page-runner-connectors"][phx-value-direction="next"]))
      |> render_click()

    assert html =~ second_alias
    refute html =~ first_alias
    assert html =~ "First connectors"

    send(view.pid, :refresh_fin_mac_minis)
    refreshed_html = render(view)
    assert refreshed_html =~ second_alias
    refute refreshed_html =~ first_alias
    assert refreshed_html =~ "First connectors"
  end

  test "cursor paginates the Fin runner fleet", %{conn: conn, org: org} do
    for index <- 1..26 do
      padded = String.pad_leading(to_string(index), 2, "0")

      assert {:ok, _provisioner} =
               Environments.register_mac_mini_provisioner(org.id, %{
                 "stable_id" => "fin-paged-mac-mini-#{padded}",
                 "name" => "Fin Paged Mac mini #{padded}",
                 "status" => "online"
               })
    end

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/fin")

    assert html =~ "26 runners"
    assert html =~ "Showing 25 of 26 runners"
    assert html =~ "Fin Paged Mac mini 01"
    refute html =~ "Fin Paged Mac mini 26"
    assert html =~ "Next runners"
    refute html =~ "First page"

    html =
      view
      |> element("a", "Next runners")
      |> render_click()

    assert html =~ "26 runners"
    assert html =~ "Showing 1 of 26 runners"
    assert html =~ "Fin Paged Mac mini 26"
    refute html =~ "Fin Paged Mac mini 01"
    assert html =~ "First page"
    refute html =~ "Next runners"
  end

  test "shows stale Runners as recently lost", %{conn: conn, org: org} do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "stale-mac-mini",
               "name" => "Stale Mac mini",
               "status" => "online",
               "host_identity" => "stale-host",
               "last_seen_at" => DateTime.add(DateTime.utc_now(), -90, :second)
             })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/fin")

    assert html =~ "Stale Mac mini"
    assert html =~ "recently_lost"
    assert html =~ "reported online"
    assert html =~ "online"

    html = expand_runner(view, provisioner.id)
    assert html =~ "1m ago"
  end

  test "refreshes the runner fleet without a page reload", %{conn: conn, org: org} do
    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/fin")

    assert html =~ "No runners connected"

    assert {:ok, provisioner} =
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

    send(view.pid, :refresh_fin_mac_minis)
    html = render(view)

    assert html =~ "Refresh Mac mini"
    assert html =~ "0 / 2"

    html = expand_runner(view, provisioner.id)
    assert html =~ "refresh-host"
  end

  test "onboards a runner inside Fin without exposing a durable token", %{
    conn: conn,
    org: org
  } do
    assert {:ok, %{token: other_token, api_key: other_key}} =
             Auth.create_api_key(org.id, %{
               "name" => "General automation key",
               "scopes" => ["projects:read"]
             })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/fin")

    refute html =~ ~s(id="fin-runner-onboarding")
    refute html =~ other_key.name
    refute html =~ "bft_"

    html =
      view
      |> element("#add-fin-runner")
      |> render_click()

    assert html =~ ~s(id="fin-runner-onboarding")
    assert html =~ ~s(id="runner-onboarding-manual")
    assert html =~ ~s(id="runner-onboarding-mode-manual")
    assert html =~ ~s(id="runner-onboarding-mode-agent")
    refute html =~ ~s(id="runner-onboarding-agent")
    assert html =~ "Install or update"
    assert html =~ "Check local posture"
    assert html =~ "Smoke in the foreground"
    assert html =~ "Make the runner persistent"
    assert html =~ "Advanced diagnostics"
    assert html =~ "~/.bridge-for-teams/runner.json"
    assert html =~ "~/.bridge-for-teams/runner-install-status.json"
    assert html =~ "~/.bridge-for-teams/state/runner-status.json"
    assert html =~ "~/.bridge-for-teams/state/logs"
    assert html =~ ~s(id="copy-mac-mini-local-step-foreground")
    assert html =~ ~s(phx-hook="CopyToClipboard")

    assert html =~ escaped_command(~s("$HOME/.bridge-for-teams/bin/bft-runner" doctor))
    assert html =~ escaped_command(~s("$HOME/.bridge-for-teams/bin/bft-runner"))

    assert html =~
             escaped_command(~s("$HOME/.bridge-for-teams/bin/bft-runner" service start))

    html = render_click(view, "revoke-mac-mini-runner-key", %{"id" => other_key.id})
    assert html =~ "Runner API key not found"
    assert {:ok, %{scopes: ["projects:read"]}} = Auth.authenticate_api_key(other_token)

    html =
      view
      |> element(~s(button[phx-click="create-mac-mini-runner-key"]))
      |> render_click()

    assert html =~ "Server release is unavailable"
    refute html =~ "code="
    refute html =~ "BFT_RUNNER_TOKEN"
    refute html =~ "bft_"

    assert [] =
             Enum.filter(
               Auth.list_api_keys(org.id),
               &("runners:write" in (&1.scopes || []))
             )

    html = render_click(view, "close-runner-onboarding")
    refute html =~ ~s(id="fin-runner-onboarding")
    refute html =~ "code="

    {:ok, _view, remounted_html} = live(conn, ~p"/orgs/#{org.slug}/fin")
    refute remounted_html =~ "bfti_"
  end

  test "hands runner onboarding to a local agent without minting credentials", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/fin")

    manual_html =
      view
      |> element("#add-fin-runner")
      |> render_click()

    assert manual_html =~ ~s(id="runner-onboarding-manual")
    refute manual_html =~ ~s(id="runner-onboarding-agent")
    assert Repo.aggregate(MacMiniInstallCode, :count, :id) == 0

    agent_html =
      render_click(view, "select-runner-onboarding-mode", %{"mode" => "agent"})

    assert agent_html =~ ~s(id="runner-onboarding-agent")
    refute agent_html =~ ~s(id="runner-onboarding-manual")
    assert agent_html =~ ~s(id="copy-bft-agent-handoff")
    assert agent_html =~ ~s(data-copy-target="#bft-agent-handoff")
    assert agent_html =~ ~s(id="copy-bft-agent-skill")
    assert agent_html =~ ~s(data-copy-target="#bft-agent-skill")
    assert agent_html =~ org.id
    assert agent_html =~ "http://localhost:4102"
    assert agent_html =~ "bft commands --json"
    assert agent_html =~ "bft agent help runners --json"
    assert agent_html =~ "--confirm-mutating"
    assert agent_html =~ "create exactly one runner install command"
    assert agent_html =~ "name: bft-operator"
    refute agent_html =~ "code="
    refute agent_html =~ "BFT_RUNNER_TOKEN"
    refute agent_html =~ "bfti_"
    assert Repo.aggregate(MacMiniInstallCode, :count, :id) == 0

    manual_html =
      render_click(view, "select-runner-onboarding-mode", %{"mode" => "manual"})

    assert manual_html =~ ~s(id="runner-onboarding-manual")
    refute manual_html =~ ~s(id="runner-onboarding-agent")
    assert manual_html =~ "Smoke in the foreground"
    assert Repo.aggregate(MacMiniInstallCode, :count, :id) == 0
  end

  test "removes a runner and revokes its bound API key", %{conn: conn, org: org, user: user} do
    {:ok, runner} = register_runner(org.id, "lab-mac-mini", "Lab Mac mini")
    %{token: token, api_key: api_key} = bind_runner_key(org.id, runner.stable_id)

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/fin")
    html = expand_runner(view, runner.id)
    assert html =~ "Access active"
    refute html =~ token

    html =
      view
      |> element(~s(button[phx-click="request-remove-runner"][phx-value-id="#{runner.id}"]))
      |> render_click()

    assert html =~ ~s(id="remove-runner-modal")
    assert html =~ "This does not remove local files from the host"

    html = render_click(view, "confirm-remove-runner")
    assert html =~ "Runner removed and its access revoked"
    refute html =~ "Lab Mac mini"
    assert {:error, :unauthenticated} = Auth.authenticate_api_key(token)
    assert {:error, :not_found} = Environments.get_mac_mini_provisioner(runner.id)

    assert [audit] = Observability.list_audit_logs(org.id, action: "api_key.revoked")
    assert audit.actor_user_id == user.id
    assert audit.resource_id == api_key.id
  end

  test "does not revoke a runner key when the Server release is unavailable", %{
    conn: conn,
    org: org,
    user: _user
  } do
    {:ok, runner} = register_runner(org.id, "lab-mac-mini", "Lab Mac mini")
    %{token: old_token, api_key: api_key} = bind_runner_key(org.id, runner.stable_id)

    {1, _} =
      Repo.update_all(
        from(k in ApiKey, where: k.id == ^api_key.id),
        set: [created_at: DateTime.add(DateTime.utc_now(), -91, :day)]
      )

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/fin")
    html = expand_runner(view, runner.id)
    assert html =~ "Access active"
    refute html =~ old_token

    html =
      view
      |> element(
        ~s(button[phx-click="rotate-mac-mini-runner-key"][phx-value-id="#{api_key.id}"][phx-value-stable-id="#{runner.stable_id}"])
      )
      |> render_click()

    refute html =~ "code="
    refute html =~ "BFT_RUNNER_TOKEN"
    refute html =~ "bft_"
    [old] = Auth.list_api_keys(org.id)
    assert old.id == api_key.id
    assert is_nil(old.revoked_at)
  end

  test "ordinary org members only see connector assignments for accessible Agent Swarms", %{
    conn: conn,
    org: org
  } do
    member = user_fixture(email: "fin-member@example.com")
    {:ok, _membership} = Memberships.put_org_member(org.id, member.id, "member")

    assert {:ok, runner} = register_runner(org.id, "member-runner", "Member Runner")

    assert {:ok, visible_project} =
             Projects.create_project(org.id, %{
               "name" => "Visible Agent Swarm",
               "slug" => "visible-agent-swarm"
             })

    assert {:ok, private_project} =
             Projects.create_project(org.id, %{
               "name" => "Private Agent Swarm",
               "slug" => "private-agent-swarm"
             })

    assert {:ok, visible_membership} =
             Memberships.put_project_member(visible_project.id, member.id, "user")

    assert {:ok, visible_request} =
             Environments.create_device_provision_request(visible_project.id, %{
               "provisioner_id" => runner.id,
               "name" => "Visible connector",
               "alias" => "visible-connector"
             })

    assert {:ok, private_request} =
             Environments.create_device_provision_request(private_project.id, %{
               "provisioner_id" => runner.id,
               "name" => "Private connector",
               "alias" => "private-connector"
             })

    conn = log_in_user(conn, member)
    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/fin")

    assert html =~ "Fin"
    assert html =~ "Member Runner"
    refute html =~ "Add runner"
    refute html =~ ~s(id="fin-runner-credentials")

    toggle_html = render(element(view, "#fin-runner-toggle-#{runner.id}"))
    assert toggle_html =~ "1 pending"
    refute toggle_html =~ "2 pending"

    runner_html = expand_runner(view, runner.id)
    assert runner_html =~ ~s(id="fin-runner-connector-#{visible_request.id}")
    assert runner_html =~ "visible-connector"
    assert runner_html =~ "Visible Agent Swarm"
    refute runner_html =~ private_request.id
    refute runner_html =~ "private-connector"
    refute runner_html =~ "Private Agent Swarm"

    Repo.delete!(visible_membership)
    send(view.pid, :refresh_fin_mac_minis)
    refreshed_html = render(view)
    assert refreshed_html =~ "No connectors assigned to this runner."
    refute refreshed_html =~ visible_request.id
    refute refreshed_html =~ "visible-connector"
    refute refreshed_html =~ "Visible Agent Swarm"
    refute refreshed_html =~ private_request.id
    refute refreshed_html =~ "Private Agent Swarm"

    html = render_click(view, "open-runner-onboarding")
    assert html =~ "Only organization admins can manage runners"
    refute html =~ ~s(id="fin-runner-onboarding")
  end

  test "renders the Fin runner management surface in Simplified Chinese", %{
    conn: conn,
    org: org,
    user: user
  } do
    assert {:ok, _user} = Accounts.update_locale(user, "zh_Hans")

    assert {:ok, runner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "zh-runner",
               "name" => "中文测试 Runner",
               "status" => "online"
             })

    assert {:ok, project} =
             Projects.create_project(org.id, %{
               "name" => "中文 Agent Swarm",
               "slug" => "zh-agent-swarm"
             })

    assert {:ok, _request} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => runner.id,
               "name" => "中文连接器",
               "alias" => "zh-connector"
             })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/fin")

    assert html =~ "管理为 #{org.name} 执行任务的 runner 集群"
    assert html =~ "Runner 列表"
    assert html =~ "1 个 runner"
    assert html =~ "显示 1 / 1 个 runner"
    assert html =~ "添加 runner"
    assert render(element(view, "#fin-runner-toggle-#{runner.id}")) =~ ~s(aria-expanded="false")

    html = expand_runner(view, runner.id)
    assert html =~ "无有效凭据"
    assert html =~ "连接器"
    assert html =~ "配置状态"
    assert html =~ "待处理"
    assert html =~ "zh-connector"
    refute html =~ "1 个已完成"
    refute html =~ "Add a runner to execute Fin workloads"

    panel_html =
      view
      |> element("#add-fin-runner")
      |> render_click()

    assert panel_html =~ "检查本机状态"
    assert panel_html =~ "检查状态与日志"
    refute panel_html =~ "Check local posture"
  end

  test "redirects users outside the org", %{conn: conn, org: org} do
    outsider = user_fixture(email: "fin-outsider@example.com")
    conn = log_in_user(conn, outsider)

    assert {:error, {:redirect, %{to: "/orgs"}}} = live(conn, ~p"/orgs/#{org.slug}/fin")
  end

  defp restore_env(key, nil), do: Application.delete_env(:bridge_for_teams_web, key)
  defp restore_env(key, value), do: Application.put_env(:bridge_for_teams_web, key, value)

  defp escaped_command(command) do
    command
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp expand_runner(view, runner_id) do
    view
    |> element("#fin-runner-toggle-#{runner_id}")
    |> render_click()
  end

  defp register_runner(org_id, stable_id, name) do
    Environments.register_mac_mini_provisioner(org_id, %{
      "stable_id" => stable_id,
      "name" => name,
      "status" => "online"
    })
  end

  defp bind_runner_key(org_id, stable_id) do
    {:ok, %{token: token, api_key: api_key}} =
      Auth.create_api_key(org_id, %{
        "name" => "#{stable_id} key",
        "scopes" => ["runners:write"]
      })

    now = DateTime.utc_now()

    {:ok, _install_code} =
      %MacMiniInstallCode{}
      |> MacMiniInstallCode.changeset(%{
        "org_id" => org_id,
        "api_key_id" => api_key.id,
        "code_hash" => Ecto.UUID.generate(),
        "server_build_id" => String.duplicate("a", 40),
        "audit_metadata" => %{"runner_stable_id" => stable_id},
        "expires_at" => DateTime.add(now, 900, :second),
        "consumed_at" => now
      })
      |> Repo.insert()

    %{token: token, api_key: api_key}
  end
end
