defmodule BridgeForTeamsWeb.Dashboard.AgentLive.Show do
  @moduledoc """
  Agent detail page for a project agent.

  The page is reached from the project Agents table and validates the full
  org/project/agent chain before rendering. Postgres provides the configured
  agent record; Salix resolves only the agent's selected template.
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  alias BridgeForTeams.{Agents, Memberships, Orgs, Projects}
  alias BridgeForTeams.Salix.Client

  @impl true
  def mount(%{"org" => slug, "id" => project_id, "agent_id" => agent_id}, _session, socket) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, project} <- Projects.get_project(project_id),
         true <- project.org_id == org.id,
         {:ok, org_role} <- Memberships.org_role(org.id, user.id),
         {:ok, project_role} <- Memberships.project_role(project.id, user.id),
         {:ok, agent} <- Agents.get_agent(agent_id),
         true <- agent.project_id == project.id do
      {:ok,
       socket
       |> assign(:orgs, orgs)
       |> assign(:current_org, org)
       |> assign(:current_org_role, org_role)
       |> assign(:project, project)
       |> assign(:can_manage_project, project_role == "admin")
       |> assign(:agent, agent)
       |> assign_router_session(project, agent)
       |> assign(:llm_model, llm_model(agent, org.salix_tenant_id))
       |> assign(:active_nav, :projects)
       |> assign(:page_title, agent.salix["name"] || agent.salix_agent_id || gettext("Agent"))
       |> assign(:breadcrumbs, breadcrumbs(org, project, agent))}
    else
      _ ->
        {:ok,
         socket
         |> assign(:orgs, orgs)
         |> put_flash(:error, gettext("Agent not found."))
         |> push_navigate(to: ~p"/orgs/#{slug}/projects/#{project_id}/agents")}
    end
  end

  @impl true
  def handle_event(
        "switch_router_session",
        %{"expected_session_id" => expected_session_id},
        socket
      ) do
    cond do
      not socket.assigns.can_manage_project ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Only Agent Swarm admins can switch the Router session.")
         )}

      socket.assigns.agent.role != "router" ->
        {:noreply,
         put_flash(socket, :error, gettext("Only Router agents have a canonical session."))}

      expected_session_id != socket.assigns.router_session_id ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The Router session changed. Refresh before retrying.")
         )}

      true ->
        case Agents.switch_router_session(
               socket.assigns.project,
               socket.assigns.agent,
               expected_session_id,
               audit_opts(socket)
             ) do
          {:ok, %{"router_session_id" => new_session_id}} ->
            {:noreply,
             socket
             |> assign(:router_session_id, new_session_id)
             |> assign(:router_session_error, nil)
             |> put_flash(:info, gettext("Started a new canonical Router session."))}

          {:error, {:stale_router_session, current_session_id}} ->
            {:noreply,
             socket
             |> assign(:router_session_id, current_session_id)
             |> put_flash(
               :error,
               gettext(
                 "The Router session was already switched. The current session is shown below."
               )
             )}

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, gettext("Could not switch the canonical Router session."))}
        end
    end
  end

  def handle_event("switch_router_session", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Refresh before switching the Router session."))}
  end

  defp assign_router_session(socket, _project, %{role: role}) when role != "router" do
    socket
    |> assign(:router_session_id, nil)
    |> assign(:router_session_error, nil)
  end

  defp assign_router_session(socket, project, agent) do
    case Agents.get_salix_agent(project, agent) do
      {:ok, %{"router_session_id" => session_id}} when is_binary(session_id) ->
        socket
        |> assign(:router_session_id, session_id)
        |> assign(:router_session_error, nil)

      {:ok, _projection} ->
        socket
        |> assign(:router_session_id, nil)
        |> assign(:router_session_error, :missing)

      {:error, reason} ->
        socket
        |> assign(:router_session_id, nil)
        |> assign(:router_session_error, reason)
    end
  end

  defp breadcrumbs(org, project, agent) do
    [
      {gettext("Agent Swarms"), ~p"/orgs/#{org.slug}/projects"},
      {project.name, ~p"/orgs/#{org.slug}/projects/#{project.id}"},
      {gettext("Agents"), ~p"/orgs/#{org.slug}/projects/#{project.id}/agents"},
      {agent.salix["name"] || agent.salix_agent_id || gettext("Agent"), nil}
    ]
  end

  # Resolve the agent's model for display. Template-backed agents resolve their
  # model id live from the Salix catalog (best-effort — falls back to the
  # template id if the catalog is unreachable). Legacy agents fall back to the
  # journaled `llm_config` snapshot.
  defp llm_model(%{salix: %{"template_id" => template_id}}, tenant_id)
       when is_binary(template_id) and template_id != "" do
    case Client.impl().get_template(template_id, tenant_id) do
      {:ok, template} -> template["model"] || template_id
      {:error, _} -> template_id
    end
  end

  defp llm_model(%{salix: %{"llm_config" => %{"model" => model}}}, _tenant_id)
       when is_binary(model) and model != "",
       do: model

  defp llm_model(_agent, _tenant_id), do: "—"

  defp format_seen(nil), do: "—"
  defp format_seen(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <.button
            size="sm"
            navigate={~p"/orgs/#{@current_org.slug}/projects/#{@project.id}/agents"}
            class="mb-3"
          >
            <.icon name="arrow-left" class="h-4 w-4" /> {gettext("Agents")}
          </.button>
          <h1 class="text-lg font-semibold tracking-tight">{@agent.salix["name"] || gettext("Unnamed agent")}</h1>
          <p class="mt-1 flex items-center gap-2 text-sm text-neutral-500">
            <.badge color={if @agent.role == "router", do: "brand", else: "neutral"}>{@agent.role}</.badge>
            <.status_pill status={BridgeForTeams.Schema.Agent.lifecycle(@agent)} />
          </p>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <.card>
          <:title>{gettext("Agent")}</:title>
          <dl class="grid grid-cols-3 gap-y-3 text-sm">
            <dt class="text-neutral-500">{gettext("Name")}</dt>
            <dd class="col-span-2 text-neutral-800">{@agent.salix["name"] || "—"}</dd>
            <dt class="text-neutral-500">{gettext("Role")}</dt>
            <dd class="col-span-2"><.badge color={if @agent.role == "router", do: "brand", else: "neutral"}>{@agent.role}</.badge></dd>
            <dt class="text-neutral-500">{gettext("Status")}</dt>
            <dd class="col-span-2"><.status_pill status={BridgeForTeams.Schema.Agent.lifecycle(@agent)} /></dd>
            <dt class="text-neutral-500">{gettext("Created")}</dt>
            <dd class="col-span-2 text-neutral-800">{format_seen(@agent.created_at)}</dd>
          </dl>
        </.card>

        <.card :if={@agent.role == "router"}>
          <:title>{gettext("Canonical Router session")}</:title>
          <div class="space-y-4 text-sm">
            <p class="text-neutral-500">
              {gettext("New messages are routed to this Salix session. Starting a new one stops the current session and leaves its history readable.")}
            </p>
            <div>
              <p class="text-xs font-medium uppercase tracking-wide text-neutral-500">{gettext("Session id")}</p>
              <p :if={@router_session_id} id="router-session-id" class="mt-1 break-all font-mono text-xs text-neutral-800">
                {@router_session_id}
              </p>
              <p :if={@router_session_error} class="mt-1 text-sm text-red-600">
                {gettext("The canonical session is unavailable. Refresh to try again.")}
              </p>
            </div>
            <.button
              :if={@can_manage_project && @router_session_id}
              id="switch-router-session"
              variant="danger"
              phx-click="switch_router_session"
              phx-value-expected_session_id={@router_session_id}
              phx-disable-with={gettext("Starting…")}
              data-confirm={gettext("Start a new canonical Router session? Current work will stop, and new messages will use an empty session.")}
            >
              {gettext("Start new session")}
            </.button>
          </div>
        </.card>

        <.card>
          <:title>{gettext("Runtime")}</:title>
          <dl class="grid grid-cols-3 gap-y-3 text-sm">
            <dt class="text-neutral-500">{gettext("Bridge id")}</dt>
            <dd class="col-span-2 break-all font-mono text-xs text-neutral-800">{@agent.id}</dd>
            <dt class="text-neutral-500">{gettext("Agent runtime id")}</dt>
            <dd class="col-span-2 break-all font-mono text-xs text-neutral-800">{@agent.salix_agent_id}</dd>
            <dt class="text-neutral-500">{gettext("Agent Swarm runtime")}</dt>
            <dd class="col-span-2 break-all font-mono text-xs text-neutral-800">{@project.salix_group_id}</dd>
          </dl>
        </.card>

        <.card>
          <:title>{gettext("Configuration")}</:title>
          <dl class="grid grid-cols-3 gap-y-3 text-sm">
            <dt class="text-neutral-500">{gettext("LLM model")}</dt>
            <dd class="col-span-2 text-neutral-800">{@llm_model}</dd>
            <dt class="text-neutral-500">{gettext("Slot")}</dt>
            <dd class="col-span-2 text-neutral-800">{@agent.slot || "—"}</dd>
            <dt class="text-neutral-500">{gettext("System prompt")}</dt>
            <dd class="col-span-2 whitespace-pre-wrap text-neutral-800">{@agent.salix["system_prompt"] || "—"}</dd>
          </dl>
        </.card>

      </div>
    </div>
    """
  end

  defp audit_opts(socket) do
    user = socket.assigns.current_user

    [
      actor_user_id: user.id,
      actor_label: user.email || user.name || user.id,
      request_id: Ecto.UUID.generate()
    ]
  end
end
