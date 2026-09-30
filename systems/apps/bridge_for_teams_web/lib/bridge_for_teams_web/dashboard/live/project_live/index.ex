defmodule BridgeForTeamsWeb.Dashboard.ProjectLive.Index do
  @moduledoc """
  Project list for an org (`/orgs/:org/projects`). Dense table of projects
  (name, slug, Agent Swarm id, status pill, created) with a client-side search
  filter, row-click navigation to the project detail, and a "New project" modal
  that creates a project via `BridgeForTeams.Projects.create_project/2` (which
  allocates the canonical Salix group and enqueues the create-group reconcile).
  Org owners/admins create freely; ordinary members get exactly one Agent Swarm
  per org (`Projects.can_create_project?/2`), so the button hides once used.

  Owned by slice "projects".
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  alias BridgeForTeams.{Memberships, Orgs, Projects}
  alias BridgeForTeams.Schema.Project
  alias BridgeForTeamsWeb.Dashboard.Onboarding, as: OnboardingHook

  @impl true
  def mount(%{"org" => slug} = _params, _session, socket) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, org_role} <- Memberships.org_role(org.id, user.id) do
      projects = Projects.list_projects_for_user(org.id, user.id)

      {:ok,
       socket
       |> assign(:page_title, gettext("Agent Swarms"))
       |> assign(:active_nav, :projects)
       |> assign(:current_org, org)
       |> assign(:current_org_role, org_role)
       |> assign(:can_create_project, Projects.can_create_project?(org.id, user.id))
       |> assign(:orgs, orgs)
       |> assign(:breadcrumbs, [
         {org.name, ~p"/orgs/#{org.slug}"},
         {gettext("Agent Swarms"), nil}
       ])
       |> assign(:projects, projects)
       |> assign(:query, "")
       |> assign(:show_new, false)
       |> reset_form()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Organization not found."))
         |> redirect(to: ~p"/orgs")}
    end
  end

  @impl true
  def handle_event("filter", %{"query" => query}, socket) do
    {:noreply, assign(socket, :query, query)}
  end

  def handle_event("new", _params, socket) do
    if socket.assigns.can_create_project do
      {:noreply,
       socket
       |> assign(:show_new, true)
       |> reset_form()}
    else
      {:noreply, put_flash(socket, :error, create_denied_message())}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, :show_new, false)}
  end

  def handle_event("validate", %{"project" => params}, socket) do
    if socket.assigns.can_create_project do
      changeset = validate_changeset(socket, params)
      {:noreply, assign_form(socket, params, changeset)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"project" => params}, socket) do
    org = socket.assigns.current_org

    if socket.assigns.can_create_project do
      case Projects.create_project(org.id, params,
             creator_user_id: socket.assigns.current_user.id,
             actor_label: audit_actor_label(socket.assigns.current_user)
           ) do
        {:ok, project} ->
          user = socket.assigns.current_user

          {:noreply,
           socket
           |> put_flash(:info, gettext("Agent Swarm \"%{name}\" created.", name: project.name))
           |> assign(:show_new, false)
           |> assign(:projects, Projects.list_projects_for_user(org.id, user.id))
           |> assign(:can_create_project, Projects.can_create_project?(org.id, user.id))
           |> reset_form()
           |> OnboardingHook.rebuild()}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign_form(socket, params, Map.put(changeset, :action, :validate))}

        {:error, :project_quota_reached} ->
          {:noreply,
           socket
           |> assign(:show_new, false)
           |> assign(:can_create_project, false)
           |> put_flash(:error, create_denied_message())}

        {:error, _other} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Could not create the Agent Swarm. Please try again.")
           )}
      end
    else
      maybe_record_project_create_denied(socket, params)

      {:noreply, put_flash(socket, :error, create_denied_message())}
    end
  end

  # The umbrella does not pull in phoenix_ecto, so Ecto.Changeset has no
  # Phoenix.HTML.FormData impl — we drive the form from a plain params map and
  # surface field errors via a separate `@form_errors` map.
  defp validate_changeset(socket, params) do
    %Project{org_id: socket.assigns.current_org.id}
    |> Project.changeset(params)
    |> Map.put(:action, :validate)
  end

  defp reset_form(socket) do
    socket
    |> assign(:form, to_form(%{}, as: :project))
    |> assign(:form_errors, %{})
  end

  defp assign_form(socket, params, %Ecto.Changeset{} = changeset) do
    socket
    |> assign(:form, to_form(params, as: :project))
    |> assign(:form_errors, errors_for(changeset))
  end

  defp errors_for(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  defp filtered(projects, ""), do: projects

  defp filtered(projects, query) do
    q = String.downcase(String.trim(query))

    Enum.filter(projects, fn p ->
      String.contains?(String.downcase(p.name || ""), q) or
        String.contains?(String.downcase(p.slug || ""), q) or
        String.contains?(String.downcase(p.salix_group_id || ""), q)
    end)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible, filtered(assigns.projects, assigns.query))

    ~H"""
    <div class="space-y-5">
      <div class="flex items-center justify-between gap-4">
        <div>
          <h1 class="text-lg font-semibold tracking-tight">{gettext("Agent Swarms")}</h1>
          <p class="text-sm text-neutral-500">
            {gettext(
              "Agent Swarms in %{name}. Each groups agents, tasks, integrations, environments, and websites.",
              name: @current_org.name
            )}
          </p>
        </div>
        <.button :if={@can_create_project} variant="primary" phx-click="new" id="new-project-button">
          <.icon name="plus" class="h-4 w-4" /> {gettext("New Agent Swarm")}
        </.button>
      </div>

      <div :if={@projects != []} class="flex items-center">
        <div class="relative w-72 max-w-full">
          <span class="pointer-events-none absolute inset-y-0 left-0 flex items-center pl-2.5 text-neutral-400">
            <.icon name="search" class="h-4 w-4" />
          </span>
          <form id="project-search" phx-change="filter" phx-submit="filter">
            <input
              type="text"
              name="query"
              value={@query}
              placeholder={gettext("Search Agent Swarms...")}
              autocomplete="off"
              phx-debounce="150"
              class="block h-8 w-full rounded-md border border-neutral-300 pl-8 pr-2.5 text-sm placeholder:text-neutral-400 focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            />
          </form>
        </div>
      </div>

      <.empty_state
        :if={@projects == []}
        icon="folder"
        title={gettext("No Agent Swarms yet")}
        description={gettext("Create your first Agent Swarm to provision its runtime.")}
      >
        <:actions>
          <.button :if={@can_create_project} variant="primary" phx-click="new">
            <.icon name="plus" class="h-4 w-4" /> {gettext("New Agent Swarm")}
          </.button>
        </:actions>
      </.empty_state>

      <.empty_state
        :if={@projects != [] and @visible == []}
        icon="search"
        title={gettext("No matching Agent Swarms")}
        description={gettext("No Agent Swarm matches your search.")}
      />

      <.table
        :if={@visible != []}
        id="projects"
        rows={@visible}
        row_id={fn p -> "project-#{p.id}" end}
        row_click={fn p -> JS.navigate(~p"/orgs/#{@current_org.slug}/projects/#{p.id}") end}
      >
        <:col :let={p} label={gettext("Name")}>
          <span class="font-medium text-neutral-900">{p.name}</span>
        </:col>
        <:col :let={p} label={gettext("Slug")}>
          <span class="text-neutral-500">{p.slug}</span>
        </:col>
        <:col :let={p} label={gettext("Agent Swarm")}>
          <span class="font-mono text-xs text-neutral-500">{p.salix_group_id}</span>
        </:col>
        <:col :let={p} label={gettext("Status")}>
          <.status_pill status={p.status} />
        </:col>
        <:col :let={p} label={gettext("Created")}>
          <span class="text-neutral-500">{format_date(p.created_at)}</span>
        </:col>
      </.table>

      <.modal :if={@show_new} id="new-project" show on_cancel={JS.push("cancel")}>
        <:title>{gettext("New Agent Swarm")}</:title>
        <.form for={@form} phx-change="validate" phx-submit="save" id="new-project-form">
          <div class="space-y-4">
            <.input
              id="project_name"
              name="project[name]"
              value={@form[:name].value}
              errors={Map.get(@form_errors, :name, [])}
              label={gettext("Name")}
              placeholder={gettext("e.g. Billing service")}
              phx-mounted={JS.focus()}
              required
            />
            <.input
              id="project_slug"
              name="project[slug]"
              value={@form[:slug].value}
              errors={Map.get(@form_errors, :slug, [])}
              label={gettext("Slug")}
              placeholder={gettext("billing-service")}
              hint={gettext("A short URL-friendly identifier, unique within the org.")}
              required
            />
          </div>
          <div class="mt-5 flex items-center justify-end gap-2">
            <.button
              type="button"
              variant="secondary"
              phx-click={JS.exec("phx-remove", to: "#new-project") |> JS.push("cancel")}
            >
              {gettext("Cancel")}
            </.button>
            <.button type="submit" variant="primary" phx-disable-with={gettext("Creating…")}>
              {gettext("Create Agent Swarm")}
            </.button>
          </div>
        </.form>
      </.modal>
    </div>
    """
  end

  defp format_date(nil), do: "—"

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %-d, %Y")
  end

  # Everyone who can mount this view holds an org membership, so the only
  # reachable denial is an ordinary member whose one-Agent-Swarm quota is used.
  defp create_denied_message,
    do: gettext("Org members can create only one Agent Swarm; you have already created yours.")

  defp maybe_record_project_create_denied(socket, params) do
    _ =
      Projects.record_project_write_attempt(
        {:org, socket.assigns.current_org.id},
        "project.created",
        "denied",
        :project_quota_reached,
        audit_opts(socket),
        metadata: attempted_project_create_metadata(params)
      )

    :ok
  end

  defp attempted_project_create_metadata(params) do
    params = stringify(params)

    %{
      "attempted_name_configured" => present?(params["name"]),
      "attempted_slug_configured" => present?(params["slug"]),
      "surface" => "project_index"
    }
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
      present?(user.email) -> String.trim(user.email)
      present?(user.name) -> String.trim(user.name)
      true -> user.id
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp stringify(params) when is_map(params),
    do: Map.new(params, fn {key, value} -> {to_string(key), value} end)
end
