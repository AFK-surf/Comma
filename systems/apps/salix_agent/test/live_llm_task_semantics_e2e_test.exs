defmodule SalixAgent.LiveLlmTaskSemanticsE2eTest do
  @moduledoc """
  Real-LLM coverage for semantic decisions that only become observable through
  the canonical Chat and Task conversation paths.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.LiveLlmTestSupport, as: Live

  defmodule NativeAuthorizationDispatch do
    @moduledoc false

    # The model chooses the command. This boundary double never executes a host shell.
    def exec(_agent_id, %{device_id: "auth-mac", environment_id: "auth-env"}, command, _opts) do
      %{owner: owner, result: result} = :persistent_term.get(__MODULE__)
      send(owner, {:native_auth_command, command})

      if String.contains?(command, "osascript") and
           String.contains?(command, "with administrator privileges") do
        {:ok, result}
      else
        {:ok,
         %{
           "status" => "completed",
           "exit_code" => 1,
           "stdout" => "",
           "stderr" => "Administrator privileges required. No OS authorization was requested."
         }}
      end
    end

    def get_device(_agent_id, "auth-mac") do
      {:ok,
       %{
         "device_id" => "auth-mac",
         "name" => "Test Mac",
         "environments" => [
           %{"environment_id" => "auth-env", "os" => "darwin", "status" => "connected"}
         ]
       }}
    end
  end

  defmodule ObservedImProvider do
    @moduledoc false

    def observe(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)
    def clear, do: :persistent_term.erase({__MODULE__, :owner})

    defdelegate list_connects(agent_id), to: SalixIM.Provider
    defdelegate provider_manual(platform), to: SalixIM.Provider

    def call_api(agent_id, platform, api, args) do
      if platform == "internal" and api == "internal.task.list" do
        if owner = :persistent_term.get({__MODULE__, :owner}, nil) do
          send(owner, {:internal_task_list_called, agent_id, args["params"] || %{}})
        end
      end

      SalixIM.Provider.call_api(agent_id, platform, api, args)
    end
  end

  @moduletag :live_llm
  @moduletag timeout: 300_000

  setup_all do
    {:ok, llm: Live.llm_config!()}
  end

  setup do
    cleanup = Live.install_runtime!()

    # The shared test config disables cluster background sweeps. Run the real
    # timer owner here so a live model's intentional wait_for call can expire
    # through the same durable delivery path used in production.
    start_supervised!(SalixCluster.Timers)

    on_exit(cleanup)
    :ok
  end

  test "live LLM: an explicit daily delegated request creates one scheduled Task, not a Router schedule",
       %{llm: llm} do
    suffix = Live.unique_suffix()
    %{group_id: group_id, router: router, worker: worker} = configure_group!(llm, suffix)

    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
    parent_conversation_id = parent["conversation_id"]
    router_session_id = Live.router_session_id!(router)

    Live.flush_notifications!()

    assert {:ok, %{"message_id" => parent_message_id}} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" =>
                 "每天上午 9:00（Asia/Shanghai）让一个 worker 检查仓库健康并生成报告，" <>
                   "报告必须包含唯一标记 RECURRING_TASK_#{suffix}。",
               "client_request_id" => "recurring-task-#{suffix}"
             })

    task_conversation_id =
      Live.eventually(fn ->
        {:ok, messages} =
          SalixIM.Conversations.list_group_conversation_messages(
            group_id,
            parent_conversation_id,
            limit: 20
          )

        ids = Live.conversation_ref_ids(messages) |> Enum.uniq()
        inline_ids = Live.inline_task_ref_ids(messages) |> Enum.uniq()

        case {ids, inline_ids} do
          {[conversation_id], [conversation_id]} ->
            {:ok, conversation_id}

          {[], []} ->
            if settled_router_reply?(router, router_session_id, messages) do
              raise "recurring request settled with a Router reply but no Task reference: " <>
                      inspect(router_replies(router, messages))
            else
              :retry
            end

          {ids, inline_ids} ->
            raise "recurring request must create exactly one inline Task reference; " <>
                    "all=#{inspect(ids)} inline=#{inspect(inline_ids)}"
        end
      end)

    _router_session = Live.await_session_settled!(router, router_session_id)

    assert {:ok, task} =
             SalixIM.Conversations.get_group_conversation(group_id, task_conversation_id)

    assert task["kind"] == "agent_task"
    assert task["task_worker_agent_id"] == worker
    assert get_in(task, ["source_refs", "parent_conversation_id"]) == parent_conversation_id
    assert get_in(task, ["source_refs", "parent_message_id"]) == parent_message_id

    assert %{"schedule_id" => schedule_id, "command" => command} = task["schedule"]
    assert is_binary(schedule_id) and schedule_id != ""
    assert command =~ "RECURRING_TASK_#{suffix}"
    assert command =~ ~r/\p{Han}/u

    refute command =~
             ~r/(每天|每日|周期|定时|9:00|09:00|Asia\/Shanghai|cron|timezone)/iu

    assert {:ok, schedule} = SalixCluster.Schedules.get(schedule_id)
    assert schedule["receiver"] == "task"
    assert schedule["cron"] == "0 9 * * *"
    assert schedule["timezone"] == "Asia/Shanghai"
    refute Map.has_key?(schedule, "interval_minutes")
    refute Map.has_key?(schedule, "run_at")

    assert schedule["payload"] == %{
             "agent_group_id" => group_id,
             "conversation_id" => task_conversation_id
           }

    assert {:ok, parent_messages} =
             SalixIM.Conversations.list_group_conversation_messages(
               group_id,
               parent_conversation_id,
               limit: 20
             )

    router_texts =
      parent_messages
      |> Enum.filter(&(&1["actor_type"] == "agent" and &1["agent_id"] == router))
      |> Enum.map(&Live.text_content(&1["content"]))
      |> Enum.reject(&(String.trim(&1) == ""))

    assert router_texts != []
    assert Enum.all?(router_texts, &(&1 =~ ~r/\p{Han}/u))

    assert {:ok, task_messages} =
             SalixIM.Conversations.list_group_conversation_messages(
               group_id,
               task_conversation_id,
               limit: 20
             )

    assert [task_command] =
             Enum.filter(task_messages, fn message ->
               message["actor_type"] == "agent" and message["agent_id"] == router and
                 get_in(message, ["metadata", "message_type"]) == "task_command"
             end)

    initial_envelope = task_command["content"] |> Live.text_content() |> Jason.decode!()

    assert initial_envelope["format"] == "scheduled_task_initial/v1"
    assert initial_envelope["mode"] == "read_only_validation"
    assert initial_envelope["production_command"] == command
    assert initial_envelope["production_command"] =~ ~r/\p{Han}/u
    assert initial_envelope["execute_production_command"] == false
    assert initial_envelope["external_side_effects"] == false
    assert initial_envelope["claim_production_completed"] == false

    assert "deployment" in initial_envelope["forbidden_operations"]
    assert "read_only_validation" in initial_envelope["allowed_operations"]

    assert {:ok, schedules} =
             SalixCluster.Schedules.list_for_owners([router, worker], group_id)

    assert Enum.map(schedules, & &1["id"]) == [schedule_id]

    assert {:ok, %{"data" => conversations}} =
             SalixIM.Conversations.list_group_conversations(group_id, limit: 20)

    assert Enum.count(conversations, &(&1["kind"] == "agent_task")) == 1
  end

  test "live LLM: a daily delegated request without a time asks in Chat and creates no schedule",
       %{llm: llm} do
    suffix = Live.unique_suffix()
    %{group_id: group_id, router: router, worker: worker} = configure_group!(llm, suffix)

    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
    parent_conversation_id = parent["conversation_id"]
    router_session_id = Live.router_session_id!(router)

    Live.flush_notifications!()

    assert {:ok, %{"message_id" => _message_id}} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" =>
                 "每天让一个 worker 检查仓库健康并生成报告；我还没有指定每天几点执行。" <>
                   "如果必须补充执行时间，请在追问里原样包含 NEED_RUN_TIME_#{suffix}。",
               "client_request_id" => "missing-recurring-time-#{suffix}"
             })

    visible_reply =
      Live.eventually(fn ->
        {:ok, messages} =
          SalixIM.Conversations.list_group_conversation_messages(
            group_id,
            parent_conversation_id,
            limit: 20
          )

        case Enum.filter(messages, &(&1["actor_type"] == "agent" and &1["agent_id"] == router)) do
          [message] -> {:ok, message}
          [] -> :retry
          messages -> raise "Router produced multiple clarification replies: #{inspect(messages)}"
        end
      end)

    router_session = Live.await_session_settled!(router, router_session_id)

    assert is_nil(router_session.wait)

    assert {:ok, settled_messages} =
             SalixIM.Conversations.list_group_conversation_messages(
               group_id,
               parent_conversation_id,
               limit: 20
             )

    assert [^visible_reply] = router_replies(router, settled_messages)

    assert Live.text_content(visible_reply["content"]) =~ "NEED_RUN_TIME_#{suffix}"
    assert Live.text_content(visible_reply["content"]) =~ ~r/\p{Han}/u
    assert Live.conversation_ref_ids([visible_reply]) == []

    assert {:ok, %{"data" => conversations}} =
             SalixIM.Conversations.list_group_conversations(group_id, limit: 20)

    assert Enum.count(conversations, &(&1["kind"] == "agent_task")) == 0

    assert {:ok, []} =
             SalixCluster.Schedules.list_for_owners([router, worker], group_id)
  end

  test "live LLM: an exact current-Tasks question lists through the canonical internal API and replies with ordered inline refs",
       %{llm: llm} do
    suffix = Live.unique_suffix()
    %{group_id: group_id, router: router, worker: worker} = configure_group!(llm, suffix)

    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
    parent_conversation_id = parent["conversation_id"]
    router_session_id = Live.router_session_id!(router)

    older_task_id = SalixStore.Ids.new_conversation_id()
    newer_task_id = SalixStore.Ids.new_conversation_id()
    older_created_at = System.system_time(:millisecond) - 1

    assert {:ok, _older_task} =
             SalixIM.TaskConversationInput.ensure_with_id(
               group_id,
               older_task_id,
               worker,
               %{
                 "title" => "Older Task #{suffix}",
                 "command" => "Keep the older Task available for discovery.",
                 "created_at" => older_created_at
               }
             )

    assert {:ok, _newer_task} =
             SalixIM.TaskConversationInput.ensure_with_id(
               group_id,
               newer_task_id,
               worker,
               %{
                 "title" => "Newer Task #{suffix}",
                 "command" => "Keep the newer Task available for discovery.",
                 "created_at" => older_created_at + 1
               }
             )

    previous_im_provider = Application.get_env(:salix_agent, :im_provider_mod)
    ObservedImProvider.observe(self())
    Application.put_env(:salix_agent, :im_provider_mod, ObservedImProvider)

    on_exit(fn ->
      ObservedImProvider.clear()

      if is_nil(previous_im_provider),
        do: Application.delete_env(:salix_agent, :im_provider_mod),
        else: Application.put_env(:salix_agent, :im_provider_mod, previous_im_provider)
    end)

    Live.flush_notifications!()

    assert {:ok, %{"message_id" => _message_id}} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" => "我现在有哪些 task？",
               "client_request_id" => "list-current-tasks-#{suffix}"
             })

    visible_reply =
      Live.eventually(fn ->
        {:ok, messages} =
          SalixIM.Conversations.list_group_conversation_messages(
            group_id,
            parent_conversation_id,
            limit: 20
          )

        case Enum.filter(messages, &(&1["actor_type"] == "agent" and &1["agent_id"] == router)) do
          [message] -> {:ok, message}
          [] -> :retry
          messages -> raise "Router produced multiple Task-list replies: #{inspect(messages)}"
        end
      end)

    _router_session = Live.await_session_settled!(router, router_session_id)

    assert_received {:internal_task_list_called, ^router, params}
    assert Map.keys(params) -- ["cursor", "limit"] == []
    refute Map.has_key?(params, "query")

    if Map.has_key?(params, "limit") do
      assert params["limit"] in 1..1_000
    end

    assert Live.conversation_ref_ids([visible_reply]) == [newer_task_id, older_task_id]
    assert Live.inline_task_ref_ids([visible_reply]) == [newer_task_id, older_task_id]

    # A plain follow-up must also become a canonical Comma Message, not merely
    # generated prose in the settled Session. Keep the production Router prompt.
    assert {:ok, follow_up} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" => "再用一句话概括共有几个 task？",
               "client_request_id" => "summarize-current-tasks-#{suffix}"
             })

    Live.eventually(fn ->
      {:ok, messages} =
        SalixIM.Conversations.list_group_conversation_messages(group_id, parent_conversation_id,
          after_id: follow_up["message_id"]
        )

      if Enum.any?(messages, &(&1["actor_type"] == "agent")), do: {:ok, :delivered}, else: :retry
    end)

    Live.await_session_settled!(router, router_session_id)

    assert {:ok, [summary]} =
             SalixIM.Conversations.list_group_conversation_messages(
               group_id,
               parent_conversation_id,
               after_id: follow_up["message_id"]
             )

    assert summary["agent_id"] == router
    assert Live.text_content(summary["content"]) =~ ~r/2|两|二/
  end

  test "live LLM: a user follow-up reuses the existing Task before its worker completes",
       %{llm: llm} do
    suffix = Live.unique_suffix()
    tenant = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    router = SalixStore.Ids.new_agent_id(group_id)
    worker = SalixStore.Ids.new_agent_id(group_id)
    requester_id = "task-user-#{suffix}"
    Live.seed_group!(tenant, group_id)

    Live.configure!(router, llm, %{
      tenant_id: tenant,
      group_id: group_id,
      role: "router",
      template_id: "clarification-router-#{suffix}"
    })

    Live.configure!(worker, Map.put(llm, :max_tokens, 4_000), %{
      tenant_id: tenant,
      group_id: group_id,
      role: "worker",
      template_id: "clarification-worker-#{suffix}"
    })

    {:ok, _group} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router)
      end)

    Live.flush_notifications!()

    assert {:ok, created_task} =
             SalixCluster.TaskSchedules.create_task_conversation(
               group_id,
               router,
               worker,
               %{
                 "content" =>
                   "Return the required payload unchanged in the exact form " <>
                     "RESULT_#{suffix}: <payload>. No payload value is present in this request, " <>
                     "so ask the delegator for it without inventing one. Include the tracking " <>
                     "label NEED_PAYLOAD_#{suffix} in that clarification.",
                 "title" => "Missing payload",
                 "owner_user_id" => requester_id,
                 "client_request_id" => "clarification-task-#{suffix}"
               }
             )

    task_conversation_id = created_task["conversation_id"]
    router_session_id = Live.router_session_id!(router)

    clarification =
      Live.eventually(fn ->
        messages = task_messages!(group_id, task_conversation_id)

        case Enum.filter(messages, fn message ->
               message["agent_id"] == worker and
                 Live.text_content(message["content"]) =~ "NEED_PAYLOAD_#{suffix}"
             end) do
          [message] -> {:ok, message}
          [] -> :retry
          messages -> raise "worker sent duplicate clarifications: #{inspect(messages)}"
        end
      end)

    wait_for_all_sessions_quiescent!(worker)

    assert get_in(clarification, ["metadata", "task_completion"]) == nil

    assert {:ok, active_task} =
             SalixIM.Conversations.get_group_conversation(group_id, task_conversation_id)

    assert active_task["status"] == "active"
    refute Map.has_key?(active_task, "task_completion")

    assert {:ok, %{"participants" => participants}} =
             SalixIM.Conversations.list_group_conversation_participants(
               group_id,
               task_conversation_id
             )

    router_participant_id =
      participants
      |> Enum.find(&(&1["agent_id"] == router and &1["role_label"] == "delegator"))
      |> Map.fetch!("participant_id")

    Live.await_session_quiescent!(router, router_session_id)
    Live.flush_notifications!()

    assert {:ok, %{"inserted" => true, "message_id" => follow_up_message_id}} =
             SalixIM.ConversationServer.append_group_conversation_message(
               group_id,
               task_conversation_id,
               %{
                 "actor_type" => "user",
                 "user_id" => requester_id,
                 "content" => "补充输入：PAYLOAD_#{suffix}",
                 "client_request_id" => "clarification-follow-up-#{suffix}"
               }
             )

    Live.eventually(fn ->
      case SalixIM.Conversations.group_conversation_delivery_status(
             group_id,
             task_conversation_id,
             participant_id: router_participant_id,
             message_id: follow_up_message_id,
             limit: 1
           ) do
        {:ok, %{"deliveries" => [%{"status" => "delivered"}]}} -> {:ok, :delivered}
        {:ok, _status} -> :retry
        {:error, reason} -> raise "Router delivery read failed: #{inspect(reason)}"
      end
    end)

    Live.await_session_settled!(router, router_session_id)

    completed_task =
      Live.eventually(fn ->
        case SalixIM.Conversations.get_group_conversation(group_id, task_conversation_id) do
          {:ok, %{"status" => "ready_for_review"} = task} ->
            {:ok, task}

          {:ok, _task} ->
            :retry

          {:error, reason} ->
            raise "Task read failed: #{inspect(reason)}"
        end
      end)

    wait_for_all_sessions_settled!(worker)

    final_messages = task_messages!(group_id, task_conversation_id)

    assert [final_message] =
             Enum.filter(final_messages, fn message ->
               message["agent_id"] == worker and
                 Live.text_content(message["content"]) =~ "RESULT_#{suffix}: PAYLOAD_#{suffix}"
             end)

    refute Map.has_key?(final_message["metadata"] || %{}, "task_completion")
    refute Map.has_key?(completed_task, "task_completion")
    refute Map.has_key?(completed_task, "task_last_command_seq")
    assert final_message["seq"] > clarification["seq"]

    assert {:ok, %{"data" => conversations}} =
             SalixIM.Conversations.list_group_conversations(group_id, limit: 20)

    assert Enum.count(conversations, &(&1["kind"] == "agent_task")) == 1
  end

  test "live LLM: asking for an optional clue does not stop available lookup", %{llm: llm} do
    suffix = Live.unique_suffix()
    %{group_id: group_id, router: router} = configure_group!(llm, suffix)
    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
    path = "/published-pages-#{suffix}.json"
    url = "https://example.invalid/nothing-#{suffix}"

    {:ok, event} =
      SalixAgent.AgentWorkspace.prepare_write(
        router,
        path,
        Jason.encode!(%{"pages" => [%{"title" => "Nothing", "url" => url}]})
      )

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(router, "lookup-seed-#{suffix}", %{}, [
               event
             ])

    assert {:ok, _} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" =>
                 "Send me the Nothing page link from my publishing records at #{path}. " <>
                   "First ask which day or channel I published it in, in case I remember, " <>
                   "but I may not be around to answer. The records are available to you.",
               "client_request_id" => "optional-clue-#{suffix}"
             })

    # No human reply is supplied: a question must not terminate the lookup.
    Live.eventually(fn ->
      replies = router_replies(router, task_messages!(group_id, parent["conversation_id"]))

      case Enum.find(replies, &(Live.text_content(&1["content"]) =~ url)) do
        nil ->
          :retry

        result ->
          if Enum.any?(replies, fn message ->
               text = Live.text_content(message["content"])

               message["seq"] < result["seq"] and
                 Regex.match?(~r/day|date|channel|when|where/i, text) and
                 String.contains?(text, "?")
             end), do: {:ok, :asked_then_delivered}, else: :retry
      end
    end)

    Live.await_session_settled!(router, Live.router_session_id!(router))
  end

  test "live LLM: one exact-resource read returns directly without a Task", %{llm: llm} do
    suffix = Live.unique_suffix()
    %{group_id: group_id, router: router} = configure_group!(llm, suffix)
    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
    path = "/status-#{suffix}.txt"
    marker = "STATUS_#{suffix}"
    {:ok, event} = SalixAgent.AgentWorkspace.prepare_write(router, path, marker)

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(router, "status-seed-#{suffix}", %{}, [
               event
             ])

    assert {:ok, _} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" => "What does #{path} say?",
               "client_request_id" => "status-read-#{suffix}"
             })

    Live.eventually(fn ->
      replies = router_replies(router, task_messages!(group_id, parent["conversation_id"]))

      if Enum.any?(replies, &(Live.text_content(&1["content"]) =~ marker)),
        do: {:ok, :answered},
        else: :retry
    end)

    Live.await_session_settled!(router, Live.router_session_id!(router))
    assert routing_tasks!(group_id) == []
  end

  test "live LLM: one exact-content short note is delivered directly", %{llm: llm} do
    suffix = Live.unique_suffix()
    %{group_id: group_id, router: router} = configure_group!(llm, suffix)
    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
    path = "/short-note-#{suffix}.txt"
    marker = "SHORT_NOTE_#{suffix}"

    assert {:ok, _} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" =>
                 "Create a one-line note containing #{marker} at #{path} and send me the file. " <>
                   "This is a trivial scratch note; no research or independent review is needed.",
               "client_request_id" => "short-note-#{suffix}"
             })

    Live.eventually(fn ->
      replies = router_replies(router, task_messages!(group_id, parent["conversation_id"]))

      if Enum.any?(replies, fn message ->
           Enum.any?(List.wrap(message["content"]), &(is_map(&1) and &1["type"] == "file"))
         end), do: {:ok, :delivered}, else: :retry
    end)

    Live.await_session_settled!(router, Live.router_session_id!(router))
    assert {:ok, content} = SalixAgent.AgentWorkspace.read(router, path)
    assert content =~ marker
    replies = router_replies(router, task_messages!(group_id, parent["conversation_id"]))

    assert Enum.any?(replies, fn message ->
             Enum.any?(List.wrap(message["content"]), &(is_map(&1) and &1["type"] == "file"))
           end)

    assert routing_tasks!(group_id) == []
  end

  test "live LLM: two exact-content notes require a Task", %{llm: llm} do
    suffix = Live.unique_suffix()
    %{group_id: group_id, router: router, worker: worker} = configure_group!(llm, suffix)
    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
    path = "/short-note-#{suffix}.txt"
    marker = "SHORT_NOTE_#{suffix}"

    assert {:ok, _} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" =>
                 "Create one-line notes containing #{marker} at #{path} and #{path}.copy and send both files. " <>
                   "This is a trivial scratch note; no research or independent review is needed.",
               "client_request_id" => "short-note-#{suffix}"
             })

    Live.eventually(fn ->
      replies = router_replies(router, task_messages!(group_id, parent["conversation_id"]))

      if Enum.any?(replies, fn message ->
           Enum.any?(List.wrap(message["content"]), &(is_map(&1) and &1["type"] == "file"))
         end), do: {:ok, :delivered}, else: :retry
    end)

    Live.await_session_settled!(router, Live.router_session_id!(router))
    assert {:ok, content} = SalixAgent.AgentWorkspace.read(worker, path)
    assert content =~ marker
    assert {:ok, second_content} = SalixAgent.AgentWorkspace.read(worker, path <> ".copy")
    assert second_content =~ marker
    replies = router_replies(router, task_messages!(group_id, parent["conversation_id"]))

    assert Enum.any?(replies, fn message ->
             Enum.any?(List.wrap(message["content"]), &(is_map(&1) and &1["type"] == "file"))
           end)

    assert [task] = routing_tasks!(group_id)
    assert task["task_worker_agent_id"] == worker
  end

  test "live LLM: ordinary conversational review gets a Task", %{llm: llm} do
    suffix = Live.unique_suffix()
    result_code = "REVIEW_RESULT_#{suffix}"

    %{group_id: group_id, router: router, worker: worker} =
      configure_group!(
        llm,
        suffix,
        "Review the supplied policy, report a concrete finding in your Task, and include " <>
          "the result code #{result_code}. No external research is needed."
      )

    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)

    assert {:ok, _} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" =>
                 "Take a look at this retention policy and tell me what is wrong. Policy: logs are deleted " <>
                   "after 7 days, but support promises recovery of any log for 30 days.",
               "client_request_id" => "quality-review-#{suffix}"
             })

    tasks =
      Live.eventually(fn ->
        case routing_tasks!(group_id) do
          [] -> :retry
          tasks -> {:ok, tasks}
        end
      end)

    assert Enum.any?(tasks, &(&1["task_worker_agent_id"] == worker))
    await_review_delivery!(group_id, parent["conversation_id"], router, result_code)
    Live.await_session_settled!(router, Live.router_session_id!(router))
  end

  # Comma Home shows a Task only through an inline reference in a Router Message.
  # Without it the person sees no Task while the Worker runs.
  test "live LLM: a delegated Comma request shows its Task inline before the Worker result",
       %{llm: llm} do
    suffix = Live.unique_suffix()

    %{group_id: group_id, router: router, worker: worker} =
      configure_group!(
        llm,
        suffix,
        "Answer the Task question from general knowledge in one short result Message in your Task. " <>
          "No external research is needed."
      )

    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)

    assert {:ok, _} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" => "请交给一个 worker 去查证：\"Winter is coming\" 这句话第一次出现在《权力的游戏》哪一集？查完告诉我结论。",
               "client_request_id" => "inline-task-ref-#{suffix}"
             })

    task =
      Live.eventually(fn ->
        case routing_tasks!(group_id) do
          [] -> :retry
          [task | _] -> {:ok, task}
        end
      end)

    assert task["task_worker_agent_id"] == worker

    worker_result_at =
      Live.eventually(fn ->
        task_messages!(group_id, task["conversation_id"])
        |> Enum.filter(&(&1["actor_type"] == "agent" and &1["agent_id"] == worker))
        |> Enum.map(& &1["created_at"])
        |> case do
          [] -> :retry
          times -> {:ok, Enum.min(times)}
        end
      end)

    {:ok, home_messages} =
      SalixIM.Conversations.list_group_conversation_messages(
        group_id,
        parent["conversation_id"],
        limit: 20
      )

    assert Enum.any?(home_messages, fn message ->
             message["agent_id"] == router and message["created_at"] <= worker_result_at and
               task["conversation_id"] in Live.inline_task_ref_ids([message])
           end),
           "no Router Home Message referenced the Task inline before the Worker result: " <>
             inspect(
               Enum.map(router_replies(router, home_messages), &Live.text_content(&1["content"]))
             )

    Live.await_session_settled!(router, Live.router_session_id!(router))
  end

  test "live LLM: independent reviews are dispatched before the first can finish", %{llm: llm} do
    suffix = Live.unique_suffix()
    release = "REVIEW_INPUT_#{suffix}"
    result_code = "PARALLEL_RESULT_#{suffix}"

    %{group_id: group_id, router: router} =
      configure_group!(
        llm,
        suffix,
        "You can begin reviewing the supplied policy, but cannot finish until a later Task " <>
          "message supplies #{release}. Ask once for that missing verification input and block. " <>
          "After it arrives, send a final finding with #{result_code} in this Task."
      )

    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)

    assert {:ok, _} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" =>
                 "Start two independent, high-quality policy reviews in parallel, with separate " <>
                   "results. A: backups expire at 7 days but restoration is promised for 30 days. " <>
                   "B: invoices say both tax-inclusive and tax-exclusive. Neither review depends on the " <>
                   "other; final verification input will arrive later, so begin both preliminary reviews " <>
                   "now. Include returned result codes in your final report.",
               "client_request_id" => "parallel-review-#{suffix}"
             })

    # Hold completion of the first review until the second Task exists. A Router
    # that serializes delegation behind the first result cannot satisfy this.
    tasks =
      Live.eventually(fn ->
        case routing_tasks!(group_id) do
          [_, _] = tasks -> {:ok, tasks}
          tasks when length(tasks) < 2 -> :retry
          tasks -> flunk("duplicate review Tasks: #{inspect(tasks)}")
        end
      end)

    for task <- tasks do
      refute Enum.any?(task_messages!(group_id, task["id"]), fn message ->
               Live.text_content(message["content"]) =~ result_code
             end)

      assert {:ok, _} =
               SalixIM.ConversationServer.append_group_conversation_message(
                 group_id,
                 task["id"],
                 %{
                   "actor_type" => "user",
                   "user_id" => "routing-user-#{suffix}",
                   "content" => release,
                   "client_request_id" => "release-#{task["id"]}"
                 }
               )
    end

    for task <- tasks do
      Live.eventually(fn ->
        if Enum.any?(task_messages!(group_id, task["id"]), fn message ->
             message["actor_type"] == "agent" and
               Live.text_content(message["content"]) =~ result_code
           end), do: {:ok, :reported}, else: :retry
      end)
    end

    await_review_delivery!(group_id, parent["conversation_id"], router, result_code)
    Live.await_session_settled!(router, Live.router_session_id!(router))
    assert length(routing_tasks!(group_id)) == 2
  end

  test "live LLM: a quick status read hands off newly discovered sustained work", %{llm: llm} do
    suffix = Live.unique_suffix()

    %{group_id: group_id, router: router} =
      configure_group!(
        llm,
        suffix,
        "Read your assigned context, report the missing audit inputs in this Task, and block. " <>
          "Do not invent audit results or perform external side effects."
      )

    path = "/audit-status-#{suffix}.json"
    marker = "BACKLOG_#{suffix}"

    {:ok, event} =
      SalixAgent.AgentWorkspace.prepare_write(
        router,
        path,
        Jason.encode!(%{
          batch: marker,
          pending_records: 500,
          estimated_minutes: 120,
          details:
            "Reconcile each record against its source documents; documents not yet provided."
        })
      )

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(router, "audit-seed-#{suffix}", %{}, [event])

    {:ok, _parent} = SalixIM.RouterConversationInput.ensure(group_id)

    assert {:ok, _} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" =>
                 "Check #{path}; I expect this to be a quick status check. If it reveals " <>
                   "unfinished reconciliation, take responsibility for getting that work resolved. " <>
                   "Include the batch identifier when handing off work; do not hold up our conversation while doing a long audit.",
               "client_request_id" => "growing-work-#{suffix}"
             })

    [task] =
      Live.eventually(fn ->
        case routing_tasks!(group_id) do
          [] -> :retry
          tasks -> {:ok, tasks}
        end
      end)

    # The batch marker is only in the file, not the request: the handoff must
    # carry the newly discovered facts, rather than blindly delegating the read.
    assert Enum.any?(task_messages!(group_id, task["id"]), fn message ->
             message["agent_id"] == router and Live.text_content(message["content"]) =~ marker
           end)

    Live.await_session_settled!(router, Live.router_session_id!(router))
  end

  test "live LLM: a tiny follow-up stays on its existing Task and Worker", %{llm: llm} do
    suffix = Live.unique_suffix()
    %{group_id: group_id, router: router, worker: worker} = configure_group!(llm, suffix, "")
    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
    task_id = SalixStore.Ids.new_conversation_id()
    path = "/existing-note-#{suffix}.txt"
    marker = "FOLLOWUP_NOTE_#{suffix}"
    {:ok, event} = SalixAgent.AgentWorkspace.prepare_write(worker, path, "original note")

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(worker, "followup-seed-#{suffix}", %{}, [
               event
             ])

    assert {:ok, _} =
             SalixIM.TaskConversationInput.create_with_id(group_id, task_id, router, worker, %{
               "title" => "Existing note #{suffix}",
               "content" => "Maintain the existing note at #{path}.",
               "origin_session_id" => Live.router_session_id!(router),
               "source_refs" => %{"parent_conversation_id" => parent["conversation_id"]},
               "schedule" => %{
                 "schedule_id" => nil,
                 "command" => "Maintain the existing note at #{path}."
               },
               "initial_message_attrs" => %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => router,
                 "content" =>
                   "The note at #{path} is already written. Keep it unchanged until a follow-up arrives.",
                 "metadata" => %{"message_type" => "task_command"},
                 "client_request_id" => "existing-note-#{suffix}"
               }
             })

    assert {:ok, _} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" =>
                 "A tiny follow-up to Task #{task_id}: replace the note at #{path} with " <>
                   "#{marker} and send me the updated file. This is only a one-line edit.",
               "client_request_id" => "tiny-followup-#{suffix}"
             })

    Live.eventually(fn ->
      case SalixAgent.AgentWorkspace.read(worker, path) do
        {:ok, content} -> if content =~ marker, do: {:ok, :updated}, else: :retry
        _ -> :retry
      end
    end)

    Live.eventually(fn ->
      replies = router_replies(router, task_messages!(group_id, parent["conversation_id"]))

      if Enum.any?(replies, fn message ->
           Enum.any?(List.wrap(message["content"]), &(is_map(&1) and &1["type"] == "file"))
         end), do: {:ok, :delivered}, else: :retry
    end)

    Live.await_session_settled!(router, Live.router_session_id!(router))
    assert [task] = routing_tasks!(group_id)
    assert task["id"] == task_id
    assert task["task_worker_agent_id"] == worker
  end

  test "live LLM: unfinished delivery relays the attached bytes without another Worker request",
       %{llm: llm} do
    suffix = Live.unique_suffix()

    %{group_id: group_id, router: router, worker: worker} =
      configure_group!(
        llm,
        suffix,
        "The report is already prepared. Do not send a Message or modify files. End the turn with outcome done."
      )

    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
    task_id = SalixStore.Ids.new_conversation_id()
    path = "/report-#{suffix}.pdf"
    original = File.read!(Path.join(__DIR__, "fixtures/attached-report.pdf"))

    # Use the real Task lifecycle, then let the initial Worker activation settle
    # before seeding its completed result. The result is not delivered to the
    # Router automatically; the user asks it to finish the outstanding delivery.
    assert {:ok, _} =
             SalixIM.TaskConversationInput.create_with_id(group_id, task_id, router, worker, %{
               "title" => "Prepared report #{suffix}",
               "content" => "Prepare a report and deliver the PDF to the user.",
               "origin_session_id" => Live.router_session_id!(router),
               "source_refs" => %{"parent_conversation_id" => parent["conversation_id"]},
               "schedule" => %{
                 "schedule_id" => nil,
                 "command" => "Prepare a report and deliver the PDF to the user."
               },
               "initial_message_attrs" => %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => router,
                 "content" => "Prepare the requested report PDF.",
                 "client_request_id" => "prepared-report-#{suffix}"
               }
             })

    wait_for_all_sessions_settled!(worker)
    seed_artifact!(worker, path, original, "original-#{suffix}")

    assert {:ok, blocks} =
             SalixIM.ConversationAttachments.bind_sender_files(worker, [
               %{"type" => "text", "text" => "The requested report is ready in this attachment."},
               %{"type" => "file", "path" => path, "title" => "Report.pdf"}
             ])

    assert {:ok, result} =
             SalixIM.ConversationServer.append_group_conversation_agent_message(
               group_id,
               task_id,
               worker,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => worker,
                 "content" => blocks,
                 "delivery_filter" => %{"participant_ids" => []},
                 "client_request_id" => "report-result-#{suffix}"
               }
             )

    # Same paths in different VFSes, and a later producer edit, must not replace
    # the immutable bytes that the Worker already attached.
    seed_artifact!(router, path, "WRONG_ROUTER_BYTES", "router-decoy-#{suffix}")
    seed_artifact!(worker, path, "LATER_WORKER_EDIT", "later-edit-#{suffix}")

    assert {:ok, _} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" =>
                 "You delegated my PDF to Task #{task_id}. Its result Message " <>
                   "#{result["message_id"]} has the completed report, but you only gave me a Task link. " <>
                   "I still need the actual PDF here to finish my original request.",
               "client_request_id" => "finish-delivery-#{suffix}"
             })

    delivered =
      Live.eventually(fn ->
        replies = router_replies(router, task_messages!(group_id, parent["conversation_id"]))

        case Enum.find(replies, fn message ->
               Enum.any?(List.wrap(message["content"]), &(is_map(&1) and &1["type"] == "file"))
             end) do
          nil -> :retry
          message -> {:ok, message}
        end
      end)

    assert {:ok, [projected]} =
             SalixIM.ConversationAttachments.materialize_messages(worker, [delivered])

    file = Enum.find(projected["content"], &(&1["type"] == "file"))
    assert {:ok, ^original} = SalixAgent.AgentWorkspace.read(worker, file["path"])
    Live.await_session_settled!(router, Live.router_session_id!(router))
    assert [task] = routing_tasks!(group_id)
    assert task["id"] == task_id
    assert length(task_messages!(group_id, task_id)) == 2
  end

  defp seed_artifact!(agent_id, path, bytes, operation_id) do
    assert {:ok, event} = SalixAgent.AgentWorkspace.prepare_write(agent_id, path, bytes)

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(agent_id, operation_id, %{}, [event])
  end

  defp routing_tasks!(group_id) do
    {:ok, %{"data" => conversations}} =
      SalixIM.Conversations.list_group_conversations(group_id, limit: 20)

    Enum.filter(conversations, &(&1["kind"] == "agent_task"))
  end

  defp await_review_delivery!(group_id, conversation_id, router, result_code) do
    Live.eventually(fn ->
      if Enum.any?(
           router_replies(router, task_messages!(group_id, conversation_id)),
           fn message ->
             Live.text_content(message["content"]) =~ result_code
           end
         ), do: {:ok, :delivered}, else: :retry
    end)
  end

  defp configure_group!(llm, suffix, worker_prompt \\ nil) do
    tenant = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    router = SalixStore.Ids.new_agent_id(group_id)
    worker = SalixStore.Ids.new_agent_id(group_id)
    Live.seed_group!(tenant, group_id)

    Live.configure!(router, llm, %{
      tenant_id: tenant,
      group_id: group_id,
      role: "router",
      template_id: "task-semantics-router-#{suffix}"
    })

    Live.configure!(worker, llm, %{
      tenant_id: tenant,
      group_id: group_id,
      role: "worker",
      template_id: "task-semantics-worker-#{suffix}",
      system_prompt:
        worker_prompt ||
          "This is a scheduled Task dry run. Do not perform external side effects or call tools; finish privately and briefly."
    })

    {:ok, _group} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router)
      end)

    %{tenant: tenant, group_id: group_id, router: router, worker: worker}
  end

  defp task_messages!(group_id, conversation_id) do
    {:ok, messages} =
      SalixIM.Conversations.list_group_conversation_messages(
        group_id,
        conversation_id,
        limit: 20
      )

    messages
  end

  defp wait_for_all_sessions_settled!(agent_id) do
    sessions =
      Live.eventually(fn ->
        case SalixAgent.Runtime.list_sessions(agent_id, include_hidden: true) do
          {:ok, []} -> :retry
          {:ok, sessions} -> {:ok, sessions}
          {:error, reason} -> raise "session list failed: #{inspect(reason)}"
        end
      end)

    Enum.each(sessions, fn %{"session_id" => session_id} ->
      Live.await_session_settled!(agent_id, session_id)
    end)
  end

  defp wait_for_all_sessions_quiescent!(agent_id) do
    sessions =
      Live.eventually(fn ->
        case SalixAgent.Runtime.list_sessions(agent_id, include_hidden: true) do
          {:ok, []} -> :retry
          {:ok, sessions} -> {:ok, sessions}
          {:error, reason} -> raise "session list failed: #{inspect(reason)}"
        end
      end)

    Enum.each(sessions, fn %{"session_id" => session_id} ->
      Live.await_session_quiescent!(agent_id, session_id)
    end)
  end

  defp settled_router_reply?(router, session_id, messages) do
    router_replies(router, messages) != [] and
      case SalixAgent.InternalSessionStore.read(router, session_id) do
        {:ok, session} ->
          SalixAgent.InternalSession.status(session) == :idle and
            SalixAgent.InternalSession.work_reasons(session) == []

        _other ->
          false
      end
  end

  defp router_replies(router, messages) do
    Enum.filter(messages, &(&1["actor_type"] == "agent" and &1["agent_id"] == router))
  end

  for scenario <- [:action_question, :nonblocking_preference] do
    @scenario scenario
    test "live model completes #{@scenario} without an extra user confirmation", %{llm: llm} do
      agent = SalixAgent.TestSupport.new_agent_id()
      session = SalixStore.Ids.new_session_id()
      marker = "FOLLOW_THROUGH_#{Live.unique_suffix()}"
      path = "/follow-through/#{marker}.md"
      Live.configure!(agent, llm)

      request =
        case @scenario do
          :action_question ->
            "Can you create #{path} in your VFS containing #{marker}? A short heading is fine."

          :nonblocking_preference ->
            "Create #{path} in your VFS containing #{marker}. I haven't chosen a heading; " <>
              "pick a suitable one. Complete the file even if you ask about my style preference."
        end

      assert {:ok, _} =
               SalixAgent.deliver(
                 agent,
                 %{content: request, session_id: session},
                 source_message_id: marker
               )

      state = Live.await_session_settled!(agent, session)
      assert {:ok, content} = SalixAgent.AgentWorkspace.read(agent, path)
      assert content =~ marker
      refute state.wait
    end
  end

  for {scenario, exit_code, stderr} <- [
        {"approved", 0, ""},
        {"cancelled", 1, "User canceled. (-128)"}
      ] do
    @auth_exit_code exit_code
    @auth_stderr stderr
    @tag :native_authorization
    test "live model uses native authorization and records #{scenario} without another user message",
         %{llm: llm} do
      agent = SalixAgent.TestSupport.new_agent_id()
      session = SalixStore.Ids.new_session_id()
      marker = "NATIVE_AUTH_#{Live.unique_suffix()}"
      path = "/authorization/#{marker}.json"
      previous = Application.get_env(:salix_agent, :env_dispatch)

      result = %{
        "status" => "completed",
        "exit_code" => @auth_exit_code,
        "stdout" => if(@auth_exit_code == 0, do: "0\n", else: ""),
        "stderr" => @auth_stderr
      }

      :persistent_term.put(NativeAuthorizationDispatch, %{owner: self(), result: result})
      Application.put_env(:salix_agent, :env_dispatch, NativeAuthorizationDispatch)

      on_exit(fn ->
        :persistent_term.erase(NativeAuthorizationDispatch)

        if previous,
          do: Application.put_env(:salix_agent, :env_dispatch, previous),
          else: Application.delete_env(:salix_agent, :env_dispatch)
      end)

      Live.configure!(agent, llm)

      assert {:ok, _} =
               SalixAgent.deliver(
                 agent,
                 %{
                   session_id: session,
                   content:
                     "On my connected macOS device auth-mac, environment auth-env, read the numeric effective user ID with administrator privileges. " <>
                       "This read-only check is authorized. I can use the native system dialog on that Mac. " <>
                       "Save the command's actual exit_code, stdout, and stderr as JSON in your VFS at #{path}, including if I cancel."
                 },
                 source_message_id: marker
               )

      Live.await_session_settled!(agent, session)
      assert {:ok, report} = SalixAgent.AgentWorkspace.read(agent, path)

      assert Map.take(Jason.decode!(report), ["exit_code", "stdout", "stderr"]) ==
               Map.take(result, ["exit_code", "stdout", "stderr"])

      commands = collect_native_auth_commands([])

      assert [authorization_request] =
               Enum.filter(
                 commands,
                 &(String.contains?(&1, "osascript") and
                     String.contains?(&1, "with administrator privileges"))
               )

      if @auth_exit_code != 0 do
        assert List.last(commands) == authorization_request,
               "user cancellation must stop further command execution"
      end
    end
  end

  defp collect_native_auth_commands(commands) do
    receive do
      {:native_auth_command, command} -> collect_native_auth_commands([command | commands])
    after
      0 -> Enum.reverse(commands)
    end
  end
end
