defmodule BridgeForTeamsWeb.Dashboard.PluginLive.Index do
  @moduledoc """
  Org plugin catalog and tenant-owned plugin definition management.

  Group enablement is not handled here. It belongs to the Agent Swarm detail
  page because BFT projects map 1:1 to Salix groups.
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  alias BridgeForTeams.{Memberships, Orgs, Plugins, Projects}
  alias BridgeForTeamsWeb.Dashboard.PluginComponents
  alias BridgeForTeamsWeb.Dashboard.PluginForm

  @impl true
  def mount(%{"org" => slug}, _session, socket) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, org_role} <- Memberships.org_role(org.id, user.id) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Plugins"))
       |> assign(:active_nav, :plugins)
       |> assign(:current_org, org)
       |> assign(:current_org_role, org_role)
       |> assign(:can_manage, org_role in ["owner", "admin"])
       |> assign(:orgs, orgs)
       |> assign(:projects, Projects.list_projects_for_user(org.id, user.id))
       |> assign(:breadcrumbs, [{org.name, ~p"/orgs/#{org.slug}"}, {gettext("Plugins"), nil}])
       |> assign(:definitions, [])
       |> assign(:plugins_error, nil)
       |> assign(:plugin_catalog, "organization")
       |> assign(:plugin_query, "")
       |> assign(:plugin_panel, nil)
       |> assign(:plugin_panel_error, nil)
       |> assign(:plugin_form, PluginForm.empty_form())
       |> load_plugins()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Organization not found."))
         |> redirect(to: ~p"/orgs")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("set_plugin_catalog", %{"catalog" => catalog}, socket)
      when catalog in ["organization", "system"] do
    {:noreply, assign(socket, :plugin_catalog, catalog)}
  end

  def handle_event("filter_plugins", %{"query" => query}, socket) do
    {:noreply, assign(socket, :plugin_query, trim(query))}
  end

  def handle_event("clear_plugin_search", _params, socket) do
    {:noreply, assign(socket, :plugin_query, "")}
  end

  def handle_event("retry_plugins", _params, socket), do: {:noreply, load_plugins(socket)}

  def handle_event("new_plugin", _params, socket) do
    case require_org_admin(socket) do
      :ok ->
        {:noreply,
         socket
         |> assign(:plugin_panel, %{mode: :create, owner_scope: "tenant"})
         |> assign(:plugin_panel_error, nil)
         |> assign(:plugin_form, PluginForm.empty_form())}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, gettext("Only organization admins can manage plugins."))}
    end
  end

  def handle_event("show_plugin_details", %{"id" => plugin_id}, socket) do
    {:noreply, open_plugin_details(socket, plugin_id)}
  end

  def handle_event("edit_plugin", %{"id" => plugin_id}, socket) do
    with :ok <- require_org_admin(socket),
         plugin when not is_nil(plugin) <- find_plugin(socket.assigns.definitions, plugin_id),
         true <- editable_tenant_plugin?(plugin) do
      {:noreply,
       socket
       |> assign(:plugin_panel, %{mode: :edit, owner_scope: "tenant", plugin: plugin})
       |> assign(:plugin_panel_error, nil)
       |> assign(:plugin_form, PluginForm.form_for_definition(plugin))}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("This plugin cannot be edited here."))}
    end
  end

  def handle_event("close_plugin_panel", _params, socket) do
    {:noreply,
     socket
     |> assign(:plugin_panel, nil)
     |> assign(:plugin_panel_error, nil)
     |> assign(:plugin_form, PluginForm.empty_form())}
  end

  @impl true
  def handle_event("create_tenant_plugin", params, socket) do
    with :ok <- require_org_admin(socket),
         {:ok, attrs} <- PluginForm.parse_attrs(params),
         {:ok, definition} <-
           Plugins.create_tenant_definition(
             socket.assigns.current_org.id,
             attrs,
             audit_opts(socket)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Plugin created: %{id}.", id: definition["plugin_id"]))
       |> assign(:plugin_panel, nil)
       |> assign(:plugin_panel_error, nil)
       |> assign(:plugin_form, PluginForm.empty_form())
       |> load_plugins()}
    else
      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, gettext("Only organization admins can manage plugins."))}

      {:error, {:bad_request, message}} ->
        {:noreply, put_editor_error(socket, params, message)}

      {:error, :invalid_refs_json} ->
        {:noreply, put_editor_error(socket, params, gettext("Refs JSON must be an object."))}

      {:error, :invalid_setup_destination} ->
        {:noreply, put_editor_error(socket, params, gettext("Choose a valid setup destination."))}

      {:error, reason} ->
        {:noreply, put_editor_error(socket, params, plugin_error_message(reason))}
    end
  end

  def handle_event("update_tenant_plugin", params, socket) do
    with :ok <- require_org_admin(socket),
         plugin_id when plugin_id != "" <- trim(params["plugin_id"]),
         {:ok, attrs} <- PluginForm.parse_attrs(params, allow_blank_refs: true),
         {:ok, _definition} <-
           Plugins.update_tenant_definition(
             socket.assigns.current_org.id,
             plugin_id,
             attrs,
             audit_opts(socket)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Plugin updated."))
       |> assign(:plugin_panel, nil)
       |> assign(:plugin_panel_error, nil)
       |> assign(:plugin_form, PluginForm.empty_form())
       |> load_plugins()}
    else
      "" ->
        {:noreply, put_editor_error(socket, params, gettext("Plugin is required."))}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, gettext("Only organization admins can manage plugins."))}

      {:error, {:bad_request, message}} ->
        {:noreply, put_editor_error(socket, params, message)}

      {:error, :invalid_refs_json} ->
        {:noreply, put_editor_error(socket, params, gettext("Refs JSON must be an object."))}

      {:error, :invalid_setup_destination} ->
        {:noreply, put_editor_error(socket, params, gettext("Choose a valid setup destination."))}

      {:error, reason} ->
        {:noreply, put_editor_error(socket, params, plugin_error_message(reason))}
    end
  end

  defp load_plugins(socket) do
    case Plugins.list_org_plugins(socket.assigns.current_org.id,
           actor_user_id: socket.assigns.current_user.id
         ) do
      {:ok, %{definitions: definitions}} ->
        socket
        |> assign(:definitions, definitions)
        |> assign(:plugins_error, nil)

      {:error, reason} ->
        socket
        |> assign(:definitions, [])
        |> assign(:plugins_error, reason)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <% product_plugins = Enum.filter(@definitions, &Plugins.product_plugin?/1) %>
    <% visible_definitions =
      filtered_definitions(product_plugins, @plugin_catalog, @plugin_query) %>
    <% organization_count = count_scope(product_plugins, "tenant") %>
    <% system_count = count_scope(product_plugins, "system") %>
    <div class="space-y-5">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 class="text-lg font-semibold tracking-tight">{gettext("Plugins")}</h1>
          <p class="mt-1 max-w-2xl text-sm text-neutral-500">
            {gettext("Create product plugins here. Enable or disable them inside a specific Agent Swarm.")}
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.dropdown :if={@projects != []} id="org-plugin-swarm-menu" align="right">
            <:trigger>
              <.button>
                {gettext("Manage enablement")}
                <.icon name="chevron-down" variant="outlined" class="h-3.5 w-3.5" />
              </.button>
            </:trigger>
            <.dropdown_item
              :for={project <- @projects}
              navigate={~p"/orgs/#{@current_org.slug}/projects/#{project.id}/plugins"}
            >
              {project.name}
            </.dropdown_item>
          </.dropdown>
          <.button :if={@projects == []} navigate={~p"/orgs/#{@current_org.slug}/projects"}>
            {gettext("Manage enablement")}
          </.button>
          <.button :if={@can_manage} variant="primary" phx-click="new_plugin">
            <.icon name="plus" class="h-3.5 w-3.5" />
            {gettext("New organization plugin")}
          </.button>
        </div>
      </div>

      <.empty_state
        :if={@plugins_error}
        icon="plug"
        title={gettext("Plugins unavailable")}
        description={plugin_error_message(@plugins_error)}
      >
        <:actions>
          <.button phx-click="retry_plugins">{gettext("Retry")}</.button>
        </:actions>
      </.empty_state>

      <div :if={is_nil(@plugins_error)} class="space-y-4">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div
            class="inline-flex w-fit rounded-md bg-neutral-100 p-0.5"
            role="tablist"
            aria-label={gettext("Plugin catalog")}
          >
            <button
              type="button"
              role="tab"
              aria-selected={to_string(@plugin_catalog == "organization")}
              aria-controls="org-plugin-inventory"
              phx-click="set_plugin_catalog"
              phx-value-catalog="organization"
              class={catalog_button_class(@plugin_catalog == "organization")}
            >
              {gettext("Organization plugins")} <span class="text-neutral-400">{organization_count}</span>
            </button>
            <button
              type="button"
              role="tab"
              aria-selected={to_string(@plugin_catalog == "system")}
              aria-controls="org-plugin-inventory"
              phx-click="set_plugin_catalog"
              phx-value-catalog="system"
              class={catalog_button_class(@plugin_catalog == "system")}
            >
              {gettext("System catalog")} <span class="text-neutral-400">{system_count}</span>
            </button>
          </div>

          <form id="org-plugin-filter" phx-change="filter_plugins" class="relative w-full sm:max-w-xs">
            <.icon name="search" variant="outlined" class="pointer-events-none absolute left-2.5 top-2 h-4 w-4 text-neutral-400" />
            <input
              type="search"
              name="query"
              value={@plugin_query}
              phx-debounce="200"
              placeholder={gettext("Search plugins")}
              aria-label={gettext("Search plugins")}
              class="h-8 w-full rounded-md border border-neutral-300 bg-white pl-8 pr-3 text-sm text-neutral-900 placeholder:text-neutral-400 focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            />
          </form>
        </div>

        <p id="org-plugin-inventory" class="text-xs text-neutral-500">
          {if @plugin_catalog == "organization",
            do: gettext("Definitions owned by this organization and visible to its Agent Swarms."),
            else: gettext("Product integrations provided by Comma.")}
        </p>

        <PluginComponents.plugin_list
          :if={visible_definitions != []}
          id="org-plugin-definitions"
          definitions={visible_definitions}
          editable_scope={if @can_manage, do: "tenant", else: nil}
        />

        <.empty_state
          :if={visible_definitions == []}
          icon="plug"
          title={
            if @plugin_query == "",
              do: gettext("No plugins in this catalog"),
              else: gettext("No matching plugins")
          }
          description={
            if @plugin_catalog == "organization" and @can_manage and @plugin_query == "",
              do: gettext("Create the first plugin owned by this organization."),
              else: nil
          }
        >
          <:actions :if={@plugin_catalog == "organization" and @can_manage and @plugin_query == ""}>
            <.button variant="primary" phx-click="new_plugin">{gettext("New organization plugin")}</.button>
          </:actions>
          <:actions :if={@plugin_query != ""}>
            <.button phx-click="clear_plugin_search">{gettext("Clear search")}</.button>
          </:actions>
        </.empty_state>
      </div>

      <PluginComponents.plugin_editor_drawer
        :if={editor_panel?(@plugin_panel)}
        id="org-plugin-editor"
        panel={@plugin_panel}
        form={@plugin_form}
        submit_event={if @plugin_panel.mode == :edit, do: "update_tenant_plugin", else: "create_tenant_plugin"}
        close_event="close_plugin_panel"
        error={@plugin_panel_error}
      />

      <PluginComponents.plugin_details_drawer
        :if={details_panel?(@plugin_panel)}
        id="org-plugin-details"
        plugin={@plugin_panel.plugin}
        close_event="close_plugin_panel"
        edit_event="edit_plugin"
        editable={@can_manage and editable_tenant_plugin?(@plugin_panel.plugin)}
        setup_links={org_plugin_setup_links(@plugin_panel.plugin, @current_org)}
      />
    </div>
    """
  end

  defp org_plugin_setup_links(definition, org) do
    definition
    |> Plugins.setup_targets()
    |> Enum.map(fn
      "org_oauth" ->
        %{label: gettext("OAuth settings"), navigate: ~p"/orgs/#{org.slug}/settings/oauth"}

      "org_feishu" ->
        %{label: gettext("Feishu settings"), navigate: ~p"/orgs/#{org.slug}/settings/feishu"}

      "org_composio" ->
        %{label: gettext("Composio settings"), navigate: ~p"/orgs/#{org.slug}/settings/composio"}

      _project_target ->
        %{label: gettext("Set up in an Agent Swarm"), navigate: ~p"/orgs/#{org.slug}/projects"}
    end)
    |> Enum.uniq_by(&(&1[:navigate] || &1[:href]))
  end

  defp require_org_admin(%{assigns: %{can_manage: true}}), do: :ok
  defp require_org_admin(_socket), do: {:error, :forbidden}

  defp open_plugin_details(socket, plugin_id) do
    case find_plugin(socket.assigns.definitions, plugin_id) do
      nil ->
        put_flash(socket, :error, gettext("Plugin data was not found."))

      plugin ->
        socket
        |> assign(:plugin_panel, %{mode: :details, plugin: plugin})
        |> assign(:plugin_panel_error, nil)
    end
  end

  defp put_editor_error(socket, params, message) do
    socket
    |> assign(:plugin_form, PluginForm.form_from_params(params))
    |> assign(:plugin_panel_error, message)
  end

  defp find_plugin(definitions, plugin_id) do
    Enum.find(definitions, &(&1["plugin_id"] == trim(plugin_id)))
  end

  defp filtered_definitions(definitions, catalog, query) do
    owner_scope = if catalog == "system", do: "system", else: "tenant"
    query = query |> trim() |> String.downcase()

    definitions
    |> Enum.filter(&(&1["owner_scope"] == owner_scope))
    |> Enum.filter(fn definition ->
      query == "" or
        Enum.any?(
          [definition["name"], definition["description"], definition["plugin_id"]],
          fn value ->
            value |> trim() |> String.downcase() |> String.contains?(query)
          end
        )
    end)
  end

  defp count_scope(definitions, owner_scope),
    do: Enum.count(definitions, &(&1["owner_scope"] == owner_scope))

  defp catalog_button_class(active?) do
    [
      "h-7 rounded px-2.5 text-xs font-medium transition-colors",
      active? && "bg-white text-neutral-900 shadow-subtle",
      !active? && "text-neutral-500 hover:text-neutral-800"
    ]
  end

  defp editor_panel?(%{mode: mode}) when mode in [:create, :edit], do: true
  defp editor_panel?(_panel), do: false
  defp details_panel?(%{mode: :details}), do: true
  defp details_panel?(_panel), do: false

  defp editable_tenant_plugin?(%{"owner_scope" => "tenant"} = plugin),
    do: plugin["read_only"] != true

  defp editable_tenant_plugin?(_plugin), do: false

  defp plugin_error_message(:forbidden),
    do: gettext("You do not have permission to manage plugins.")

  defp plugin_error_message(:group_not_ready), do: gettext("Agent Swarm is still preparing.")
  defp plugin_error_message(:unavailable), do: gettext("Salix is unavailable. Retry shortly.")
  defp plugin_error_message(:timeout), do: gettext("Salix timed out. Retry shortly.")
  defp plugin_error_message(:not_found), do: gettext("Plugin data was not found.")
  defp plugin_error_message({:bad_request, message}) when is_binary(message), do: message
  defp plugin_error_message(_), do: gettext("Could not load plugins.")

  defp audit_opts(socket) do
    user = socket.assigns.current_user

    [
      actor_user_id: user.id,
      actor_label: audit_actor_label(user),
      request_id: Ecto.UUID.generate()
    ]
  end

  defp audit_actor_label(user) do
    cond do
      trim(user.email) != "" -> trim(user.email)
      trim(user.name) != "" -> trim(user.name)
      true -> user.id
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
