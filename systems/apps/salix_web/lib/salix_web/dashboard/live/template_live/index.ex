defmodule SalixWeb.Dashboard.TemplateLive.Index do
  @moduledoc "Bounded model catalog for platform and tenant template administration."
  use SalixWeb.Dashboard, :live_view

  alias SalixAgent.{Templates, AgentDefaults, ModelPresentation}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       active_nav: :templates,
       page_title: "Model catalog",
       breadcrumbs: [{"Model catalog", nil}],
       query: "",
       global_cursor: nil
     )
     |> load()}
  end

  defp load(socket) do
    with {:ok, global} <- Templates.list_admin_page(socket.assigns.global_cursor),
         {:ok, private} <- Templates.list_private(socket.assigns.current_tenant),
         {:ok, defaults} <- AgentDefaults.platform() do
      assign(socket,
        templates: global.templates ++ private,
        next_global_cursor: global.next_cursor,
        defaults: defaults,
        catalog_error: nil
      )
    else
      {:error, _} ->
        assign(socket,
          templates: [],
          next_global_cursor: nil,
          defaults: %{},
          catalog_error: "The model catalog is unavailable. Check storage access, then retry."
        )
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket),
    do: {:noreply, assign(socket, query: query)}

  def handle_event("retry", _, socket), do: {:noreply, load(socket)}

  def handle_event("next-global", _, %{assigns: %{next_global_cursor: next}} = socket)
      when is_binary(next),
      do: {:noreply, socket |> assign(global_cursor: next, query: "") |> load()}

  def handle_event("next-global", _, socket), do: {:noreply, socket}

  def handle_event("first-global", _, socket),
    do: {:noreply, socket |> assign(global_cursor: nil, query: "") |> load()}

  def handle_event("delete", %{"id" => id}, socket) do
    result =
      if SalixStore.Ids.valid_private_template_id?(id),
        do: Templates.delete_private(id, socket.assigns.current_tenant),
        else: Templates.delete(id)

    case result do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Template deleted.") |> load()}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not delete this template. Check whether it is selected by an Agent or a default."
         )}
    end
  end

  defp filtered(templates, query, private) do
    Enum.filter(templates, fn t ->
      not is_nil(t["tenant_id"]) == private and t["template_id"] != "default" and
        String.contains?(
          String.downcase(Enum.join([t["name"], t["model"], ModelPresentation.name(t)], " ")),
          String.downcase(query)
        )
    end)
  end

  defp source(t) do
    case get_in(t, ["provider_config", "account_pool"]) do
      "codex" -> "Codex subscription"
      "claude" -> "Claude subscription"
      _ -> "API connection"
    end
  end

  defp edit_path(t),
    do: "/dash/templates/#{t["template_id"]}" <> if(t["tenant_id"], do: "?scope=tenant", else: "")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-8">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div><h1 class="text-2xl font-semibold tracking-tight">Model catalog</h1><p class="mt-2 text-sm text-neutral-500">Configure the models that Agents can use. Users see model names, not configuration aliases.</p></div>
        <.button variant="primary" navigate="/dash/templates/new"><.icon name="plus" class="h-4 w-4" /> Add model configuration</.button>
      </div>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <form id="catalog-search-form" phx-change="search" class="w-full sm:max-w-sm"><.input id="catalog-search" name="query" label="Search configurations" hint="Searches the current catalog page." value={@query} phx-debounce="200" placeholder="Model name, ID, or alias" /></form>
        <.link navigate="/dash/agent-defaults" class="text-sm text-brand-600">Manage Router and Worker defaults →</.link>
      </div>
      <div :if={@catalog_error} role="alert" class="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm"><p>{@catalog_error}</p><.button type="button" phx-click="retry">Retry</.button></div>
      <section :for={{label, private} <- [{"Platform billing", false}, {"BYOK", true}]} id={if private, do: "private-catalog", else: "platform-catalog"} phx-hook={if !private, do: "CatalogPage"} data-cursor={if !private, do: @global_cursor || "first"} class="space-y-4">
        <div><h2 class="text-lg font-semibold">{label}</h2><p class="mt-1 text-xs text-neutral-500">{if private, do: "Current tenant · Private API and subscription configurations", else: "Global · Available across tenants"}</p></div>
        <.table id={if private, do: "private-templates", else: "global-templates"} rows={filtered(@templates, @query, private)}>
          <:col :let={t} label="Model">
            <div class="flex items-center gap-3"><.model_icon brand={ModelPresentation.public(t)["model_icon"]} /><div><.link navigate={edit_path(t)} class="font-medium hover:underline">{ModelPresentation.name(t)}</.link><p class="mt-1 break-all text-xs text-neutral-500">{t["model"]}</p></div></div>
          </:col>
          <:col :let={t} label="Configuration alias">{t["name"]}</:col>
          <:col :let={t} label="Source">{source(t)}</:col>
          <:col :let={t} label="Catalog status">
            <div class="flex flex-wrap gap-2 text-xs">
              <span class="rounded bg-neutral-100 px-2 py-1">{if t["hidden"], do: "Hidden", else: "Visible"}</span>
              <span :for={role <- ~w(router worker)} :if={@defaults[role <> "_template_id"] == t["template_id"]} class="rounded bg-blue-50 px-2 py-1 text-blue-700">{String.capitalize(role)} default</span>
            </div>
          </:col>
          <:action :let={t}>
            <div class="flex items-center gap-3"><.link navigate={edit_path(t)} class="text-sm text-brand-600">Edit</.link><.dropdown id={"template-actions-" <> t["template_id"]} floating label={"More actions for " <> t["name"]}>
              <:trigger>More</:trigger>
              <button type="button" role="menuitem" phx-click="delete" phx-value-id={t["template_id"]} data-confirm={"Delete configuration “" <> t["name"] <> "”?"} class="block w-full px-3 py-2 text-left text-sm text-red-700 hover:bg-red-50 focus:bg-red-50 focus:outline-none">Delete</button>
            </.dropdown></div>
          </:action>
        </.table>
        <div :if={!private && (@global_cursor || @next_global_cursor)} class="flex items-center justify-between gap-3 text-sm">
          <span class="text-neutral-500">Up to 50 platform configurations per page.</span>
          <div class="flex gap-2"><.button :if={@global_cursor} type="button" phx-click="first-global">First page</.button><.button :if={@next_global_cursor} type="button" phx-click="next-global">Next page</.button></div>
        </div>
        <p :if={!@catalog_error && filtered(@templates, @query, private) == []} class="rounded-lg border border-dashed border-neutral-200 p-6 text-sm text-neutral-500">{if @query == "", do: "No model configurations in this section.", else: "No matching configurations."}</p>
      </section>
      <details id="system-fallback" phx-hook="PersistentDetails" :if={Enum.any?(@templates, &(&1["template_id"] == "default"))} class="rounded-lg border border-neutral-200 p-4 text-sm">
        <summary class="cursor-pointer font-medium">System fallback</summary>
        <p class="mt-3 text-neutral-500">The built-in default template is used when a platform role has no configured template. It is not an extra model choice.</p>
        <.link navigate="/dash/templates/default" class="mt-3 inline-block text-brand-600">Inspect fallback configuration →</.link>
      </details>
    </div>
    """
  end
end
