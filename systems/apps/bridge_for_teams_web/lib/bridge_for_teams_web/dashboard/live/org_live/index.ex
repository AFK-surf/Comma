defmodule BridgeForTeamsWeb.Dashboard.OrgLive.Index do
  @moduledoc """
  Lists the organizations the current user belongs to (`/orgs`) as cards with a
  member/project count, and lets the user pick one (navigate to `/orgs/:slug`).

  Owned by slice "orgs-shell". Talks to `BridgeForTeams.{Orgs,Projects}` in-process.
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  import Ecto.Query

  alias BridgeForTeams.{Memberships, Orgs, Projects, Repo}
  alias BridgeForTeams.Schema.OrgMembership

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)
    current_org = List.first(orgs)
    current_org_role = current_org_role(current_org, user.id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Organizations"))
     |> assign(:active_nav, nil)
     |> assign(:breadcrumbs, [{gettext("Organizations"), nil}])
     |> assign(:current_org, current_org)
     |> assign(:current_org_role, current_org_role)
     |> assign(:orgs, orgs)
     |> assign(:org_cards, build_cards(orgs))}
  end

  defp current_org_role(nil, _user_id), do: nil

  defp current_org_role(org, user_id) do
    case Memberships.org_role(org.id, user_id) do
      {:ok, role} -> role
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-lg font-semibold">{gettext("Organizations")}</h1>
          <p class="text-sm text-neutral-500">{gettext("Workspaces you belong to.")}</p>
        </div>
      </div>

      <.empty_state
        :if={@org_cards == []}
        icon="building-office"
        title={gettext("No organizations yet")}
        description={gettext("Use an invite code to create a new organization, or ask an administrator to add you to an existing one.")}
      />

      <div :if={@org_cards != []} class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <.link :for={c <- @org_cards} navigate={~p"/orgs/#{c.org.slug}"} class="block">
          <.card class="transition hover:border-neutral-300">
            <:title>
              <div class="flex items-center gap-2">
                <.org_avatar org={c.org} size="sm" />
                <span class="truncate">{c.org.name}</span>
              </div>
            </:title>
            <div class="flex items-center gap-4 text-sm text-neutral-500">
              <span class="inline-flex items-center gap-1.5">
                <.icon name="users" class="h-4 w-4" /> {ngettext("%{count} member", "%{count} members", c.member_count)}
              </span>
              <span class="inline-flex items-center gap-1.5">
                <.icon name="folder" class="h-4 w-4" /> {ngettext("%{count} Agent Swarm", "%{count} Agent Swarms", c.project_count)}
              </span>
            </div>
          </.card>
        </.link>
      </div>
    </div>
    """
  end

  # ---- helpers ----

  defp build_cards(orgs) do
    Enum.map(orgs, fn org ->
      %{
        org: org,
        member_count: member_count(org.id),
        project_count: length(Projects.list_projects(org.id))
      }
    end)
  end

  defp member_count(org_id) do
    Repo.aggregate(from(m in OrgMembership, where: m.org_id == ^org_id), :count, :id)
  end
end
