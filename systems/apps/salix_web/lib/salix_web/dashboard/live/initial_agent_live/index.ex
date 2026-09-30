defmodule SalixWeb.Dashboard.InitialAgentLive.Index do
  @moduledoc """
  List the tenant's initial-agent slots (the seed roster materialized into
  group agents) with create/edit/delete.
  """
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.InitialAgentSeeds
  alias SalixWeb.Dashboard.Format

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       active_nav: :initial_agents,
       page_title: "Initial agents",
       breadcrumbs: [{"Initial agents", nil}]
     )
     |> load()}
  end

  defp load(socket) do
    assign(socket, agents: InitialAgentSeeds.list(socket.assigns.current_tenant))
  end

  @impl true
  def handle_event("delete", %{"slot" => slot}, socket) do
    case InitialAgentSeeds.delete(slot, socket.assigns.current_tenant) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Initial agent slot deleted.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-xl font-semibold">Initial agents</h1>
          <p class="mt-1 text-sm text-neutral-500">
            Seed agents provisioned for new groups in this tenant. Each slot names a
            template; the default slot seeds new groups when no agent is specified.
          </p>
        </div>
        <.button variant="primary" navigate="/dash/initial-agents/new">
          <.icon name="plus" class="h-4 w-4" /> New slot
        </.button>
      </div>

      <.table :if={@agents != []} id="initial-agents" rows={@agents}>
        <:col :let={a} label="Slot"><span class="font-mono text-xs">{a["slot"]}</span></:col>
        <:col :let={a} label="Name">{a["display_name"]}</:col>
        <:col :let={a} label="Template">{a["template_name"]}</:col>
        <:col :let={a} label="Model"><span class="font-mono text-xs">{a["model"]}</span></:col>
        <:col :let={a} label="Role">{a["role"]}</:col>
        <:col :let={a} label="Default">{if a["is_default"], do: "yes", else: "—"}</:col>
        <:col :let={a} label="Enabled">{if a["enabled"], do: "yes", else: "no"}</:col>
        <:col :let={a} label="Order">{a["sort_order"]}</:col>
        <:col :let={a} label="Updated">{Format.time_ago(a["updated_at"])}</:col>
        <:action :let={a}>
          <.button size="sm" navigate={"/dash/initial-agents/#{a["slot"]}"}>Edit</.button>
          <.button
            size="sm"
            variant="danger"
            phx-click="delete"
            phx-value-slot={a["slot"]}
            data-confirm="Delete this initial agent slot?"
          >
            Delete
          </.button>
        </:action>
      </.table>

      <.empty_state
        :if={@agents == []}
        icon="cube"
        title="No initial agents"
        description="Add a slot to define which agents seed new groups in this tenant."
      />
    </div>
    """
  end
end
