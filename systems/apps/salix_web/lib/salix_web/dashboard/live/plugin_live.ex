defmodule SalixWeb.Dashboard.PluginLive do
  @moduledoc "Plugin definition and group enablement management."
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.{Groups, Plugins}
  alias SalixWeb.Dashboard.Format

  @default_refs_json Jason.encode!(
                       %{
                         "tool_refs" => [],
                         "skill_refs" => [],
                         "mcp_refs" => [],
                         "oauth_requirements" => [],
                         "im_connect_requirements" => []
                       },
                       pretty: true
                     )

  @impl true
  def mount(_params, _session, socket) do
    groups = Groups.list(socket.assigns.current_tenant)
    selected_group = groups |> List.first() |> then(&(&1 && &1["group_id"]))

    {:ok,
     socket
     |> assign(
       active_nav: :plugins,
       page_title: "Plugins",
       breadcrumbs: [{"Plugins", nil}],
       groups: groups,
       selected_group: selected_group,
       definition_form: %{"owner_scope" => "group", "refs_json" => @default_refs_json},
       refs_form: %{"plugin_id" => "", "refs_json" => @default_refs_json}
     )
     |> load()}
  end

  defp load(socket) do
    group_id = socket.assigns.selected_group

    if group_id do
      case plugin_page(socket.assigns.current_tenant, group_id) do
        {:ok, page} ->
          assign(socket,
            definitions: page.definitions,
            enablements: page.enablements,
            projection: page.projection,
            enablement_by_id: Map.new(page.enablements, &{&1["plugin_id"], &1})
          )

        {:error, reason} ->
          socket
          |> assign(
            definitions: [],
            enablements: [],
            projection: %{},
            enablement_by_id: %{}
          )
          |> put_flash(:error, "Load failed: #{inspect(reason)}")
      end
    else
      assign(socket,
        definitions: [],
        enablements: [],
        projection: %{},
        enablement_by_id: %{}
      )
    end
  end

  defp plugin_page(tenant_id, group_id) do
    with {:ok, _group} <- Groups.get(group_id, tenant_id),
         {:ok, definitions} <- Plugins.list_definitions(tenant_id, group_id),
         {:ok, enablements} <- Plugins.list_group_enablements(tenant_id, group_id),
         {:ok, projection} <-
           Plugins.runtime_projection(%{"tenant_id" => tenant_id, "group_id" => group_id}) do
      {:ok, %{definitions: definitions, enablements: enablements, projection: projection}}
    end
  end

  @impl true
  def handle_event("select-group", %{"group_id" => group_id}, socket) do
    if group_id_valid?(socket, group_id) do
      {:noreply, socket |> assign(selected_group: group_id) |> load()}
    else
      {:noreply, put_flash(socket, :error, "Selected group is not available for this tenant.")}
    end
  end

  def handle_event("create-definition", params, socket) do
    with {:ok, group_id} <- current_group_id(socket),
         {:ok, attrs} <- definition_attrs(params),
         {:ok, definition} <-
           Plugins.create_definition(socket.assigns.current_tenant, group_id, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, "Plugin definition created: #{definition["plugin_id"]}.")
       |> load()}
    else
      {:error, :missing_group} ->
        {:noreply, put_flash(socket, :error, "Select a group first.")}

      {:error, :invalid_group} ->
        {:noreply, put_flash(socket, :error, "Selected group is not available for this tenant.")}

      {:error, {:bad_request, message}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, :exists} ->
        {:noreply, put_flash(socket, :error, "Plugin id is already visible to this group.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  def handle_event("put-refs", params, socket) do
    with {:ok, group_id} <- current_group_id(socket),
         plugin_id when plugin_id != "" <- trim(params["plugin_id"]),
         {:ok, refs} <- decode_json_object(params["refs_json"] || "{}"),
         {:ok, _definition} <-
           Plugins.put_refs(socket.assigns.current_tenant, group_id, plugin_id, refs) do
      {:noreply, socket |> put_flash(:info, "Plugin refs saved.") |> load()}
    else
      "" ->
        {:noreply, put_flash(socket, :error, "Plugin id is required.")}

      {:error, :missing_group} ->
        {:noreply, put_flash(socket, :error, "Select a group first.")}

      {:error, :invalid_group} ->
        {:noreply, put_flash(socket, :error, "Selected group is not available for this tenant.")}

      {:error, {:bad_request, message}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Editable group plugin not found.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("enable", %{"id" => plugin_id}, socket) do
    mutate_enablement(socket, plugin_id, true, "Plugin enabled.")
  end

  def handle_event("disable", %{"id" => plugin_id}, socket) do
    mutate_enablement(socket, plugin_id, false, "Plugin disabled.")
  end

  defp mutate_enablement(socket, plugin_id, enabled?, message) do
    with {:ok, group_id} <- current_group_id(socket) do
      result =
        if enabled? do
          Plugins.enable_group(socket.assigns.current_tenant, group_id, plugin_id)
        else
          Plugins.disable_group(socket.assigns.current_tenant, group_id, plugin_id)
        end

      case result do
        {:ok, _enablement} ->
          {:noreply, socket |> put_flash(:info, message) |> load()}

        {:error, {:bad_request, msg}} ->
          {:noreply, put_flash(socket, :error, msg)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Operation failed: #{inspect(reason)}")}
      end
    else
      {:error, :missing_group} ->
        {:noreply, put_flash(socket, :error, "Select a group first.")}

      {:error, :invalid_group} ->
        {:noreply, put_flash(socket, :error, "Selected group is not available for this tenant.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 class="text-xl font-semibold">Plugins</h1>
          <p class="text-sm text-neutral-500">Feature packages and group runtime enablement.</p>
        </div>
        <form id="plugin-group-selector" phx-change="select-group" class="w-72">
          <.select name="group_id" label="Group" value={@selected_group} options={group_options(@groups)} />
        </form>
      </div>

      <div class="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <.card>
          <:title>Create plugin</:title>
          <form id="plugin-create-form" phx-submit="create-definition" class="space-y-3">
            <.input name="name" label="Name" required />
            <.input name="description" label="Description" />
            <.select
              name="owner_scope"
              label="Owner scope"
              value={@definition_form["owner_scope"]}
              options={[{"Group", "group"}, {"Tenant", "tenant"}]}
            />
            <.textarea name="refs_json" label="Refs JSON" value={@definition_form["refs_json"]} rows="8" />
            <.button type="submit" variant="primary" disabled={is_nil(@selected_group)}>Create plugin</.button>
          </form>
        </.card>

        <.card>
          <:title>Replace plugin refs</:title>
          <form id="plugin-refs-form" phx-submit="put-refs" class="space-y-3">
            <.input name="plugin_id" label="Plugin ID" />
            <.textarea name="refs_json" label="Refs JSON" value={@refs_form["refs_json"]} rows="8" />
            <.button type="submit" variant="primary" disabled={is_nil(@selected_group)}>Save refs</.button>
          </form>
        </.card>
      </div>

      <.card>
        <:title>Definitions</:title>
        <:actions>
          <.badge color="neutral">revision {short_revision(@projection["revision"])}</.badge>
        </:actions>
        <.table :if={@definitions != []} id="plugin-definitions" rows={@definitions}>
          <:col :let={row} label="Plugin">
            {row["name"]}
            <div class="font-mono text-xs text-neutral-500">{row["plugin_id"]}</div>
          </:col>
          <:col :let={row} label="Scope">
            {row["owner_scope"]}
            <div :if={row["read_only"] == true} class="text-xs text-neutral-500">read-only</div>
          </:col>
           <:col :let={row} label="State">
             <.badge color={state_color(row, @enablement_by_id)}>
               {state_label(row, @enablement_by_id)}
             </.badge>
           </:col>
          <:col :let={row} label="Refs">
            <div class="max-w-md text-xs text-neutral-600">{refs_summary(row["refs"])}</div>
          </:col>
          <:col :let={row} label="Updated">{Format.time_ago(ts(row["updated_at"]))}</:col>
          <:action :let={row}>
            <.button
              :if={row["locked"] != true and not enabled?(row, @enablement_by_id)}
              size="sm"
              phx-click="enable"
              phx-value-id={row["plugin_id"]}
            >
              Enable
            </.button>
            <.button
              :if={row["locked"] != true and enabled?(row, @enablement_by_id)}
              size="sm"
              variant="danger"
              phx-click="disable"
              phx-value-id={row["plugin_id"]}
            >
              Disable
            </.button>
          </:action>
        </.table>
        <.empty_state :if={@definitions == []} icon="plug" title="No plugin definitions" />
      </.card>

       <.card>
         <:title>Related setup</:title>
         <:actions>
           <.button size="sm" navigate="/dash/oauth">OAuth</.button>
           <.button size="sm" navigate="/dash/mcp">MCP</.button>
           <.button size="sm" navigate="/dash/im">IM</.button>
           <.button size="sm" navigate="/dash/environments">Devices</.button>
         </:actions>
         <p class="text-sm text-neutral-600">
           Plugins expose feature refs and group enablement. Configuration, authorization,
           connection and runtime status stay on the owning pages.
         </p>
       </.card>
    </div>
    """
  end

  defp definition_attrs(params) do
    with {:ok, refs} <- decode_json_object(params["refs_json"] || "{}") do
      {:ok,
       %{
         "owner_scope" => trim(params["owner_scope"]),
         "name" => trim(params["name"]),
         "description" => trim(params["description"]),
         "refs" => refs
       }}
    end
  end

  defp current_group_id(socket) do
    case socket.assigns.selected_group do
      group_id when is_binary(group_id) and group_id != "" ->
        if group_id_valid?(socket, group_id), do: {:ok, group_id}, else: {:error, :invalid_group}

      _ ->
        {:error, :missing_group}
    end
  end

  defp group_id_valid?(socket, group_id) when is_binary(group_id) do
    Enum.any?(socket.assigns.groups, &(&1["group_id"] == group_id))
  end

  defp group_id_valid?(_socket, _group_id), do: false

  defp group_options(groups) do
    Enum.map(groups, fn group -> {group["name"] || group["group_id"], group["group_id"]} end)
  end

  defp enabled?(definition, enablements),
    do: Plugins.effective_enabled?(definition, enablements)

  defp state_label(%{"locked" => true}, _enablements), do: "locked"

  defp state_label(definition, enablements),
    do: if(enabled?(definition, enablements), do: "enabled", else: "disabled")

  defp state_color(%{"locked" => true}, _enablements), do: "brand"

  defp state_color(definition, enablements),
    do: if(enabled?(definition, enablements), do: "green", else: "neutral")

  defp refs_summary(refs) when is_map(refs) do
    refs
    |> Enum.map(fn {key, values} -> "#{key}: #{length(List.wrap(values))}" end)
    |> Enum.sort()
    |> Enum.join(" / ")
    |> case do
      "" -> "No refs"
      summary -> summary
    end
  end

  defp refs_summary(_refs), do: "No refs"

  defp short_revision(nil), do: "none"
  defp short_revision(revision) when is_binary(revision), do: String.slice(revision, 0, 10)
  defp short_revision(revision), do: revision |> to_string() |> String.slice(0, 10)

  defp decode_json_object(json) do
    case Jason.decode(json || "") do
      {:ok, %{} = value} -> {:ok, value}
      {:ok, _} -> {:error, {:bad_request, "JSON must be an object."}}
      {:error, error} -> {:error, {:bad_request, "Invalid JSON: #{Exception.message(error)}"}}
    end
  end

  defp ts(value) when is_binary(value), do: DateTime.from_iso8601(value) |> elem_or_nil()
  defp ts(_), do: nil

  defp elem_or_nil({:ok, dt, _offset}), do: dt
  defp elem_or_nil(_), do: nil

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
