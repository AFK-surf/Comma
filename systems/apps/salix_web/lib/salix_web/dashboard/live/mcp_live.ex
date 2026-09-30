defmodule SalixWeb.Dashboard.MCPLive do
  @moduledoc "MCP definition and group binding management."
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.Groups
  alias SalixWeb.Dashboard.Format

  @impl true
  def mount(_params, _session, socket) do
    groups = Groups.list(socket.assigns.current_tenant)
    selected_group = groups |> List.first() |> then(&(&1 && &1["group_id"]))

    {:ok,
     socket
     |> assign(
       active_nav: :mcp,
       page_title: "MCP",
       breadcrumbs: [{"MCP", nil}],
       groups: groups,
       selected_group: selected_group,
       definition_form: %{"install_json" => ""},
       binding_form: %{
         "binding_id" => "",
         "mcp_id" => "",
         "alias" => "",
         "target_ref" => "",
         "placement" => "server",
         "device_runtime_id" => "",
         "config_values_json" => "{}",
         "oauth_binding_refs_json" => "{}",
         "root_grants_json" => "[]"
       },
       authorization_action: nil
     )
     |> load()}
  end

  defp load(socket) do
    group_id = socket.assigns.selected_group

    assign(socket,
      definitions: SalixMCP.Store.list_definitions(socket.assigns.current_tenant),
      bindings:
        if(group_id,
          do: SalixMCP.Store.list_group_bindings(socket.assigns.current_tenant, group_id),
          else: []
        )
    )
  end

  @impl true
  def handle_event("select-group", %{"group_id" => group_id}, socket) do
    if group_id_valid?(socket, group_id) do
      {:noreply, socket |> assign(selected_group: group_id) |> load()}
    else
      {:noreply, put_flash(socket, :error, "Selected group is not available for this tenant.")}
    end
  end

  def handle_event("create-definition", %{"install_json" => json} = params, socket) do
    attrs =
      case Jason.decode(json || "") do
        {:ok, %{} = decoded} -> Map.merge(Map.take(params, ["mcp_id"]), decoded)
        _ -> Map.drop(params, ["install_json"])
      end

    case create_or_update_definition(socket.assigns.current_tenant, attrs) do
      {:ok, _definition} ->
        {:noreply, socket |> put_flash(:info, "MCP definition saved.") |> load()}

      {:error, {:bad_request, message}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  def handle_event("create-binding", params, socket) do
    with {:ok, group_id} <- current_group_id(socket),
         {:ok, attrs} <- binding_attrs(params),
         {:ok, _binding} <-
           create_or_update_binding(socket.assigns.current_tenant, group_id, attrs) do
      {:noreply, socket |> put_flash(:info, "MCP binding saved.") |> load()}
    else
      {:error, :missing_group} ->
        {:noreply, put_flash(socket, :error, "Select a group first.")}

      {:error, :invalid_group} ->
        {:noreply, put_flash(socket, :error, "Selected group is not available for this tenant.")}

      {:error, {:bad_request, message}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  def handle_event("enable", %{"id" => binding_id}, socket) do
    mutate_binding(
      socket,
      fn group_id ->
        SalixMCP.Gateway.set_binding_enabled(
          socket.assigns.current_tenant,
          group_id,
          binding_id,
          true
        )
      end,
      "Binding enabled."
    )
  end

  def handle_event("disable", %{"id" => binding_id}, socket) do
    mutate_binding(
      socket,
      fn group_id ->
        SalixMCP.Gateway.set_binding_enabled(
          socket.assigns.current_tenant,
          group_id,
          binding_id,
          false
        )
      end,
      "Binding disabled."
    )
  end

  def handle_event("discover", %{"id" => binding_id}, socket) do
    mutate_binding(
      socket,
      fn group_id ->
        SalixMCP.Gateway.refresh_binding(socket.assigns.current_tenant, group_id, binding_id)
      end,
      "Discovery refreshed."
    )
  end

  def handle_event("authorize", %{"id" => binding_id}, socket) do
    with {:ok, group_id} <- current_group_id(socket) do
      case Salix.Control.RemoteMCPOAuth.start_authorization(
             socket.assigns.current_tenant,
             group_id,
             binding_id,
             %{}
           ) do
        {:ok, auth} ->
          {:noreply,
           socket
           |> assign(authorization_action: auth)
           |> put_flash(:info, "Open the authorization link to connect this MCP binding.")
           |> load()}

        {:error, {:bad_request, message}} ->
          {:noreply, put_flash(socket, :error, message)}

        {:error, {:precondition_failed, message}} ->
          {:noreply, put_flash(socket, :error, message)}

        {:error, {:missing_oauth_client, message}} ->
          {:noreply, put_flash(socket, :error, message)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Authorization failed: #{inspect(reason)}")}
      end
    else
      {:error, :missing_group} ->
        {:noreply, put_flash(socket, :error, "Select a group first.")}

      {:error, :invalid_group} ->
        {:noreply, put_flash(socket, :error, "Selected group is not available for this tenant.")}
    end
  end

  def handle_event("restart", %{"id" => binding_id}, socket) do
    mutate_binding(
      socket,
      fn group_id ->
        SalixMCP.Gateway.restart_binding(socket.assigns.current_tenant, group_id, binding_id)
      end,
      "Connection restarted."
    )
  end

  def handle_event("reconnect", %{"id" => binding_id}, socket) do
    mutate_binding(
      socket,
      fn group_id ->
        SalixMCP.Gateway.restart_binding(socket.assigns.current_tenant, group_id, binding_id)
      end,
      "Connection reconnected."
    )
  end

  def handle_event("stop", %{"id" => binding_id}, socket) do
    mutate_binding(
      socket,
      fn group_id ->
        SalixMCP.Gateway.stop_binding(socket.assigns.current_tenant, group_id, binding_id)
      end,
      "Connection stopped."
    )
  end

  defp mutate_binding(socket, fun, ok_message) do
    with {:ok, group_id} <- current_group_id(socket),
         result <- fun.(group_id) do
      case result do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, ok_message) |> load()}

        {:error, {:bad_request, message}} ->
          {:noreply, put_flash(socket, :error, message)}

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 class="text-xl font-semibold">MCP</h1>
          <p class="text-sm text-neutral-500">Definitions are reusable; bindings are group-scoped runtime entries.</p>
        </div>
        <form phx-change="select-group" class="w-72">
          <.select name="group_id" label="Group" value={@selected_group} options={group_options(@groups)} />
        </form>
      </div>

      <div class="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <.card>
          <:title>Create definition</:title>
          <form phx-submit="create-definition" class="space-y-3">
            <.input name="mcp_id" label="MCP ID to update" value="" />
            <.textarea
              name="install_json"
              label="Install JSON"
              value={@definition_form["install_json"]}
              placeholder={~s({"mcpServers":{"playwright":{"command":"npx","args":["@playwright/mcp@latest"]}}})}
            />
            <.button type="submit" variant="primary">Create definition</.button>
          </form>
        </.card>

        <.card>
          <:title>Create group binding</:title>
          <form phx-submit="create-binding" class="grid grid-cols-1 gap-3 md:grid-cols-2">
            <.input name="binding_id" label="Binding ID to update" value={@binding_form["binding_id"]} />
            <.input name="mcp_id" label="MCP ID" value={@binding_form["mcp_id"]} />
            <.input name="alias" label="Alias" value={@binding_form["alias"]} />
            <.input name="target_ref" label="Target ref" value={@binding_form["target_ref"]} />
            <.select name="placement" label="Placement" value="server" options={[{"server", "server"}, {"device", "device"}]} />
            <.input name="device_runtime_id" label="Device runtime ID" value={@binding_form["device_runtime_id"]} />
            <.textarea
              name="config_values_json"
              label="Config values JSON"
              value={@binding_form["config_values_json"]}
            />
            <.textarea
              name="oauth_binding_refs_json"
              label="OAuth refs JSON"
              value={@binding_form["oauth_binding_refs_json"]}
              placeholder={~s({"GITHUB_TOKEN":{"provider":"github","alias":"default","credential":"access_token"}})}
            />
            <.textarea
              name="root_grants_json"
              label="Root grants JSON"
              value={@binding_form["root_grants_json"]}
              placeholder={~s(["/Users/me/project"])}
            />
            <div class="md:col-span-2">
              <.button type="submit" variant="primary" disabled={is_nil(@selected_group)}>Save binding</.button>
            </div>
          </form>
        </.card>
      </div>

      <.card>
        <:title>Definitions</:title>
        <.table :if={@definitions != []} id="mcp-definitions" rows={@definitions}>
          <:col :let={row} label="Name">
            {row["name"]}
            <div class="font-mono text-xs text-neutral-500">{row["mcp_id"]}</div>
          </:col>
          <:col :let={row} label="Server support">{inspect(row["supports_server"])}</:col>
          <:col :let={row} label="Targets">
            <div class="font-mono text-xs">{target_refs(row) || "—"}</div>
          </:col>
          <:col :let={row} label="Updated">{Format.time_ago(ts(row["updated_at"]))}</:col>
        </.table>
        <.empty_state :if={@definitions == []} icon="plug" title="No MCP definitions" />
      </.card>

      <.card>
        <:title>Bindings</:title>
        <div
          :if={@authorization_action}
          class="mb-3 rounded border border-blue-200 bg-blue-50 p-3 text-sm text-blue-950"
        >
          <div class="font-medium">MCP authorization ready</div>
          <a
            class="break-all font-mono text-xs underline"
            href={@authorization_action["authorization_url"]}
            target="_blank"
            rel="noopener noreferrer"
          >
            {@authorization_action["authorization_url"]}
          </a>
        </div>
        <.table :if={@bindings != []} id="mcp-bindings" rows={@bindings}>
          <:col :let={row} label="Binding">
            {row["alias"]}
            <div class="font-mono text-xs text-neutral-500">{row["binding_id"]}</div>
          </:col>
          <:col :let={row} label="MCP"><span class="font-mono text-xs">{row["mcp_id"]}</span></:col>
          <:col :let={row} label="Placement">
            {row["placement"]}
            <div class="text-xs text-neutral-500">{profile_summary(row["execution_profile"])}</div>
            <div :if={row["device_runtime_id"]} class="font-mono text-xs text-neutral-500">{row["device_runtime_id"]}</div>
          </:col>
          <:col :let={row} label="Status">
            <.status_pill status={get_in(row, ["connection", "status"]) || row["status"] || "configured"} />
            <div :if={get_in(row, ["connection", "last_error"])} class="mt-1 max-w-sm truncate text-xs text-red-600">
              {inspect(get_in(row, ["connection", "last_error"]))}
            </div>
          </:col>
          <:col :let={row} label="Discovered">
            {discovery_count(row, "tools")} tools /
            {discovery_count(row, "resources")} resources /
            {discovery_count(row, "prompts")} prompts
          </:col>
          <:action :let={row}>
            <.button size="sm" phx-click="discover" phx-value-id={row["binding_id"]}>Discover</.button>
            <.button
              :if={oauth_actionable?(row)}
              size="sm"
              phx-click="authorize"
              phx-value-id={row["binding_id"]}
            >
              Authorize
            </.button>
            <.button size="sm" phx-click="restart" phx-value-id={row["binding_id"]}>Restart</.button>
            <.button size="sm" phx-click="reconnect" phx-value-id={row["binding_id"]}>Reconnect</.button>
            <.button size="sm" phx-click="stop" phx-value-id={row["binding_id"]}>Stop</.button>
            <.button
              :if={row["enabled"] == false}
              size="sm"
              phx-click="enable"
              phx-value-id={row["binding_id"]}
            >
              Enable
            </.button>
            <.button
              :if={row["enabled"] != false}
              size="sm"
              variant="danger"
              phx-click="disable"
              phx-value-id={row["binding_id"]}
            >
              Disable
            </.button>
          </:action>
        </.table>
        <.empty_state :if={@bindings == []} icon="plug" title="No MCP bindings" />
      </.card>
    </div>
    """
  end

  defp binding_attrs(params) do
    with {:ok, config_values} <- decode_json_object(params["config_values_json"] || "{}"),
         {:ok, oauth_refs} <- decode_json_object(params["oauth_binding_refs_json"] || "{}"),
         {:ok, root_grants} <- decode_json_list(params["root_grants_json"] || "[]") do
      {:ok,
       params
       |> Map.take(~w(binding_id mcp_id alias target_ref placement device_runtime_id))
       |> Map.put("config_values", config_values)
       |> Map.put("oauth_binding_refs", oauth_refs)
       |> Map.put("root_grants", root_grants)}
    end
  end

  defp create_or_update_definition(tenant_id, %{"mcp_id" => mcp_id} = attrs)
       when is_binary(mcp_id) and mcp_id != "" do
    SalixMCP.Store.update_definition(mcp_id, Map.delete(attrs, "mcp_id"), tenant_id)
  end

  defp create_or_update_definition(tenant_id, attrs),
    do: SalixMCP.Store.create_definition(Map.put(attrs, "tenant_id", tenant_id))

  defp create_or_update_binding(tenant_id, group_id, %{"binding_id" => binding_id} = attrs)
       when is_binary(binding_id) and binding_id != "" do
    SalixMCP.Gateway.update_binding(
      tenant_id,
      group_id,
      binding_id,
      Map.delete(attrs, "binding_id")
    )
  end

  defp create_or_update_binding(tenant_id, group_id, attrs) do
    attrs = Map.delete(attrs, "binding_id")
    SalixMCP.Gateway.create_binding(tenant_id, group_id, attrs)
  end

  defp decode_json_object(json) do
    case Jason.decode(blank_json(json, "{}")) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _} -> {:error, {:bad_request, "JSON value must be an object."}}
      {:error, _} -> {:error, {:bad_request, "JSON object is invalid."}}
    end
  end

  defp decode_json_list(json) do
    case Jason.decode(blank_json(json, "[]")) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, _} -> {:error, {:bad_request, "Root grants must be a JSON array."}}
      {:error, _} -> {:error, {:bad_request, "Root grants JSON is invalid."}}
    end
  end

  defp blank_json(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      value -> value
    end
  end

  defp blank_json(_value, fallback), do: fallback

  defp group_options(groups),
    do: Enum.map(groups, &{&1["name"] || &1["group_id"], &1["group_id"]})

  defp target_refs(definition) do
    metadata = definition["server_metadata"] || %{}

    (List.wrap(metadata["remotes"]) ++ List.wrap(metadata["packages"]))
    |> Enum.map(& &1["target_ref"])
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp discovery_count(row, key),
    do: row |> get_in(["connection", "discovered", key]) |> List.wrap() |> length()

  defp profile_summary(%{"transports" => transports, "network" => network}) do
    [Enum.join(List.wrap(transports), ","), network]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" / ")
  end

  defp profile_summary(_profile), do: "—"

  defp oauth_actionable?(row) do
    status = get_in(row, ["connection", "status"]) || ""

    status in [
      "not_authorized",
      "authorization_pending",
      "reauthorization_required",
      "missing_oauth_client",
      "auth_failed"
    ]
  end

  defp ts(seconds) when is_integer(seconds),
    do: DateTime.from_unix!(seconds) |> DateTime.to_iso8601()

  defp ts(v), do: v
end
