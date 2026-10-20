defmodule BridgeForTeamsWeb.DashboardAPIController do
  @moduledoc """
  JSON API for the React dashboard (`clients/apps/bft`).

  The SPA is served same-origin, so these endpoints use the browser session
  (`:dashboard_api` pipeline). Every org-scoped action resolves the org and the
  caller's membership first. A caller who is not a member gets the same 404 as
  an unknown slug, so the endpoint does not reveal which orgs exist.
  """
  use BridgeForTeamsWeb.Dashboard, :controller
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  import BridgeForTeamsWeb.ProjectAPIResponse, only: [send_ok: 2, send_ok: 3, send_error: 5]

  alias BridgeForTeams.{
    Accounts,
    Agents,
    Analytics,
    DashboardProjection,
    Environments,
    Memberships,
    Onboarding,
    Orgs,
    Projects,
    Sites
  }

  alias BridgeForTeamsWeb.{
    DashboardCLILogin,
    DashboardDataPolicy,
    DashboardHealth,
    DashboardMeetings,
    DashboardMembers,
    DashboardModelAccounts,
    DashboardOnboardingWizard,
    DashboardPlugins,
    DashboardProjects,
    DashboardRunners,
    DashboardSettings,
    DashboardSwarmAgents,
    DashboardSwarmConnections,
    DashboardSwarmDevices,
    DashboardSwarmPlugins,
    DashboardSwarmSettings,
    DashboardSwarmSkills,
    DashboardSwarmTaskDetail,
    DashboardSwarmTasks,
    DashboardTriage,
    JSON
  }

  # The Overview's Websites panel lists at most this many sites.
  @overview_site_limit 50

  @admin_roles ~w(owner admin)
  # Names of members waiting for an OAuth client that the Overview shows.
  @oauth_waiting_limit 5

  def session(conn, _params) do
    user = conn.assigns.current_user
    send_ok(conn, %{"user" => public_user(user), "orgs" => public_orgs(user)})
  end

  def context(conn, %{"org" => slug}) do
    user = conn.assigns.current_user

    with {:ok, org, role} <- member_org(slug, user) do
      admin? = role in @admin_roles

      send_ok(conn, %{
        "user" => public_user(user),
        "orgs" => public_orgs(user),
        "org" => %{"slug" => org.slug, "name" => org.name, "role" => role},
        "capabilities" => %{
          "operations" => admin?,
          "triage" => admin?,
          "information_flow" => admin?,
          "meetings" => admin?,
          "settings" => admin?
        },
        "projects" =>
          org.id
          |> Projects.list_projects_for_user(user.id)
          |> Enum.map(&%{"id" => &1.id, "name" => &1.name})
      })
    else
      :not_found -> org_not_found(conn)
    end
  end

  def overview(conn, %{"org" => slug}) do
    user = conn.assigns.current_user

    with {:ok, org, role} <- member_org(slug, user) do
      summary = Analytics.org_home_summary(org.id, user.id)
      runners = Environments.mac_mini_health_summary(org.id)
      projects = Enum.map(summary.project_usage_rows, &public_project_usage/1)

      send_ok(conn, %{
        "project_count" => summary.project_count,
        "used_project_count" => summary.used_project_count,
        "conversation_count" => summary.conversation_count,
        "token_totals" => summary.token_totals,
        "member_count" => Memberships.count_org_members(org.id),
        "runners" => %{"total" => runners.total, "online" => runners.online},
        "projects" => projects,
        "attention" => attention(org, summary.project_usage_rows, runners.unhealthy),
        "oauth_waiting" => oauth_waiting(org, role)
      })
    else
      :not_found -> org_not_found(conn)
    end
  end

  # ---- Quick setup checklist ----
  #
  # The Overview shows the steps of `BridgeForTeams.Onboarding`; it is the
  # only checklist.
  # `active: false` once the user skipped or finished it.

  def onboarding(conn, %{"org" => slug}),
    do: org_action(conn, slug, 200, &{:ok, public_onboarding(&1, &2, &3)})

  @doc "Skips the checklist for good, or acknowledges it when every step is done."
  def dismiss_onboarding(conn, %{"org" => slug}) do
    org_action(conn, slug, 200, fn org, user, role ->
      {:ok, _state} =
        if Onboarding.snapshot(org, user.id, role).all_done?,
          do: Onboarding.celebrate(org.id, user.id),
          else: Onboarding.dismiss(org.id, user.id)

      {:ok, public_onboarding(org, user, role)}
    end)
  end

  @doc """
  A member whose connect step waits for an OAuth client asks the org admins to
  configure one. Idempotent; admins configure it themselves.
  """
  def remind_onboarding_admins(conn, %{"org" => slug}) do
    org_action(conn, slug, 200, fn org, user, role ->
      if role == "member" do
        case Onboarding.remind_admins(org.id, user.id) do
          {:ok, _state} ->
            {:ok, public_onboarding(org, user, role)}

          {:error, _reason} ->
            {:error, 500, "write_failed", gettext("Could not remind the admins. Try again."), %{}}
        end
      else
        {:error, 403, "forbidden",
         gettext("Admins configure OAuth clients in Settings → Integrations."), %{}}
      end
    end)
  end

  defp public_onboarding(org, user, role) do
    state = Onboarding.get_state(org.id, user.id)

    if Onboarding.steps_for_role(role) == [] or not is_nil(state.dismissed_at) or
         not is_nil(state.celebrated_at) do
      %{
        "active" => false,
        "steps" => [],
        "first_project_id" => nil,
        "oauth_configured" => nil,
        "oauth_reminded" => false
      }
    else
      snapshot = Onboarding.snapshot(org, user.id, role, state: state)

      %{
        "active" => true,
        "steps" =>
          for(step <- snapshot.steps, do: %{"id" => step, "done" => snapshot.done[step] == true}),
        "first_project_id" => snapshot.first_project && snapshot.first_project.id,
        # A member's connect step waits for an admin's OAuth client.
        "oauth_configured" => snapshot.oauth_configured,
        "oauth_reminded" => not is_nil(state.oauth_reminded_at)
      }
    end
  end

  def health(conn, %{"org" => slug}) do
    with {:ok, org} <- admin_org(slug, conn.assigns.current_user) do
      send_ok(conn, DashboardHealth.health(org))
    else
      :not_found -> org_not_found(conn)
    end
  end

  def audit(conn, %{"org" => slug} = params) do
    with {:ok, org} <- admin_org(slug, conn.assigns.current_user) do
      cursor = if is_binary(params["cursor"]), do: params["cursor"]
      send_ok(conn, DashboardHealth.audit_page(org, cursor))
    else
      :not_found -> org_not_found(conn)
    end
  end

  def project_overview(conn, %{"org" => slug, "id" => id}) do
    swarm_action(conn, slug, id, fn org, _user, project, role ->
      snapshot = DashboardProjection.snapshot_for_project(project.id)

      {:ok,
       %{
         "project" => %{
           "id" => project.id,
           "name" => project.name,
           "slug" => project.slug,
           "status" => project.status,
           "created_at" => project.created_at,
           "created_by" => creator_label(project.created_by_user_id),
           "role" => role
         },
         "usage" => project_usage(snapshot),
         "recent_conversations" => recent_conversations(org, project, snapshot),
         "connected_providers" => (snapshot && snapshot.connected_providers) || [],
         "agents" => overview_agents(project)
       }}
    end)
  end

  @doc """
  The Overview's Websites panel, loaded apart from the Overview because it
  reads every agent's sites from Salix (bounded fan-out, cached for 45 s).
  """
  def project_websites(conn, %{"org" => slug, "id" => id}) do
    swarm_action(conn, slug, id, fn org, _user, project, _role ->
      {:ok,
       case Sites.list_project_sites(project, cache: true) do
         {:ok, sites} ->
           %{
             "status" => "ok",
             "items" =>
               sites
               |> Enum.take(@overview_site_limit)
               |> Enum.map(&public_site(org, project, &1)),
             "total" => length(sites)
           }

         {:error, _reason} ->
           %{"status" => "unavailable", "items" => [], "total" => 0}
       end}
    end)
  end

  defp public_site(org, project, site) do
    %{
      "name" => site["name"],
      "url" => text_or_nil(site["url"]),
      "agent_name" => site["agent_name"],
      "agent_href" => "/orgs/#{org.slug}/projects/#{project.id}/agents/#{site["agent_id"]}"
    }
  end

  # ---- Agent Swarm Agents, Devices, Plugins, Skills, Tasks and Settings (swarm members read; swarm admins write) ----

  def project_agents(conn, %{"org" => slug, "id" => id} = params),
    do:
      swarm_action(conn, slug, id, fn org, _user, project, role ->
        DashboardSwarmAgents.page(org, project, role, params)
      end)

  def create_project_agent(conn, %{"org" => slug, "id" => id} = params),
    do: swarm_action(conn, slug, id, 201, &DashboardSwarmAgents.create(&1, &2, &3, &4, params))

  def project_agent_targets(conn, %{"org" => slug, "id" => id}),
    do:
      swarm_action(conn, slug, id, fn _org, _user, project, role ->
        DashboardSwarmAgents.targets(project, role)
      end)

  def project_agent(conn, %{"org" => slug, "id" => id, "agent_id" => agent}),
    do:
      swarm_action(conn, slug, id, fn org, _user, project, role ->
        DashboardSwarmAgents.show(org, project, role, agent)
      end)

  def project_agent_config(conn, %{"org" => slug, "id" => id, "agent_id" => agent}),
    do:
      swarm_action(conn, slug, id, fn org, _user, project, role ->
        DashboardSwarmAgents.config(org, project, role, agent)
      end)

  def configure_project_agent(conn, %{"org" => slug, "id" => id, "agent_id" => agent} = params),
    do:
      swarm_action(
        conn,
        slug,
        id,
        &DashboardSwarmAgents.configure(&1, &2, &3, &4, agent, params)
      )

  def rebind_project_agent(conn, %{"org" => slug, "id" => id, "agent_id" => agent} = params),
    do: swarm_action(conn, slug, id, &DashboardSwarmAgents.rebind(&1, &2, &3, &4, agent, params))

  def archive_project_agent(conn, %{"org" => slug, "id" => id, "agent_id" => agent} = params),
    do: swarm_action(conn, slug, id, &DashboardSwarmAgents.archive(&1, &2, &3, &4, agent, params))

  def switch_project_agent_session(
        conn,
        %{"org" => slug, "id" => id, "agent_id" => agent} = params
      ),
      do:
        swarm_action(
          conn,
          slug,
          id,
          &DashboardSwarmAgents.switch_router_session(&1, &2, &3, &4, agent, params)
        )

  def project_devices(conn, %{"org" => slug, "id" => id}),
    do: swarm_action(conn, slug, id, &DashboardSwarmDevices.page/4)

  def project_device_provisioning(conn, %{"org" => slug, "id" => id}),
    do:
      swarm_action(conn, slug, id, fn _org, _user, project, _role ->
        DashboardSwarmDevices.provisioning(project)
      end)

  def project_device_runners(conn, %{"org" => slug, "id" => id}),
    do:
      swarm_action(conn, slug, id, fn org, _user, _project, role ->
        DashboardSwarmDevices.runners(org, role)
      end)

  def create_project_device(conn, %{"org" => slug, "id" => id} = params),
    do: swarm_action(conn, slug, id, 201, &DashboardSwarmDevices.create(&1, &2, &3, &4, params))

  def set_project_cloud_computer(conn, %{"org" => slug, "id" => id} = params),
    do: swarm_action(conn, slug, id, &DashboardSwarmDevices.set_cloud(&1, &2, &3, &4, params))

  def set_project_cloud_vm_runner(conn, %{"org" => slug, "id" => id} = params),
    do: swarm_action(conn, slug, id, &DashboardSwarmDevices.choose_runner(&1, &2, &3, &4, params))

  def remove_project_cloud_vm_runner(conn, %{"org" => slug, "id" => id}),
    do: swarm_action(conn, slug, id, &DashboardSwarmDevices.remove_runner/4)

  def disconnect_project_device(conn, %{"org" => slug, "id" => id, "device_id" => device}),
    do: swarm_action(conn, slug, id, &DashboardSwarmDevices.disconnect(&1, &2, &3, &4, device))

  def delete_project_device(conn, %{"org" => slug, "id" => id, "device_id" => device}),
    do: swarm_action(conn, slug, id, &DashboardSwarmDevices.delete(&1, &2, &3, &4, device))

  def create_project_shell_workload(
        conn,
        %{"org" => slug, "id" => id, "environment_id" => environment}
      ),
      do:
        swarm_action(
          conn,
          slug,
          id,
          201,
          &DashboardSwarmDevices.create_shell(&1, &2, &3, &4, environment)
        )

  def drain_project_environment(conn, params), do: environment_intent(conn, params, :drain)
  def revoke_project_environment(conn, params), do: environment_intent(conn, params, :revoke)

  defp environment_intent(
         conn,
         %{"org" => slug, "id" => id, "environment_id" => environment} = params,
         intent
       ),
       do:
         swarm_action(
           conn,
           slug,
           id,
           &DashboardSwarmDevices.environment_intent(&1, &2, &3, &4, environment, intent, params)
         )

  def project_plugins(conn, %{"org" => slug, "id" => id}),
    do:
      swarm_action(conn, slug, id, fn org, user, project, role ->
        DashboardSwarmPlugins.page(org, user, project, role)
      end)

  def project_plugin(conn, %{"org" => slug, "id" => id, "plugin_id" => plugin}),
    do:
      swarm_action(conn, slug, id, fn org, user, project, role ->
        DashboardSwarmPlugins.show(org, user, project, role, plugin)
      end)

  def create_project_plugin(conn, %{"org" => slug, "id" => id} = params),
    do: swarm_action(conn, slug, id, 201, &DashboardSwarmPlugins.create(&1, &2, &3, &4, params))

  def update_project_plugin(conn, %{"org" => slug, "id" => id, "plugin_id" => plugin} = params),
    do:
      swarm_action(conn, slug, id, &DashboardSwarmPlugins.update(&1, &2, &3, &4, plugin, params))

  def set_project_plugin_enablement(
        conn,
        %{"org" => slug, "id" => id, "plugin_id" => plugin} = params
      ),
      do:
        swarm_action(
          conn,
          slug,
          id,
          &DashboardSwarmPlugins.set_enabled(&1, &2, &3, &4, plugin, params)
        )

  # The provider sends the browser back to the plugin page on this origin.
  def connect_project_plugin(
        conn,
        %{"org" => slug, "id" => id, "plugin_id" => plugin, "connection_id" => connection} =
          params
      ) do
    base_url = dashboard_base_url(conn)

    swarm_action(
      conn,
      slug,
      id,
      &DashboardSwarmPlugins.connect(&1, &2, &3, &4, plugin, connection, base_url, params)
    )
  end

  def disconnect_project_plugin(
        conn,
        %{"org" => slug, "id" => id, "plugin_id" => plugin, "connection_id" => connection}
      ),
      do:
        swarm_action(
          conn,
          slug,
          id,
          &DashboardSwarmPlugins.disconnect(&1, &2, &3, &4, plugin, connection)
        )

  def project_connections(conn, %{"org" => slug, "id" => id}),
    do: swarm_action(conn, slug, id, &DashboardSwarmConnections.page/4)

  def project_slack_manifest(conn, %{"org" => slug, "id" => id} = params),
    do:
      swarm_action(conn, slug, id, fn _org, _user, _project, _role ->
        DashboardSwarmConnections.slack_manifest(params)
      end)

  def create_project_feishu_connect(conn, %{"org" => slug, "id" => id} = params),
    do:
      swarm_action(
        conn,
        slug,
        id,
        201,
        &DashboardSwarmConnections.create_feishu(&1, &2, &3, &4, params)
      )

  def create_project_lark_connect(conn, %{"org" => slug, "id" => id} = params),
    do:
      swarm_action(
        conn,
        slug,
        id,
        201,
        &DashboardSwarmConnections.create_lark(&1, &2, &3, &4, params)
      )

  def create_project_qq_connect(conn, %{"org" => slug, "id" => id} = params),
    do:
      swarm_action(
        conn,
        slug,
        id,
        201,
        &DashboardSwarmConnections.create_qq(&1, &2, &3, &4, params)
      )

  def update_project_qq_command_menu(
        conn,
        %{"org" => slug, "id" => id, "connect_id" => connect} = params
      ),
      do:
        swarm_action(
          conn,
          slug,
          id,
          &DashboardSwarmConnections.update_qq_menu(&1, &2, &3, &4, connect, params)
        )

  def create_project_slack_connect(conn, %{"org" => slug, "id" => id} = params),
    do:
      swarm_action(
        conn,
        slug,
        id,
        201,
        &DashboardSwarmConnections.create_slack(&1, &2, &3, &4, params)
      )

  def set_project_im_connect_enablement(
        conn,
        %{"org" => slug, "id" => id, "connect_id" => connect} = params
      ),
      do:
        swarm_action(
          conn,
          slug,
          id,
          &DashboardSwarmConnections.set_im_enabled(&1, &2, &3, &4, connect, params)
        )

  def delete_project_im_connect(conn, %{"org" => slug, "id" => id, "connect_id" => connect}),
    do:
      swarm_action(conn, slug, id, &DashboardSwarmConnections.delete_im(&1, &2, &3, &4, connect))

  def run_project_feishu_checks(conn, %{"org" => slug, "id" => id}),
    do: swarm_action(conn, slug, id, &DashboardSwarmConnections.run_feishu_checks/4)

  def run_project_lark_checks(conn, %{"org" => slug, "id" => id, "connect_id" => connect}),
    do:
      swarm_action(
        conn,
        slug,
        id,
        &DashboardSwarmConnections.run_lark_checks(&1, &2, &3, &4, connect)
      )

  def run_project_slack_checks(conn, %{"org" => slug, "id" => id, "connect_id" => connect}),
    do:
      swarm_action(
        conn,
        slug,
        id,
        &DashboardSwarmConnections.run_slack_checks(&1, &2, &3, &4, connect)
      )

  def create_project_signal_claim(conn, %{"org" => slug, "id" => id}),
    do: swarm_action(conn, slug, id, 201, &DashboardSwarmConnections.create_signal_claim/4)

  def remove_project_signal_binding(
        conn,
        %{"org" => slug, "id" => id, "binding_id" => binding}
      ),
      do:
        swarm_action(
          conn,
          slug,
          id,
          &DashboardSwarmConnections.remove_signal_binding(&1, &2, &3, &4, binding)
        )

  # The provider sends the browser back to the Connections page on this origin.
  def connect_project_tailnet(conn, %{"org" => slug, "id" => id} = params),
    do:
      swarm_action(
        conn,
        slug,
        id,
        &DashboardSwarmConnections.connect_tailnet(&1, &2, &3, &4, params)
      )

  def disconnect_project_tailnet(conn, %{"org" => slug, "id" => id}),
    do: swarm_action(conn, slug, id, &DashboardSwarmConnections.disconnect_tailnet/4)

  def connect_project_account(conn, %{"org" => slug, "id" => id} = params) do
    base_url = dashboard_base_url(conn)

    swarm_action(
      conn,
      slug,
      id,
      &DashboardSwarmConnections.connect_account(&1, &2, &3, &4, params, base_url)
    )
  end

  def set_project_account_enablement(
        conn,
        %{"org" => slug, "id" => id, "binding_id" => binding} = params
      ),
      do:
        swarm_action(
          conn,
          slug,
          id,
          &DashboardSwarmConnections.set_account_enabled(&1, &2, &3, &4, binding, params)
        )

  def delete_project_account(conn, %{"org" => slug, "id" => id, "binding_id" => binding}),
    do:
      swarm_action(
        conn,
        slug,
        id,
        &DashboardSwarmConnections.delete_account(&1, &2, &3, &4, binding)
      )

  def connect_project_composio(conn, %{"org" => slug, "id" => id, "toolkit" => toolkit}) do
    base_url = dashboard_base_url(conn)

    swarm_action(
      conn,
      slug,
      id,
      &DashboardSwarmConnections.connect_composio(&1, &2, &3, &4, toolkit, base_url)
    )
  end

  def delete_project_composio(conn, %{"org" => slug, "id" => id, "account_id" => account}),
    do:
      swarm_action(
        conn,
        slug,
        id,
        &DashboardSwarmConnections.delete_composio(&1, &2, &3, &4, account)
      )

  def project_skills(conn, %{"org" => slug, "id" => id}),
    do:
      swarm_action(conn, slug, id, fn org, _user, project, role ->
        DashboardSwarmSkills.page(org, project, role)
      end)

  def project_skill(conn, %{"org" => slug, "id" => id, "skill_id" => skill}),
    do:
      swarm_action(conn, slug, id, fn org, _user, project, _role ->
        DashboardSwarmSkills.show(org, project, skill)
      end)

  def create_project_skill(conn, %{"org" => slug, "id" => id} = params),
    do: swarm_action(conn, slug, id, 201, &DashboardSwarmSkills.create(&1, &2, &3, &4, params))

  def upload_project_skill(conn, %{"org" => slug, "id" => id} = params),
    do: swarm_action(conn, slug, id, 201, &DashboardSwarmSkills.upload(&1, &2, &3, &4, params))

  def delete_project_skill(conn, %{"org" => slug, "id" => id, "skill_id" => skill}),
    do: swarm_action(conn, slug, id, &DashboardSwarmSkills.delete(&1, &2, &3, &4, skill))

  def project_tasks(conn, %{"org" => slug, "id" => id} = params),
    do:
      swarm_action(conn, slug, id, fn org, _user, project, role ->
        DashboardSwarmTasks.page(org, project, role, params)
      end)

  def create_project_task(conn, %{"org" => slug, "id" => id} = params),
    do: swarm_action(conn, slug, id, 201, &DashboardSwarmTasks.create(&1, &2, &3, &4, params))

  def project_task_targets(conn, %{"org" => slug, "id" => id}),
    do:
      swarm_action(conn, slug, id, fn org, _user, project, role ->
        DashboardSwarmTasks.targets(org, project, role)
      end)

  # ---- Task detail ----

  def project_task(conn, %{"org" => slug, "id" => id, "task_id" => task}),
    do:
      swarm_action(conn, slug, id, fn org, _user, project, role ->
        DashboardSwarmTaskDetail.show(org, project, role, task)
      end)

  def project_task_messages(conn, %{"org" => slug, "id" => id, "task_id" => task} = params),
    do:
      swarm_action(conn, slug, id, fn org, _user, project, _role ->
        DashboardSwarmTaskDetail.messages(org, project, task, params)
      end)

  def send_project_task_message(conn, %{"org" => slug, "id" => id, "task_id" => task} = params),
    do:
      swarm_action(
        conn,
        slug,
        id,
        201,
        &DashboardSwarmTaskDetail.send_message(&1, &2, &3, &4, task, params)
      )

  def accept_project_task_review(
        conn,
        %{"org" => slug, "id" => id, "task_id" => task} = params
      ),
      do:
        swarm_action(
          conn,
          slug,
          id,
          &DashboardSwarmTaskDetail.accept_review(&1, &2, &3, &4, task, params)
        )

  def put_project_task_schedule(conn, %{"org" => slug, "id" => id, "task_id" => task} = params),
    do:
      swarm_action(
        conn,
        slug,
        id,
        &DashboardSwarmTaskDetail.put_schedule(&1, &2, &3, &4, task, params)
      )

  def delete_project_task_schedule(conn, %{"org" => slug, "id" => id, "task_id" => task}),
    do:
      swarm_action(
        conn,
        slug,
        id,
        &DashboardSwarmTaskDetail.delete_schedule(&1, &2, &3, &4, task)
      )

  def preview_project_task_schedule(conn, %{"org" => slug, "id" => id} = params),
    do:
      swarm_action(conn, slug, id, fn _org, _user, _project, _role ->
        DashboardSwarmTaskDetail.preview_schedule(params)
      end)

  def project_schedules(conn, %{"org" => slug, "id" => id}),
    do:
      swarm_action(conn, slug, id, fn org, _user, project, role ->
        DashboardSwarmTasks.schedules(org, project, role)
      end)

  def delete_project_schedule(conn, %{"org" => slug, "id" => id, "schedule_id" => schedule}),
    do:
      swarm_action(conn, slug, id, &DashboardSwarmTasks.delete_schedule(&1, &2, &3, &4, schedule))

  def project_settings(conn, %{"org" => slug, "id" => id}),
    do:
      swarm_action(conn, slug, id, fn org, _user, project, role ->
        DashboardSwarmSettings.page(org, project, role)
      end)

  def update_project_settings(conn, %{"org" => slug, "id" => id} = params),
    do: swarm_action(conn, slug, id, &DashboardSwarmSettings.rename(&1, &2, &3, &4, params))

  def put_project_task_model(conn, %{"org" => slug, "id" => id} = params),
    do:
      swarm_action(conn, slug, id, &DashboardSwarmSettings.set_task_model(&1, &2, &3, &4, params))

  def put_project_task_place(conn, %{"org" => slug, "id" => id} = params),
    do:
      swarm_action(conn, slug, id, &DashboardSwarmSettings.set_task_place(&1, &2, &3, &4, params))

  def delete_project_task_model(conn, %{"org" => slug, "id" => id}),
    do: swarm_action(conn, slug, id, &DashboardSwarmSettings.clear_task_model(&1, &2, &3, &4))

  def archive_project(conn, %{"org" => slug, "id" => id}),
    do: swarm_action(conn, slug, id, &DashboardSwarmSettings.archive(&1, &2, &3, &4))

  def project_access(conn, %{"org" => slug, "id" => id} = params),
    do:
      swarm_action(conn, slug, id, fn _org, _user, project, _role ->
        DashboardSwarmSettings.access(project, params)
      end)

  def grant_project_access(conn, %{"org" => slug, "id" => id} = params),
    do: swarm_action(conn, slug, id, &DashboardSwarmSettings.grant(&1, &2, &3, &4, params))

  def update_project_access(conn, %{"org" => slug, "id" => id, "user_id" => target} = params),
    do:
      swarm_action(
        conn,
        slug,
        id,
        &DashboardSwarmSettings.change_role(&1, &2, &3, &4, target, params)
      )

  def remove_project_access(conn, %{"org" => slug, "id" => id, "user_id" => target}),
    do: swarm_action(conn, slug, id, &DashboardSwarmSettings.remove(&1, &2, &3, &4, target))

  # A read or write inside one Agent Swarm the caller can see; anyone else gets
  # the same 404 as an unknown swarm.
  defp swarm_action(conn, slug, project_id, status \\ 200, action) do
    user = conn.assigns.current_user

    with {:ok, org, _org_role} <- member_org(slug, user),
         {:ok, project, role} <- visible_project(org, project_id, user),
         {:ok, data} <- action.(org, user, project, role) do
      send_ok(conn, data, status)
    else
      :not_found -> org_not_found(conn)
      :project_not_found -> project_not_found(conn)
      {:error, status, code, message, details} -> send_error(conn, status, code, message, details)
    end
  end

  # ---- Agent Swarms ----

  def projects(conn, %{"org" => slug} = params) do
    user = conn.assigns.current_user

    with {:ok, org, _role} <- member_org(slug, user) do
      send_ok(conn, DashboardProjects.page(org, user, params))
    else
      :not_found -> org_not_found(conn)
    end
  end

  def create_project(conn, %{"org" => slug} = params) do
    org_action(conn, slug, 201, fn org, user, _role ->
      DashboardProjects.create(org, user, params)
    end)
  end

  # ---- Plugins ----

  def plugins(conn, %{"org" => slug}),
    do: org_action(conn, slug, 200, &DashboardPlugins.page/3)

  def create_plugin(conn, %{"org" => slug} = params) do
    org_action(conn, slug, 201, &DashboardPlugins.create(&1, &2, &3, params))
  end

  def update_plugin(conn, %{"org" => slug, "plugin_id" => plugin_id} = params) do
    org_action(conn, slug, 200, &DashboardPlugins.update(&1, &2, &3, plugin_id, params))
  end

  # ---- Meetings and Data policy (owner/admin; members get the non-member 404) ----

  def meetings(conn, %{"org" => slug, "project_id" => id}),
    do: admin_action(conn, slug, &DashboardMeetings.overview(&1, &2, id))

  def meetings_read(conn, %{"org" => slug, "project_id" => id, "read" => read} = params),
    do: admin_action(conn, slug, &DashboardMeetings.read(&1, &2, id, read, params))

  def save_meetings(conn, %{"org" => slug, "project_id" => id} = params),
    do: admin_action(conn, slug, &DashboardMeetings.save(&1, &2, id, params))

  def data_policy(conn, %{"org" => slug, "project_id" => id}),
    do: admin_action(conn, slug, fn org, _user -> DashboardDataPolicy.overview(org, id) end)

  def update_data_policy(conn, params), do: data_policy_change(conn, params, :group)
  def classify_data_policy_scope(conn, params), do: data_policy_change(conn, params, :classify)
  def reset_data_policy_scope(conn, params), do: data_policy_change(conn, params, :reset)
  def grant_data_policy_clearance(conn, params), do: data_policy_change(conn, params, :grant)

  def withdraw_data_policy_clearance(conn, params),
    do: data_policy_change(conn, params, :withdraw)

  def place_data_policy_principal(conn, params), do: data_policy_change(conn, params, :place)

  defp data_policy_change(conn, %{"org" => slug, "project_id" => id} = params, change) do
    admin_action(conn, slug, fn org, _user ->
      DashboardDataPolicy.change(org, id, change, params)
    end)
  end

  # ---- Slack triage (owner/admin; members get the non-member 404) ----

  def triage(conn, %{"org" => slug}),
    do: admin_action(conn, slug, fn org, _user -> DashboardTriage.overview(org) end)

  def triage_evaluation(conn, %{"org" => slug} = params),
    do: admin_action(conn, slug, fn org, _user -> DashboardTriage.evaluation(org, params) end)

  def triage_channels(conn, %{"org" => slug} = params),
    do: admin_action(conn, slug, fn org, _user -> DashboardTriage.channels(org, params) end)

  def set_triage_source(conn, %{"org" => slug, "connect_id" => id} = params),
    do: admin_action(conn, slug, &DashboardTriage.set_source(&1, &2, id, params))

  def set_triage_channel(
        conn,
        %{"org" => slug, "connect_id" => id, "channel_id" => channel} = params
      ),
      do: admin_action(conn, slug, &DashboardTriage.set_channel(&1, &2, id, channel, params))

  def add_triage_channels(conn, %{"org" => slug, "connect_id" => id} = params),
    do: admin_action(conn, slug, &DashboardTriage.add_channels(&1, &2, id, params))

  def triage_worker(conn, %{"org" => slug} = params),
    do: admin_action(conn, slug, &DashboardTriage.worker(&1, &2, params))

  def save_triage_worker(conn, %{"org" => slug} = params),
    do: admin_action(conn, slug, &DashboardTriage.save_worker(&1, &2, params))

  def triage_activity(conn, %{"org" => slug} = params),
    do: admin_action(conn, slug, fn org, _user -> DashboardTriage.activity(org, params) end)

  def reveal_triage_text(conn, %{"org" => slug} = params),
    do: admin_action(conn, slug, &DashboardTriage.reveal(&1, &2, params))

  def triage_heatmap(conn, %{"org" => slug} = params),
    do: admin_action(conn, slug, fn org, _user -> DashboardTriage.heatmap(org, params) end)

  def triage_processing(conn, %{"org" => slug} = params),
    do: admin_action(conn, slug, fn org, _user -> DashboardTriage.processing(org, params) end)

  def triage_delegation(conn, %{"org" => slug} = params),
    do: admin_action(conn, slug, &DashboardTriage.delegation(&1, &2, params))

  def triage_knowledge(conn, %{"org" => slug} = params),
    do: admin_action(conn, slug, &DashboardTriage.knowledge(&1, &2, params))

  defp admin_action(conn, slug, action) do
    user = conn.assigns.current_user

    with {:ok, org} <- admin_org(slug, user),
         {:ok, data} <- action.(org, user) do
      send_ok(conn, data)
    else
      :not_found -> org_not_found(conn)
      {:error, status, code, message, details} -> send_error(conn, status, code, message, details)
    end
  end

  # A member-scoped read or write whose helper answers `{:ok, data}` or an error tuple.
  defp org_action(conn, slug, status, action) do
    user = conn.assigns.current_user

    with {:ok, org, role} <- member_org(slug, user),
         {:ok, data} <- action.(org, user, role) do
      send_ok(conn, data, status)
    else
      :not_found -> org_not_found(conn)
      {:error, status, code, message, details} -> send_error(conn, status, code, message, details)
    end
  end

  # ---- Members ----

  def members(conn, %{"org" => slug}) do
    user = conn.assigns.current_user

    with {:ok, org, role} <- member_org(slug, user) do
      send_members(conn, org, user, role)
    else
      :not_found -> org_not_found(conn)
    end
  end

  def invite_member(conn, %{"org" => slug} = params) do
    member_write(conn, slug, &DashboardMembers.invite(&1, &2, &3, params))
  end

  def update_member(conn, %{"org" => slug, "user_id" => target} = params) do
    member_write(conn, slug, &DashboardMembers.change_role(&1, &2, &3, target, params))
  end

  def remove_member(conn, %{"org" => slug, "user_id" => target}) do
    member_write(conn, slug, &DashboardMembers.remove(&1, &2, &3, target))
  end

  defp member_write(conn, slug, write) do
    user = conn.assigns.current_user

    with {:ok, org, role} <- member_org(slug, user),
         :ok <- write.(org, user, role) do
      send_members(conn, org, user, role)
    else
      :not_found -> org_not_found(conn)
      {:error, status, code, message, details} -> send_error(conn, status, code, message, details)
    end
  end

  # Member ids are the payload here, so skip the generic `user_id` redaction.
  defp send_members(conn, org, user, role),
    do: JSON.send_json(conn, %{"ok" => true, "data" => DashboardMembers.page(org, user, role)})

  # ---- Runners ----

  def runners(conn, %{"org" => slug} = params) do
    user = conn.assigns.current_user

    with {:ok, org, role} <- member_org(slug, user) do
      send_ok(conn, DashboardRunners.page(org, user, role in @admin_roles, params["cursor"]))
    else
      :not_found -> org_not_found(conn)
    end
  end

  def runner_connectors(conn, %{"org" => slug, "id" => runner_id} = params) do
    user = conn.assigns.current_user

    with {:ok, org, _role} <- member_org(slug, user),
         {:ok, data} <- DashboardRunners.connectors(org, user, runner_id, params["cursor"]) do
      send_ok(conn, data)
    else
      :not_found -> org_not_found(conn)
      {:error, status, code, message, details} -> send_error(conn, status, code, message, details)
    end
  end

  def runner_onboarding(conn, %{"org" => slug}) do
    runner_admin(conn, slug, fn org, _user -> {:ok, DashboardRunners.onboarding(org)} end)
  end

  def create_runner_install_command(conn, %{"org" => slug}) do
    runner_admin(conn, slug, &DashboardRunners.create_install_command/2, 201)
  end

  def revoke_runner_key(conn, %{"org" => slug, "id" => key_id}) do
    runner_admin(conn, slug, &DashboardRunners.revoke_key(&1, &2, key_id))
  end

  def rotate_runner_key(conn, %{"org" => slug, "id" => key_id}) do
    runner_admin(conn, slug, &DashboardRunners.rotate_key(&1, &2, key_id), 201)
  end

  def remove_runner(conn, %{"org" => slug, "id" => runner_id}) do
    runner_admin(conn, slug, &DashboardRunners.remove(&1, &2, runner_id))
  end

  defp runner_admin(conn, slug, action, status \\ 200) do
    user = conn.assigns.current_user

    with {:ok, org, role} <- member_org(slug, user),
         :ok <- require_runner_admin(role),
         {:ok, data} <- action.(org, user) do
      send_ok(conn, data, status)
    else
      :not_found -> org_not_found(conn)
      {:error, status, code, message, details} -> send_error(conn, status, code, message, details)
    end
  end

  defp require_runner_admin(role) when role in @admin_roles, do: :ok

  defp require_runner_admin(_role),
    do: {:error, 403, "forbidden", gettext("Only organization admins can manage runners."), %{}}

  # ---- Settings (owner/admin) ----

  def settings_general(conn, %{"org" => slug}),
    do: settings_read(conn, slug, &DashboardSettings.general/2)

  def update_settings_general(conn, %{"org" => slug} = params) do
    settings_write(conn, slug, "org.settings.updated", fn org, user ->
      DashboardSettings.update_general(org, user, params)
    end)
  end

  def revoke_settings_cli_session(conn, %{"org" => slug, "id" => session_id}) do
    settings_write(conn, slug, "cli_session.revoked", fn _org, user ->
      DashboardSettings.revoke_cli_session(user, session_id)
    end)
  end

  def settings_models(conn, %{"org" => slug}),
    do: settings_read(conn, slug, fn org, _user -> DashboardSettings.models(org) end)

  def update_settings_models(conn, %{"org" => slug} = params) do
    settings_write(conn, slug, "org.model_settings.updated", fn org, user ->
      DashboardSettings.update_models(org, user, params)
    end)
  end

  # ---- AI models: organization accounts ----

  def model_accounts(conn, %{"org" => slug} = params) do
    settings_read(conn, slug, fn org, user ->
      DashboardModelAccounts.accounts(org, user, params["cursor"])
    end)
  end

  def create_model_account(conn, %{"org" => slug} = params) do
    settings_write(conn, slug, "model_account.created", fn org, user ->
      DashboardModelAccounts.create_account(org, user, params)
    end)
  end

  def update_model_account(conn, %{"org" => slug, "id" => id} = params) do
    settings_write(conn, slug, "model_account.updated", fn org, user ->
      DashboardModelAccounts.update_account(org, user, id, params)
    end)
  end

  def delete_model_account(conn, %{"org" => slug, "id" => id} = params) do
    settings_write(conn, slug, "model_account.deleted", fn org, user ->
      DashboardModelAccounts.delete_account(org, user, id, params)
    end)
  end

  def refresh_model_account_quota(conn, %{"org" => slug, "id" => id} = params) do
    settings_write(conn, slug, "model_account.quota_refreshed", fn org, user ->
      DashboardModelAccounts.refresh_quota(org, user, id, params)
    end)
  end

  def reset_model_account_quota(conn, %{"org" => slug, "id" => id} = params) do
    settings_write(conn, slug, "model_account.quota_reset", fn org, user ->
      DashboardModelAccounts.reset_quota(org, user, id, params)
    end)
  end

  def model_account_usage(conn, %{"org" => slug, "id" => id} = params) do
    settings_read(conn, slug, fn org, user ->
      DashboardModelAccounts.account_usage(org, user, id, params["cursor"])
    end)
  end

  def begin_model_account_oauth(conn, %{"org" => slug} = params) do
    settings_write(conn, slug, "model_account.authorized", fn org, user ->
      DashboardModelAccounts.begin_oauth(org, user, params)
    end)
  end

  def complete_model_account_oauth(conn, %{"org" => slug, "attempt_id" => id} = params) do
    settings_write(conn, slug, "model_account.authorized", fn org, user ->
      DashboardModelAccounts.complete_oauth(org, user, id, params)
    end)
  end

  def settings_sso(conn, %{"org" => slug}),
    do: settings_read(conn, slug, fn org, _user -> DashboardSettings.sso(org) end)

  def update_settings_sso(conn, %{"org" => slug} = params) do
    settings_write(conn, slug, "sso_connection.updated", fn org, user ->
      DashboardSettings.update_sso(org, user, params)
    end)
  end

  def run_settings_sso_checks(conn, %{"org" => slug}),
    do: settings_write(conn, slug, "run_checks.ran", &DashboardSettings.run_sso_checks/2)

  def settings_integrations(conn, %{"org" => slug}),
    do: settings_read(conn, slug, fn org, _user -> DashboardSettings.integrations(org) end)

  def save_settings_oauth_app(conn, %{"org" => slug, "provider" => provider} = params) do
    settings_write(conn, slug, "oauth_provider_app.saved", fn org, user ->
      DashboardSettings.save_oauth_app(org, user, provider, params)
    end)
  end

  def delete_settings_oauth_app(conn, %{"org" => slug, "provider" => provider}) do
    settings_write(conn, slug, "oauth_provider_app.deleted", fn org, user ->
      DashboardSettings.delete_oauth_app(org, user, provider)
    end)
  end

  def save_settings_composio(conn, %{"org" => slug} = params) do
    settings_write(conn, slug, "composio_settings.saved", fn org, user ->
      DashboardSettings.save_composio(org, user, params)
    end)
  end

  def delete_settings_composio(conn, %{"org" => slug}),
    do:
      settings_write(
        conn,
        slug,
        "composio_settings.deleted",
        &DashboardSettings.delete_composio/2
      )

  def save_settings_signal(conn, %{"org" => slug} = params) do
    settings_write(conn, slug, "signal_number.saved", fn org, user ->
      DashboardSettings.save_signal(org, user, params)
    end)
  end

  def create_settings_feishu_app(conn, %{"org" => slug} = params) do
    settings_write(conn, slug, "feishu_app_binding.created", fn org, user ->
      DashboardSettings.save_feishu_app(org, user, nil, params)
    end)
  end

  def update_settings_feishu_app(conn, %{"org" => slug, "id" => id} = params) do
    settings_write(conn, slug, "feishu_app_binding.updated", fn org, user ->
      DashboardSettings.save_feishu_app(org, user, id, params)
    end)
  end

  def delete_settings_feishu_app(conn, %{"org" => slug, "id" => id}) do
    settings_write(conn, slug, "feishu_app_binding.deleted", fn org, user ->
      DashboardSettings.delete_feishu_app(org, user, id)
    end)
  end

  defp settings_read(conn, slug, read) do
    user = conn.assigns.current_user

    case member_org(slug, user) do
      {:ok, org, role} when role in @admin_roles ->
        case read.(org, user) do
          {:error, status, code, message, details} ->
            send_error(conn, status, code, message, details)

          {:ok, data} ->
            send_ok(conn, data)

          data ->
            send_ok(conn, data)
        end

      {:ok, _org, _role} ->
        {:error, status, code, message, details} = DashboardSettings.forbidden()
        send_error(conn, status, code, message, details)

      :not_found ->
        org_not_found(conn)
    end
  end

  defp settings_write(conn, slug, action, write) do
    user = conn.assigns.current_user

    result =
      case member_org(slug, user) do
        {:ok, org, role} when role in @admin_roles -> write.(org, user)
        {:ok, org, _role} -> DashboardSettings.deny(org, user, action)
        :not_found -> :not_found
      end

    case result do
      {:ok, data} -> send_ok(conn, data)
      :not_found -> org_not_found(conn)
      {:error, status, code, message, details} -> send_error(conn, status, code, message, details)
    end
  end

  # ---- BFT CLI device login (outside any organization) ----

  def cli_login(conn, %{"user_code" => code}),
    do: cli_login_reply(conn, DashboardCLILogin.show(conn.assigns.current_user, code))

  def approve_cli_login(conn, %{"user_code" => code} = params),
    do: cli_login_reply(conn, DashboardCLILogin.approve(conn.assigns.current_user, code, params))

  def deny_cli_login(conn, %{"user_code" => code}),
    do: cli_login_reply(conn, DashboardCLILogin.deny(conn.assigns.current_user, code))

  # ---- First-run onboarding wizard (outside any organization) ----

  def onboarding_wizard(conn, _params),
    do: wizard_reply(conn, DashboardOnboardingWizard.show(conn.assigns.current_user))

  def onboarding_wizard_integrations(conn, _params),
    do: wizard_reply(conn, DashboardOnboardingWizard.integrations(conn.assigns.current_user))

  def save_onboarding_capabilities(conn, params),
    do:
      wizard_reply(
        conn,
        DashboardOnboardingWizard.save_capabilities(conn.assigns.current_user, params)
      )

  def save_onboarding_profile(conn, _params),
    do: wizard_reply(conn, DashboardOnboardingWizard.save_profile(conn.assigns.current_user))

  def connect_onboarding_toolkit(conn, params),
    do:
      wizard_reply(
        conn,
        DashboardOnboardingWizard.connect(
          conn.assigns.current_user,
          params,
          dashboard_base_url(conn)
        )
      )

  def complete_onboarding(conn, _params),
    do: wizard_reply(conn, DashboardOnboardingWizard.complete(conn.assigns.current_user))

  def skip_onboarding(conn, _params),
    do: wizard_reply(conn, DashboardOnboardingWizard.skip(conn.assigns.current_user))

  defp wizard_reply(conn, {:ok, data}), do: send_ok(conn, data)

  defp wizard_reply(conn, {:error, status, code, message, details}),
    do: send_error(conn, status, code, message, details)

  defp cli_login_reply(conn, {:ok, data}), do: send_ok(conn, data)

  defp cli_login_reply(conn, {:error, status, code, message, details}),
    do: send_error(conn, status, code, message, details)

  defp visible_project(org, project_id, user) do
    with {:ok, _uuid} <- Ecto.UUID.cast(project_id),
         {:ok, project} <- Projects.get_project(project_id),
         true <- project.org_id == org.id,
         {:ok, role} <- Memberships.project_role(project.id, user.id) do
      {:ok, project, role}
    else
      _ -> :project_not_found
    end
  end

  defp creator_label(nil), do: nil

  defp creator_label(user_id) do
    case Accounts.get_user(user_id) do
      {:ok, user} -> if(present?(user.name), do: user.name, else: user.email)
      _ -> nil
    end
  end

  defp project_usage(nil),
    do: %{
      "conversation_count" => 0,
      "token_total" => 0,
      "refreshed_at" => nil,
      "status" => "missing"
    }

  defp project_usage(snapshot) do
    %{
      "conversation_count" => snapshot.conversation_count || 0,
      "token_total" => snapshot.token_total || 0,
      "refreshed_at" => snapshot.refreshed_at,
      "status" => snapshot_status(snapshot)
    }
  end

  defp snapshot_status(%{refresh_error: error}) when is_binary(error) and error != "", do: "error"
  defp snapshot_status(%{refreshing_at: %DateTime{}}), do: "refreshing"
  defp snapshot_status(%{stale_at: %DateTime{}}), do: "stale"
  defp snapshot_status(_snapshot), do: "ready"

  defp recent_conversations(_org, _project, nil), do: []

  defp recent_conversations(org, project, snapshot) do
    for %{"conversation_id" => id} = conversation <- snapshot.recent_conversations || [],
        is_binary(id) do
      %{
        "id" => id,
        "title" => text_or_nil(conversation["title"]),
        "status" => text_or_nil(conversation["status"]),
        "updated_at" => iso_timestamp(conversation["updated_at"]),
        "href" => "/orgs/#{org.slug}/projects/#{project.id}/tasks/#{id}"
      }
    end
  end

  # The Agents panel lists the Router (Workers are retired). A Salix outage
  # degrades the panel, not the page.
  defp overview_agents(project) do
    case Agents.current_router(project) do
      {:ok, router} ->
        %{
          "status" => "ok",
          "items" => [DashboardSwarmAgents.summary(router)],
          "truncated" => false
        }

      _ ->
        unavailable_agents()
    end
  rescue
    _exception -> unavailable_agents()
  catch
    :exit, _reason -> unavailable_agents()
  end

  defp unavailable_agents, do: %{"status" => "unavailable", "items" => [], "truncated" => false}

  defp text_or_nil(value) when is_binary(value), do: value
  defp text_or_nil(_value), do: nil

  # Salix stores conversation times as unix seconds or milliseconds.
  defp iso_timestamp(value) when is_integer(value) do
    unit = if value > 99_999_999_999, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _ -> nil
    end
  end

  defp iso_timestamp(value) when is_binary(value), do: value
  defp iso_timestamp(_value), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # The configured public origin; the request's own origin in dev and e2e.
  defp dashboard_base_url(conn) do
    case SystemsRuntime.get_env(:bridge_for_teams_web, :public_base_url) do
      base when is_binary(base) and base != "" ->
        String.trim_trailing(base, "/")

      _unset ->
        port =
          case {conn.scheme, conn.port} do
            {:http, 80} -> ""
            {:https, 443} -> ""
            {_scheme, port} -> ":#{port}"
          end

        "#{conn.scheme}://#{conn.host}#{port}"
    end
  end

  defp member_org(slug, user) do
    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, role} <- Memberships.org_role(org.id, user.id) do
      {:ok, org, role}
    else
      _ -> :not_found
    end
  end

  # Owner/admin pages (Health, Meetings, Data policy, Slack triage): anyone else gets the non-member 404.
  defp admin_org(slug, user) do
    case member_org(slug, user) do
      {:ok, org, role} when role in @admin_roles -> {:ok, org}
      _ -> :not_found
    end
  end

  defp attention(org, usage_rows, runners) do
    failed_snapshots =
      for %{snapshot_status: :error} = row <- usage_rows do
        %{
          "id" => "usage-refresh-#{row.project_id}",
          "severity" => "warning",
          "title" => gettext("Usage for %{name} could not be refreshed", name: row.name),
          "detail" => gettext("The numbers shown may be out of date."),
          "href" => "/orgs/#{org.slug}/projects/#{row.project_id}"
        }
      end

    unhealthy_runners =
      for runner <- runners do
        %{
          "id" => "runner-#{runner.id}",
          "severity" => if(runner.effective_status == "offline", do: "error", else: "warning"),
          "title" => runner_title(runner),
          "detail" => gettext("Agents that run on it cannot start new work."),
          "href" => "/orgs/#{org.slug}/fin"
        }
      end

    unhealthy_runners ++ failed_snapshots
  end

  # Org admins see the members who asked for an OAuth client while none is
  # configured: one bounded query, and the cached OAuth answer only when
  # someone is waiting.
  defp oauth_waiting(org, role) when role in @admin_roles do
    case Onboarding.pending_oauth_reminders(org.id, limit: @oauth_waiting_limit + 1) do
      [] ->
        nil

      waiting ->
        if Onboarding.oauth_configured?(org.id) do
          nil
        else
          %{
            "names" =>
              waiting
              |> Enum.take(@oauth_waiting_limit)
              |> Enum.map(fn %{user: user} -> user.name || user.email || user.id end),
            "truncated" => length(waiting) > @oauth_waiting_limit
          }
        end
    end
  end

  defp oauth_waiting(_org, _role), do: nil

  defp runner_title(%{effective_status: "degraded", name: name}),
    do: gettext("Runner %{name} is degraded", name: name)

  defp runner_title(%{name: name}), do: gettext("Runner %{name} is offline", name: name)

  defp public_project_usage(row) do
    %{
      "id" => row.project_id,
      "name" => row.name,
      "conversation_count" => row.conversation_count,
      "token_total" => row.token_usage.total,
      "status" => Atom.to_string(row.snapshot_status),
      "refreshed_at" => Map.get(row, :refreshed_at)
    }
  end

  defp public_user(user), do: %{"id" => user.id, "name" => user.name, "email" => user.email}

  defp public_orgs(user) do
    user.id
    |> Orgs.list_orgs_for_user()
    |> Enum.map(&%{"slug" => &1.slug, "name" => &1.name})
  end

  defp project_not_found(conn),
    do: send_error(conn, 404, "project_not_found", gettext("Agent Swarm not found."), %{})

  defp org_not_found(conn),
    do: send_error(conn, 404, "org_not_found", gettext("Organization not found."), %{})
end
