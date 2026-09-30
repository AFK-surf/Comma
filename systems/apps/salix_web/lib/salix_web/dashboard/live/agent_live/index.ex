defmodule SalixWeb.Dashboard.AgentLive.Index do
  @moduledoc """
  List agents with lifecycle/group filters.

  The dead render shows a skeleton only; control-plane data is loaded once on
  the connected mount. Listing agents is a full control-prefix scan, so there
  is deliberately no auto-refresh — reload the page for fresh data.
  """
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.Groups
  alias SalixAgent.Control
  alias SalixWeb.Dashboard.Format

  @statuses ~w(idle completed failed cancelled)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        active_nav: :agents,
        page_title: "Agents",
        breadcrumbs: [{"Agents", nil}],
        statuses: @statuses,
        groups: [],
        filter_status: "",
        filter_group: "",
        include_archived: false,
        agents: nil,
        load_error: false
      )

    if connected?(socket) do
      {:ok,
       socket
       |> assign(groups: Groups.list(socket.assigns.current_tenant))
       |> load()}
    else
      {:ok, socket}
    end
  end

  # On storage failure the previous rows are kept (possibly nil, i.e. never
  # loaded) and a retry banner is shown, so an outage is never rendered as an
  # empty tenant.
  defp load(socket) do
    opts = [
      status: nilify(socket.assigns.filter_status),
      group_id: nilify(socket.assigns.filter_group),
      include_archived: socket.assigns.include_archived
    ]

    case Control.list_result(socket.assigns.current_tenant, opts) do
      {:ok, agents} -> assign(socket, agents: agents, load_error: false)
      {:error, _reason} -> assign(socket, load_error: true)
    end
  end

  defp nilify(""), do: nil
  defp nilify(v), do: v

  @impl true
  def handle_event("retry", _p, socket), do: {:noreply, load(socket)}

  def handle_event("filter", %{"status" => status, "group_id" => group}, socket) do
    {:noreply, socket |> assign(filter_status: status, filter_group: group) |> load()}
  end

  def handle_event("toggle-archived", _p, socket),
    do: {:noreply, socket |> update(:include_archived, &(!&1)) |> load()}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-xl font-semibold">Agents</h1>
        <.button variant="primary" navigate="/dash/agents/new">
          <.icon name="plus" class="h-4 w-4" /> New agent
        </.button>
      </div>

      <div class="flex flex-wrap items-end justify-between gap-3">
        <form phx-change="filter" class="flex flex-wrap items-end gap-3">
          <.select
            name="status"
            label="Status"
            value={@filter_status}
            prompt="All statuses"
            options={Enum.map(@statuses, &{&1, &1})}
            class="w-44"
          />
          <.select
            name="group_id"
            label="Group"
            value={@filter_group}
            prompt="All groups"
            options={Enum.map(@groups, &{&1["name"], &1["group_id"]})}
            class="w-56"
          />
        </form>
        <.toggle
          name="include_archived"
          label="Show archived"
          checked={@include_archived}
          phx-click="toggle-archived"
        />
      </div>

      <div
        :if={@load_error}
        data-role="agents-load-error"
        class="flex items-center justify-between rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700"
      >
        <span>
          Failed to load agents from storage.
          <span :if={is_list(@agents)}>The list below may be stale.</span>
        </span>
        <.button size="sm" phx-click="retry">Retry</.button>
      </div>

      <div
        :if={@agents == nil and not @load_error}
        data-role="agents-skeleton"
        class="animate-pulse space-y-2"
      >
        <div class="h-9 rounded bg-neutral-200/60"></div>
        <div :for={_i <- 1..5} class="h-12 rounded bg-neutral-100"></div>
      </div>

      <.table :if={@agents != nil and @agents != []} id="agents" rows={@agents} row_click={
        fn a -> JS.navigate("/dash/agents/#{a["agent_id"]}") end
      }>
        <:col :let={a} label="Name">
          {a["name"]}
          <.badge :if={Control.archived?(a)} color="amber" class="ml-1">archived</.badge>
        </:col>
        <:col :let={a} label="Status"><.status_pill status={a["status"]} /></:col>
        <:col :let={a} label="Role">{a["role"]}</:col>
        <:col :let={a} label="Group"><span class="font-mono text-xs">{Format.short_id(a["group_id"])}</span></:col>
        <:col :let={a} label="Template">
          <span :if={a["template_id"]} class="font-mono text-xs">{Format.short_id(a["template_id"])}</span>
          <span :if={is_nil(a["template_id"])} class="text-xs text-neutral-500">follows default</span>
        </:col>
        <:action :let={a}>
          <.button size="sm" navigate={"/dash/agents/#{a["agent_id"]}"}>Open</.button>
        </:action>
      </.table>
      <.empty_state :if={@agents == [] and not @load_error} icon="cube" title="No agents" />
    </div>
    """
  end
end
