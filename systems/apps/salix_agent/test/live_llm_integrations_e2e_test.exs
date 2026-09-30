defmodule SalixAgent.LiveLlmIntegrationsE2eTest do
  @moduledoc """
  Real-model checks for integration decisions that deterministic adapter tests
  cannot exercise. External systems terminate at local seams; the LLM,
  session actor, round driver, disclosure policy, call envelope, tool
  dispatcher, and workspace commits are the production implementations.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.LiveLlmTestSupport, as: Live

  @moduletag :live_llm
  @moduletag timeout: 300_000

  defmodule IntegrationIMProvider do
    @moduledoc false
    @behaviour SalixAgent.Tools.ImRouter

    @state_key {__MODULE__, :state}

    def configure(owner, feishu_help_code \\ nil) do
      :persistent_term.put(@state_key, %{owner: owner, feishu_help_code: feishu_help_code})
    end

    def set_owner(pid), do: configure(pid)

    def set_thread_marker(marker) do
      :persistent_term.put(@state_key, Map.put(state!(), :thread_marker, marker))
    end

    def set_context_marker(marker) do
      :persistent_term.put(@state_key, Map.put(state!(), :context_marker, marker))
    end

    def enable_internal_calls do
      :persistent_term.put(@state_key, Map.put(state!(), :internal_passthrough, true))
    end

    def clear_owner, do: :persistent_term.erase(@state_key)

    @impl true
    def list_connects(_agent_id) do
      {:ok,
       [
         %{"connect_id" => "internal", "provider" => "internal"},
         %{"connect_id" => "feishu-live", "provider" => "feishu"},
         %{
           "connect_id" => "slack-live",
           "provider" => "slack",
           "workspace_id" => "W-LIVE",
           "workspace_name" => "Live Integration Workspace"
         }
       ]}
    end

    @impl true
    def provider_manual("internal") do
      if Map.get(state!(), :internal_passthrough, false),
        do: SalixIM.Provider.provider_manual("internal"),
        else: stub_internal_manual()
    end

    def provider_manual("feishu") do
      %{feishu_help_code: help_code} = state!()

      {:ok,
       %{
         "provider" => "feishu",
         "apis" => [
           %{
             "name" => "feishu.reply_text",
             "safety" => "write",
             "description" => "Reply visibly to one exact Feishu message.",
             "required_params" => ["message_id", "text", "manual_code"],
             "parameters" => %{
               "message_id" => "Exact inbound Feishu message id.",
               "text" => "Exact visible reply text.",
               "manual_code" =>
                 "Provider policy code required for this operation. Use exactly #{help_code}.",
               "chat_id" => "Optional source chat id.",
               "reply_in_thread" => "Optional boolean."
             }
           },
           %{
             "name" => "feishu.send_text",
             "safety" => "write",
             "description" => "Send a proactive Feishu message to a chat.",
             "required_params" => ["receive_id", "text"],
             "parameters" => %{
               "receive_id" => "Exact target chat id.",
               "text" => "Message body."
             }
           }
         ]
       }}
    end

    def provider_manual("slack") do
      {:ok,
       %{
         "provider" => "slack",
         "apis" => [
           %{
             "name" => "slack.list_channels",
             "safety" => "read",
             "description" =>
               "List one bounded page of visible Slack channels. A page may be short or empty while next_cursor is non-empty. For a named channel, keep the same filters and follow every non-empty next_cursor until the channel is found or pagination is exhausted; never use the returned row count as the stopping condition.",
             "required_params" => [],
             "parameters" => %{
               "cursor" => "Pagination cursor returned as next_cursor.",
               "limit" => "Optional upper bound for one Slack virtual page, max 200.",
               "types" => "Optional comma-separated Slack conversation types.",
               "exclude_archived" => "Optional boolean archive filter."
             }
           },
           %{
             "name" => "slack.post_message",
             "safety" => "write",
             "description" =>
               "Post a message to an exact Slack channel id. Resolve named channels with paginated slack.list_channels; never guess an id.",
             "required_params" => ["channel", "text"],
             "parameters" => %{
               "channel" => "Exact Slack channel id returned by slack.list_channels.",
               "text" => "Exact message body.",
               "thread_ts" => "Optional root timestamp for a reply in an existing thread."
             }
           },
           %{
             "name" => "slack.create_channel",
             "safety" => "write",
             "description" =>
               "Create a channel on an explicit user request; the bot becomes a member. Use the returned channel id to invite people.",
             "required_params" => ["name"],
             "parameters" => %{
               "name" => "Requested channel name.",
               "is_private" => "Optional boolean."
             }
           },
           %{
             "name" => "slack.invite_users",
             "safety" => "write",
             "description" => "Invite requested users to a channel the bot is a member of.",
             "required_params" => ["channel", "users"],
             "parameters" => %{
               "channel" => "Exact channel id.",
               "users" => "List of Slack user ids."
             }
           },
           %{
             "name" => "slack.get_channel_history",
             "safety" => "read",
             "description" => "Read one page of top-level channel messages, newest first.",
             "required_params" => ["channel"],
             "parameters" => %{
               "channel" => "Source channel id.",
               "latest" => "Optional upper timestamp bound.",
               "oldest" => "Optional lower timestamp bound.",
               "inclusive" => "Include boundary timestamps when true.",
               "limit" => "Maximum message count.",
               "cursor" => "Pagination cursor."
             }
           },
           %{
             "name" => "slack.search",
             "safety" => "read",
             "description" => "Search indexed Slack messages including replies, newest first.",
             "required_params" => ["query"],
             "parameters" => %{
               "query" => "Keywords with optional in:C_CHANNEL_ID and before:YYYY-MM-DD filters.",
               "count" => "Maximum match count.",
               "cursor" => "Pagination cursor.",
               "sort" => "Only timestamp is supported.",
               "sort_dir" => "asc or desc."
             }
           },
           %{
             "name" => "slack.get_thread_replies",
             "safety" => "read",
             "description" =>
               "Read the earliest chronological page before a known Slack thread message. Start with the source message_ts as before_ts, then follow every non-empty next_cursor until pagination is exhausted.",
             "required_params" => ["channel", "ts"],
             "parameters" => %{
               "channel" => "Exact source channel id.",
               "ts" => "Exact root thread_ts.",
               "before_ts" => "Exclusive message timestamp for the first page only.",
               "cursor" => "Pagination cursor returned as next_cursor.",
               "limit" => "Page size, at most 15."
             }
           },
           %{
             "name" => "slack.list_users",
             "safety" => "read",
             "description" =>
               "List visible Slack users. Resolve a named person with query and follow next_cursor until a clear match is found.",
             "required_params" => [],
             "parameters" => %{
               "query" => "Name, handle, display name, or title to match.",
               "cursor" => "Pagination cursor returned as next_cursor.",
               "limit" => "Optional page size."
             }
           },
           %{
             "name" => "slack.send_dm",
             "safety" => "write",
             "description" =>
               "Send a DM to an exact Slack user_id. Resolve names with paginated slack.list_users; never guess an id.",
             "required_params" => ["user_id", "text"],
             "parameters" => %{
               "user_id" => "Exact Slack user id returned by slack.list_users.",
               "text" => "Exact DM body."
             }
           }
         ]
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    defp stub_internal_manual() do
      {:ok,
       %{
         "provider" => "internal",
         "apis" => [
           %{
             "name" => "internal.send_message",
             "safety" => "write",
             "description" => "Send a visible internal conversation message.",
             "required_params" => ["conversation_id", "content"],
             "parameters" => %{
               "conversation_id" => "Conversation id from trusted source context.",
               "content" => "Message body."
             }
           }
         ]
       }}
    end

    @impl true
    def call_api(agent_id, provider, api, args) do
      send(owner!(), {:integration_im_call, agent_id, provider, api, args})

      if provider == "internal" and Map.get(state!(), :internal_passthrough, false),
        do: SalixIM.Provider.call_api(agent_id, provider, api, args),
        else: dispatch(provider, api, args)
    end

    defp dispatch("feishu", "feishu.reply_text", args) do
      if get_in(args, ["params", "manual_code"]) == state!().feishu_help_code do
        {:ok, %{"message_id" => "om-live-reply", "status" => "sent"}}
      else
        {:error, :invalid_manual_code}
      end
    end

    defp dispatch("slack", "slack.list_users", args) do
      case get_in(args, ["params", "cursor"]) do
        "page-2" ->
          {:ok,
           %{
             "users" => [
               %{
                 "id" => "U_ADA_LIVE",
                 "name" => "ada",
                 "real_name" => "Ada Lovelace",
                 "display_name" => "Ada"
               }
             ],
             "next_cursor" => ""
           }}

        _first_page ->
          {:ok,
           %{
             "users" => [
               %{
                 "id" => "U_GRACE_LIVE",
                 "name" => "grace",
                 "real_name" => "Grace Hopper",
                 "display_name" => "Grace"
               }
             ],
             "next_cursor" => "page-2"
           }}
      end
    end

    defp dispatch("slack", "slack.list_channels", args) do
      case get_in(args, ["params", "cursor"]) do
        "channel-page-2" ->
          {:ok,
           %{
             "channels" => [
               %{"id" => "C_HIPPO_LIVE", "name" => "hippo"},
               %{"id" => "C_AFTER_HIPPO", "name" => "after-hippo"}
             ],
             "next_cursor" => ""
           }}

        _first_page ->
          {:ok,
           %{
             "channels" =>
               Enum.map(1..31, fn index ->
                 %{
                   "id" => "C_PAGE_1_#{String.pad_leading(Integer.to_string(index), 2, "0")}",
                   "name" => "page-1-channel-#{index}"
                 }
               end),
             "next_cursor" => "channel-page-2"
           }}
      end
    end

    defp dispatch("slack", "slack.get_channel_history", args) do
      params = args["params"] || %{}

      messages =
        if params["latest"] == "1790000000.000100" do
          [origin_message()]
        else
          [
            %{"ts" => "1800000000.000200", "text" => "奖金。"},
            %{"ts" => "1800000000.000150", "text" => "这是什么？"},
            %{
              "ts" => "1800000000.000100",
              "text" => "#{state!().context_marker} 活动：上个月的 $500，表彰优秀 demo、客户合作和可靠性改进。"
            }
          ]
        end

      {:ok, %{"messages" => messages, "next_cursor" => ""}}
    end

    defp dispatch("slack", "slack.search", args) do
      query = get_in(args, ["params", "query"]) || ""

      matches =
        if String.contains?(query, ["500", "奖金", state!().context_marker]),
          do: [origin_message()],
          else: []

      {:ok, %{"messages" => matches, "next_cursor" => ""}}
    end

    defp origin_message do
      %{
        "channel" => "C_CONTEXT_LIVE",
        "ts" => "1790000000.000100",
        "text" =>
          "#{state!().context_marker} 奖金活动最初来自 ORIGIN-#{state!().context_marker} 提案：每月留出 $500，由团队提名奖励帮助同事完成交付的人。",
        "permalink" => "https://example.slack.com/archives/C_CONTEXT_LIVE/p1790000000000100"
      }
    end

    defp dispatch("slack", "slack.create_channel", args) do
      {:ok,
       %{"channel" => %{"id" => "C_CREATED_LIVE", "name" => get_in(args, ["params", "name"])}}}
    end

    defp dispatch("slack", "slack.invite_users", _args), do: {:ok, %{"ok" => true}}

    defp dispatch("slack", "slack.get_thread_replies", %{
           "params" => %{"channel" => "C_UNAVAILABLE_LIVE"}
         }) do
      {:error, "Slack history access is unavailable; an administrator must reconnect Slack."}
    end

    defp dispatch("slack", "slack.get_thread_replies", args) do
      params = args["params"] || %{}

      case {params["before_ts"], params["cursor"]} do
        {"1800000000.000300", nil} ->
          {:ok,
           %{
             "messages" => [
               %{
                 "ts" => "1800000000.000200",
                 "user" => "U_GRACE_LIVE",
                 "text" => "The final instruction is earlier in this thread."
               }
             ],
             "next_cursor" => "thread-page-2"
           }}

        {nil, "thread-page-2"} ->
          {:ok,
           %{
             "messages" => [
               %{
                 "ts" => "1800000000.000100",
                 "user" => "U_ADA_LIVE",
                 "text" =>
                   "When I later agree, reply in this thread with exactly #{state!().thread_marker}."
               }
             ],
             "next_cursor" => ""
           }}

        bounds ->
          {:error, {:unexpected_thread_bounds, bounds}}
      end
    end

    defp dispatch("slack", "slack.post_message", args) do
      {:ok,
       %{
         "channel" => get_in(args, ["params", "channel"]),
         "thread_ts" => get_in(args, ["params", "thread_ts"]),
         "ts" => "1800000000.000400",
         "ok" => true
       }}
    end

    defp dispatch("slack", "slack.send_dm", _args) do
      {:ok, %{"channel" => "D_ADA_LIVE", "ts" => "1800000000.000100", "ok" => true}}
    end

    defp dispatch(_provider, _api, _args), do: {:ok, %{"ok" => true}}

    defp owner!, do: state!().owner
    defp state!, do: :persistent_term.get(@state_key)
  end

  defmodule InventoryMCPProvider do
    @moduledoc false
    @state_key {__MODULE__, :state}
    @operation "mcp.inventory.lookup_batch"

    def configure(owner, marker) do
      :persistent_term.put(@state_key, %{owner: owner, marker: marker})
    end

    def clear, do: :persistent_term.erase(@state_key)

    def provider_state(_agent_id), do: {:ok, %{"revision" => "inventory-live-v1"}}

    def dynamic_disclosure_entries(_agent_id) do
      {:ok,
       [
         %{
           "name" => @operation,
           "summary" =>
             "Look up an inventory catalog batch by its exact catalog key. A provider-defined policy code documented only in help is also required.",
           "manual" =>
             "Look up one catalog batch. catalog_key and backorder_policy_code are required. When the user requests backorders, set backorder_policy_code to exactly BX-INCLUDE-17.",
           "input_schema" => %{
             "type" => "object",
             "additionalProperties" => false,
             "properties" => %{
               "catalog_key" => %{"type" => "string"},
               "backorder_policy_code" => %{
                 "type" => "string",
                 "enum" => ["BX-INCLUDE-17", "BX-EXCLUDE-04"]
               }
             },
             "required" => ["catalog_key", "backorder_policy_code"]
           }
         }
       ]}
    end

    def call_tool(agent_id, "inventory", "lookup_batch", args, _ctx) do
      %{owner: owner, marker: marker} = :persistent_term.get(@state_key)
      send(owner, {:integration_mcp_call, agent_id, args})

      {:ok,
       %{
         "status" => "completed",
         "content" =>
           Jason.encode!(%{
             "catalog_key" => args["catalog_key"],
             "warehouse" => "WH-#{marker}",
             "available" => 17,
             "backorder_included" => args["backorder_policy_code"] == "BX-INCLUDE-17"
           })
       }}
    end

    def cancel_tool_call(_agent_id, _operation_id, _tool_call_id, _reason, _ctx), do: :ok
  end

  defmodule MeetingPreparationSeam do
    @moduledoc false
    @state_key {__MODULE__, :state}

    def configure(owner, plan_id, revision) do
      :persistent_term.put(@state_key, %{
        owner: owner,
        plan_id: plan_id,
        revision: revision,
        opened: false,
        decision: nil,
        baseline: nil
      })
    end

    def clear, do: :persistent_term.erase(@state_key)
    def snapshot, do: :persistent_term.get(@state_key)

    def open_trigger(group_id, plan_id, "decision", revision, caller_agent_id, _session_id) do
      state = snapshot()

      if plan_id != state.plan_id or revision != state.revision do
        {:error, :stale_dispatch_revision}
      else
        send(state.owner, {
          :integration_meeting_call,
          :open_trigger,
          group_id,
          plan_id,
          revision,
          caller_agent_id
        })

        :persistent_term.put(@state_key, %{state | opened: true})

        {:ok,
         %{
           "status" => "opened",
           "context" => %{
             "agenda" => ["Review the already-complete launch checklist"],
             "known_facts" => ["Owners and launch criteria are present"],
             "gaps" => []
           },
           "required_follow_up" => %{
             "tool" => "meeting.preparation.record_decision",
             "must_complete_before_finish" => true,
             "allowed_decisions" => ["required", "not_required"],
             "meeting_plan_id" => plan_id,
             "dispatch_revision" => revision,
             "baseline_requirement" => "Record only bounded known facts and gaps."
           }
         }}
      end
    end

    def record_decision(
          group_id,
          plan_id,
          revision,
          decision,
          baseline,
          caller_agent_id,
          _session_id
        ) do
      state = snapshot()

      cond do
        not state.opened ->
          {:error, :decision_trigger_not_opened}

        plan_id != state.plan_id or revision != state.revision ->
          {:error, :stale_dispatch_revision}

        true ->
          send(state.owner, {
            :integration_meeting_call,
            :record_decision,
            group_id,
            plan_id,
            revision,
            decision,
            baseline,
            caller_agent_id
          })

          :persistent_term.put(
            @state_key,
            %{state | decision: decision, baseline: baseline}
          )

          {:ok,
           %{
             "meeting_plan_id" => plan_id,
             "preparation" => %{
               "research_decision" => decision,
               "baseline" => baseline
             }
           }}
      end
    end
  end

  defmodule ScheduleSeam do
    @moduledoc false
    @state_key {__MODULE__, :state}

    def configure(owner), do: :persistent_term.put(@state_key, %{owner: owner, schedules: []})
    def clear, do: :persistent_term.erase(@state_key)
    def snapshot, do: :persistent_term.get(@state_key)

    def create(id, params) do
      state = snapshot()

      schedule =
        params
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.put("id", id)
        |> Map.put("receiver", "agent")

      :persistent_term.put(@state_key, %{state | schedules: state.schedules ++ [schedule]})
      send(state.owner, {:integration_schedule_create, schedule})
      {:ok, schedule}
    end

    def list_by_agents(agent_ids) do
      {:ok, Enum.filter(snapshot().schedules, &(&1["agent_id"] in agent_ids))}
    end

    def delete_agent_owned(id, agent_id) do
      state = snapshot()

      case Enum.split_with(state.schedules, &(&1["id"] == id and &1["agent_id"] == agent_id)) do
        {[], _rest} ->
          {:error, :not_found}

        {_deleted, rest} ->
          :persistent_term.put(@state_key, %{state | schedules: rest})
          :ok
      end
    end
  end

  setup_all do
    {:ok, llm: Live.llm_config!()}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    restore_runtime = Live.install_runtime!()

    # The shared test config disables cluster background sweeps. Run the real
    # timer owner here so a live model's intentional wait_for call can expire
    # through the same durable delivery path used in production.
    start_supervised!(SalixCluster.Timers)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      IntegrationIMProvider.clear_owner()
      InventoryMCPProvider.clear()
      MeetingPreparationSeam.clear()
      ScheduleSeam.clear()
      restore_runtime.()
    end)

    :ok
  end

  test "skill projection applies hidden reference rules to a persisted artifact",
       %{llm: llm} do
    suffix = Live.unique_suffix()
    marker = String.upcase(suffix)
    skill_id = "blue-orchid-#{suffix}"
    artifact_path = "/artifacts/orchid-#{suffix}.txt"
    expected = "ORCHID-83-#{marker}"

    %{group_id: group_id, agent_id: agent_id, session_id: session_id} =
      new_agent!(llm, "worker",
        system_prompt:
          "Apply matching installed skills faithfully. Perform requested filesystem work instead of merely describing it."
      )

    skill_ctx = %{group_id: group_id, agent_id: agent_id}

    assert {:ok, create_event} =
             SalixAgent.SkillStore.prepare_group_create(skill_ctx, %{
               "skill_id" => skill_id,
               "name" => "Blue Orchid Checksum #{suffix}",
               "description" =>
                 "Use for a blue-orchid checksum of three integers; the rules are intentionally available only inside the skill files.",
               "content" => """
               ---
               name: Blue Orchid Checksum #{suffix}
               description: Use for a blue-orchid checksum of three integers.
               ---

               Before calculating, read `/.runtime/skills/#{skill_id}/references/rules.md`.
               Follow that reference exactly. You MUST use `script.run` (read `script.sdk` first) for the arithmetic and
               MUST write the exact formatted result to the user-requested path with
               `fs.write_file`. Do not answer from memory or mental arithmetic.
               """
             })

    assert {:ok, _} =
             SalixAgent.SkillStore.commit_operation(
               "live-skill-create-#{suffix}",
               %{"skill_id" => skill_id},
               [create_event]
             )

    assert {:ok, group_skills} = SalixAgent.SkillStore.read_scope(:group, group_id)

    skill =
      group_skills.skills
      |> Map.fetch!(skill_id)
      |> Map.put("scope", %{"layer" => "group", "id" => group_id})

    assert {:ok, reference_event} =
             SalixAgent.SkillStore.prepare_file_write(
               skill_ctx,
               skill,
               "references/rules.md",
               """
               For inputs a, b, c compute `(a * 7) + (b * 11) + c` in JavaScript.
               Format the file as exactly `ORCHID-<number>-#{marker}` with no explanation.
               """
             )

    assert {:ok, _} =
             SalixAgent.SkillStore.commit_operation(
               "live-skill-reference-#{suffix}",
               %{"skill_id" => skill_id},
               [reference_event]
             )

    Live.flush_notifications!()

    assert {:ok, _} =
             SalixAgent.deliver(
               agent_id,
               %{
                 session_id: session_id,
                 content:
                   "Compute the blue-orchid checksum for a=3, b=5, c=7 and save only the exact result to #{artifact_path}. Use the matching installed skill."
               },
               source_message_id: "live-integrations-1:#{agent_id}"
             )

    _session = Live.await_session_settled!(agent_id, session_id)
    assert {:ok, body} = SalixAgent.AgentWorkspace.read(agent_id, artifact_path)
    assert String.trim(body) == expected
  end

  test "Feishu source uses hidden-operation help then replies exactly once through reply_text",
       %{llm: llm} do
    suffix = Live.unique_suffix()
    marker = "FEISHU-LIVE-#{String.upcase(suffix)}"
    help_code = "FEISHU-HELP-#{String.upcase(suffix)}"
    message_id = "om-live-#{suffix}"
    chat_id = "oc-live-#{suffix}"
    IntegrationIMProvider.configure(self(), help_code)
    put_agent_env(:im_provider_mod, IntegrationIMProvider)

    %{tenant_id: tenant_id, group_id: group_id, agent_id: agent_id, session_id: session_id} =
      new_agent!(llm, "router")

    disclosure = live_disclosure("router", tenant_id, group_id, agent_id)
    feishu_entry = disclosure_entry!(disclosure, "im_api.feishu.reply_text")
    assert feishu_entry["prompt_visibility"] == "hidden"

    refute SalixAgent.ToolDisclosure.prompt_section(disclosure, :internal) =~
             "im_api.feishu.reply_text"

    content = """
    <system-reminder>
    IM provider message context.
    provider=feishu
    connect_id=feishu-live
    chat_id=#{chat_id}
    message_id=#{message_id}
    </system-reminder>
    Feishu message from a user:
    Reply visibly with exactly this text and nothing else: #{marker}
    """

    Live.flush_notifications!()

    assert {:ok, _} =
             SalixAgent.deliver(
               agent_id,
               %{content: content, session_id: session_id},
               source_message_id: "im_provider:feishu:feishu-live:#{message_id}"
             )

    assert_receive {:integration_im_call, ^agent_id, "feishu", "feishu.reply_text", api_args},
                   180_000

    assert api_args["connect_id"] == "feishu-live"
    assert get_in(api_args, ["params", "message_id"]) == message_id
    assert get_in(api_args, ["params", "text"]) == marker
    assert get_in(api_args, ["params", "manual_code"]) == help_code
    _session = Live.await_session_settled!(agent_id, session_id)
    refute_receive {:integration_im_call, ^agent_id, "feishu", _, _}, 100
  end

  test "MCP summary disclosure drives help before the exact dynamic operation", %{llm: llm} do
    suffix = Live.unique_suffix()
    marker = String.upcase(suffix)
    catalog_key = "CATALOG-#{marker}"
    InventoryMCPProvider.configure(self(), marker)
    put_agent_env(:mcp_provider_mod, InventoryMCPProvider)

    %{tenant_id: tenant_id, group_id: group_id, agent_id: agent_id, session_id: session_id} =
      new_agent!(llm, "worker",
        system_prompt: "Use relevant MCP capabilities when requested; never guess arguments."
      )

    disclosure = live_disclosure("worker", tenant_id, group_id, agent_id)
    mcp_entry = disclosure_entry!(disclosure, "mcp.inventory.lookup_batch")
    prompt_section = SalixAgent.ToolDisclosure.prompt_section(disclosure, :internal)
    assert mcp_entry["prompt_visibility"] == "summary"
    assert prompt_section =~ "mcp.inventory.lookup_batch"
    refute prompt_section =~ "BX-INCLUDE-17"
    refute prompt_section =~ "backorder_policy_code"

    Live.flush_notifications!()

    assert {:ok, _} =
             SalixAgent.deliver(
               agent_id,
               %{
                 session_id: session_id,
                 content:
                   "Look up inventory batch #{catalog_key}, including backorders, with the available inventory MCP capability. Report the returned warehouse."
               },
               source_message_id: "live-integrations-2:#{agent_id}"
             )

    expected_params = %{
      "catalog_key" => catalog_key,
      "backorder_policy_code" => "BX-INCLUDE-17"
    }

    assert_receive {:integration_mcp_call, ^agent_id, ^expected_params}, 180_000
    _session = Live.await_session_settled!(agent_id, session_id)
    refute_receive {:integration_mcp_call, ^agent_id, _}, 100
  end

  test "Slack named DM paginates list_users and sends once to the returned id", %{llm: llm} do
    IntegrationIMProvider.set_owner(self())
    put_agent_env(:im_provider_mod, IntegrationIMProvider)

    suffix = Live.unique_suffix()
    marker = "SLACK-DM-#{String.upcase(suffix)}"

    %{agent_id: agent_id, session_id: session_id} =
      new_agent!(llm, "router",
        router_system_prompt:
          "This activation is the already-authorized execution phase of a Slack operation. Execute it directly instead of creating another Task. Follow provider manuals, paginate discovery, and never guess person ids."
      )

    Live.flush_notifications!()

    assert {:ok, _} =
             SalixAgent.deliver(
               agent_id,
               %{
                 session_id: session_id,
                 content:
                   "In the connected Slack workspace, send Ada Lovelace a DM containing exactly #{marker}. No Slack user id is given: resolve her across all returned user pages before sending."
               },
               source_message_id: "live-integrations-3:#{agent_id}"
             )

    assert_receive {:integration_im_call, ^agent_id, "slack", "slack.list_users", first_args},
                   180_000

    assert first_args["connect_id"] == "slack-live"
    assert get_in(first_args, ["params", "cursor"]) in [nil, ""]
    assert String.downcase(get_in(first_args, ["params", "query"])) =~ "ada"

    assert_receive {:integration_im_call, ^agent_id, "slack", "slack.list_users", second_args},
                   180_000

    assert second_args["connect_id"] == "slack-live"
    assert get_in(second_args, ["params", "cursor"]) == "page-2"

    assert_receive {:integration_im_call, ^agent_id, "slack", "slack.send_dm", dm_args},
                   180_000

    assert dm_args["connect_id"] == "slack-live"
    assert get_in(dm_args, ["params", "user_id"]) == "U_ADA_LIVE"
    assert get_in(dm_args, ["params", "text"]) == marker
    _session = Live.await_session_settled!(agent_id, session_id)
    refute_receive {:integration_im_call, ^agent_id, "slack", "slack.send_dm", _}, 100
  end

  test "Slack channel message resolves a named user into a native mention", %{llm: llm} do
    IntegrationIMProvider.set_owner(self())
    put_agent_env(:im_provider_mod, IntegrationIMProvider)

    suffix = Live.unique_suffix()
    marker = "SLACK-MENTION-#{String.upcase(suffix)}"

    %{agent_id: agent_id, session_id: session_id} =
      new_agent!(llm, "router",
        router_system_prompt:
          "This activation is the already-authorized execution phase of a Slack operation. Execute it directly instead of creating another Task. Follow provider manuals, paginate discovery, and never guess person or channel ids."
      )

    Live.flush_notifications!()

    assert {:ok, _} =
             SalixAgent.deliver(
               agent_id,
               %{
                 session_id: session_id,
                 content:
                   "In the connected Slack workspace, post one top-level message in the channel named hippo that says #{marker} and directly notifies Ada Lovelace. Resolve both names across all returned pages. Use a real Slack mention in the posted text, and do not send a DM."
               },
               source_message_id: "live-integrations-slack-mention:#{agent_id}"
             )

    calls = collect_slack_calls_until(agent_id, "slack.post_message")

    user_calls = for {"slack.list_users", args} <- calls, do: args
    channel_calls = for {"slack.list_channels", args} <- calls, do: args
    post_calls = for {"slack.post_message", args} <- calls, do: args

    assert Enum.map(user_calls, &get_in(&1, ["params", "cursor"])) == [nil, "page-2"]

    assert Enum.map(channel_calls, &get_in(&1, ["params", "cursor"])) == [
             nil,
             "channel-page-2"
           ]

    assert [post_args] = post_calls
    assert post_args["connect_id"] == "slack-live"
    assert get_in(post_args, ["params", "channel"]) == "C_HIPPO_LIVE"

    posted_text = get_in(post_args, ["params", "text"])
    assert posted_text =~ marker
    assert posted_text =~ "<@U_ADA_LIVE>"
    refute posted_text =~ "@Ada"

    _session = Live.await_session_settled!(agent_id, session_id)
    refute_receive {:integration_im_call, ^agent_id, "slack", "slack.send_dm", _}, 100
    refute_receive {:integration_im_call, ^agent_id, "slack", "slack.post_message", _}, 100
  end

  test "Slack named channel follows a sparse page cursor before posting", %{llm: llm} do
    IntegrationIMProvider.set_owner(self())
    put_agent_env(:im_provider_mod, IntegrationIMProvider)

    suffix = Live.unique_suffix()
    marker = "SLACK-CHANNEL-#{String.upcase(suffix)}"

    %{agent_id: agent_id, session_id: session_id} =
      new_agent!(llm, "router",
        router_system_prompt:
          "This activation is the already-authorized execution phase of a Slack operation. Execute it directly instead of creating another Task. Follow provider manuals and never guess channel ids."
      )

    Live.flush_notifications!()

    assert {:ok, _} =
             SalixAgent.deliver(
               agent_id,
               %{
                 session_id: session_id,
                 content:
                   "In the connected Slack workspace, post exactly #{marker} as a top-level message in the channel named hippo. No Slack channel id is given: resolve it before posting, and use limit=200 for channel discovery."
               },
               source_message_id: "live-integrations-4:#{agent_id}"
             )

    assert_receive {:integration_im_call, ^agent_id, "slack", "slack.list_channels", first_args},
                   180_000

    assert first_args["connect_id"] == "slack-live"
    assert get_in(first_args, ["params", "cursor"]) in [nil, ""]
    assert get_in(first_args, ["params", "limit"]) == 200

    assert_receive {:integration_im_call, ^agent_id, "slack", "slack.list_channels", second_args},
                   180_000

    assert second_args["connect_id"] == "slack-live"
    assert get_in(second_args, ["params", "cursor"]) == "channel-page-2"
    assert get_in(second_args, ["params", "limit"]) == 200

    assert Map.drop(first_args["params"], ["cursor"]) ==
             Map.drop(second_args["params"], ["cursor"])

    assert_receive {:integration_im_call, ^agent_id, "slack", "slack.post_message", post_args},
                   180_000

    assert post_args["connect_id"] == "slack-live"
    assert get_in(post_args, ["params", "channel"]) == "C_HIPPO_LIVE"
    assert get_in(post_args, ["params", "text"]) == marker
    _session = Live.await_session_settled!(agent_id, session_id)
    refute_receive {:integration_im_call, ^agent_id, "slack", "slack.list_channels", _}, 100
    refute_receive {:integration_im_call, ^agent_id, "slack", "slack.post_message", _}, 100
  end

  test "Slack thread reply reads every earlier page before acting on its ambiguous trigger", %{
    llm: llm
  } do
    IntegrationIMProvider.set_owner(self())
    put_agent_env(:im_provider_mod, IntegrationIMProvider)

    suffix = Live.unique_suffix()
    marker = "SLACK-THREAD-CONTEXT-#{String.upcase(suffix)}"
    IntegrationIMProvider.set_thread_marker(marker)

    %{agent_id: agent_id, session_id: session_id} =
      new_agent!(llm, "router",
        router_system_prompt:
          "This activation is an already-authorized Slack conversation response. Do not create a Task. Follow every immutable Slack context and provider contract before responding."
      )

    Live.flush_notifications!()

    content = """
    <system-reminder>
    IM provider message context.
    provider=slack
    connect_id=slack-live
    channel_id=C_THREAD_LIVE
    thread_ts=1800000000.000100
    message_ts=1800000000.000300
    event_ts=1800000000.000300
    user_id=U_ADA_LIVE
    event_type=message
    </system-reminder>
    Slack message from Ada in an existing thread:
    Yes — do what we agreed.
    """

    assert {:ok, _} =
             SalixAgent.deliver(
               agent_id,
               %{session_id: session_id, content: content},
               source_message_id: "im_provider:slack:slack-live:thread-context-#{suffix}"
             )

    calls = collect_slack_calls_until(agent_id, "slack.post_message")

    assert Enum.map(calls, &elem(&1, 0)) == [
             "slack.get_thread_replies",
             "slack.get_thread_replies",
             "slack.post_message"
           ]

    [{_, first_read}, {_, second_read}, {_, post_args}] = calls

    assert first_read["connect_id"] == "slack-live"
    assert get_in(first_read, ["params", "channel"]) == "C_THREAD_LIVE"
    assert get_in(first_read, ["params", "ts"]) == "1800000000.000100"
    assert get_in(first_read, ["params", "before_ts"]) == "1800000000.000300"
    assert valid_thread_limit?(get_in(first_read, ["params", "limit"]))

    assert second_read["connect_id"] == "slack-live"
    assert get_in(second_read, ["params", "channel"]) == "C_THREAD_LIVE"
    assert get_in(second_read, ["params", "ts"]) == "1800000000.000100"
    assert get_in(second_read, ["params", "cursor"]) == "thread-page-2"
    refute get_in(second_read, ["params", "before_ts"])
    assert valid_thread_limit?(get_in(second_read, ["params", "limit"]))

    assert post_args["connect_id"] == "slack-live"
    assert get_in(post_args, ["params", "channel"]) == "C_THREAD_LIVE"
    assert get_in(post_args, ["params", "thread_ts"]) == "1800000000.000100"
    assert get_in(post_args, ["params", "text"]) == marker

    _session = Live.await_session_settled!(agent_id, session_id)
    refute_receive {:integration_im_call, ^agent_id, "slack", "slack.post_message", _}, 100
  end

  for {scenario, request} <- [
        {:subject, "讲讲"},
        {:origin, "讲讲这个奖金活动的来源"}
      ] do
    @tag :slack_context_recovery
    test "Slack top-level #{scenario} recovers evidence before its first reply", %{llm: llm} do
      IntegrationIMProvider.set_owner(self())
      put_agent_env(:im_provider_mod, IntegrationIMProvider)
      marker = "BONUS-#{String.upcase(Live.unique_suffix())}"
      IntegrationIMProvider.set_context_marker(marker)
      %{agent_id: agent_id, session_id: session_id} = new_agent!(llm, "router")
      Live.flush_notifications!()

      content = """
      <system-reminder>
      IM provider message context.
      provider=slack
      connect_id=slack-live
      channel_id=C_CONTEXT_LIVE
      thread_ts=1800000000.000300
      message_ts=1800000000.000300
      user_id=U_ADA_LIVE
      event_type=app_mention
      </system-reminder>
      Slack message from a user:
      #{unquote(request)}
      """

      assert {:ok, _} =
               SalixAgent.deliver(
                 agent_id,
                 %{session_id: session_id, content: content},
                 source_message_id: "im_provider:slack:slack-live:context-#{marker}"
               )

      calls = collect_slack_calls_until(agent_id, "slack.post_message")
      assert [{"slack.get_channel_history", first_read} | _] = calls
      assert get_in(first_read, ["params", "channel"]) == "C_CONTEXT_LIVE"
      assert get_in(first_read, ["params", "latest"]) == "1800000000.000300"
      assert get_in(first_read, ["params", "inclusive"]) == false
      assert get_in(first_read, ["params", "limit"]) == 15
      history = for {"slack.get_channel_history", args} <- calls, do: args
      searches = for {"slack.search", args} <- calls, do: args
      assert length(history) <= 2
      assert length(searches) <= 3

      {"slack.post_message", reply} = List.last(calls)
      assert get_in(reply, ["params", "channel"]) == "C_CONTEXT_LIVE"
      assert get_in(reply, ["params", "thread_ts"]) == "1800000000.000300"
      text = get_in(reply, ["params", "text"])
      assert text =~ marker

      if unquote(scenario) == :origin do
        assert searches != []

        assert Enum.all?(searches, fn args ->
                 params = args["params"]

                 String.contains?(params["query"], "C_CONTEXT_LIVE") and
                   is_integer(params["count"]) and params["count"] <= 30
               end)

        assert text =~ "ORIGIN-#{marker}"
      end

      _session = Live.await_session_settled!(agent_id, session_id)
      refute_receive {:integration_im_call, ^agent_id, "slack", "slack.post_message", _}, 100
    end
  end

  @tag :slack_prompt_boundaries
  test "explicit channel creation continues to invitations and confirms only once", %{llm: llm} do
    IntegrationIMProvider.set_owner(self())
    put_agent_env(:im_provider_mod, IntegrationIMProvider)
    %{agent_id: agent_id, session_id: session_id} = new_agent!(llm, "router")
    channel_name = "context-#{Live.unique_suffix()}"
    Live.flush_notifications!()

    assert {:ok, _} =
             SalixAgent.deliver(
               agent_id,
               %{
                 session_id: session_id,
                 content: """
                 <system-reminder>
                 IM provider message context.
                 provider=slack
                 connect_id=slack-live
                 channel_id=C_CONTEXT_LIVE
                 thread_ts=1800000000.000300
                 message_ts=1800000000.000300
                 user_id=U_ADA_LIVE
                 event_type=app_mention
                 </system-reminder>
                 创建名为 #{channel_name} 的频道，并邀请 <@U_ADA_LIVE>。
                 """
               },
               source_message_id: "live-create-invite:#{agent_id}"
             )

    calls = collect_slack_calls_until(agent_id, "slack.post_message")

    assert [
             {"slack.create_channel", create},
             {"slack.invite_users", invite},
             {"slack.post_message", reply}
           ] = calls

    assert get_in(create, ["params", "name"]) == channel_name
    assert get_in(invite, ["params", "channel"]) == "C_CREATED_LIVE"
    assert get_in(invite, ["params", "users"]) == ["U_ADA_LIVE"]
    assert get_in(reply, ["params", "channel"]) == "C_CONTEXT_LIVE"
    _session = Live.await_session_settled!(agent_id, session_id)
    refute_receive {:integration_im_call, ^agent_id, "slack", _, _}, 100
  end

  @tag :slack_prompt_boundaries
  test "unavailable thread history reports its limitation without executing the request", %{
    llm: llm
  } do
    IntegrationIMProvider.set_owner(self())
    put_agent_env(:im_provider_mod, IntegrationIMProvider)
    IntegrationIMProvider.enable_internal_calls()
    %{group_id: group_id, agent_id: agent_id, session_id: session_id} = new_agent!(llm, "router")
    Live.flush_notifications!()

    assert {:ok, _} =
             SalixAgent.deliver(
               agent_id,
               %{
                 session_id: session_id,
                 content: """
                 <system-reminder>
                 IM provider message context.
                 provider=slack
                 connect_id=slack-live
                 channel_id=C_UNAVAILABLE_LIVE
                 thread_ts=1800000000.000100
                 message_ts=1800000000.000300
                 user_id=U_ADA_LIVE
                 event_type=message
                 </system-reminder>
                 按前面讨论的安排建群拉人吧。
                 """
               },
               source_message_id: "live-unavailable-thread:#{agent_id}"
             )

    calls = collect_slack_calls_until(agent_id, "slack.post_message")
    assert [{"slack.get_thread_replies", _} | _] = calls

    assert Enum.all?(calls, fn {api, _} ->
             api in ["slack.get_thread_replies", "slack.post_message"]
           end)

    {_, reply} = List.last(calls)
    assert get_in(reply, ["params", "channel"]) == "C_UNAVAILABLE_LIVE"
    assert get_in(reply, ["params", "text"]) =~ ~r/无法|不能|不可用|读取失败|重新连接/
    _session = Live.await_session_settled!(agent_id, session_id)

    assert {:ok, %{"data" => conversations}} =
             SalixIM.Conversations.list_group_conversations(group_id, limit: 20)

    refute Enum.any?(conversations, &(&1["kind"] == "agent_task"))
    refute_receive {:integration_im_call, ^agent_id, "internal", _, _}, 100
    refute_receive {:integration_im_call, ^agent_id, "slack", _, _}, 100
  end

  test "Feishu decision activation opens the trigger then records not_required in the same run",
       %{llm: llm} do
    suffix = Live.unique_suffix()
    plan_id = SalixStore.Ids.new_meeting_plan_id()
    revision = "dispatch-live-#{suffix}"
    MeetingPreparationSeam.configure(self(), plan_id, revision)
    put_agent_env(:meeting_preparation_mod, MeetingPreparationSeam)

    %{agent_id: agent_id, session_id: session_id} =
      new_agent!(llm, "router",
        router_system_prompt:
          "Feishu meeting-preparation activations are Router work. Follow their required follow-up in the same run and do not create a Task when no research is needed."
      )

    prompt = """
    Meeting preparation decision trigger. Call meeting.preparation.open_trigger with
    #{Jason.encode!(%{"meeting_plan_id" => plan_id, "trigger_kind" => "decision", "dispatch_revision" => revision})}.
    Do not finish after open_trigger when it returns opened. Review its context and
    required_follow_up, then call meeting.preparation.record_decision in this same run.
    A complete agenda with no gaps means decision=not_required. Record a bounded baseline
    and do not invent facts.
    """

    Live.flush_notifications!()

    assert {:ok, _} =
             SalixAgent.deliver(agent_id, %{session_id: session_id, content: prompt},
               source_message_id: "live-integrations-meeting:#{agent_id}"
             )

    assert_receive {:integration_meeting_call, :open_trigger, _, ^plan_id, ^revision, ^agent_id},
                   180_000

    assert_receive {:integration_meeting_call, :record_decision, _, ^plan_id, ^revision,
                    "not_required", baseline, ^agent_id},
                   180_000

    assert is_map(baseline)
    _session = Live.await_session_settled!(agent_id, session_id)
    assert %{opened: true, decision: "not_required"} = MeetingPreparationSeam.snapshot()
  end

  test "current-session reminder uses one cron schedule with an explicit timezone", %{llm: llm} do
    IntegrationIMProvider.set_owner(self())
    ScheduleSeam.configure(self())
    put_agent_env(:im_provider_mod, IntegrationIMProvider)
    put_agent_env(:schedules_mod, ScheduleSeam)

    suffix = Live.unique_suffix()
    marker = "SCHEDULE-LIVE-#{String.upcase(suffix)}"
    message_id = "om-schedule-#{suffix}"
    chat_id = "oc-schedule-#{suffix}"

    %{agent_id: agent_id, session_id: session_id} = new_agent!(llm, "router")

    content = """
    <system-reminder>
    IM provider message context.
    provider=feishu
    connect_id=feishu-live
    chat_id=#{chat_id}
    message_id=#{message_id}
    </system-reminder>
    Feishu message from a user:
    每个工作日 09:00（Asia/Shanghai）在当前飞书群发送且只发送 #{marker}。
    """

    Live.flush_notifications!()

    assert {:ok, _} =
             SalixAgent.deliver(
               agent_id,
               %{session_id: session_id, content: content},
               source_message_id: "im_provider:feishu:feishu-live:#{message_id}"
             )

    assert_receive {:integration_schedule_create, stored}, 180_000
    assert stored["agent_id"] == agent_id
    assert stored["session_id"] == session_id
    assert stored["cron"] == "0 9 * * 1-5"
    assert stored["timezone"] == "Asia/Shanghai"
    refute Map.has_key?(stored, "interval_minutes")
    refute Map.has_key?(stored, "run_at")
    assert stored["prompt"] =~ "im_api.feishu.send_text"
    assert stored["prompt"] =~ "feishu-live"
    assert stored["prompt"] =~ chat_id
    assert stored["prompt"] =~ marker
    _session = Live.await_session_settled!(agent_id, session_id)
    assert ScheduleSeam.snapshot().schedules == [stored]
  end

  test "a recurring reminder without a clock time stays in chat for clarification", %{llm: llm} do
    ScheduleSeam.configure(self())
    put_agent_env(:schedules_mod, ScheduleSeam)

    suffix = Live.unique_suffix()
    marker = "NEED_CLOCK_#{String.upcase(suffix)}"

    %{group_id: group_id, agent_id: agent_id} = new_agent!(llm, "router")

    {:ok, _group} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", agent_id)
      end)

    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
    parent_conversation_id = parent["conversation_id"]
    session_id = Live.router_session_id!(agent_id)

    Live.flush_notifications!()

    assert {:ok, %{"message_id" => _message_id}} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" =>
                 "每个工作日提醒我提交 #{suffix} 报告，但我还没有说几点执行。" <>
                   "如果必须补充时间，请在追问中原样包含 #{marker}。",
               "client_request_id" => "missing-reminder-time-#{suffix}"
             })

    visible_reply =
      Live.eventually(fn ->
        {:ok, messages} =
          SalixIM.Conversations.list_group_conversation_messages(
            group_id,
            parent_conversation_id,
            limit: 20
          )

        case Enum.filter(messages, &(&1["actor_type"] == "agent" and &1["agent_id"] == agent_id)) do
          [message] -> {:ok, message}
          [] -> :retry
          messages -> raise "Router produced multiple clarification replies: #{inspect(messages)}"
        end
      end)

    _session = Live.await_session_quiescent!(agent_id, session_id)
    assert ScheduleSeam.snapshot().schedules == []
    assert Live.text_content(visible_reply["content"]) =~ marker
    assert Live.conversation_ref_ids([visible_reply]) == []

    assert {:ok, %{"data" => conversations}} =
             SalixIM.Conversations.list_group_conversations(group_id, limit: 20)

    assert Enum.count(conversations, &(&1["kind"] == "agent_task")) == 0
  end

  defp new_agent!(llm, role, opts \\ []) do
    suffix = Live.unique_suffix()
    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    agent_id = SalixStore.Ids.new_agent_id(group_id)
    session_id = SalixStore.Ids.new_session_id()

    Live.seed_group!(tenant_id, group_id)

    config =
      %{
        tenant_id: tenant_id,
        group_id: group_id,
        role: role,
        template_id: "live-integrations-#{role}-#{suffix}"
      }
      |> maybe_put(:system_prompt, opts[:system_prompt])
      |> maybe_put(:router_system_prompt, opts[:router_system_prompt])

    Live.configure!(agent_id, llm, config)

    session_id =
      if role == "router" do
        Live.router_session_id!(agent_id)
      else
        session_id
      end

    %{
      tenant_id: tenant_id,
      group_id: group_id,
      agent_id: agent_id,
      session_id: session_id
    }
  end

  defp live_disclosure(role, tenant_id, group_id, agent_id) do
    %{tenant_id: tenant_id, group_id: group_id, agent_id: agent_id}
    |> SalixAgent.TestSupport.with_plugin_projection()
    |> then(&SalixAgent.ToolDisclosure.materialize(role, :internal, &1))
  end

  defp disclosure_entry!(disclosure, target) do
    Enum.find(disclosure["tools"], &(&1["name"] == target)) ||
      flunk("missing disclosure entry #{target}")
  end

  defp put_agent_env(key, value) do
    previous = Application.get_env(:salix_agent, key)
    Application.put_env(:salix_agent, key, value)
    on_exit(fn -> Live.restore_env(key, previous) end)
  end

  defp collect_slack_calls_until(agent_id, terminal_api, calls \\ []) do
    receive do
      {:integration_im_call, ^agent_id, "slack", api, args} ->
        calls = [{api, args} | calls]

        if api == terminal_api do
          Enum.reverse(calls)
        else
          collect_slack_calls_until(agent_id, terminal_api, calls)
        end
    after
      180_000 ->
        flunk("timed out waiting for #{terminal_api}; calls=#{inspect(Enum.reverse(calls))}")
    end
  end

  defp valid_thread_limit?(nil), do: true

  defp valid_thread_limit?(limit) when is_integer(limit),
    do: limit >= 1 and limit <= 15

  defp valid_thread_limit?(_limit), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
