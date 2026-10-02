defmodule BridgeForTeamsWeb.Dashboard.PluginComponents do
  @moduledoc false
  use BridgeForTeamsWeb.Dashboard, :html

  alias BridgeForTeams.Plugins
  alias BridgeForTeamsWeb.Dashboard.PluginForm
  import BridgeForTeamsWeb.Dashboard.BrandLogos, only: [brand_logo: 1]

  attr(:id, :string, required: true)
  attr(:definitions, :list, required: true)
  attr(:enablement_by_id, :map, default: %{})
  attr(:show_state, :boolean, default: false)
  attr(:can_toggle, :boolean, default: false)
  attr(:toggle_allowed, :any, default: nil)
  attr(:editable_scope, :string, default: nil)
  attr(:details_path, :any, default: nil)
  attr(:details_event, :string, default: "show_plugin_details")
  attr(:edit_event, :string, default: "edit_plugin")
  attr(:enable_event, :string, default: "enable_plugin")
  attr(:disable_event, :string, default: "disable_plugin")

  def plugin_list(assigns) do
    ~H"""
    <div id={@id} class="divide-y divide-neutral-200 border-y border-neutral-200">
      <div
        :for={definition <- @definitions}
        id={"#{@id}-#{definition["plugin_id"]}"}
        class="flex min-w-0 items-start gap-3 px-1 py-3 sm:px-2"
      >
        <div
          id={"plugin-icon-#{definition["plugin_id"]}"}
          data-plugin-icon={plugin_icon_key(definition)}
          class="mt-0.5 grid h-8 w-8 shrink-0 place-items-center rounded-md bg-neutral-100 text-neutral-500"
        >
          <.brand_logo
            :if={plugin_brand(definition)}
            name={plugin_brand(definition)}
            class="h-4 w-4"
          />
          <.icon :if={is_nil(plugin_brand(definition))} name={plugin_icon(definition)} class="h-4 w-4" />
        </div>

        <div class="min-w-0 flex-1">
          <.link
            :if={@details_path}
            navigate={@details_path.(definition)}
            class="max-w-full text-left text-sm font-medium text-neutral-900 hover:text-brand-600"
          >
            {definition["name"] || definition["plugin_id"]}
          </.link>
          <button
            :if={is_nil(@details_path)}
            type="button"
            class="max-w-full text-left text-sm font-medium text-neutral-900 hover:text-brand-600"
            phx-click={@details_event}
            phx-value-id={definition["plugin_id"]}
          >
            {definition["name"] || definition["plugin_id"]}
          </button>
          <p class="mt-0.5 line-clamp-2 text-xs leading-5 text-neutral-500">
            {definition["description"] || gettext("No description")}
          </p>

          <div
            :if={setup_attention(definition) != []}
            class="mt-2 flex flex-wrap gap-1.5"
          >
            <span
              :for={name <- setup_attention(definition)}
              class="inline-flex items-center gap-1 rounded-md bg-amber-50 px-2 py-1 text-xs font-medium text-amber-700"
            >
              <.icon name="alert-triangle" class="h-3 w-3" />
              {gettext("%{name} needs setup", name: name)}
            </span>
          </div>

        </div>

        <div class="flex shrink-0 items-center gap-2 pt-0.5">
          <.plugin_state_control
            :if={@show_state}
            definition={definition}
            enablement_by_id={@enablement_by_id}
            can_toggle={@can_toggle && toggle_allowed?(@toggle_allowed, definition)}
            enable_event={@enable_event}
            disable_event={@disable_event}
          />
          <button
            :if={definition["owner_scope"] == @editable_scope and definition["read_only"] != true}
            type="button"
            class="grid h-8 w-8 place-items-center rounded-md text-neutral-400 hover:bg-neutral-100 hover:text-neutral-800"
            title={gettext("Edit plugin")}
            aria-label={gettext("Edit %{name}", name: definition["name"] || definition["plugin_id"])}
            phx-click={@edit_event}
            phx-value-id={definition["plugin_id"]}
          >
            <.icon name="pencil" class="h-3.5 w-3.5" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp toggle_allowed?(nil, _definition), do: true
  defp toggle_allowed?(fun, definition) when is_function(fun, 1), do: fun.(definition)

  defp setup_attention(%{"setup_status" => status}) when is_map(status) do
    mcp_names =
      status
      |> Map.get("mcps", [])
      |> Enum.reject(&(&1["state"] in ~w(ready_on_use running degraded)))
      |> Enum.map(&(&1["alias"] || &1["mcp_id"] || gettext("MCP")))

    messaging_names =
      status
      |> Map.get("connections", [])
      |> Enum.filter(&(&1["kind"] == "im_connect" and &1["state"] not in ~w(connected external)))
      |> Enum.map(&(&1["label"] || &1["id"] || gettext("Messaging")))

    mcp_names ++ messaging_names
  end

  defp setup_attention(_definition), do: []

  defp plugin_brand(definition), do: get_in(definition, ["ui", "brand"])
  defp plugin_icon(definition), do: get_in(definition, ["ui", "icon"]) || "plug"
  defp plugin_icon_key(definition), do: plugin_brand(definition) || plugin_icon(definition)

  attr(:definition, :map, required: true)
  attr(:enablement_by_id, :map, required: true)
  attr(:can_toggle, :boolean, required: true)
  attr(:enable_event, :string, required: true)
  attr(:disable_event, :string, required: true)

  def plugin_state_control(assigns) do
    assigns =
      assign(assigns, :enabled, Plugins.enabled?(assigns.definition, assigns.enablement_by_id))

    ~H"""
    <div class="flex items-center gap-1">
      <span class={["text-xs", @definition["locked"] == true && "font-medium text-neutral-600", @definition["locked"] != true && "text-neutral-500"]}>
        <%= cond do %>
          <% @definition["locked"] == true -> %>
            {gettext("Enabled")}
          <% @enabled -> %>
            {gettext("Enabled")}
          <% true -> %>
            {gettext("Disabled")}
        <% end %>
      </span>
      <button
        type="button"
        role="switch"
        aria-checked={to_string(@definition["locked"] == true or @enabled)}
        aria-label={
          if @definition["locked"] == true,
            do: gettext("%{name} is required", name: @definition["name"]),
            else:
              if(@enabled,
                do: gettext("Disable %{name}", name: @definition["name"]),
                else: gettext("Enable %{name}", name: @definition["name"])
              )
        }
        disabled={@definition["locked"] == true or not @can_toggle}
        phx-click={if @enabled, do: @disable_event, else: @enable_event}
        phx-value-id={@definition["plugin_id"]}
        class={[
          "grid h-11 w-11 shrink-0 place-items-center rounded-md focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-1 phx-click-loading:pointer-events-none phx-click-loading:opacity-50",
          @definition["locked"] == true && "cursor-not-allowed",
          @definition["locked"] != true and not @can_toggle && "cursor-not-allowed opacity-60"
        ]}
      >
        <span class={[
          "relative inline-flex h-5 w-9 rounded-full transition-colors",
          @definition["locked"] == true && "bg-neutral-500",
          @definition["locked"] != true and @enabled && "bg-brand-500",
          @definition["locked"] != true and not @enabled && "bg-neutral-300"
        ]}>
          <span
            class={[
              "pointer-events-none absolute top-0.5 h-4 w-4 rounded-full bg-white shadow-subtle transition-transform",
              (@definition["locked"] == true or @enabled) && "translate-x-[18px]",
              @definition["locked"] != true and not @enabled && "translate-x-0.5"
            ]}
          />
        </span>
      </button>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:panel, :map, required: true)
  attr(:form, :map, required: true)
  attr(:submit_event, :string, required: true)
  attr(:close_event, :string, required: true)
  attr(:error, :string, default: nil)

  def plugin_editor_drawer(assigns) do
    assigns =
      assigns
      |> assign(:form_id, "#{assigns.id}-form")
      |> assign(:refs_id, "#{assigns.id}-refs-#{panel_key(assigns.panel)}")

    ~H"""
    <.side_panel id={@id} show size="lg" on_cancel={JS.push(@close_event)}>
      <:title>{editor_title(@panel)}</:title>
      <form id={@form_id} phx-submit={@submit_event} class="space-y-5">
        <input :if={@panel.mode == :edit} type="hidden" name="plugin_id" value={@form["plugin_id"]} />
        <div
          :if={@error}
          role="alert"
          class="rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700"
        >
          {@error}
        </div>
        <div class="space-y-3">
          <.input name="name" label={gettext("Name")} value={@form["name"]} required />
          <.textarea
            name="description"
            label={gettext("Description")}
            value={@form["description"]}
            rows="3"
          />
          <.select
            name="setup_destination"
            label={gettext("Setup destination")}
            value={@form["setup_destination"]}
            options={PluginForm.setup_destination_options()}
            prompt={gettext("No setup link")}
          />
        </div>

        <div>
          <div class="mb-3">
            <h3 class="text-sm font-medium text-neutral-900">{gettext("Capabilities")}</h3>
            <p class="mt-0.5 text-xs text-neutral-500">
              {gettext("Group existing capabilities into this plugin. Add one reference at a time.")}
            </p>
          </div>
          <.plugin_refs_editor id={@refs_id} refs_json={PluginForm.refs_json(@form)} />
        </div>
      </form>
      <:footer>
        <.button type="button" phx-click={@close_event}>{gettext("Cancel")}</.button>
        <.button
          type="submit"
          form={@form_id}
          variant="primary"
          phx-disable-with={gettext("Saving...")}
        >
          {if @panel.mode == :edit, do: gettext("Save changes"), else: gettext("Create plugin")}
        </.button>
      </:footer>
    </.side_panel>
    """
  end

  attr(:id, :string, required: true)
  attr(:refs_json, :string, required: true)

  defp plugin_refs_editor(assigns) do
    assigns = assign(assigns, :ref_groups, localized_ref_groups())

    ~H"""
    <div
      id={@id}
      phx-hook="PluginRefsEditor"
      phx-update="ignore"
      data-refs={@refs_json}
      data-error-object-ref={gettext("Object refs must be JSON objects.")}
      data-error-invalid-json={gettext("Enter valid JSON.")}
      data-error-refs-object={gettext("Refs JSON must be an object.")}
      data-error-array={gettext("Each capability category must be an array.")}
      data-remove-label={gettext("Remove")}
      class="space-y-4"
    >
      <input type="hidden" name="refs_json" value={@refs_json} data-plugin-refs-output />
      <details
        :for={{key, label, help} <- @ref_groups}
        data-plugin-ref-group={key}
        open={initial_ref_entries(@refs_json, key) != []}
        class="rounded-md border border-neutral-200"
      >
        <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-3 py-2.5 marker:hidden">
          <span>
            <span class="block text-xs font-medium text-neutral-700">{label}</span>
            <span class="block text-xs text-neutral-500">{help}</span>
          </span>
          <.icon name="chevron-down" variant="outlined" class="h-4 w-4 shrink-0 text-neutral-400" />
        </summary>
        <div class="space-y-2 border-t border-neutral-200 p-3">
          <div data-plugin-ref-chips class="flex flex-wrap gap-1.5"></div>
          <div class="flex items-center gap-2">
            <input
              id={"#{@id}-#{key}"}
              type="text"
              data-plugin-ref-input
              autocomplete="off"
              placeholder={gettext("Capability reference")}
              class="block h-9 min-w-0 flex-1 rounded-md border border-neutral-300 bg-white px-3 text-sm text-neutral-900 placeholder:text-neutral-400 focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            />
            <button
              type="button"
              data-plugin-ref-add
              class="grid h-9 w-9 shrink-0 place-items-center rounded-md border border-neutral-300 text-neutral-600 hover:bg-neutral-50 hover:text-neutral-900"
              aria-label={gettext("Add %{type} reference", type: label)}
            >
              <.icon name="plus" class="h-4 w-4" />
            </button>
          </div>
        </div>
      </details>

      <details class="rounded-md border border-neutral-200">
        <summary class="cursor-pointer px-3 py-2 text-xs font-medium text-neutral-700">
          {gettext("Advanced JSON")}
        </summary>
        <div class="border-t border-neutral-200 p-3">
          <textarea
            data-plugin-refs-json
            aria-describedby={"#{@id}-json-error"}
            rows="10"
            spellcheck="false"
            class="block w-full resize-y rounded-md border border-neutral-300 bg-white px-3 py-2 font-mono text-xs text-neutral-800 focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          >{@refs_json}</textarea>
          <p
            id={"#{@id}-json-error"}
            data-plugin-refs-error
            role="alert"
            class="mt-1 hidden text-xs text-red-600"
          ></p>
        </div>
      </details>
    </div>
    """
  end

  defp editor_title(%{mode: :edit, plugin: plugin}),
    do: gettext("Edit %{name}", name: plugin["name"] || plugin["plugin_id"])

  defp editor_title(_panel), do: gettext("New project plugin")

  defp panel_key(%{mode: :edit, plugin: plugin}), do: "edit-#{plugin["plugin_id"]}"
  defp panel_key(panel), do: "#{panel.mode}-#{panel.owner_scope}"

  defp localized_ref_groups do
    [
      {"tool_refs", gettext("Tools"), gettext("Add a canonical tool id, then press Enter.")},
      {"skill_refs", gettext("Skills"), gettext("Add a skill id or wildcard, then press Enter.")},
      {"mcp_refs", gettext("MCP"),
       gettext("Add an MCP binding or capability ref, then press Enter.")},
      {"oauth_requirements", gettext("OAuth"),
       gettext("Add a provider or JSON requirement, then press Enter.")},
      {"im_connect_requirements", gettext("Messaging"),
       gettext("Add a provider or JSON requirement, then press Enter.")}
    ]
  end

  defp initial_ref_entries(refs_json, key) do
    case Jason.decode(refs_json) do
      {:ok, refs} when is_map(refs) -> refs |> Map.get(key, []) |> List.wrap()
      _ -> []
    end
  end
end
