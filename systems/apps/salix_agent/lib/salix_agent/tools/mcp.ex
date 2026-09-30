defmodule SalixAgent.Tools.MCP do
  @moduledoc """
  MCP management, usage and dynamic operation dispatch.

  MCP dynamic tool ids use `mcp.<binding_alias>.<tool_alias>`. The binding is
  resolved through the configured MCP provider seam, and execution still goes
  through the current session's materialized disclosure.
  """

  alias SalixAgent.IFC.ConnectorLabels

  @normal_auto_wait_seconds SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()

  @callback provider_state(agent_id :: String.t()) :: {:ok, map()} | {:error, term()}
  @callback dynamic_disclosure_entries(agent_id :: String.t()) ::
              {:ok, [map()]} | {:error, term()}
  @callback list_definitions(agent_id :: String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback create_definition(agent_id :: String.t(), attrs :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback list_bindings(agent_id :: String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback create_binding(agent_id :: String.t(), attrs :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback update_binding(agent_id :: String.t(), binding_id :: String.t(), attrs :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback set_binding_enabled(
              agent_id :: String.t(),
              binding_id :: String.t(),
              enabled :: boolean()
            ) ::
              {:ok, map()} | {:error, term()}
  @callback refresh_binding(agent_id :: String.t(), binding_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback authorize_binding(agent_id :: String.t(), binding_id :: String.t(), params :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback call_tool(
              agent_id :: String.t(),
              binding_alias :: String.t(),
              tool_alias :: String.t(),
              args :: map(),
              ctx :: map()
            ) ::
              {:ok, map()} | {:error, term()}
  @callback cancel_tool_call(
              agent_id :: String.t(),
              operation_id :: String.t(),
              tool_call_id :: String.t(),
              reason :: String.t(),
              ctx :: map()
            ) :: :ok | {:error, term()}
  @callback list_resources(agent_id :: String.t(), binding_id :: String.t()) ::
              {:ok, [map()]} | {:error, term()}
  @callback read_resource(agent_id :: String.t(), binding_id :: String.t(), uri :: String.t()) ::
              {:ok, term()} | {:error, term()}
  @callback list_prompts(agent_id :: String.t(), binding_id :: String.t()) ::
              {:ok, [map()]} | {:error, term()}
  @callback get_prompt(
              agent_id :: String.t(),
              binding_id :: String.t(),
              name :: String.t(),
              args :: map()
            ) ::
              {:ok, term()} | {:error, term()}

  def defs do
    [
      {"mcp_manager.definition_list", "List MCP definitions visible to this tenant.",
       schema(:definition_list), &__MODULE__.definition_list/2, @normal_auto_wait_seconds},
      {"mcp_manager.definition_create",
       "Create an MCP definition immediately from server metadata, server_json, remote URL, package spec, or mcpServers config. Check definition_list first and reuse an equivalent definition when available; after creation, continue setup with mcp_manager.connect.",
       schema(:definition_create), &__MODULE__.definition_create/2, @normal_auto_wait_seconds},
      {"mcp_manager.connect",
       "Create a group MCP binding immediately from an MCP definition, placement, target_ref and group config values. After connecting, inspect the binding with mcp.list; if it requires provider OAuth, call mcp_manager.authorize.",
       schema(:connect), &__MODULE__.connect/2, @normal_auto_wait_seconds},
      {"mcp_manager.update",
       "Update a group MCP binding config, alias, OAuth refs, root grants, placement or device runtime immediately. Reconnect afterward when connection discovery must be refreshed.",
       schema(:update), &__MODULE__.update/2, @normal_auto_wait_seconds},
      {"mcp_manager.set_enabled",
       "Enable or disable a group MCP binding immediately without deleting its config. Reconnect after enabling when discovery is stale.",
       schema(:set_enabled), &__MODULE__.set_enabled/2, @normal_auto_wait_seconds},
      {"mcp_manager.reconnect",
       "Start or reconnect one MCP binding and refresh tools/resources/prompts discovery.",
       schema(:reconnect), &__MODULE__.reconnect/2, @normal_auto_wait_seconds},
      {"mcp_manager.authorize",
       "Start or restart provider OAuth for a remote MCP binding and return the authorization URL immediately. Give that URL to the user; after the user completes provider consent, call mcp_manager.reconnect and mcp.list to verify discovered capabilities.",
       schema(:authorize), &__MODULE__.authorize/2, @normal_auto_wait_seconds},
      {"mcp.list",
       "List connected MCP services, including Slack connections authorized through Plugins, and discover their tools/resources/prompts on demand. Use kind=bindings to inspect connections. MCP operation names and manuals are not in the initial prompt. Use kind=tools with a binding filter to discover operation_id values. Read help for the selected operation before calling its canonical name. Management actions are under mcp_manager.*.",
       schema(:list), &__MODULE__.list/2, @normal_auto_wait_seconds},
      {"mcp.get",
       "Read one MCP resource or prompt through an existing binding. For MCP tool manuals and schemas, use help on the returned operation_id.",
       schema(:get), &__MODULE__.get/2, @normal_auto_wait_seconds}
    ]
  end

  def provider_state(ctx) when is_map(ctx) do
    case provider() do
      nil ->
        %{}

      mod ->
        case mod.provider_state(ctx_agent_id(ctx)) do
          {:ok, state} when is_map(state) -> state
          _ -> %{}
        end
    end
  end

  def dynamic_disclosure_entries(ctx) do
    case provider() do
      nil ->
        []

      mod ->
        case mod.dynamic_disclosure_entries(ctx_agent_id(ctx)) do
          {:ok, entries} when is_list(entries) -> entries
          _ -> []
        end
    end
  end

  def definition_list(_args, ctx), do: call_provider!(ctx, :list_definitions, [], "definitions")

  def definition_create(args, ctx) do
    args = stringify(args)
    call_provider!(ctx, :create_definition, [args], "definition")
  end

  def connect(args, ctx) do
    args = stringify(args)
    call_provider!(ctx, :create_binding, [args], "binding")
  end

  def update(args, ctx) do
    args = stringify(args)
    binding_id = required(args, "binding_id")

    call_provider!(
      ctx,
      :update_binding,
      [binding_id, Map.delete(args, "binding_id")],
      "binding"
    )
  end

  def set_enabled(args, ctx) do
    args = stringify(args)
    binding_id = required(args, "binding_id")
    enabled = raw(args, "enabled") in [true, "true", 1, "1"]
    call_provider!(ctx, :set_binding_enabled, [binding_id, enabled], "binding")
  end

  def reconnect(args, ctx) do
    binding_id = required(args, "binding_id")
    call_provider!(ctx, :refresh_binding, [binding_id], "connection")
  end

  def authorize(args, ctx) do
    args = stringify(args)
    binding_id = required(args, "binding_id")

    params =
      args
      |> Map.take(["scope", "scopes", "redirect_after"])
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" or value == [] end)
      |> Map.new()

    authorize_binding_result!(ctx, binding_id, params)
  end

  defp authorize_binding_result!(ctx, binding_id, params) do
    case seam!().authorize_binding(ctx_agent_id(ctx), binding_id, params) do
      {:ok, result} ->
        Jason.encode!(%{"authorization" => result})

      {:error, {:missing_oauth_client, message}} ->
        Jason.encode!(%{
          "authorization" => %{
            "status" => "missing_oauth_client",
            "error" => to_string(message)
          }
        })

      {:error, {:precondition_failed, message}} ->
        Jason.encode!(%{
          "authorization" => %{
            "status" => "precondition_failed",
            "error" => to_string(message)
          }
        })

      {:error, {:bad_request, message}} ->
        Jason.encode!(%{
          "authorization" => %{
            "status" => "error",
            "error" => to_string(message)
          }
        })

      {:error, reason} ->
        Jason.encode!(%{
          "authorization" => %{
            "status" => "error",
            "error" => error_message(reason)
          }
        })
    end
  end

  def list(args, ctx), do: ConnectorLabels.group_audience(do_list(args, ctx), ctx)

  defp do_list(args, ctx) do
    args = stringify(args || %{})

    case normalized_kind(raw(args, "kind"), "bindings") do
      "bindings" ->
        bindings = provider_result!(ctx, :list_bindings, [])
        Jason.encode!(%{"bindings" => filter_bindings(bindings, args)})

      "tools" ->
        bindings = provider_result!(ctx, :list_bindings, [])
        Jason.encode!(%{"tools" => list_tools(bindings, args)})

      "resources" ->
        bindings = provider_result!(ctx, :list_bindings, [])
        Jason.encode!(%{"resources" => list_resources(bindings, args)})

      "prompts" ->
        bindings = provider_result!(ctx, :list_bindings, [])
        Jason.encode!(%{"prompts" => list_prompts(bindings, args)})

      kind ->
        raise "unsupported mcp.list kind: #{kind}"
    end
  end

  def get(args, ctx), do: ConnectorLabels.group_audience(do_get(args, ctx), ctx)

  defp do_get(args, ctx) do
    args = stringify(args || %{})

    case normalized_kind(raw(args, "kind"), "") do
      "resource" ->
        binding_id = binding_id_from_args!(ctx, args)
        uri = required(args, "uri")
        call_provider!(ctx, :read_resource, [binding_id, uri], "resource")

      "prompt" ->
        binding_id = binding_id_from_args!(ctx, args)
        name = required(args, "name")
        arguments = raw(args, "arguments") || %{}
        call_provider!(ctx, :get_prompt, [binding_id, name, arguments], "prompt")

      "" ->
        raise "kind is required; use resource or prompt"

      kind ->
        raise "unsupported mcp.get kind: #{kind}"
    end
  end

  # What a binding returned belongs to the Group that configured it, not to
  # whatever this round happened to declare
  # (docs/verification.md).
  def call_dynamic_operation("mcp." <> _rest = operation_id, args, ctx) when is_map(args),
    do: ConnectorLabels.group_audience(do_call_dynamic_operation(operation_id, args, ctx), ctx)

  defp do_call_dynamic_operation("mcp." <> rest, args, ctx) do
    case String.split(rest, ".", parts: 2) do
      [binding_alias, tool_alias] when binding_alias != "" and tool_alias != "" ->
        case seam!().call_tool(ctx_agent_id(ctx), binding_alias, tool_alias, args, ctx) do
          {:ok, %{"content" => content, "status" => "completed"}} ->
            content

          {:ok, %{"content" => content, "status" => "cancelled"}} ->
            {:tool_status, "cancelled", content, []}

          {:ok, %{"content" => content, "status" => status}} when is_binary(status) ->
            {:tool_status, "error", content, []}

          {:ok, result} ->
            Jason.encode!(result)

          {:error, reason} ->
            raise error_message(reason)
        end

      _ ->
        raise "invalid MCP operation id"
    end
  end

  def cancel_dynamic_operation("mcp." <> _ = operation_id, ctx, tool_call_id, reason)
      when is_binary(tool_call_id) do
    seam!().cancel_tool_call(
      ctx_agent_id(ctx),
      operation_id,
      tool_call_id,
      to_string(reason || ""),
      ctx
    )
  end

  def cancel_dynamic_operation(_operation_id, _ctx, _tool_call_id, _reason), do: :ok

  defp call_provider!(ctx, fun, args, key) do
    result = provider_result!(ctx, fun, args)
    Jason.encode!(%{key => result})
  end

  defp provider_result!(ctx, fun, args) do
    mod = seam!()

    case apply(mod, fun, [ctx_agent_id(ctx) | args]) do
      {:ok, result} -> result
      {:error, reason} -> raise error_message(reason)
    end
  end

  defp list_tools(bindings, args) when is_list(bindings) do
    bindings
    |> filter_bindings(args)
    |> Enum.flat_map(fn binding ->
      binding
      |> discovered_items("tools")
      |> Enum.map(&put_binding_ref(&1, binding))
    end)
  end

  defp list_resources(bindings, args) when is_list(bindings) do
    bindings
    |> filter_bindings(args)
    |> Enum.flat_map(fn binding ->
      binding
      |> discovered_items("resources")
      |> Enum.map(&put_binding_ref(&1, binding))
    end)
  end

  defp list_prompts(bindings, args) when is_list(bindings) do
    bindings
    |> filter_bindings(args)
    |> Enum.flat_map(fn binding ->
      binding
      |> discovered_items("prompts")
      |> Enum.map(&put_binding_ref(&1, binding))
    end)
  end

  defp filter_bindings(bindings, args) do
    binding_id = trim(raw(args, "binding_id"))
    binding_alias = first_present(args, ["binding_alias", "alias"])

    Enum.filter(bindings, fn binding ->
      (binding_id == "" or to_string(binding["binding_id"] || "") == binding_id) and
        (binding_alias == "" or to_string(binding["alias"] || "") == binding_alias)
    end)
  end

  defp discovered_items(binding, key) do
    binding
    |> get_in(["connection", "discovered", key])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp put_binding_ref(item, binding) do
    item
    |> Map.put("binding_id", binding["binding_id"])
    |> Map.put("binding_alias", binding["alias"])
    |> Map.put("binding_status", get_in(binding, ["connection", "status"]) || "configured")
    |> Map.put("binding_enabled", binding["enabled"] != false)
  end

  defp binding_id_from_args!(ctx, args) do
    case trim(raw(args, "binding_id")) do
      "" ->
        binding_alias = first_present(args, ["binding_alias", "alias"])

        if binding_alias == "" do
          raise "binding_id or binding_alias is required"
        end

        ctx
        |> provider_result!(:list_bindings, [])
        |> Enum.find(fn binding -> to_string(binding["alias"] || "") == binding_alias end)
        |> case do
          %{"binding_id" => binding_id} when is_binary(binding_id) and binding_id != "" ->
            binding_id

          _ ->
            raise "MCP binding alias not found: #{binding_alias}"
        end

      binding_id ->
        binding_id
    end
  end

  defp first_present(args, keys) do
    keys
    |> Enum.find_value(fn key ->
      case trim(raw(args, key)) do
        "" -> nil
        value -> value
      end
    end)
    |> case do
      nil -> ""
      value -> value
    end
  end

  defp normalized_kind(value, default) do
    value
    |> trim()
    |> case do
      "" -> default
      kind -> kind
    end
  end

  defp schema(:definition_list), do: %{"type" => "object", "properties" => %{}, "required" => []}

  defp schema(:definition_create) do
    %{
      "type" => "object",
      "properties" => %{
        "server_metadata" => %{"type" => "object", "description" => "MCP server metadata object."},
        "server_json" => %{"type" => "object", "description" => "Alias for server_metadata."},
        "server_json_url" => %{
          "type" => "string",
          "description" => "Public URL returning MCP server metadata JSON."
        },
        "registry_base_url" => %{"type" => "string", "description" => "MCP registry base URL."},
        "server_name" => %{"type" => "string", "description" => "MCP registry server name."},
        "server_version" => %{
          "type" => "string",
          "description" => "Optional MCP registry server version."
        },
        "mcpServers" => %{
          "type" => "object",
          "description" => "Client config snippet with one mcpServers entry."
        },
        "url" => %{"type" => "string", "description" => "Remote MCP URL."},
        "remote_url" => %{"type" => "string", "description" => "Alias for remote MCP URL."},
        "transport" => %{
          "type" => "string",
          "description" => "MCP transport such as streamable-http or stdio."
        },
        "headers_schema" => %{
          "type" => "object",
          "description" => "Remote HTTP header input schema."
        },
        "variables_schema" => %{
          "type" => "object",
          "description" => "Remote URL variable input schema."
        },
        "registry_type" => %{
          "type" => "string",
          "description" => "Package registry type: npm, pypi, nuget, oci, mcpb, or direct."
        },
        "identifier" => %{
          "type" => "string",
          "description" => "Package identifier such as @playwright/mcp."
        },
        "image" => %{"type" => "string", "description" => "Container image for OCI MCP."},
        "command" => %{"type" => "string", "description" => "Direct stdio command."},
        "version" => %{"type" => "string", "description" => "Package or definition version."},
        "args" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Runtime command args."
        },
        "runtime_arguments" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Runtime command args."
        },
        "package_arguments" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "MCP package args."
        },
        "env" => %{
          "type" => "object",
          "description" => "Environment variable input schema or placeholder map."
        },
        "environment_variables_schema" => %{
          "type" => "object",
          "description" => "Package environment variable input schema."
        },
        "working_dir" => %{
          "type" => "string",
          "description" => "Working directory for stdio MCP process."
        },
        "name" => %{"type" => "string", "description" => "Display name."},
        "description" => %{"type" => "string", "description" => "Display description."},
        "supports_server" => %{
          "type" => "boolean",
          "description" => "Creator-declared server support hint."
        },
        "server_support_note" => %{
          "type" => "string",
          "description" => "Human-readable server support note."
        },
        "trust" => %{"type" => "object", "description" => "Source/trust metadata."}
      },
      "required" => []
    }
  end

  defp schema(:list) do
    %{
      "type" => "object",
      "properties" => %{
        "kind" => %{
          "type" => "string",
          "enum" => ["bindings", "tools", "resources", "prompts"],
          "description" => "What to list. Defaults to bindings."
        },
        "binding_id" => id_schema("Optional binding id filter."),
        "binding_alias" => id_schema("Optional binding alias filter."),
        "alias" => id_schema("Alias for binding_alias.")
      },
      "required" => []
    }
  end

  defp schema(:get) do
    %{
      "type" => "object",
      "properties" => %{
        "kind" => %{
          "type" => "string",
          "enum" => ["resource", "prompt"],
          "description" => "Runtime MCP object to read."
        },
        "binding_id" => id_schema("Binding id."),
        "binding_alias" => id_schema("Binding alias."),
        "alias" => id_schema("Alias for binding_alias."),
        "uri" => id_schema("MCP resource URI. Required when kind is resource."),
        "name" => id_schema("Prompt name. Required when kind is prompt."),
        "arguments" => %{"type" => "object", "description" => "Prompt arguments."}
      },
      "required" => ["kind"]
    }
  end

  defp schema(:connect) do
    %{
      "type" => "object",
      "properties" => binding_properties(),
      "required" => ["mcp_id", "target_ref", "placement"]
    }
  end

  defp schema(:update) do
    %{
      "type" => "object",
      "properties" =>
        binding_properties()
        |> Map.put("binding_id", id_schema("Binding id.")),
      "required" => ["binding_id"]
    }
  end

  defp schema(:set_enabled) do
    %{
      "type" => "object",
      "properties" => %{
        "binding_id" => id_schema("Binding id."),
        "enabled" => %{"type" => "boolean", "description" => "true to enable, false to disable."}
      },
      "required" => ["binding_id", "enabled"]
    }
  end

  defp schema(:reconnect),
    do: %{
      "type" => "object",
      "properties" => %{"binding_id" => id_schema("Binding id.")},
      "required" => ["binding_id"]
    }

  defp schema(:authorize) do
    %{
      "type" => "object",
      "properties" => %{
        "binding_id" => id_schema("Remote MCP binding id."),
        "scope" => %{
          "type" => "string",
          "description" =>
            "Optional OAuth scope override. Omit it unless the provider requires a different scope."
        },
        "scopes" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Optional OAuth scopes override."
        },
        "redirect_after" => %{
          "type" => "string",
          "description" => "Optional Salix URL to return to after callback."
        }
      },
      "required" => ["binding_id"]
    }
  end

  defp binding_properties do
    %{
      "mcp_id" => id_schema("MCP definition id."),
      "alias" => id_schema("Group-local binding alias used in mcp.<alias>.<tool>."),
      "target_ref" => id_schema("Target entry ref from the MCP definition."),
      "placement" => %{
        "type" => "string",
        "enum" => ["server", "device"],
        "description" => "Where this binding runs."
      },
      "device_runtime_id" => id_schema("Required for device placement."),
      "config_values" => %{
        "type" => "object",
        "description" => "Group config values; secrets are stored here but not shown back."
      },
      "oauth_binding_refs" => %{
        "type" => "object",
        "description" =>
          "OAuth binding refs by env var. Each ref names provider/alias or binding_id and optional credential selector, for example {\"GITHUB_TOKEN\":{\"provider\":\"github\",\"alias\":\"default\",\"credential\":\"access_token\"}}. Do not include token values."
      },
      "root_grants" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Allowed roots for local/root MCPs."
      },
      "enabled" => %{"type" => "boolean", "description" => "Whether this binding is callable."}
    }
  end

  defp id_schema(desc), do: %{"type" => "string", "description" => desc}

  defp provider, do: Application.get_env(:salix_agent, :mcp_provider_mod)

  defp seam!, do: provider() || raise("mcp provider is not configured")

  defp ctx_agent_id(ctx) when is_map(ctx),
    do: to_string(Map.get(ctx, :agent_id) || Map.get(ctx, "agent_id") || "")

  defp raw(args, key) when is_map(args) do
    args[key] || atom_key_value(args, key)
  end

  defp raw(_args, _key), do: nil

  defp atom_key_value(args, key) do
    Enum.find_value(args, fn
      {atom_key, value} when is_atom(atom_key) ->
        if Atom.to_string(atom_key) == key, do: value

      _ ->
        nil
    end)
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp required(args, key) do
    case raw(args, key) do
      value when is_binary(value) and value != "" -> value
      value when not is_nil(value) -> to_string(value)
      _ -> raise "#{key} is required"
    end
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)
end
