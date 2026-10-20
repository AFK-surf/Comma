defmodule SalixWeb.Dashboard.AgentLive.New do
  @moduledoc "Create an agent (group + model, optional fork, VM)."
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.Groups
  alias SalixAgent.Control
  alias SalixWeb.Dashboard.ModelField

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       active_nav: :agents,
       page_title: "New agent",
       breadcrumbs: [{"Agents", "/dash/agents"}, {"New", nil}],
       groups: Groups.list(socket.assigns.current_tenant),
       agents: Control.list(socket.assigns.current_tenant, []),
       selected_group_id: ""
     )}
  end

  @impl true
  def handle_event("form_change", params, socket) do
    {:noreply, assign(socket, selected_group_id: params["group_id"] || "")}
  end

  @impl true
  def handle_event("create", params, socket) do
    case Control.create(agent_attrs(params), socket.assigns.current_tenant) do
      {:ok, agent} ->
        {:noreply, push_navigate(socket, to: "/dash/agents/#{agent["agent_id"]}")}

      {:error, {:bad_request, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  defp agent_attrs(params) do
    %{"group_id" => params["group_id"]}
    |> then(fn attrs ->
      case ModelField.change(params["model"], nil) do
        model when is_map(model) -> Map.put(attrs, "model", model)
        _follow -> attrs
      end
    end)
    |> put_if(params, "name")
    |> put_if(params, "fork_from")
    |> put_if(params, "role")
  end

  defp put_if(attrs, params, key) do
    case params[key] do
      v when is_binary(v) and v != "" -> Map.put(attrs, key, v)
      _ -> attrs
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-xl font-semibold">New agent</h1>

      <form id="new-agent-form" phx-change="form_change" phx-submit="create" class="max-w-xl space-y-4">
        <.card>
          <div class="space-y-3">
            <.input name="name" label="Name (optional)" />
            <.select
              name="group_id"
              label="Agent group"
              prompt="Select a group"
              value={@selected_group_id}
              options={Enum.map(@groups, &{&1["name"], &1["group_id"]})}
              required
            />
            <.select
              name="model"
              label="Model"
              prompt="Platform model of the role"
              options={ModelField.options(nil)}
            />
            <.select
              name="role"
              label="Role"
              value="worker"
              options={[{"worker", "worker"}, {"router", "router"}]}
            />
            <.select
              name="fork_from"
              label="Fork from (optional)"
              prompt="None"
              options={Enum.map(@agents, &{&1["name"], &1["agent_id"]})}
            />
          </div>
        </.card>
        <div class="flex justify-end gap-2">
          <.button navigate="/dash/agents">Cancel</.button>
          <.button type="submit" variant="primary">Create agent</.button>
        </div>
      </form>
    </div>
    """
  end
end
