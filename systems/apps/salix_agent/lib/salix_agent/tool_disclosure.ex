defmodule SalixAgent.ToolDisclosure do
  @moduledoc """
  Session-scoped tool disclosure materialization.

  This module materializes the tools that the current role/runtime can use,
  including provider-owned dynamic operations. Prompt visibility, helpability
  and callability are independent axes, and every runtime asks this module
  before exposing or executing a tool.

  MCP operations stay hidden from initial prompts and native tool listings.
  Discover them through `mcp.list`, then read a selected manual with `help`.
  The internal call schema has no catalog-dependent enum. Discovery and help
  do not rewrite the session prefix. Dispatch still checks current authority.
  External runtimes call discovered canonical names through the session tool API.
  """

  alias SalixAgent.Tools

  @hidden "hidden"
  @manual "manual"
  @summary "summary"
  @revision_contract 2

  # Staging usage, 2026-09-19..26: >=100 calls OR >=20 distinct sessions.
  # 42 catalog tools plus the direct wait_for control cover 19,984/21,695 calls.
  # Selection affects presentation only, after session capability filtering.
  @common_tools ~w(
    composio.execute
    composio.get_tool
    composio.list_connections
    device.get
    device.list
    env.exec
    fs.edit_file
    fs.read_file
    fs.write_file
    help
    im.connects_list
    im.provider_apis_list
    im_api.internal.read_conversation
    im_api.internal.send_message
    im_api.internal.task.create
    im_api.internal.triage.complete
    im_api.internal.triage.read_context
    im_api.internal.triage.read_memory
    im_api.internal.triage.read_source
    im_api.internal.update_conversation
    im_api.slack.fetch_file
    im_api.slack.get_channel_history
    im_api.slack.get_thread_replies
    im_api.slack.get_user_info
    im_api.slack.post_channel_message
    im_api.slack.post_task_card
    im_api.slack.reply_message
    im_api.slack.search
    im_api.wechat.reply_text
    loop.get
    mcp.list
    memory.write
    oauth.list_credentials
    proactive.state
    process.start
    recommendation.read
    script.run_file
    script.sdk
    tool_call.get_result
    web.http_request
    web.read_pages
    web.search
  )

  @internal_controls ~w(wait_for)
  @internal_llm_envelope ~w(call)
  @doc false
  def internal_llm_specs(_role) do
    [
      Tools.call_spec(),
      wait_for_spec(),
      SalixAgent.TurnOutcome.spec()
    ]
  end

  @doc false
  # Dynamic catalogs must not enter the provider's cached tool-schema prefix.
  # Dispatch still checks the current disclosure for every target.
  def internal_llm_specs(role, disclosure) when is_map(disclosure),
    do: internal_llm_specs(role)

  @doc false
  def external_specs(disclosure) when is_map(disclosure) do
    disclosure
    |> Map.fetch!("tools")
    |> Enum.reject(&(&1["name"] in @internal_controls or &1["name"] in @internal_llm_envelope))
    |> Enum.reject(&(&1["prompt_visibility"] == @hidden))
    |> Enum.filter(& &1["callable"])
    |> Enum.map(&entry_spec/1)
  end

  @doc false
  def prompt_section(disclosure, runtime_kind \\ :internal) when is_map(disclosure) do
    entries =
      disclosure
      |> Map.fetch!("tools")
      |> Enum.reject(&(&1["prompt_visibility"] == @hidden))

    if entries == [] do
      nil
    else
      rendered =
        entries
        |> Enum.map_join("\n", fn entry ->
          lines =
            case entry["prompt_visibility"] do
              @manual ->
                [
                  "- #{entry["name"]}: #{entry["summary"]}",
                  restriction_line(entry),
                  manual_line(entry),
                  "  schema: " <> Jason.encode!(entry["input_schema"] || %{}),
                  examples_line(entry, runtime_kind)
                ]

              _ ->
                ["- #{entry["name"]}: #{entry["summary"]}", restriction_line(entry)]
            end

          lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")
        end)

      """
      ## Tool Disclosure

      #{runtime_call_instruction(runtime_kind)} Every listed tool is callable and has a help manual unless a line under it says otherwise.

      #{rendered}
      """
      |> String.trim()
    end
  end

  # The flag line only earns its place when it carries a restriction; the
  # all-true case is stated once in the section preamble.
  defp restriction_line(entry) do
    restricted =
      Enum.reject(
        [
          {"manual_available", entry["manual_available"]},
          {"helpable", entry["helpable"]},
          {"callable", entry["callable"]}
        ],
        fn {_key, value} -> value != false end
      )

    case restricted do
      [] -> nil
      flags -> "  " <> Enum.map_join(flags, ", ", fn {key, _} -> "#{key}=false" end)
    end
  end

  # Registry manuals are the summary itself and dynamic manuals begin with
  # it, so only the part the summary does not already say is printed.
  defp manual_line(entry) do
    summary = to_string(entry["summary"] || "")
    manual = to_string(entry["manual"] || "")

    remainder =
      manual
      |> String.replace_prefix(summary, "")
      |> String.trim()

    if remainder == "", do: nil, else: "  manual: " <> remainder
  end

  # Placeholder examples generated from the schema (`"example path"`) say
  # nothing the schema does not; only authored examples are printed.
  defp examples_line(entry, runtime_kind) do
    examples = entry["examples"] || %{}

    schema = entry["input_schema"] || %{}

    if examples == %{} or examples == Tools.help_examples(entry["name"], schema) do
      nil
    else
      "  examples: " <> Jason.encode!(runtime_examples(examples, runtime_kind))
    end
  end

  @doc false
  def materialize(role, runtime_kind, ctx \\ %{}) do
    materialize_candidates(role, runtime_kind, ctx, dynamic_candidates(role, runtime_kind, ctx))
  end

  @doc false
  def materialize_prepared(role, runtime_kind, ctx, im_entries, mcp_entries)
      when is_map(ctx) and is_list(im_entries) and is_list(mcp_entries) do
    dynamic = dynamic_candidates_from(im_entries, mcp_entries)
    materialize_candidates(role, runtime_kind, ctx, dynamic)
  end

  @doc "Build a static disclosure without consulting dynamic provider seams."
  @spec materialize_static(String.t() | nil, atom(), map()) :: map()
  def materialize_static(role, runtime_kind, ctx \\ %{}) do
    materialize_candidates(role, runtime_kind, ctx, [])
  end

  defp materialize_candidates(role, runtime_kind, ctx, dynamic) do
    disabled_tools = disabled_tools(ctx)

    candidate_list =
      all_candidates()
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&role_candidate?(&1, role))
      |> Enum.filter(&runtime_candidate?(&1, runtime_kind))
      |> Kernel.++(dynamic)
      |> Enum.reject(fn candidate ->
        candidate["name"]
        |> SalixAgent.ToolPolicy.tool_permission_names()
        |> Enum.any?(&MapSet.member?(disabled_tools, &1))
      end)
      |> reject_disabled_memory_consultation(ctx)
      |> Enum.filter(&SalixAgent.PluginPolicy.allowed_tool?(ctx, &1["name"]))
      |> Enum.filter(&SalixAgent.RecommendationPolicy.allowed_disclosure?(ctx, &1))
      |> Enum.filter(&SalixAgent.GuestPolicy.allowed_disclosure?(ctx, &1))
      |> Enum.filter(&SalixAgent.InspectorPolicy.allowed_disclosure?(ctx, &1))
      |> Enum.map(&SalixAgent.InspectorPolicy.describe(&1, ctx))
      |> reject_unconfigured_capabilities(ctx)
      |> Enum.with_index()
      |> Enum.map(fn {candidate, index} -> Map.put(candidate, "__order__", index) end)

    tools =
      candidate_list
      |> Enum.map(&candidate_to_disclosure(&1, role, runtime_kind))
      |> Enum.uniq_by(& &1["name"])
      |> Enum.sort_by(& &1["__order__"])
      |> Enum.map(&Map.drop(&1, ["__order__"]))

    %{
      "revision" => revision(role, runtime_kind, tools),
      "tools" => tools
    }
  end

  @doc false
  def callable?(ctx, tool_name) do
    SalixAgent.PlatformCapabilities.allowed?(ctx, tool_name) and runtime_allowed?(ctx, tool_name) and
      match?(%{"callable" => true}, find_disclosure_entry(ctx, tool_name))
  end

  @doc false
  def helpable?(ctx, tool_name) do
    SalixAgent.PlatformCapabilities.allowed?(ctx, tool_name) and runtime_allowed?(ctx, tool_name) and
      match?(%{"helpable" => true}, find_disclosure_entry(ctx, tool_name))
  end

  @doc false
  def find_disclosure_entry(ctx, tool_name) do
    case cached_disclosure(ctx) do
      %{"tools" => tools} ->
        Enum.find(tools, &(&1["name"] == to_string(tool_name || "")))

      _ ->
        nil
    end
  end

  defp cached_disclosure(ctx) when is_map(ctx) do
    case Map.get(ctx, :tool_disclosure) do
      %{"tools" => tools} = disclosure when is_list(tools) -> disclosure
      _ -> nil
    end
  end

  defp cached_disclosure(_ctx), do: nil

  # Re-check the registry-owned runtime boundary at execution/help time rather
  # than trusting only the cached session disclosure. This keeps a session
  # created before a runtime restriction was deployed from calling a tool that
  # its stale disclosure still contains.
  defp runtime_allowed?(ctx, tool_name) do
    case Tools.find_entry(to_string(tool_name || "")) do
      nil ->
        true

      entry ->
        case Tools.entry_runtimes(entry) do
          [] -> true
          runtimes -> runtime_kind(ctx) in runtimes
        end
    end
  end

  defp runtime_kind(ctx) when is_map(ctx) do
    case Map.get(ctx, :runtime_kind, Map.get(ctx, "runtime_kind", :internal)) do
      kind when kind in [:internal, :external, :script] -> kind
      "external" -> :external
      "script" -> :script
      _internal_or_unknown -> :internal
    end
  end

  defp runtime_kind(_ctx), do: :internal

  defp runtime_call_instruction(:external) do
    "Call Salix business tools from the shell with `\"${SALIX_CLI:-salix}\" tool call <canonical_tool_name> --json '<JSON object>'`. The runtime supplies `SALIX_CLI` as an absolute executable path so login shells cannot discard the Connector-managed CLI from `PATH`; the fallback keeps non-external environments usable. The CLI routes the call with the current external runtime session's capability. If the target tool and valid parameters are already known, call it directly. Inspect an unfamiliar tool with `\"${SALIX_CLI:-salix}\" tool call help --json '{\"tool\":\"<canonical_tool_name>\"}'`."
  end

  defp runtime_call_instruction(_runtime_kind) do
    "Call the session controls `wait_for` and `end_turn` directly. Call other business tools through the single outer LLM tool named `call`. In that outer call's arguments, set `tool` to the target canonical tool, for example `fs.read_file` or `help`, and set `params` to that target tool's JSON object parameters. If the target tool and valid parameters are already known, call it directly. To inspect a tool, call target tool `help` with params like {\"tool\":\"fs.read_file\"}."
  end

  defp runtime_examples(examples, runtime_kind) when is_map(examples) do
    key =
      cond do
        runtime_kind == :external ->
          "external_runtime"

        runtime_kind == :script ->
          "script"

        true ->
          "internal_llm"
      end

    case Map.get(examples, key) do
      nil -> examples
      example -> %{key => example}
    end
  end

  defp runtime_examples(examples, _runtime_kind), do: examples

  defp all_candidates do
    registry_candidates =
      Tools.registry()
      |> Kernel.++([SalixAgent.Tools.AsyncOps.wait_for_def()])
      |> Enum.map(&registry_candidate(&1, :registry))

    registry_candidates
  end

  defp dynamic_candidates(role, runtime_kind, ctx) do
    im_ctx = ctx |> Map.put(:role, role) |> Map.put(:runtime_kind, runtime_kind)

    dynamic_candidates_from(
      SalixAgent.Tools.ImRouter.dynamic_disclosure_entries(im_ctx),
      SalixAgent.Tools.MCP.dynamic_disclosure_entries(ctx)
    )
  end

  defp dynamic_candidates_from(im_source, mcp_source) do
    im_entries =
      im_source
      |> Enum.map(fn entry ->
        entry
        |> Map.put_new("manual_available", true)
        |> Map.put_new("discovery_sources", ["im.provider_apis_list"])
        |> Map.put("__source__", :dynamic)
      end)

    mcp_entries =
      mcp_source
      |> Enum.map(fn entry ->
        entry
        |> Map.put_new("manual_available", true)
        |> Map.put_new("discovery_sources", ["mcp.list", "mcp_manager.reconnect"])
        |> Map.put("__source__", :dynamic)
      end)

    im_entries ++ mcp_entries
  end

  defp registry_candidate(entry, source) do
    name = Tools.entry_name(entry)
    schema = Tools.entry_schema(entry)

    if name in @internal_llm_envelope do
      nil
    else
      %{
        "name" => name,
        "summary" => Tools.entry_description(entry),
        "manual_available" => true,
        "input_schema" => schema,
        "manual" =>
          case name do
            "ui.create" ->
              SalixAgent.Tools.DynamicUI.manual()

            "meeting.preparation.publish_report" ->
              SalixAgent.Tools.MeetingPreparation.manual(name)

            "meeting.preparation.publish_personal_report" ->
              SalixAgent.Tools.MeetingPreparation.manual(name)

            _ ->
              Tools.entry_description(entry)
          end,
        "examples" => Tools.help_examples(name, schema),
        "discovery_sources" => [],
        "roles" => Tools.entry_roles(entry),
        "runtimes" => Tools.entry_runtimes(entry),
        "__source__" => source
      }
      |> maybe_put_safety(Tools.entry_safety(entry))
    end
  end

  defp candidate_to_disclosure(candidate, _role, runtime_kind) do
    name = candidate["name"]

    %{
      "name" => name,
      "prompt_visibility" =>
        if(name in @internal_controls, do: @hidden, else: default_visibility(candidate)),
      "summary" => candidate["summary"] || "",
      "manual_available" => candidate["manual_available"] != false,
      "helpable" => candidate["helpable"] != false,
      "callable" => candidate["callable"] != false and callable_surface?(name, runtime_kind),
      "input_schema" => candidate["input_schema"] || %{},
      "manual" => candidate["manual"] || candidate["summary"] || "",
      "examples" => candidate["examples"] || %{},
      "discovery_sources" => candidate["discovery_sources"] || [],
      "__order__" => candidate["__order__"]
    }
    |> maybe_put_safety(candidate["safety"])
  end

  defp maybe_put_safety(disclosure, safety) when is_binary(safety) and safety != "",
    do: Map.put(disclosure, "safety", safety)

  defp maybe_put_safety(disclosure, _safety), do: disclosure

  defp callable_surface?(name, :internal) when name in @internal_controls, do: true
  defp callable_surface?(name, _runtime_kind) when name in @internal_controls, do: false
  defp callable_surface?(_name, _runtime_kind), do: true

  defp runtime_candidate?(%{"runtimes" => runtimes}, runtime_kind)
       when is_list(runtimes) and runtimes != [],
       do: runtime_kind in runtimes

  defp runtime_candidate?(%{"name" => name}, runtime_kind) when name in @internal_controls,
    do: runtime_kind == :internal

  defp runtime_candidate?(_candidate, _runtime_kind), do: true

  defp role_candidate?(%{"roles" => roles}, role) when is_list(roles) and roles != [] do
    normalize_role(role) in roles
  end

  defp role_candidate?(_candidate, _role), do: true

  # Production runtime configuration always supplies this Group-owned flag.
  # Its absence keeps static/offline registry inspection role-based; an
  # explicit false removes the tool from prompt, help, and call surfaces.
  defp reject_disabled_memory_consultation(candidates, ctx) do
    enabled =
      Map.get(
        ctx,
        :memory_ask_worker_enabled,
        Map.get(ctx, "memory_ask_worker_enabled", :not_materialized)
      )

    if enabled == false do
      Enum.reject(candidates, &(&1["name"] == "memory.ask_worker"))
    else
      candidates
    end
  end

  # ---- tenant-configuration capability gating ----

  # `oauth.*` and `composio.*` are integration surfaces a tenant explicitly
  # opts into (OAuth client credentials / a Composio API key, each with a
  # platform-default fallback). A tenant on only one path should not carry the
  # other path's dead tools in every session prompt, so a capability family
  # whose tenant configuration definitively resolves to :not_configured is
  # dropped from the disclosure entirely (not just hidden — it also stops
  # being callable/helpable).
  #
  # Fail-open on anything less than a definitive answer: no wired store seam
  # (bare runtimes/tests), a blank tenant in ctx, or a transient store error
  # keeps the family visible — suppression must never depend on store uptime,
  # and the tools themselves error politely when actually unconfigured.
  defp reject_unconfigured_capabilities(candidates, ctx) do
    tenant = tenant_id(ctx)

    candidates =
      if tenant == "" do
        candidates
      else
        candidates
        |> maybe_reject_family("oauth.", fn -> oauth_configured?(tenant) end)
        |> maybe_reject_family("composio.", fn -> composio_configured?(tenant) end)
      end

    candidates
    |> maybe_reject_family("email.", fn -> owner_emails_configured?(ctx) end)
    |> maybe_reject_family("video.generate", fn -> video_configured?(ctx) end)
  end

  defp video_configured?(ctx) do
    agent = Map.get(ctx, :agent_id, Map.get(ctx, "agent_id"))

    if is_nil(Application.get_env(:salix_agent, :media_resolver)) or
         not is_binary(agent) or agent == "" do
      true
    else
      case SalixAgent.MediaResolver.resolve(agent) do
        {:ok, media} when is_map(media) ->
          SalixAgent.MediaResolver.generation_configured?(media["video_config"])

        {:ok, nil} ->
          false

        _ ->
          true
      end
    end
  end

  defp maybe_reject_family(candidates, prefix, configured_fn) do
    has_family? = Enum.any?(candidates, &String.starts_with?(&1["name"], prefix))

    if has_family? and not configured_fn.() do
      Enum.reject(candidates, &String.starts_with?(&1["name"], prefix))
    else
      candidates
    end
  end

  # Any supported provider with resolvable client credentials (tenant record
  # or platform default — the store's provider_app already falls back) keeps
  # the oauth.* family visible.
  defp oauth_configured?(tenant) do
    case SalixAgent.OAuthStore.impl() do
      nil ->
        true

      _mod ->
        Enum.any?(SalixStore.OAuth.Adapters.supported(), fn provider ->
          case SalixAgent.OAuthStore.provider_app(tenant, provider) do
            {:ok, _app} -> true
            {:error, :not_configured} -> false
            _other -> true
          end
        end)
    end
  end

  # `email.send_to_owners` is only useful when the session's group carries a
  # non-empty platform-managed `owner_emails` list, so the family is dropped
  # when the group record definitively has none. Fail-open mirrors the tenant
  # gates above: no wired group-context seam, blank tenant/group in ctx, or a
  # transient store error keeps the family visible.
  defp owner_emails_configured?(ctx) do
    tenant = tenant_id(ctx)
    group = group_id(ctx)

    cond do
      is_nil(Application.get_env(:salix_agent, :group_context_mod)) ->
        true

      tenant == "" or group == "" ->
        true

      true ->
        case SalixAgent.GroupContext.get(group, tenant) do
          {:ok, record} -> SalixAgent.Tools.OwnerEmail.owner_emails(record) != []
          {:error, :not_found} -> false
          _other -> true
        end
    end
  end

  defp composio_configured?(tenant) do
    case SalixAgent.ComposioStore.impl() do
      nil ->
        true

      _mod ->
        case SalixAgent.ComposioStore.settings(tenant) do
          {:ok, _settings} -> true
          {:error, :not_configured} -> false
          _other -> true
        end
    end
  end

  defp tenant_id(ctx) when is_map(ctx) do
    ctx
    |> Map.get(:tenant_id, Map.get(ctx, "tenant_id", ""))
    |> to_string()
    |> String.trim()
  end

  defp tenant_id(_ctx), do: ""

  defp group_id(ctx) when is_map(ctx) do
    ctx
    |> Map.get(:group_id, Map.get(ctx, "group_id", ""))
    |> to_string()
    |> String.trim()
  end

  defp group_id(_ctx), do: ""

  defp disabled_tools(ctx) when is_map(ctx) do
    ctx
    |> Map.get(:disabled_tools, Map.get(ctx, "disabled_tools", []))
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp disabled_tools(_ctx), do: MapSet.new()

  defp normalize_role(nil), do: "worker"
  defp normalize_role(role), do: to_string(role)

  defp default_visibility(%{"name" => name}) when name in @common_tools, do: @manual

  defp default_visibility(%{"name" => name, "__source__" => :dynamic}) do
    dynamic_visibility(name)
  end

  defp default_visibility(%{"name" => name}) do
    if Enum.any?(discovery_namespaces(), &String.starts_with?(name, &1 <> ".")),
      do: @hidden,
      else: @summary
  end

  @doc false
  def discovery_namespaces,
    do: ~w(mcp_manager plugin calendar inbound_api ssh browser im_api.internal.label)

  defp dynamic_visibility("im_api.internal.task." <> _operation), do: @manual
  defp dynamic_visibility("im_api.internal.search_conversations"), do: @manual
  defp dynamic_visibility("im_api.internal.read_conversation"), do: @manual
  defp dynamic_visibility("im_api.internal.add_agent_participant"), do: @manual
  defp dynamic_visibility("im_api.internal.update_conversation"), do: @manual
  defp dynamic_visibility("im_api.internal.label." <> _operation), do: @hidden
  defp dynamic_visibility("im_api.internal.send_message"), do: @manual
  # Card publication is a standing Router obligation after every Slack-created
  # Task, and a hidden operation's existence cannot be discovered without first
  # reading the provider manual — so this one Slack operation stays visible.
  defp dynamic_visibility("im_api.slack.post_task_card"), do: @summary
  defp dynamic_visibility("im_api.telegram.open_task_topic"), do: @summary
  # A live caller waits on every Router answer; reading the manual first would
  # add a model round to each call's first reply.
  defp dynamic_visibility("im_api.voice.say"), do: @summary
  defp dynamic_visibility("mcp." <> _name), do: @hidden
  defp dynamic_visibility(_name), do: @hidden

  defp entry_spec(entry) do
    case Tools.find_entry(entry["name"]) do
      nil ->
        %{
          "name" => entry["name"],
          "description" => entry["summary"] || entry["manual"] || "",
          "input_schema" => entry["input_schema"] || %{"type" => "object"},
          "auto_wait_timeout_seconds" =>
            SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()
        }

      _entry ->
        spec_for!(entry["name"])
    end
  end

  defp spec_for!(name) do
    case Tools.find_entry(name) do
      nil ->
        raise "tool #{inspect(name)} missing from registry"

      entry ->
        %{
          "name" => name,
          "description" => Tools.entry_description(entry),
          "input_schema" => Tools.entry_schema(entry),
          "auto_wait_timeout_seconds" => Tools.entry_auto_wait_seconds(entry)
        }
    end
  end

  defp wait_for_spec do
    entry = SalixAgent.Tools.AsyncOps.wait_for_def()

    %{
      "name" => "wait_for",
      "description" => Tools.entry_description(entry),
      "input_schema" => Tools.entry_schema(entry),
      "auto_wait_timeout_seconds" => Tools.entry_auto_wait_seconds(entry)
    }
  end

  defp revision(role, runtime_kind, tools) do
    entries =
      tools
      |> Enum.map(fn entry ->
        Map.take(entry, [
          "name",
          "prompt_visibility",
          "summary",
          "manual",
          "input_schema",
          "examples",
          "manual_available",
          "helpable",
          "callable",
          "discovery_sources"
        ])
      end)
      |> Enum.sort_by(& &1["name"])

    :crypto.hash(
      :sha256,
      Jason.encode!(%{
        contract: @revision_contract,
        role: role,
        runtime_kind: runtime_kind,
        tools: entries
      })
    )
    |> Base.encode16(case: :lower)
  end
end
