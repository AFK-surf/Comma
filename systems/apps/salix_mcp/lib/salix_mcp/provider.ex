defmodule SalixMCP.Provider do
  @moduledoc false

  @behaviour SalixAgent.Tools.MCP

  alias SalixMCP.{Credentials, Gateway, Store}

  @impl true
  def provider_state(agent_id) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id) do
      bindings =
        Store.list_group_bindings(scope.tenant_id, scope.group_id, include_disabled: true)
        |> Enum.map(&provider_binding_state/1)

      {:ok,
       %{
         "revision" => provider_revision(bindings),
         "bindings" => bindings
       }}
    end
  end

  @impl true
  def dynamic_disclosure_entries(agent_id) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id) do
      entries =
        Store.list_group_bindings(scope.tenant_id, scope.group_id, include_disabled: true)
        |> Enum.flat_map(&binding_tool_entries/1)

      {:ok, entries}
    end
  end

  @doc "Returns the fail-closed safety class for one exact dynamic MCP operation."
  def operation_safety(agent_id, operation_id) do
    with {:ok, entries} <- dynamic_disclosure_entries(agent_id),
         %{} = entry <- Enum.find(entries, &(&1["name"] == operation_id)) do
      {:ok, entry["safety"] || "write"}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @impl true
  def list_definitions(agent_id) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id) do
      {:ok, Store.list_definitions(scope.tenant_id)}
    end
  end

  @impl true
  def create_definition(agent_id, attrs) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id) do
      attrs =
        attrs
        |> stringify()
        |> Map.put_new("created_by", agent_id)
        |> Map.put_new("tenant_id", scope.tenant_id)

      Store.create_definition(attrs)
    end
  end

  @impl true
  def list_bindings(agent_id) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id) do
      bindings =
        Store.list_group_bindings(scope.tenant_id, scope.group_id, include_disabled: true)
        |> Enum.map(&put_operation_ids/1)
        |> Enum.map(&agent_binding_projection/1)

      {:ok, bindings}
    end
  end

  @impl true
  def create_binding(agent_id, attrs) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id) do
      Gateway.create_binding(scope.tenant_id, scope.group_id, attrs)
    end
  end

  @impl true
  def update_binding(agent_id, binding_id, attrs) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id) do
      Gateway.update_binding(scope.tenant_id, scope.group_id, binding_id, attrs)
    end
  end

  @impl true
  def set_binding_enabled(agent_id, binding_id, enabled) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id) do
      Gateway.set_binding_enabled(scope.tenant_id, scope.group_id, binding_id, enabled)
    end
  end

  @impl true
  def refresh_binding(agent_id, binding_id) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id) do
      Gateway.refresh_binding(scope.tenant_id, scope.group_id, binding_id)
    end
  end

  @impl true
  def authorize_binding(agent_id, binding_id, params) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id) do
      Credentials.start_remote_authorization(
        scope.tenant_id,
        scope.group_id,
        binding_id,
        params || %{}
      )
    end
  end

  @impl true
  def call_tool(agent_id, binding_alias, tool_alias, args, ctx) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id),
         {:ok, binding} <-
           Store.find_binding_by_alias(scope.tenant_id, scope.group_id, binding_alias),
         {:ok, tool_name} <- resolve_tool_name(binding, tool_alias) do
      Gateway.call_tool(scope.tenant_id, scope.group_id, binding["binding_id"], tool_name, args,
        agent_id: agent_id,
        session_id: ctx[:session_id] || ctx["session_id"],
        tool_call_id: ctx[:tool_call_id] || ctx["tool_call_id"]
      )
    end
  end

  @impl true
  def cancel_tool_call(agent_id, "mcp." <> rest, tool_call_id, reason, _ctx) do
    with [binding_alias, _tool_alias] <- String.split(rest, ".", parts: 2),
         {:ok, scope} <- Store.scope_for_agent(agent_id),
         {:ok, binding} <-
           Store.find_binding_by_alias(scope.tenant_id, scope.group_id, binding_alias) do
      Gateway.cancel_tool_call(
        scope.tenant_id,
        scope.group_id,
        binding["binding_id"],
        tool_call_id,
        reason
      )
    else
      _ -> :ok
    end
  end

  @impl true
  def list_resources(agent_id, binding_id) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id) do
      Gateway.list_resources(scope.tenant_id, scope.group_id, binding_id)
    end
  end

  @impl true
  def read_resource(agent_id, binding_id, uri) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id) do
      Gateway.read_resource(scope.tenant_id, scope.group_id, binding_id, uri)
    end
  end

  @impl true
  def list_prompts(agent_id, binding_id) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id) do
      Gateway.list_prompts(scope.tenant_id, scope.group_id, binding_id)
    end
  end

  @impl true
  def get_prompt(agent_id, binding_id, name, args) do
    with {:ok, scope} <- Store.scope_for_agent(agent_id) do
      Gateway.get_prompt(scope.tenant_id, scope.group_id, binding_id, name, args)
    end
  end

  defp binding_tool_entries(binding) do
    binding_alias = binding["alias"] || binding["binding_id"]
    tools = get_in(binding, ["connection", "discovered", "tools"]) || []

    tools
    |> tool_alias_entries()
    |> Enum.map(fn {tool, alias_name} ->
      tool_name = to_string(tool["name"] || "")
      op_id = operation_id(binding_alias, alias_name)

      %{
        "name" => op_id,
        "summary" => to_string(tool["description"] || tool["title"] || tool_name),
        "manual" => operation_manual(binding, tool),
        "input_schema" => tool["inputSchema"] || tool["input_schema"] || %{"type" => "object"},
        "examples" => operation_examples(op_id, tool),
        "manual_available" => true,
        "helpable" => true,
        "callable" => binding["enabled"] != false
      }
      |> maybe_put_read_safety(tool)
    end)
  end

  defp maybe_put_read_safety(entry, tool) do
    annotations = tool["annotations"] || %{}

    if annotations["readOnlyHint"] == true or annotations["read_only_hint"] == true,
      do: Map.put(entry, "safety", "read"),
      else: Map.put(entry, "safety", "write")
  end

  defp put_operation_ids(binding) do
    binding_alias = binding["alias"] || binding["binding_id"]
    tools = get_in(binding, ["connection", "discovered", "tools"]) || []

    tools =
      tools
      |> tool_alias_entries()
      |> Enum.map(fn {tool, alias_name} ->
        tool
        |> Map.put("tool_alias", alias_name)
        |> Map.put("operation_id", operation_id(binding_alias, alias_name))
      end)

    connection = Map.get(binding, "connection", %{})
    discovered = Map.get(connection, "discovered", %{})

    binding
    |> Map.put(
      "connection",
      Map.put(connection, "discovered", Map.put(discovered, "tools", tools))
    )
  end

  defp resolve_tool_name(binding, tool_alias) do
    tools = get_in(binding, ["connection", "discovered", "tools"]) || []

    case Enum.find(tool_alias_entries(tools), fn {_tool, alias_name} ->
           alias_name == tool_alias
         end) do
      {%{"name" => name}, _alias_name} when is_binary(name) and name != "" ->
        {:ok, name}

      _ ->
        {:error,
         "MCP tool not found in binding discovery cache; reconnect the binding with mcp_manager.reconnect or inspect mcp.list"}
    end
  end

  defp operation_id(binding_alias, tool_alias), do: "mcp." <> binding_alias <> "." <> tool_alias

  defp tool_alias(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "_")
    |> String.trim("_-")
    |> case do
      "" -> "tool"
      value -> value
    end
  end

  defp tool_alias_entries(tools) do
    aliases =
      tools
      |> Enum.map(fn tool -> {tool, tool_alias(tool["name"])} end)

    counts =
      aliases
      |> Enum.map(fn {_tool, alias_name} -> alias_name end)
      |> Enum.frequencies()

    Enum.map(aliases, fn {tool, alias_name} ->
      alias_name =
        if counts[alias_name] > 1 do
          alias_name <> "_" <> short_hash(tool["name"])
        else
          alias_name
        end

      {tool, alias_name}
    end)
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, to_string(value || ""))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  defp operation_manual(binding, tool) do
    [
      to_string(tool["description"] || tool["title"] || tool["name"] || ""),
      "MCP binding: #{binding["alias"] || binding["binding_id"]}",
      "Binding id: #{binding["binding_id"]}",
      "Placement: #{binding["placement"]}",
      "Connection status: #{get_in(binding, ["connection", "status"]) || "configured"}",
      "Call parameters are the MCP tool arguments. Use mcp_manager.reconnect if discovery is stale."
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp operation_examples(op_id, tool) do
    schema = tool["inputSchema"] || tool["input_schema"] || %{"type" => "object"}
    params = example_params(schema)

    %{
      "internal_llm" => %{"tool" => "call", "arguments" => %{"tool" => op_id, "params" => params}},
      "external_runtime" => %{"tool" => op_id, "arguments" => params},
      "script" => %{
        "call" =>
          "sf_host_call(\"salix.call\", " <>
            Jason.encode!(%{"tool" => op_id, "args" => params}) <> ", 20000)"
      }
    }
  end

  defp example_params(%{"properties" => props, "required" => required})
       when is_map(props) and is_list(required) do
    required
    |> Enum.map(&to_string/1)
    |> Map.new(fn key -> {key, example_value(props[key] || %{})} end)
  end

  defp example_params(_schema), do: %{}

  defp example_value(%{"type" => "array"}), do: []
  defp example_value(%{"type" => "object"}), do: %{}
  defp example_value(%{"type" => "boolean"}), do: true
  defp example_value(%{"type" => "integer"}), do: 1
  defp example_value(%{"type" => "number"}), do: 1
  defp example_value(_), do: "value"

  defp provider_binding_state(binding) do
    %{
      "binding_id" => binding["binding_id"],
      "alias" => binding["alias"],
      "enabled" => binding["enabled"],
      "placement" => binding["placement"],
      "revision" => binding["revision"],
      "protocol_version" => get_in(binding, ["connection", "protocol_version"]),
      "capabilities" => get_in(binding, ["connection", "capabilities"]) || %{},
      "server_info" => get_in(binding, ["connection", "server_info"]) || %{},
      "status" => get_in(binding, ["connection", "status"]),
      "discovery_revision" => get_in(binding, ["connection", "discovery_revision"])
    }
  end

  defp agent_binding_projection(binding) do
    binding
    |> Map.drop(["root_grants"])
    |> Map.update("connection", %{}, &agent_connection_projection/1)
    |> Map.update("execution_profile", %{}, &agent_execution_profile/1)
    |> Map.update("oauth_binding_refs", %{}, &agent_oauth_refs/1)
    |> Map.put("root_grants_configured", root_grants_configured?(binding))
  end

  defp agent_connection_projection(connection) when is_map(connection) do
    connection
    |> Map.drop(["last_error"])
    |> Map.update("discovered", %{}, &agent_discovered_projection/1)
  end

  defp agent_connection_projection(_connection), do: %{}

  defp agent_discovered_projection(discovered) when is_map(discovered) do
    %{
      "tools" =>
        discovered
        |> Map.get("tools", [])
        |> List.wrap()
        |> Enum.map(&agent_tool_projection/1),
      "resources" =>
        discovered
        |> Map.get("resources", [])
        |> List.wrap()
        |> Enum.map(&agent_resource_projection/1),
      "prompts" =>
        discovered
        |> Map.get("prompts", [])
        |> List.wrap()
        |> Enum.map(&agent_prompt_projection/1)
    }
  end

  defp agent_discovered_projection(_discovered),
    do: %{"tools" => [], "resources" => [], "prompts" => []}

  defp agent_tool_projection(tool) when is_map(tool) do
    tool
    |> Map.take(["name", "title", "description", "tool_alias", "operation_id"])
    |> Map.put("manual_available", true)
  end

  defp agent_tool_projection(tool),
    do: %{"name" => to_string(tool), "manual_available" => true}

  defp agent_resource_projection(resource) when is_map(resource) do
    Map.take(resource, ["uri", "name", "title", "description", "mimeType", "mime_type"])
  end

  defp agent_resource_projection(resource),
    do: %{"uri" => to_string(resource)}

  defp agent_prompt_projection(prompt) when is_map(prompt) do
    Map.take(prompt, ["name", "title", "description"])
  end

  defp agent_prompt_projection(prompt),
    do: %{"name" => to_string(prompt)}

  defp agent_execution_profile(profile) when is_map(profile) do
    profile
    |> Map.drop(["filesystem_roots"])
    |> Map.put("filesystem_roots_configured", filesystem_roots_configured?(profile))
  end

  defp agent_execution_profile(_profile), do: %{}

  defp agent_oauth_refs(refs) when is_map(refs) do
    Map.new(refs, fn {name, ref} ->
      ref =
        case ref do
          %{} = map ->
            Map.drop(map, [
              "value",
              "token",
              "access_token",
              "refresh_token",
              "id_token",
              "secret",
              "client_secret",
              "password",
              "api_key",
              "authorization"
            ])

          value ->
            value
        end

      {name, ref}
    end)
  end

  defp agent_oauth_refs(_refs), do: %{}

  defp root_grants_configured?(binding), do: List.wrap(binding["root_grants"]) != []
  defp filesystem_roots_configured?(profile), do: List.wrap(profile["filesystem_roots"]) != []

  defp provider_revision(binding_states) do
    binding_states
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
