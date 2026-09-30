defmodule SalixWeb.Dashboard.HomeLive do
  @moduledoc "Dashboard landing page — overview + quick links into the admin areas."
  use SalixWeb.Dashboard, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, active_nav: :home, breadcrumbs: [{"Home", nil}], page_title: "Home")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-xl font-semibold">Salix Admin</h1>
        <p class="mt-1 text-sm text-neutral-500">
          System-wide administration for tenants, agents, sessions and conversations.
        </p>
      </div>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <.home_card title="Cluster" desc="Nodes and capacity" icon="server" navigate="/dash/cluster" />
        <.home_card title="Tenants" desc="Tenants & API keys" icon="building-office" navigate="/dash/tenants" />
        <.home_card title="Templates" desc="LLM agent templates" icon="template" navigate="/dash/templates" />
        <.home_card title="Agent Groups" desc="Groups, OAuth & router" icon="folder" navigate="/dash/groups" />
        <.home_card title="Agents" desc="Agents, sessions & chat" icon="cube" navigate="/dash/agents" />
        <.home_card title="Devices" desc="Connected and known devices" icon="bolt" navigate="/dash/environments" />
        <.home_card title="IM" desc="Provider connects & config" icon="chat" navigate="/dash/im" />
        <.home_card title="MCP" desc="Definitions & bindings" icon="plug" navigate="/dash/mcp" />
        <.home_card title="OAuth Apps" desc="Provider credentials" icon="key" navigate="/dash/oauth" />
        <.home_card title="Config" desc="Agent defaults" icon="cog" navigate="/dash/agent-defaults" />
      </div>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:desc, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:navigate, :string, required: true)

  defp home_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="flex items-start gap-3 rounded-lg border border-neutral-200 bg-white p-4 hover:border-neutral-300 hover:bg-neutral-50"
    >
      <div class="flex h-8 w-8 items-center justify-center rounded-md bg-brand-50 text-brand-600">
        <.icon name={@icon} class="h-4 w-4" />
      </div>
      <div class="min-w-0">
        <p class="text-sm font-medium text-neutral-900">{@title}</p>
        <p class="mt-0.5 text-xs text-neutral-500">{@desc}</p>
      </div>
    </.link>
    """
  end
end
