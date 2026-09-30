defmodule Comma.Plugins do
  @moduledoc """
  Product-facing plugin catalog and workspace enablement commands.

  Comma owns workspace authorization and the public response shape. Salix remains
  the source of truth for plugin definitions and group enablement.
  """

  alias Comma.{PluginInstallations, Workspaces}
  alias SalixAgent.PluginStore

  @description_max 1_000

  def list(user, session, workspace_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, definitions} <- list_definitions(workspace),
         {:ok, enablements} <- list_enablements(workspace),
         {:ok, installed_plugin_ids} <-
           PluginInstallations.installed_plugin_ids(workspace["id"]) do
      enablement_by_id = Map.new(enablements, &{&1["plugin_id"], &1})

      plugins =
        definitions
        |> Enum.filter(&product_plugin?/1)
        |> Enum.map(&public_plugin(&1, enablement_by_id, installed_plugin_ids))

      {:ok, plugins}
    end
  end

  def install(user, session, workspace_id, plugin_id) do
    with {:ok, plugin} <- mutate(user, session, workspace_id, plugin_id, :enable_group),
         :ok <- PluginInstallations.mark_installed(workspace_id, plugin_id) do
      {:ok, Map.put(plugin, "installed", true)}
    end
  end

  def uninstall(user, session, workspace_id, plugin_id) do
    with {:ok, plugin} <- mutate(user, session, workspace_id, plugin_id, :disable_group),
         :ok <- PluginInstallations.mark_uninstalled(workspace_id, plugin_id) do
      {:ok, Map.put(plugin, "installed", false)}
    end
  end

  defp mutate(user, session, workspace_id, plugin_id, operation) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         :ok <- validate_plugin_id(plugin_id),
         {:ok, _definition} <- get_product_definition(workspace, plugin_id),
         {:ok, _enablement} <-
           apply(PluginStore, operation, [
             workspace["salix_tenant_id"],
             workspace["default_group_id"],
             plugin_id
           ]),
         {:ok, plugins} <- list(user, session, workspace_id),
         plugin when not is_nil(plugin) <- Enum.find(plugins, &(&1["id"] == plugin_id)) do
      {:ok, plugin}
    else
      nil -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:bad_request, _message} = reason} -> {:error, reason}
      {:error, _reason} -> {:error, :plugins_unavailable}
    end
  end

  defp get_product_definition(workspace, plugin_id) do
    case PluginStore.get_definition(
           workspace["salix_tenant_id"],
           workspace["default_group_id"],
           plugin_id
         ) do
      {:ok, definition} when is_map(definition) ->
        if product_plugin?(definition), do: {:ok, definition}, else: {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :plugins_unavailable}

      _other ->
        {:error, :plugins_unavailable}
    end
  end

  defp list_definitions(workspace) do
    case PluginStore.list_raw_definitions(
           workspace["salix_tenant_id"],
           workspace["default_group_id"]
         ) do
      {:ok, definitions} when is_list(definitions) -> {:ok, Enum.filter(definitions, &is_map/1)}
      {:error, _reason} -> {:error, :plugins_unavailable}
      _other -> {:error, :plugins_unavailable}
    end
  end

  defp list_enablements(workspace) do
    case PluginStore.list_group_enablements(
           workspace["salix_tenant_id"],
           workspace["default_group_id"]
         ) do
      {:ok, enablements} when is_list(enablements) ->
        {:ok, Enum.filter(enablements, &is_map/1)}

      {:error, _reason} ->
        {:error, :plugins_unavailable}

      _other ->
        {:error, :plugins_unavailable}
    end
  end

  # System runtime packages are implementation details unless they declare an
  # integration setup surface. Tenant/group definitions remain product-owned.
  # Feishu is not open for installation in Comma yet. Keep its Salix definition.
  defp product_plugin?(%{"plugin_id" => "feishu"}), do: false

  defp product_plugin?(%{"owner_scope" => "system"} = definition) do
    get_in(definition, ["setup", "type"]) == "integration" or
      get_in(definition, ["setup_status", "type"]) == "integration"
  end

  defp product_plugin?(_definition), do: true

  defp public_plugin(definition, enablement_by_id, installed_plugin_ids) do
    description = clean_description(definition["description"])
    refs = definition["refs"] || %{}
    mcp_names = setup_mcp_names(definition)

    %{
      "id" => definition["plugin_id"],
      "name" => nonblank(definition["name"], definition["plugin_id"]),
      "summary" => description,
      "description" => description,
      "brand" => get_in(definition, ["ui", "brand"]),
      "category" => category(definition),
      # Product "installed" means the workspace has explicitly opted into the
      # plugin. System default_enabled controls runtime availability, but does
      # not mean the user connected or installed an integration.
      "installed" => installed?(definition, enablement_by_id, installed_plugin_ids),
      "locked" => definition["locked"] == true,
      "mcps" => resources(refs["mcp_refs"], "mcp_id", mcp_names),
      "skills" => resources(refs["skill_refs"], "skill_id", %{})
    }
  end

  defp installed?(%{"locked" => true}, _enablement_by_id, _installed_plugin_ids), do: true

  defp installed?(definition, enablement_by_id, installed_plugin_ids) do
    case Map.get(enablement_by_id, definition["plugin_id"]) do
      %{"enabled" => true} -> MapSet.member?(installed_plugin_ids, definition["plugin_id"])
      _missing_or_disabled -> false
    end
  end

  defp category(definition) do
    nonblank(get_in(definition, ["ui", "category"]), "Integrations")
  end

  defp setup_mcp_names(definition) do
    definition
    |> get_in(["setup", "mcps"])
    |> List.wrap()
    |> Enum.reduce(%{}, fn
      mcp, names when is_map(mcp) ->
        id = nonblank(mcp["mcp_id"], mcp["id"])
        name = nonblank(mcp["name"], mcp["alias"])

        if id == "" or name == "", do: names, else: Map.put_new(names, id, name)

      _mcp, names ->
        names
    end)
  end

  defp resources(values, id_key, names_by_id) when is_list(values) do
    values
    |> Enum.map(&resource(&1, id_key, names_by_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1["id"])
  end

  defp resources(_values, _id_key, _names_by_id), do: []

  defp resource(value, _id_key, names_by_id) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      id -> %{"id" => id, "name" => nonblank(names_by_id[id], id)}
    end
  end

  defp resource(value, id_key, names_by_id) when is_map(value) do
    id = nonblank(value[id_key], value["id"])

    if id == "" do
      nil
    else
      setup_name = nonblank(names_by_id[id], id)
      name = nonblank(value["name"], nonblank(value["alias"], setup_name))
      %{"id" => id, "name" => name}
    end
  end

  defp resource(_value, _id_key, _names_by_id), do: nil

  defp clean_description(value) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, @description_max)

  defp clean_description(_value), do: ""

  defp validate_plugin_id(plugin_id) when is_binary(plugin_id) do
    if String.trim(plugin_id) == "", do: {:error, {:bad_request, "plugin is required"}}, else: :ok
  end

  defp validate_plugin_id(_plugin_id), do: {:error, {:bad_request, "plugin is required"}}

  defp nonblank(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" when is_binary(fallback) -> String.trim(fallback)
      "" -> ""
      clean -> clean
    end
  end

  defp nonblank(_value, fallback) when is_binary(fallback), do: String.trim(fallback)
  defp nonblank(_value, _fallback), do: ""
end
