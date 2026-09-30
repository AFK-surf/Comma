defmodule SalixWeb.Dashboard.ClusterLive do
  @moduledoc "Cluster overview: stats and nodes."
  use SalixWeb.Dashboard, :live_view

  alias SalixWeb.Dashboard.Format

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok,
     socket
     |> assign(active_nav: :cluster, page_title: "Cluster", breadcrumbs: [{"Cluster", nil}])
     |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    assign(socket,
      stats: SalixCluster.Nodes.stats(),
      nodes: SalixCluster.Nodes.list()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-xl font-semibold">Cluster</h1>

      <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <.stat label="Active nodes" value={@stats.active_nodes} />
        <.stat label="Total nodes" value={@stats.total_nodes} />
        <.stat label="Agents" value={@stats.total_agents} />
        <.stat label="Capacity" value={@stats.total_capacity} />
      </div>

      <.card>
        <:title>Nodes</:title>
        <.table :if={@nodes != []} id="nodes" rows={@nodes}>
          <:col :let={n} label="Node">{n["node_id"]}</:col>
          <:col :let={n} label="Address">{n["address"]}</:col>
          <:col :let={n} label="Status"><.status_pill status={n["status"]} /></:col>
          <:col :let={n} label="Agents">{n["agent_count"]} / {n["max_agents"]}</:col>
          <:col :let={n} label="Heartbeat">{Format.time_ago(n["heartbeat_at"])}</:col>
        </.table>
        <.empty_state :if={@nodes == []} title="No nodes" description="No cluster nodes reporting." />
      </.card>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  defp stat(assigns) do
    ~H"""
    <div class="rounded-lg border border-neutral-200 bg-white px-4 py-3">
      <p class="text-xs font-medium uppercase tracking-wide text-neutral-500">{@label}</p>
      <p class="mt-1 text-2xl font-semibold text-neutral-900">{@value}</p>
    </div>
    """
  end
end
