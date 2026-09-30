defmodule BridgeForTeamsWeb.Dashboard.ProjectLive.Show do
  @moduledoc """
  Project detail (`/orgs/:org/projects/:id`) with sections selected from the
  current Agent Swarm navigation in the dashboard sidebar:

    * **Agents** — list project agents (name, role pill, status), create + per
      agent configure (`Agents.update_agent` reconciles the Agent Swarm control
      record), and archive.
    * **Tasks** — list Agent Swarm tasks backed by Salix conversations.
    * **Schedules** — list recurring schedules for the project's agents and
      task conversations, read live from Salix via
      `Schedules.list_project_schedules`, and delete one.
    * **Plugins** — list Salix-visible plugin definitions for this Agent Swarm,
      create project-owned plugin definitions, and toggle group enablement.
    * **Skills** — manage the router agent's custom skills and inspect its
      projected system skills.
    * **Devices** — list project devices (name, status pill, last seen), add a
      device through an org runner, and disconnect.
    * **Websites** — list every website deployed by the project's agents, read
      live from Salix via `Sites.list_project_sites`.
    * **Settings** — project identity, access, and archival controls.

  The tab is driven by `live_action`
  (`:show`/`:agents`/`:tasks`/`:schedules`/`:integrations`/`:connections`/`:plugins`/`:skills`/`:environments`/`:websites`/`:settings`)
  with `?tab=` as a fallback. All reads/writes go through the `BridgeForTeams.*`
  contexts in-process; status is surfaced with `status_pill`.
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  alias BridgeForTeams.{
    Accounts,
    Agents,
    Conversations,
    Compute,
    Environments,
    FeishuAppBindings,
    Memberships,
    Models,
    Observability,
    Orgs,
    ProjectComposioConnections,
    Plugins,
    ProjectIMConnects,
    ProjectOAuthConnections,
    ProjectSignal,
    Projects,
    RunChecks,
    RuntimeAuth,
    Schedules,
    Skills,
    Sites
  }

  import BridgeForTeamsWeb.Dashboard.DeviceProvisioning
  import BridgeForTeamsWeb.Dashboard.BrandLogos, only: [brand_logo: 1]

  alias BridgeForTeams.Salix.Client
  alias SalixStore.RuntimeIds

  alias BridgeForTeams.Schema.Agent
  alias BridgeForTeamsWeb.Dashboard.Onboarding, as: OnboardingHook
  alias BridgeForTeamsWeb.Dashboard.PluginComponents
  alias BridgeForTeamsWeb.Dashboard.PluginForm
  alias BridgeForTeamsWeb.Dashboard.SchedulePresentation

  @tabs ~w(agents tasks schedules integrations connections plugins skills environments websites settings)a
  @access_roles ~w(admin user)
  @agent_page_limit 500
  @environment_provision_refresh_interval_ms 2_000
  @empty_skill_form %{
    "name" => "",
    "description" => "",
    "instructions" => "",
    "activation" => "regular"
  }

  @impl true
  def mount(%{"org" => slug, "id" => id}, _session, socket) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, project} <- Projects.get_project(id),
         true <- project.org_id == org.id,
         {:ok, org_role} <- Memberships.org_role(org.id, user.id),
         {:ok, project_role} <- Memberships.project_role(project.id, user.id) do
      {:ok,
       socket
       |> assign(:orgs, orgs)
       |> assign(:current_org, org)
       |> assign(:current_org_role, org_role)
       |> assign(:project, project)
       |> assign(:project_role, project_role)
       |> assign(:can_manage_project, project_role == "admin")
       |> assign(:can_view_operations, can_view_operations?(org_role))
       |> assign(:can_view_audit, can_view_audit?(org_role))
       |> assign(:active_nav, :projects)
       |> assign(:rename_form, rename_form(%{"name" => project.name}))
       |> assign(:agent_form, nil)
       |> assign(:archive_agent, nil)
       |> assign(:archive_triage_binding, nil)
       |> assign(:triage_worker_binding, nil)
       |> assign(:agent_environments, [])
       |> assign(:agent_environments_error, nil)
       |> assign(:agent_environments_loaded, false)
       |> assign(:external_workload_items, [])
       |> assign(:external_workload_next_cursor, nil)
       |> assign(:external_workload_error, nil)
       |> assign(:external_workload_read_at, nil)
       |> assign(:salix_agents_error, nil)
       |> assign(:agent_templates, [])
       |> assign(:effective_model_defaults, %{})
       |> assign(:access_form, access_form())
       |> assign(:show_access_form, false)
       |> assign(:configure_agent, nil)
       |> assign(:rebind_agent, nil)
       |> assign(:conversation_form, nil)
       |> assign(:conversation_query, "")
       |> assign(:conversation_status_filter, "all")
       |> assign(:feishu_connect_form, nil)
       |> assign(:feishu_checks, nil)
       |> assign(:feishu_bot_bindings, [])
       |> assign(:slack_connect_form, nil)
       |> assign(:slack_checks, nil)
       |> assign(:slack_manifest, nil)
       |> assign(:integration_setup_provider, nil)
       |> assign(:connection_detail, nil)
       |> assign(:project_plugin_panel, nil)
       |> assign(:project_plugin_panel_error, nil)
       |> assign(:project_plugin_detail, nil)
       |> assign(:project_plugin_form, PluginForm.empty_form())
       |> assign(:project_plugin_query, "")
       |> assign(:project_plugin_state_filter, "all")
       |> assign(:project_plugin_source_filter, "all")
       |> assign(:project_skill_agent, nil)
       |> assign(:project_system_skills, [])
       |> assign(:project_user_skills, [])
       |> assign(:project_skills_unavailable, false)
       |> assign(:project_miniskill_status, nil)
       |> assign(:project_skill_form, @empty_skill_form)
       |> assign(:project_skill_composing, false)
       |> assign(:project_skill_error, nil)
       |> assign(:project_skill_viewing, nil)
       |> assign(:env_form, nil)
       |> assign(:env_provisioners, [])
       |> assign(:env_provisioning_active, false)
       |> assign(:env_provision_refresh_ref, nil)
       |> assign(:android_control, %{entitled: false})
       |> assign(:android_control_error, nil)
       |> assign(:runtime_auth_selected, nil)
       |> assign(:runtime_auth_requests, [])
       |> assign(:runtime_auth_requests_next_cursor, nil)
       |> assign(:runtime_auth_requests_error, nil)
       |> allow_upload(:project_skill_file,
         accept: ~w(.md .markdown),
         max_entries: 1,
         max_file_size: 200_000,
         auto_upload: true,
         progress: &handle_project_skill_upload_progress/3
       )}
    else
      _ ->
        {:ok,
         socket
         |> assign(:orgs, orgs)
         |> put_flash(:error, gettext("Agent Swarm not found."))
         |> push_navigate(to: ~p"/orgs/#{slug}/projects")}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    project = socket.assigns.project
    tab = resolve_tab(socket.assigns.live_action, params)

    socket =
      socket
      |> assign(:tab, tab)
      |> assign(:current_url, uri)
      |> maybe_flash_oauth_outcome(params)
      |> load_tab(tab)
      |> maybe_open_runtime_auth_target(tab, params)
      |> maybe_open_integration_setup(tab, params)
      |> assign_project_plugin_detail(params)

    detail = socket.assigns.project_plugin_detail

    socket =
      socket
      |> assign(:page_title, (detail && detail["name"]) || project.name)
      |> assign(:breadcrumbs, breadcrumbs(socket.assigns.current_org, project, tab, detail))

    {:noreply, socket}
  end

  # The Salix OAuth callback returns the browser to this page, appending
  # `?oauth_error=...` only on failure (a success just lands back here and the
  # new connection shows up in the list).
  defp maybe_flash_oauth_outcome(socket, %{"oauth_error" => reason})
       when is_binary(reason) and reason != "" do
    put_flash(socket, :error, gettext("We couldn't connect that account. Please try again."))
  end

  defp maybe_flash_oauth_outcome(socket, _params), do: socket

  defp maybe_open_integration_setup(socket, :integrations, %{"provider" => provider})
       when provider in ["feishu", "slack"] do
    if socket.assigns.can_manage_project,
      do: assign(socket, :integration_setup_provider, provider),
      else: socket
  end

  defp maybe_open_integration_setup(socket, _tab, _params), do: socket

  defp resolve_tab(:show, _params), do: :agents
  defp resolve_tab(:plugin, _params), do: :plugins
  defp resolve_tab(action, _params) when action in @tabs, do: action

  defp resolve_tab(_action, params) do
    case params["tab"] do
      t when is_binary(t) ->
        if String.to_existing_atom(t) in @tabs, do: String.to_existing_atom(t), else: :agents

      _ ->
        :agents
    end
  rescue
    ArgumentError -> :agents
  end

  defp load_tab(socket, :agents), do: load_agent_page(socket, nil)

  defp load_tab(socket, :tasks) do
    {agent_choices, agent_error} = agent_choices(socket.assigns.project)

    case Conversations.list_project_conversations(socket.assigns.project) do
      {:ok, conversations} ->
        socket
        |> assign(:conversations, conversations)
        |> assign(:conversation_agents, agent_choices)
        |> assign(:conversations_error, agent_error)

      {:error, reason} ->
        socket
        |> assign(:conversations, [])
        |> assign(:conversation_agents, agent_choices)
        |> assign(:conversations_error, reason)
    end
  end

  defp load_tab(socket, :schedules) do
    case Schedules.list_project_schedules(socket.assigns.project) do
      {:ok, schedules} ->
        socket
        |> assign(:schedules, schedules)
        |> assign(:schedules_error, nil)

      {:error, reason} ->
        socket
        |> assign(:schedules, [])
        |> assign(:schedules_error, reason)
    end
  end

  defp load_tab(socket, :environments) do
    socket = socket |> assign_environment_provisioning() |> assign_android_control()

    {:ok, environments} =
      Environments.list_projected_environments(socket.assigns.project.id)

    socket =
      socket
      |> assign(
        :environments,
        Enum.map(environments, &env_view/1)
      )
      |> assign(:environments_error, nil)

    socket =
      case Compute.project(socket.assigns.current_org, socket.assigns.project) do
        {:ok, projection} ->
          socket
          |> assign(:compute_projection, projection)
          |> assign(:compute_projection_error, nil)

        {:error, reason} ->
          socket
          |> assign(:compute_projection, %{
            "environments" => [],
            "workloads" => [],
            "runtimes" => []
          })
          |> assign(:compute_projection_error, reason)
      end

    socket
    |> load_runtime_auth_requests()
    |> maybe_schedule_environment_provision_refresh()
  end

  defp load_tab(socket, :websites) do
    # Dashboard read path: served from the project-sites ReadCache (short TTL)
    # so tab switches don't re-fan-out to Salix.
    case Sites.list_project_sites(socket.assigns.project, cache: true) do
      {:ok, sites} ->
        socket
        |> assign(:websites, sites)
        |> assign(:websites_error, nil)

      {:error, reason} ->
        socket
        |> assign(:websites, [])
        |> assign(:websites_error, reason)
    end
  end

  defp load_tab(socket, :integrations) do
    org = socket.assigns.current_org
    project = socket.assigns.project

    {connects, error} =
      case ProjectIMConnects.list_project_connects(org.id, project.id, nil) do
        {:ok, connects} -> {connects, nil}
        {:error, reason} -> {[], reason}
      end

    slack_app_name = default_slack_app_name(project)
    {integration_agents, agent_error} = agent_choices(project)
    default_inbound_agent_id = current_router_agent_id(project)

    # The project Feishu card selects one of the org's bot-enabled,
    # secret-configured app bindings. Salix sources the bot secret from its
    # tenant store, so the card forwards only the chosen binding's app_id.
    bot_bindings =
      org.id
      |> FeishuAppBindings.list_bindings()
      |> Enum.filter(&(&1.bot_enabled and &1.app_secret_configured))

    feishu_connects = connects_for(connects, "feishu")

    socket
    |> assign(:project_im_connects_error, error || agent_error)
    |> assign(:feishu_connects, feishu_connects)
    |> assign(:feishu_checks, nil)
    |> assign(:feishu_bot_bindings, bot_bindings)
    |> assign(:feishu_route_state, feishu_route_state(project, feishu_connects))
    |> assign(:integration_agents, integration_agents)
    |> assign(:slack_connects, connects_for(connects, "slack"))
    |> assign(:slack_checks, nil)
    |> assign(:feishu_connect_form, feishu_connect_form(default_feishu_params(bot_bindings)))
    |> assign(
      :slack_connect_form,
      slack_connect_form(%{
        "app_name" => slack_app_name,
        "inbound_agent_id" => default_inbound_agent_id
      })
    )
    |> assign_slack_manifest(slack_app_name)
    |> assign_project_signal()
  end

  defp load_tab(socket, :connections) do
    org = socket.assigns.current_org
    project = socket.assigns.project

    {available, available_error} =
      case ProjectOAuthConnections.list_available_providers(org.id) do
        {:ok, providers} -> {providers, nil}
        {:error, reason} -> {[], reason}
      end

    {connections, connections_error} =
      case ProjectOAuthConnections.list_connections(org.id, project.id) do
        {:ok, connections} -> {connections, nil}
        {:error, reason} -> {[], reason}
      end

    socket
    |> assign(:oauth_available, available)
    |> assign(:oauth_available_error, available_error)
    |> assign(:oauth_connections, connections)
    |> assign(:oauth_connections_error, connections_error)
    |> assign(:oauth_connect_form, to_form(%{}, as: :oauth))
    |> load_composio_connections()
    |> OnboardingHook.observe_connections(connections)
  end

  defp load_tab(socket, :plugins) do
    org = socket.assigns.current_org
    project = socket.assigns.project

    case Plugins.list_project_plugins(org.id, project.id,
           actor_user_id: socket.assigns.current_user.id
         ) do
      {:ok, page} ->
        socket
        |> assign(:project_plugin_definitions, page.definitions)
        |> assign(:project_plugin_enablements, page.enablements)
        |> assign(:project_plugin_enablement_by_id, page.enablement_by_id)
        |> assign(:project_plugins_error, nil)
        |> assign_android_control()

      {:error, reason} ->
        socket
        |> assign(:project_plugin_definitions, [])
        |> assign(:project_plugin_enablements, [])
        |> assign(:project_plugin_enablement_by_id, %{})
        |> assign(:project_plugins_error, reason)
    end
  end

  defp load_tab(socket, :skills), do: load_project_skills(socket)

  defp load_tab(socket, :settings) do
    assign(socket, :project_members, Memberships.list_project_members(socket.assigns.project.id))
  end

  defp load_runtime_auth_requests(socket, cursor \\ nil) do
    case RuntimeAuth.list_requests(
           socket.assigns.current_user.id,
           socket.assigns.project.id,
           cursor: cursor
         ) do
      {:ok, page} ->
        socket
        |> assign(:runtime_auth_requests, page["requests"])
        |> assign(:runtime_auth_requests_next_cursor, page["next_cursor"])
        |> assign(:runtime_auth_requests_error, nil)

      {:error, reason} ->
        socket
        |> assign(:runtime_auth_requests, [])
        |> assign(:runtime_auth_requests_next_cursor, nil)
        |> assign(:runtime_auth_requests_error, reason)
    end
  end

  defp maybe_open_runtime_auth_target(
         socket,
         :environments,
         %{"runtime_auth_target" => target} = params
       )
       when is_binary(target) do
    rows = runtime_auth_rows(socket.assigns.compute_projection, socket.assigns.environments)

    request =
      case params["runtime_auth_request"] do
        request_id when is_binary(request_id) ->
          case RuntimeAuth.get_request(
                 socket.assigns.current_user.id,
                 socket.assigns.project.id,
                 request_id
               ) do
            {:ok, %{"target" => %{"workload_id" => ^target}} = request} -> request
            _ -> nil
          end

        _ ->
          nil
      end

    selected =
      runtime_auth_request_selection(target, Enum.find(rows, &(&1.id == target)), request)

    if selected && socket.assigns.can_manage_project,
      do: assign(socket, :runtime_auth_selected, selected),
      else: socket
  end

  defp maybe_open_runtime_auth_target(socket, _tab, _params), do: socket

  defp assign_project_plugin_detail(%{assigns: %{live_action: :plugin}} = socket, %{
         "plugin_id" => plugin_id
       }) do
    assign(
      socket,
      :project_plugin_detail,
      find_project_plugin(socket.assigns.project_plugin_definitions, plugin_id)
    )
  end

  defp assign_project_plugin_detail(socket, _params),
    do: assign(socket, :project_plugin_detail, nil)

  defp load_project_skills(socket) do
    agent = project_skill_agent(socket.assigns.project)

    case agent do
      {:error, _} ->
        socket
        |> assign(:project_skill_agent, nil)
        |> assign(:project_system_skills, [])
        |> assign(:project_user_skills, [])
        |> assign(:project_skills_unavailable, true)

      nil ->
        socket
        |> assign(:project_skill_agent, nil)
        |> assign(:project_system_skills, [])
        |> assign(:project_user_skills, [])
        |> assign(:project_skills_unavailable, false)
        |> assign(:project_miniskill_status, nil)

      agent ->
        case Skills.list_skills(socket.assigns.current_org, agent) do
          {:ok, %{system: system, user: user_skills} = catalog} ->
            socket
            |> assign(:project_skill_agent, agent)
            |> assign(:project_system_skills, system)
            |> assign(:project_user_skills, user_skills)
            |> assign(:project_skills_unavailable, false)
            |> assign(:project_miniskill_status, catalog[:miniskill_status])

          {:error, _reason} ->
            socket
            |> assign(:project_skill_agent, agent)
            |> assign(:project_system_skills, [])
            |> assign(:project_user_skills, [])
            |> assign(:project_skills_unavailable, true)
        end
    end
  end

  defp project_skill_agent(project) do
    case agent_choices(project) do
      {agents, nil} ->
        router_agent_id = current_router_agent_id(project)
        Enum.find(agents, &(&1.salix_agent_id == router_agent_id)) || List.first(agents)

      {_, reason} ->
        {:error, reason}
    end
  end

  defp agent_choices(project) do
    case Agents.page_agents(project, limit: @agent_page_limit) do
      {:ok, %{items: items, next_cursor: nil}} -> {items, nil}
      {:ok, _} -> {[], :agent_page_required}
      {:error, reason} -> {[], reason}
    end
  end

  # Composio account connections run alongside the managed-OAuth path on the
  # connections tab. Readiness is org-wide (one Composio API key), so it
  # degrades independently of the OAuth runtime: an unconfigured org shows the
  # toolkits as needing setup, and a Salix hiccup surfaces as "unavailable"
  # without blocking the OAuth section above.
  defp load_composio_connections(socket) do
    org = socket.assigns.current_org
    project = socket.assigns.project

    {configured?, connections, unavailable?} =
      if ProjectComposioConnections.configured?(org.id) do
        case ProjectComposioConnections.list_connections(org.id, project.id) do
          {:ok, connections} -> {true, connections, false}
          {:error, :not_configured} -> {false, [], false}
          {:error, _reason} -> {true, [], true}
        end
      else
        {false, [], false}
      end

    socket
    |> assign(:composio_configured, configured?)
    |> assign(:composio_connections, connections)
    |> assign(:composio_unavailable, unavailable?)
  end

  # Pre-select the first bot-enabled binding so the select has a sensible default.
  defp default_feishu_params([binding | _]),
    do: %{"app_id" => binding.app_id, "app_name" => binding.display_name || binding.app_id}

  defp default_feishu_params([]), do: %{}

  @impl true
  def handle_info(:refresh_environment_provisioning, socket) do
    socket = assign(socket, :env_provision_refresh_ref, nil)

    if socket.assigns[:tab] == :environments do
      {:noreply, load_tab(socket, :environments)}
    else
      {:noreply, socket}
    end
  end

  # The Slack bot's display name defaults to the project name (falling back to
  # "Comma" when blank), so it shows up in the workspace under a recognizable
  # label without the user typing anything.
  defp default_slack_app_name(project) do
    case project && project.name do
      name when is_binary(name) -> if String.trim(name) == "", do: "Comma", else: name
      _ -> "Comma"
    end
  end

  # The Slack App Manifest only depends on the app name + the deployment's public
  # base URL (resolved by Salix), so it can be previewed before any connect
  # exists and regenerated as the user edits the app name.
  defp assign_slack_manifest(socket, app_name) do
    manifest =
      case ProjectIMConnects.slack_manifest(app_name) do
        {:ok, manifest} -> slack_manifest_view(manifest)
        {:error, _reason} -> nil
      end

    assign(socket, :slack_manifest, manifest)
  end

  defp slack_manifest_view(%{"manifest" => manifest} = payload) do
    %{
      json: Jason.encode!(manifest, pretty: true),
      create_url: slack_create_app_url(manifest),
      redirect_url: payload["redirect_url"],
      events_url: payload["events_url"],
      interactions_url: payload["interactions_url"]
    }
  end

  defp slack_manifest_view(_), do: nil

  # Slack pre-fills the "Create New App → From a manifest" flow when the manifest
  # is passed as a URL-encoded `manifest_json` query param, so the user only has
  # to pick a workspace and confirm. The Copy button stays as a fallback for the
  # rare case the encoded URL exceeds the browser's length limit.
  @slack_create_app_base "https://api.slack.com/apps"
  defp slack_create_app_url(manifest) do
    query = URI.encode_query(new_app: "1", manifest_json: Jason.encode!(manifest))
    @slack_create_app_base <> "?" <> query
  end

  defp connects_for(connects, provider),
    do: Enum.filter(connects, &(&1["provider"] == provider))

  # ---- Agent Swarm (project) lifecycle events ----

  def handle_event("rename_project", %{"rename" => params}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can rename this Agent Swarm."),
      {:project, "project.renamed"},
      fn socket ->
        name = params |> Map.get("name", "") |> String.trim()

        case Projects.rename_project(socket.assigns.project, name, audit_opts(socket)) do
          {:ok, project} ->
            {:noreply,
             socket
             |> assign(:project, project)
             |> assign(:page_title, project.name)
             |> assign(
               :breadcrumbs,
               breadcrumbs(socket.assigns.current_org, project, socket.assigns.tab)
             )
             |> assign(:rename_form, rename_form(%{"name" => project.name}))
             |> put_flash(
               :info,
               gettext("Agent Swarm renamed to \"%{name}\".", name: project.name)
             )}

          {:error, %Ecto.Changeset{} = cs} ->
            {:noreply, assign(socket, :rename_form, rename_form(params, cs))}

          {:error, _other} ->
            {:noreply, put_flash(socket, :error, gettext("Could not rename the Agent Swarm."))}
        end
      end
    )
  end

  def handle_event("toggle_vm_enabled", _params, socket) do
    project = socket.assigns.project

    if socket.assigns.can_manage_project do
      case Projects.set_vm_enabled(project, not project.vm_enabled, audit_opts(socket)) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:project, updated)
           |> put_flash(
             :info,
             if(updated.vm_enabled,
               do: gettext("Cloud computer enabled for this Agent Swarm."),
               else: gettext("Cloud computer disabled for this Agent Swarm.")
             )
           )}

        {:error, _reason} ->
          {:noreply,
           put_flash(socket, :error, gettext("Couldn't update the cloud computer setting."))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only Agent Swarm admins can manage devices."))}
    end
  end

  def handle_event("create_shell_workload", %{"id" => environment_id}, socket) do
    if socket.assigns.can_manage_project do
      case Compute.create_workload(socket.assigns.current_org, socket.assigns.project, %{
             "environment_id" => environment_id,
             "kind" => "shell"
           }) do
        {:ok, _result} ->
          {:noreply,
           socket
           |> load_tab(:environments)
           |> put_flash(
             :info,
             gettext("Shell workload accepted. Refresh to check its runtime status.")
           )}

        {:error, reason} ->
          {:noreply,
           socket
           |> load_tab(:environments)
           |> put_flash(
             :error,
             gettext("Workload creation failed: %{reason}", reason: inspect(reason))
           )}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only Agent Swarm admins can manage Compute."))}
    end
  end

  def handle_event(
        "compute_environment_intent",
        %{"id" => id, "revision" => revision, "intent" => intent},
        socket
      )
      when intent in ["drain", "revoke"] do
    if socket.assigns.can_manage_project do
      result =
        with {expected_revision, ""} <- Integer.parse(revision) do
          attrs = %{"expected_revision" => expected_revision}

          case intent do
            "drain" ->
              Compute.drain(socket.assigns.current_org, socket.assigns.project, id, attrs)

            "revoke" ->
              Compute.revoke(socket.assigns.current_org, socket.assigns.project, id, attrs)
          end
        else
          _ -> {:error, :invalid_revision}
        end

      case result do
        {:ok, _environment} ->
          {:noreply,
           socket
           |> load_tab(:environments)
           |> put_flash(:info, gettext("Compute environment updated."))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update Compute environment."))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only Agent Swarm admins can manage Compute."))}
    end
  end

  def handle_event("archive_project", _params, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can archive this Agent Swarm."),
      {:project, "project.archived"},
      fn socket ->
        case archival_blocker(socket) do
          nil ->
            archive_project(socket)

          {:error, :active_connects} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext(
                 "Disable every IM connection on the Integrations tab before archiving this Agent Swarm."
               )
             )}

          {:error, :schedules_present} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext(
                 "Delete every schedule on the Schedules tab before archiving this Agent Swarm."
               )
             )}

          {:error, :unavailable} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext(
                 "Couldn't verify the Agent Swarm state. Salix is unavailable — retry shortly."
               )
             )}
        end
      end
    )
  end

  # ---- Access events ----

  def handle_event("open_access_form", _params, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage access."),
      fn socket ->
        {:noreply,
         socket
         |> assign(:access_form, access_form())
         |> assign(:show_access_form, true)}
      end
    )
  end

  def handle_event("close_access_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:access_form, access_form())
     |> assign(:show_access_form, false)}
  end

  def handle_event("grant_access", %{"access" => params}, socket) do
    if socket.assigns.can_manage_project do
      email = params |> Map.get("email", "") |> String.trim() |> String.downcase()
      role = if params["role"] in @access_roles, do: params["role"], else: "user"

      cond do
        email == "" ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("Email can't be blank."))
           |> assign(:access_form, access_form(params))}

        true ->
          with {:ok, user} <- find_or_create_user(email),
               {:ok, _membership} <-
                 Memberships.put_project_member(
                   socket.assigns.project.id,
                   user.id,
                   role,
                   audit_opts(socket)
                 ) do
            {:noreply,
             socket
             |> put_flash(
               :info,
               gettext("%{email} added as %{role}.",
                 email: email,
                 role: access_role_label(role)
               )
             )
             |> assign(:access_form, access_form())
             |> assign(:show_access_form, false)
             |> load_tab(:settings)}
          else
            {:error, _reason} ->
              {:noreply,
               socket
               |> put_flash(:error, gettext("Could not update access."))
               |> assign(:access_form, access_form(params))}
          end
      end
    else
      maybe_record_project_member_denied_attempt(
        socket,
        "project_member.granted",
        nil,
        attempted_access_grant_metadata(params)
      )

      {:noreply, put_flash(socket, :error, gettext("Only Agent Swarm admins can manage access."))}
    end
  end

  def handle_event("change_access_role", %{"user-id" => user_id, "role" => role}, socket)
      when role in @access_roles do
    if socket.assigns.can_manage_project do
      case Memberships.put_project_member(
             socket.assigns.project.id,
             user_id,
             role,
             audit_opts(socket)
           ) do
        {:ok, _membership} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Access role updated."))
           |> load_tab(:settings)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update access role."))}
      end
    else
      maybe_record_project_member_denied_attempt(
        socket,
        "project_member.role_changed",
        user_id,
        attempted_access_role_metadata(role)
      )

      {:noreply, put_flash(socket, :error, gettext("Only Agent Swarm admins can manage access."))}
    end
  end

  def handle_event("change_access_role", _params, socket), do: {:noreply, socket}

  def handle_event("remove_access", %{"user-id" => user_id}, socket) do
    if socket.assigns.can_manage_project do
      case Memberships.remove_project_member(
             socket.assigns.project.id,
             user_id,
             audit_opts(socket)
           ) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Access removed."))
           |> load_tab(:settings)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not remove access."))}
      end
    else
      maybe_record_project_member_denied_attempt(
        socket,
        "project_member.removed",
        user_id,
        %{"surface" => "project_access"}
      )

      {:noreply, put_flash(socket, :error, gettext("Only Agent Swarm admins can manage access."))}
    end
  end

  # ---- Agents events ----

  @impl true
  def handle_event("retry_agents", _params, socket),
    do: {:noreply, load_agent_page(socket, socket.assigns.agent_page_cursor)}

  def handle_event("first_agent_page", _params, socket),
    do: {:noreply, load_agent_page(socket, nil)}

  def handle_event("next_agent_page", _params, socket) do
    if socket.assigns.agent_next_cursor,
      do: {:noreply, load_agent_page(socket, socket.assigns.agent_next_cursor)},
      else: {:noreply, socket}
  end

  def handle_event("new_agent", _params, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage agents."),
      fn socket ->
        {:noreply,
         socket
         |> reset_agent_environments()
         |> reset_external_workloads()
         |> assign(:configure_agent, nil)
         |> assign(:rebind_agent, nil)
         |> assign(:agent_form, agent_form(agent_form_defaults()))}
      end
    )
  end

  def handle_event("validate_agent", %{"agent" => attrs}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage agents."),
      fn socket ->
        socket = maybe_load_external_targets(socket, attrs)
        attrs = normalize_agent_form_attrs(socket, attrs)
        {:noreply, assign(socket, :agent_form, agent_form(attrs))}
      end
    )
  end

  def handle_event("create_agent", %{"agent" => attrs}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage agents."),
      "agent.created",
      fn socket ->
        socket = maybe_load_external_targets(socket, attrs)
        attrs = normalize_agent_form_attrs(socket, attrs)

        case build_agent_create_attrs(socket, attrs) do
          {:internal, create_attrs} ->
            case Agents.create_agent(socket.assigns.project.id, create_attrs, audit_opts(socket)) do
              {:ok, _agent} ->
                {:noreply,
                 socket
                 |> assign(:agent_form, nil)
                 |> put_flash(
                   :info,
                   gettext("Agent creation accepted. Refresh the list after provisioning.")
                 )
                 |> load_tab(:agents)}

              {:error, %Ecto.Changeset{} = cs} ->
                {:noreply, assign(socket, :agent_form, agent_form(attrs, cs))}

              {:error, _other} ->
                {:noreply, put_flash(socket, :error, gettext("Could not create the agent."))}
            end

          {:external, create_attrs, target} ->
            case Agents.create_external_agent(
                   socket.assigns.project,
                   create_attrs,
                   target,
                   audit_opts(socket)
                 ) do
              {:ok, _agent} ->
                {:noreply,
                 socket
                 |> assign(:agent_form, nil)
                 |> put_flash(
                   :info,
                   gettext("Agent creation accepted. Refresh the list after provisioning.")
                 )
                 |> load_tab(:agents)}

              {:error, %Ecto.Changeset{} = cs} ->
                {:noreply, assign(socket, :agent_form, agent_form(attrs, cs))}

              {:error, _other} ->
                {:noreply, put_flash(socket, :error, gettext("Could not create the agent."))}
            end

          {:error, message} ->
            {:noreply,
             socket
             |> assign(:agent_form, agent_form(attrs))
             |> put_flash(:error, message)}
        end
      end
    )
  end

  def handle_event("close_agent_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:agent_form, nil)
     |> assign(:configure_agent, nil)
     |> assign(:rebind_agent, nil)
     |> reset_agent_environments()
     |> reset_external_workloads()}
  end

  def handle_event("configure_agent", %{"id" => id}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage agents."),
      fn socket ->
        case Enum.find(socket.assigns.agents, &(&1.id == id)) do
          nil ->
            {:noreply, socket}

          agent ->
            attrs = %{"role" => agent.role, "system_prompt" => agent.salix["system_prompt"]}
            templates = load_agent_templates(socket.assigns.current_org)

            {:noreply,
             socket
             |> assign(:configure_agent, agent)
             |> assign(:rebind_agent, nil)
             |> assign(:agent_templates, templates)
             |> assign(
               :effective_model_defaults,
               Models.platform_defaults()
             )
             |> assign(
               :agent_template_options,
               configure_template_options(agent, socket.assigns.current_org, templates)
             )
             |> assign(:agent_form, agent_form(attrs))}
        end
      end
    )
  end

  def handle_event("save_config", %{"agent" => attrs}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage agents."),
      "agent.config_updated",
      fn socket ->
        agent = socket.assigns.configure_agent
        template_id = attrs["template_id"]

        if valid_template?(socket, template_id) do
          save_agent_config(socket, agent, attrs)
        else
          {:noreply,
           put_flash(socket, :error, gettext("Choose a model from the list before saving."))}
        end
      end
    )
  end

  def handle_event("rebind_agent", %{"id" => id}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage agents."),
      fn socket ->
        case Agents.get_project_agent(socket.assigns.project.id, id) do
          {:error, _} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Could not load the agent configuration. Retry shortly.")
             )}

          {:ok, agent} ->
            socket =
              socket
              |> reset_agent_environments()
              |> assign_agent_environments()
              |> reset_external_workloads()

            attrs = rebind_form_attrs(socket, agent)
            socket = maybe_load_external_targets(socket, attrs)

            {:noreply,
             socket
             |> assign(:configure_agent, nil)
             |> assign(:rebind_agent, agent)
             |> assign(:agent_form, agent_form(attrs))}
        end
      end
    )
  end

  def handle_event("validate_rebind", %{"agent" => attrs}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage agents."),
      fn socket ->
        socket = maybe_load_external_targets(socket, attrs)
        attrs = normalize_runtime_rebind_attrs(socket, attrs)
        {:noreply, assign(socket, :agent_form, agent_form(attrs))}
      end
    )
  end

  def handle_event("save_rebind", %{"agent" => attrs}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage agents."),
      "agent.runtime_rebound",
      fn socket ->
        agent = socket.assigns.rebind_agent
        socket = maybe_load_external_targets(socket, attrs)
        attrs = normalize_runtime_rebind_attrs(socket, attrs)

        case build_agent_rebind_attrs(socket, attrs) do
          {:ok, target, expected_revision} ->
            save_agent_runtime_rebind(socket, agent, target, expected_revision, attrs)

          {:error, message} ->
            {:noreply,
             socket
             |> assign(:agent_form, agent_form(attrs))
             |> put_flash(:error, message)}
        end
      end
    )
  end

  def handle_event("next_external_workloads", _params, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage agents."),
      fn socket -> {:noreply, load_external_workloads(socket, next: true)} end
    )
  end

  def handle_event("refresh_external_workloads", _params, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage agents."),
      fn socket -> {:noreply, load_external_workloads(socket)} end
    )
  end

  def handle_event("archive_agent", %{"id" => id}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage agents."),
      "agent.archived",
      fn socket ->
        with agent when not is_nil(agent) <- Enum.find(socket.assigns.agents, &(&1.id == id)),
             {:ok, _} <- Agents.archive_agent(agent, archive_opts(socket, agent)) do
          {:noreply,
           socket
           |> assign(:archive_agent, nil)
           |> put_flash(:info, gettext("Agent archived."))
           |> load_agent_page(nil)}
        else
          {:error, :triage_worker_confirmation_required} ->
            {:noreply,
             socket
             |> assign(:archive_agent, nil)
             |> put_flash(
               :error,
               gettext(
                 "This Worker is now assigned to Triage. Open Archive again to review the impact."
               )
             )
             |> load_agent_page(nil)}

          {:error, :router_agent} ->
            {:noreply, put_flash(socket, :error, gettext("Router agents cannot be archived."))}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Could not archive the agent."))}
        end
      end
    )
  end

  def handle_event("request_archive_agent", %{"id" => id}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage agents."),
      fn socket ->
        agent = Enum.find(socket.assigns.agents, &(&1.id == id && &1.role != "router"))

        case Agents.triage_worker_binding(socket.assigns.project) do
          {:ok, binding} ->
            {:noreply,
             socket |> assign(:archive_agent, agent) |> assign(:archive_triage_binding, binding)}

          {:error, _} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Could not check this Worker's Triage assignment. Try again.")
             )}
        end
      end
    )
  end

  def handle_event("close_archive_agent", _params, socket) do
    {:noreply, assign(socket, :archive_agent, nil)}
  end

  # ---- Conversation events ----

  def handle_event("new_conversation", _params, socket) do
    agent_id =
      case socket.assigns.conversation_agents do
        [agent | _] -> agent.id
        _ -> ""
      end

    {:noreply, assign(socket, :conversation_form, conversation_form(%{"agent_id" => agent_id}))}
  end

  def handle_event("close_conversation_form", _params, socket) do
    {:noreply, assign(socket, :conversation_form, nil)}
  end

  def handle_event("filter_conversations", %{"query" => query}, socket) do
    {:noreply, assign(socket, :conversation_query, String.trim(query))}
  end

  def handle_event("set_conversation_status_filter", %{"status" => status}, socket) do
    statuses = conversation_statuses(socket.assigns.conversations)
    status = if status in ["all", "scheduled"] or status in statuses, do: status, else: "all"

    {:noreply, assign(socket, :conversation_status_filter, status)}
  end

  def handle_event("create_conversation", %{"conversation" => attrs}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage tasks."),
      project_resource_write_attempt(
        "project_conversation.created",
        "project_conversation",
        "conversation",
        %{"agent_id_configured" => nonblank?(attrs["agent_id"])}
      ),
      fn socket ->
        with agent when not is_nil(agent) <-
               Enum.find(socket.assigns.conversation_agents, &(&1.id == attrs["agent_id"])),
             {:ok, conversation} <-
               Conversations.create_project_conversation(
                 socket.assigns.project,
                 agent,
                 attrs,
                 audit_opts(socket)
               ) do
          conversation_id = conversation["conversation_id"]

          {:noreply,
           socket
           |> assign(:conversation_form, nil)
           |> put_flash(:info, gettext("Task created."))
           |> push_navigate(
             to:
               ~p"/orgs/#{socket.assigns.current_org.slug}/projects/#{socket.assigns.project.id}/tasks/#{conversation_id}"
           )}
        else
          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not create the task."))}

          nil ->
            {:noreply, put_flash(socket, :error, gettext("Choose an agent for this task."))}
        end
      end
    )
  end

  # ---- Schedules events ----

  def handle_event("delete_schedule", %{"id" => id}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage schedules."),
      project_resource_write_attempt(
        "project_schedule.deleted",
        "project_schedule",
        "schedule",
        %{"schedule_id_configured" => nonblank?(id)}
      ),
      fn socket ->
        case delete_visible_schedule(socket, id) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Schedule deleted."))
             |> load_tab(:schedules)}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("That schedule no longer exists."))
             |> load_tab(:schedules)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete the schedule."))}
        end
      end
    )
  end

  def handle_event("manage_runtime_auth", %{"id" => id} = params, socket) do
    row =
      Enum.find(
        runtime_auth_rows(socket.assigns.compute_projection, socket.assigns.environments),
        &(&1.id == id)
      )

    select = fn socket ->
      request_id = params["request-id"]

      request =
        if is_binary(request_id) do
          Enum.find(socket.assigns.runtime_auth_requests, fn request ->
            request["request_id"] == request_id and
              get_in(request, ["target", "workload_id"]) == id
          end)
        end

      selected =
        if is_nil(request_id) or request do
          runtime_auth_request_selection(
            id,
            row,
            request
          )
        end

      {:noreply, assign(socket, :runtime_auth_selected, selected)}
    end

    if row && (row.target["kind"] == "compute_workload" || row.provider in ~w(codex claude)) do
      select.(socket)
    else
      require_project_admin(
        socket,
        gettext("Only Agent Swarm admins can sign in runtimes."),
        select
      )
    end
  end

  def handle_event("close_runtime_auth_panel", _params, socket) do
    {:noreply, assign(socket, :runtime_auth_selected, nil)}
  end

  def handle_event("next_runtime_auth_requests", _params, socket) do
    {:noreply,
     load_runtime_auth_requests(socket, socket.assigns.runtime_auth_requests_next_cursor)}
  end

  # ---- Device events ----

  def handle_event("new_environment", _params, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage devices."),
      fn socket ->
        provisioners = online_mac_mini_provisioners(socket.assigns.current_org.id)

        {:noreply,
         socket
         |> assign(:env_provisioners, provisioners)
         |> assign(:env_form, env_form(env_form_defaults(provisioners)))}
      end
    )
  end

  def handle_event("close_env_form", _params, socket) do
    {:noreply, assign(socket, :env_form, nil)}
  end

  def handle_event("create_environment", %{"device" => attrs}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage devices."),
      environment_create_denied_attempt(attrs),
      fn socket ->
        if nonblank?(attrs["provisioner_id"]),
          do: create_provisioned_environment(socket, attrs),
          else: {:noreply, put_flash(socket, :error, gettext("Select an online runner."))}
      end
    )
  end

  def handle_event("disconnect_environment", %{"id" => id}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage devices."),
      project_resource_write_attempt(
        "device.disconnected",
        "device",
        "device",
        %{"device_id_configured" => nonblank?(id)}
      ),
      fn socket ->
        if environment_loaded?(socket, id) do
          case Environments.disconnect_environment(
                 socket.assigns.project.id,
                 id,
                 audit_opts(socket) ++
                   [
                     org_id: socket.assigns.current_org.id,
                     project_id: socket.assigns.project.id,
                     resource_label: id
                   ]
               ) do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, gettext("Device disconnected."))
               |> update(:environments, &set_environment_status(&1, id, "disconnected"))
               |> clear_runtime_auth_for_device(id)}

            _ ->
              {:noreply, put_flash(socket, :error, gettext("Could not disconnect the device."))}
          end
        else
          {:noreply, put_flash(socket, :error, gettext("Device not found."))}
        end
      end
    )
  end

  def handle_event("delete_environment", %{"id" => id}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage devices."),
      project_resource_write_attempt(
        "device.deleted",
        "device",
        "device",
        %{"device_id_configured" => nonblank?(id)}
      ),
      fn socket ->
        if environment_loaded?(socket, id) do
          case Environments.delete_environment(
                 socket.assigns.project.id,
                 id,
                 audit_opts(socket) ++
                   [
                     org_id: socket.assigns.current_org.id,
                     project_id: socket.assigns.project.id,
                     resource_label: id
                   ]
               ) do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, gettext("Device deleted."))
               |> update(:environments, &remove_environment(&1, id))
               |> clear_runtime_auth_for_device(id)}

            {:error, :not_found} ->
              {:noreply,
               socket
               |> put_flash(:error, gettext("Device not found."))
               |> load_tab(:environments)}

            _ ->
              {:noreply, put_flash(socket, :error, gettext("Could not delete the device."))}
          end
        else
          {:noreply, put_flash(socket, :error, gettext("Device not found."))}
        end
      end
    )
  end

  # ---- Integrations events ----

  def handle_event("create_feishu_connect", %{"feishu_connect" => attrs}, socket) do
    # Forward only the selected binding's app_id and display name. No secrets
    # cross from the browser; Salix resolves them from the tenant store.
    create_connect(socket, "feishu", feishu_connect_attrs(attrs, socket.assigns), nil)
  end

  def handle_event("run-feishu-checks", _params, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage integrations."),
      project_resource_write_attempt(
        "integration.feishu.checks_run",
        "project_im_connect",
        "integration",
        %{"operation" => "run_checks"}
      ),
      fn socket ->
        case RunChecks.run_bot(socket.assigns.current_org.id, socket.assigns.project.id) do
          {:ok, checks} ->
            {:noreply,
             socket
             |> persist_run_checks_activity(checks)
             |> assign(:feishu_checks, checks)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not run Feishu checks."))}
        end
      end
    )
  end

  def handle_event("run-slack-calendar-checks", %{"id" => connect_id}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage integrations."),
      project_resource_write_attempt(
        "integration.slack.calendar_checks_run",
        "project_im_connect",
        "integration",
        %{
          "operation" => "run_calendar_checks",
          "connect_id_configured" => nonblank?(connect_id)
        }
      ),
      fn socket ->
        case RunChecks.run_slack_calendar(
               socket.assigns.current_org.id,
               socket.assigns.project.id,
               connect_id: connect_id
             ) do
          {:ok, checks} ->
            {:noreply,
             socket
             |> persist_run_checks_activity(checks)
             |> assign(:slack_checks, checks)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not run Slack calendar checks."))}
        end
      end
    )
  end

  # This explicit admin action sends one synthetic @Bridge message and flashes
  # the result. It stays separate from Run checks because it bills and has live
  # effects, so it is never auto-fired.
  def handle_event("send-feishu-test-message", _params, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can run the first-message smoke."),
      project_resource_write_attempt(
        "integration.feishu.first_message_smoke",
        "project_im_connect",
        "integration",
        %{"side_effects" => "billable_llm_wake"}
      ),
      fn socket -> {:noreply, run_feishu_first_message(socket)} end
    )
  end

  def handle_event("create_slack_connect", %{"slack_connect" => attrs}, socket),
    do:
      create_connect(
        socket,
        "slack",
        attrs,
        gettext("Slack connect created. Open the install URL to finish the OAuth install.")
      )

  # Keep the manifest preview (and the form values) in sync with the typed app
  # name so the manifest the user pastes matches the credentials they'll create.
  def handle_event("slack_form_changed", %{"slack_connect" => attrs}, socket) do
    {:noreply,
     socket
     |> assign(:slack_connect_form, slack_connect_form(attrs))
     |> assign_slack_manifest(attrs["app_name"] || "")}
  end

  def handle_event("open_integration_setup", %{"provider" => provider}, socket)
      when provider in ["choose", "feishu", "slack"] do
    {:noreply,
     if socket.assigns.can_manage_project do
       assign(socket, :integration_setup_provider, provider)
     else
       socket
     end}
  end

  def handle_event("open_integration_setup", _params, socket), do: {:noreply, socket}

  def handle_event("close_integration_setup", _params, socket) do
    {:noreply, assign(socket, :integration_setup_provider, nil)}
  end

  def handle_event("disable_connect", %{"id" => connect_id}, socket),
    do:
      lifecycle_connect(
        socket,
        connect_id,
        &ProjectIMConnects.disable_project_connect/4,
        gettext("Connect disabled.")
      )

  def handle_event("enable_connect", %{"id" => connect_id}, socket),
    do:
      lifecycle_connect(
        socket,
        connect_id,
        &ProjectIMConnects.enable_project_connect/4,
        gettext("Connect enabled.")
      )

  def handle_event("signal-new-code", _params, socket) do
    if socket.assigns.can_manage_project do
      case ProjectSignal.start_claim(
             socket.assigns.current_org,
             socket.assigns.project,
             socket.assigns.current_user.id
           ) do
        {:ok, status} ->
          {:noreply,
           socket
           |> assign(:signal_status, Map.delete(status, "claim"))
           |> assign(:signal_claim, status["claim"])}

        {:error, :not_configured} ->
          {:noreply,
           put_flash(socket, :error, gettext("Signal has no number on this server yet."))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Couldn't create a Signal code."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Only project admins can do this."))}
    end
  end

  def handle_event("signal-dismiss-code", _params, socket),
    do: {:noreply, assign(socket, :signal_claim, nil)}

  def handle_event("signal-remove-binding", %{"id" => binding_id}, socket) do
    if socket.assigns.can_manage_project do
      case ProjectSignal.remove_binding(
             socket.assigns.current_org,
             socket.assigns.project,
             binding_id
           ) do
        {:ok, status} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Signal chat disconnected."))
           |> assign(:signal_status, status)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Couldn't disconnect the Signal chat."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Only project admins can do this."))}
    end
  end

  def handle_event("delete_connect", %{"id" => connect_id}, socket),
    do:
      lifecycle_connect(
        socket,
        connect_id,
        &ProjectIMConnects.delete_project_connect/4,
        gettext("Connect deleted.")
      )

  # ---- Connections (OAuth account) events ----

  def handle_event("connect_oauth", %{"oauth" => %{"provider" => provider} = params}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can connect accounts."),
      project_resource_write_attempt(
        "project_oauth_connection.authorization_started",
        "project_oauth_connection",
        "oauth",
        %{"provider_configured" => nonblank?(provider)}
      ),
      fn socket ->
        {:noreply,
         assign(socket, :connection_detail, %{
           "source" => "oauth",
           "kind" => "managed_oauth",
           "label" => oauth_provider_label(provider),
           "provider" => provider,
           "alias" => params["alias"]
         })}
      end
    )
  end

  def handle_event("disconnect_oauth", %{"id" => binding_id}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage connected accounts."),
      project_resource_write_attempt(
        "project_oauth_connection.deleted",
        "project_oauth_connection",
        "oauth",
        %{"binding_id_configured" => nonblank?(binding_id)}
      ),
      fn socket ->
        org = socket.assigns.current_org
        project = socket.assigns.project

        case ProjectOAuthConnections.delete_connection(
               org.id,
               project.id,
               binding_id,
               audit_opts(socket)
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Account disconnected."))
             |> load_tab(:connections)}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, oauth_error_message(reason))
             |> load_tab(:connections)}
        end
      end
    )
  end

  def handle_event("disable_oauth", %{"id" => binding_id}, socket),
    do:
      lifecycle_oauth_connection(
        socket,
        binding_id,
        &ProjectOAuthConnections.disable_connection/4,
        gettext("Account disabled.")
      )

  def handle_event("enable_oauth", %{"id" => binding_id}, socket),
    do:
      lifecycle_oauth_connection(
        socket,
        binding_id,
        &ProjectOAuthConnections.enable_connection/4,
        gettext("Account enabled.")
      )

  # ---- Connections (Composio account) events ----

  def handle_event("connect_composio", %{"toolkit" => toolkit}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can connect accounts."),
      project_resource_write_attempt(
        "project_composio_connection.authorization_started",
        "composio_connection",
        "composio",
        %{"toolkit_configured" => nonblank?(toolkit)}
      ),
      fn socket ->
        {:noreply,
         assign(socket, :connection_detail, %{
           "source" => "composio",
           "kind" => "composio",
           "label" => toolkit,
           "toolkit" => toolkit
         })}
      end
    )
  end

  def handle_event("disconnect_composio", %{"id" => account_id}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage connected accounts."),
      project_resource_write_attempt(
        "project_composio_connection.deleted",
        "composio_connection",
        "composio",
        %{"account_id_configured" => nonblank?(account_id)}
      ),
      fn socket ->
        org = socket.assigns.current_org
        project = socket.assigns.project

        case ProjectComposioConnections.delete_connection(
               org.id,
               project.id,
               account_id,
               audit_opts(socket)
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Account disconnected."))
             |> load_tab(:connections)}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, composio_error_message(reason))
             |> load_tab(:connections)}
        end
      end
    )
  end

  # ---- Skills events ----

  def handle_event("view_project_skill", %{"loc" => location}, socket) do
    skill =
      Enum.find(
        socket.assigns.project_user_skills ++ socket.assigns.project_system_skills,
        &(&1["location"] == location)
      )

    {:noreply, assign(socket, :project_skill_viewing, skill)}
  end

  def handle_event("close_project_skill", _params, socket) do
    {:noreply, assign(socket, :project_skill_viewing, nil)}
  end

  def handle_event("new_project_skill", _params, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage skills."),
      fn socket ->
        {:noreply,
         socket
         |> assign(:project_skill_composing, true)
         |> assign(:project_skill_form, @empty_skill_form)
         |> assign(:project_skill_error, nil)}
      end
    )
  end

  def handle_event("cancel_new_project_skill", _params, socket) do
    {:noreply, assign(socket, :project_skill_composing, false)}
  end

  def handle_event("validate_project_skill", %{"skill" => attrs}, socket) do
    if socket.assigns.can_manage_project do
      {:noreply, assign(socket, :project_skill_form, Map.merge(@empty_skill_form, attrs))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("create_project_skill", %{"skill" => attrs}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage skills."),
      fn socket ->
        case socket.assigns.project_skill_agent do
          nil ->
            {:noreply, put_flash(socket, :error, gettext("Create an Agent Swarm agent first."))}

          agent ->
            case Skills.create_user_skill(socket.assigns.current_org, agent, attrs) do
              {:ok, _file} ->
                {:noreply,
                 socket
                 |> assign(:project_skill_composing, false)
                 |> assign(:project_skill_form, @empty_skill_form)
                 |> put_flash(:info, gettext("Skill created."))
                 |> load_project_skills()}

              {:error, :invalid_name} ->
                {:noreply,
                 put_flash(
                   socket,
                   :error,
                   gettext("Give the skill a name (letters or numbers).")
                 )}

              {:error, :duplicate} ->
                {:noreply,
                 put_flash(socket, :error, gettext("A skill with that name already exists."))}

              {:error, reason}
              when reason in [
                     "activation must be regular or per-message",
                     "miniskills require a name and description",
                     "miniskill instructions exceed 2 KiB"
                   ] ->
                {:noreply, put_flash(socket, :error, reason)}

              {:error, _reason} ->
                {:noreply, put_flash(socket, :error, project_skill_runtime_error())}
            end
        end
      end
    )
  end

  def handle_event("validate_project_skill_upload", _params, socket) do
    {:noreply, assign(socket, :project_skill_error, project_skill_upload_client_error(socket))}
  end

  def handle_event("delete_project_skill", %{"loc" => location}, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage skills."),
      project_resource_write_attempt(
        "skill.group.deleted",
        "skill",
        "skills",
        %{"location_configured" => nonblank?(location)}
      ),
      fn socket ->
        cond do
          is_nil(socket.assigns.project_skill_agent) ->
            {:noreply, socket}

          not known_project_user_skill?(socket, location) ->
            {:noreply, socket}

          true ->
            case Skills.delete_user_skill(
                   socket.assigns.current_org,
                   socket.assigns.project_skill_agent,
                   location,
                   audit_opts(socket)
                 ) do
              {:ok, _result} ->
                {:noreply,
                 socket
                 |> assign(:project_skill_viewing, nil)
                 |> put_flash(:info, gettext("Skill deleted."))
                 |> load_project_skills()}

              {:error, reason}
              when reason in [
                     "activation must be regular or per-message",
                     "miniskills require a name and description",
                     "miniskill instructions exceed 2 KiB"
                   ] ->
                {:noreply, put_flash(socket, :error, reason)}

              {:error, _reason} ->
                {:noreply, put_flash(socket, :error, project_skill_runtime_error())}
            end
        end
      end
    )
  end

  # ---- Plugins events ----

  def handle_event("filter_project_plugins", params, socket) do
    {:noreply,
     socket
     |> assign(:project_plugin_query, trim(params["query"]))
     |> assign(
       :project_plugin_source_filter,
       valid_plugin_source_filter(params["source"])
     )}
  end

  def handle_event("set_project_plugin_state", %{"state" => state}, socket) do
    {:noreply, assign(socket, :project_plugin_state_filter, valid_plugin_state_filter(state))}
  end

  def handle_event("clear_plugin_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:project_plugin_query, "")
     |> assign(:project_plugin_state_filter, "all")
     |> assign(:project_plugin_source_filter, "all")}
  end

  def handle_event("retry_plugins", _params, socket), do: {:noreply, load_tab(socket, :plugins)}

  def handle_event("new_project_plugin", _params, socket) do
    if socket.assigns.can_manage_project do
      {:noreply,
       socket
       |> assign(:project_plugin_panel, %{mode: :create, owner_scope: "group"})
       |> assign(:project_plugin_panel_error, nil)
       |> assign(:project_plugin_form, PluginForm.empty_form())}
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only Agent Swarm admins can manage plugins."))}
    end
  end

  def handle_event("connect_plugin", %{"id" => plugin_id} = params, socket) do
    open_plugin_connection_detail(socket, plugin_id, params["connection"], "connect")
  end

  def handle_event("disconnect_plugin", %{"id" => plugin_id} = params, socket) do
    open_plugin_connection_detail(socket, plugin_id, params["connection"], "disconnect")
  end

  def handle_event("close_connection_detail", _params, socket),
    do: {:noreply, assign(socket, :connection_detail, nil)}

  def handle_event("confirm_connection", _params, socket) do
    case socket.assigns.connection_detail do
      nil ->
        {:noreply, socket}

      detail ->
        require_project_admin(
          socket,
          gettext("Only Agent Swarm admins can connect accounts."),
          connection_write_attempt(detail),
          fn socket ->
            if detail["action"] == "disconnect",
              do: disconnect_confirmed_plugin_connection(socket, detail),
              else: start_confirmed_connection(socket, detail)
          end
        )
    end
  end

  def handle_event("edit_plugin", %{"id" => plugin_id}, socket) do
    plugin = find_project_plugin(socket.assigns.project_plugin_definitions, plugin_id)

    if socket.assigns.can_manage_project and editable_group_plugin?(plugin) do
      {:noreply,
       socket
       |> assign(:project_plugin_panel, %{mode: :edit, owner_scope: "group", plugin: plugin})
       |> assign(:project_plugin_panel_error, nil)
       |> assign(:project_plugin_form, PluginForm.form_for_definition(plugin))}
    else
      {:noreply, put_flash(socket, :error, gettext("This plugin cannot be edited here."))}
    end
  end

  def handle_event("close_plugin_panel", _params, socket) do
    {:noreply,
     socket
     |> assign(:project_plugin_panel, nil)
     |> assign(:project_plugin_panel_error, nil)
     |> assign(:project_plugin_form, PluginForm.empty_form())}
  end

  def handle_event("create_group_plugin", params, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage plugins."),
      project_resource_write_attempt(
        "plugin.group_definition.created",
        "plugin",
        "plugins",
        %{"name_configured" => nonblank?(params["name"])}
      ),
      fn socket ->
        org = socket.assigns.current_org
        project = socket.assigns.project

        with {:ok, attrs} <- PluginForm.parse_attrs(params),
             {:ok, definition} <-
               Plugins.create_group_definition(org.id, project.id, attrs, audit_opts(socket)) do
          {:noreply,
           socket
           |> put_flash(:info, gettext("Plugin created: %{id}.", id: definition["plugin_id"]))
           |> assign(:project_plugin_panel, nil)
           |> assign(:project_plugin_panel_error, nil)
           |> assign(:project_plugin_form, PluginForm.empty_form())
           |> load_tab(:plugins)}
        else
          {:error, :invalid_refs_json} ->
            {:noreply,
             put_project_plugin_editor_error(
               socket,
               params,
               gettext("Refs JSON must be an object.")
             )}

          {:error, :invalid_setup_destination} ->
            {:noreply,
             put_project_plugin_editor_error(
               socket,
               params,
               gettext("Choose a valid setup destination.")
             )}

          {:error, {:bad_request, message}} when is_binary(message) ->
            {:noreply, put_project_plugin_editor_error(socket, params, message)}

          {:error, reason} ->
            {:noreply,
             put_project_plugin_editor_error(socket, params, plugin_error_message(reason))}
        end
      end
    )
  end

  def handle_event("update_group_plugin", params, socket) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage plugins."),
      project_resource_write_attempt(
        "plugin.group_definition.updated",
        "plugin",
        "plugins",
        %{"plugin_id_configured" => nonblank?(params["plugin_id"])}
      ),
      fn socket ->
        org = socket.assigns.current_org
        project = socket.assigns.project

        with plugin_id when plugin_id != "" <- trim(params["plugin_id"]),
             {:ok, attrs} <- PluginForm.parse_attrs(params, allow_blank_refs: true),
             {:ok, _definition} <-
               Plugins.update_group_definition(
                 org.id,
                 project.id,
                 plugin_id,
                 attrs,
                 audit_opts(socket)
               ) do
          {:noreply,
           socket
           |> put_flash(:info, gettext("Plugin updated."))
           |> assign(:project_plugin_panel, nil)
           |> assign(:project_plugin_panel_error, nil)
           |> assign(:project_plugin_form, PluginForm.empty_form())
           |> load_tab(:plugins)}
        else
          "" ->
            {:noreply,
             put_project_plugin_editor_error(socket, params, gettext("Plugin is required."))}

          {:error, :invalid_refs_json} ->
            {:noreply,
             put_project_plugin_editor_error(
               socket,
               params,
               gettext("Refs JSON must be an object.")
             )}

          {:error, :invalid_setup_destination} ->
            {:noreply,
             put_project_plugin_editor_error(
               socket,
               params,
               gettext("Choose a valid setup destination.")
             )}

          {:error, {:bad_request, message}} when is_binary(message) ->
            {:noreply, put_project_plugin_editor_error(socket, params, message)}

          {:error, reason} ->
            {:noreply,
             put_project_plugin_editor_error(socket, params, plugin_error_message(reason))}
        end
      end
    )
  end

  def handle_event("enable_plugin", %{"id" => plugin_id}, socket) do
    mutate_plugin_enablement(socket, plugin_id, true)
  end

  def handle_event("disable_plugin", %{"id" => plugin_id}, socket) do
    mutate_plugin_enablement(socket, plugin_id, false)
  end

  defp runtime_auth_request_selection(id, selected, request) do
    cond do
      selected && request ->
        Map.put(selected, :request_id, request["request_id"])

      selected ->
        selected

      request ->
        %{
          id: id,
          provider: "待读取",
          status: "unknown",
          target: %{"kind" => "compute_workload", "workload_id" => id},
          request_id: request["request_id"]
        }

      true ->
        nil
    end
  end

  defp mutate_plugin_enablement(socket, plugin_id, enabled?) do
    if plugin_id == "android-control" && enabled? do
      case Environments.android_control_status(socket.assigns.project.id) do
        {:ok, %{entitled: true}} ->
          do_mutate_plugin_enablement(socket, plugin_id, enabled?)

        {:ok, %{entitled: false}} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Android connector access is not enabled for this organization.")
           )}

        {:error, _reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Android admission status is unavailable. Try again shortly.")
           )}
      end
    else
      do_mutate_plugin_enablement(socket, plugin_id, enabled?)
    end
  end

  defp do_mutate_plugin_enablement(socket, plugin_id, enabled?) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage plugins."),
      project_resource_write_attempt(
        if(enabled?,
          do: "plugin.group_enablement.enabled",
          else: "plugin.group_enablement.disabled"
        ),
        "plugin",
        "plugins",
        %{"plugin_id_configured" => nonblank?(plugin_id)}
      ),
      fn socket ->
        org = socket.assigns.current_org
        project = socket.assigns.project

        result =
          if enabled? do
            Plugins.enable_project_plugin(org.id, project.id, plugin_id, audit_opts(socket))
          else
            Plugins.disable_project_plugin(org.id, project.id, plugin_id, audit_opts(socket))
          end

        case result do
          {:ok, _enablement} ->
            message =
              if enabled?, do: gettext("Plugin enabled."), else: gettext("Plugin disabled.")

            {:noreply, socket |> put_flash(:info, message) |> load_tab(:plugins)}

          {:error, {:bad_request, message}} when is_binary(message) ->
            {:noreply, put_flash(socket, :error, message)}

          {:error, reason} ->
            {:noreply,
             socket |> put_flash(:error, plugin_error_message(reason)) |> load_tab(:plugins)}
        end
      end
    )
  end

  defp handle_project_skill_upload_progress(:project_skill_file, entry, socket) do
    if entry.done? do
      body =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, File.read!(path)}
        end)

      {:noreply, store_uploaded_project_skill(socket, body)}
    else
      {:noreply, socket}
    end
  end

  defp store_uploaded_project_skill(socket, body) do
    cond do
      not socket.assigns.can_manage_project ->
        put_flash(socket, :error, gettext("Only Agent Swarm admins can manage skills."))

      is_nil(socket.assigns.project_skill_agent) ->
        put_flash(socket, :error, gettext("Create an Agent Swarm agent first."))

      true ->
        case Skills.upload_user_skill(
               socket.assigns.current_org,
               socket.assigns.project_skill_agent,
               body
             ) do
          {:ok, _file} ->
            socket
            |> assign(:project_skill_error, nil)
            |> put_flash(:info, gettext("Skill uploaded."))
            |> load_project_skills()

          {:error, reason}
          when reason in [:missing_frontmatter, :missing_frontmatter_close, :invalid_name] ->
            assign(socket, :project_skill_error, project_skill_format_error(reason))

          {:error, :duplicate} ->
            assign(
              socket,
              :project_skill_error,
              gettext("A skill with that name already exists.")
            )

          {:error, _reason} ->
            put_flash(socket, :error, project_skill_runtime_error())
        end
    end
  end

  defp project_skill_upload_client_error(socket) do
    case upload_errors(socket.assigns.uploads.project_skill_file) do
      [] ->
        socket.assigns.project_skill_error

      [error | _] ->
        case error do
          :too_large -> gettext("SKILL.md must be smaller than 200 KB.")
          :not_accepted -> gettext("Upload a Markdown file with SKILL.md frontmatter.")
          _ -> gettext("The file could not be uploaded. Please try again.")
        end
    end
  end

  defp project_skill_format_error(:missing_frontmatter),
    do: gettext("SKILL.md must start with YAML frontmatter delimited by ---")

  defp project_skill_format_error(:missing_frontmatter_close),
    do: gettext("SKILL.md frontmatter is missing its closing --- delimiter")

  defp project_skill_format_error(:invalid_name),
    do: gettext("SKILL.md frontmatter needs a non-empty name (letters or numbers)")

  defp project_skill_runtime_error,
    do: gettext("The runtime is unreachable right now. Try again shortly.")

  defp known_project_user_skill?(socket, location) do
    Enum.any?(
      socket.assigns.project_user_skills,
      &(&1["location"] == location and &1["deletable"] == true)
    )
  end

  defp create_connect(socket, provider, attrs, ok_message) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage integrations."),
      project_resource_write_attempt(
        "integration.#{provider}.created",
        "project_im_connect",
        "integration",
        %{"provider_configured" => nonblank?(provider)}
      ),
      fn socket ->
        org = socket.assigns.current_org
        project = socket.assigns.project

        case ProjectIMConnects.create_project_connect(
               org.id,
               project.id,
               provider,
               attrs,
               audit_opts(socket)
             ) do
          {:ok, connect} ->
            # When `ok_message` is nil, derive it from the connect's `"action"`
            # marker so a reused or refreshed connect is not reported as new.
            {:noreply,
             socket
             |> put_flash(:info, ok_message || connect_action_message(connect))
             |> load_tab(:integrations)}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, project_im_error_message(reason))
             |> load_tab(:integrations)}
        end
      end
    )
  end

  # Build Feishu connect attrs from the selected binding's app_id and display
  # name (falling back to the binding name when the field is blank). Salix
  # sources secrets from the tenant store.
  defp feishu_connect_attrs(attrs, assigns) do
    app_id = attrs["app_id"]
    binding = Enum.find(assigns.feishu_bot_bindings, &(&1.app_id == app_id))
    fallback_name = (binding && (binding.display_name || binding.app_id)) || "Bridge"

    %{
      "app_id" => app_id,
      "app_name" => nonblank_param(attrs["app_name"], fallback_name)
    }
  end

  defp nonblank_param(value, fallback) do
    case value && String.trim(value) do
      nil -> fallback
      "" -> fallback
      trimmed -> trimmed
    end
  end

  # Render create/resync feedback from the response-only `"action"` marker set
  # by ProjectIMConnects.create_project_connect/4.
  defp connect_action_message(%{"action" => "resynced"}),
    do:
      gettext(
        "Reused the existing Feishu connect and refreshed its credentials from the org app."
      )

  defp connect_action_message(_connect),
    do: gettext("Feishu webhook connect ready.")

  defp lifecycle_connect(socket, connect_id, fun, ok_message) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage integrations."),
      project_resource_write_attempt(
        "integration.connect.#{connect_lifecycle_name(fun)}",
        "project_im_connect",
        "integration",
        %{"connect_id_configured" => nonblank?(connect_id)}
      ),
      fn socket ->
        org = socket.assigns.current_org
        project = socket.assigns.project

        case fun.(org.id, project.id, connect_id, audit_opts(socket)) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, ok_message) |> load_tab(:integrations)}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, project_im_error_message(reason))
             |> load_tab(:integrations)}
        end
      end
    )
  end

  defp lifecycle_oauth_connection(socket, binding_id, fun, ok_message) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can manage connected accounts."),
      project_resource_write_attempt(
        "project_oauth_connection.#{oauth_connection_lifecycle_name(fun)}",
        "project_oauth_connection",
        "oauth",
        %{"binding_id_configured" => nonblank?(binding_id)}
      ),
      fn socket ->
        org = socket.assigns.current_org
        project = socket.assigns.project

        case fun.(org.id, project.id, binding_id, audit_opts(socket)) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, ok_message) |> load_tab(:connections)}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, oauth_error_message(reason))
             |> load_tab(:connections)}
        end
      end
    )
  end

  # The provider callback (on Salix) returns the browser to this connections
  # page; build the absolute URL from the current request, dropping any query so
  # a previous `?oauth_error=` doesn't ride along.
  # The connecting user's granted capabilities (first-run onboarding record);
  # a user who skipped onboarding has none and gets the adapter defaults.
  defp user_capabilities(socket) do
    case BridgeForTeams.UserOnboardings.ensure_onboarding(socket.assigns.current_user.id) do
      {:ok, onboarding} -> onboarding.capabilities || %{}
      _error -> %{}
    end
  end

  defp oauth_redirect_after(socket) do
    case socket.assigns[:current_url] do
      url when is_binary(url) and url != "" ->
        url |> URI.parse() |> Map.put(:query, nil) |> Map.put(:fragment, nil) |> URI.to_string()

      _ ->
        nil
    end
  end

  defp create_provisioned_environment(socket, attrs) do
    case Environments.create_device_provision_request(
           socket.assigns.project.id,
           attrs,
           audit_opts(socket)
         ) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> assign(:env_form, nil)
         |> put_flash(:info, "Device connection request created.")
         |> load_tab(:environments)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :env_form, env_form(attrs, changeset))}

      {:error, :provisioner_offline} ->
        {:noreply, put_flash(socket, :error, "Runner is offline.")}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Could not create the device connection.")}
    end
  end

  # ---- helpers ----

  # Map-backed forms (no phoenix_ecto, so we don't `to_form` a changeset). On a
  # changeset error we thread the changeset errors back onto the form.
  defp agent_form(params, changeset \\ nil) do
    to_form(stringify(params), as: :agent, errors: form_errors(changeset))
  end

  defp agent_form_defaults do
    %{
      "agent_type" => "internal",
      "role" => "worker",
      "runtime_location" => "connected",
      "workload_provider" => "codex",
      "workload_query" => "",
      "show_unavailable_workloads" => false
    }
  end

  defp assign_agent_environments(socket) do
    {:ok, environments} =
      Environments.list_projected_environments(socket.assigns.project.id)

    socket
    |> assign(:agent_environments, environments)
    |> assign(:agent_environments_error, nil)
    |> assign(:agent_environments_loaded, true)
  end

  defp assign_triage_configuration_path(socket) do
    path =
      case Agents.get_project_agent(socket.assigns.project.id, socket.assigns.router_agent_id) do
        {:ok, router} ->
          ~p"/orgs/#{socket.assigns.current_org.slug}/triage?#{%{agent: router.id}}" <>
            "#triage-worker-configuration"

        _ ->
          nil
      end

    assign(socket, :triage_configuration_path, path)
  end

  defp load_agent_page(socket, cursor) do
    socket =
      socket
      |> assign(:agent_page_cursor, cursor)
      |> assign(:router_agent_id, current_router_agent_id(socket.assigns.project))
      |> assign_triage_configuration_path()
      |> assign(
        :triage_worker_binding,
        case Agents.triage_worker_binding(socket.assigns.project) do
          {:ok, binding} -> binding
          _ -> nil
        end
      )

    case Agents.page_agents(socket.assigns.project, limit: @agent_page_limit, cursor: cursor) do
      {:ok, page} ->
        socket
        |> assign(:agents, page.items)
        |> assign(:salix_agents_error, nil)
        |> assign(:agent_next_cursor, page.next_cursor)

      {:error, reason} ->
        socket
        |> assign(:agents, [])
        |> assign(:salix_agents_error, reason)
        |> assign(:agent_next_cursor, nil)
    end
  end

  defp maybe_load_external_targets(socket, attrs) do
    attrs = stringify(attrs)

    if attrs["agent_type"] == "external" or socket.assigns.rebind_agent do
      case attrs["runtime_location"] || "connected" do
        "compute" ->
          provider = normalize_workload_provider(attrs["workload_provider"])
          query = String.trim(attrs["workload_query"] || "")
          show_unavailable? = show_unavailable_workloads?(attrs["show_unavailable_workloads"])

          if socket.assigns.external_workload_items == [] or
               provider != external_workload_provider(socket) or
               query != external_workload_query(socket) or
               show_unavailable? != external_workload_show_unavailable?(socket) do
            load_external_workloads(
              socket,
              provider: provider,
              query: query,
              show_unavailable: show_unavailable?
            )
          else
            socket
          end

        _ ->
          if socket.assigns.agent_environments_loaded,
            do: socket,
            else: assign_agent_environments(socket)
      end
    else
      socket
    end
  end

  defp reset_agent_environments(socket) do
    socket
    |> assign(:agent_environments, [])
    |> assign(:agent_environments_error, nil)
    |> assign(:agent_environments_loaded, false)
  end

  defp reset_external_workloads(socket) do
    socket
    |> assign(:external_workload_items, [])
    |> assign(:external_workload_next_cursor, nil)
    |> assign(:external_workload_error, nil)
    |> assign(:external_workload_read_at, nil)
  end

  defp load_external_workloads(socket, opts \\ []) do
    provider = Keyword.get(opts, :provider, external_workload_provider(socket))
    query = Keyword.get(opts, :query, external_workload_query(socket))

    show_unavailable? =
      Keyword.get(opts, :show_unavailable, external_workload_show_unavailable?(socket))

    next? = Keyword.get(opts, :next, false)
    cursor = if next?, do: socket.assigns.external_workload_next_cursor, else: nil

    page_opts = [limit: 50, query: query, include_unavailable: show_unavailable?]
    page_opts = if cursor, do: Keyword.put(page_opts, :cursor, cursor), else: page_opts

    case Agents.page_external_worker_targets(socket.assigns.project, provider, page_opts) do
      {:ok, page} ->
        page = stringify(page)

        items =
          (page["items"] || [])
          |> Enum.map(&stringify_nested_map/1)
          |> filter_external_workloads(show_unavailable?)

        socket
        |> assign(:external_workload_items, items)
        |> assign(:external_workload_next_cursor, page["next_cursor"])
        |> assign(:external_workload_read_at, page["read_at"])
        |> assign(:external_workload_error, nil)
        |> clear_dropped_external_workload_selection(items)

      {:error, reason} ->
        socket
        |> assign(:external_workload_items, [])
        |> assign(:external_workload_error, reason)
        |> assign(:external_workload_next_cursor, nil)
        |> assign(:external_workload_read_at, nil)
        |> clear_dropped_external_workload_selection([])
    end
  end

  defp clear_dropped_external_workload_selection(%{assigns: %{agent_form: nil}} = socket, _items),
    do: socket

  defp clear_dropped_external_workload_selection(socket, items) do
    selected = agent_form_value(socket.assigns.agent_form, :workload_id)

    if selected in [nil, ""] or Enum.any?(items, &(&1["workload_id"] == selected)) do
      socket
    else
      params =
        socket.assigns.agent_form.params
        |> stringify()
        |> Map.put("workload_id", "")

      assign(socket, :agent_form, agent_form(params))
    end
  end

  defp external_workload_provider(socket) do
    socket.assigns.agent_form
    |> case do
      nil -> "codex"
      form -> agent_form_value(form, :workload_provider, "codex")
    end
    |> normalize_workload_provider()
  end

  defp external_workload_show_unavailable?(socket) do
    case socket.assigns.agent_form do
      nil -> false
      form -> show_unavailable_workloads?(agent_form_value(form, :show_unavailable_workloads))
    end
  end

  defp show_unavailable_workloads?(value) when value in [true, "true", "1", "on"], do: true
  defp show_unavailable_workloads?(_value), do: false

  defp filter_external_workloads(items, true), do: items

  defp filter_external_workloads(items, false),
    do: Enum.filter(items, &Map.get(&1, "selectable", false))

  defp external_workload_query(socket) do
    case socket.assigns.agent_form do
      nil -> ""
      form -> agent_form_value(form, :workload_query, "") |> String.trim()
    end
  end

  defp normalize_workload_provider(provider) when provider in ["codex", "pi", "claude"],
    do: provider

  defp normalize_workload_provider(_), do: "codex"

  defp normalize_agent_form_attrs(socket, attrs) do
    attrs = stringify(attrs)
    agent_type = attrs["agent_type"] || "internal"

    attrs =
      attrs
      |> Map.put("agent_type", agent_type)
      |> Map.put("role", "worker")

    if agent_type == "external" do
      runtime_location =
        if attrs["runtime_location"] in ["connected", "compute"],
          do: attrs["runtime_location"],
          else: "connected"

      attrs =
        attrs
        |> Map.put("runtime_location", runtime_location)
        |> Map.put("workload_provider", normalize_workload_provider(attrs["workload_provider"]))
        |> Map.put("workload_query", String.trim(attrs["workload_query"] || ""))
        |> Map.put(
          "show_unavailable_workloads",
          show_unavailable_workloads?(attrs["show_unavailable_workloads"])
        )

      if runtime_location == "connected" do
        device_id =
          normalize_selected_agent_environment(
            socket.assigns.agent_environments,
            attrs["device_id"] || ""
          )

        device_runtime_id =
          normalize_selected_agent_runtime(
            socket.assigns.agent_environments,
            device_id,
            attrs["device_runtime_id"] || ""
          )

        attrs
        |> Map.put("device_id", device_id)
        |> Map.put("device_runtime_id", device_runtime_id)
      else
        attrs
        |> Map.put("device_id", "")
        |> Map.put("device_runtime_id", "")
      end
    else
      attrs
      |> Map.put("device_id", "")
      |> Map.put("device_runtime_id", "")
    end
  end

  defp rebind_form_attrs(socket, agent) do
    runtime_config = stringify(agent.salix["runtime_config"] || %{})

    runtime_location =
      if runtime_config["kind"] == "compute_workload", do: "compute", else: "connected"

    device_id =
      normalize_selected_agent_environment(
        socket.assigns.agent_environments,
        runtime_config["device_id"] || ""
      )

    device_runtime_id =
      normalize_selected_agent_runtime(
        socket.assigns.agent_environments,
        device_id,
        runtime_config["device_runtime_id"] || ""
      )

    %{
      "agent_type" => "external",
      "runtime_location" => runtime_location,
      "device_id" => device_id,
      "device_runtime_id" => device_runtime_id,
      "workload_provider" => get_in(runtime_config, ["runtime_spec", "provider"]) || "codex",
      "workload_id" => runtime_config["workload_id"] || "",
      "workload_query" => "",
      "show_unavailable_workloads" => false,
      "expected_binding_revision" => runtime_config["binding_revision"] || 0
    }
  end

  defp normalize_runtime_rebind_attrs(socket, attrs) do
    attrs = stringify(attrs)

    attrs =
      attrs
      |> Map.put("agent_type", "external")
      |> Map.put_new("runtime_location", "connected")
      |> Map.put("workload_provider", normalize_workload_provider(attrs["workload_provider"]))
      |> Map.put("workload_query", String.trim(attrs["workload_query"] || ""))
      |> Map.put(
        "show_unavailable_workloads",
        show_unavailable_workloads?(attrs["show_unavailable_workloads"])
      )

    if attrs["runtime_location"] == "compute" do
      Map.take(attrs, [
        "agent_type",
        "runtime_location",
        "workload_provider",
        "workload_query",
        "show_unavailable_workloads",
        "workload_id",
        "expected_binding_revision"
      ])
    else
      device_id =
        normalize_selected_agent_environment(
          socket.assigns.agent_environments,
          attrs["device_id"] || ""
        )

      device_runtime_id =
        normalize_selected_agent_runtime(
          socket.assigns.agent_environments,
          device_id,
          attrs["device_runtime_id"] || ""
        )

      attrs
      |> Map.put("device_id", device_id)
      |> Map.put("device_runtime_id", device_runtime_id)
    end
  end

  defp build_agent_create_attrs(socket, %{"agent_type" => "external"} = attrs) do
    create_attrs = maybe_put_nonblank(%{"role" => "worker"}, "name", attrs["name"])

    case build_external_target(socket, attrs) do
      {:ok, target} -> {:external, create_attrs, target}
      {:error, message} -> {:error, message}
    end
  end

  defp build_agent_create_attrs(_socket, attrs) do
    {:internal, Map.take(attrs, ["name", "role"])}
  end

  defp build_agent_rebind_attrs(socket, attrs) do
    with {expected, ""} <- Integer.parse(to_string(attrs["expected_binding_revision"] || "")),
         true <- expected >= 0,
         {:ok, target} <- build_external_target(socket, attrs) do
      {:ok, target, expected}
    else
      _ -> {:error, gettext("The binding changed. Reopen the form and try again.")}
    end
  end

  defp build_external_target(socket, %{"runtime_location" => "compute"} = attrs) do
    case Enum.find(
           socket.assigns.external_workload_items,
           &(&1["workload_id"] == attrs["workload_id"])
         ) do
      %{"selectable" => true} = item ->
        {:ok,
         %{
           "kind" => "compute_workload",
           "workload_id" => item["workload_id"],
           "selection_fence" => item["selection_fence"]
         }}

      %{} ->
        {:error, external_agent_form_error(:runtime_not_ready)}

      nil ->
        {:error, gettext("Select a Compute Workload.")}
    end
  end

  defp build_external_target(socket, attrs) do
    with nil <- socket.assigns.agent_environments_error,
         {:ok, env} <-
           fetch_selected_agent_environment(socket.assigns.agent_environments, attrs["device_id"]),
         {:ok, runtime} <- fetch_selected_agent_runtime(env, attrs["device_runtime_id"]),
         true <- runtime_ready?(runtime) do
      {:ok,
       %{
         "kind" => "connected_runtime",
         "device_id" => env["device_id"],
         "device_runtime_id" => device_runtime_id(runtime)
       }}
    else
      false ->
        {:error, external_agent_form_error(:runtime_not_ready)}

      reason when reason in [:unavailable, :timeout] ->
        {:error, agent_environment_error_message(reason)}

      {:error, reason} ->
        {:error, external_agent_form_error(reason)}

      reason ->
        {:error, agent_environment_error_message(reason)}
    end
  end

  defp fetch_selected_agent_environment(_environments, device_id) when device_id in [nil, ""] do
    {:error, :device_required}
  end

  defp fetch_selected_agent_environment(environments, device_id) do
    case selected_agent_environment(environments, device_id) do
      nil -> {:error, :device_required}
      env -> {:ok, env}
    end
  end

  defp fetch_selected_agent_runtime(_env, device_runtime_id)
       when device_runtime_id in [nil, ""] do
    {:error, :runtime_required}
  end

  defp fetch_selected_agent_runtime(env, device_runtime_id) do
    case Enum.find(external_agent_runtimes(env), &(device_runtime_id(&1) == device_runtime_id)) do
      nil -> {:error, :runtime_unavailable}
      runtime -> {:ok, runtime}
    end
  end

  defp maybe_put_nonblank(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put_nonblank(map, key, value), do: Map.put(map, key, value)

  defp external_agent_form_error(:device_required), do: gettext("Select a connected device.")
  defp external_agent_form_error(:runtime_required), do: gettext("Select an external runtime.")

  defp external_agent_form_error(:runtime_unavailable),
    do: gettext("Selected device does not report an external runtime.")

  defp external_agent_form_error(:runtime_not_ready),
    do: gettext("Selected external runtime is not ready.")

  defp external_agent_form_error(_reason), do: gettext("Could not create the external agent.")

  defp agent_environment_error_message(:unavailable),
    do: gettext("Devices are unavailable right now. Retry shortly.")

  defp agent_environment_error_message(:timeout),
    do: gettext("Loading devices timed out. Retry shortly.")

  defp agent_environment_error_message(_reason),
    do: gettext("Could not load connected devices.")

  defp runtime_rebind_error_message(:runtime_unavailable),
    do: gettext("Selected external runtime is not ready.")

  defp runtime_rebind_error_message(:runtime_not_found),
    do: gettext("Selected external runtime is no longer available.")

  defp runtime_rebind_error_message(:runtime_ambiguous),
    do: gettext("Selected external runtime is ambiguous. Select the device and runtime again.")

  defp runtime_rebind_error_message(:unsupported_agent_role),
    do: gettext("Only worker agents can be rebound to an external runtime.")

  defp runtime_rebind_error_message(:unsupported_runtime_binding),
    do: gettext("Only existing external workers can be rebound.")

  defp runtime_rebind_error_message(reason)
       when reason in [:stale_binding_revision, :binding_conflict],
       do: gettext("The binding changed. Reopen the form and try again.")

  defp runtime_rebind_error_message(:selection_changed),
    do: gettext("The selected Workload changed. Refresh the list and select it again.")

  defp runtime_rebind_error_message({:target_unavailable, reason}),
    do: gettext("The selected Workload is not ready: %{reason}.", reason: reason)

  defp runtime_rebind_error_message(_reason),
    do: gettext("Could not rebind the runtime.")

  defp salix_agents_error_message(:unavailable),
    do: gettext("Agent list is unavailable right now. Retry shortly.")

  defp salix_agents_error_message(:timeout),
    do: gettext("Loading the agent list timed out. Retry shortly.")

  defp salix_agents_error_message(_reason),
    do: gettext("Could not load the agent list.")

  defp agent_form_value(form, key, default \\ "") do
    string_key = to_string(key)
    field = form[String.to_existing_atom(string_key)]

    case field.value do
      value when value in [nil, ""] -> form.params[string_key] || default
      value -> value
    end
  rescue
    ArgumentError -> form.params[to_string(key)] || default
  end

  defp connected_agent_environments(environments) do
    environments
    |> Enum.filter(&(&1["status"] == "connected"))
    |> Enum.filter(&group_visible_environment?/1)
  end

  defp group_visible_environment?(env), do: environment_agent_id(env) in [nil, ""]

  defp selected_agent_environment(_environments, device_id) when device_id in [nil, ""],
    do: nil

  defp selected_agent_environment(environments, device_id) do
    Enum.find(connected_agent_environments(environments), &(&1["device_id"] == device_id))
  end

  defp normalize_selected_agent_environment(_environments, device_id) when device_id in [nil, ""],
    do: ""

  defp normalize_selected_agent_environment(environments, device_id) do
    if selected_agent_environment(environments, device_id), do: device_id, else: ""
  end

  defp normalize_selected_agent_runtime(environments, device_id, device_runtime_id) do
    with env when not is_nil(env) <- selected_agent_environment(environments, device_id),
         runtimes = [_ | _] <- external_agent_runtimes(env) do
      if Enum.any?(runtimes, &(device_runtime_id(&1) == device_runtime_id)) do
        device_runtime_id
      else
        ""
      end
    else
      _ -> ""
    end
  end

  defp agent_environment_options(environments) do
    environments
    |> connected_agent_environments()
    |> Enum.map(fn env ->
      name = environment_name(env)
      label = if name == env["device_id"], do: name, else: "#{name} / #{env["device_id"]}"
      {label, env["device_id"]}
    end)
  end

  defp agent_runtime_options(nil), do: []

  defp agent_runtime_options(env) do
    env
    |> external_agent_runtimes()
    |> Enum.map(fn runtime ->
      label =
        [
          runtime_value(runtime, "provider"),
          device_runtime_id(runtime),
          runtime_value(runtime, "version")
        ]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" / ")

      {label, device_runtime_id(runtime)}
    end)
  end

  defp selected_runtime(nil, _runtime_id), do: nil
  defp selected_runtime(_env, device_runtime_id) when device_runtime_id in [nil, ""], do: nil

  defp selected_runtime(env, device_runtime_id) do
    Enum.find(external_agent_runtimes(env), &(device_runtime_id(&1) == device_runtime_id))
  end

  defp runtime_rebindable_agent?(%Agent{role: "worker", salix: record}) do
    get_in(record, ["runtime_config", "kind"]) in ~w(external connected_runtime compute_workload)
  end

  defp runtime_rebindable_agent?(_), do: false

  defp runtime_ready?(nil), do: false
  defp runtime_ready?(runtime), do: runtime_value(runtime, "status") == "ready"

  defp runtime_pill_status(runtime) do
    if runtime_ready?(runtime), do: "ready", else: "error"
  end

  defp runtime_status_label(runtime) do
    cond do
      runtime_ready?(runtime) ->
        "ready"

      is_binary(runtime_value(runtime, "status")) and runtime_value(runtime, "status") != "" ->
        runtime_value(runtime, "status")

      true ->
        "not ready"
    end
  end

  defp runtime_version_label(runtime) do
    case runtime_value(runtime, "version") do
      version when is_binary(version) and version != "" -> version
      _ -> nil
    end
  end

  defp runtime_readiness_test_id("agent"), do: "codex-runtime-readiness"
  defp runtime_readiness_test_id("rebind_agent"), do: "rebind-codex-runtime-readiness"

  defp binding_summary(nil), do: gettext("None")

  defp binding_summary(config) when is_map(config) do
    config = stringify_nested_map(config)

    case config["kind"] do
      "compute_workload" ->
        provider = get_in(config, ["runtime_spec", "provider"]) || gettext("unknown")
        "#{String.capitalize(provider)} · #{short_binding_id(config["workload_id"])}"

      kind when kind in ["connected_runtime", "external"] ->
        provider = config["provider"] || gettext("unknown")
        "#{String.capitalize(provider)} · #{short_binding_id(config["device_runtime_id"])}"

      _ ->
        gettext("None")
    end
  end

  defp short_binding_id(value) when is_binary(value) and byte_size(value) > 12,
    do: String.slice(value, 0, 12)

  defp short_binding_id(value) when is_binary(value), do: value
  defp short_binding_id(_), do: gettext("unknown")

  defp workload_reason_label("provider_unsupported"), do: gettext("Provider unsupported")
  defp workload_reason_label("registration_unavailable"), do: gettext("Node unavailable")
  defp workload_reason_label("binding_unavailable"), do: gettext("Provider binding unavailable")
  defp workload_reason_label("environment_not_ready"), do: gettext("Environment not ready")
  defp workload_reason_label("allocation_not_ready"), do: gettext("Allocation not ready")
  defp workload_reason_label("workload_not_ready"), do: gettext("Workload not ready")
  defp workload_reason_label("runtime_missing"), do: gettext("Runtime missing")
  defp workload_reason_label("runtime_generation_mismatch"), do: gettext("Runtime is outdated")
  defp workload_reason_label("runtime_not_connected"), do: gettext("Runtime not connected")

  defp workload_reason_label("runtime_recovery_expired"),
    do: gettext("Runtime recovery needs operator attention")

  defp workload_reason_label("runtime_not_ready"), do: gettext("Runtime not ready")
  defp workload_reason_label("runtime_catching_up"), do: gettext("Runtime catching up")

  defp workload_reason_label("resource_capacity_exhausted"),
    do: gettext("Host capacity needs attention")

  defp workload_reason_label("scope_mismatch"), do: gettext("Outside this Agent Swarm")
  defp workload_reason_label(_), do: gettext("Unavailable")

  defp workload_availability_label(%{"selectable" => false, "reason" => reason}),
    do: workload_reason_label(reason)

  defp workload_availability_label(%{"availability" => "sleeping"}),
    do: gettext("Sleeping · starts when work arrives")

  defp workload_availability_label(%{"availability" => "queued"}),
    do: gettext("Waiting for Host capacity")

  defp workload_availability_label(%{"availability" => "starting"}),
    do: gettext("Starting")

  defp workload_availability_label(%{"availability" => "action_required"} = item),
    do: workload_reason_label(item["availability_issue"])

  defp workload_availability_label(_item), do: gettext("Ready to select")

  defp workload_availability_class(%{"availability" => "ready"}), do: "text-xs text-green-700"

  defp workload_availability_class(%{"availability" => "sleeping"}),
    do: "text-xs text-neutral-600"

  defp workload_availability_class(_item), do: "text-xs text-amber-700"

  defp reconcile_error_label(error) do
    ["code", "stage", "resource", "message", "available_bytes", "required_bytes"]
    |> Enum.flat_map(fn key ->
      case Map.fetch(error, key) do
        {:ok, value} -> ["#{key}=#{value}"]
        :error -> []
      end
    end)
    |> Enum.join(" / ")
  end

  defp external_agent_runtimes(env) do
    env
    |> environment_runtimes()
    |> Enum.filter(fn runtime ->
      RuntimeIds.external_runtime_provider?(runtime_value(runtime, "provider")) and
        device_runtime_id(runtime) != ""
    end)
  end

  defp environment_runtimes(env) do
    case env["device_runtimes"] do
      runtimes when is_list(runtimes) -> runtimes
      _ -> []
    end
  end

  defp environment_name(env) do
    case env["name"] || env["device_id"] do
      name when is_binary(name) and name != "" -> name
      _ -> env["device_id"]
    end
  end

  defp environment_agent_id(env), do: env["agent_id"]

  defp device_runtime_id(runtime), do: runtime_value(runtime, "device_runtime_id") || ""

  defp runtime_value(runtime, key) when is_map(runtime) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    cond do
      Map.has_key?(runtime, key) -> Map.get(runtime, key)
      not is_nil(atom_key) and Map.has_key?(runtime, atom_key) -> Map.get(runtime, atom_key)
      true -> nil
    end
  rescue
    ArgumentError -> Map.get(runtime, key)
  end

  defp conversation_form(params) do
    to_form(stringify(params), as: :conversation)
  end

  defp feishu_connect_form(params) do
    to_form(stringify(params), as: :feishu_connect)
  end

  # Select options for the bot-enabled org Feishu app bindings: label is the
  # binding's display_name (falling back to its app_id), value is the app_id the
  # connect is created against.
  defp feishu_binding_options(bindings) do
    Enum.map(bindings, fn binding -> {binding.display_name || binding.app_id, binding.app_id} end)
  end

  # The explicit first-message smoke bills and has live side effects, so it is
  # never auto-fired by Run checks; only this admin action can start it.
  # Connect-aware: only the `connect_id` identity is passed; secrets + router are
  # resolved inside Salix.
  defp run_feishu_first_message(socket) do
    case List.first(socket.assigns.feishu_connects || []) do
      nil ->
        put_flash(socket, :error, gettext("Create a Feishu connect first."))

      connect ->
        case Client.impl().feishu_first_message(%{"connect_id" => connect["connect_id"]}) do
          {:ok, _evidence} ->
            put_flash(
              socket,
              :info,
              gettext("Test @Bridge message round-tripped: the bot produced a reply.")
            )

          {:error, reason} ->
            put_flash(socket, :error, feishu_first_message_error(reason))
        end
    end
  end

  defp feishu_first_message_error(:router_not_configured),
    do: gettext("No router agent is configured for this Agent Swarm yet.")

  defp feishu_first_message_error(:no_assistant_reply),
    do: gettext("The message was delivered but the bot did not reply in time. Check LLM config.")

  defp feishu_first_message_error(:secrets_not_configured),
    do: gettext("Feishu bot secrets are not configured for this app.")

  defp feishu_first_message_error(reason)
       when reason in [:connect_not_found, :connect_inactive],
       do: gettext("This connect is not active; re-create or re-enable it, then retry.")

  defp feishu_first_message_error(reason) when reason in [:unavailable, :timeout],
    do: gettext("Salix is unavailable right now. Retry shortly.")

  defp feishu_first_message_error(_reason),
    do: gettext("Could not complete the test message round-trip.")

  defp slack_connect_form(params) do
    to_form(stringify(params), as: :slack_connect)
  end

  defp access_form(params \\ %{"email" => "", "role" => "user"}) do
    to_form(stringify(params), as: :access)
  end

  defp maybe_record_project_member_denied_attempt(socket, action, target_user_id, metadata) do
    _ =
      Memberships.record_project_member_write_attempt(
        socket.assigns.project.id,
        target_user_id,
        action,
        "denied",
        :forbidden,
        audit_opts(socket),
        metadata: metadata
      )

    :ok
  end

  defp project_resource_write_attempt(action, resource_type, surface, metadata) do
    {:project_resource_write_attempt, action, resource_type, surface, metadata}
  end

  defp environment_create_denied_attempt(attrs) do
    project_resource_write_attempt(
      "device.provision_requested",
      "device_provision_request",
      "device",
      %{"provisioner_id_configured" => nonblank?(attrs["provisioner_id"])}
    )
  end

  defp attempted_access_grant_metadata(params) do
    params = stringify(params)

    %{
      "attempted_email_configured" => nonblank?(params["email"]),
      "attempted_role" => params["role"],
      "surface" => "project_access"
    }
  end

  defp attempted_access_role_metadata(role) do
    %{
      "attempted_role" => role,
      "surface" => "project_access"
    }
  end

  defp require_project_admin(socket, message, fun) do
    require_project_admin(socket, message, nil, fun)
  end

  defp can_view_operations?(role), do: role in ["owner", "admin"]
  defp can_view_audit?(role), do: role in ["owner", "admin"]

  defp require_project_admin(socket, message, audit_action, fun) do
    if socket.assigns.can_manage_project do
      fun.(socket)
    else
      maybe_record_denied_attempt(socket, audit_action)
      {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp maybe_record_denied_attempt(_socket, nil), do: :ok

  defp maybe_record_denied_attempt(
         socket,
         {:project_resource_write_attempt, action, resource_type, surface, metadata}
       ) do
    metadata =
      socket
      |> project_resource_denied_metadata(surface)
      |> Map.merge(stringify(metadata))

    _ =
      Observability.record_write_attempt(%{
        org_id: socket.assigns.current_org.id,
        actor_user_id: socket.assigns.current_user.id,
        actor_label: audit_actor_label(socket.assigns.current_user),
        action: action,
        resource_type: resource_type,
        resource_label: socket.assigns.project.name,
        result: "denied",
        reason: :forbidden,
        request_id: Ecto.UUID.generate(),
        surface: surface,
        metadata: metadata
      })

    :ok
  end

  defp maybe_record_denied_attempt(socket, {:project, audit_action}) do
    _ =
      Projects.record_project_write_attempt(
        socket.assigns.project,
        audit_action,
        "denied",
        :forbidden,
        audit_opts(socket)
      )

    :ok
  end

  defp maybe_record_denied_attempt(socket, audit_action) do
    _ =
      Agents.record_agent_write_attempt(
        socket.assigns.project,
        audit_action,
        "denied",
        :forbidden,
        audit_opts(socket)
      )

    :ok
  end

  defp project_resource_denied_metadata(socket, surface) do
    %{
      "project_id" => socket.assigns.project.id,
      "salix_group_id" => socket.assigns.project.salix_group_id,
      "surface" => surface
    }
  end

  defp connect_lifecycle_name(fun) do
    cond do
      fun == (&ProjectIMConnects.disable_project_connect/4) -> "disabled"
      fun == (&ProjectIMConnects.enable_project_connect/4) -> "enabled"
      fun == (&ProjectIMConnects.delete_project_connect/4) -> "deleted"
      true -> "updated"
    end
  end

  defp oauth_connection_lifecycle_name(fun) do
    cond do
      fun == (&ProjectOAuthConnections.disable_connection/4) -> "disabled"
      fun == (&ProjectOAuthConnections.enable_connection/4) -> "enabled"
      true -> "updated"
    end
  end

  defp rename_form(params, changeset \\ nil) do
    to_form(stringify(params), as: :rename, errors: form_errors(changeset))
  end

  defp archive_project(socket) do
    project = socket.assigns.project

    case Projects.archive_project(project, audit_opts(socket)) do
      {:ok, _archived} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Agent Swarm \"%{name}\" archived.", name: project.name))
         |> push_navigate(to: ~p"/orgs/#{socket.assigns.current_org.slug}/projects")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not archive the Agent Swarm."))}
    end
  end

  # Archiving requires the swarm to be quiesced first: every IM connect on its
  # Agent Swarm disabled (so inbound IM traffic can't keep reaching it) and no
  # agent left holding a recurring schedule (so nothing keeps waking it). Returns
  # the first blocker found, or `nil` when archival may proceed. If Salix can't
  # confirm either state we refuse to archive rather than guess.
  defp archival_blocker(socket) do
    im_connects_blocker(socket) || schedules_blocker(socket)
  end

  defp im_connects_blocker(socket) do
    org = socket.assigns.current_org
    project = socket.assigns.project

    case ProjectIMConnects.list_project_connects(org.id, project.id, nil) do
      {:ok, connects} ->
        if Enum.any?(connects, &im_connect_active?/1), do: {:error, :active_connects}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp schedules_blocker(socket) do
    case Schedules.list_project_schedules(socket.assigns.project) do
      {:ok, []} -> nil
      {:ok, _schedules} -> {:error, :schedules_present}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp im_connect_active?(connect), do: is_nil(connect["disabled_at"])

  # ---- Connections (OAuth account) helpers ----

  defp oauth_runtime_unavailable?(connections_error, available_error) do
    connections_error in [:unavailable, :timeout] or available_error in [:unavailable, :timeout]
  end

  defp oauth_connection_enabled?(connection), do: Map.get(connection, "enabled", true) != false

  defp oauth_provider_label("github"), do: "GitHub"
  defp oauth_provider_label("google"), do: "Google"
  defp oauth_provider_label("linear"), do: "Linear"
  defp oauth_provider_label("notion"), do: "Notion"
  defp oauth_provider_label("slack"), do: "Slack"
  defp oauth_provider_label(other), do: other |> to_string() |> String.capitalize()

  defp oauth_account_name(connection) do
    case connection["provider_account_name"] || connection["provider_account_id"] do
      name when is_binary(name) and name != "" -> name
      _ -> "—"
    end
  end

  defp oauth_scopes(connection) do
    case connection["scopes"] do
      scopes when is_list(scopes) and scopes != [] -> Enum.join(scopes, ", ")
      _ -> "—"
    end
  end

  defp oauth_error_message(:group_not_ready),
    do: gettext("The runtime is not ready yet. Retry shortly.")

  defp oauth_error_message(:provider_not_configured),
    do: gettext("That platform isn't configured for your organization yet.")

  defp oauth_error_message({:precondition_failed, _}),
    do: gettext("That platform isn't configured for your organization yet.")

  defp oauth_error_message({:bad_request, _}),
    do: gettext("The platform rejected the authorization request.")

  defp oauth_error_message(reason) when reason in [:unavailable, :timeout],
    do: gettext("Salix is unavailable right now. Retry shortly.")

  defp oauth_error_message(_reason),
    do: gettext("Could not connect the account. Please try again.")

  # ---- Connections (Composio account) helpers ----

  # Precomputed per-toolkit row state for the Composio section, mirroring the
  # onboarding integrations step. Composio is org-wide (one API key), so
  # readiness is a single flag rather than per-platform.
  defp composio_toolkit_rows(connections, configured?, can_connect?) do
    Enum.map(ProjectComposioConnections.toolkits(), fn toolkit ->
      connection = composio_connection_for(connections, toolkit)

      state =
        cond do
          connection -> :connected
          configured? and can_connect? -> :connectable
          configured? -> :ask_admin
          true -> :unconfigured
        end

      %{toolkit: toolkit, state: state, connection: connection}
    end)
  end

  defp composio_connection_for(connections, toolkit) do
    Enum.find(connections, fn account ->
      ProjectComposioConnections.connection_toolkit(account) == toolkit and
        ProjectComposioConnections.connection_active?(account)
    end)
  end

  defp composio_account_id(%{"id" => id}) when is_binary(id), do: id
  defp composio_account_id(_account), do: nil

  defp composio_toolkit_label("gmail"), do: gettext("Gmail")
  defp composio_toolkit_label("googlecalendar"), do: gettext("Google Calendar")
  defp composio_toolkit_label("google_admin"), do: gettext("Google Admin")
  defp composio_toolkit_label("github"), do: "GitHub"
  defp composio_toolkit_label("linear"), do: "Linear"
  defp composio_toolkit_label("notion"), do: "Notion"
  defp composio_toolkit_label("slack"), do: "Slack"
  defp composio_toolkit_label(other), do: other |> to_string() |> String.capitalize()

  defp composio_toolkit_description("gmail"), do: gettext("Read and send email on your behalf.")

  defp composio_toolkit_description("googlecalendar"),
    do: gettext("See and manage your calendar events.")

  defp composio_toolkit_description("google_admin"),
    do:
      gettext(
        "Read Google Workspace group members for meeting reminders. Requires custom Google OAuth setup."
      )

  defp composio_toolkit_description("github"),
    do: gettext("Work with issues, pull requests, and repositories.")

  defp composio_toolkit_description("linear"), do: gettext("Track issues and projects.")

  defp composio_toolkit_description("notion"),
    do: gettext("Read and update your Notion workspace.")

  defp composio_toolkit_description("slack"), do: gettext("Post and read messages in Slack.")
  defp composio_toolkit_description(_other), do: ""

  defp composio_error_message(:group_not_ready),
    do: gettext("The runtime is not ready yet. Retry shortly.")

  defp composio_error_message(:not_configured),
    do: gettext("Composio isn't configured for your organization yet.")

  defp composio_error_message(:no_redirect_url),
    do: gettext("Could not start the connection. Please try again.")

  defp composio_error_message(:google_admin_custom_oauth_required),
    do:
      gettext(
        "Configure a Google Admin OAuth app in Composio with Directory group read scopes before connecting."
      )

  defp composio_error_message({:bad_request, _}),
    do: gettext("The platform rejected the connection request.")

  defp composio_error_message(reason) when reason in [:unavailable, :timeout],
    do: gettext("Salix is unavailable right now. Retry shortly.")

  defp composio_error_message(_reason),
    do: gettext("Could not connect the account. Please try again.")

  defp environment_loaded?(socket, id) do
    socket.assigns
    |> Map.get(:environments, [])
    |> Enum.any?(&(environment_device_id(&1) == id))
  end

  defp set_environment_status(environments, id, status) do
    Enum.map(environments, fn
      %{"device_id" => ^id} = environment -> Map.put(environment, "status", status)
      %{device_id: ^id} = environment -> Map.put(environment, :status, status)
      environment -> environment
    end)
  end

  defp remove_environment(environments, id) do
    Enum.reject(environments, &(environment_device_id(&1) == id))
  end

  defp environment_device_id(%{"device_id" => id}), do: id
  defp environment_device_id(%{device_id: id}), do: id
  defp environment_device_id(_environment), do: nil

  defp clear_runtime_auth_for_device(socket, device_id) do
    case socket.assigns[:runtime_auth_selected] do
      %{target: %{"device_id" => ^device_id}} -> assign(socket, :runtime_auth_selected, nil)
      _other -> socket
    end
  end

  defp form_errors(nil), do: []
  defp form_errors(%Ecto.Changeset{} = cs), do: cs.errors

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_nested_map(%_{} = value), do: value

  defp stringify_nested_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_nested_map(value)} end)
  end

  defp stringify_nested_map(list) when is_list(list), do: Enum.map(list, &stringify_nested_map/1)
  defp stringify_nested_map(value), do: value

  # The org's assignable model templates (catalog ∩ allowlist). `[]` when none
  # are available or the Salix catalog is unreachable — the modal then disables
  # the picker and points admins to org settings.
  defp load_agent_templates(org) do
    case Models.list_for_org(org) do
      {:ok, templates} -> templates
      {:error, _reason} -> []
    end
  end

  # Dropdown-only: the submitted template must be one the org currently offers,
  # or `""` to follow the role default.
  defp valid_template?(_socket, ""), do: true

  defp valid_template?(socket, template_id) do
    is_binary(template_id) and
      Enum.any?(socket.assigns.agent_templates, &(&1["template_id"] == template_id))
  end

  # Pre-select the agent's pinned model; "" means it follows the default.
  defp configure_template_value(agent), do: agent.salix["template_id"] || ""

  # The prompt option names the default this agent follows when nothing is pinned.
  defp follow_default_prompt(agent, effective_defaults) do
    case effective_defaults[agent.role] do
      nil -> gettext("Default (unavailable)")
      template -> gettext("Default (%{model})", model: Models.label(template))
    end
  end

  # Keep an unavailable pin visible without making it assignable. An unpinned
  # Agent uses the follow-default prompt rather than an unavailable-model option.
  defp configure_template_options(agent, org, templates) do
    current = configure_template_value(agent)
    options = Models.options(templates, current)

    if current == "" or Enum.any?(templates, &(&1["template_id"] == current)) do
      options
    else
      template =
        case Client.impl().get_template(current, org.salix_tenant_id) do
          {:ok, template} when is_map(template) -> template
          _ -> %{"template_id" => current}
        end

      label =
        gettext("%{model} (current; unavailable for selection)", model: Models.label(template))

      [[key: label, value: current, disabled: true] | options]
    end
  end

  defp save_agent_config(socket, agent, attrs) do
    # An untouched empty input must not turn a model change into a prompt clear.
    attrs =
      if attrs["system_prompt"] == "" and agent.salix["system_prompt"] in [nil, ""],
        do: Map.delete(attrs, "system_prompt"),
        else: attrs

    case Agents.update_agent(agent, attrs, audit_opts(socket)) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> assign(:configure_agent, nil)
         |> assign(:agent_form, nil)
         |> put_flash(:info, gettext("Agent configuration saved."))
         |> load_agent_page(nil)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :agent_form, agent_form(attrs, cs))}

      {:error, {:bad_request, "system_prompt cannot be cleared"}} ->
        form =
          to_form(stringify(attrs),
            as: :agent,
            errors: [system_prompt: {gettext("An existing system prompt cannot be cleared."), []}]
          )

        {:noreply, assign(socket, :agent_form, form)}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save the configuration."))}
    end
  end

  defp save_agent_runtime_rebind(socket, agent, target, expected_revision, form_attrs) do
    case Agents.rebind_external_target(
           socket.assigns.project,
           agent,
           target,
           expected_revision,
           audit_opts(socket)
         ) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> assign(:rebind_agent, nil)
         |> assign(:agent_form, nil)
         |> put_flash(:info, gettext("Agent runtime rebound."))
         |> load_tab(:agents)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :agent_form, agent_form(form_attrs, cs))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:agent_form, agent_form(form_attrs))
         |> put_flash(:error, runtime_rebind_error_message(reason))}
    end
  end

  defp breadcrumbs(org, project, tab, detail \\ nil) do
    base = [
      {gettext("Agent Swarms"), ~p"/orgs/#{org.slug}/projects"},
      {project.name, ~p"/orgs/#{org.slug}/projects/#{project.id}"}
    ]

    case tab do
      :agents ->
        base ++ [{gettext("Agents"), nil}]

      :tasks ->
        base ++ [{gettext("Tasks"), nil}]

      :schedules ->
        base ++ [{gettext("Schedules"), nil}]

      :integrations ->
        base ++ [{gettext("Integrations"), nil}]

      :connections ->
        base ++ [{gettext("Connections"), nil}]

      :plugins when is_map(detail) ->
        base ++
          [
            {gettext("Plugins"), ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins"},
            {detail["name"] || detail["plugin_id"], nil}
          ]

      :plugins ->
        base ++ [{gettext("Plugins"), nil}]

      :skills ->
        base ++ [{gettext("Skills"), nil}]

      :environments ->
        base ++ [{gettext("Devices"), nil}]

      :websites ->
        base ++ [{gettext("Websites"), nil}]

      :settings ->
        base ++ [{gettext("Settings"), nil}]
    end
  end

  defp assign_environment_provisioning(socket) do
    project = socket.assigns.project
    org = socket.assigns.current_org

    socket
    |> assign(:env_provisioners, online_mac_mini_provisioners(org.id))
    |> assign(:env_provisioning_active, Environments.device_provisioning_active?(project.id))
  end

  defp maybe_schedule_environment_provision_refresh(socket) do
    if connected?(socket) and socket.assigns.env_provisioning_active do
      schedule_environment_provision_refresh(socket)
    else
      cancel_environment_provision_refresh(socket)
    end
  end

  defp schedule_environment_provision_refresh(socket) do
    case socket.assigns[:env_provision_refresh_ref] do
      nil ->
        assign(
          socket,
          :env_provision_refresh_ref,
          Process.send_after(
            self(),
            :refresh_environment_provisioning,
            @environment_provision_refresh_interval_ms
          )
        )

      _ref ->
        socket
    end
  end

  defp cancel_environment_provision_refresh(socket) do
    case socket.assigns[:env_provision_refresh_ref] do
      nil ->
        socket

      ref ->
        Process.cancel_timer(ref)
        assign(socket, :env_provision_refresh_ref, nil)
    end
  end

  # ---- project device projection (from the live Salix registry record) ----

  defp assign_android_control(socket) do
    case Environments.android_control_status(socket.assigns.project.id) do
      {:ok, status} ->
        socket
        |> assign(:android_control, status)
        |> assign(:android_control_error, nil)

      {:error, reason} ->
        socket
        |> assign(:android_control, %{entitled: false})
        |> assign(:android_control_error, reason)
    end
  end

  # Project a public Salix device record onto the flat shape the table renders.
  defp env_view(record) when is_map(record) do
    %{
      id: record["device_id"],
      kind: :connector,
      connector_run_id: record["connector_run_id"],
      device_id: record["device_id"],
      name: record["name"],
      status: record["status"] || "unknown",
      last_seen_at: record["updated_at"],
      system_info: record["system_info"],
      system_info_updated_at: record["system_info_updated_at"],
      runtimes: List.wrap(record["device_runtimes"]),
      capabilities: record["capabilities"] || %{}
    }
  end

  defp android_environment?(%{kind: :connector, capabilities: capabilities})
       when is_map(capabilities),
       do: capabilities["android_device_tool"] == true or is_map(capabilities["android"])

  defp android_environment?(_environment), do: false

  defp android_environment_present?(environments),
    do: Enum.any?(environments, &android_environment?/1)

  defp android_environment_status(environments) do
    android = Enum.filter(environments, &android_environment?/1)

    cond do
      Enum.any?(android, &(&1.status in ["online", "connected", "ready"])) ->
        "connected"

      android != [] ->
        "needs_attention"

      true ->
        "not_connected"
    end
  end

  defp android_setup_status_label("connected"), do: gettext("Connected")
  defp android_setup_status_label("needs_attention"), do: gettext("Needs attention")
  defp android_setup_status_label(_status), do: gettext("Not connected")

  defp android_profiles(environment),
    do:
      get_in(environment.capabilities, ["android", "profiles"])
      |> List.wrap()
      |> Enum.take(8)
      |> Enum.join(", ")

  defp android_field(environment, key),
    do: get_in(environment.capabilities, ["android", key])

  defp android_capability_status_label("ready"), do: gettext("Last reported ready")
  defp android_capability_status_label("idle"), do: gettext("Idle")
  defp android_capability_status_label("preparing"), do: gettext("Preparing")
  defp android_capability_status_label("error"), do: gettext("Needs attention")
  defp android_capability_status_label("unavailable"), do: gettext("Unavailable")
  defp android_capability_status_label("leased"), do: gettext("Lease active")
  defp android_capability_status_label(_status), do: gettext("Status unavailable")

  defp android_phase_label("checking"), do: gettext("Checking device")
  defp android_phase_label("stopping"), do: gettext("Stopping previous version")
  defp android_phase_label("booting"), do: gettext("Starting Android")
  defp android_phase_label("waiting_ready"), do: gettext("Waiting for Android")
  defp android_phase_label("cleanup"), do: gettext("Cleaning up failed start")
  defp android_phase_label(_phase), do: gettext("Status unavailable")

  defp android_slots(environment) do
    android = get_in(environment.capabilities, ["android"]) || %{}
    {android["available_slots"], android["capacity"]}
  end

  defp device_rows(project, environments) do
    [
      %{
        id: "cloud-computer",
        kind: :cloud,
        name: gettext("Cloud computer"),
        status: if(project.vm_enabled, do: "enabled", else: "disabled")
      }
      | environments
    ]
  end

  defp system_host(%{"hostname" => host}) when is_binary(host) and host != "", do: host
  defp system_host(_), do: "—"

  defp system_os(%{} = info) do
    [info["os_type"], info["os_release"] || info["os_version"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> blank_dash()
  end

  defp system_os(_), do: "—"

  defp system_cpu(%{} = info) do
    model = to_string(info["cpu_model"] || "")
    cores = info["cpu_count"]

    cond do
      model != "" and is_integer(cores) -> "#{model} (#{cores} cores)"
      model != "" -> model
      is_integer(cores) -> "#{cores} cores"
      true -> "—"
    end
  end

  defp system_cpu(_), do: "—"

  defp system_memory(%{"memory_total" => bytes}) when is_integer(bytes) and bytes > 0,
    do: format_bytes(bytes)

  defp system_memory(_), do: "—"

  defp format_bytes(n) when is_integer(n) and n > 0 do
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    exp = min(trunc(:math.log(n) / :math.log(1024)), length(units) - 1)
    value = n / :math.pow(1024, exp)
    :erlang.float_to_binary(value, decimals: 1) <> " " <> Enum.at(units, exp)
  end

  defp format_bytes(_), do: "—"

  defp blank_dash(""), do: "—"
  defp blank_dash(value), do: value

  defp format_unix(nil), do: "—"

  defp format_unix(value) when is_integer(value) do
    unit = if value > 99_999_999_999, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
      _ -> to_string(value)
    end
  end

  defp format_unix(value), do: to_string(value)

  # Human recurrence summary for a schedule: interval schedules fire every N
  # minutes; cron schedules use the same human-facing text as task details.
  defp schedule_recurrence(schedule), do: SchedulePresentation.recurrence(schedule)

  defp delete_visible_schedule(socket, schedule_id) do
    case Enum.find(socket.assigns.schedules, &(&1["id"] == schedule_id)) do
      %{"target_type" => "task", "conversation_id" => conversation_id} ->
        case Conversations.delete_project_task_schedule(
               socket.assigns.project,
               conversation_id,
               audit_opts(socket)
             ) do
          {:ok, _conversation} -> :ok
          error -> error
        end

      %{"target_type" => "agent"} ->
        Schedules.delete_project_schedule(socket.assigns.project, schedule_id, audit_opts(socket))

      _ ->
        {:error, :not_found}
    end
  end

  defp schedule_audit_filters(%{"target_type" => "task", "conversation_id" => conversation_id}) do
    %{resource_type: "task_schedule", resource_id: conversation_id}
  end

  defp schedule_audit_filters(schedule) do
    %{resource_type: "project_schedule", resource_id: schedule["id"]}
  end

  # Schedule `created_at` / `last_run` are unix milliseconds (or nil before a
  # first run).
  defp format_schedule_ms(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
      _ -> "—"
    end
  end

  defp format_schedule_ms(_ms), do: "—"

  defp conversation_title(%{"title" => title}) when is_binary(title) and title != "", do: title
  defp conversation_title(_conversation), do: gettext("Untitled task")

  defp conversation_status(%{"status" => status}) when is_binary(status) and status != "",
    do: status

  defp conversation_status(_conversation), do: "active"

  defp conversation_statuses(conversations) do
    conversations
    |> Enum.map(&conversation_status/1)
    |> Enum.uniq()
    |> Enum.sort_by(fn status -> {status != "active", status} end)
  end

  defp conversation_status_label(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp conversation_status_count(conversations, "all"), do: length(conversations)

  defp conversation_status_count(conversations, "scheduled"),
    do: Enum.count(conversations, &scheduled_conversation?/1)

  defp conversation_status_count(conversations, status),
    do: Enum.count(conversations, &(conversation_status(&1) == status))

  defp filtered_conversations(conversations, status, query, agents) do
    normalized_query = String.downcase(String.trim(query))

    Enum.filter(conversations, fn conversation ->
      status_matches =
        case status do
          "all" -> true
          "scheduled" -> scheduled_conversation?(conversation)
          status -> conversation_status(conversation) == status
        end

      query_matches =
        normalized_query == "" or
          conversation_search_text(conversation, agents)
          |> String.downcase()
          |> String.contains?(normalized_query)

      status_matches and query_matches
    end)
  end

  defp scheduled_conversation?(%{"schedule" => %{"schedule_id" => id}}),
    do: is_binary(id) and id != ""

  defp scheduled_conversation?(_conversation), do: false

  defp conversation_search_text(conversation, agents) do
    participants =
      if is_list(conversation["participants"]), do: conversation["participants"], else: []

    participant_text =
      participants
      |> Enum.flat_map(fn participant ->
        [
          participant["provider"],
          participant["role_label"],
          conversation_agent_label_for_participant(participant, agents)
        ]
      end)

    [
      conversation_title(conversation),
      conversation["kind"],
      conversation_status(conversation)
      | participant_text
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp conversation_groups(conversations) do
    conversations
    |> Enum.group_by(&conversation_status/1)
    |> Enum.sort_by(fn {status, _rows} -> {status != "active", status} end)
  end

  defp conversation_agent_label_for_participant(%{"agent_id" => agent_id} = participant, agents)
       when is_binary(agent_id) and agent_id != "" do
    case Enum.find(agents, &(&1.salix_agent_id == agent_id)) do
      nil -> participant["role_label"] || gettext("Agent")
      agent -> agent.salix["name"] || agent.role || gettext("Agent")
    end
  end

  defp conversation_agent_label_for_participant(_participant, _agents), do: nil

  defp conversation_kind_label(%{"kind" => kind}) when is_binary(kind) and kind != "" do
    kind
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp conversation_kind_label(_conversation), do: gettext("Task")

  defp agent_options(agents) do
    Enum.map(agents, fn agent ->
      {agent.salix["name"] || agent.salix_agent_id || agent.id, agent.id}
    end)
  end

  defp slack_inbound_agent_options(agents) do
    agents
    |> Enum.filter(&(&1.role in ["router", "worker"]))
    |> Enum.filter(&(Agent.active?(&1) and nonblank?(&1.salix_agent_id)))
    |> Enum.map(fn agent ->
      label =
        [agent.salix["name"] || agent.salix_agent_id, agent.role]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" · ")

      {label, agent.salix_agent_id}
    end)
  end

  defp slack_bound_agent_label(connect, agents) do
    inbound_agent_id = connect["inbound_agent_id"]

    case Enum.find(agents, &(&1.salix_agent_id == inbound_agent_id)) do
      nil ->
        inbound_agent_id || "—"

      agent ->
        Enum.join(Enum.reject([agent.salix["name"], agent.role], &(&1 in [nil, ""])), " · ")
    end
  end

  defp access_role_options do
    [{gettext("User"), "user"}, {gettext("Admin"), "admin"}]
  end

  defp access_role_label("admin"), do: gettext("Admin")
  defp access_role_label("user"), do: gettext("User")
  defp access_role_label(other), do: other || "—"

  defp find_or_create_user(email) do
    case Accounts.get_user_by_email(email) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> Accounts.create_user(%{"email" => email})
    end
  end

  defp archive_opts(socket, agent) do
    binding = socket.assigns.archive_triage_binding

    if socket.assigns.archive_agent && socket.assigns.archive_agent.id == agent.id &&
         binding && binding["worker_agent_id"] == agent.salix_agent_id do
      Keyword.put(audit_opts(socket), :triage_worker_revision, binding["revision"])
    else
      audit_opts(socket)
    end
  end

  defp audit_opts(socket) do
    user = socket.assigns.current_user

    [
      actor_user_id: user.id,
      actor_label: audit_actor_label(user),
      request_id: Ecto.UUID.generate()
    ]
  end

  defp audit_actor_label(user) do
    cond do
      nonblank?(user.email) -> String.trim(user.email)
      nonblank?(user.name) -> String.trim(user.name)
      true -> user.id
    end
  end

  defp display_name(%Agent{salix: %{"name" => name}}) when is_binary(name) and name != "",
    do: name

  defp display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(_), do: "—"

  defp format_date(nil), do: "—"

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y")
  end

  defp nonblank?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank?(_), do: false

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()

  defp role_color("router"), do: "brand"
  defp role_color(_), do: "neutral"

  defp current_router_agent_id(project) do
    case read_current_router_agent_id(project) do
      {:ok, router_agent_id} -> router_agent_id
      _ -> nil
    end
  end

  # Best-effort read of the group's currently assigned router agent (the Salix
  # `router_agent_id`, which is an agent's `salix_agent_id`). Runtime failures
  # stay tagged as unknown so readiness checks do not misreport "missing router".
  defp read_current_router_agent_id(project) do
    client = Client.impl()

    if function_exported?(client, :get_group, 1) do
      case client.get_group(project.salix_group_id) do
        {:ok, group} -> {:ok, group["router_agent_id"]}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      {:unsupported, :get_group_unavailable}
    end
  end

  # True when this agent is the one currently assigned as the group's router
  # (matched by its Salix agent id against the group's `router_agent_id`).
  defp router_agent?(_agent, nil), do: false
  defp router_agent?(_agent, ""), do: false
  defp router_agent?(agent, router_agent_id), do: agent.salix_agent_id == router_agent_id

  defp feishu_route_state(project, connects) do
    connect = preferred_feishu_connect(connects)

    {router_agent_id, router_agent, route_error} =
      if is_nil(connect) do
        {nil, nil, nil}
      else
        case read_current_router_agent_id(project) do
          {:ok, router_agent_id} ->
            case Agents.get_project_agent(project.id, router_agent_id) do
              {:ok, router_agent} -> {router_agent_id, router_agent, nil}
              {:error, reason} -> {router_agent_id, nil, reason}
            end

          {:unsupported, reason} ->
            {nil, nil, reason}

          {:error, reason} ->
            {nil, nil, reason}
        end
      end

    status =
      cond do
        is_nil(connect) -> :not_connected
        connect["disabled_at"] -> :disabled
        route_error -> :unknown
        is_nil(router_agent) -> :missing_router
        true -> :ready
      end

    %{
      status: status,
      project: project,
      connect: connect,
      router_agent: router_agent,
      router_agent_id: router_agent_id,
      route_error: route_error
    }
  end

  defp preferred_feishu_connect(connects) do
    Enum.find(connects, &is_nil(&1["disabled_at"])) || List.first(connects)
  end

  defp feishu_route_badge_color(:ready), do: "green"
  defp feishu_route_badge_color(:disabled), do: "red"
  defp feishu_route_badge_color(:missing_router), do: "amber"
  defp feishu_route_badge_color(:not_connected), do: "neutral"
  defp feishu_route_badge_color(:unknown), do: "amber"

  defp feishu_route_badge_text(:ready), do: gettext("route ready")
  defp feishu_route_badge_text(:disabled), do: gettext("connect disabled")
  defp feishu_route_badge_text(:missing_router), do: gettext("router missing")
  defp feishu_route_badge_text(:not_connected), do: gettext("not connected")
  defp feishu_route_badge_text(:unknown), do: gettext("route unknown")

  defp feishu_route_next_action(:ready),
    do:
      gettext(
        "Send a real @Bridge message in the Feishu group after the Feishu console steps pass."
      )

  defp feishu_route_next_action(:disabled),
    do: gettext("Enable this Feishu connect before testing the group bot.")

  defp feishu_route_next_action(:missing_router),
    do:
      gettext(
        "The Agent Swarm router is not ready. Retry checks shortly; if this persists, contact support."
      )

  defp feishu_route_next_action(:unknown),
    do: gettext("Retry checks shortly; Salix route/router readiness could not be verified.")

  defp feishu_route_next_action(:not_connected),
    do:
      gettext(
        "Create the Feishu connect below. Feishu callback HTTP 200 alone does not prove this Agent Swarm will reply."
      )

  defp find_project_plugin(definitions, plugin_id),
    do: Enum.find(definitions, &(&1["plugin_id"] == trim(plugin_id)))

  defp editable_group_plugin?(%{"owner_scope" => "group"} = plugin),
    do: plugin["read_only"] != true

  defp editable_group_plugin?(_plugin), do: false

  defp put_project_plugin_editor_error(socket, params, message) do
    socket
    |> assign(:project_plugin_form, PluginForm.form_from_params(params))
    |> assign(:project_plugin_panel_error, message)
  end

  defp plugin_dependency_paths(plugin) do
    status = plugin["setup_status"] || %{}
    connections = status["connections"] || []

    Enum.map(status["mcps"] || [], fn mcp ->
      %{
        mcp: mcp,
        connections:
          Enum.filter(
            connections,
            &(&1["id"] in plugin_mcp_auth_refs(mcp))
          )
      }
    end)
    |> Enum.reject(&(&1.connections == []))
  end

  defp plugin_standalone_connections(plugin) do
    status = plugin["setup_status"] || %{}

    auth_refs =
      plugin_dependency_paths(plugin)
      |> Enum.flat_map(& &1.connections)
      |> MapSet.new(& &1["id"])

    Enum.reject(status["connections"] || [], &MapSet.member?(auth_refs, &1["id"]))
  end

  defp plugin_connection_card(assigns) do
    assigns = assign_new(assigns, :compact, fn -> false end)
    assigns = assign_new(assigns, :embedded, fn -> false end)
    assigns = assign_new(assigns, :connect_mcp, fn -> false end)

    ~H"""
    <div
      id={"plugin-connection-#{@connection["id"]}"}
      class={[
        "rounded-lg",
        !@embedded && "border bg-white shadow-subtle",
        @embedded && "grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 bg-white/70",
        @embedded && @connection["state"] == "connected" && "bg-brand-50/70",
        @compact && "p-3",
        !@compact && "p-4",
        !@embedded && @connection["state"] == "connected" &&
          "border-brand-200 ring-1 ring-brand-100",
        !@embedded && @connection["state"] != "connected" && "border-neutral-200"
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="flex min-w-0 items-start gap-3">
          <div class={[
            "flex shrink-0 items-center justify-center rounded-md bg-neutral-100 text-neutral-600",
            @compact && "h-7 w-7",
            !@compact && "h-8 w-8"
          ]}>
            <.icon
              name={
                cond do
                  @connection["kind"] == "im_connect" -> "chat-bubble"
                  @embedded -> "globe"
                  true -> "plug"
                end
              }
              variant="outlined"
              class="h-4 w-4"
            />
          </div>
          <div class="min-w-0">
            <div class="flex min-w-0 items-center gap-2">
              <div class="truncate text-sm font-medium text-neutral-900">
                {@connection["label"] || @connection["id"]}
              </div>
              <span
                id={"plugin-connection-status-#{@connection["id"]}"}
                class={[
                  "shrink-0 rounded-full px-2 py-0.5 text-[11px] font-medium",
                  @connection["state"] == "connected" && "bg-emerald-50 text-emerald-700",
                  @connection["state"] != "connected" && "bg-neutral-100 text-neutral-600"
                ]}
              >
                {plugin_setup_state_label(@connection["state"])}
              </span>
            </div>
            <div class="mt-0.5 text-xs text-neutral-500">
              {plugin_connection_kind_label(@connection["kind"])}
            </div>
          </div>
        </div>
      </div>

      <div
        :if={@dependent_mcps != []}
        class="mt-3 flex items-center gap-1.5 border-t border-neutral-100 pt-3 text-xs text-brand-700"
      >
        <.icon name="bolt" class="h-3.5 w-3.5" />
        {ngettext(
          "Credential for %{names} MCP",
          "Credential for %{names} MCPs",
          length(@dependent_mcps),
          names: Enum.join(@dependent_mcps, ", ")
        )}
      </div>

      <div
        :if={@can_manage}
        class={[
          "flex flex-wrap items-center gap-2",
          @compact && !@embedded && "mt-2",
          @embedded && "mt-0",
          !@compact && "mt-3"
        ]}
      >
        <%= if @connection["kind"] == "im_connect" do %>
          <.button
            id={
              if @connection["id"] == @default_connection,
                do: "connect-plugin",
                else: "connect-plugin-#{@connection["id"]}"
            }
            size="sm"
            phx-click="connect_plugin"
            phx-value-id={@plugin_id}
            phx-value-connection={@connection["id"]}
          >
            {if @connection["state"] == "connected", do: gettext("Configure"), else: gettext("Connect")}
          </.button>
        <% else %>
          <%= if @connection["state"] == "connected" do %>
          <.button
            id={
              if @connect_mcp,
                do: "connect-plugin-#{@connection["id"]}",
                else: "reconnect-plugin-#{@connection["id"]}"
            }
            size="sm"
            phx-click="connect_plugin"
            phx-value-id={@plugin_id}
            phx-value-connection={@connection["id"]}
          >
            {if @connect_mcp, do: gettext("Connect"), else: gettext("Reconnect")}
          </.button>
          <.button
            id={"disconnect-plugin-#{@connection["id"]}"}
            variant="ghost"
            size="sm"
            class="text-red-600 hover:bg-red-50 hover:text-red-700"
            phx-click="disconnect_plugin"
            phx-value-id={@plugin_id}
            phx-value-connection={@connection["id"]}
          >
            {gettext("Disconnect")}
          </.button>
          <% else %>
            <.button
              id={
                if @connection["id"] == @default_connection,
                  do: "connect-plugin",
                  else: "connect-plugin-#{@connection["id"]}"
              }
              size="sm"
              phx-click="connect_plugin"
              phx-value-id={@plugin_id}
              phx-value-connection={@connection["id"]}
            >
              {gettext("Connect")}
            </.button>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp plugin_mcp_card(assigns) do
    ~H"""
    <div
      id={"plugin-mcp-#{@mcp["alias"]}"}
      class="rounded-xl border border-brand-200 bg-gradient-to-br from-white to-brand-50/60 p-4 shadow-subtle"
    >
      <div class="flex items-start justify-between gap-3">
        <div class="flex min-w-0 items-start gap-3">
          <div class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md border border-brand-100 bg-white shadow-subtle">
            <.brand_logo name={@mcp["icon"] || @mcp["alias"]} class="h-5 w-5" />
          </div>
          <div class="min-w-0">
            <div class="text-[10px] font-semibold uppercase tracking-[0.16em] text-brand-700">
              {gettext("MCP Server")}
            </div>
            <div class="mt-0.5 truncate font-mono text-sm font-medium text-neutral-900">
              {@mcp["alias"]}
            </div>
          </div>
        </div>
        <div class="flex shrink-0 items-center gap-2">
          <span class="rounded-full bg-white px-2 py-0.5 font-mono text-[11px] text-neutral-600 shadow-subtle">
            {@mcp["placement"]}
          </span>
          <span
            id={"plugin-mcp-status-#{@mcp["alias"]}"}
            class="rounded-full bg-white px-2 py-0.5 text-[11px] font-medium text-neutral-600 shadow-subtle"
          >
            {plugin_setup_state_label(plugin_mcp_display_state(@mcp, @connections))}
          </span>
        </div>
      </div>

      <div class="mt-4 border-t border-brand-100 pt-4">
        <div class="space-y-2">
          <.plugin_connection_card
            :for={connection <- @connections}
            connection={connection}
            dependent_mcps={[]}
            connect_mcp={plugin_connection_needs_mcp?(connection, @mcp)}
            compact={true}
            embedded={true}
            plugin_id={@plugin_id}
            default_connection={@default_connection}
            can_manage={@can_manage}
          />
        </div>
      </div>
    </div>
    """
  end

  defp plugin_mcp_display_state(%{"state" => state}, _connections)
       when state in ~w(ready_on_use running degraded disabled conflict),
       do: state

  defp plugin_mcp_display_state(mcp, connections) do
    cond do
      Enum.any?(connections, &(&1["state"] == "missing_scopes")) ->
        "missing_scopes"

      Enum.any?(connections, &(&1["state"] == "reauthorization_required")) ->
        "reauthorization_required"

      Enum.any?(connections, &(&1["state"] == "connected")) ->
        mcp["state"]

      true ->
        "waiting_for_oauth"
    end
  end

  defp filtered_project_plugins(definitions, enablements, query, state, source) do
    query = query |> trim() |> String.downcase()

    definitions
    |> Enum.filter(fn definition ->
      source == "all" or definition["owner_scope"] == source
    end)
    |> Enum.filter(fn definition ->
      case state do
        "enabled" ->
          Plugins.enabled?(definition, enablements)

        "disabled" ->
          definition["locked"] != true and not Plugins.enabled?(definition, enablements)

        _ ->
          true
      end
    end)
    |> Enum.filter(fn definition ->
      searchable = [
        definition["name"],
        definition["description"],
        definition["plugin_id"],
        Jason.encode!(definition["refs"] || %{})
      ]

      query == "" or
        Enum.any?(searchable, fn value ->
          value |> trim() |> String.downcase() |> String.contains?(query)
        end)
    end)
  end

  defp sort_project_plugins(definitions) do
    Enum.sort_by(definitions, fn definition ->
      definition["name"] || definition["plugin_id"] || ""
    end)
  end

  defp enabled_plugin_count(definitions, enablements) do
    Enum.count(definitions, &Plugins.enabled?(&1, enablements))
  end

  defp disabled_plugin_count(definitions, enablements) do
    Enum.count(definitions, fn definition ->
      definition["locked"] != true and not Plugins.enabled?(definition, enablements)
    end)
  end

  defp valid_plugin_source_filter(source) when source in ~w(all system tenant group), do: source
  defp valid_plugin_source_filter(_source), do: "all"

  defp valid_plugin_state_filter(state) when state in ~w(all enabled disabled), do: state
  defp valid_plugin_state_filter(_state), do: "all"

  defp plugin_state_filter_options do
    [
      {"all", gettext("All")},
      {"enabled", gettext("Enabled")},
      {"disabled", gettext("Disabled")}
    ]
  end

  defp plugin_filter_button_class(active?) do
    [
      "h-7 rounded px-2.5 text-xs font-medium transition-colors",
      active? && "bg-white text-neutral-900 shadow-subtle",
      !active? && "text-neutral-500 hover:text-neutral-800"
    ]
  end

  defp plugin_filters_clear?(query, state, source),
    do: trim(query) == "" and state == "all" and source == "all"

  defp project_plugin_editor_panel?(%{mode: mode}) when mode in [:create, :edit], do: true
  defp project_plugin_editor_panel?(_panel), do: false
  defp plugin_connection_kind_label("native_mcp_oauth"), do: gettext("Native MCP OAuth")
  defp plugin_connection_kind_label("managed_oauth"), do: gettext("Managed OAuth")
  defp plugin_connection_kind_label("composio"), do: gettext("Composio direct API")
  defp plugin_connection_kind_label("im_connect"), do: gettext("Messaging connection")
  defp plugin_connection_kind_label(_kind), do: gettext("Connection")

  defp plugin_setup_state_label("connected"), do: gettext("Connected")
  defp plugin_setup_state_label("not_connected"), do: gettext("Not connected")
  defp plugin_setup_state_label("missing_scopes"), do: gettext("Additional access required")

  defp plugin_setup_state_label("reauthorization_required"),
    do: gettext("Reconnect required")

  defp plugin_setup_state_label("authorization_pending"), do: gettext("Authorization pending")
  defp plugin_setup_state_label("external"), do: gettext("Direct API connection")
  defp plugin_setup_state_label("waiting_for_oauth"), do: gettext("Waiting for OAuth")
  defp plugin_setup_state_label("not_configured"), do: gettext("Not configured")
  defp plugin_setup_state_label("ready_on_use"), do: gettext("Ready on first use")
  defp plugin_setup_state_label("running"), do: gettext("Running")
  defp plugin_setup_state_label("degraded"), do: gettext("Degraded")
  defp plugin_setup_state_label("disabled"), do: gettext("Disabled")
  defp plugin_setup_state_label("conflict"), do: gettext("Configuration conflict")
  defp plugin_setup_state_label(_state), do: gettext("Unavailable")

  defp plugin_setup_error_message({:conflict, message}) when is_binary(message), do: message
  defp plugin_setup_error_message({:bad_request, message}) when is_binary(message), do: message

  defp plugin_setup_error_message({:precondition_failed, message}) when is_binary(message),
    do: message

  defp plugin_setup_error_message(reason), do: oauth_error_message(reason)

  defp plugin_mcp_auth_refs(%{"auth_refs" => refs}) when is_list(refs), do: refs
  defp plugin_mcp_auth_refs(%{"auth_ref" => ref}) when is_binary(ref), do: [ref]
  defp plugin_mcp_auth_refs(_mcp), do: []

  defp open_plugin_connection_detail(socket, plugin_id, connection_id, requested_action) do
    require_project_admin(
      socket,
      gettext("Only Agent Swarm admins can connect plugins."),
      project_resource_write_attempt(
        "plugin.setup.authorization_started",
        "plugin",
        "plugins",
        %{"plugin_id" => plugin_id}
      ),
      fn socket ->
        plugin = find_project_plugin(socket.assigns.project_plugin_definitions, plugin_id)

        connection =
          plugin &&
            Enum.find(
              get_in(plugin, ["setup_status", "connections"]) || [],
              &(&1["id"] == connection_id)
            )

        if connection do
          dependent_mcp_statuses =
            (get_in(plugin, ["setup_status", "mcps"]) || [])
            |> Enum.filter(&(connection_id in plugin_mcp_auth_refs(&1)))

          dependent_mcps = Enum.map(dependent_mcp_statuses, & &1["alias"])

          if connection["kind"] == "im_connect" and requested_action == "connect" do
            {:noreply,
             socket
             |> load_tab(:integrations)
             |> assign(:connection_detail, nil)
             |> assign(:integration_setup_provider, connection["provider"])}
          else
            {:noreply,
             assign(socket, :connection_detail, %{
               "source" => "plugin",
               "action" =>
                 plugin_connection_action(
                   requested_action,
                   connection,
                   dependent_mcp_statuses
                 ),
               "kind" => connection["kind"],
               "label" => connection["label"] || connection["id"],
               "plugin_id" => plugin_id,
               "connection_id" => connection_id,
               "provider" => connection["provider"],
               "toolkit" => connection["toolkit"],
               "credential_connected" => connection["state"] == "connected",
               "dependent_mcps" => dependent_mcps
             })}
          end
        else
          {:noreply, put_flash(socket, :error, gettext("Plugin connection was not found."))}
        end
      end
    )
  end

  defp connection_write_attempt(%{"source" => source} = detail) do
    action = detail["action"] || "connect"

    project_resource_write_attempt(
      "connection.#{action}",
      "connection",
      source,
      %{
        "kind" => detail["kind"],
        "plugin_id" => detail["plugin_id"],
        "provider" => detail["provider"],
        "toolkit" => detail["toolkit"]
      }
    )
  end

  defp plugin_connection_action(
         "connect",
         %{"kind" => "managed_oauth", "state" => "connected"},
         [_ | _] = mcps
       ) do
    if Enum.all?(mcps, &(&1["state"] in ~w(ready_on_use running degraded))),
      do: "reconnect",
      else: "connect"
  end

  defp plugin_connection_action("connect", %{"state" => "connected"}, _mcps), do: "reconnect"
  defp plugin_connection_action(requested_action, _connection, _mcps), do: requested_action

  defp plugin_connection_needs_mcp?(
         %{"kind" => "managed_oauth", "state" => "connected"},
         mcp
       ),
       do: mcp["state"] not in ~w(ready_on_use running degraded)

  defp plugin_connection_needs_mcp?(_connection, _mcp), do: false

  defp disconnect_confirmed_plugin_connection(socket, detail) do
    org = socket.assigns.current_org
    project = socket.assigns.project

    case Plugins.disconnect_plugin(
           org.id,
           project.id,
           detail["plugin_id"],
           detail["connection_id"],
           audit_opts(socket)
         ) do
      {:ok, _value} ->
        socket =
          socket
          |> assign(:connection_detail, nil)
          |> put_flash(:info, gettext("Connection disconnected."))
          |> load_tab(:plugins)
          |> assign_project_plugin_detail(%{"plugin_id" => detail["plugin_id"]})

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, plugin_setup_error_message(reason))}
    end
  end

  defp start_confirmed_connection(socket, %{"source" => "plugin"} = detail) do
    org = socket.assigns.current_org
    project = socket.assigns.project

    Plugins.connect_plugin(
      org.id,
      project.id,
      detail["plugin_id"],
      detail["connection_id"],
      oauth_redirect_after(socket),
      [force_reauthorize: detail["action"] == "reconnect"] ++ audit_opts(socket)
    )
    |> finish_connection_start(socket, &plugin_setup_error_message/1)
  end

  defp start_confirmed_connection(socket, %{"source" => "oauth"} = detail) do
    org = socket.assigns.current_org
    project = socket.assigns.project
    provider = detail["provider"]

    attrs = %{
      "alias" => detail["alias"],
      "redirect_after" => oauth_redirect_after(socket),
      "scopes" => BridgeForTeams.ProviderScopes.scopes(provider, user_capabilities(socket))
    }

    ProjectOAuthConnections.start_connection(
      org.id,
      project.id,
      provider,
      attrs,
      audit_opts(socket)
    )
    |> finish_connection_start(socket, &oauth_error_message/1)
  end

  defp start_confirmed_connection(socket, %{"source" => "composio"} = detail) do
    org = socket.assigns.current_org
    project = socket.assigns.project

    ProjectComposioConnections.start_connection(
      org.id,
      project.id,
      detail["toolkit"],
      %{"callback_url" => oauth_redirect_after(socket)},
      audit_opts(socket)
    )
    |> finish_connection_start(socket, &composio_error_message/1)
  end

  defp finish_connection_start({:ok, %{"authorization_url" => url}}, socket, _error)
       when is_binary(url) and url != "",
       do: {:noreply, redirect(socket, external: url)}

  defp finish_connection_start({:ok, %{"redirect_url" => url}}, socket, _error)
       when is_binary(url) and url != "",
       do: {:noreply, redirect(socket, external: url)}

  defp finish_connection_start(
         {:ok, %{"status" => "connected"}},
         socket,
         _error
       ) do
    plugin_id = socket.assigns.connection_detail["plugin_id"]

    socket =
      socket
      |> assign(:connection_detail, nil)
      |> put_flash(:info, gettext("Connected"))
      |> load_tab(:plugins)
      |> assign_project_plugin_detail(%{"plugin_id" => plugin_id})

    {:noreply, socket}
  end

  defp finish_connection_start({:ok, _payload}, socket, error),
    do: {:noreply, put_flash(socket, :error, error.(:no_redirect_url))}

  defp finish_connection_start({:error, reason}, socket, error),
    do: {:noreply, put_flash(socket, :error, error.(reason))}

  defp plugin_error_message(:group_not_ready),
    do: gettext("Agent Swarm is still preparing. Retry shortly.")

  defp plugin_error_message(:forbidden),
    do: gettext("Only Agent Swarm admins can manage plugins.")

  defp plugin_error_message(:unavailable), do: gettext("Salix is unavailable. Retry shortly.")
  defp plugin_error_message(:timeout), do: gettext("Salix timed out. Retry shortly.")
  defp plugin_error_message(:not_found), do: gettext("Plugin data was not found.")
  defp plugin_error_message(_reason), do: gettext("Could not update plugin state.")

  defp project_im_error_message(:group_not_ready),
    do: gettext("Agent Swarm is still preparing. Retry shortly.")

  defp project_im_error_message(:unsupported_provider),
    do: gettext("That IM provider is not supported.")

  defp project_im_error_message(:connect_not_found), do: gettext("That connect no longer exists.")

  defp project_im_error_message({:missing_credentials, fields}) do
    gettext("Connect is missing required fields: %{fields}.", fields: Enum.join(fields, ", "))
  end

  defp project_im_error_message(:connect_rejected),
    do: gettext("The provider rejected the connect setup. Check the app credentials and retry.")

  defp project_im_error_message(:provider_app_in_use),
    do:
      gettext(
        "This Feishu app is already connected to another Agent Swarm. Current limitation: one Feishu app can serve one Agent Swarm; delete the existing connect or use a different app."
      )

  defp project_im_error_message(:unavailable), do: gettext("Salix is unavailable. Retry shortly.")
  defp project_im_error_message(:timeout), do: gettext("Salix timed out. Retry shortly.")
  defp project_im_error_message(_), do: gettext("Could not update the IM connect.")

  defp display_webhook_url(%{"webhook_url" => url} = connect) when is_binary(url) and url != "" do
    app_id = connect["app_id"]

    uri = URI.parse(url)
    existing_query = URI.decode_query(uri.query || "")

    query = maybe_put_query(%{}, "app_id", app_id || existing_query["app_id"])

    %{uri | query: if(query == %{}, do: nil, else: URI.encode_query(query))}
    |> URI.to_string()
  rescue
    _ -> "—"
  end

  defp display_webhook_url(_), do: "—"

  defp slack_oauth_completed?(connect), do: (connect["oauth_completed_at"] || 0) > 0

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, _key, ""), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  defp configured_text(true), do: gettext("set")
  defp configured_text(_), do: gettext("missing")

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div
        :if={@live_action != :plugin}
        id="project-header"
        class="flex items-start justify-between gap-4"
      >
        <div :if={@tab == :settings} class="group/runtime-ids relative inline-block min-w-0">
          <h1
            id={"project-runtime-ids-trigger-#{@project.id}"}
            tabindex="0"
            aria-controls={"project-runtime-ids-#{@project.id}"}
            class="truncate text-lg font-semibold tracking-tight"
          >
            {@project.name}
          </h1>
          <.runtime_ids_popover project={@project} org={@current_org} />
        </div>
        <h1 :if={@tab != :settings} class="text-lg font-semibold tracking-tight">{@project.name}</h1>
        <div class="hidden flex-wrap items-center justify-end gap-2 sm:flex">
          <.button
            :if={@can_view_operations}
            href={~p"/orgs/#{@current_org.slug}/operations/delivery?#{%{project_id: @project.id}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View delivery")}
          </.button>
          <.button
            :if={@can_view_operations}
            href={~p"/orgs/#{@current_org.slug}/operations/events?#{%{project_id: @project.id}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View events")}
          </.button>
        </div>
        <.dropdown :if={@can_view_operations} id="project-operations-menu" align="right" class="sm:hidden">
          <:trigger>
            <button
              type="button"
              class="grid h-8 w-8 place-items-center rounded-md text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900"
              aria-label={gettext("Project operations")}
            >
              <.icon name="ellipsis" class="h-4 w-4" />
            </button>
          </:trigger>
          <.dropdown_item href={~p"/orgs/#{@current_org.slug}/operations/delivery?#{%{project_id: @project.id}}"}>
            {gettext("View delivery")}
          </.dropdown_item>
          <.dropdown_item href={~p"/orgs/#{@current_org.slug}/operations/events?#{%{project_id: @project.id}}"}>
            {gettext("View events")}
          </.dropdown_item>
        </.dropdown>
      </div>

      <div :if={@tab == :agents}>{agents_tab(assigns)}</div>
      <div :if={@tab == :tasks}>{conversations_tab(assigns)}</div>
      <div :if={@tab == :schedules}>{schedules_tab(assigns)}</div>
      <div :if={@tab == :integrations}>{integrations_tab(assigns)}</div>
      <div :if={@tab == :connections}>{connections_tab(assigns)}</div>
      <div :if={@tab == :plugins && @live_action != :plugin}>{plugins_tab(assigns)}</div>
      <div :if={@live_action == :plugin}>{plugin_detail_page(assigns)}</div>
      <div :if={@live_action == :plugin && @integration_setup_provider}>
        {integration_setup_panel(assigns)}
      </div>
      <div :if={@tab == :skills}>{project_skills_tab(assigns)}</div>
      <div :if={@tab == :environments}>{environments_tab(assigns)}</div>
      <div :if={@tab == :websites}>{websites_tab(assigns)}</div>
      <div :if={@tab == :settings}>{settings_tab(assigns)}</div>

      <.modal
        :if={@connection_detail}
        id="connection-detail-modal"
        show
        on_cancel={JS.push("close_connection_detail")}
      >
        <:title>{@connection_detail["label"]}</:title>
        <div class="space-y-4">
          <.badge color="neutral">
            {plugin_connection_kind_label(@connection_detail["kind"])}
          </.badge>

          <p
            :if={@connection_detail["action"] == "disconnect"}
            class="text-sm leading-6 text-neutral-600"
          >
            {gettext("Disconnecting removes this credential from the plugin and its dependent MCP servers. You can reconnect at any time.")}
          </p>
          <p
            :if={@connection_detail["action"] != "disconnect" && @connection_detail["kind"] == "native_mcp_oauth"}
            class="text-sm leading-6 text-neutral-600"
          >
            {gettext("The MCP server owns this OAuth flow. Comma discovers its authorization server, registers a client when supported, and stores and refreshes the resulting credential securely.")}
          </p>
          <p
            :if={@connection_detail["action"] != "disconnect" && @connection_detail["kind"] == "managed_oauth"}
            class="text-sm leading-6 text-neutral-600"
          >
            {gettext("This uses the organization's OAuth app and stores the connected account in Comma. Resources that explicitly depend on this connection can use it.")}
          </p>
          <p
            :if={@connection_detail["action"] != "disconnect" && @connection_detail["kind"] == "composio"}
            class="text-sm leading-6 text-neutral-600"
          >
            {gettext("Composio hosts the account connection. It enables direct API tools only and is never used as an MCP credential.")}
          </p>
          <p
            :if={@connection_detail["action"] != "disconnect" && @connection_detail["kind"] == "im_connect"}
            class="text-sm leading-6 text-neutral-600"
          >
            {gettext("This messaging connection lets the product receive workspace messages and route replies through this Agent Swarm. Continue to configure the existing provider integration.")}
          </p>

          <div
            :if={@connection_detail["dependent_mcps"] not in [nil, []]}
            class="rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2"
          >
            <div class="text-xs font-medium uppercase text-neutral-500">
              {gettext("Dependent MCP servers")}
            </div>
            <div class="mt-1 text-sm text-neutral-800">
              {Enum.join(@connection_detail["dependent_mcps"], ", ")}
            </div>
          </div>

          <p
            :if={
              @connection_detail["action"] != "disconnect" &&
                @connection_detail["kind"] != "im_connect" &&
                not (@connection_detail["action"] == "connect" &&
                       @connection_detail["credential_connected"])
            }
            class="text-xs text-neutral-500"
          >
            {if @connection_detail["action"] == "reconnect" do
                gettext("The current credential stays active until the new authorization succeeds.")
              else
                gettext("Nothing is connected until you continue to the provider and approve access.")
            end}
          </p>
        </div>
        <:footer>
          <.button
            variant="ghost"
            size="sm"
            phx-click={
              JS.exec("phx-remove", to: "#connection-detail-modal")
              |> JS.push("close_connection_detail")
            }
          >
            {gettext("Cancel")}
          </.button>
          <.button
            id="continue-connection"
            variant={if @connection_detail["action"] == "disconnect", do: "danger", else: "primary"}
            size="sm"
            phx-click="confirm_connection"
            phx-disable-with={
              if @connection_detail["action"] == "disconnect",
                do: gettext("Disconnecting..."),
                else: gettext("Connecting...")
            }
          >
            {cond do
              @connection_detail["action"] == "disconnect" -> gettext("Disconnect")
              true -> gettext("Continue")
            end}
          </.button>
        </:footer>
      </.modal>
    </div>
    """
  end

  defp runtime_ids_popover(assigns) do
    ~H"""
    <div
      id={"project-runtime-ids-#{@project.id}"}
      role="group"
      aria-label={gettext("Runtime IDs")}
      class="invisible absolute left-0 top-full z-50 mt-2 w-56 rounded-md border border-neutral-200 bg-white p-3 opacity-0 shadow-popover transition-opacity group-hover/runtime-ids:visible group-hover/runtime-ids:opacity-100 group-focus-within/runtime-ids:visible group-focus-within/runtime-ids:opacity-100"
    >
      <p class="text-[11px] font-medium text-neutral-500">{gettext("Organization runtime id")}</p>
      <div class="mt-1 flex items-center gap-1.5">
        <code
          id={"organization-runtime-id-#{@project.id}"}
          class="min-w-0 flex-1 truncate font-mono text-[11px] text-neutral-700"
        >{@org.salix_tenant_id}</code>
        <button
          id={"copy-organization-runtime-id-#{@project.id}"}
          type="button"
          phx-hook="CopyToClipboard"
          data-copy-target={"#organization-runtime-id-#{@project.id}"}
          class="shrink-0 rounded px-1.5 py-1 text-[11px] font-medium text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900"
        >
          {gettext("Copy")}
        </button>
      </div>
      <p class="mt-3 text-[11px] font-medium text-neutral-500">{gettext("Agent Swarm runtime id")}</p>
      <div class="mt-1 flex items-center gap-1.5">
        <code
          id={"agent-swarm-runtime-id-#{@project.id}"}
          class="min-w-0 flex-1 truncate font-mono text-[11px] text-neutral-700"
        >{@project.salix_group_id}</code>
        <button
          id={"copy-agent-swarm-runtime-id-#{@project.id}"}
          type="button"
          phx-hook="CopyToClipboard"
          data-copy-target={"#agent-swarm-runtime-id-#{@project.id}"}
          class="shrink-0 rounded px-1.5 py-1 text-[11px] font-medium text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900"
        >
          {gettext("Copy")}
        </button>
      </div>
    </div>
    """
  end

  defp settings_tab(assigns) do
    ~H"""
    <div id="project-settings" class="space-y-8">
      <section aria-labelledby="project-general-settings-title" class="space-y-4">
        <h2 id="project-general-settings-title" class="text-sm font-semibold text-neutral-700">
          {gettext("General")}
        </h2>

        <div class="divide-y divide-neutral-200 border-y border-neutral-200">
          <div class="grid gap-3 py-4 sm:grid-cols-[10rem_minmax(0,1fr)] sm:items-center">
            <div>
              <p class="text-sm font-medium text-neutral-800">{gettext("Name")}</p>
              <p class="text-xs text-neutral-500">{gettext("Shown throughout this Agent Swarm.")}</p>
            </div>
            <.form :if={@can_manage_project} for={@rename_form} phx-submit="rename_project" id="rename-project-form">
              <div class="flex items-start gap-2">
                <.input field={@rename_form[:name]} aria-label={gettext("Name")} required class="min-w-0 flex-1" />
                <.button type="submit" variant="primary" phx-disable-with={gettext("Renaming…")}>
                  {gettext("Rename")}
                </.button>
              </div>
            </.form>
            <p :if={!@can_manage_project} class="text-sm text-neutral-800">{@project.name}</p>
          </div>

          <dl class="grid gap-x-4 gap-y-3 py-4 text-sm sm:grid-cols-[10rem_minmax(0,1fr)]">
            <dt class="text-neutral-500">{gettext("Slug")}</dt>
            <dd class="font-mono text-xs text-neutral-700">{@project.slug}</dd>
            <dt class="text-neutral-500">{gettext("Status")}</dt>
            <dd><.status_pill status={@project.status} /></dd>
          </dl>
        </div>
      </section>

      {access_tab(assigns)}

      <section :if={@can_manage_project} aria-labelledby="project-danger-zone-title" class="border-t border-neutral-200 pt-6">
        <h2 id="project-danger-zone-title" class="text-sm font-semibold text-red-700">{gettext("Danger zone")}</h2>
        <div :if={@project.status != "archived"}>
          <p class="mt-1 text-xs text-neutral-500">
            {gettext("Archiving hides this Agent Swarm from the list. Disable every IM connection on the Integrations tab and delete every schedule on the Schedules tab first.")}
          </p>
          <.button
            class="mt-3"
            variant="danger"
            phx-click="archive_project"
            data-confirm={gettext("Archive \"%{name}\"? It will be hidden from the Agent Swarm list.", name: @project.name)}
          >
            {gettext("Archive Agent Swarm")}
          </.button>
        </div>

        <div :if={@project.status == "archived"} class="mt-3">
          <.badge color="neutral">{gettext("This Agent Swarm is archived.")}</.badge>
        </div>
      </section>
    </div>
    """
  end

  defp access_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-semibold text-neutral-700">{gettext("Access")}</h2>
        <div class="flex items-center gap-2">
          <.button
            :if={@can_manage_project}
            variant="primary"
            size="sm"
            phx-click="open_access_form"
          >
            <.icon name="plus" class="h-4 w-4" /> {gettext("Add user")}
          </.button>
          <.button
            :if={@can_view_audit}
            href={~p"/orgs/#{@current_org.slug}/operations/audit?#{%{resource_type: "project_member"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View audit")}
          </.button>
          <.badge color={if @project_role == "admin", do: "brand", else: "neutral"}>
            {access_role_label(@project_role)}
          </.badge>
        </div>
      </div>

      <.modal
        :if={@can_manage_project && @show_access_form}
        id="grant-access-modal"
        show
        on_cancel={JS.push("close_access_form")}
      >
        <:title>{gettext("Add user")}</:title>
        <.form for={@access_form} phx-submit="grant_access" id="grant-access-form">
          <div class="space-y-4">
            <.input
              field={@access_form[:email]}
              type="email"
              label={gettext("Email")}
              placeholder="person@example.com"
              required
            />
            <.select
              field={@access_form[:role]}
              label={gettext("Role")}
              options={access_role_options()}
            />
          </div>
          <div class="mt-5 flex items-center justify-end gap-2">
            <.button type="button" phx-click={JS.exec("phx-remove", to: "#grant-access-modal") |> JS.push("close_access_form")}>{gettext("Cancel")}</.button>
            <.button type="submit" variant="primary">{gettext("Add user")}</.button>
          </div>
        </.form>
      </.modal>

      <.empty_state
        :if={@project_members == []}
        icon="users"
        title={gettext("No explicit access grants")}
        description={gettext("Org admins still have admin access to this Agent Swarm.")}
      />

      <.table
        :if={@project_members != []}
        id="project-access"
        rows={@project_members}
        row_id={fn m -> "project-access-#{m.user_id}" end}
      >
        <:col :let={m} label={gettext("User")}>
          <div class="flex flex-col">
            <span class="font-medium text-neutral-900">{display_name(m.user)}</span>
            <span class="text-xs text-neutral-500">{m.user.email}</span>
          </div>
        </:col>
        <:col :let={m} label={gettext("Role")}>
          <form
            :if={@can_manage_project}
            id={"project-access-role-form-#{m.user_id}"}
            phx-change="change_access_role"
            class="inline-flex"
          >
            <input type="hidden" name="user-id" value={m.user_id} />
            <.select
              name="role"
              value={m.role}
              options={access_role_options()}
              class="w-32"
            />
          </form>
          <.badge :if={!@can_manage_project} color={if m.role == "admin", do: "brand", else: "neutral"}>
            {access_role_label(m.role)}
          </.badge>
        </:col>
        <:col :let={m} label={gettext("Granted")}>
          <span class="text-xs text-neutral-500">{format_date(m.created_at)}</span>
        </:col>
        <:action :let={m}>
          <.button
            :if={@can_manage_project}
            variant="ghost"
            size="sm"
            phx-click="remove_access"
            phx-value-user-id={m.user_id}
            data-confirm={gettext("Remove %{email} from %{project}?", email: m.user.email, project: @project.name)}
          >
            {gettext("Remove")}
          </.button>
        </:action>
      </.table>
    </div>
    """
  end

  defp external_target_picker(assigns) do
    location = agent_form_value(assigns.form, :runtime_location, "connected")
    selected_device_id = agent_form_value(assigns.form, :device_id)
    selected_env = selected_agent_environment(assigns.environments, selected_device_id)
    environment_options = agent_environment_options(assigns.environments)
    runtime_options = agent_runtime_options(selected_env)

    selected_runtime =
      selected_runtime(selected_env, agent_form_value(assigns.form, :device_runtime_id))

    assigns =
      assigns
      |> assign(:location, location)
      |> assign(:selected_device_id, selected_device_id)
      |> assign(:selected_env, selected_env)
      |> assign(:environment_options, environment_options)
      |> assign(:runtime_options, runtime_options)
      |> assign(:selected_runtime, selected_runtime)

    ~H"""
    <div class="space-y-3" data-testid="external-target-picker">
      <fieldset>
        <legend class="mb-1.5 block text-xs font-medium text-neutral-700">{gettext("Run on")}</legend>
        <div class="grid grid-cols-2 gap-2">
          <label class="relative cursor-pointer">
            <input
              type="radio"
              name="agent[runtime_location]"
              id={"#{@id_prefix}_runtime_location_connected"}
              value="connected"
              checked={@location == "connected"}
              class="peer sr-only"
            />
            <span class="flex min-h-10 items-center justify-center rounded-md border border-neutral-200 px-3 text-sm peer-checked:border-brand-500 peer-checked:bg-brand-50 peer-checked:text-brand-700">
              {gettext("Connected Device")}
            </span>
          </label>
          <label class="relative cursor-pointer">
            <input
              type="radio"
              name="agent[runtime_location]"
              id={"#{@id_prefix}_runtime_location_compute"}
              value="compute"
              checked={@location == "compute"}
              class="peer sr-only"
            />
            <span class="flex min-h-10 items-center justify-center rounded-md border border-neutral-200 px-3 text-sm peer-checked:border-brand-500 peer-checked:bg-brand-50 peer-checked:text-brand-700">
              {gettext("Compute Workload")}
            </span>
          </label>
        </div>
      </fieldset>

      <div :if={@location == "connected"} class="space-y-3" data-testid="connected-target-picker">
        <p :if={@environments_error} class="text-xs text-red-600" role="alert">
          {agent_environment_error_message(@environments_error)}
        </p>
        <p :if={is_nil(@environments_error) && @environment_options == []} class="text-xs text-neutral-500">
          {gettext("No connected devices are available for this Agent Swarm.")}
        </p>
        <.select
          name="agent[device_id]"
          id={"#{@id_prefix}_device_id"}
          label={gettext("Connected Device")}
          prompt={gettext("Select a device")}
          value={@selected_device_id}
          options={@environment_options}
          disabled={@environment_options == []}
          required
        />
        <.select
          name="agent[device_runtime_id]"
          id={"#{@id_prefix}_device_runtime_id"}
          label={gettext("External runtime")}
          prompt={gettext("Select a runtime")}
          value={agent_form_value(@form, :device_runtime_id)}
          options={@runtime_options}
          disabled={is_nil(@selected_env) || @runtime_options == []}
          required
        />
        <div
          :if={@selected_runtime}
          class="space-y-2 rounded-md border border-neutral-200 bg-white p-3"
          data-testid={runtime_readiness_test_id(@id_prefix)}
        >
          <div class="flex flex-wrap items-center gap-2">
            <.status_pill
              status={runtime_pill_status(@selected_runtime)}
              label={runtime_status_label(@selected_runtime)}
            />
            <span :if={runtime_version_label(@selected_runtime)} class="text-xs text-neutral-500">
              {runtime_version_label(@selected_runtime)}
            </span>
            <span
              :if={runtime_value(@selected_runtime, "readiness_checked_at")}
              class="text-xs text-neutral-400"
            >
              {gettext("checked")} {format_unix(runtime_value(@selected_runtime, "readiness_checked_at"))}
            </span>
          </div>
          <p :if={runtime_value(@selected_runtime, "issue")} class="text-xs text-neutral-500">
            {runtime_value(@selected_runtime, "issue")}
          </p>
          <p :if={!runtime_ready?(@selected_runtime)} class="text-xs text-amber-700">
            {gettext("This runtime is not ready. Select a ready runtime before saving.")}
          </p>
        </div>
      </div>

      <div :if={@location == "compute"} class="space-y-3" data-testid="compute-workload-picker">
        <fieldset>
          <legend class="mb-1.5 block text-xs font-medium text-neutral-700">{gettext("Provider")}</legend>
          <div class="flex flex-wrap items-center gap-4">
            <label :for={provider <- ["codex", "pi", "claude"]} class="flex items-center gap-2 text-sm">
              <input
                type="radio"
                name="agent[workload_provider]"
                value={provider}
                checked={agent_form_value(@form, :workload_provider, "codex") == provider}
              />
              {String.capitalize(provider)}
            </label>
            <label class="flex items-center gap-2 text-sm text-neutral-600">
              <input
                type="checkbox"
                id={"#{@id_prefix}_show_unavailable_workloads"}
                name="agent[show_unavailable_workloads]"
                value="true"
                checked={show_unavailable_workloads?(agent_form_value(@form, :show_unavailable_workloads))}
              />
              {gettext("Show unavailable workloads")}
            </label>
          </div>
        </fieldset>
        <label class="block">
          <span class="mb-1.5 block text-xs font-medium text-neutral-700">{gettext("Search workloads")}</span>
          <input
            type="search"
            name="agent[workload_query]"
            value={agent_form_value(@form, :workload_query)}
            placeholder={gettext("Search by workload or node")}
            class="w-full rounded-md border border-neutral-200 bg-white px-3 py-2 text-sm"
          />
        </label>
        <p :if={@workload_error} class="text-xs text-red-600" role="alert">
          {gettext("Compute Workloads are unavailable. Refresh and try again.")}
        </p>
        <p :if={is_nil(@workload_error) && @workload_items == []} class="text-xs text-neutral-500">
          {gettext("No matching Compute Workloads.")}
        </p>
        <fieldset :if={@workload_items != []} class="space-y-2" aria-label={gettext("Compute Workloads")}>
          <label
            :for={item <- @workload_items}
            class={[
              "flex items-start gap-3 rounded-md border bg-white p-3",
              item["selectable"] && "cursor-pointer border-neutral-200",
              !item["selectable"] && "cursor-not-allowed border-neutral-100 opacity-60"
            ]}
          >
            <input
              type="radio"
              name="agent[workload_id]"
              value={item["workload_id"]}
              checked={agent_form_value(@form, :workload_id) == item["workload_id"]}
              disabled={!item["selectable"]}
              aria-describedby={"workload-#{item["workload_id"]}-status"}
            />
            <span class="min-w-0 flex-1">
              <span class="block text-sm font-medium text-neutral-800">{item["label"]}</span>
              <span class="block truncate text-xs text-neutral-500">{get_in(item, ["node", "label"])}</span>
              <span
                id={"workload-#{item["workload_id"]}-status"}
                class={workload_availability_class(item)}
              >
                {workload_availability_label(item)}
              </span>
              <span
                :if={is_map(item["reconcile_error"])}
                class="block text-xs text-amber-700"
              >
                {reconcile_error_label(item["reconcile_error"])}
              </span>
            </span>
          </label>
        </fieldset>
        <div class="flex items-center justify-between gap-2">
          <.button type="button" size="sm" phx-click="refresh_external_workloads">
            {gettext("Refresh")}
          </.button>
          <.button
            :if={@workload_next_cursor}
            type="button"
            size="sm"
            phx-click="next_external_workloads"
          >
            {gettext("Next page")}
          </.button>
        </div>
      </div>
    </div>
    """
  end

  defp agents_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
        <h2 class="text-sm font-semibold text-neutral-700">{gettext("Agents")}</h2>
        <div class="flex flex-wrap items-center justify-end gap-2">
          <.button
            :if={@can_view_operations}
            href={~p"/orgs/#{@current_org.slug}/operations/events?#{%{project_id: @project.id, domain: "agent"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View events")}
          </.button>
          <.button
            :if={@can_view_audit}
            href={~p"/orgs/#{@current_org.slug}/operations/audit?#{%{resource_type: "agent"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View audit")}
          </.button>
          <.button variant="ghost" size="sm" phx-click="retry_agents">{gettext("Refresh")}</.button>
          <.button :if={@can_manage_project} variant="primary" size="sm" phx-click="new_agent">
            <.icon name="plus" class="h-4 w-4" /> {gettext("New agent")}
          </.button>
        </div>
      </div>

      <.empty_state
        :if={@agents == [] && is_nil(@salix_agents_error) && is_nil(@agent_next_cursor)}
        icon="bolt"
        title={gettext("No agents yet")}
        description={gettext("New agents appear after provisioning. Refresh to check their status.")}
      >
        <:actions>
          <.button :if={@can_manage_project} variant="primary" size="sm" phx-click="new_agent">{gettext("New agent")}</.button>
        </:actions>
      </.empty_state>

      <div
        :if={@salix_agents_error}
        class="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800"
      >
        {salix_agents_error_message(@salix_agents_error)}
        <.button variant="ghost" size="sm" phx-click="retry_agents">{gettext("Retry")}</.button>
      </div>

      <.table
        :if={@agents != []}
        id="agents"
        rows={@agents}
        action_align="left"
        row_id={fn agent -> "agent-#{agent.id}" end}
        row_click={fn agent ->
          JS.navigate(~p"/orgs/#{@current_org.slug}/projects/#{@project.id}/agents/#{agent.id}")
        end}
      >
        <:col :let={agent} label={gettext("Name")}>
          <span class="font-medium text-neutral-800">{agent.salix["name"] || "—"}</span>
        </:col>
        <:col :let={agent} label={gettext("Role")}>
          <.badge color={role_color(agent.role)}>{agent.role}</.badge>
          <span :if={@triage_worker_binding && @triage_worker_binding["worker_agent_id"] == agent.salix_agent_id}>
            <.link :if={@triage_configuration_path} navigate={@triage_configuration_path} phx-click={JS.navigate(@triage_configuration_path)}>
              <.badge color="brand">{gettext("Used by Triage")}</.badge>
            </.link>
            <.badge :if={!@triage_configuration_path} color="brand">{gettext("Used by Triage")}</.badge>
          </span>
          <.badge :if={router_agent?(agent, @router_agent_id)} color="green">{gettext("group router")}</.badge>
        </:col>
        <:col :let={agent} label={gettext("Status")}>
          <.status_pill status={BridgeForTeams.Schema.Agent.lifecycle(agent)} />
        </:col>
        <:action :let={agent}>
          <.button
            :if={@can_view_operations}
            href={
              ~p"/orgs/#{@current_org.slug}/operations/events?#{%{project_id: @project.id, domain: "agent", resource_id: agent.id}}"
            }
            variant="ghost"
            size="sm"
            class="whitespace-nowrap"
          >
            {gettext("Events")}
          </.button>
          <.button
            :if={@can_view_audit}
            href={
              ~p"/orgs/#{@current_org.slug}/operations/audit?#{%{resource_type: "agent", resource_id: agent.id}}"
            }
            variant="ghost"
            size="sm"
            class="whitespace-nowrap"
          >
            {gettext("Audit")}
          </.button>
          <.button :if={@can_manage_project} size="sm" class="whitespace-nowrap" phx-click="configure_agent" phx-value-id={agent.id}>{gettext("Configure")}</.button>
          <.button
            :if={
              @can_manage_project &&
                runtime_rebindable_agent?(agent)
            }
            size="sm"
            class="whitespace-nowrap"
            phx-click="rebind_agent"
            phx-value-id={agent.id}
          >
            {gettext("Rebind runtime")}
          </.button>
          <.button
            :if={@can_manage_project && agent.role != "router"}
            size="sm"
            variant="danger"
            class="whitespace-nowrap"
            phx-click="request_archive_agent"
            phx-value-id={agent.id}
          >
            {gettext("Archive")}
          </.button>
        </:action>
      </.table>
      <div :if={@agent_page_cursor || @agent_next_cursor} class="flex justify-end gap-2">
        <.button :if={@agent_page_cursor} variant="ghost" size="sm" phx-click="first_agent_page">{gettext("First page")}</.button>
        <.button :if={@agent_next_cursor} variant="secondary" size="sm" phx-click="next_agent_page">{gettext("Next page")}</.button>
      </div>


      <.modal
        :if={@archive_agent}
        id="archive-agent-modal"
        show
        on_cancel={JS.push("close_archive_agent")}
      >
        <:title>{gettext("Archive agent")}</:title>
        <p class="text-sm text-neutral-600">
          {gettext("Archive %{name}? The agent will be removed from this Agent Swarm.", name: @archive_agent.salix["name"])}
        </p>
        <div :if={@archive_triage_binding && @archive_triage_binding["worker_agent_id"] == @archive_agent.salix_agent_id} class="mt-3 rounded-lg bg-amber-50 p-3 text-sm text-amber-900" id="archive-triage-warning">
          <p>{gettext("This Worker is used by Triage in %{swarm}. Archiving it will stop new Triage assignments until you select another Worker.", swarm: @project.name)}</p>
          <p class="mt-2">{gettext("Existing tasks are not reassigned. Archiving also stops this Worker's execution and pauses its schedules.")}</p>
          <.link :if={@triage_configuration_path} navigate={@triage_configuration_path} class="mt-2 inline-block font-medium underline">{gettext("Choose another Worker in Triage")}</.link>
        </div>
        <div class="mt-5 flex items-center justify-end gap-2">
          <.button type="button" phx-click={JS.exec("phx-remove", to: "#archive-agent-modal") |> JS.push("close_archive_agent")}>{gettext("Cancel")}</.button>
          <.button
            type="button"
            variant="danger"
            phx-click="archive_agent"
            phx-value-id={@archive_agent.id}
          >
            <%= if @archive_triage_binding && @archive_triage_binding["worker_agent_id"] == @archive_agent.salix_agent_id do %>
              {gettext("Archive and pause Triage")}
            <% else %>
              {gettext("Archive")}
            <% end %>
          </.button>
        </div>
      </.modal>

      <.modal
        :if={@agent_form && is_nil(@configure_agent) && is_nil(@rebind_agent)}
        id="new-agent-modal"
        show
        on_cancel={JS.push("close_agent_form")}
      >
        <:title>{gettext("New agent")}</:title>
        <.form for={@agent_form} phx-change="validate_agent" phx-submit="create_agent" id="new-agent-form">
          <% agent_type = agent_form_value(@agent_form, :agent_type, "internal") %>

          <div class="space-y-4">
            <.input field={@agent_form[:name]} label={gettext("Name")} placeholder={gettext("e.g. triage-worker")} />
            <fieldset>
              <legend class="mb-1.5 block text-xs font-medium text-neutral-700">{gettext("Agent type")}</legend>
              <div class="grid grid-cols-2 gap-2">
                <label class="relative cursor-pointer">
                  <input
                    type="radio"
                    name="agent[agent_type]"
                    id="agent_agent_type_internal"
                    value="internal"
                    checked={agent_type == "internal"}
                    class="peer sr-only"
                  />
                  <span class="flex min-h-10 items-center justify-center rounded-md border border-neutral-200 px-3 text-sm font-medium text-neutral-600 transition-colors peer-checked:border-brand-500 peer-checked:bg-brand-50 peer-checked:text-brand-700 hover:border-neutral-300">
                    {gettext("Internal")}
                  </span>
                </label>
                <label class="relative cursor-pointer">
                  <input
                    type="radio"
                    name="agent[agent_type]"
                    id="agent_agent_type_external"
                    value="external"
                    checked={agent_type == "external"}
                    class="peer sr-only"
                  />
                  <span class="flex min-h-10 items-center justify-center rounded-md border border-neutral-200 px-3 text-sm font-medium text-neutral-600 transition-colors peer-checked:border-brand-500 peer-checked:bg-brand-50 peer-checked:text-brand-700 hover:border-neutral-300">
                    {gettext("External Agent")}
                  </span>
                </label>
              </div>
            </fieldset>
            <input type="hidden" name="agent[role]" value="worker" />
            <div
              :if={agent_type == "external"}
              class="rounded-md border border-neutral-200 bg-neutral-50 p-3 space-y-3"
            >
              <p class="text-xs text-neutral-500">
                {gettext("External agents run as workers on a Connected Device or Compute Workload.")}
              </p>
              <.external_target_picker
                form={@agent_form}
                id_prefix="agent"
                environments={@agent_environments}
                environments_error={@agent_environments_error}
                workload_items={@external_workload_items}
                workload_error={@external_workload_error}
                workload_next_cursor={@external_workload_next_cursor}
              />
            </div>
          </div>
          <div class="mt-5 flex items-center justify-end gap-2">
            <.button
              type="button"
              phx-click={JS.exec("phx-remove", to: "#new-agent-modal") |> JS.push("close_agent_form")}
            >
              {gettext("Cancel")}
            </.button>
            <.button type="submit" variant="primary">{gettext("Create agent")}</.button>
          </div>
        </.form>
      </.modal>

      <.modal
        :if={@rebind_agent}
        id="rebind-agent-runtime-modal"
        show
        on_cancel={JS.push("close_agent_form")}
      >
        <:title>{gettext("Rebind runtime for %{name}", name: @rebind_agent.salix["name"] || gettext("agent"))}</:title>
        <.form for={@agent_form} phx-change="validate_rebind" phx-submit="save_rebind" id="rebind-agent-runtime-form">
          <div class="space-y-4">
            <div
              class="grid gap-2 rounded-md border border-neutral-200 bg-neutral-50 p-3 text-xs"
              data-testid="external-binding-summary"
            >
              <div>
                <span class="font-medium text-neutral-700">{gettext("Target for new sessions")}</span>
                <span class="ml-2 text-neutral-500">{binding_summary(@rebind_agent.salix["runtime_config"])}</span>
              </div>
            </div>
            <input
              type="hidden"
              name="agent[expected_binding_revision]"
              value={agent_form_value(@agent_form, :expected_binding_revision, "0")}
            />
            <.external_target_picker
              form={@agent_form}
              id_prefix="rebind_agent"
              environments={@agent_environments}
              environments_error={@agent_environments_error}
              workload_items={@external_workload_items}
              workload_error={@external_workload_error}
              workload_next_cursor={@external_workload_next_cursor}
            />
            <p class="text-xs text-amber-700">
              {gettext("This changes new tasks only. Active tasks keep their current runtime.")}
            </p>
          </div>
          <div class="mt-5 flex items-center justify-end gap-2">
            <.button
              type="button"
              phx-click={
                JS.exec("phx-remove", to: "#rebind-agent-runtime-modal")
                |> JS.push("close_agent_form")
              }
            >
              {gettext("Cancel")}
            </.button>
            <.button type="submit" variant="primary">{gettext("Save runtime")}</.button>
          </div>
        </.form>
      </.modal>

      <.modal
        :if={@configure_agent}
        id="configure-agent-modal"
        show
        on_cancel={JS.push("close_agent_form")}
      >
        <:title>{gettext("Configure %{name}", name: @configure_agent.salix["name"] || gettext("agent"))}</:title>
        <.form for={@agent_form} phx-submit="save_config" id="configure-agent-form">
          <div class="space-y-4">
            <div>
              <.field_label>{gettext("Role")}</.field_label>
              <p class="text-sm text-neutral-600">{@configure_agent.role}</p>
            </div>
            <.select
              name="agent[template_id]"
              id="agent_template_id"
              label={gettext("Model")}
              value={configure_template_value(@configure_agent)}
              prompt={follow_default_prompt(@configure_agent, @effective_model_defaults)}
              options={@agent_template_options}
              model_catalog={@agent_templates}
              model_default_icon={@effective_model_defaults[@configure_agent.role]["model_icon"]}
              disabled={@agent_templates == []}
            />
            <div :if={@agent_templates == []}>
              <p class="text-xs text-neutral-500">
                {gettext("No models are available. An org admin can enable models in organization settings.")}
              </p>
            </div>
            <.textarea
              field={@agent_form[:system_prompt]}
              label={gettext("System prompt")}
              rows="5"
              placeholder={gettext("System prompt for this agent…")}
            />
          </div>
          <div class="mt-5 flex items-center justify-end gap-2">
            <.button
              type="button"
              phx-click={
                JS.exec("phx-remove", to: "#configure-agent-modal")
                |> JS.push("close_agent_form")
              }
            >
              {gettext("Cancel")}
            </.button>
            <.button type="submit" variant="primary">{gettext("Save configuration")}</.button>
          </div>
        </.form>
      </.modal>
    </div>
    """
  end

  defp conversations_tab(assigns) do
    filtered =
      filtered_conversations(
        assigns.conversations,
        assigns.conversation_status_filter,
        assigns.conversation_query,
        assigns.conversation_agents
      )

    assigns =
      assigns
      |> assign(:conversation_statuses, conversation_statuses(assigns.conversations))
      |> assign(:filtered_conversations, filtered)
      |> assign(:conversation_groups, conversation_groups(filtered))

    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between gap-3">
        <div class="flex min-w-0 items-baseline gap-2">
          <h2 class="text-sm font-semibold text-neutral-700">{gettext("Tasks")}</h2>
          <span class="text-xs text-neutral-400">{length(@conversations)}</span>
        </div>

        <div class="flex items-center justify-end gap-2">
          <.dropdown
            :if={@can_view_operations || @can_view_audit}
            id="task-operations-menu"
            align="right"
          >
            <:trigger>
              <button
                type="button"
                class="grid h-7 w-7 place-items-center rounded-md text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900"
                aria-label={gettext("Task operations")}
                title={gettext("Task operations")}
              >
                <.icon name="ellipsis" class="h-4 w-4" />
              </button>
            </:trigger>
            <.dropdown_item
              :if={@can_view_operations}
              href={~p"/orgs/#{@current_org.slug}/operations/events?#{%{project_id: @project.id, domain: "conversation"}}"}
            >
              {gettext("View events")}
            </.dropdown_item>
            <.dropdown_item
              :if={@can_view_audit}
              href={~p"/orgs/#{@current_org.slug}/operations/audit?#{%{resource_type: "project_conversation"}}"}
            >
              {gettext("View audit")}
            </.dropdown_item>
          </.dropdown>
          <.button
            :if={@conversation_agents != [] && @can_manage_project}
            variant="primary"
            size="sm"
            phx-click="new_conversation"
          >
            <.icon name="plus" class="h-4 w-4" /> {gettext("New task")}
          </.button>
        </div>
      </div>

      <div class="flex min-w-0 items-center gap-1 overflow-x-auto">
        <button
          :for={status <- ["all", "scheduled" | @conversation_statuses]}
          type="button"
          phx-click="set_conversation_status_filter"
          phx-value-status={status}
          aria-pressed={to_string(@conversation_status_filter == status)}
          class={[
            "h-7 shrink-0 rounded-md px-2.5 text-xs font-medium transition-colors",
            @conversation_status_filter == status && "bg-neutral-100 text-neutral-900",
            @conversation_status_filter != status && "text-neutral-500 hover:bg-neutral-50 hover:text-neutral-800"
          ]}
        >
          {if status == "all", do: gettext("All"), else: conversation_status_label(status)}
          <span class="ml-1 text-neutral-400">
            {conversation_status_count(@conversations, status)}
          </span>
        </button>
      </div>

      <form
        :if={is_nil(@conversations_error) && @conversations != []}
        id="task-search-form"
        phx-change="filter_conversations"
        class="relative max-w-sm"
      >
        <.icon name="search" class="pointer-events-none absolute left-2.5 top-2 h-3.5 w-3.5 text-neutral-400" />
        <input
          type="search"
          name="query"
          value={@conversation_query}
          placeholder={gettext("Search tasks")}
          aria-label={gettext("Search tasks")}
          phx-debounce="150"
          class="h-8 w-full rounded-md border border-neutral-200 bg-white pl-8 pr-3 text-xs text-neutral-800 outline-none placeholder:text-neutral-400 focus:border-brand-400 focus:ring-2 focus:ring-brand-100"
        />
      </form>

      <.empty_state
        :if={@conversations_error}
        icon="inbox"
        title={gettext("Tasks unavailable")}
        description={gettext("The task index could not be loaded.")}
      />

      <.empty_state
        :if={is_nil(@conversations_error) && @conversation_agents != [] && @conversations == []}
        icon="inbox"
        title={gettext("No tasks yet")}
        description={gettext("Tasks created in this Agent Swarm will appear here.")}
      >
        <:actions>
          <.button
            :if={@conversation_agents != [] && @can_manage_project}
            variant="primary"
            size="sm"
            phx-click="new_conversation"
          >
            {gettext("New task")}
          </.button>
        </:actions>
      </.empty_state>

      <.empty_state
        :if={is_nil(@conversations_error) && @conversation_agents == []}
        icon="bolt"
        title={gettext("Create an agent first")}
        description={gettext("A task needs an agent before work can begin.")}
      />

      <.empty_state
        :if={@conversations != [] && @filtered_conversations == []}
        icon="search"
        title={gettext("No matching tasks")}
        description={gettext("Try another search or status filter.")}
      />

      <div :if={@conversation_groups != []} id="conversations" class="overflow-hidden rounded-lg border border-neutral-200 bg-white">
        <section :for={{status, conversations} <- @conversation_groups} id={"task-group-#{status}"}>
          <div class="flex h-9 items-center gap-2 border-b border-neutral-200 bg-neutral-50 px-3 text-xs font-medium text-neutral-600">
            <.status_pill status={status} label={conversation_status_label(status)} />
            <span class="text-neutral-400">{length(conversations)}</span>
          </div>

          <div
            :for={conversation <- conversations}
            id={"conversation-#{conversation["conversation_id"]}"}
            class="group relative flex min-h-12 items-center gap-3 border-b border-neutral-100 px-3 last:border-b-0 hover:bg-neutral-50"
          >
            <.link
              navigate={~p"/orgs/#{@current_org.slug}/projects/#{@project.id}/tasks/#{conversation["conversation_id"]}"}
              class="absolute inset-0"
              aria-label={conversation_title(conversation)}
            >
              <span class="sr-only">{conversation_title(conversation)}</span>
            </.link>
            <.status_pill status={conversation_status(conversation)} label="" />
            <div class="min-w-0 flex-1 py-2">
              <div class="flex min-w-0 items-center gap-2 text-[13px] font-medium text-neutral-800">
                <span class="truncate">{conversation_title(conversation)}</span>
                <span
                  :if={scheduled_conversation?(conversation)}
                  class="shrink-0 rounded-full bg-violet-50 px-1.5 py-0.5 text-[10px] font-medium text-violet-700"
                >
                  {gettext("Scheduled")}
                </span>
              </div>
              <div class="mt-0.5 flex items-center gap-2 overflow-hidden text-xs text-neutral-500">
                <span class="shrink-0">{conversation_kind_label(conversation)}</span>
              </div>
            </div>
            <time class="hidden shrink-0 text-xs text-neutral-400 sm:block">
              {format_unix(conversation["updated_at"])}
            </time>
            <.dropdown
              :if={@can_view_operations || @can_view_audit}
              id={"task-row-menu-#{conversation["conversation_id"]}"}
              align="right"
              class="relative z-10 shrink-0"
            >
              <:trigger>
                <button
                  type="button"
                  class="grid h-7 w-7 place-items-center rounded-md text-neutral-400 opacity-0 hover:bg-neutral-100 hover:text-neutral-900 focus:opacity-100 group-hover:opacity-100"
                  aria-label={gettext("Task actions")}
                  title={gettext("Task actions")}
                >
                  <.icon name="ellipsis" class="h-4 w-4" />
                </button>
              </:trigger>
              <.dropdown_item
                :if={@can_view_operations}
                href={~p"/orgs/#{@current_org.slug}/operations/events?#{%{project_id: @project.id, domain: "conversation", resource_id: conversation["conversation_id"]}}"}
              >
                {gettext("View events")}
              </.dropdown_item>
              <.dropdown_item
                :if={@can_view_audit}
                href={~p"/orgs/#{@current_org.slug}/operations/audit?#{%{resource_type: "project_conversation", resource_id: conversation["conversation_id"]}}"}
              >
                {gettext("View audit")}
              </.dropdown_item>
            </.dropdown>
          </div>
        </section>
      </div>

      <.modal
        :if={@conversation_form}
        id="new-conversation-modal"
        show
        on_cancel={JS.push("close_conversation_form")}
      >
        <:title>{gettext("New task")}</:title>
        <.form
          for={@conversation_form}
          phx-submit="create_conversation"
          id="new-conversation-form"
        >
          <div class="space-y-4">
            <.input
              field={@conversation_form[:title]}
              label={gettext("Title")}
              placeholder={gettext("e.g. Incident triage")}
            />
            <.select
              field={@conversation_form[:agent_id]}
              label={gettext("Agent")}
              options={agent_options(@conversation_agents)}
              required
            />
          </div>
          <div class="mt-5 flex items-center justify-end gap-2">
            <.button
              type="button"
              phx-click={
                JS.exec("phx-remove", to: "#new-conversation-modal")
                |> JS.push("close_conversation_form")
              }
            >
              {gettext("Cancel")}
            </.button>
            <.button type="submit" variant="primary">{gettext("Create task")}</.button>
          </div>
        </.form>
      </.modal>
    </div>
    """
  end

  defp schedules_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
        <div>
          <h2 class="text-sm font-semibold text-neutral-700">{gettext("Schedules")}</h2>
          <p class="mt-1 text-xs text-neutral-500">
            {gettext("Recurring schedules for this Agent Swarm, including task schedules, sourced live from Salix.")}
          </p>
        </div>
        <div class="flex flex-wrap items-center justify-end gap-2">
          <.button
            :if={@can_view_operations}
            href={~p"/orgs/#{@current_org.slug}/operations/events?#{%{project_id: @project.id, domain: "schedule"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View events")}
          </.button>
          <.button
            :if={@can_view_audit}
            href={~p"/orgs/#{@current_org.slug}/operations/audit?#{%{resource_type: "project_schedule"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View audit")}
          </.button>
        </div>
      </div>

      <.empty_state
        :if={@schedules_error in [:unavailable, :timeout]}
        icon="clock"
        title={gettext("Salix unavailable")}
        description={gettext("Could not load schedules from Salix. Retry shortly.")}
      />

      <.empty_state
        :if={is_nil(@schedules_error) && @schedules == []}
        icon="clock"
        title={gettext("No schedules yet")}
        description={gettext("Recurring schedules for agents and tasks in this Agent Swarm appear here.")}
      />

      <.table
        :if={@schedules != []}
        id="schedules"
        rows={@schedules}
        row_id={fn schedule -> "schedule-#{schedule["id"]}" end}
      >
        <:col :let={schedule} label={gettext("Target")}>
          <.link
            :if={schedule["target_type"] == "agent"}
            navigate={
              ~p"/orgs/#{@current_org.slug}/projects/#{@project.id}/agents/#{schedule["bft_agent_id"]}"
            }
            class="text-brand-600 underline"
          >
            {schedule["agent_name"]}
          </.link>
          <.link
            :if={schedule["target_type"] == "task"}
            navigate={
              ~p"/orgs/#{@current_org.slug}/projects/#{@project.id}/tasks/#{schedule["conversation_id"]}"
            }
            class="text-brand-600 underline"
          >
            {gettext("Task")}
          </.link>
        </:col>
        <:col :let={schedule} label={gettext("Recurrence")}>
          <span class="text-neutral-700">{schedule_recurrence(schedule)}</span>
        </:col>
        <:col :let={schedule} label={gettext("Details")}>
          <span :if={schedule["target_type"] == "task"} class="text-neutral-700">
            {gettext("Runs this task")}
          </span>
          <span :if={schedule["target_type"] == "agent"} class="line-clamp-2 max-w-md text-neutral-700">
            {schedule["prompt"]}
          </span>
        </:col>
        <:col :let={schedule} label={gettext("Session")}>
          <span class="font-mono text-xs text-neutral-500">{schedule["session_id"] || "—"}</span>
        </:col>
        <:col :let={schedule} label={gettext("Last run")}>
          <span class="text-xs text-neutral-500">{format_schedule_ms(schedule["last_run"])}</span>
        </:col>
        <:col :let={schedule} label={gettext("Created")}>
          <span class="text-xs text-neutral-500">{format_schedule_ms(schedule["created_at"])}</span>
        </:col>
        <:action :let={schedule}>
          <.button
            :if={@can_view_operations}
            href={
              ~p"/orgs/#{@current_org.slug}/operations/events?#{%{project_id: @project.id, domain: "schedule", resource_id: schedule["id"]}}"
            }
            variant="ghost"
            size="sm"
          >
            {gettext("Events")}
          </.button>
          <.button
            :if={@can_view_audit}
            href={
              ~p"/orgs/#{@current_org.slug}/operations/audit?#{schedule_audit_filters(schedule)}"
            }
            variant="ghost"
            size="sm"
          >
            {gettext("Audit")}
          </.button>
          <.button
            :if={@can_manage_project}
            variant="danger"
            size="sm"
            phx-click="delete_schedule"
            phx-value-id={schedule["id"]}
            data-confirm={gettext("Delete this schedule? It will stop firing immediately.")}
          >
            {gettext("Delete")}
          </.button>
        </:action>
      </.table>
    </div>
    """
  end

  # The project's Signal chats (docs/messaging-voice.md). A runtime failure, or
  # a Salix client without the optional Signal callbacks, shows this card as
  # unavailable and affects nothing else. A new code lives in `signal_claim`
  # until dismissed.
  defp assign_project_signal(socket) do
    status =
      case ProjectSignal.status(socket.assigns.current_org, socket.assigns.project) do
        {:ok, %{} = status} -> status
        _error -> nil
      end

    socket
    |> assign(:signal_status, status)
    |> assign_new(:signal_claim, fn -> nil end)
  end

  defp integrations_tab(assigns) do
    assigns = assign_new(assigns, :panel_only, fn -> false end)

    ~H"""
    <div class="space-y-5">
      <div
        :if={not @panel_only}
        class="flex flex-col gap-3 border-b border-neutral-200 pb-4 md:flex-row md:items-start md:justify-between"
      >
        <div>
          <h2 class="text-sm font-semibold text-neutral-800">{gettext("Messaging integrations")}</h2>
          <p class="mt-1 max-w-2xl text-xs text-neutral-500">
            {gettext("Connect Feishu or Slack so this Agent Swarm can receive messages and reply in your team's workspace.")}
          </p>
        </div>
        <div class="flex shrink-0 flex-wrap items-center gap-1">
          <.button
            :if={@can_view_operations}
            href={~p"/orgs/#{@current_org.slug}/operations/integrations?#{%{project_id: @project.id, surface: "bot"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View in Operations")}
          </.button>
          <.button
            :if={@can_view_operations}
            href={~p"/orgs/#{@current_org.slug}/operations/checks?#{%{project_id: @project.id, surface: "bot"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View checks")}
          </.button>
          <.button
            :if={@can_manage_project}
            type="button"
            size="sm"
            variant="primary"
            phx-click="open_integration_setup"
            phx-value-provider="choose"
          >
            <.icon name="plus" class="h-4 w-4" /> {gettext("Add")}
          </.button>
        </div>
      </div>

      <.empty_state
        :if={not @panel_only && @project_im_connects_error == :group_not_ready}
        icon="inbox"
        title={gettext("Agent Swarm is still preparing")}
        description={gettext("The runtime is not ready yet. Retry shortly.")}
      />

      <.empty_state
        :if={not @panel_only && @project_im_connects_error in [:unavailable, :timeout]}
        icon="inbox"
        title={gettext("Salix unavailable")}
        description={project_im_error_message(@project_im_connects_error)}
      />

      <div :if={@panel_only || is_nil(@project_im_connects_error)}>
        <section
          :if={not @panel_only}
          id="integration-provider-list"
          class="overflow-hidden rounded-lg border border-neutral-200 bg-white"
          aria-label={gettext("Messaging integrations")}
        >
          <ul class="divide-y divide-neutral-200">
            <li id="integration-provider-feishu" class="flex flex-col gap-3 px-4 py-4 sm:flex-row sm:items-center sm:justify-between">
              <div class="flex min-w-0 items-center gap-3">
                <span class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md border border-neutral-200 bg-white">
                  <.brand_logo name="feishu" class="h-5 w-5" />
                </span>
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="text-sm font-semibold text-neutral-900">{gettext("Feishu")}</h3>
                    <.badge color={feishu_route_badge_color(@feishu_route_state.status)}>
                      {feishu_route_badge_text(@feishu_route_state.status)}
                    </.badge>
                  </div>
                  <p class="mt-0.5 text-xs text-neutral-500">{gettext("Receive group mentions and route them to this Agent Swarm.")}</p>
                </div>
              </div>
              <div class="flex shrink-0 items-center gap-3 sm:pl-4">
                <span class="text-xs tabular-nums text-neutral-500">
                  {ngettext(
                    "%{count} connection",
                    "%{count} connections",
                    length(@feishu_connects)
                  )}
                </span>
                <.button
                  :if={@can_manage_project}
                  type="button"
                  size="sm"
                  phx-click="open_integration_setup"
                  phx-value-provider="feishu"
                >
                  {gettext("Configure")}
                </.button>
              </div>
            </li>
            <li id="integration-provider-slack" class="flex flex-col gap-3 px-4 py-4 sm:flex-row sm:items-center sm:justify-between">
              <div class="flex min-w-0 items-center gap-3">
                <span class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md border border-neutral-200 bg-white">
                  <.brand_logo name="slack" class="h-5 w-5" />
                </span>
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="text-sm font-semibold text-neutral-900">{gettext("Slack")}</h3>
                    <.badge color={if @slack_connects == [], do: "neutral", else: "green"}>
                      {if @slack_connects == [], do: gettext("not connected"), else: gettext("connected")}
                    </.badge>
                  </div>
                  <p class="mt-0.5 text-xs text-neutral-500">{gettext("Receive app mentions and send replies in Slack.")}</p>
                </div>
              </div>
              <div class="flex shrink-0 items-center gap-3 sm:pl-4">
                <span class="text-xs tabular-nums text-neutral-500">
                  {ngettext(
                    "%{count} connection",
                    "%{count} connections",
                    length(@slack_connects)
                  )}
                </span>
                <.button
                  :if={@can_manage_project}
                  type="button"
                  size="sm"
                  phx-click="open_integration_setup"
                  phx-value-provider="slack"
                >
                  {gettext("Configure")}
                </.button>
              </div>
            </li>
          </ul>
        </section>

        <.side_panel
          :if={@integration_setup_provider}
          id="integration-setup-panel"
          show
          size="xl"
          on_cancel={JS.push("close_integration_setup")}
        >
          <:title>{if @integration_setup_provider == "choose", do: gettext("Add"), else: gettext("Configure")}</:title>
          <div :if={@integration_setup_provider == "choose"} class="space-y-2">
            <button
              type="button"
              class="flex w-full items-center gap-3 rounded-lg border border-neutral-200 px-4 py-4 text-left hover:border-neutral-300 hover:bg-neutral-50"
              phx-click="open_integration_setup"
              phx-value-provider="feishu"
            >
              <span class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md border border-neutral-200 bg-white">
                <.brand_logo name="feishu" class="h-5 w-5" />
              </span>
              <span>
                <span class="block text-sm font-semibold text-neutral-900">Feishu</span>
                <span class="mt-0.5 block text-xs text-neutral-500">{gettext("Receive group mentions and route them to this Agent Swarm.")}</span>
              </span>
            </button>
            <button
              type="button"
              class="flex w-full items-center gap-3 rounded-lg border border-neutral-200 px-4 py-4 text-left hover:border-neutral-300 hover:bg-neutral-50"
              phx-click="open_integration_setup"
              phx-value-provider="slack"
            >
              <span class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md border border-neutral-200 bg-white">
                <.brand_logo name="slack" class="h-5 w-5" />
              </span>
              <span>
                <span class="block text-sm font-semibold text-neutral-900">Slack</span>
                <span class="mt-0.5 block text-xs text-neutral-500">{gettext("Receive app mentions and send replies in Slack.")}</span>
              </span>
            </button>
          </div>

          <div :if={@integration_setup_provider in ["feishu", "slack"]} class="space-y-3">
            <section
              :if={@integration_setup_provider == "feishu"}
              class="overflow-hidden rounded-lg border border-neutral-200 bg-white"
              aria-labelledby="feishu-integration-title"
            >
          <div class="flex flex-col gap-3 px-4 py-3.5 sm:flex-row sm:items-center sm:justify-between">
            <div class="flex min-w-0 items-center gap-3">
              <span class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md border border-neutral-200 bg-white">
                <.brand_logo name="feishu" class="h-5 w-5" />
              </span>
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <h3 id="feishu-integration-title" class="text-sm font-semibold text-neutral-900">{gettext("Feishu")}</h3>
                  <.badge color={feishu_route_badge_color(@feishu_route_state.status)}>
                    {feishu_route_badge_text(@feishu_route_state.status)}
                  </.badge>
                </div>
                <p class="mt-0.5 text-xs text-neutral-500">{gettext("Receive group mentions and route them to this Agent Swarm.")}</p>
              </div>
            </div>
            <div :if={@feishu_connects != []} class="flex shrink-0 flex-wrap items-center gap-1">
              <.button size="sm" type="button" phx-click="run-feishu-checks">{gettext("Run checks")}</.button>
              <.button
                :if={@can_manage_project}
                size="sm"
                type="button"
                phx-click="send-feishu-test-message"
                data-confirm={gettext("This sends a real test message that wakes the bot's LLM (billable). Continue?")}
              >
                {gettext("Send test message")}
              </.button>
            </div>
          </div>

          <div class="border-t border-neutral-200 px-4 py-4">
            <div
              :if={@can_manage_project and @feishu_bot_bindings == []}
              class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
            >
              <div>
                <p class="text-sm font-medium text-neutral-800">{gettext("No org Feishu app has bot enabled yet.")}</p>
                <p class="mt-1 max-w-2xl text-xs text-neutral-500">
                  {gettext("Add a Feishu app at the organization level and enable it for group bot messaging. Credentials are reused automatically.")}
                </p>
              </div>
              <.button navigate={~p"/orgs/#{@current_org.slug}/settings/feishu"} variant="primary" size="sm" class="shrink-0">
                {gettext("Configure Feishu app")}
              </.button>
            </div>

            <.form
              :if={@can_manage_project and @feishu_bot_bindings != []}
              for={@feishu_connect_form}
              phx-submit="create_feishu_connect"
              id="create-feishu-connect-form"
            >
              <p :if={@feishu_connects == []} class="mb-3 text-sm font-medium text-neutral-800">{gettext("No Feishu connects yet")}</p>
              <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                <.select
                  field={@feishu_connect_form[:app_id]}
                  label={gettext("Feishu app")}
                  options={feishu_binding_options(@feishu_bot_bindings)}
                />
                <.input
                  field={@feishu_connect_form[:app_name]}
                  label={gettext("Connect name")}
                  placeholder="Bridge"
                  hint={gettext("Shown in Salix. Defaults to the app's display name.")}
                />
              </div>
              <div class="mt-3 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                <p class="max-w-2xl text-xs text-neutral-500">
                  {gettext("Current limitation: one Feishu app can be connected to one Agent Swarm. If this app is already used elsewhere, delete that connect or choose another app.")}
                </p>
                <.button :if={@can_manage_project} size="sm" variant="primary" type="submit" class="shrink-0">
                  <.icon name="plus" class="h-4 w-4" /> {gettext("Create connect")}
                </.button>
              </div>
            </.form>

          <.table :if={@feishu_connects != []} id="feishu-connects" rows={@feishu_connects}>
            <:col :let={connect} label={gettext("Connect")}>
              <span class="font-mono text-xs text-neutral-700">{connect["connect_id"]}</span>
              <div class="mt-1 flex items-center gap-2">
                <.status_pill status={connect["status"] || "configured"} />
                <.badge :if={connect["disabled_at"]} color="red">{gettext("disabled")}</.badge>
              </div>
            </:col>
            <:col :let={connect} label={gettext("Webhook URL")}>
              <pre class="max-w-xl overflow-x-auto rounded-md border border-neutral-200 bg-neutral-50 px-2 py-1 font-mono text-xs text-neutral-700">{display_webhook_url(connect)}</pre>
            </:col>
            <:col :let={connect} label={gettext("Credentials")}>
              <div class="flex flex-wrap gap-1">
                <.badge color={if connect["app_secret_configured"], do: "green", else: "red"}>
                  {gettext("secret")} {configured_text(connect["app_secret_configured"])}
                </.badge>
                <.badge color={if connect["verification_token_configured"], do: "green", else: "red"}>
                  {gettext("verification")} {configured_text(connect["verification_token_configured"])}
                </.badge>
                <.badge color={if connect["encrypt_key_configured"], do: "green", else: "neutral"}>
                  {gettext("encryption")} {configured_text(connect["encrypt_key_configured"])}
                </.badge>
              </div>
            </:col>
            <:col :let={connect} label={gettext("Updated")}>
              <span class="text-xs text-neutral-500">{format_unix(connect["updated_at"])}</span>
            </:col>
            <:action :let={connect}>
              <.button
                :if={@can_manage_project && is_nil(connect["disabled_at"])}
                size="sm"
                phx-click="disable_connect"
                phx-value-id={connect["connect_id"]}
              >
                {gettext("Disable")}
              </.button>
              <.button
                :if={@can_manage_project && connect["disabled_at"]}
                size="sm"
                variant="primary"
                phx-click="enable_connect"
                phx-value-id={connect["connect_id"]}
              >
                {gettext("Enable")}
              </.button>
              <.button
                :if={@can_manage_project}
                size="sm"
                variant="danger"
                phx-click="delete_connect"
                phx-value-id={connect["connect_id"]}
                data-confirm={gettext("Delete this connect? This releases the provider app reservation.")}
              >
                {gettext("Delete")}
              </.button>
            </:action>
          </.table>
          <.run_checks_panel :if={@feishu_checks} checks={@feishu_checks} class="mt-4" />
          <details class="mt-4 border-t border-neutral-200 pt-3">
            <summary class="cursor-pointer select-none text-xs font-medium text-neutral-600 hover:text-neutral-900">
              {gettext("Message route details")}
            </summary>
            <div class="pt-3">
              <p class="text-xs text-neutral-500">
                {gettext("Feishu group messages for this connect route to this Agent Swarm. Feishu callback HTTP 200 only proves the provider reached Salix; the message route and selected Router determine whether the bot replies.")}
              </p>
              <dl class="mt-3 grid grid-cols-1 gap-3 text-xs sm:grid-cols-3">
                <div>
                  <dt class="text-neutral-500">{gettext("Agent Swarm")}</dt>
                  <dd class="mt-1 text-neutral-800">{@project.name}</dd>
                </div>
                <div>
                  <dt class="text-neutral-500">{gettext("Router")}</dt>
                  <dd :if={@feishu_route_state.router_agent} class="mt-1 text-neutral-800">
                    {@feishu_route_state.router_agent.salix["name"] || @feishu_route_state.router_agent.salix_agent_id}
                  </dd>
                  <dd :if={is_nil(@feishu_route_state.router_agent)} class="mt-1 text-amber-700">{gettext("No group router selected")}</dd>
                </div>
                <div>
                  <dt class="text-neutral-500">{gettext("Connect")}</dt>
                  <dd class="mt-1 font-mono text-neutral-800">
                    {if @feishu_route_state.connect, do: @feishu_route_state.connect["connect_id"], else: gettext("Not created yet")}
                  </dd>
                </div>
              </dl>
              <p class="mt-3 text-xs text-neutral-500">{feishu_route_next_action(@feishu_route_state.status)}</p>
            </div>
          </details>
          </div>
        </section>

        <section
          :if={@integration_setup_provider == "slack"}
          class="overflow-hidden rounded-lg border border-neutral-200 bg-white"
          aria-labelledby="slack-integration-title"
        >
          <div class="flex flex-col gap-3 px-4 py-3.5 sm:flex-row sm:items-center sm:justify-between">
            <div class="flex min-w-0 items-center gap-3">
              <span class="flex h-9 w-9 shrink-0 items-center justify-center rounded-md border border-neutral-200 bg-white">
                <.brand_logo name="slack" class="h-5 w-5" />
              </span>
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <h3 id="slack-integration-title" class="text-sm font-semibold text-neutral-900">{gettext("Slack")}</h3>
                  <.badge color={if @slack_connects == [], do: "neutral", else: "green"}>
                    {if @slack_connects == [], do: gettext("not connected"), else: gettext("connected")}
                  </.badge>
                </div>
                <p class="mt-0.5 text-xs text-neutral-500">{gettext("Receive app mentions and send replies in Slack.")}</p>
              </div>
            </div>
          </div>

          <div class="border-t border-neutral-200 px-4 py-4">
            <details open>
              <summary class="cursor-pointer select-none text-sm font-medium text-neutral-800">
                {if @slack_connects == [], do: gettext("Set up Slack"), else: gettext("Add another Slack connect")}
              </summary>
              <div class="mt-4 space-y-5">
                <div :if={@slack_manifest} class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                  <div>
                    <p class="text-xs font-semibold text-neutral-700">{gettext("Step 1 · Create the Slack app from this manifest")}</p>
                    <p class="mt-1 max-w-2xl text-xs text-neutral-500">
                      {gettext("Open Slack with the app settings pre-filled, then choose a workspace and confirm.")}
                    </p>
                  </div>
                  <a
                    :if={@slack_manifest.create_url}
                    href={@slack_manifest.create_url}
                    target="_blank"
                    rel="noreferrer"
                    class="inline-flex shrink-0 items-center justify-center whitespace-nowrap rounded-md border border-brand-600 bg-brand-600 px-2.5 py-1.5 text-xs font-medium text-white hover:bg-brand-700"
                  >
                    {gettext("Create app on Slack")}
                  </a>
                </div>

                <details :if={@slack_manifest} class="rounded-md border border-neutral-200 bg-neutral-50/70 px-3 py-2">
                  <summary class="cursor-pointer select-none text-xs font-medium text-neutral-600 hover:text-neutral-900">
                    {gettext("View manifest and callback URLs")}
                  </summary>
                  <div class="mt-3">
                    <div class="flex justify-end">
                      <button
                        type="button"
                        id="copy-slack-manifest"
                        phx-hook="CopyToClipboard"
                        data-copy-target="#slack-manifest-json"
                        class="whitespace-nowrap rounded-md border border-neutral-300 bg-white px-2 py-1 text-xs font-medium text-neutral-700 hover:bg-neutral-100"
                      >
                        {gettext("Copy manifest")}
                      </button>
                    </div>
                    <pre
                      id="slack-manifest-json"
                      class="mt-2 max-h-64 overflow-auto rounded-md border border-neutral-200 bg-white px-3 py-2 font-mono text-xs leading-relaxed text-neutral-800"
                    >{@slack_manifest.json}</pre>
                    <dl class="mt-3 grid grid-cols-1 gap-2 text-xs text-neutral-500">
                      <div class="sm:flex sm:gap-2">
                        <dt class="w-28 shrink-0">{gettext("Redirect URL")}</dt>
                        <dd class="break-all font-mono text-neutral-700">{@slack_manifest.redirect_url}</dd>
                      </div>
                      <div class="sm:flex sm:gap-2">
                        <dt class="w-28 shrink-0">{gettext("Events URL")}</dt>
                        <dd class="break-all font-mono text-neutral-700">{@slack_manifest.events_url}</dd>
                      </div>
                      <div class="sm:flex sm:gap-2">
                        <dt class="w-28 shrink-0">{gettext("Interactions URL")}</dt>
                        <dd class="break-all font-mono text-neutral-700">{@slack_manifest.interactions_url}</dd>
                      </div>
                    </dl>
                  </div>
                </details>

                <div>
                  <p class="mb-3 text-xs font-semibold text-neutral-700">{gettext("Step 2 · Paste the created app's credentials")}</p>
                  <.form
                    for={@slack_connect_form}
                    phx-change="slack_form_changed"
                    phx-submit="create_slack_connect"
                    id="create-slack-connect-form"
                  >
                    <div :if={@can_manage_project} class="grid grid-cols-1 gap-4 md:grid-cols-2">
                      <.input field={@slack_connect_form[:app_name]} label={gettext("App name")} placeholder="Comma" />
                      <.input field={@slack_connect_form[:app_id]} label={gettext("App ID")} placeholder="Axxxx" required />
                      <.input field={@slack_connect_form[:client_id]} label={gettext("Client ID")} required />
                      <.input field={@slack_connect_form[:client_secret]} type="password" label={gettext("Client secret")} required />
                      <.input field={@slack_connect_form[:signing_secret]} type="password" label={gettext("Signing secret")} required />
                      <.select
                        field={@slack_connect_form[:inbound_agent_id]}
                        label={gettext("Inbound agent")}
                        options={slack_inbound_agent_options(@integration_agents)}
                      />
                    </div>
                    <div :if={@can_manage_project} class="mt-4 flex items-center justify-between gap-3">
                      <p :if={@slack_connects == []} class="text-xs text-neutral-500">{gettext("No Slack connects yet")}</p>
                      <.button size="sm" variant="primary" type="submit" class="shrink-0">
                        <.icon name="plus" class="h-4 w-4" /> {gettext("Create connect")}
                      </.button>
                    </div>
                  </.form>
                </div>
              </div>
            </details>

          <.table :if={@slack_connects != []} id="slack-connects" rows={@slack_connects}>
            <:col :let={connect} label={gettext("Connect")}>
              <span class="font-mono text-xs text-neutral-700">{connect["connect_id"]}</span>
              <div class="mt-1 flex items-center gap-2">
                <.badge :if={slack_oauth_completed?(connect)} color="green">{gettext("installed")}</.badge>
                <.badge :if={!slack_oauth_completed?(connect)} color="amber">{gettext("awaiting install")}</.badge>
                <.badge :if={connect["disabled_at"]} color="red">{gettext("disabled")}</.badge>
              </div>
            </:col>
            <:col :let={connect} label={gettext("Workspace")}>
              <span class="text-neutral-700">{connect["workspace_name"] || connect["workspace_id"] || "—"}</span>
            </:col>
            <:col :let={connect} label={gettext("Inbound agent")}>
              <span class="text-xs text-neutral-700">{slack_bound_agent_label(connect, @integration_agents)}</span>
            </:col>
            <:col :let={connect} label={gettext("Install")}>
              <a
                :if={connect["oauth_url"] not in [nil, ""]}
                href={connect["oauth_url"]}
                target="_blank"
                rel="noreferrer"
                class="text-brand-600 underline"
              >
                {gettext("Open install URL")}
              </a>
              <span :if={connect["oauth_url"] in [nil, ""]} class="text-neutral-400">—</span>
            </:col>
            <:col :let={connect} label={gettext("Credentials")}>
              <div class="flex flex-wrap gap-1">
                <.badge color={if connect["client_secret_configured"], do: "green", else: "red"}>
                  {gettext("client")} {configured_text(connect["client_secret_configured"])}
                </.badge>
                <.badge color={if connect["signing_secret_configured"], do: "green", else: "red"}>
                  {gettext("signing")} {configured_text(connect["signing_secret_configured"])}
                </.badge>
              </div>
            </:col>
            <:col :let={connect} label={gettext("Updated")}>
              <span class="text-xs text-neutral-500">{format_unix(connect["updated_at"])}</span>
            </:col>
            <:action :let={connect}>
              <.button
                :if={@can_manage_project}
                size="sm"
                phx-click="run-slack-calendar-checks"
                phx-value-id={connect["connect_id"]}
              >
                {gettext("Run checks")}
              </.button>
              <.button
                :if={@can_manage_project && is_nil(connect["disabled_at"])}
                size="sm"
                phx-click="disable_connect"
                phx-value-id={connect["connect_id"]}
              >
                {gettext("Disable")}
              </.button>
              <.button
                :if={@can_manage_project && connect["disabled_at"]}
                size="sm"
                variant="primary"
                phx-click="enable_connect"
                phx-value-id={connect["connect_id"]}
              >
                {gettext("Enable")}
              </.button>
              <.button
                :if={@can_manage_project}
                size="sm"
                variant="danger"
                phx-click="delete_connect"
                phx-value-id={connect["connect_id"]}
                data-confirm={gettext("Delete this connect? This releases the provider app reservation.")}
              >
                {gettext("Delete")}
              </.button>
            </:action>
          </.table>
          <.run_checks_panel :if={@slack_checks} checks={@slack_checks} class="mt-4" />
          </div>
        </section>
          </div>
        </.side_panel>
      </div>
      <section
        :if={not @panel_only and Map.has_key?(assigns, :signal_status) and is_nil(@signal_status)}
        id="project-signal"
        class="rounded-lg border border-neutral-200 p-4"
      >
        <h3 class="text-sm font-semibold text-neutral-800">{gettext("Signal")}</h3>
        <p id="project-signal-unavailable" class="mt-1 text-xs text-neutral-500">
          {gettext("Signal is unavailable right now.")}
        </p>
      </section>
      <section
        :if={not @panel_only and assigns[:signal_status]}
        id="project-signal"
        class="rounded-lg border border-neutral-200 p-4"
      >
        <div class="flex items-start justify-between gap-3">
          <div>
            <h3 class="text-sm font-semibold text-neutral-800">{gettext("Signal")}</h3>
            <p class="mt-1 max-w-2xl text-xs text-neutral-500">
              {gettext("People and Signal groups connect by sending a one-time code on Signal to %{number}. Signal messages and call audio are decrypted on Comma servers so the agents can answer.",
                number: get_in(@signal_status, ["account", "e164"]) || gettext("the Signal number")
              )}
            </p>
          </div>
          <.button
            :if={@can_manage_project && get_in(@signal_status, ["account", "e164"])}
            id="signal-new-code"
            type="button"
            size="sm"
            variant="primary"
            phx-click="signal-new-code"
          >
            {gettext("New code")}
          </.button>
        </div>
        <div
          :if={assigns[:signal_claim]}
          id="signal-code"
          class="mt-3 flex items-center justify-between gap-2 rounded-md border border-amber-200 bg-amber-50 px-3 py-2"
        >
          <div class="min-w-0">
            <p class="text-xs font-medium text-amber-800">
              {gettext("Send this message on Signal to %{number} within 10 minutes. It is shown once.",
                number: @signal_claim["number"]
              )}
            </p>
            <p class="font-mono text-sm text-amber-900">{@signal_claim["command"]}</p>
          </div>
          <.button size="sm" phx-click="signal-dismiss-code">{gettext("Done")}</.button>
        </div>
        <ul :if={@signal_status["bindings"] != []} class="mt-3 divide-y divide-neutral-100 text-sm">
          <li :for={binding <- @signal_status["bindings"]} class="flex items-center justify-between py-2">
            <span>
              {binding["display_name"] ||
                if(binding["kind"] == "group", do: gettext("Signal group"), else: gettext("Person"))}
              <span class="ml-2 font-mono text-xs text-neutral-500">{binding["number"]}</span>
            </span>
            <.button
              :if={@can_manage_project}
              size="sm"
              variant="danger"
              phx-click="signal-remove-binding"
              phx-value-id={binding["binding_id"]}
              data-confirm={gettext("Disconnect this Signal chat? A call in progress ends now.")}
            >
              {gettext("Disconnect")}
            </.button>
          </li>
        </ul>
        <p :if={@signal_status["bindings"] == []} class="mt-3 text-xs text-neutral-500">
          {gettext("No Signal chats are connected yet.")}
        </p>
      </section>
    </div>
    """
  end

  defp integration_setup_panel(assigns) do
    assigns
    |> assign(:panel_only, true)
    |> integrations_tab()
  end

  defp connections_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <p class="text-xs text-neutral-500">
        {gettext("Connect third-party accounts for")}
        <span class="font-medium text-neutral-700">{@project.name}</span>.
      </p>

      <.empty_state
        :if={@oauth_connections_error == :group_not_ready}
        icon="inbox"
        title={gettext("Agent Swarm is still preparing")}
        description={gettext("The runtime is not ready yet. Retry shortly.")}
      />

      <.empty_state
        :if={oauth_runtime_unavailable?(@oauth_connections_error, @oauth_available_error)}
        icon="inbox"
        title={gettext("Salix unavailable")}
        description={gettext("The runtime is unavailable right now. Retry shortly.")}
      />

      <div
        :if={is_nil(@oauth_connections_error) and is_nil(@oauth_available_error)}
        class="space-y-6"
      >
        <.card>
          <:title>{gettext("Connected accounts")}</:title>

          <.empty_state
            :if={@oauth_connections == []}
            icon="plug"
            title={gettext("No connected accounts yet")}
            description={gettext("Connect an account below to let this Agent Swarm's agents act on your behalf.")}
          />

          <.table :if={@oauth_connections != []} id="oauth-connections" rows={@oauth_connections}>
            <:col :let={connection} label={gettext("Platform")}>
              <span class="font-medium text-neutral-800">
                {oauth_provider_label(connection["provider"])}
              </span>
              <div class="mt-1">
                <.badge color="neutral">{connection["alias"]}</.badge>
              </div>
            </:col>
            <:col :let={connection} label={gettext("Account")}>
              <span class="text-neutral-700">{oauth_account_name(connection)}</span>
            </:col>
            <:col :let={connection} label={gettext("Scopes")}>
              <span class="text-xs text-neutral-500">{oauth_scopes(connection)}</span>
            </:col>
            <:col :let={connection} label={gettext("Status")}>
              <.status_pill status={connection["status"] || "active"} />
            </:col>
            <:action :let={connection}>
              <.button
                :if={@can_manage_project && oauth_connection_enabled?(connection)}
                size="sm"
                variant="secondary"
                phx-click="disable_oauth"
                phx-value-id={connection["binding_id"]}
              >
                {gettext("Disable")}
              </.button>
              <.button
                :if={@can_manage_project && !oauth_connection_enabled?(connection)}
                size="sm"
                variant="primary"
                phx-click="enable_oauth"
                phx-value-id={connection["binding_id"]}
              >
                {gettext("Enable")}
              </.button>
              <.button
                :if={@can_manage_project}
                size="sm"
                variant="danger"
                phx-click="disconnect_oauth"
                phx-value-id={connection["binding_id"]}
                data-confirm={gettext("Disconnect this account? Agents will lose access to it.")}
              >
                {gettext("Disconnect")}
              </.button>
            </:action>
          </.table>
        </.card>

        <.card>
          <:title>{gettext("Connect an account")}</:title>

          <p class="mb-4 text-xs text-neutral-500">
            {gettext("Supported OAuth platforms appear here. Organization OAuth settings control whether authorization can start.")}
          </p>

          <div :if={@oauth_available == []} data-tour="conn-empty">
            <.empty_state
              icon="plug"
              title={gettext("No OAuth platforms available")}
              description={gettext("No supported OAuth platforms were returned by the runtime. Retry shortly.")}
            />
          </div>

          <div :if={@oauth_available != []} class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <div
              :for={app <- @oauth_available}
              id={"oauth-provider-#{app["provider"]}"}
              class="rounded-md border border-neutral-200 p-4"
            >
              <div class="flex items-center justify-between">
                <span class="font-medium text-neutral-800">
                  {oauth_provider_label(app["provider"])}
                </span>
                <.badge color={if ProjectOAuthConnections.provider_authorization_ready?(app), do: "green", else: "amber"}>
                  {if ProjectOAuthConnections.provider_authorization_ready?(app),
                    do: gettext("ready"),
                    else: gettext("setup required")}
                </.badge>
              </div>

              <.form
                :if={@can_manage_project && ProjectOAuthConnections.provider_authorization_ready?(app)}
                for={@oauth_connect_form}
                id={"connect-oauth-#{app["provider"]}-form"}
                phx-submit="connect_oauth"
                class="mt-3 space-y-3"
              >
                <input type="hidden" name="oauth[provider]" value={app["provider"]} />
                <.input
                  id={"oauth-alias-#{app["provider"]}"}
                  name="oauth[alias]"
                  value=""
                  label={gettext("Label (optional)")}
                  placeholder={oauth_provider_label(app["provider"])}
                />
                <.button type="submit" size="sm" variant="primary">
                  <.icon name="plus" class="h-4 w-4" /> {gettext("Connect")}
                </.button>
              </.form>

              <div :if={@can_manage_project && !ProjectOAuthConnections.provider_authorization_ready?(app)} class="mt-3">
                <.button
                  :if={@current_org_role in ["owner", "admin"]}
                  size="sm"
                  navigate={~p"/orgs/#{@current_org.slug}/settings/oauth"}
                >
                  {gettext("Configure in org settings")}
                </.button>
                <p
                  :if={@current_org_role not in ["owner", "admin"]}
                  class="text-xs text-neutral-500"
                >
                  {gettext("An organization admin must configure this OAuth app before accounts can be connected.")}
                </p>
              </div>

              <p :if={!@can_manage_project} class="mt-2 text-xs text-neutral-400">
                {gettext("Only Agent Swarm admins can connect accounts.")}
              </p>
            </div>
          </div>
        </.card>
      </div>

      {composio_connections(assigns)}
    </div>
    """
  end

  # The Composio integrations section: connect toolkit accounts (Gmail, Notion,
  # …) through Composio-hosted Connect Links, the same path first-run
  # onboarding uses, now reachable anytime from the swarm. Readiness is org-wide
  # (one Composio API key), so it renders independently of the managed-OAuth
  # runtime state above.
  defp composio_connections(assigns) do
    ~H"""
    <.card>
      <:title>{gettext("App connections via Composio")}</:title>

      <p class="mb-4 text-xs text-neutral-500">
        {gettext("Connect toolkits through Composio so this Agent Swarm's agents can act in them. Managed once for your organization with a single Composio API key.")}
      </p>

      <div
        :if={@composio_unavailable}
        class="mb-4 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-700"
      >
        {gettext("The runtime is unreachable right now — connection status may be incomplete. Retry shortly.")}
      </div>

      <div class="divide-y divide-neutral-100 rounded-lg border border-neutral-200">
        <div
          :for={row <- composio_toolkit_rows(@composio_connections, @composio_configured, @can_manage_project)}
          id={"composio-toolkit-#{row.toolkit}"}
          class="flex items-center justify-between gap-3 px-4 py-3"
        >
          <div class="flex min-w-0 items-center gap-3">
            <.brand_logo name={row.toolkit} class="h-5 w-5" />
            <div class="min-w-0">
              <div class="text-sm font-medium text-neutral-900">
                {composio_toolkit_label(row.toolkit)}
              </div>
              <div class="truncate text-xs text-neutral-500">
                {composio_toolkit_description(row.toolkit)}
              </div>
            </div>
          </div>

          <div class="flex shrink-0 items-center gap-2">
            <.status_pill :if={row.state == :connected} status="connected" label={gettext("Connected")} />
            <.button
              :if={row.state == :connected && @can_manage_project}
              size="sm"
              variant="danger"
              phx-click="disconnect_composio"
              phx-value-id={composio_account_id(row.connection)}
              data-confirm={gettext("Disconnect this account? Agents will lose access to it.")}
            >
              {gettext("Disconnect")}
            </.button>
            <.button
              :if={row.state == :connectable}
              size="sm"
              variant="secondary"
              phx-click="connect_composio"
              phx-value-toolkit={row.toolkit}
            >
              {gettext("Connect")}
            </.button>
            <span :if={row.state == :ask_admin} class="text-xs text-neutral-400">
              {gettext("Ask a swarm admin")}
            </span>
            <.button :if={row.state == :unconfigured} size="sm" variant="secondary" disabled>
              {gettext("Connect")}
            </.button>
          </div>
        </div>
      </div>

      <div :if={not @composio_configured} class="mt-3 text-xs text-neutral-400">
        {gettext("Connections need a Composio API key configured once for your organization.")}
        <.link
          :if={@current_org_role in ["owner", "admin"]}
          navigate={~p"/orgs/#{@current_org.slug}/settings/composio"}
          class="text-brand-600 hover:underline"
        >
          {gettext("Configure in Settings")}
        </.link>
        <span :if={@current_org_role not in ["owner", "admin"]}>
          {gettext("An organization admin must configure it before accounts can be connected.")}
        </span>
      </div>
    </.card>
    """
  end

  defp plugin_detail_page(assigns) do
    ~H"""
    <div id="project-plugin-detail" class="space-y-6">
      <.empty_state
        :if={is_nil(@project_plugin_detail)}
        icon="plug"
        title={gettext("Plugin not found")}
        description={gettext("This plugin is not available to the Agent Swarm.")}
      >
        <:actions>
          <.button navigate={~p"/orgs/#{@current_org.slug}/projects/#{@project.id}/plugins"}>
            {gettext("Back to plugins")}
          </.button>
        </:actions>
      </.empty_state>

      <%= if plugin = @project_plugin_detail do %>
        <div>
          <.link
            navigate={~p"/orgs/#{@current_org.slug}/projects/#{@project.id}/plugins"}
            class="inline-flex items-center gap-1 text-xs font-medium text-neutral-500 hover:text-neutral-800"
          >
            <.icon name="arrow-left" class="h-3.5 w-3.5" /> {gettext("Plugins")}
          </.link>
          <div class="mt-3 flex items-start justify-between gap-4">
            <div>
              <div class="flex flex-wrap items-center gap-2">
                <h1 class="text-xl font-semibold tracking-tight text-neutral-900">
                  {plugin["name"] || plugin["plugin_id"]}
                </h1>
                <PluginComponents.plugin_state_control
                  definition={plugin}
                  enablement_by_id={@project_plugin_enablement_by_id}
                  can_toggle={
                    @can_manage_project &&
                      (plugin["plugin_id"] != "android-control" || @android_control.entitled)
                  }
                  enable_event="enable_plugin"
                  disable_event="disable_plugin"
                />
              </div>
              <p class="mt-1 max-w-3xl text-sm leading-6 text-neutral-600">
                {plugin["description"] || gettext("No description")}
              </p>
              <div class="mt-3 flex flex-wrap items-center gap-2">
                <.badge color="neutral">{plugin["owner_scope"]}</.badge>
              </div>
            </div>
            <.button
              :if={@can_manage_project && editable_group_plugin?(plugin)}
              size="sm"
              phx-click="edit_plugin"
              phx-value-id={plugin["plugin_id"]}
            >
              {gettext("Edit")}
            </.button>
          </div>
        </div>

        <section
          :if={plugin["plugin_id"] == "android-control"}
          id="android-plugin-status"
          class="rounded-xl border border-neutral-200 p-4"
        >
          <div class="grid gap-3 sm:grid-cols-2">
            <div>
              <div class="text-xs font-medium text-neutral-500">{gettext("Admission")}</div>
              <.badge color={if @android_control.entitled, do: "green", else: "neutral"}>
                {cond do
                  @android_control_error -> gettext("Enablement unavailable")
                  @android_control.entitled -> gettext("Available to this organization")
                  true -> gettext("Not available for this organization")
                end}
              </.badge>
            </div>
            <div>
              <div class="text-xs font-medium text-neutral-500">{gettext("Agent Swarm status")}</div>
              <.badge color={if get_in(@project_plugin_enablement_by_id, ["android-control", "enabled"]) == true, do: "green", else: "neutral"}>
                {if get_in(@project_plugin_enablement_by_id, ["android-control", "enabled"]) == true,
                  do: gettext("Enabled for this Agent Swarm"),
                  else: gettext("Not enabled for this Agent Swarm")}
              </.badge>
            </div>
          </div>
          <p :if={@android_control_error} class="mt-3 text-sm text-neutral-600">
            {gettext("Android admission status is unavailable. Try again shortly.")}
          </p>
          <p
            :if={!@android_control_error && !@android_control.entitled}
            class="mt-3 text-sm text-neutral-600"
          >
            {gettext("Android connector access is not enabled for your organization. Contact your platform administrator.")}
          </p>
          <div
            :if={!@android_control_error && @android_control.entitled}
            class="mt-4 flex flex-wrap gap-2"
          >
            <.button
              :if={@can_manage_project && get_in(@project_plugin_enablement_by_id, ["android-control", "enabled"]) != true}
              phx-click="enable_plugin"
              phx-value-id="android-control"
              variant="primary"
              size="sm"
            >
              {gettext("Enable for this Agent Swarm")}
            </.button>
            <.button
              :if={get_in(@project_plugin_enablement_by_id, ["android-control", "enabled"]) == true}
              navigate={~p"/orgs/#{@current_org.slug}/projects/#{@project.id}/devices"}
              variant="secondary"
              size="sm"
            >
              {gettext("Go to Devices")}
            </.button>
          </div>
        </section>

        <section
          :if={plugin_integration_setup?(plugin)}
          id="plugin-components"
          class="space-y-5"
        >
          <div :if={plugin_dependency_paths(plugin) != []} class="space-y-3">
            <div class="text-[11px] font-semibold uppercase tracking-wide text-neutral-500">
              {gettext("MCP servers")}
            </div>
            <div
              :for={path <- plugin_dependency_paths(plugin)}
              class="space-y-0"
            >
              <.plugin_mcp_card
                mcp={path.mcp}
                connections={path.connections}
                plugin_id={plugin["plugin_id"]}
                default_connection={get_in(plugin, ["setup_status", "default_connection"])}
                can_manage={@can_manage_project}
              />
            </div>
          </div>

          <div :if={plugin_standalone_connections(plugin) != []} class="space-y-3">
            <.plugin_connection_card
              :for={connection <- plugin_standalone_connections(plugin)}
              connection={connection}
              dependent_mcps={[]}
              plugin_id={plugin["plugin_id"]}
              default_connection={get_in(plugin, ["setup_status", "default_connection"])}
              can_manage={@can_manage_project}
            />
          </div>
        </section>

        <PluginComponents.plugin_editor_drawer
          :if={project_plugin_editor_panel?(@project_plugin_panel)}
          id="project-plugin-editor"
          panel={@project_plugin_panel}
          form={@project_plugin_form}
          submit_event="update_group_plugin"
          close_event="close_plugin_panel"
          error={@project_plugin_panel_error}
        />
      <% end %>
    </div>
    """
  end

  defp plugin_integration_setup?(%{"setup_status" => %{"type" => "integration"}}), do: true
  defp plugin_integration_setup?(_plugin), do: false

  defp plugins_tab(assigns) do
    ~H"""
    <% product_plugins = Enum.filter(@project_plugin_definitions, &Plugins.product_plugin?/1) %>
    <% enabled_count =
      enabled_plugin_count(product_plugins, @project_plugin_enablement_by_id) %>
    <% disabled_count =
      disabled_plugin_count(product_plugins, @project_plugin_enablement_by_id) %>
    <% visible_plugins =
      filtered_project_plugins(
        product_plugins,
        @project_plugin_enablement_by_id,
        @project_plugin_query,
        @project_plugin_state_filter,
        @project_plugin_source_filter
      ) %>
    <% visible_plugins = sort_project_plugins(visible_plugins) %>
    <div class="space-y-5">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <p class="text-sm text-neutral-600">
            {gettext("Choose which products this Agent Swarm can use.")}
          </p>
          <p class="mt-1 text-xs text-neutral-500">
            {gettext("%{enabled} enabled · %{disabled} disabled",
              enabled: enabled_count,
              disabled: disabled_count
            )}
          </p>
        </div>
        <.button
          :if={@can_manage_project}
          variant="primary"
          phx-click="new_project_plugin"
        >
          <.icon name="plus" class="h-3.5 w-3.5" />
          {gettext("New project plugin")}
        </.button>
      </div>

      <.empty_state
        :if={@project_plugins_error == :group_not_ready}
        icon="plug"
        title={gettext("Agent Swarm is still preparing")}
        description={gettext("The runtime group is not ready yet. Retry shortly.")}
      >
        <:actions>
          <.button phx-click="retry_plugins">{gettext("Retry")}</.button>
        </:actions>
      </.empty_state>

      <.empty_state
        :if={@project_plugins_error && @project_plugins_error != :group_not_ready}
        icon="plug"
        title={gettext("Plugins unavailable")}
        description={plugin_error_message(@project_plugins_error)}
      >
        <:actions>
          <.button phx-click="retry_plugins">{gettext("Retry")}</.button>
        </:actions>
      </.empty_state>

      <div :if={is_nil(@project_plugins_error)} class="space-y-5">
        <div class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
          <form
            id="project-plugin-filter"
            phx-change="filter_project_plugins"
            class="flex min-w-0 flex-1 flex-col gap-2 sm:flex-row"
          >
            <div class="relative min-w-0 flex-1 sm:max-w-sm">
              <.icon name="search" variant="outlined" class="pointer-events-none absolute left-2.5 top-2 h-4 w-4 text-neutral-400" />
              <input
                type="search"
                name="query"
                value={@project_plugin_query}
                phx-debounce="200"
                placeholder={gettext("Search plugins")}
                aria-label={gettext("Search plugins")}
                class="h-8 w-full rounded-md border border-neutral-300 bg-white pl-8 pr-3 text-sm text-neutral-900 placeholder:text-neutral-400 focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </div>
            <select
              name="source"
              aria-label={gettext("Plugin source")}
              class="h-8 rounded-md border border-neutral-300 bg-white px-2.5 text-sm text-neutral-700 focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            >
              <option value="all" selected={@project_plugin_source_filter == "all"}>{gettext("All sources")}</option>
              <option value="system" selected={@project_plugin_source_filter == "system"}>{gettext("System")}</option>
              <option value="tenant" selected={@project_plugin_source_filter == "tenant"}>{gettext("Organization")}</option>
              <option value="group" selected={@project_plugin_source_filter == "group"}>{gettext("Project")}</option>
            </select>
          </form>

          <div
            class="inline-flex w-fit rounded-md bg-neutral-100 p-0.5"
            role="group"
            aria-label={gettext("Plugin state")}
          >
            <button
              :for={{value, label} <- plugin_state_filter_options()}
              type="button"
              aria-pressed={to_string(@project_plugin_state_filter == value)}
              aria-controls="project-plugin-inventory"
              phx-click="set_project_plugin_state"
              phx-value-state={value}
              class={plugin_filter_button_class(@project_plugin_state_filter == value)}
            >
              {label}
            </button>
          </div>
        </div>

        <div id="project-plugin-inventory" class="space-y-5">
        <section :if={visible_plugins != []} class="space-y-2">
          <PluginComponents.plugin_list
            id="project-plugins"
            definitions={visible_plugins}
            enablement_by_id={@project_plugin_enablement_by_id}
            show_state
            can_toggle={@can_manage_project}
            toggle_allowed={fn definition ->
              definition["plugin_id"] != "android-control" || @android_control.entitled
            end}
            editable_scope={if @can_manage_project, do: "group", else: nil}
            details_path={fn definition ->
              ~p"/orgs/#{@current_org.slug}/projects/#{@project.id}/plugins/#{definition["plugin_id"]}"
            end}
          />
        </section>

        <.empty_state
          :if={visible_plugins == []}
          icon="plug"
          title={
            if plugin_filters_clear?(
                 @project_plugin_query,
                 @project_plugin_state_filter,
                 @project_plugin_source_filter
               ),
              do: gettext("No plugins yet"),
              else: gettext("No matching plugins")
          }
          description={
            if plugin_filters_clear?(
                 @project_plugin_query,
                 @project_plugin_state_filter,
                 @project_plugin_source_filter
               ),
              do: gettext("Create a project plugin or add one in the organization catalog."),
              else: gettext("Try a different search or clear the filters.")
          }
        >
          <:actions :if={not plugin_filters_clear?(
            @project_plugin_query,
            @project_plugin_state_filter,
            @project_plugin_source_filter
          )}>
            <.button phx-click="clear_plugin_filters">{gettext("Clear filters")}</.button>
          </:actions>
        </.empty_state>
        </div>
      </div>

      <PluginComponents.plugin_editor_drawer
        :if={project_plugin_editor_panel?(@project_plugin_panel)}
        id="project-plugin-editor"
        panel={@project_plugin_panel}
        form={@project_plugin_form}
        submit_event={if @project_plugin_panel.mode == :edit, do: "update_group_plugin", else: "create_group_plugin"}
        close_event="close_plugin_panel"
        error={@project_plugin_panel_error}
      />

    </div>
    """
  end

  defp project_skills_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <p class="text-sm text-neutral-600">
            {gettext("Reusable playbooks available to this Agent Swarm.")}
          </p>
          <p :if={@project_skill_agent} class="mt-1 text-xs text-neutral-500">
            {gettext("Managed through %{agent}.", agent: display_name(@project_skill_agent))}
          </p>
        </div>
        <div
          :if={@can_manage_project && @project_skill_agent}
          class="flex shrink-0 items-center gap-2"
        >
          <form id="project-skill-upload-form" phx-change="validate_project_skill_upload">
            <label class="inline-flex h-7 cursor-pointer items-center justify-center gap-1.5 rounded-md border border-neutral-300 bg-white px-2.5 text-xs font-medium text-neutral-800 shadow-subtle transition-colors duration-150 hover:bg-neutral-50">
              <.icon name="arrow-up" class="h-3.5 w-3.5" />
              {gettext("Upload")}
              <.live_file_input upload={@uploads.project_skill_file} class="sr-only" />
            </label>
          </form>
          <.button variant="primary" size="sm" phx-click="new_project_skill">
            <.icon name="plus" class="h-3.5 w-3.5" />
            {gettext("New skill")}
          </.button>
        </div>
      </div>

      <div
        :if={@project_skill_error}
        class="rounded-md border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-700"
      >
        {@project_skill_error}
      </div>

      <p :if={@project_miniskill_status == "catalog_over_budget"} role="status">
        {gettext("Miniskill selection exceeds its request budget. Shorten descriptions or disable unused miniskills.")}
      </p>
      <div
        :if={@project_skills_unavailable}
        class="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-700"
      >
        {gettext("The runtime is unreachable right now; skills may be incomplete. Refresh to retry.")}
      </div>

      <.empty_state
        :if={is_nil(@project_skill_agent)}
        icon="document-text"
        title={gettext("No runtime agent yet")}
        description={gettext("Create or bind an Agent before managing Agent Swarm skills.")}
      >
        <:actions>
          <.button
            :if={@can_manage_project}
            variant="primary"
            size="sm"
            navigate={~p"/orgs/#{@current_org.slug}/projects/#{@project.id}/agents"}
          >
            {gettext("Go to Agents")}
          </.button>
        </:actions>
      </.empty_state>

      <section :if={@project_skill_agent}>
        <h2 class="text-sm font-semibold text-neutral-900">{gettext("Custom skills")}</h2>
        <p class="mt-0.5 text-xs text-neutral-500">
          {gettext("Created here, uploaded, or saved by this Agent Swarm from chat.")}
        </p>

        <div
          :if={@project_user_skills == []}
          class="mt-3 rounded-lg bg-neutral-100/70 px-4 py-3 text-xs text-neutral-500"
        >
          {gettext("No custom skills yet.")}
        </div>

        <div :if={@project_user_skills != []} class="mt-3 grid gap-3 sm:grid-cols-2">
          <.project_skill_card
            :for={skill <- @project_user_skills}
            skill={skill}
            can_manage={@can_manage_project}
          />
        </div>
      </section>

      <section
        :if={
          @project_skill_agent &&
            (@project_system_skills != [] || !@project_skills_unavailable)
        }
      >
        <h2 class="text-sm font-semibold text-neutral-900">{gettext("System skills")}</h2>
        <p class="mt-0.5 text-xs text-neutral-500">
          {gettext("Read-only playbooks projected into this Agent Swarm by the runtime and plugins.")}
        </p>

        <div
          :if={@project_system_skills == []}
          class="mt-3 rounded-lg bg-neutral-100/70 px-4 py-3 text-xs text-neutral-500"
        >
          {gettext("No system skills are projected in this environment.")}
        </div>

        <div :if={@project_system_skills != []} class="mt-3 divide-y divide-neutral-100">
          <.project_skill_row :for={skill <- @project_system_skills} skill={skill} />
        </div>
      </section>

      <.modal
        :if={@project_skill_composing}
        id="new-project-skill-modal"
        show
        on_cancel={JS.push("cancel_new_project_skill")}
      >
        <:title>{gettext("New Agent Swarm skill")}</:title>
        <form
          id="new-project-skill-form"
          phx-submit="create_project_skill"
          phx-change="validate_project_skill"
          class="space-y-3"
        >
          <.input
            name="skill[name]"
            value={@project_skill_form["name"]}
            label={gettext("Name")}
            hint={project_skill_slug_hint(@project_skill_form["name"])}
            autofocus
            required
          />
          <.input
            name="skill[description]"
            value={@project_skill_form["description"]}
            label={gettext("When should the Agent Swarm use it?")}
          />
          <.select
            name="skill[activation]"
            id="project-skill-activation"
            value={@project_skill_form["activation"]}
            label={gettext("Activation")}
            options={[{gettext("Regular skill"), "regular"}, {gettext("Miniskill: select for each message"), "per-message"}]}
          />
          <.textarea
            name="skill[instructions]"
            value={@project_skill_form["instructions"]}
            label={gettext("Instructions")}
            rows="6"
          />
        </form>
        <:footer>
          <.button
            variant="ghost"
            size="sm"
            type="button"
            phx-click={
              JS.exec("phx-remove", to: "#new-project-skill-modal")
              |> JS.push("cancel_new_project_skill")
            }
          >
            {gettext("Cancel")}
          </.button>
          <.button variant="primary" size="sm" type="submit" form="new-project-skill-form">
            {gettext("Create skill")}
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@project_skill_viewing}
        id="project-skill-view-modal"
        show
        on_cancel={JS.push("close_project_skill")}
      >
        <:title>{@project_skill_viewing["name"]}</:title>
        <div class="space-y-3">
          <p
            :if={nonblank?(@project_skill_viewing["description"])}
            class="text-sm text-neutral-500"
          >
            {@project_skill_viewing["description"]}
          </p>
          <div class="flex items-center gap-3 text-xs text-neutral-400">
            <span>{project_skill_source_label(@project_skill_viewing["source"])}</span>
            <span class="truncate font-mono">{@project_skill_viewing["location"]}</span>
          </div>
          <div class="max-h-[55vh] overflow-y-auto rounded-lg bg-neutral-50 px-4 py-3">
            <.markdown text={project_skill_body(@project_skill_viewing["content"])} />
          </div>
        </div>
        <:footer>
          <.button
            :if={@can_manage_project && @project_skill_viewing["deletable"] == true}
            variant="danger"
            size="sm"
            phx-click={
              JS.push("delete_project_skill",
                value: %{loc: @project_skill_viewing["location"]}
              )
            }
            data-confirm={gettext("Delete this skill? This Agent Swarm loses it immediately.")}
          >
            <.icon name="trash" class="h-3.5 w-3.5" />
            {gettext("Delete")}
          </.button>
          <span
            :if={@can_manage_project && @project_skill_viewing["deletable"] != true}
            class="text-xs text-neutral-500"
          >
            {project_skill_delete_reason(@project_skill_viewing["delete_reason"])}
          </span>
          <.button
            variant="secondary"
            size="sm"
            phx-click={
              JS.exec("phx-remove", to: "#project-skill-view-modal")
              |> JS.push("close_project_skill")
            }
          >
            {gettext("Close")}
          </.button>
        </:footer>
      </.modal>
    </div>
    """
  end

  attr(:skill, :map, required: true)
  attr(:can_manage, :boolean, default: false)

  defp project_skill_card(assigns) do
    ~H"""
    <div
      id={"project-skill-#{@skill["skill_id"]}"}
      class="rounded-lg border border-neutral-200 bg-white p-4 shadow-subtle"
    >
      <div class="flex items-start justify-between gap-3">
        <button
          type="button"
          phx-click="view_project_skill"
          phx-value-loc={@skill["location"]}
          class="min-w-0 flex-1 text-left"
        >
          <span class="flex min-w-0 items-center gap-2">
            <.icon name="document-text" class="h-4 w-4 shrink-0 text-neutral-400" />
            <span class="truncate text-sm font-medium text-neutral-900">{@skill["name"]}</span>
            <span :if={@skill["activation"] == "per-message"} class="text-xs text-neutral-500">{gettext("Miniskill")}</span>
            <.badge :if={@skill["source"] == "imported"}>{gettext("Imported")}</.badge>
          </span>
          <span
            :if={nonblank?(@skill["description"])}
            class="mt-1 line-clamp-2 block text-xs leading-relaxed text-neutral-500"
          >
            {@skill["description"]}
          </span>
        </button>
        <.button
          :if={@can_manage && @skill["deletable"] == true}
          variant="ghost"
          size="sm"
          phx-click="delete_project_skill"
          phx-value-loc={@skill["location"]}
          data-confirm={gettext("Delete this skill? This Agent Swarm loses it immediately.")}
        >
          <.icon name="trash" class="h-3.5 w-3.5" />
          {gettext("Delete")}
        </.button>
        <span
          :if={@can_manage && @skill["deletable"] != true}
          class="shrink-0 text-xs text-neutral-500"
          title={project_skill_delete_reason(@skill["delete_reason"])}
        >
          {project_skill_delete_reason(@skill["delete_reason"])}
        </span>
      </div>
    </div>
    """
  end

  attr(:skill, :map, required: true)

  defp project_skill_row(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="view_project_skill"
      phx-value-loc={@skill["location"]}
      class="flex w-full items-center gap-3 py-3 text-left"
    >
      <.icon name="document-text" class="h-4 w-4 shrink-0 text-neutral-400" />
      <span class="min-w-0 flex-1">
        <span class="block truncate text-sm font-medium text-neutral-900">{@skill["name"]}</span>
        <span
          :if={nonblank?(@skill["description"])}
          class="block truncate text-xs text-neutral-500"
        >
          {@skill["description"]}
        </span>
      </span>
    </button>
    """
  end

  defp project_skill_slug_hint(name) do
    case Skills.slugify(to_string(name)) do
      "" -> gettext("Shared with this Agent Swarm as SKILL.md.")
      slug -> gettext("Stored as %{location}", location: Skills.runtime_location(slug))
    end
  end

  defp project_skill_body(content) do
    content = String.replace(content || "", "\r\n", "\n")

    case String.split(content, "---", parts: 3) do
      ["", _frontmatter, body] -> String.trim(body)
      _ -> String.trim(content)
    end
  end

  defp project_skill_source_label("system"), do: gettext("System skill")
  defp project_skill_source_label("imported"), do: gettext("Imported skill")
  defp project_skill_source_label(_custom), do: gettext("Custom skill")

  defp project_skill_delete_reason("read_only"), do: gettext("Read-only skill")
  defp project_skill_delete_reason("managed_at_source"), do: gettext("Managed at source")

  defp project_skill_delete_reason(_reason),
    do: gettext("This skill cannot be deleted here.")

  # Reuse bounded Compute/device projections; the panel does not issue a probe
  # or per-runtime RPC while listing. Only the selected panel reads live status.
  defp runtime_auth_rows(projection, environments) do
    compute =
      for row <- projection["workloads"] || [],
          "external." <> provider <- [Map.get(row, :template_key)],
          provider in ~w(codex pi claude) do
        %{
          id: row.id,
          provider: provider,
          status: row.observed_state,
          target: %{"kind" => "compute_workload", "workload_id" => row.id}
        }
      end

    connected =
      environments
      |> Stream.flat_map(fn environment ->
        environment.runtimes
        |> Stream.filter(&(runtime_value(&1, "provider") in ~w(codex pi claude)))
        |> Stream.map(fn runtime ->
          %{
            id: device_runtime_id(runtime),
            provider: runtime_value(runtime, "provider"),
            status: environment.status,
            target: %{
              "kind" => "connected_runtime",
              "device_id" => environment.device_id,
              "runtime_id" => device_runtime_id(runtime)
            }
          }
        end)
      end)

    compute |> Stream.concat(connected) |> Enum.take(50)
  end

  defp environments_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <section id="android-setup" class="space-y-3 rounded-xl border border-neutral-200 p-4">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 class="text-sm font-semibold text-neutral-700">{gettext("Android setup")}</h2>
            <p class="mt-1 text-xs text-neutral-500">
              {gettext("Connect a Linux host with KVM so agents in this Agent Swarm can operate Android.")}
            </p>
          </div>
          <.status_pill
            status={android_environment_status(@environments)}
            label={android_setup_status_label(android_environment_status(@environments))}
          />
        </div>

        <.empty_state
          :if={@android_control_error}
          icon="plug"
          title={gettext("Android status unavailable")}
          description={gettext("Could not load Android admission. Retry shortly.")}
        />

        <div :if={!@android_control_error && !@android_control.entitled} class="rounded-lg bg-neutral-50 p-3 text-sm text-neutral-600">
          {gettext("Android setup is unavailable because this organization has no Android connector entitlement. Contact your platform administrator.")}
        </div>

        <div :if={!@android_control_error && @android_control.entitled} class="space-y-3">
          <div class="flex flex-wrap items-center gap-2 text-xs text-neutral-500">
            <span>{gettext("Allowed profiles: %{profiles}", profiles: Enum.join(@android_control.profiles, ", "))}</span>
            <span>·</span>
            <span>{gettext("One concurrent lease")}</span>
          </div>
          <p class="text-xs text-neutral-500">
            {if android_environment_present?(@environments),
              do: gettext("The Android connector is registered to this Agent Swarm."),
              else: gettext("Ask your platform administrator to register an Android connector for this Agent Swarm.")}
          </p>
        </div>
      </section>

      <section id="project-compute" class="space-y-3 rounded-xl border border-neutral-200 p-4">
        <div>
          <h2 class="text-sm font-semibold text-neutral-700">{gettext("Compute environments")}</h2>
          <p class="mt-1 text-xs text-neutral-500">
            {gettext("Stable project intent and readiness. Infrastructure providers stay hidden from members.")}
          </p>
        </div>
        <.empty_state
          :if={@compute_projection_error}
          icon="plug"
          title={gettext("Compute unavailable")}
          description={gettext("Could not load Compute readiness. Retry shortly.")}
        />
        <.table
          :if={!@compute_projection_error}
          id="compute-environments"
          rows={@compute_projection["environments"]}
          row_id={fn row -> "compute-environment-#{row.id}" end}
        >
          <:col :let={row} label={gettext("Environment")}><span class="font-mono text-xs">{row.id}</span></:col>
          <:col :let={row} label={gettext("Intent")}><.status_pill status={row.desired_state} /></:col>
          <:col :let={row} label={gettext("Readiness")}><.status_pill status={row.observed_state} /></:col>
          <:action :let={row}>
            <.button
              :if={@can_manage_project && row.desired_state == "ready"}
              size="sm"
              variant="ghost"
              phx-click="create_shell_workload"
              phx-value-id={row.id}
              phx-disable-with={gettext("Creating…")}
              data-confirm={gettext("Create a Shell workload in this environment? It has a 512 PID limit, a 2 GiB writable disk limit, and no network access.")}
            >{gettext("Create Shell workload")}</.button>
            <.button
              :if={@can_manage_project && row.desired_state == "ready"}
              size="sm"
              variant="ghost"
              phx-click="compute_environment_intent"
              phx-value-id={row.id}
              phx-value-revision={row.revision}
              phx-value-intent="drain"
            >{gettext("Drain")}</.button>
            <.button
              :if={@can_manage_project && row.desired_state != "revoked"}
              size="sm"
              variant="danger"
              phx-click="compute_environment_intent"
              phx-value-id={row.id}
              phx-value-revision={row.revision}
              phx-value-intent="revoke"
            >{gettext("Revoke")}</.button>
          </:action>
        </.table>
        <p :if={!@compute_projection_error && @compute_projection["environments"] == []} class="text-sm text-neutral-500">
          {gettext("Connect a Compute Node to this project before creating a workload.")}
        </p>
        <.table :if={!@compute_projection_error && @compute_projection["workloads"] != []} id="compute-workloads" rows={@compute_projection["workloads"]}>
          <:col :let={row} label={gettext("Workload")}><span class="font-mono text-xs">{row.id}</span></:col>
          <:col :let={row} label={gettext("Kind")}>{row.kind}</:col>
          <:col :let={row} label={gettext("Status")}><.status_pill status={row.observed_state} /></:col>
        </.table>
      </section>

      <BridgeForTeamsWeb.Dashboard.Components.RuntimeAuth.panel
        rows={runtime_auth_rows(@compute_projection, @environments)}
        can_manage={@can_manage_project}
        selected={@runtime_auth_selected}
        requests={@runtime_auth_requests}
        requests_next_cursor={@runtime_auth_requests_next_cursor}
        endpoint={"/dashboard/orgs/#{@current_org.slug}/projects/#{@project.slug}/runtime-auth"}
        managed_endpoint={"/dashboard/orgs/#{@current_org.slug}/projects/#{@project.slug}/workloads"}
      />

      <div class="flex items-center justify-between">
        <h2 class="text-sm font-semibold text-neutral-700">{gettext("Devices")}</h2>
        <div class="flex flex-wrap items-center justify-end gap-2">
          <.button
            :if={@can_view_operations}
            href={~p"/orgs/#{@current_org.slug}/operations/runners?#{%{project_id: @project.id}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View runners")}
          </.button>
          <.button
            :if={@can_view_operations}
            href={~p"/orgs/#{@current_org.slug}/operations/events?#{%{project_id: @project.id, domain: "device"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View events")}
          </.button>
          <.button :if={@can_manage_project} variant="primary" size="sm" phx-click="new_environment">
            <.icon name="plus" class="h-4 w-4" /> {gettext("Add device")}
          </.button>
        </div>
      </div>

      <p class="text-xs text-neutral-500">
        {gettext("Cloud computer is managed by Comma. Other devices are sourced live from Salix and reflect the connectors registered to this Agent Swarm.")}
      </p>

      <.empty_state
        :if={@environments_error in [:unavailable, :timeout]}
        icon="plug"
        title={gettext("Salix unavailable")}
        description={gettext("Could not load devices from Salix. Retry shortly.")}
      />

      <.table id="environments" rows={device_rows(@project, @environments)} row_id={fn row -> "device-#{row.id}" end}>
        <:col :let={row} label={gettext("Name")}>
          <span class="font-medium text-neutral-800">{row.name || "—"}</span>
          <div :if={row.kind == :cloud} class="mt-0.5 text-xs text-neutral-500">
            {gettext("Fixed · managed by Comma")}
          </div>
        </:col>
        <:col :let={row} label={gettext("Status")}>
          <.status_pill status={row.status} />
          <div :if={android_environment?(row)} class="mt-1 space-y-0.5 text-xs text-neutral-500">
            <div>{gettext("Configured profiles: %{profiles}", profiles: android_profiles(row))}</div>
            <div>{gettext("Default: %{profile}", profile: android_field(row, "default_profile") || "unknown")}</div>
            <div :if={android_field(row, "active_profile") not in [nil, ""]}>{gettext("Current: %{profile}", profile: android_field(row, "active_profile"))}</div>
            <div :if={android_field(row, "target_profile") not in [nil, ""]}>{gettext("Target: %{profile}", profile: android_field(row, "target_profile"))}</div>
            <div :if={android_field(row, "phase") not in [nil, ""]}>{gettext("Phase: %{phase}", phase: android_phase_label(android_field(row, "phase")))}</div>
            <div>
              {gettext("Android: %{status}",
                status: android_capability_status_label(android_field(row, "state"))
              )}
            </div>
            <% {available, capacity} = android_slots(row) %>
            <div :if={is_integer(available) && is_integer(capacity)}>
              {gettext("%{available} of %{capacity} slots available", available: available, capacity: capacity)}
            </div>
          </div>
        </:col>
        <:col :let={row} label={gettext("Agent runtimes")}>
          <span :if={row.kind == :cloud} class="text-neutral-400">—</span>
          <span
            :if={row.kind == :connector && external_agent_runtimes(row) == []}
            class="text-xs text-neutral-400"
          >
            {gettext("No agent runtime")}
          </span>
          <div
            :for={runtime <- external_agent_runtimes(row)}
            id={"agent-runtime-#{row.device_id}-#{device_runtime_id(runtime)}"}
            class="min-w-44 text-xs"
          >
            <span class="font-medium text-neutral-800">{runtime_value(runtime, "provider")}</span>
            <span :if={runtime_value(runtime, "version")} class="ml-1 text-neutral-400">
              {runtime_value(runtime, "version")}
            </span>
          </div>
        </:col>
        <:col :let={row} label={gettext("Boundary")}>
          <.badge :if={row.kind == :cloud} color="brand">{gettext("Managed cloud")}</.badge>
          <span :if={row.kind == :connector} class="text-neutral-400">—</span>
        </:col>
        <:col :let={row} label={gettext("Host / OS")}>
          <span :if={row.kind == :cloud} class="text-neutral-700">{gettext("Comma Cloud")}</span>
          <div :if={row.kind == :cloud} class="text-xs text-neutral-500">{gettext("Managed")}</div>
          <span :if={row.kind == :connector} class="text-neutral-700">{system_host(row.system_info)}</span>
          <div :if={row.kind == :connector} class="text-xs text-neutral-500">{system_os(row.system_info)}</div>
        </:col>
        <:col :let={row} label={gettext("CPU / Memory")}>
          <span :if={row.kind == :cloud} class="text-neutral-500">{gettext("Managed capacity")}</span>
          <span :if={row.kind == :connector} class="text-neutral-700">{system_cpu(row.system_info)}</span>
          <div :if={row.kind == :connector} class="text-xs text-neutral-500">{system_memory(row.system_info)}</div>
        </:col>
        <:col :let={row} label={gettext("Last seen")}>
          <span :if={row.kind == :cloud} class="text-neutral-400">—</span>
          <span :if={row.kind == :connector} class="text-xs text-neutral-500">{format_unix(row.last_seen_at)}</span>
          <div :if={row.kind == :connector && row.system_info_updated_at} class="text-xs text-neutral-400">
            {gettext("info")} {format_unix(row.system_info_updated_at)}
          </div>
        </:col>
        <:action :let={row}>
          <.button
            :if={@can_manage_project && @project.status != "archived" && row.kind == :cloud}
            size="sm"
            variant={if @project.vm_enabled, do: "ghost", else: "primary"}
            phx-click="toggle_vm_enabled"
            phx-disable-with={gettext("Saving…")}
          >
            {if @project.vm_enabled, do: gettext("Disable"), else: gettext("Enable")}
          </.button>
          <.button
            :if={@can_manage_project && row.kind == :connector && row.status != "disconnected" && row.connector_run_id}
            size="sm"
            variant="ghost"
            phx-click="disconnect_environment"
            phx-value-id={row.device_id}
            phx-disable-with={gettext("Disconnecting…")}
            data-confirm={gettext("Disconnect this device?")}
          >
            {gettext("Disconnect")}
          </.button>
          <.button
            :if={@can_manage_project && row.kind == :connector}
            size="sm"
            variant="danger"
            phx-click="delete_environment"
            phx-value-id={row.device_id}
            phx-disable-with={gettext("Deleting…")}
            data-confirm={gettext("Delete this device? It will be disconnected and removed from this Agent Swarm. Agents using it will become unavailable.")}
          >
            {gettext("Delete")}
          </.button>
        </:action>
      </.table>

      <.add_device_modal
        :if={@env_form}
        form={@env_form}
        provisioners={@env_provisioners}
        org={@current_org}
      />

    </div>
    """
  end

  defp websites_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-semibold text-neutral-700">{gettext("Websites")}</h2>
      </div>

      <p class="text-xs text-neutral-500">
        {gettext("Deployed websites hosted by this Agent Swarm's agents, sourced live from Salix.")}
      </p>

      <.empty_state
        :if={@websites_error in [:unavailable, :timeout]}
        icon="globe"
        title={gettext("Salix unavailable")}
        description={gettext("Could not load websites from Salix. Retry shortly.")}
      />

      <.empty_state
        :if={is_nil(@websites_error) && @websites == []}
        icon="globe"
        title={gettext("No websites yet")}
        description={gettext("When an agent in this Agent Swarm publishes a website, it appears here.")}
      />

      <.table :if={@websites != []} id="websites" rows={@websites}>
        <:col :let={site} label={gettext("Site")}>
          <span class="font-medium text-neutral-800">{site["name"]}</span>
        </:col>
        <:col :let={site} label={gettext("Agent")}>
          <.link
            navigate={
              ~p"/orgs/#{@current_org.slug}/projects/#{@project.id}/agents/#{site["agent_id"]}"
            }
            class="text-brand-600 underline"
          >
            {site["agent_name"]}
          </.link>
        </:col>
        <:col :let={site} label={gettext("URL")}>
          <a
            :if={site["url"] not in [nil, ""]}
            href={site["url"]}
            target="_blank"
            rel="noreferrer"
            class="break-all font-mono text-xs text-brand-600 underline"
          >
            {site["url"]}
          </a>
          <span :if={site["url"] in [nil, ""]} class="text-neutral-400">—</span>
        </:col>
      </.table>
    </div>
    """
  end

  defp persist_run_checks_activity(socket, checks) do
    case Observability.record_run_checks_activity(checks,
           ran_by_user_id: socket.assigns.current_user.id
         ) do
      {:ok, _check} ->
        socket

      {:error, _reason} ->
        put_flash(
          socket,
          :error,
          gettext("Checks ran, but Operations could not record them.")
        )
    end
  end
end
