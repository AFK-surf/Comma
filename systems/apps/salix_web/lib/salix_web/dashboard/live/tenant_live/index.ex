defmodule SalixWeb.Dashboard.TenantLive.Index do
  @moduledoc "Browse tenants in bounded pages and create new ones."
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.Tenants
  alias SalixWeb.Dashboard.Format

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(active_nav: :tenants, page_title: "Tenants", breadcrumbs: [{"Tenants", nil}])
     |> assign(
       show_new: false,
       cursor: nil,
       next: nil,
       previous: [],
       tenant_page: [],
       page_error: nil,
       page_retry: nil
     )
     |> load()}
  end

  defp load(socket, cursor \\ nil, previous \\ []) do
    case Tenants.page(cursor) do
      {:ok, %{tenants: tenants, next: next}} ->
        assign(socket,
          tenant_page: tenants,
          cursor: cursor,
          next: next,
          previous: previous,
          page_error: nil,
          page_retry: nil
        )

      {:error, _} ->
        assign(socket,
          page_error: "Tenants are unavailable. Try again.",
          page_retry: {cursor, previous}
        )
    end
  end

  @impl true
  def handle_event("next-page", _, %{assigns: %{next: nil}} = socket), do: {:noreply, socket}

  def handle_event("next-page", _, socket) do
    {:noreply,
     load(socket, socket.assigns.next, [socket.assigns.cursor | socket.assigns.previous])}
  end

  def handle_event("previous-page", _, %{assigns: %{previous: []}} = socket),
    do: {:noreply, socket}

  def handle_event("previous-page", _, socket) do
    [cursor | previous] = socket.assigns.previous
    {:noreply, load(socket, cursor, previous)}
  end

  def handle_event("retry-page", _, %{assigns: %{page_retry: {cursor, previous}}} = socket) do
    {:noreply, load(socket, cursor, previous)}
  end

  def handle_event("retry-page", _, socket), do: {:noreply, socket}

  def handle_event("new", _params, socket), do: {:noreply, assign(socket, show_new: true)}
  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, show_new: false)}

  def handle_event("create", %{"name" => name} = params, socket) do
    attrs = %{"name" => name} |> maybe_put_tenant_id(params["tenant_id"])

    case Tenants.create(attrs) do
      {:ok, tenant} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tenant created.")
         |> assign(show_new: false)
         |> push_navigate(to: "/dash/tenants/#{tenant["tenant_id"]}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  defp maybe_put_tenant_id(attrs, id) when is_binary(id) and id != "",
    do: Map.put(attrs, "tenant_id", id)

  defp maybe_put_tenant_id(attrs, _), do: attrs

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-xl font-semibold">Tenants</h1>
        <.button variant="primary" phx-click="new">
          <.icon name="plus" class="h-4 w-4" /> New tenant
        </.button>
      </div>

      <div :if={@page_error} role="alert" class="flex items-center justify-between">
        <p>{@page_error}</p>
        <.button phx-click="retry-page">Retry</.button>
      </div>

      <.table :if={@tenant_page != []} id="tenants" rows={@tenant_page} row_click={
        fn t -> JS.navigate("/dash/tenants/#{t["tenant_id"]}") end
      }>
        <:col :let={t} label="Name">{t["name"]}</:col>
        <:col :let={t} label="Tenant ID"><span class="font-mono text-xs">{t["tenant_id"]}</span></:col>
        <:col :let={t} label="Created">{Format.time_ago(t["created_at"])}</:col>
        <:action :let={t}>
          <.button size="sm" navigate={"/dash/tenants/#{t["tenant_id"]}"}>Open</.button>
          <.button size="sm" href={"/dash/tenant/select?tenant_id=#{t["tenant_id"]}"}>
            Use this tenant
          </.button>
        </:action>
      </.table>
      <.empty_state :if={@tenant_page == [] and is_nil(@page_error)} icon="building-office" title="No tenants on this page" />
      <div class="flex items-center justify-between">
        <div><.button :if={@previous != []} phx-click="previous-page">Previous</.button></div>
        <span class="text-sm text-neutral-500">Page {length(@previous) + 1}</span>
        <div><.button :if={@next} phx-click="next-page">Next</.button></div>
      </div>

      <.modal :if={@show_new} id="new-tenant" show on_cancel={JS.push("cancel")}>
        <:title>New tenant</:title>
        <form phx-submit="create" class="space-y-3">
          <.input name="name" label="Name" required placeholder="Acme Inc" />
          <.input name="tenant_id" label="Tenant ID (optional)" placeholder="auto-generated" />
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
