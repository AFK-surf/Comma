defmodule SalixAgent.Tools.ImRouter do
  @moduledoc """
  IM provider discovery tools and dynamic operation dispatcher.

  Salix exposes two static IM discovery tools: `im.connects_list` and
  `im.provider_apis_list`. Provider API calls are dynamic operation ids such as
  `im_api.slack.reply_message`; their full manual is read through `help`, and
  execution goes through the shared dispatcher.

  Provider API contracts, including required params, come from the configured IM
  provider seam:
  `Application.get_env(:salix_agent, :im_provider_mod)` — a module implementing
  the `@behaviour` defined here (`c:list_connects/1`, `c:provider_manual/1`,
  `c:call_api/4`). No seam configured ⇒ every tool raises willow's
  tool-unavailable wording (`"control db is required"`, willow's
  `resolveIMProviderToolScope` failure).

  These tools are stable registry tools for every agent role. Connect and
  operation visibility is enforced by the provider seam at runtime: the seam
  decides which connects each agent lists and, through the optional
  role-aware `c:provider_manual/2`, which provider operations each agent
  discovers. In production the router sees every external provider, while
  workers see baseline Slack reads and any operations admitted by their current
  Task execution scope. Context-aware callbacks validate the same scope for
  discovery and dispatch.

  Salix passes `agent_id` to the seam and leaves tenant/group resolution to the
  seam implementation. Group-owned search operations resolve their group scope
  at the provider owner; other operations keep the existing connect visibility
  checks. Both paths retain the session's provider plugin policy.
  """

  @normal_auto_wait_seconds SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()
  @egress_archive_broker_key :egress_archive_reservation_broker
  @egress_archive_reservation_key :egress_archive_reservation

  # A read adapter says what audience its result came from by putting a label
  # block under this key. It is runtime metadata, not content: it is popped
  # before the result is encoded, so the model never sees it and can never
  # supply it (docs/verification.md).
  @ifc_result_key "__ifc__"

  @doc """
  List IM connects visible to `agent_id`. Each connect is a JSON-able map that
  MUST carry `"connect_id"` and `"provider"` (willow's summaries add
  provider-specific fields such as `"workspace_id"` / `"wechat_id"`). The seam
  decides which connects are listable (willow hid OAuth-incomplete Slack rows
  and non-connected WeChat rows) and must include willow's fixed internal
  connect (`%{"connect_id" => "internal", "provider" => "internal"}`).
  """
  @callback list_connects(agent_id :: String.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  The provider operation manual for `platform` (willow's static
  `internalProviderManual` / `slackProviderManual` / `wechatProviderManual`
  maps). Return `{:error, :unsupported}` for unknown providers (surfaces as
  willow's `"unsupported provider"` tool error).
  """
  @callback provider_manual(platform :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  Optional agent-aware variant of `c:provider_manual/1` used for discovery
  surfaces (dynamic tool disclosure and `im.provider_apis_list`). Seams that
  implement it decide per agent which provider operations are listed; the
  production backend applies role-based access. The context-aware arity also
  includes current Task execution requests. Falls back to `c:provider_manual/1`
  when unimplemented.
  """
  @callback provider_manual(platform :: String.t(), agent_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback group_providers(agent_id :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback list_connects(String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  @callback provider_manual(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @doc "Optional owner-resolved catalog; shares scope reads across connects and their manuals."
  @callback discovery_catalog(String.t(), map()) ::
              {:ok, %{connects: [map()], manuals: map()}} | {:error, term()}
  @callback task_execution_request(String.t(), map(), map()) ::
              {:ok, String.t(), String.t()} | :none
  @optional_callbacks provider_manual: 2,
                      provider_manual: 3,
                      group_providers: 1,
                      list_connects: 2,
                      discovery_catalog: 2,
                      task_execution_request: 3

  @doc """
  Invoke one provider API. `args` is
  `%{"connect_id" => String.t(), "params" => map()}` — the validated target
  params object plus the target connect. Tool execution
  metadata, such as `"tool_call_id"`, may also be present for provider-owned
  idempotency. Return
  `{:ok, json_able}` (encoded as the tool content) or `{:error, message}`
  (surfaces as a tool error, e.g. willow's `"connect not found"` /
  `"unsupported provider"`).
  """
  @callback call_api(
              agent_id :: String.t(),
              platform :: String.t(),
              method :: String.t(),
              args :: map()
            ) :: {:ok, term()} | {:error, term()}

  @doc """
  Tool defs in stable registry order.
  """
  @spec defs() :: [{String.t(), String.t(), (map(), map() -> term()), pos_integer()}]
  def defs do
    [
      {"im.connects_list",
       "List IM messaging connects available to the current group. Each connect is one provider instance with provider and connect_id. This list excludes Plugins OAuth credentials and MCP bindings. For connected Slack accounts, also check oauth.list_credentials and mcp.list before concluding that Slack is not connected. Known connect_id/provider facts can be used directly.",
       &__MODULE__.list_im_connects/2, @normal_auto_wait_seconds},
      {"im.provider_apis_list",
       "List provider API operation ids exposed by Comma for a visible IM connect. callable=true means the local adapter and session policy allow dispatch; for operations with declared OAuth scopes, scope_availability reports granted, missing, or unknown for the exact connect. Slack's current API result remains authoritative for workspace features, channel access, payload validity, and permission drift. This is discovery only; known operation ids can be called directly. Use call(tool=\"help\", params={\"tool\":\"im_api.<provider>.<api>\"}) for one API's full schema.",
       &__MODULE__.provider_apis_list/2, @normal_auto_wait_seconds}
    ]
  end

  @doc false
  def internal_read_disclosure_entries(ctx) do
    mod = Application.get_env(:salix_agent, :im_provider_mod)

    if is_nil(mod) do
      []
    else
      case discovery_manual(mod, "internal", ctx) do
        {:ok, manual} ->
          manual_entries(manual, "internal", ctx)
          |> Enum.filter(&(&1["name"] == "im_api.internal.read_conversation"))

        _ ->
          []
      end
    end
  end

  @doc false
  def dynamic_disclosure_entries(ctx) do
    mod = Application.get_env(:salix_agent, :im_provider_mod)
    agent_id = ctx_agent_id(ctx)

    cond do
      is_nil(mod) or agent_id == "" ->
        []

      Code.ensure_loaded?(mod) && function_exported?(mod, :discovery_catalog, 2) ->
        case mod.discovery_catalog(agent_id, discovery_context(ctx)) do
          {:ok, %{connects: connects, manuals: manuals}} ->
            connects
            |> Enum.filter(&connect_visible_by_plugin?(ctx, &1))
            |> Enum.map(&connect_provider/1)
            |> Enum.uniq()
            |> Enum.sort()
            |> Enum.flat_map(&manual_entries(Map.get(manuals, &1), &1, ctx))

          _ ->
            []
        end

      true ->
        case discovery_connects(mod, ctx) do
          {:ok, connects} when is_list(connects) ->
            connects
            |> Enum.filter(&connect_visible_by_plugin?(ctx, &1))
            |> Enum.map(&connect_provider/1)
            |> Enum.reject(&(&1 == ""))
            |> Kernel.++(group_providers(mod, agent_id, ctx))
            |> Enum.uniq()
            |> Enum.sort()
            |> Enum.flat_map(&dynamic_provider_entries(mod, &1, ctx))

          _ ->
            []
        end
    end
  end

  defp ctx_agent_id(ctx) when is_map(ctx) do
    (Map.get(ctx, :agent_id) || Map.get(ctx, "agent_id") || "")
    |> present_string()
  end

  defp ctx_agent_id(_ctx), do: ""

  defp group_providers(mod, agent_id, ctx) do
    if function_exported?(mod, :group_providers, 1) do
      case mod.group_providers(agent_id) do
        {:ok, providers} when is_list(providers) ->
          Enum.filter(providers, &SalixAgent.PluginPolicy.visible_im_provider?(ctx, &1))

        _ ->
          []
      end
    else
      []
    end
  end

  defp present_string(value) when value in [nil, ""], do: ""
  defp present_string(value), do: to_string(value)

  defp dynamic_provider_entries(mod, provider, ctx) do
    case discovery_manual(mod, provider, ctx) do
      {:ok, manual} -> manual_entries(manual, provider, ctx)
      _ -> []
    end
  end

  defp manual_entries(%{"apis" => apis}, provider, ctx) when is_list(apis) do
    apis
    |> Enum.filter(&operation_allowed?(&1, ctx))
    |> Enum.map(&dynamic_operation_entry(provider, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1["name"])
  end

  defp manual_entries(_manual, _provider, _ctx), do: []

  # Discovery surfaces ask the seam for the agent-aware manual so the seam
  # decides which provider operations each agent lists. Dispatch validation
  # keeps the full manual: the seam rejects role-ineligible dispatch itself.
  defp discovery_manual(mod, provider, ctx) do
    cond do
      Code.ensure_loaded?(mod) && function_exported?(mod, :provider_manual, 3) ->
        mod.provider_manual(provider, ctx_agent_id(ctx), discovery_context(ctx))

      function_exported?(mod, :provider_manual, 2) ->
        mod.provider_manual(provider, ctx_agent_id(ctx))

      true ->
        mod.provider_manual(provider)
    end
  end

  defp discovery_connects(mod, ctx) do
    if Code.ensure_loaded?(mod) && function_exported?(mod, :list_connects, 2),
      do: mod.list_connects(ctx_agent_id(ctx), discovery_context(ctx)),
      else: mod.list_connects(ctx_agent_id(ctx))
  end

  # Session configuration is built before the per-call context exists. Resolve
  # only admitted, current origins from its envelope; never inspect content.
  defp discovery_context(%_{} = ctx), do: discovery_context(Map.from_struct(ctx))

  defp discovery_context(ctx) do
    if ctx[:trusted_origin] || ctx["trusted_origin"] do
      provider_tool_context(ctx)
    else
      # The round configuration context carries the session's admitted source
      # ids and the current turn's trusted origins as data (the kernel answers
      # both); a per-call context still carries the messages themselves.
      origins =
        case ctx[:trusted_origins] do
          origins when is_list(origins) ->
            origins

          _ ->
            ids = List.wrap(ctx[:source_message_ids] || context_source_ids(ctx))

            List.wrap(ctx[:input_messages] || ctx[:messages] || ctx["messages"])
            |> Enum.flat_map(&SalixAgent.ToolCallProvenance.message_origins(&1, ids))
        end

      origin = List.last(origins)

      ctx
      |> Map.put(:trusted_origin, origin)
      |> Map.put(:source_message_id, origin && origin["source_message_id"])
      |> provider_tool_context()
    end
  end

  # A per-call context that carries no admitted source ids still carries the
  # transcript envelope it was built from. Only that envelope (messages and
  # the last ack) is admitted for the query; the rest of the context is host
  # data and never becomes session state.
  defp context_source_ids(ctx) do
    SalixAgent.ToolCallProvenance.current_source_ids(%{
      messages: List.wrap(ctx[:messages] || ctx["messages"]),
      last_ack_message_id: ctx[:last_ack_message_id] || ctx["last_ack_message_id"] || 0
    })
  end

  defp dynamic_operation_entry(_provider, api) when not is_map(api), do: nil

  defp dynamic_operation_entry(provider, api) when is_map(api) do
    api_name = to_string(api["name"] || api[:name] || "")

    if api_name == "" do
      nil
    else
      op_id = operation_id(provider, api_name)
      summary = to_string(api["description"] || api[:description] || "")

      %{
        "name" => op_id,
        "summary" => summary,
        "manual" => operation_manual(provider, api_name, api),
        "input_schema" => operation_schema(api),
        "examples" => operation_help(provider, api_name, api)["examples"],
        "manual_available" => true,
        "helpable" => true,
        "callable" => true,
        "safety" => api["safety"] || api[:safety]
      }
      |> put_required_scopes(api)
    end
  end

  # ---- list_im_connects ----

  @doc false
  def list_im_connects(args, ctx) do
    mod = seam!()
    provider = args |> arg("provider") |> String.trim()

    case discovery_connects(mod, ctx) do
      {:ok, connects} when is_list(connects) ->
        connects =
          if provider == "" do
            connects
          else
            Enum.filter(connects, &(connect_provider(&1) == provider))
          end

        connects = Enum.filter(connects, &connect_visible_by_plugin?(ctx, &1))

        Jason.encode!(%{"connects" => connects})

      {:error, reason} ->
        raise error_message(reason)
    end
  end

  defp connect_provider(connect) when is_map(connect),
    do: to_string(connect["provider"] || connect[:provider] || "")

  defp connect_provider(_), do: ""

  defp connect_visible_by_plugin?(ctx, connect) do
    SalixAgent.PluginPolicy.visible_im_provider?(ctx, connect_provider(connect))
  end

  # ---- im.provider_apis_list ----

  @doc false
  def provider_apis_list(args, ctx) do
    provider = args |> arg("provider") |> String.trim()
    connect_id = args |> arg("connect_id") |> String.trim()
    mod = seam!()

    with {:ok, connect} <- resolve_provider_connect(mod, ctx, provider, connect_id) do
      case discovery_manual(mod, provider, ctx) do
        {:ok, %{"apis" => apis}} when is_list(apis) ->
          Jason.encode!(%{
            "provider" => provider,
            "connect_id" => if(connect_id == "", do: nil, else: connect_id),
            "apis" =>
              apis
              |> Enum.filter(&operation_allowed?(&1, ctx))
              |> Enum.map(&provider_api_summary(provider, &1, connect))
          })

        {:ok, _manual} ->
          Jason.encode!(%{"provider" => provider, "connect_id" => connect_id, "apis" => []})

        {:error, :unsupported} ->
          raise "unsupported provider"

        {:error, reason} ->
          raise error_message(reason)
      end
    end
  end

  defp resolve_provider_connect(mod, ctx, provider, connect_id) do
    case discovery_connects(mod, ctx) do
      {:ok, connects} when is_list(connects) ->
        provider_visible? =
          (Enum.any?(connects, &(connect_provider(&1) == provider)) or
             provider in group_providers(mod, ctx_agent_id(ctx), ctx)) and
            SalixAgent.PluginPolicy.visible_im_provider?(ctx, provider)

        cond do
          not provider_visible? ->
            raise "provider is not visible to this session"

          connect_id == "" ->
            {:ok, nil}

          true ->
            case Enum.find(
                   connects,
                   &(connect_provider(&1) == provider and connect_id(&1) == connect_id and
                       connect_visible_by_plugin?(ctx, &1))
                 ) do
              nil -> raise "connect not found"
              connect -> {:ok, connect}
            end
        end

      {:error, reason} ->
        raise error_message(reason)
    end
  end

  defp provider_api_summary(provider, api, connect) when is_map(api) do
    name = to_string(api["name"] || api[:name] || "")

    %{
      "operation_id" =>
        "im_api." <> provider <> "." <> String.replace_prefix(name, provider <> ".", ""),
      "api" => name,
      "summary" => to_string(api["description"] || api[:description] || ""),
      "manual_available" => true,
      "helpable" => true,
      "callable" => true
    }
    |> put_scope_availability(api, connect)
  end

  defp require_visible_connect(mod, ctx, provider, connect_id_arg) do
    case visible_connect(mod, ctx, provider, connect_id_arg) do
      {:ok, _connect} -> :ok
      {:error, reason} -> raise error_message(reason)
    end
  end

  defp visible_connect(mod, ctx, provider, connect_id_arg) do
    case discovery_connects(mod, ctx) do
      {:ok, connects} when is_list(connects) ->
        case Enum.find(
               connects,
               &(connect_provider(&1) == provider and connect_id(&1) == connect_id_arg and
                   connect_visible_by_plugin?(ctx, &1))
             ) do
          nil -> {:error, "connect not found"}
          connect -> {:ok, connect}
        end

      {:error, reason} ->
        {:error, error_message(reason)}
    end
  end

  defp connect_id(connect) when is_map(connect),
    do: to_string(connect["connect_id"] || connect[:connect_id] || "")

  defp connect_id(_), do: ""

  @doc false
  def call_dynamic_operation("im_api." <> rest, args, ctx) when is_map(args) do
    case parse_operation(rest) do
      {:ok, provider, api} ->
        mod = seam!()
        connect_id = args |> arg("connect_id") |> String.trim()
        params = drop_param(args, "connect_id")

        with :ok <- require_operation_connect(mod, ctx, provider, api, connect_id),
             :ok <- require_operation_allowed(mod, provider, api, ctx) do
          maybe_emit_messaging_activity(ctx, provider, api)
          call_seam(mod, ctx, provider, connect_id, api, params)
        end

      {:error, reason} ->
        raise reason
    end
  end

  defp parse_operation(rest) do
    case String.split(rest, ".", parts: 2) do
      [provider, api] when provider != "" and api != "" ->
        {:ok, provider, provider <> "." <> api}

      _ ->
        {:error, "invalid IM operation id"}
    end
  end

  # This runs only after Tools validated disclosure/schema and this adapter
  # confirmed the target connect. It intentionally carries no model-authored
  # arguments.
  defp maybe_emit_messaging_activity(ctx, "internal", "internal.send_message") do
    case {ctx_agent_id(ctx), ctx_session_id(ctx)} do
      {agent_id, session_id} when agent_id != "" and session_id != "" ->
        SalixAgent.ActivityEvent.typing(agent_id, session_id)

      _missing_runtime_identity ->
        :ok
    end
  end

  defp maybe_emit_messaging_activity(_ctx, _provider, _api), do: :ok

  defp ctx_session_id(ctx) when is_map(ctx) do
    (Map.get(ctx, :session_id) || Map.get(ctx, "session_id") || "")
    |> present_string()
  end

  defp ctx_session_id(_ctx), do: ""

  defp operation_help(provider, api, contract) do
    op_id = "im_api." <> provider <> "." <> String.replace_prefix(api, provider <> ".", "")

    %{
      "name" => op_id,
      "summary" => to_string(contract["description"] || contract[:description] || ""),
      "manual" => operation_manual(provider, api, contract),
      "input_schema" => operation_schema(contract),
      "examples" => %{
        "internal_llm" => %{
          "tool" => "call",
          "arguments" => %{
            "tool" => op_id,
            "params" => example_params(contract)
          }
        },
        "external_runtime" => %{
          "method" => "POST",
          "path" => "/tool/" <> op_id,
          "body" => example_params(contract)
        },
        "script" => %{
          "call" =>
            "sf_host_call(\"salix.call\", " <>
              Jason.encode!(%{"tool" => op_id, "args" => example_params(contract)}) <>
              ", 20000)"
        }
      }
    }
  end

  defp operation_schema(contract) do
    case contract["input_schema"] || contract[:input_schema] do
      %{} = schema -> add_connect_id_to_schema(schema, connect_required?(contract))
      _missing -> legacy_operation_schema(contract)
    end
  end

  defp legacy_operation_schema(contract) do
    params = contract["parameters"] || contract[:parameters] || %{}

    properties =
      params
      |> Enum.map(fn {key, desc} -> {to_string(key), parameter_schema(desc)} end)
      |> Map.new()
      |> Map.put_new("connect_id", %{
        "type" => "string",
        "description" => "connect_id from source context, user instruction, or discovery"
      })

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required_params(contract)
    }
  end

  defp add_connect_id_to_schema(schema, connect_required?) do
    schema = stringify_schema_keys(schema)

    properties =
      schema
      |> Map.get("properties", %{})
      |> Map.put_new("connect_id", %{
        "type" => "string",
        "description" => "connect_id from source context, user instruction, or discovery"
      })

    required =
      schema
      |> Map.get("required", [])
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> then(&Enum.uniq(if(connect_required?, do: ["connect_id" | &1], else: &1)))

    schema
    |> Map.put_new("type", "object")
    |> Map.put("properties", properties)
    |> Map.put("required", required)
  end

  defp stringify_schema_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_schema_keys(nested)} end)
  end

  defp stringify_schema_keys(value) when is_list(value),
    do: Enum.map(value, &stringify_schema_keys/1)

  defp stringify_schema_keys(value), do: value

  defp operation_manual(provider, api, contract) do
    required = required_params(contract)
    required_scopes = contract_list(contract, "required_scopes")
    description = to_string(contract["description"] || contract[:description] || "")

    required_line =
      if required == [],
        do: "see query/cursor alternatives in input_schema",
        else: Enum.join(required, ", ")

    [
      description,
      "Provider: #{provider}",
      "API: #{api}",
      "Required params: " <> required_line,
      required_scopes_line(required_scopes),
      case contract["task_payload_params"] do
        fields when is_list(fields) ->
          "Delegatable through internal.task.create execution_requests. Worker payload params: " <>
            Enum.join(fields, ", ") <>
            ". All other params must match the granted values, including absence."

        _ ->
          ""
      end,
      if(connect_required?(contract),
        do:
          "Use connect_id from source context, user instruction, or im.connects_list discovery.",
        else:
          "Omit connect_id for the group's connected data domains; an explicit connect_id only narrows the search."
      ),
      scope_evidence_hint(required_scopes),
      operation_provider_hint(provider, api)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp operation_provider_hint("slack", "slack.send_dm") do
    "For Slack DMs to a named or handle target without a user_id, resolve the target with slack.list_users using a query, then put the returned id into user_id. Ask for clarification if there is no clear single match."
  end

  defp operation_provider_hint("slack", _api) do
    "For Slack replies, put channel_id from the current IM provider message context into channel and put thread_ts into thread_ts when replying in a thread. For Slack DMs to a named person without user_id, resolve user_id with slack.list_users query."
  end

  defp operation_provider_hint(_provider, _api), do: ""

  defp required_scopes_line([]), do: ""
  defp required_scopes_line(scopes), do: "Required provider scopes: " <> Enum.join(scopes, ", ")

  defp scope_evidence_hint([]), do: ""

  defp scope_evidence_hint(_scopes) do
    "In im.provider_apis_list, callable=true means Comma can dispatch the operation; scope_availability is connect-specific OAuth evidence. unknown is not proof of denial, and the current provider API result remains authoritative."
  end

  defp put_required_scopes(entry, contract) do
    case contract_list(contract, "required_scopes") do
      [] -> entry
      scopes -> Map.put(entry, "required_scopes", scopes)
    end
  end

  defp put_scope_availability(entry, contract, connect) do
    required_scopes = contract_list(contract, "required_scopes")

    if required_scopes == [] do
      entry
    else
      {availability, missing_scopes} = scope_availability(connect, required_scopes)

      entry
      |> Map.put("required_scopes", required_scopes)
      |> Map.put("scope_availability", availability)
      |> maybe_put_missing_scopes(missing_scopes)
    end
  end

  defp scope_availability(nil, _required_scopes), do: {"unknown", []}

  defp scope_availability(connect, required_scopes) when is_map(connect) do
    case connect["oauth_bot_scopes"] || connect[:oauth_bot_scopes] do
      %{"status" => "known", "scopes" => scopes} ->
        scope_availability_from_snapshot(scopes, required_scopes)

      %{status: "known", scopes: scopes} ->
        scope_availability_from_snapshot(scopes, required_scopes)

      _unknown ->
        {"unknown", []}
    end
  end

  defp scope_availability(_connect, _required_scopes), do: {"unknown", []}

  defp scope_availability_from_snapshot(scopes, required_scopes)
       when is_list(scopes) and is_list(required_scopes) do
    if Enum.all?(scopes, &(is_binary(&1) and String.trim(&1) != "")) do
      granted = MapSet.new(scopes)
      missing = Enum.reject(required_scopes, &MapSet.member?(granted, &1))
      if missing == [], do: {"granted", []}, else: {"missing", missing}
    else
      {"unknown", []}
    end
  end

  defp scope_availability_from_snapshot(_scopes, _required_scopes), do: {"unknown", []}

  defp maybe_put_missing_scopes(entry, []), do: entry
  defp maybe_put_missing_scopes(entry, scopes), do: Map.put(entry, "missing_scopes", scopes)

  defp parameter_schema(%{} = spec) do
    %{"description" => parameter_description(spec)}
    |> put_optional_type(spec["type"] || spec[:type])
    |> put_optional_schema("items", spec["items"] || spec[:items])
    |> put_optional_enum(spec["enum"] || spec[:enum])
  end

  defp parameter_schema(desc), do: %{"description" => to_string(desc)}

  defp parameter_description(spec) do
    to_string(
      spec["description"] || spec[:description] || spec["summary"] || spec[:summary] || ""
    )
  end

  defp put_optional_type(schema, nil), do: schema
  defp put_optional_type(schema, type), do: Map.put(schema, "type", to_string(type))

  defp put_optional_schema(schema, key, value) when is_map(value), do: Map.put(schema, key, value)
  defp put_optional_schema(schema, _key, _value), do: schema

  defp put_optional_enum(schema, enum) when is_list(enum), do: Map.put(schema, "enum", enum)
  defp put_optional_enum(schema, _enum), do: schema

  defp example_params(contract) do
    case call_example_params(contract) do
      %{} = params ->
        params

      nil ->
        params = contract["parameters"] || contract[:parameters] || %{}

        contract
        |> contract_required_params()
        |> Map.new(&{&1, parameter_example(parameter_spec(params, &1), &1)})
        |> Map.put_new(
          "connect_id",
          "connect_id from source context, user instruction, or discovery"
        )
    end
  end

  defp call_example_params(contract) when is_map(contract) do
    case get_in(contract, ["call", "arguments", "params"]) do
      params when is_map(params) -> params
      _ -> nil
    end
  end

  defp parameter_spec(params, name) when is_map(params) do
    Enum.find_value(params, fn {key, value} ->
      if to_string(key) == name, do: value
    end)
  end

  defp parameter_spec(_params, _name), do: nil

  defp parameter_example(%{} = spec, name) do
    cond do
      Map.has_key?(spec, "example") -> spec["example"]
      Map.has_key?(spec, :example) -> spec[:example]
      to_string(spec["type"] || spec[:type] || "") == "array" -> []
      to_string(spec["type"] || spec[:type] || "") == "object" -> %{}
      to_string(spec["type"] || spec[:type] || "") == "integer" -> 1
      to_string(spec["type"] || spec[:type] || "") == "number" -> 1
      to_string(spec["type"] || spec[:type] || "") == "boolean" -> true
      true -> "required " <> name
    end
  end

  defp parameter_example(_spec, name), do: "required " <> name

  defp drop_param(args, key) do
    args
    |> Map.delete(key)
    |> Map.delete(String.to_atom(key))
  end

  defp call_seam(mod, ctx, provider, connect_id, api, params) do
    broker = maybe_start_egress_archive_broker(ctx, provider, api)

    args =
      %{"connect_id" => connect_id, "params" => params}
      |> put_present("tool_call_id", ctx[:tool_call_id])
      |> Map.put(
        "tool_context",
        provider_tool_context(ctx)
        |> maybe_put_egress_archive_broker(broker)
      )

    try do
      case mod.call_api(ctx_agent_id(ctx), provider, api, args) do
        {:ok, result} when is_binary(result) ->
          result

        {:ok, %{} = result} ->
          {reservation, result} = Map.pop(result, @egress_archive_reservation_key)
          {ifc, result} = Map.pop(result, @ifc_result_key)

          maybe_archive_committed_egress(
            ctx,
            provider,
            api,
            connect_id,
            params,
            result,
            reservation
          )

          result =
            if provider == "internal" and api == "internal.task.create",
              do: SalixAgent.Tools.TaskCard.after_create(result, ctx),
              else: result

          with_ifc(encode_provider_result(result), ifc)

        {:ok, result} ->
          encode_provider_result(result)

        {:error, %{} = failure} ->
          provider_failure(failure)

        {:error, reason} ->
          raise error_message(reason)
      end
    after
      SalixAgent.EventArchive.EgressReservationBroker.stop(broker)
    end
  end

  # A labelled read hands the dispatcher its label alongside the content;
  # `SalixAgent.IFC.Check.stamp_results/3` keeps it instead of falling back.
  defp with_ifc(content, %{"label" => label} = ifc) when is_list(label) and is_binary(content),
    do: {:tool_ifc, content, [], ifc}

  defp with_ifc(content, _absent), do: content

  defp maybe_start_egress_archive_broker(ctx, "internal", "internal.send_message") do
    SalixAgent.EventArchive.EgressReservationBroker.start(ctx, ctx_session_id(ctx))
  end

  defp maybe_start_egress_archive_broker(_ctx, _provider, _api), do: nil

  defp maybe_put_egress_archive_broker(tool_context, nil), do: tool_context

  defp maybe_put_egress_archive_broker(tool_context, broker),
    do: Map.put(tool_context, @egress_archive_broker_key, broker)

  # `internal.send_message` is the explicit user-visible commit boundary. The
  # Conversation owner asks the broker to reserve exactly when an uncommitted
  # idempotency identity is about to append. A committed retry therefore makes
  # neither another reservation nor another egress item.
  defp maybe_archive_committed_egress(
         ctx,
         "internal",
         "internal.send_message",
         connect_id,
         params,
         %{} = result,
         reservation
       ) do
    if map_value(result, "inserted") == true do
      SalixAgent.EventArchive.Emit.egress(
        ctx,
        ctx_session_id(ctx),
        %{
          "method" => "im_api.internal.send_message",
          "connect_id" => connect_id,
          "params" => Map.put(params, "connect_id", connect_id),
          "result" => result
        },
        reservation
      )
    end

    :ok
  end

  defp maybe_archive_committed_egress(
         _ctx,
         _provider,
         _api,
         _connect_id,
         _params,
         _result,
         _reservation
       ),
       do: :ok

  defp provider_failure(failure) do
    public_summary =
      failure
      |> map_value("public_summary")
      |> bounded_public_summary()

    if public_summary do
      diagnostic = failure_diagnostic(failure)

      error_class =
        failure
        |> map_value("error_class")
        |> to_string()
        |> String.trim()
        |> case do
          "" -> "provider_error"
          value -> String.slice(value, 0, 128)
        end

      {:tool_failure, diagnostic, error_class, "user_reportable", public_summary, []}
    else
      # A stable code keeps its closed facts after repair removes the
      # diagnostic text (`FailureOutcome.lean`). A map without a code keeps
      # the generic tool error class.
      case failure_code(failure) do
        nil ->
          raise error_message(failure)

        code ->
          diagnostic =
            case Jason.encode(failure) do
              {:ok, encoded} -> encoded
              {:error, _reason} -> inspect(failure)
            end

          {:tool_failure, diagnostic, code, "model_only", nil, []}
      end
    end
  end

  defp failure_code(failure) do
    ["error_class", "code"]
    |> Enum.map(&map_value(failure, &1))
    |> Enum.find_value(fn
      value when is_binary(value) ->
        if Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, value), do: value

      _other ->
        nil
    end)
  end

  defp failure_diagnostic(failure) do
    case map_value(failure, "message") do
      message when is_binary(message) and message != "" -> message
      _missing -> inspect(failure)
    end
  end

  defp bounded_public_summary(summary) when is_binary(summary) do
    case String.trim(summary) do
      "" -> nil
      value -> String.slice(value, 0, 512)
    end
  end

  defp bounded_public_summary(_summary), do: nil

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  # Historical fetch operations stage bytes into VFS. Return a provider-neutral
  # file block as well as the ordinary JSON result so a synchronous image
  # result's following model request can carry native image input, and so any
  # other attachment is announced with the workspace path the agent reads with
  # its own tools. Async results preserve this exact block array in the durable
  # result; after an unpaged tool_call.get_result, ImageRefs recovers it for the
  # subsequent request.
  defp encode_provider_result(%{"vfs_path" => path} = result) when is_binary(path) do
    mime = to_string(result["mime_type"] || result["mimetype"] || "")
    filename = to_string(result["file_name"] || result["name"] || Path.basename(path))

    file_block =
      case native_image_mime(mime, filename || path) do
        {:ok, image_mime} ->
          %{
            "type" => "image",
            "file_ref" => %{"environment_id" => "vfs", "path" => path},
            "file_name" => filename,
            "mime_type" => image_mime,
            "size" => result["size"]
          }

        :error ->
          %{
            "type" => "file",
            "path" => path,
            "file_name" => filename,
            "title" => filename,
            "mime_type" => mime,
            "size" => result["size"]
          }
      end
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    Jason.encode!([
      %{"type" => "text", "text" => Jason.encode!(result)},
      file_block
    ])
  end

  defp encode_provider_result(result), do: Jason.encode!(result)

  # Provider downloads can legitimately omit Content-Type. Only infer a native
  # image for generic MIME values and a known image extension; explicit MIME
  # remains authoritative. This stays local because salix_agent must not depend
  # on the salix_im application at compile time.
  defp native_image_mime(mime, filename) do
    declared =
      mime
      |> to_string()
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()
      |> String.downcase()

    inferred =
      case filename |> to_string() |> Path.extname() |> String.downcase() do
        ".gif" -> "image/gif"
        ".jpeg" -> "image/jpeg"
        ".jpg" -> "image/jpeg"
        ".png" -> "image/png"
        ".webp" -> "image/webp"
        _ -> nil
      end

    cond do
      String.starts_with?(declared, "image/") -> {:ok, declared}
      declared in ["", "application/octet-stream"] and is_binary(inferred) -> {:ok, inferred}
      true -> :error
    end
  end

  defp operation_id(provider, api),
    do: "im_api." <> provider <> "." <> String.replace_prefix(api, provider <> ".", "")

  defp provider_tool_context(ctx) when is_map(ctx) do
    source_message_ids = correlated_source_message_ids(ctx)
    source_message_id = current_source_message_id(ctx, source_message_ids)
    trusted_origin = ctx[:trusted_origin] || ctx["trusted_origin"]

    {source_message_ids, trusted_origins} =
      operation_provenance(ctx, source_message_id, source_message_ids, trusted_origin)

    %{
      "agent_id" => ctx[:agent_id] || ctx["agent_id"],
      "session_id" => ctx[:session_id] || ctx["session_id"],
      "source_message_id" => source_message_id,
      "source_message_ids" => source_message_ids,
      "tenant_id" => ctx[:tenant_id] || ctx["tenant_id"],
      "group_id" => ctx[:group_id] || ctx["group_id"],
      "runtime_kind" => ctx[:runtime_kind] || ctx["runtime_kind"],
      "role" => ctx[:role] || ctx["role"],
      "trusted_origin" => trusted_origin,
      "trusted_origins" => trusted_origins,
      "triage_slack_read_source" => ctx[:triage_slack_read_source],
      "triage_scopes" => ctx[:triage_scopes],
      # What the information-flow decision established about this exact call.
      # A provider operation that creates a durable resource records it as
      # that resource's provenance (docs/verification.md).
      "ifc_evidence" => ctx[:ifc_evidence] || ctx["ifc_evidence"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" or value == [] end)
    |> Map.new()
  end

  # Round's activation-wide IDs also correlate ACKs and tool completions.
  # IM authorization belongs to its current provider source instead: retaining
  # a no-wake meeting ID here makes unrelated Slack Tasks inherit that grant's
  # restrictions. Keep the full provenance only for internal/unbound calls.
  defp operation_provenance(ctx, current, source_ids, origin) do
    provider = if is_map(origin), do: origin[:provider] || origin["provider"]

    origin_source =
      if is_map(origin), do: origin[:source_message_id] || origin["source_message_id"]

    if is_binary(provider) and provider not in ["", "internal"] and
         is_binary(current) and current in source_ids and origin_source == current do
      {[current], [origin]}
    else
      {source_ids, ctx[:trusted_origins] || ctx["trusted_origins"]}
    end
  end

  defp correlated_source_message_ids(ctx) do
    source_message_ids =
      case ctx[:source_message_ids] || ctx["source_message_ids"] do
        message_ids when is_list(message_ids) and message_ids != [] -> message_ids
        _missing -> [ctx[:source_message_id] || ctx["source_message_id"]]
      end

    Enum.filter(source_message_ids, &(is_binary(&1) and &1 != ""))
  end

  defp current_source_message_id(ctx, source_message_ids) do
    current = ctx[:source_message_id] || ctx["source_message_id"]

    if is_binary(current) and current in source_message_ids,
      do: current,
      else: List.last(source_message_ids)
  end

  defp contract_required_params(contract) when is_map(contract) do
    contract
    |> Map.get("required_params", Map.get(contract, :required_params, []))
    |> case do
      params when is_list(params) -> Enum.map(params, &to_string/1)
      _ -> []
    end
  end

  defp connect_required?(contract),
    do: Map.get(contract, "connect_required", Map.get(contract, :connect_required, true)) != false

  defp required_params(contract),
    do:
      if(connect_required?(contract),
        do: ["connect_id" | contract_required_params(contract)],
        else: contract_required_params(contract)
      )

  defp require_operation_connect(mod, ctx, provider, api, connect_id) do
    group_operation? =
      case mod.provider_manual(provider) do
        {:ok, %{"apis" => apis}} ->
          Enum.any?(apis, &(operation_name(&1) == api and not connect_required?(&1)))

        _ ->
          false
      end

    if group_operation? do
      if SalixAgent.PluginPolicy.visible_im_provider?(ctx, provider),
        do: :ok,
        else: raise("provider is not visible to this session")
    else
      require_visible_connect(mod, ctx, provider, connect_id)
    end
  end

  defp require_operation_allowed(mod, provider, api, ctx) do
    case mod.provider_manual(provider) do
      {:ok, %{"apis" => apis}} when is_list(apis) ->
        case Enum.find(apis, &(operation_name(&1) == api)) do
          nil ->
            raise "unsupported provider api"

          contract ->
            if(operation_allowed?(contract, ctx), do: :ok, else: restricted_operation!())
        end

      {:error, :unsupported} ->
        raise "unsupported provider"

      {:error, reason} ->
        raise error_message(reason)

      _invalid_manual ->
        raise "unsupported provider api"
    end
  end

  defp operation_allowed?(contract, ctx) when is_map(contract) do
    role_allowed?(contract, ctx_role(ctx)) and runtime_allowed?(contract, ctx_runtime_kind(ctx))
  end

  defp operation_allowed?(_contract, _ctx), do: false

  defp role_allowed?(contract, role) do
    case contract_list(contract, "roles") do
      [] -> true
      roles -> role in roles
    end
  end

  defp runtime_allowed?(contract, runtime_kind) do
    case contract_list(contract, "runtimes") do
      [] -> true
      runtimes -> Atom.to_string(runtime_kind) in runtimes
    end
  end

  defp contract_list(contract, key) do
    contract
    |> Map.get(key, Map.get(contract, String.to_atom(key), []))
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp operation_name(contract) when is_map(contract),
    do: to_string(contract["name"] || contract[:name] || "")

  defp operation_name(_contract), do: ""

  defp ctx_role(ctx) when is_map(ctx) do
    ctx
    |> Map.get(:role, Map.get(ctx, "role", "worker"))
    |> to_string()
  end

  defp ctx_role(_ctx), do: "worker"

  defp ctx_runtime_kind(ctx) when is_map(ctx) do
    case Map.get(ctx, :runtime_kind, Map.get(ctx, "runtime_kind", :internal)) do
      kind when kind in [:internal, :external, :script] -> kind
      "external" -> :external
      "script" -> :script
      _internal_or_unknown -> :internal
    end
  end

  defp ctx_runtime_kind(_ctx), do: :internal

  defp restricted_operation!,
    do: raise("operation is not available to this agent role or runtime")

  # ---- seam + helpers ----

  defp seam! do
    Application.get_env(:salix_agent, :im_provider_mod) ||
      raise "control db is required"
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)

  defp arg(args, key), do: to_string(args[key] || args[String.to_atom(key)] || "")

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, to_string(value))
end
