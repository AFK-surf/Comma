defmodule SalixWeb.Dashboard.GroupLive.Index do
  @moduledoc "List agent groups and create/delete them."
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.Groups
  alias SalixWeb.Dashboard.Format

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       active_nav: :groups,
       page_title: "Agent Groups",
       breadcrumbs: [{"Agent Groups", nil}]
     )
     |> assign(show_new: false)
     |> load()}
  end

  defp load(socket),
    do: assign(socket, groups: Groups.list(socket.assigns.current_tenant))

  @impl true
  def handle_event("new", _params, socket), do: {:noreply, assign(socket, show_new: true)}
  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, show_new: false)}

  def handle_event("create", params, socket) do
    attrs = %{"name" => params["name"]} |> put_if(params, "purpose")

    case Groups.create(attrs, socket.assigns.current_tenant) do
      {:ok, group} ->
        {:noreply, push_navigate(socket, to: "/dash/groups/#{group["group_id"]}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Groups.delete(id, socket.assigns.current_tenant) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Group deleted.") |> load()}

      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Group deleted.") |> load()}

      {:error, {:conflict, msg}} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
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
      <div class="flex items-center justify-between">
        <h1 class="text-xl font-semibold">Agent Groups</h1>
        <.button variant="primary" phx-click="new">
          <.icon name="plus" class="h-4 w-4" /> New group
        </.button>
      </div>

      <.table :if={@groups != []} id="groups" rows={@groups} row_click={
        fn g -> JS.navigate("/dash/groups/#{g["group_id"]}") end
      }>
        <:col :let={g} label="Name">{g["name"]}</:col>
        <:col :let={g} label="Group ID"><span class="font-mono text-xs">{g["group_id"]}</span></:col>
        <:col :let={g} label="Purpose">{g["purpose"] || "—"}</:col>
        <:col :let={g} label="Created">{Format.time_ago(g["created_at"])}</:col>
        <:action :let={g}>
          <.button size="sm" navigate={"/dash/groups/#{g["group_id"]}"}>Open</.button>
          <.button
            size="sm"
            variant="danger"
            phx-click="delete"
            phx-value-id={g["group_id"]}
            data-confirm="Delete this group?"
          >
            Delete
          </.button>
        </:action>
      </.table>
      <.empty_state :if={@groups == []} icon="folder" title="No agent groups" />

      <.modal :if={@show_new} id="new-group" show on_cancel={JS.push("cancel")}>
        <:title>New agent group</:title>
        <form phx-submit="create" class="space-y-3">
          <.input name="name" label="Name" required placeholder="Workspace" />
          <.input name="purpose" label="Purpose (optional)" />
          <div class="flex justify-end gap-2 pt-2">
            <.button type="button" phx-click="cancel">Cancel</.button>
            <.button type="submit" variant="primary">Create</.button>
          </div>
        </form>
      </.modal>
    </div>
    """
  end
end
