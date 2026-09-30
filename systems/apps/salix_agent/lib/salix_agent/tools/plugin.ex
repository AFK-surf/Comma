defmodule SalixAgent.Tools.Plugin do
  @moduledoc """
  Agent-facing plugin management tools.

  These tools manage plugin definitions and group enablement only. They do not
  create, enable, disable, authorize, connect, start, or stop child domain state.
  """

  @normal_auto_wait_seconds SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()

  def defs do
    [
      {"plugin.definitions_list",
       "List plugin definitions visible to the current group, including system, tenant and group definitions.",
       schema(:definitions_list), &__MODULE__.definitions_list/2, @normal_auto_wait_seconds},
      {"plugin.definition_get", "Get one visible plugin definition.", schema(:definition_get),
       &__MODULE__.definition_get/2, @normal_auto_wait_seconds},
      {"plugin.definition_create",
       "Create a plugin definition from metadata and refs. Definitions default to group scope; owner_scope can be group or tenant. Salix generates the plugin id and returns it. The plugin is only a feature package; this does not create or change Skill, MCP, OAuth, IM, env or tool state.",
       schema(:definition_create), &__MODULE__.definition_create/2, @normal_auto_wait_seconds},
      {"plugin.definition_update",
       "Update a mutable group or tenant plugin definition visible to the current group. System definitions are read-only.",
       schema(:definition_update), &__MODULE__.definition_update/2, @normal_auto_wait_seconds},
      {"plugin.refs_put",
       "Replace the refs on a mutable group or tenant plugin definition without changing child domain state.",
       schema(:refs_put), &__MODULE__.refs_put/2, @normal_auto_wait_seconds},
      {"plugin.enable",
       "Enable a visible plugin for the current group. This only writes plugin enablement.",
       schema(:enable), &__MODULE__.enable/2, @normal_auto_wait_seconds},
      {"plugin.disable",
       "Disable a visible plugin for the current group. This only writes plugin enablement; locked plugins cannot be disabled.",
       schema(:disable), &__MODULE__.disable/2, @normal_auto_wait_seconds},
      {"plugin.projection_get", "Return the current group plugin runtime projection.",
       schema(:projection_get), &__MODULE__.projection_get/2, @normal_auto_wait_seconds}
    ]
  end

  def definitions_list(_args, ctx) do
    with {:ok, scope} <- scope(ctx),
         {:ok, definitions} <-
           SalixAgent.PluginStore.list_definitions(scope.tenant_id, scope.group_id),
         {:ok, enablements} <-
           SalixAgent.PluginStore.list_group_enablements(scope.tenant_id, scope.group_id) do
      Jason.encode!(%{"definitions" => definitions, "enablements" => enablements})
    else
      {:error, reason} -> raise error(reason)
    end
  end

  def definition_get(args, ctx) do
    with {:ok, scope} <- scope(ctx),
         plugin_id <- required(args, "plugin_id"),
         {:ok, definition} <-
           SalixAgent.PluginStore.get_definition(scope.tenant_id, scope.group_id, plugin_id) do
      Jason.encode!(%{"definition" => definition})
    else
      {:error, reason} -> raise error(reason)
    end
  end

  def definition_create(args, ctx) do
    with {:ok, scope} <- scope(ctx),
         {:ok, definition} <-
           SalixAgent.PluginStore.create_definition(
             scope.tenant_id,
             scope.group_id,
             stringify(args)
           ) do
      Jason.encode!(%{"definition" => definition})
    else
      {:error, reason} -> raise error(reason)
    end
  end

  def definition_update(args, ctx) do
    with {:ok, scope} <- scope(ctx),
         plugin_id <- required(args, "plugin_id"),
         attrs <- Map.delete(stringify(args), "plugin_id"),
         {:ok, definition} <-
           SalixAgent.PluginStore.update_definition(
             scope.tenant_id,
             scope.group_id,
             plugin_id,
             attrs
           ) do
      Jason.encode!(%{"definition" => definition})
    else
      {:error, reason} -> raise error(reason)
    end
  end

  def refs_put(args, ctx) do
    with {:ok, scope} <- scope(ctx),
         plugin_id <- required(args, "plugin_id"),
         attrs <- Map.delete(stringify(args), "plugin_id"),
         {:ok, definition} <-
           SalixAgent.PluginStore.put_refs(scope.tenant_id, scope.group_id, plugin_id, attrs) do
      Jason.encode!(%{"definition" => definition})
    else
      {:error, reason} -> raise error(reason)
    end
  end

  def enable(args, ctx) do
    with {:ok, scope} <- scope(ctx),
         plugin_id <- required(args, "plugin_id"),
         {:ok, enablement} <-
           SalixAgent.PluginStore.enable_group(scope.tenant_id, scope.group_id, plugin_id) do
      Jason.encode!(%{"enablement" => enablement})
    else
      {:error, reason} -> raise error(reason)
    end
  end

  def disable(args, ctx) do
    with {:ok, scope} <- scope(ctx),
         plugin_id <- required(args, "plugin_id"),
         {:ok, enablement} <-
           SalixAgent.PluginStore.disable_group(scope.tenant_id, scope.group_id, plugin_id) do
      Jason.encode!(%{"enablement" => enablement})
    else
      {:error, reason} -> raise error(reason)
    end
  end

  def projection_get(_args, ctx) do
    with {:ok, scope} <- scope(ctx),
         {:ok, projection} <- projection(scope) do
      Jason.encode!(projection)
    else
      {:error, reason} -> raise error(reason)
    end
  end

  defp projection(scope) do
    SalixAgent.PluginStore.runtime_projection(%{
      "tenant_id" => scope.tenant_id,
      "group_id" => scope.group_id
    })
  end

  defp scope(ctx) do
    with {:ok, completed} <- SalixAgent.AgentRuntimeConfig.complete_context(ctx),
         tenant_id <- trim(value(completed, :tenant_id)),
         group_id <- trim(value(completed, :group_id)),
         true <- tenant_id != "" and group_id != "" do
      {:ok, %{tenant_id: tenant_id, group_id: group_id}}
    else
      false -> {:error, "tenant_id and group_id are required"}
      {:error, _} = err -> err
    end
  end

  defp schema(:definitions_list), do: %{"type" => "object", "properties" => %{}, "required" => []}
  defp schema(:projection_get), do: %{"type" => "object", "properties" => %{}, "required" => []}

  defp schema(:definition_get) do
    %{
      "type" => "object",
      "properties" => %{"plugin_id" => string_schema("Plugin id.")},
      "required" => ["plugin_id"]
    }
  end

  defp schema(:definition_create) do
    %{
      "type" => "object",
      "properties" =>
        base_definition_properties()
        |> Map.put(
          "owner_scope",
          string_schema("Optional owner scope: group or tenant. Defaults to group.")
        ),
      "required" => ["name"]
    }
  end

  defp schema(:definition_update) do
    %{
      "type" => "object",
      "properties" =>
        base_definition_properties()
        |> Map.put("plugin_id", string_schema("Plugin id.")),
      "required" => ["plugin_id"]
    }
  end

  defp schema(:refs_put) do
    %{
      "type" => "object",
      "properties" =>
        ref_properties()
        |> Map.put("plugin_id", string_schema("Plugin id.")),
      "required" => ["plugin_id"]
    }
  end

  defp schema(name) when name in [:enable, :disable] do
    %{
      "type" => "object",
      "properties" => %{"plugin_id" => string_schema("Plugin id.")},
      "required" => ["plugin_id"]
    }
  end

  defp base_definition_properties do
    %{
      "name" => string_schema("Display name."),
      "description" => string_schema("Display description."),
      "setup" => %{"type" => "object", "description" => "Setup metadata and UI hints."},
      "ui" => %{"type" => "object", "description" => "Dashboard/UI entry metadata."},
      "manual" => %{"type" => "object", "description" => "Plugin manual or operation guide."},
      "trust" => %{"type" => "object", "description" => "Source and trust metadata."}
    }
    |> Map.merge(ref_properties())
  end

  defp ref_properties do
    %{
      "refs" => %{"type" => "object", "description" => "Full refs object."},
      "tool_refs" => array_schema("Canonical tool ids or wildcard refs such as mcp.*."),
      "skill_refs" => array_schema("Skill ids or skill ref objects."),
      "mcp_refs" => array_schema("MCP binding or capability refs."),
      "oauth_requirements" => array_schema("OAuth provider/scope requirement refs."),
      "im_connect_requirements" => array_schema("IM provider/connect requirement refs.")
    }
  end

  defp array_schema(description) do
    %{
      "type" => "array",
      "description" => description,
      "items" => %{
        "oneOf" => [
          %{"type" => "string"},
          %{"type" => "object"}
        ]
      }
    }
  end

  defp string_schema(description), do: %{"type" => "string", "description" => description}

  defp required(args, key) do
    case args |> value(key) |> trim() do
      "" -> raise "#{key} is required"
      value -> value
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp error({:bad_request, message}), do: message
  defp error(:not_found), do: "plugin not found"
  defp error(reason), do: inspect(reason)
end
