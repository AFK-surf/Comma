defmodule SalixWeb.Dashboard.TenantLive.Index do
  @moduledoc """
  Browse tenants newest first and create new ones. The list reads the Tenant
  directory (`SalixStore.TenantDirectory`) in bounded keyset pages, filtered
  by product and by a name or Tenant id search. Search text and filter live
  in the URL (`?q=...&product=comma`).
  """
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.Tenants
  alias SalixStore.TenantDirectory
  alias SalixWeb.Dashboard.{Format, LocalTime}

  @page_size 25
  @segments [{nil, "All"}, {"comma", "Comma"}, {"cft", "CFT"}, {"other", "Other"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(active_nav: :tenants, page_title: "Tenants", breadcrumbs: [{"Tenants", nil}])
     |> assign(
       show_new: false,
       query: nil,
       product: nil,
       counts: nil,
       cursor: nil,
       next: nil,
       previous: [],
       tenant_page: [],
       guests: MapSet.new(),
       page_error: nil,
       page_retry: nil
     )}
  end

  # Search or filter changes start again on the first page.
  @impl true
  def handle_params(params, _uri, socket) do
    query = TenantDirectory.normalize_query(params["q"])
    product = if params["product"] in TenantDirectory.buckets(), do: params["product"]

    counts =
      case Tenants.directory_counts(query) do
        {:ok, counts} -> counts
        {:error, _} -> nil
      end

    {:noreply,
     socket
     |> assign(query: query, product: product, counts: counts)
     |> load(nil, [])}
  end

  defp load(socket, cursor, previous) do
    opts = %{
      product: socket.assigns.product,
      query: socket.assigns.query,
      cursor: cursor,
      limit: @page_size
    }

    case Tenants.directory_page(opts) do
      {:ok, {tenants, next}} ->
        assign(socket,
          tenant_page: tenants,
          guests: guests(tenants),
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

  # Which of the page's Comma Tenants are the router-only guest Tenant: one
  # query for at most one page of ids. Without it the label is left out.
  defp guests(tenants) do
    ids = for %{"product" => "comma", "tenant_id" => id} <- tenants, do: id

    case Tenants.router_only_ids(ids) do
      {:ok, guests} -> guests
      {:error, _} -> MapSet.new()
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    query = TenantDirectory.normalize_query(q)
    {:noreply, push_patch(socket, to: tenants_path(query, socket.assigns.product))}
  end

  def handle_event("clear-search", _, socket) do
    {:noreply, push_patch(socket, to: tenants_path(nil, socket.assigns.product))}
  end

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

  defp tenants_path(query, product) do
    case Enum.reject([{"q", query}, {"product", product}], fn {_k, v} -> is_nil(v) end) do
      [] -> "/dash/tenants"
      params -> "/dash/tenants?" <> URI.encode_query(params)
    end
  end

  defp segments, do: @segments

  defp segment_count(nil, _bucket), do: nil
  defp segment_count(counts, nil), do: counts["all"]
  defp segment_count(counts, bucket), do: counts[bucket]

  defp product_label("comma", tenant_id, guests) do
    if MapSet.member?(guests, tenant_id), do: "Comma · guests", else: "Comma"
  end

  defp product_label("cft", _tenant_id, _guests), do: "CFT"
  defp product_label(_product, _tenant_id, _guests), do: nil

  # The record's `created_at` is epoch seconds: a relative label, with the full
  # time as the tooltip, which the `BrowserLocalTime` hook turns into the
  # viewer's time zone (`data-local-time-title-template`).
  attr(:seconds, :any, required: true)

  defp created(assigns) do
    assigns =
      assign(
        assigns,
        :at,
        case is_integer(assigns.seconds) && DateTime.from_unix(assigns.seconds) do
          {:ok, at} -> at
          _ -> nil
        end
      )

    ~H"""
    <time
      :if={@at}
      datetime={DateTime.to_iso8601(@at)}
      title={LocalTime.utc_text(DateTime.to_unix(@at, :millisecond), "full")}
      data-local-time-ms={DateTime.to_unix(@at, :millisecond)}
      data-local-time-format="full"
      data-local-time-title-template="%s"
    >{Format.time_ago(@at)}</time>
    <span :if={is_nil(@at)} class="text-neutral-400">—</span>
    """
  end

  defp empty_title(query, _product) when is_binary(query), do: ~s(No tenants match "#{query}")
  defp empty_title(nil, nil), do: "No tenants yet"
  defp empty_title(nil, _product), do: "No tenants in this filter"

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `CatalogPage` brings the page top back into view when the page changes. --%>
    <div id="tenant-list" phx-hook="CatalogPage" data-cursor={length(@previous)} class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-xl font-semibold">Tenants</h1>
        <.button variant="primary" phx-click="new">
          <.icon name="plus" class="h-4 w-4" /> New tenant
        </.button>
      </div>

      <div class="flex flex-wrap items-center justify-between gap-3">
        <form id="tenant-search" phx-change="search" phx-submit="search" class="relative w-72">
          <.icon name="search" class="pointer-events-none absolute left-2.5 top-2 h-4 w-4 text-neutral-400" />
          <input
            type="text"
            inputmode="search"
            enterkeyhint="search"
            name="q"
            value={@query}
            placeholder="Search by name or tenant ID"
            aria-label="Search tenants"
            autocomplete="off"
            phx-debounce="200"
            class="block h-8 w-full rounded-md border border-neutral-300 pl-8 pr-8 text-sm placeholder:text-neutral-400 focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          />
          <button
            :if={@query}
            type="button"
            phx-click="clear-search"
            aria-label="Clear search"
            class="absolute right-1 top-1/2 inline-flex h-6 w-6 -translate-y-1/2 items-center justify-center rounded text-neutral-400 hover:bg-neutral-100 hover:text-neutral-700"
          >
            <.icon name="x-mark" class="h-4 w-4" />
          </button>
        </form>

        <div id="tenant-products" class="inline-flex rounded-md border border-neutral-200 p-0.5" role="tablist">
          <.link
            :for={{bucket, label} <- segments()}
            patch={tenants_path(@query, bucket)}
            role="tab"
            aria-selected={to_string(@product == bucket)}
            data-product={bucket || "all"}
            class={[
              "inline-flex items-center gap-1.5 rounded px-3 py-1 text-sm font-medium transition-colors",
              @product == bucket && "bg-neutral-100 text-neutral-900",
              @product != bucket && "text-neutral-500 hover:text-neutral-700"
            ]}
          >
            {label}
            <span :if={segment_count(@counts, bucket)} class="text-xs tabular-nums text-neutral-400">
              {segment_count(@counts, bucket)}
            </span>
          </.link>
        </div>
      </div>

      <div :if={@page_error} role="alert" class="flex items-center justify-between">
        <p>{@page_error}</p>
        <.button phx-click="retry-page">Retry</.button>
      </div>

      <.table :if={@tenant_page != []} id="tenants" rows={@tenant_page} fixed row_click={
        fn t -> JS.navigate("/dash/tenants/#{t["tenant_id"]}") end
      }>
        <:col :let={t} label="Name" class="truncate"><span title={t["name"]}>{t["name"]}</span></:col>
        <:col :let={t} label="Product" class="w-40">
          <%= if label = product_label(t["product"], t["tenant_id"], @guests) do %>
            <.badge>{label}</.badge>
          <% else %>
            <span class="text-neutral-400" aria-label="No product">—</span>
          <% end %>
        </:col>
        <:col :let={t} label="Tenant ID" class="w-60">
          <span class="font-mono text-xs">{t["tenant_id"]}</span>
        </:col>
        <:col :let={t} label="Created" class="w-28"><.created seconds={t["created_at"]} /></:col>
        <:action :let={t}>
          <.button size="sm" navigate={"/dash/tenants/#{t["tenant_id"]}"}>Open</.button>
          <.button size="sm" href={"/dash/tenant/select?tenant_id=#{t["tenant_id"]}"}>
            Use this tenant
          </.button>
        </:action>
      </.table>
      <.empty_state
        :if={@tenant_page == [] and is_nil(@page_error)}
        icon="building-office"
        title={empty_title(@query, @product)}
      >
        <:actions :if={@query}>
          <.button phx-click="clear-search">Clear search</.button>
        </:actions>
      </.empty_state>
      <div :if={@previous != [] or @next} id="tenant-pager" class="grid grid-cols-3 items-center">
        <div><.button :if={@previous != []} phx-click="previous-page">Previous</.button></div>
        <span class="text-center text-sm text-neutral-500">Page {length(@previous) + 1}</span>
        <div class="text-right"><.button :if={@next} phx-click="next-page">Next</.button></div>
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
