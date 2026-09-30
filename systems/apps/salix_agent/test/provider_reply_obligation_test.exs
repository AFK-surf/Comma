defmodule SalixAgent.ProviderReplyObligationTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{InternalSession, InternalSessionStore, LLM, ProviderReplyObligation}
  alias SalixAgent.TestSupport.SessionData
  alias SalixStore.S3

  @channel "C0AQ0C0KVMH"
  @thread_a "1787626579.346779"
  @thread_b "1787627519.273859"
  @source_a1 "im_provider:slack:slack-1:C0AQ0C0KVMH:1787628850.000001"
  @context_a "meeting-activation:meeting-completed-a1"
  @internal_context "internal:group-health-refresh"
  @source_b "im_provider:slack:slack-1:C0AQ0C0KVMH:1787628878.353279"
  @source_a2 "im_provider:slack:slack-1:C0AQ0C0KVMH:1787628913.646619"

  defmodule ScriptLLM do
    @behaviour LLM
    @owner_key {__MODULE__, :owner}

    def set_owner(owner, timeout \\ 5_000), do: :persistent_term.put(@owner_key, {owner, timeout})
    def clear_owner, do: :persistent_term.erase(@owner_key)

    @impl true
    def complete(messages, tools) do
      {owner, timeout} = :persistent_term.get(@owner_key)

      send(
        owner,
        {:reply_obligation_llm_request, self(), messages, tools}
      )

      receive do
        {:reply_obligation_llm_response, response} -> response
      after
        timeout -> raise "timed out waiting for provider-reply-obligation test response"
      end
    end
  end

  defmodule CaptureSlack do
    @behaviour SalixAgent.Tools.ImRouter
    @owner_key {__MODULE__, :owner}
    @telegram_response_key {__MODULE__, :telegram_response}

    def set_owner(owner), do: :persistent_term.put(@owner_key, owner)

    def clear_owner do
      :persistent_term.erase(@owner_key)
      :persistent_term.erase(@telegram_response_key)
    end

    def telegram_response(response), do: :persistent_term.put(@telegram_response_key, response)

    @task_conversation_id "cnv1_2094348809374007296_2094348809378209999"

    def task_conversation_id, do: @task_conversation_id

    @impl true
    def list_connects(_agent_id),
      do:
        {:ok,
         [
           %{"connect_id" => "internal", "provider" => "internal"},
           %{"connect_id" => "slack-1", "provider" => "slack"},
           %{"connect_id" => "telegram-1", "provider" => "telegram"},
           %{"connect_id" => "feishu-1", "provider" => "feishu"},
           %{"connect_id" => "wechat-1", "provider" => "wechat"},
           %{"connect_id" => "imessage-1", "provider" => "imessage"}
         ]}

    @impl true
    def provider_manual("slack") do
      {:ok,
       %{
         "provider" => "slack",
         "apis" => [
           %{
             "name" => "slack.reply_message",
             "safety" => "write",
             "description" => "Reply in a Slack thread.",
             "required_params" => ["channel", "text", "thread_ts"],
             "parameters" => %{
               "channel" => "channel",
               "thread_ts" => "thread",
               "text" => "message"
             }
           },
           %{
             "name" => "slack.post_task_card",
             "safety" => "write",
             "description" => "Publish one native Slack Task surface.",
             "required_params" => ["conversation_id", "channel", "thread_ts"],
             "parameters" => %{
               "conversation_id" => "task conversation",
               "channel" => "channel",
               "thread_ts" => "thread"
             }
           }
         ]
       }}
    end

    def provider_manual("internal") do
      {:ok,
       %{
         "provider" => "internal",
         "apis" => [
           %{
             "name" => "internal.task.create",
             "roles" => ["router"],
             "safety" => "write",
             "description" => "Create a durable internal Comma Task.",
             "required_params" => ["content"],
             "parameters" => %{"content" => "task command"}
           }
         ]
       }}
    end

    def provider_manual("telegram") do
      {:ok,
       %{
         "provider" => "telegram",
         "apis" => [
           %{
             "name" => "telegram.open_task_topic",
             "safety" => "write",
             "description" => "Open a Task topic.",
             "required_params" => ["chat_id", "conversation_id"],
             "parameters" => %{"chat_id" => "chat", "conversation_id" => "Task"}
           },
           %{
             "name" => "telegram.send_message",
             "safety" => "write",
             "description" => "Send a Telegram reply.",
             "required_params" => ["chat_id", "text"],
             "parameters" => %{"chat_id" => "chat", "text" => "reply"}
           }
         ]
       }}
    end

    def provider_manual(provider), do: SalixIM.Provider.Manuals.manual(provider)

    @impl true
    def call_api(agent_id, "telegram", "telegram.open_task_topic", args) do
      send(:persistent_term.get(@owner_key), {:telegram_topic_open, agent_id, args})

      {:ok,
       %{
         "status" => "ready",
         "message_thread_id" => "812",
         "conversation_id" => get_in(args, ["params", "conversation_id"])
       }}
    end

    def call_api(agent_id, "telegram", "telegram.send_message", args) do
      send(:persistent_term.get(@owner_key), {:telegram_call, agent_id, args})

      case :persistent_term.get(@telegram_response_key, {:ok, %{"ok" => true}}) do
        :controlled ->
          send(:persistent_term.get(@owner_key), {:telegram_reply_pending, self()})

          receive do
            {:complete_telegram_reply, response} -> response
          after
            5_000 -> raise "timed out waiting for Telegram reply test response"
          end

        response ->
          response
      end
    end

    def call_api(agent_id, provider, operation, args)
        when provider in ["feishu", "wechat", "imessage"] do
      send(
        :persistent_term.get(@owner_key),
        {:unified_reply, agent_id, provider, operation, args}
      )

      {:ok, %{"ok" => true, "message_id" => "receipt"}}
    end

    def call_api(agent_id, "slack", "slack.reply_message", args) do
      send(:persistent_term.get(@owner_key), {:reply_obligation_slack_call, agent_id, args})
      {:ok, %{"ok" => true, "channel" => get_in(args, ["params", "channel"])}}
    end

    def call_api(agent_id, "slack", "slack.post_task_card", args) do
      send(:persistent_term.get(@owner_key), {:reply_obligation_card_post, agent_id, args})

      if get_in(args, ["params", "thread_ts"]) == "blocked" do
        send(:persistent_term.get(@owner_key), {:blocked_card, self()})

        receive do
          :release_blocked_card -> :ok
        end
      end

      {:ok,
       %{
         "conversation_id" => get_in(args, ["params", "conversation_id"]),
         "task_id" => "comma_test_task",
         "delivery_status" => "queued"
       }}
    end

    def call_api(agent_id, "internal", "internal.task.create", args) do
      owner = :persistent_term.get(@owner_key)
      send(owner, {:reply_obligation_task_create, agent_id, args, self()})

      receive do
        :reply_obligation_complete_task_create -> :ok
      after
        5_000 -> raise "timed out waiting to complete provider-reply-obligation Task creation"
      end

      {:ok,
       %{
         "created" => get_in(args, ["params", "test_auto_card"]) == true,
         "conversation_id" => @task_conversation_id,
         "conversation_kind" => "agent_task",
         "worker_agent_id" => "agt1_0000000000000000001_0000000000000000002_0000000000000000009"
       }}
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")

    previous_store = Application.get_env(:salix_store, :s3_backend)
    previous_llm = Application.get_env(:salix_agent, :llm)
    previous_im_provider = Application.get_env(:salix_agent, :im_provider_mod)
    previous_external_runtime = Application.get_env(:salix_agent, :external_runtime_driver)
    previous_idle_ms = Application.get_env(:salix_agent, :session_actor_idle_ms)

    Application.put_env(:salix_store, :s3_backend, S3.Fake)

    if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    ScriptLLM.set_owner(self())
    CaptureSlack.set_owner(self())
    Application.put_env(:salix_agent, :llm, ScriptLLM)
    Application.put_env(:salix_agent, :im_provider_mod, CaptureSlack)
    Application.put_env(:salix_agent, :external_runtime_driver, SalixAgent.ExternalRuntime.None)
    Application.put_env(:salix_agent, :session_actor_idle_ms, 5_000)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    agent = SalixAgent.TestSupport.create_control_agent!(agent_id, %{"role" => "router"})
    {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(agent)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      ScriptLLM.clear_owner()
      CaptureSlack.clear_owner()
      put_or_delete_env(:salix_store, :s3_backend, previous_store)
      put_or_delete_env(:salix_agent, :llm, previous_llm)
      put_or_delete_env(:salix_agent, :im_provider_mod, previous_im_provider)
      put_or_delete_env(:salix_agent, :external_runtime_driver, previous_external_runtime)
      put_or_delete_env(:salix_agent, :session_actor_idle_ms, previous_idle_ms)
    end)

    {:ok, agent_id: agent_id, session_id: session_id}
  end

  test "queued Slack sources wait for the current Router activation to settle", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    deliver!(
      agent_id,
      @source_a1,
      slack_input(@thread_a, "A1: keep the Home Agent busy"),
      obligation(@thread_a)
    )

    {first_pid, first_messages, _tools} = await_request!()
    assert request_text(first_messages) =~ "A1: keep the Home Agent busy"

    # Identified provider-system context can arrive while A1 is active. It is
    # useful group context, but its no-wake source must not replace A1's
    # singular provider reply authority.
    deliver_context!(
      agent_id,
      @context_a,
      "A1 meeting completed context",
      @thread_a
    )

    # Source-less/internal work keeps its existing same-activation behavior,
    # but it must not replace A1 as the singular external reply authority.
    deliver_internal!(agent_id, @internal_context, "group health refreshed")

    # Reproduce the incident ordering: B and another A message arrive while
    # the Router is still deciding the current A round.
    deliver!(
      agent_id,
      @source_b,
      slack_input(@thread_b, "B: convert this to MP3 and send it"),
      obligation(@thread_b)
    )

    deliver!(
      agent_id,
      @source_a2,
      slack_input(@thread_a, "A2: continue the Home Agent work"),
      obligation(@thread_a)
    )

    # The zero-wait Task tool completes after B and A2 are already queued. Its
    # wakeable runtime notification must bypass those deferred provider users
    # without consuming or exposing either one to A1's activation.
    send(first_pid, {:reply_obligation_llm_response, task_create("create-task-a1")})
    assert_receive {:reply_obligation_task_create, ^agent_id, _args, task_create_pid}, 5_000

    # The deliberately wakeable internal input may start another round while
    # the Task tool runs in the background. It stays under A1's source
    # authority and must still exclude the deferred provider messages.
    {waiting_pid, waiting_messages, _tools} = await_request!()
    waiting_text = request_text(waiting_messages)
    assert waiting_text =~ "A1 meeting completed context"
    assert waiting_text =~ "group health refreshed"
    refute waiting_text =~ "B: convert this to MP3 and send it"
    refute waiting_text =~ "A2: continue the Home Agent work"

    # Queue the completion while A1's model request is still active. A generic
    # wait with no ready completion now yields to B, even if this tool runs.
    send(task_create_pid, :reply_obligation_complete_task_create)

    assert Enum.reduce_while(1..500, false, fn _, _ ->
             state = read_session!(agent_id, session_id)

             if Enum.any?(state.async_results, &(&1["tool_call_id"] == "create-task-a1")) do
               {:halt, true}
             else
               Process.sleep(10)
               {:cont, false}
             end
           end)

    send(waiting_pid, {:reply_obligation_llm_response, wait_for("wait-for-task-a1")})

    {task_result_pid, task_result_messages, _tools} = await_request!()
    task_result_text = request_text(task_result_messages)
    assert task_result_text =~ CaptureSlack.task_conversation_id()
    assert task_result_text =~ "A1 meeting completed context"
    assert task_result_text =~ "group health refreshed"
    refute task_result_text =~ "B: convert this to MP3 and send it"
    refute task_result_text =~ "A2: continue the Home Agent work"

    send(task_result_pid, {:reply_obligation_llm_response, slack_post("reply-a1", @thread_a)})
    assert_slack_call!(agent_id, @thread_a, @source_a1)

    {card_pid, card_messages, _tools} = await_request!()
    card_text = request_text(card_messages)
    refute card_text =~ "B: convert this to MP3 and send it"
    refute card_text =~ "A2: continue the Home Agent work"

    send(card_pid, {:reply_obligation_llm_response, card_post("publish-card-a1", @thread_a)})

    assert_receive {:reply_obligation_card_post, ^agent_id,
                    %{
                      "params" => %{"thread_ts" => @thread_a},
                      "tool_context" => %{"source_message_id" => @source_a1}
                    }},
                   5_000

    # Provider calls are intermediate tool turns. B and A2 must stay queued
    # while A1 continues to its explicit terminal decision.
    {a1_terminal_pid, a1_terminal_messages, _tools} = await_request!()
    a1_terminal_text = request_text(a1_terminal_messages)
    refute a1_terminal_text =~ "B: convert this to MP3 and send it"
    refute a1_terminal_text =~ "A2: continue the Home Agent work"

    send(a1_terminal_pid, {:reply_obligation_llm_response, end_turn("settle-a1")})

    {b_pid, b_messages, _tools} = await_request!()
    b_text = request_text(b_messages)
    assert b_text =~ "B: convert this to MP3 and send it"
    refute b_text =~ "A2: continue the Home Agent work"

    send(b_pid, {:reply_obligation_llm_response, slack_post("reply-b", @thread_b)})
    assert_slack_call!(agent_id, @thread_b, @source_b)

    {b_terminal_pid, b_terminal_messages, _tools} = await_request!()
    refute request_text(b_terminal_messages) =~ "A2: continue the Home Agent work"
    send(b_terminal_pid, {:reply_obligation_llm_response, end_turn("settle-b")})

    {a2_pid, a2_messages, _tools} = await_request!()
    assert request_text(a2_messages) =~ "A2: continue the Home Agent work"

    send(a2_pid, {:reply_obligation_llm_response, slack_post("reply-a2", @thread_a)})
    assert_slack_call!(agent_id, @thread_a, @source_a2)

    {a2_terminal_pid, _messages, _tools} = await_request!()
    send(a2_terminal_pid, {:reply_obligation_llm_response, end_turn("settle-a2")})

    settled = await_source_settled!(agent_id, session_id, @source_a2)
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(settled)) == 0
  end

  test "a replied source waiting without running work yields to a new provider request", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    deliver!(
      agent_id,
      @source_a1,
      slack_input(@thread_a, "A: inspect my environment"),
      obligation(@thread_a)
    )

    {a_pid, _, _} = await_request!()
    send(a_pid, {:reply_obligation_llm_response, slack_post("answer-a", @thread_a)})
    assert_slack_call!(agent_id, @thread_a, @source_a1)
    {wait_pid, _, _} = await_request!()
    send(wait_pid, {:reply_obligation_llm_response, wait_for("wait-for-user", 1800)})
    waiting = await_waiting!(agent_id, session_id)
    refute ProviderReplyObligation.pending?(SalixAgent.InternalSession.open(waiting))

    deliver!(
      agent_id,
      @source_b,
      slack_input(@thread_b, "B: a fresh request"),
      obligation(@thread_b)
    )

    {b_pid, messages, _} = await_request!()
    assert request_text(messages) =~ "B: a fresh request"
    current = read_session!(agent_id, session_id)
    assert current.last_ack_message_id >= waiting.next_message_id - 1
    assert current.wait == nil
    assert Enum.any?(current.events, &(&1["kind"] == "provider_wait_yielded"))
    send(b_pid, {:reply_obligation_llm_response, slack_post("answer-b", @thread_b)})
    assert_slack_call!(agent_id, @thread_b, @source_b)
    {end_pid, _, _} = await_request!()
    send(end_pid, {:reply_obligation_llm_response, end_turn("end-b")})
    await_source_settled!(agent_id, session_id, @source_b)
  end

  test "a replied source with a running callback yields to a new provider request", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    previous = Application.get_env(:salix_agent, :capability_request_store_mod)

    Application.put_env(
      :salix_agent,
      :capability_request_store_mod,
      SalixAgent.CapabilityRequests
    )

    on_exit(fn -> put_or_delete_env(:salix_agent, :capability_request_store_mod, previous) end)

    assert {:ok, _} =
             SalixAgent.CapabilityRequests.create_capability_request(%{
               "source_agent_id" => agent_id,
               "source_session_id" => session_id,
               "tool_call_id" => "background-A",
               "request_type" => "location",
               "request_payload" => %{"location" => %{"reason" => "weather"}},
               "expires_at" => System.system_time(:second) + 1000
             })

    # Restore a callback that belongs to A before the Router owner starts.
    assert {:ok, _} =
             InternalSessionStore.prepare_commit(agent_id, session_id, [
               %{"type" => "session_created", "session_id" => session_id},
               %{
                 "type" => "async_tool_call_started",
                 "tool_call_id" => "background-A",
                 "tool_name" => "location.request",
                 "completion_mode" => "external_callback",
                 "trusted_origin_source_message_ids" => [@source_a1],
                 "status" => "running"
               }
             ])

    deliver!(
      agent_id,
      @source_a1,
      slack_input(@thread_a, "A: inspect my environment"),
      obligation(@thread_a)
    )

    {a_pid, _, _} = await_request!()
    send(a_pid, {:reply_obligation_llm_response, slack_post("answer-a", @thread_a)})
    assert_slack_call!(agent_id, @thread_a, @source_a1)
    {wait_pid, _, _} = await_request!()
    send(wait_pid, {:reply_obligation_llm_response, wait_for("wait-for-user", 1800)})
    waiting = await_waiting!(agent_id, session_id)
    refute ProviderReplyObligation.pending?(SalixAgent.InternalSession.open(waiting))

    deliver!(
      agent_id,
      @source_b,
      slack_input(@thread_b, "B: a fresh request"),
      obligation(@thread_b)
    )

    {b_pid, messages, _} = await_request!()
    assert request_text(messages) =~ "B: a fresh request"
    current = read_session!(agent_id, session_id)
    assert current.last_ack_message_id >= waiting.next_message_id - 1
    assert current.wait == nil
    assert current.async_tool_calls["background-A"]["status"] == "running"

    assert current.async_tool_calls["background-A"]["trusted_origin_source_message_ids"] == [
             @source_a1
           ]

    assert Enum.any?(current.events, &(&1["kind"] == "provider_wait_yielded"))
    send(b_pid, {:reply_obligation_llm_response, slack_post("answer-b", @thread_b)})
    assert_slack_call!(agent_id, @thread_b, @source_b)
    {end_pid, _, _} = await_request!()
    send(end_pid, {:reply_obligation_llm_response, end_turn("end-b")})
    await_source_settled!(agent_id, session_id, @source_b)

    result = %{content: "background result", status: "completed", error: false}

    assert {:ok, _} =
             SalixAgent.complete_async_tool_call(agent_id, session_id, "background-A", result)

    {callback_pid, callback_messages, _} = await_request!()
    assert request_text(callback_messages) =~ "background result"
    callback_state = read_session!(agent_id, session_id)
    handle = SalixAgent.InternalSession.open(callback_state)
    assert {:ok, record} = SalixAgent.InternalSession.lookup_async_call(handle, "background-A")
    assert record["status"] == "completed"
    assert record["trusted_origin_source_message_ids"] == [@source_a1]

    assert {:ok, _} =
             SalixAgent.complete_async_tool_call(agent_id, session_id, "background-A", result)

    duplicate_state = read_session!(agent_id, session_id)
    assert duplicate_state.async_results == callback_state.async_results
    send(callback_pid, {:reply_obligation_llm_response, end_turn("end-background")})
  end

  for {provider, operation, destination, params} <- [
        {"slack", "slack.reply_message", %{"channel_id" => @channel, "thread_ts" => @thread_a},
         %{"channel" => @channel, "thread_ts" => @thread_a, "text" => "answer"}},
        {"feishu", "feishu.reply_text", %{"chat_id" => "chat", "message_id" => "message"},
         %{"message_id" => "message", "text" => "answer"}},
        {"wechat", "wechat.reply_text", %{"wechat_id" => "peer"}, %{"text" => "answer"}},
        {"imessage", "imessage.send_message", %{"chat_id" => "chat"},
         %{"chat_id" => "chat", "text" => "answer"}}
      ] do
    @tag :model_failure_reply
    test "#{provider} model failure notifies only the accepted destination", %{
      agent_id: agent_id,
      session_id: session_id
    } do
      provider = unquote(provider)
      source = "model-failure-" <> provider
      destination = Map.put(unquote(Macro.escape(destination)), "connect_id", provider <> "-1")

      assert {:ok, :created} =
               SalixAgent.deliver(
                 agent_id,
                 %{
                   content: "answer once",
                   role: "user",
                   trusted_origin: %{
                     "provider" => provider,
                     "source_actor_type" => "provider_user",
                     "source_message_id" => source,
                     "provider_context" => destination
                   }
                 },
                 source_message_id: source
               )

      {model, _, _} = await_request!()

      send(
        model,
        {:reply_obligation_llm_response,
         LLM.Error.http("openai_responses", 401, "private credential")}
      )

      args =
        if provider == "slack" do
          assert_receive {:reply_obligation_slack_call, ^agent_id, args}, 5_000
          args
        else
          assert_receive {:unified_reply, ^agent_id, ^provider, _, args}, 5_000
          args
        end

      for {key, value} <- unquote(Macro.escape(params)),
          key != "text",
          do: assert(args["params"][key] == value)

      assert args["tool_context"]["source_message_id"] == source
      refute inspect(args["params"]) =~ "private credential"
      await_source_settled!(agent_id, session_id, source)
      refute_receive {:reply_obligation_llm_request, _, _, _}, 100
    end

    @tag :guard_failure
    test "#{provider} guard failure releases queued input through the shared disposition", %{
      agent_id: agent_id,
      session_id: session_id
    } do
      provider = unquote(provider)
      destination = Map.put(unquote(Macro.escape(destination)), "connect_id", provider <> "-1")

      deliver = fn source, text ->
        assert {:ok, :created} =
                 SalixAgent.deliver(
                   agent_id,
                   %{
                     content: text,
                     role: "user",
                     created_at: System.system_time(:second),
                     trusted_origin: %{
                       "provider" => provider,
                       "source_actor_type" => "provider_user",
                       "source_message_id" => source,
                       "provider_context" => destination
                     }
                   },
                   source_message_id: source
                 )
      end

      deliver.("guard-source", "first request")
      {first, _, _} = await_request!()
      deliver.("guard-next", "next independent request")

      for n <- 1..5 do
        pid = if n == 1, do: first, else: elem(await_request!(), 0)

        send(
          pid,
          {:reply_obligation_llm_response,
           {:assistant, "",
            [
              %{
                id: "repeat-#{n}",
                name: "call",
                args: %{"tool" => "help", "params" => %{"tool" => "im_api.telegram.send_message"}}
              }
            ]}}
        )
      end

      args =
        if provider == "slack" do
          assert_receive {:reply_obligation_slack_call, ^agent_id, args}, 5000
          args
        else
          assert_receive {:unified_reply, ^agent_id, ^provider, _, args}, 5000
          args
        end

      assert args["params"]["text"] =~ "couldn't complete"
      assert args["tool_context"]["source_message_id"] == "guard-source"
      {next, messages, _} = await_request!()
      assert request_text(messages) =~ "next independent request"
      current = read_session!(agent_id, session_id)

      assert Enum.any?(
               current.events,
               &(&1["kind"] == "terminal_reply_delivered" and
                   &1["event"]["source_message_id"] == "guard-source" and
                   &1["event"]["outcome"] == "blocked")
             )

      assert current.last_ack_message_id < find_source_message!(current, "guard-next").id
      params = Map.put(unquote(Macro.escape(params)), "connect_id", provider <> "-1")

      send(
        next,
        {:reply_obligation_llm_response,
         {:assistant, "",
          [
            %{
              id: "after-guard-final",
              name: "call",
              args: %{
                "tool" => "im_api." <> unquote(operation),
                "params" => params,
                "reply_mode" => "final",
                "final_outcome" => "done"
              }
            }
          ]}}
      )

      {finish, _, _} = await_request!()
      send(finish, {:reply_obligation_llm_response, end_turn("after-guard-explicit-finish")})
      await_source_settled!(agent_id, session_id, "guard-next")
      refute_receive {:reply_obligation_llm_request, _, _, _}, 300
    end

    @tag :unified_reply
    test "#{provider} final reply requires a separate completion decision", %{
      agent_id: agent_id,
      session_id: session_id
    } do
      provider = unquote(provider)
      source = "unified-" <> provider
      destination = Map.put(unquote(Macro.escape(destination)), "connect_id", provider <> "-1")
      params = Map.put(unquote(Macro.escape(params)), "connect_id", provider <> "-1")

      assert {:ok, :created} =
               SalixAgent.deliver(
                 agent_id,
                 %{
                   content: "answer once",
                   role: "user",
                   created_at: System.system_time(:second),
                   trusted_origin: %{
                     "provider" => provider,
                     "source_actor_type" => "provider_user",
                     "source_message_id" => source,
                     "provider_context" => destination
                   }
                 },
                 source_message_id: source
               )

      {pid, messages, _} = await_request!()
      refute request_text(messages) =~ "Set reply_mode=final"

      send(
        pid,
        {:reply_obligation_llm_response,
         {:assistant, "",
          [
            %{
              id: "unified-final",
              name: "call",
              args: %{
                "tool" => "im_api." <> unquote(operation),
                "params" => params,
                "reply_mode" => "final",
                "final_outcome" => "done"
              }
            }
          ]}}
      )

      if provider == "slack" do
        assert_receive {:reply_obligation_slack_call, ^agent_id, _}, 5000
      else
        assert_receive {:unified_reply, ^agent_id, ^provider, _, _}, 5000
      end

      {next, _, _} = await_request!()
      send(next, {:reply_obligation_llm_response, end_turn("explicit-finish")})
      settled = await_source_settled!(agent_id, session_id, source)
      refute Enum.any?(settled.events, &(&1["kind"] == "terminal_reply_delivered"))
      refute_receive {:reply_obligation_llm_request, _, _, _}, 300
    end
  end

  for adapter <- [:call, :model_failure] do
    @tag :unified_reply
    @tag model_failure_reply: adapter == :model_failure
    test "Comma #{adapter} reply creates one canonical Message and completes separately", %{
      agent_id: agent_id,
      session_id: session_id
    } do
      group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
      SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})
      previous_delivery = Application.get_env(:salix_im, :agent_delivery_mod)
      Application.put_env(:salix_im, :agent_delivery_mod, Salix.Bindings.IMAgentDelivery)
      Application.put_env(:salix_agent, :im_provider_mod, SalixIM.Provider)

      on_exit(fn ->
        SalixIM.TestSupport.Fleet.stop_all!()
        put_or_delete_env(:salix_im, :agent_delivery_mod, previous_delivery)
      end)

      assert {:ok, input} =
               SalixIM.RouterConversationInput.append_user_message(
                 group_id,
                 %{
                   "content" => "Prepare a holiday calendar",
                   "client_request_id" => "unified-comma"
                 }
               )

      {pid, _, _} = await_request!()
      args = %{"reply_mode" => "final", "final_outcome" => "done"}

      args =
        Map.merge(args, %{
          "tool" => "im_api.internal.send_message",
          "params" => %{
            "connect_id" => "internal",
            "conversation_id" => input["conversation_id"],
            "content" => [%{"type" => "text", "text" => "I will prepare the calendar."}]
          }
        })

      response =
        if unquote(adapter) == :model_failure,
          do: LLM.Error.http("openai_responses", 402, "private credit details"),
          else:
            {:assistant, "",
             [%{id: "comma-final", name: Atom.to_string(unquote(adapter)), args: args}]}

      send(pid, {:reply_obligation_llm_response, response})

      if unquote(adapter) != :model_failure do
        {next, messages, _} = await_request!()
        assert request_text(messages) =~ "I will prepare the calendar."
        current = read_session!(agent_id, session_id)
        assert current.last_ack_message_id < Enum.find(current.messages, &(&1.role == "user")).id
        send(next, {:reply_obligation_llm_response, end_turn("comma-explicit-finish")})
      end

      await_settled!(agent_id, session_id)
      refute_receive {:reply_obligation_llm_request, _, _, _}, 300

      assert {:ok, [message]} =
               SalixIM.Conversations.list_group_conversation_messages(
                 group_id,
                 input["conversation_id"],
                 after_id: input["message_id"]
               )

      if unquote(adapter) == :model_failure do
        assert inspect(message["content"]) =~ "model service"
        refute inspect(message["content"]) =~ "private credit details"
      else
        assert message["content"] == [
                 %{"type" => "text", "text" => "I will prepare the calendar."}
               ]
      end

      events = read_session!(agent_id, session_id).events

      if unquote(adapter) == :model_failure do
        assert Enum.any?(events, &(&1["kind"] == "runtime_failure_reply_settled"))
      else
        refute Enum.any?(events, &(&1["kind"] == "terminal_reply_delivered"))
      end
    end
  end

  @tag :terminal_reply
  test "a successful final Telegram reply continues until explicit completion", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    deliver_telegram!(agent_id, "tg-final-A", "A: answer once")
    {pid, _, _} = await_request!()
    {:assistant, content, [call]} = telegram_post("tg-final-answer")

    call = %{
      call
      | args: Map.merge(call.args, %{"reply_mode" => "final", "final_outcome" => "done"})
    }

    send(pid, {:reply_obligation_llm_response, {:assistant, content, [call]}})

    assert_receive {:telegram_call, ^agent_id, _}, 5000

    {next, _, _} = await_request!()
    send(next, {:reply_obligation_llm_response, end_turn("tg-explicit-finish")})

    settled = await_source_settled!(agent_id, session_id, "tg-final-A")
    assert settled.wait == nil

    deliver_telegram!(agent_id, "tg-final-B", "B: independent next request")
    {next, messages, _} = await_request!()
    assert request_text(messages) =~ "B: independent next request"
    send(next, {:reply_obligation_llm_response, end_turn("tg-final-end-b")})
    await_source_settled!(agent_id, session_id, "tg-final-B")
    refute_receive {:telegram_call, ^agent_id, _}, 100
  end

  @tag :terminal_reply
  test "an end_turn reply retains a failed source and admits input queued during its successful retry",
       %{agent_id: agent_id, session_id: session_id} do
    CaptureSlack.telegram_response({:error, "telegram request rejected"})
    deliver_telegram!(agent_id, "tg-terminal-A", "A: answer once")
    {first, _, _} = await_request!()
    send(first, {:reply_obligation_llm_response, terminal_telegram_reply("terminal-failed")})
    assert_receive {:telegram_call, ^agent_id, _}, 5_000

    {repair, messages, _} = await_request!()
    assert request_text(messages) =~ "telegram request rejected"
    failed = read_session!(agent_id, session_id)
    assert failed.last_ack_message_id == 0
    refute Enum.any?(failed.events, &(&1["kind"] == "terminal_reply_delivered"))
    refute_receive {:telegram_call, ^agent_id, _}, 50

    send(repair, {:reply_obligation_llm_response, idle_call("inspect-terminal-failure")})
    {retry, _, _} = await_request!()
    CaptureSlack.telegram_response(:controlled)
    send(retry, {:reply_obligation_llm_response, terminal_telegram_reply("terminal-retry")})

    assert_receive {:telegram_call, ^agent_id,
                    %{"tool_context" => %{"source_message_id" => "tg-terminal-A"}}},
                   5_000

    assert_receive {:telegram_reply_pending, sender}, 5_000
    deliver_telegram!(agent_id, "tg-terminal-B", "B: independent next request")
    send(sender, {:complete_telegram_reply, {:ok, %{"ok" => true}}})

    {next, messages, _} = await_request!()
    assert request_text(messages) =~ "B: independent next request"
    current = read_session!(agent_id, session_id)
    assert current.last_ack_message_id >= find_source_message!(current, "tg-terminal-A").id
    assert current.last_ack_message_id < find_source_message!(current, "tg-terminal-B").id
    assert Enum.count(current.events, &(&1["kind"] == "terminal_reply_delivered")) == 1
    refute_receive {:telegram_call, ^agent_id, _}, 100

    send(next, {:reply_obligation_llm_response, end_turn("terminal-B-finish")})
    await_source_settled!(agent_id, session_id, "tg-terminal-B")
    refute_receive {:reply_obligation_llm_request, _, _, _}, 100
    refute_receive {:telegram_call, ^agent_id, _}, 100
  end

  defmodule NativePrompt do
    def capabilities(_), do: %{"question" => true, "location" => true, "permission" => true}

    def request(scope, type, args, call) do
      send(
        :persistent_term.get({__MODULE__, :owner}),
        {:native_prompt, self(), scope, type, args, call}
      )

      receive do
        :delivered -> {:ok, %{"status" => "question_delivered", "message_id" => 41}}
      after
        5_000 -> {:error, :test_timeout}
      end
    end
  end

  for {type, params} <- [
        {"question", %{"question" => "哪个城市？"}},
        {"location", %{"reason" => "查询当地天气需要城市或位置。"}}
      ] do
    @tag :native_interaction
    test "native #{type} repairs missing locale before delivery, releases B, and accepts independent C",
         c do
      type = unquote(type)
      params = unquote(Macro.escape(params))
      previous = Application.get_env(:salix_agent, :telegram_interaction_mod)
      Application.put_env(:salix_agent, :telegram_interaction_mod, NativePrompt)
      :persistent_term.put({NativePrompt, :owner}, self())

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:salix_agent, :telegram_interaction_mod),
          else: Application.put_env(:salix_agent, :telegram_interaction_mod, previous)

        :persistent_term.erase({NativePrompt, :owner})
      end)

      deliver_telegram!(c.agent_id, "native-A", "A: ask for my city", "501")
      {pid, _, tools} = await_request!()
      assert tools == SalixAgent.ToolDisclosure.internal_llm_specs("router")

      # Replay the old model call: a Chinese question without a locale must not
      # send an English card or settle the source before the model corrects it.
      send(
        pid,
        {:reply_obligation_llm_response,
         {:assistant, "",
          [
            %{
              id: "native-question-missing-locale",
              name: "call",
              args: %{
                "tool" => type <> ".request",
                "params" => params,
                "reply_mode" => "final",
                "final_outcome" => "blocked"
              }
            }
          ]}}
      )

      {pid, messages, _} = await_request!()

      assert request_text(messages) =~ "missing required params: locale",
             inspect(Enum.take(messages, -4), limit: :infinity)

      refute_receive {:native_prompt, _, _, _, _, _}, 100
      current = read_session!(c.agent_id, c.session_id)
      refute Enum.any?(current.events, &(&1["kind"] == "terminal_reply_delivered"))

      send(
        pid,
        {:reply_obligation_llm_response,
         {:assistant, "",
          [
            %{
              id: "native-question",
              name: "call",
              args: %{
                "tool" => type <> ".request",
                "params" => Map.put(params, "locale", "zh-CN")
              }
            }
          ]}}
      )

      assert_receive {:native_prompt, sender, scope, ^type, %{"locale" => "zh-CN"},
                      "native-question"},
                     5_000

      assert scope["context_source_message_ids"] == ["native-A"]
      assert scope["reply_to_message_id"] == "501"
      deliver_telegram!(c.agent_id, "native-B", "B: independent message")
      send(sender, :delivered)
      {b_pid, b_messages, _} = await_request!()
      assert request_text(b_messages) =~ "B: independent message"
      current = read_session!(c.agent_id, c.session_id)
      assert current.wait == nil
      refute Enum.any?(current.async_tool_calls, fn {_, call} -> call["status"] == "running" end)
      assert Enum.any?(current.events, &(&1["kind"] == "terminal_reply_delivered"))
      send(b_pid, {:reply_obligation_llm_response, end_turn("native-B-end")})
      await_source_settled!(c.agent_id, c.session_id, "native-B")
      deliver_telegram!(c.agent_id, "native-C", "Answer to native-A: 杭州")
      {c_pid, c_messages, _} = await_request!()
      assert request_text(c_messages) =~ "Answer to native-A: 杭州"
      send(c_pid, {:reply_obligation_llm_response, end_turn("native-C-end")})
      await_source_settled!(c.agent_id, c.session_id, "native-C")
      refute_receive {:native_prompt, _, _, _, _, _}, 200
    end
  end

  test "a persisted Telegram wait releases on new input after actor restart", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    deliver_telegram!(agent_id, "tg-A", "A: inspect my environment")
    {a_pid, _, _} = await_request!()
    send(a_pid, {:reply_obligation_llm_response, telegram_post("tg-answer-a")})

    assert_receive {:telegram_call, ^agent_id,
                    %{"tool_context" => %{"source_message_id" => "tg-A"}}},
                   5000

    {wait_pid, _, _} = await_request!()
    send(wait_pid, {:reply_obligation_llm_response, wait_for("tg-wait", 1800)})
    waiting = await_waiting!(agent_id, session_id)
    refute ProviderReplyObligation.pending?(SalixAgent.InternalSession.open(waiting))

    [{actor, _}] =
      Registry.lookup(
        SalixAgent.Registry,
        SalixAgent.InternalSessionActor.key(agent_id, session_id)
      )

    GenServer.stop(actor, :normal)

    deliver_telegram!(agent_id, "tg-B", "B: remember BLUE_WHALE_42")
    {b_pid, messages, _} = await_request!()
    assert request_text(messages) =~ "B: remember BLUE_WHALE_42"
    current = read_session!(agent_id, session_id)
    assert current.last_ack_message_id >= waiting.next_message_id - 1
    assert current.wait == nil
    send(b_pid, {:reply_obligation_llm_response, telegram_post("tg-answer-b")})

    assert_receive {:telegram_call, ^agent_id,
                    %{
                      "params" => %{"chat_id" => "42"},
                      "tool_context" => %{
                        "source_message_id" => "tg-B",
                        "source_message_ids" => ["tg-B"]
                      }
                    }},
                   5000

    {end_pid, _, _} = await_request!()
    send(end_pid, {:reply_obligation_llm_response, end_turn("tg-end-b")})
    await_source_settled!(agent_id, session_id, "tg-B")
  end

  @tag :terminal_reply
  test "a final question survives restart without repeating and releases an independently queued input",
       %{
         agent_id: agent_id,
         session_id: session_id
       } do
    CaptureSlack.telegram_response(:controlled)
    deliver_telegram!(agent_id, "tg-question", "Ask me for the missing account", "502")
    {pid, _, _} = await_request!()

    send(
      pid,
      {:reply_obligation_llm_response,
       telegram_post("question-send", %{"reply_mode" => "final", "final_outcome" => "blocked"})}
    )

    assert_receive {:telegram_call, ^agent_id, args}, 5000
    assert args["params"]["reply_to_message_id"] == "502"
    refute Map.has_key?(args["params"], "reply_mode")
    refute Map.has_key?(args["params"], "final_outcome")
    assert_receive {:telegram_reply_pending, sender}, 5000
    # Queue a second source while A's final delivery is still in flight.
    deliver_telegram!(agent_id, "tg-next", "The next independent request")
    send(sender, {:complete_telegram_reply, {:ok, %{"ok" => true}}})
    {finish, _, _} = await_request!()

    send(
      finish,
      {:reply_obligation_llm_response,
       {:assistant, "",
        [
          %{
            id: "question-end",
            name: "end_turn",
            args: %{"outcome" => "blocked", "reason" => "The account is required"}
          }
        ]}}
    )

    {next, messages, _} = await_request!()
    assert request_text(messages) =~ "The next independent request"
    current = read_session!(agent_id, session_id)
    assert current.last_ack_message_id < find_source_message!(current, "tg-next").id
    refute Enum.any?(current.events, &(&1["kind"] == "terminal_reply_delivered"))
    send(next, {:reply_obligation_llm_response, end_turn("next-end")})
    await_source_settled!(agent_id, session_id, "tg-next")

    [{actor, _}] =
      Registry.lookup(
        SalixAgent.Registry,
        SalixAgent.InternalSessionActor.key(agent_id, session_id)
      )

    GenServer.stop(actor, :normal)
    SalixAgent.InternalSessionActor.wake(agent_id, session_id)
    refute_receive {:reply_obligation_llm_request, _, _, _}, 300
    refute_receive {:telegram_call, ^agent_id, _}, 100
  end

  @tag :terminal_reply
  test "a nested script send cannot replace the outer final envelope during repair",
       %{
         agent_id: agent_id,
         session_id: session_id
       } do
    CaptureSlack.telegram_response({:error, "telegram request rejected"})
    deliver_telegram!(agent_id, "tg-failed", "Please answer")
    {pid, _, _} = await_request!()
    final = %{"reply_mode" => "final", "final_outcome" => "done"}
    send(pid, {:reply_obligation_llm_response, telegram_post("failed-send", final)})
    assert_receive {:telegram_call, ^agent_id, _}, 5000
    {retry, _, _} = await_request!()
    assert read_session!(agent_id, session_id).last_ack_message_id == 0

    unrepaired =
      {:assistant, "",
       [
         %{
           id: "unrepaired-js",
           name: "call",
           # A program that fails before any send: the attempt through the
           # script tool cannot become the source-bound final reply.
           args: %{
             "tool" => "script.run",
             "params" => %{"source" => SalixAgent.SpinfoamFixture.exit_program(1)}
           }
         }
       ]}

    send(retry, {:reply_obligation_llm_response, unrepaired})
    {retry, _, _} = await_request!()
    refute_receive {:telegram_call, ^agent_id, _}, 50

    assert {:repair_required, _} =
             SalixAgent.VisibleReplyPolicy.phase(
               SalixAgent.InternalSession.open(read_session!(agent_id, session_id))
             )

    # A nested script cannot declare a source-bound outer final envelope.
    # A successful inspection completes ordinary diagnostic repair.
    send(
      retry,
      {:reply_obligation_llm_response,
       {:assistant, "",
        [
          %{
            id: "inspect-send",
            name: "call",
            args: %{"tool" => "help", "params" => %{"tool" => "im_api.telegram.send_message"}}
          }
        ]}}
    )

    {repaired, _, _} = await_request!()
    CaptureSlack.telegram_response({:ok, %{"ok" => true}})
    send(repaired, {:reply_obligation_llm_response, telegram_post("fixed-send", final)})
    assert_receive {:telegram_call, ^agent_id, _}, 5000
    {next, _, _} = await_request!()
    send(next, {:reply_obligation_llm_response, end_turn("repaired-explicit-finish")})
    await_source_settled!(agent_id, session_id, "tg-failed")
    refute_receive {:reply_obligation_llm_request, _, _, _}, 300
  end

  for recovery <- [:available, :unavailable, :crashed] do
    @tag :model_failure_reply
    test "model-stop notice preserves callback completion when the model is #{recovery}", %{
      agent_id: agent_id,
      session_id: session_id
    } do
      previous = Application.get_env(:salix_agent, :capability_request_store_mod)

      Application.put_env(
        :salix_agent,
        :capability_request_store_mod,
        SalixAgent.CapabilityRequests
      )

      on_exit(fn -> put_or_delete_env(:salix_agent, :capability_request_store_mod, previous) end)
      source = "tg-model-background"

      assert {:ok, _} =
               SalixAgent.CapabilityRequests.create_capability_request(%{
                 "source_agent_id" => agent_id,
                 "source_session_id" => session_id,
                 "tool_call_id" => "model-background",
                 "request_type" => "location",
                 "request_payload" => %{"location" => %{"reason" => "weather"}},
                 "expires_at" => System.system_time(:second) + 1000
               })

      assert {:ok, _} =
               InternalSessionStore.prepare_commit(agent_id, session_id, [
                 %{"type" => "session_created", "session_id" => session_id},
                 %{
                   "type" => "async_tool_call_started",
                   "tool_call_id" => "model-background",
                   "tool_name" => "location.request",
                   "completion_mode" => "external_callback",
                   "trusted_origin_source_message_ids" => [source],
                   "status" => "running"
                 }
               ])

      deliver_telegram!(agent_id, source, "Check weather while my location is pending")
      {model, _, _} = await_request!()

      send(
        model,
        {:reply_obligation_llm_response, LLM.Error.http("openai_responses", 402, "credits")}
      )

      assert_receive {:telegram_call, ^agent_id, args}, 5_000
      assert args["params"]["text"] =~ "does not cancel"
      refute_receive {:reply_obligation_llm_request, _, _, _}, 200
      notified = read_session!(agent_id, session_id)
      assert notified.last_ack_message_id == 0
      assert notified.async_tool_calls["model-background"]["status"] == "running"
      assert notified.runtime_failure_reply["notification_outcome"] == "delivered"

      refute "runtime_failure_reply" in SalixAgent.InternalSession.query(
               SalixAgent.InternalSession.open(notified),
               :work_reasons
             )

      assert {:ok, actor} = SalixAgent.InternalSessionFleet.ensure_started(agent_id, session_id)
      GenServer.stop(actor, :normal)
      assert {:ok, _} = SalixAgent.InternalSessionFleet.ensure_started(agent_id, session_id)
      refute_receive {:telegram_call, ^agent_id, _}, 100
      refute_receive {:reply_obligation_llm_request, _, _, _}, 100

      result = %{
        content: "location result after model recovery",
        status: "completed",
        error: false
      }

      assert {:ok, _} =
               SalixAgent.complete_async_tool_call(
                 agent_id,
                 session_id,
                 "model-background",
                 result
               )

      {continued, messages, _} = await_request!()
      assert request_text(messages) =~ "location result after model recovery"

      if unquote(recovery) == :available do
        send(
          continued,
          {:reply_obligation_llm_response,
           telegram_post("background-final", %{"reply_mode" => "final", "final_outcome" => "done"})}
        )

        assert_receive {:telegram_call, ^agent_id, final}, 5_000
        assert final["params"]["text"] == "answer"
        {finish, _, _} = await_request!()
        send(finish, {:reply_obligation_llm_response, end_turn("background-explicit-finish")})
      else
        if unquote(recovery) == :crashed,
          do: Process.exit(continued, :kill),
          else:
            send(
              continued,
              {:reply_obligation_llm_response,
               LLM.Error.http("openai_responses", 402, "still credits")}
            )
      end

      await_source_settled!(agent_id, session_id, source)
      refute_receive {:reply_obligation_llm_request, _, _, _}, 100
    end
  end

  for boundary <- [:reserved, :send_started] do
    @tag :model_failure_recovery
    test "interrupted model notice at #{boundary} does not retry or release its Task card", %{
      agent_id: agent_id,
      session_id: session_id
    } do
      deliver!(
        agent_id,
        @source_b,
        slack_input(@thread_b, "Create a Task"),
        obligation(@thread_b)
      )

      {model, _, _} = await_request!()
      send(model, {:reply_obligation_llm_response, task_create("interrupted-task")})
      assert_receive {:reply_obligation_task_create, ^agent_id, _, creator}, 5_000
      send(creator, :reply_obligation_complete_task_create)
      {_model, _, _} = await_request!()
      assert {:ok, actor} = SalixAgent.InternalSessionFleet.ensure_started(agent_id, session_id)
      GenServer.stop(actor, :normal)
      current = read_session!(agent_id, session_id)

      assert {:ok, failed} =
               InternalSessionStore.prepare_commit(agent_id, session_id, [
                 %{
                   "type" => "session_event",
                   "kind" => "llm_call_failed",
                   "event" => %{
                     "retryable" => false,
                     "transcript_hwm" => current.next_message_id - 1
                   }
                 },
                 %{"type" => "status", "status" => "idle"}
               ])

      {machine, [{:commit, events, _opts, _mode}, :continue]} =
        InternalSession.query(
          failed,
          :loop_step,
          {nil, {:guard_notice, %{"role" => "worker", "guard_config" => true, "nonce" => 1}}}
        )

      call = machine["notice"]

      events =
        if unquote(boundary) == :send_started,
          do:
            events ++
              [
                %{
                  "type" => "async_tool_call_started",
                  "tool_call_id" => call["id"],
                  "tool_name" => "im_api.slack.post_message",
                  "status" => "running",
                  "trusted_origin" => call["runtime_failure_reply"]["trusted_origin"],
                  "trusted_origin_source_message_ids" => [@source_b]
                }
              ],
          else: events

      assert {:ok, _} = InternalSessionStore.prepare_commit(agent_id, session_id, events)
      assert {:ok, _} = SalixAgent.InternalSessionFleet.ensure_started(agent_id, session_id)
      refute_receive {:reply_obligation_slack_call, ^agent_id, _}, 200
      refute_receive {:reply_obligation_llm_request, _, _, _}, 200
      restored = read_session!(agent_id, session_id)
      assert restored.last_ack_message_id == 0
      assert restored.runtime_failure_reply["notification_outcome"] == "unknown"

      assert Enum.any?(
               ProviderReplyObligation.pending(SalixAgent.InternalSession.open(restored)),
               &(&1["kind"] == "task_card")
             )

      refute "runtime_failure_reply" in SalixAgent.InternalSession.query(
               SalixAgent.InternalSession.open(restored),
               :work_reasons
             )

      for _ <- 1..3, do: SalixAgent.InternalSessionActor.wake(agent_id, session_id)
      refute_receive {:reply_obligation_llm_request, _, _, _}, 100
    end
  end

  @tag :model_failure_reply
  test "model-stop receipt retains a Task card and queued input grants bounded recovery", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    deliver!(agent_id, @source_b, slack_input(@thread_b, "Create a Task"), obligation(@thread_b))
    {model, _, _} = await_request!()
    send(model, {:reply_obligation_llm_response, task_create("failure-task")})
    assert_receive {:reply_obligation_task_create, ^agent_id, _, creator}, 5_000
    send(creator, :reply_obligation_complete_task_create)
    {model, _, _} = await_request!()

    send(
      model,
      {:reply_obligation_llm_response, LLM.Error.http("openai_responses", 402, "credits")}
    )

    assert_receive {:reply_obligation_slack_call, ^agent_id, args}, 5_000
    assert args["params"]["thread_ts"] == @thread_b
    refute_receive {:reply_obligation_llm_request, _, _, _}, 100
    notified = read_session!(agent_id, session_id)
    assert notified.last_ack_message_id == 0

    assert [%{"kind" => "task_card"}] =
             ProviderReplyObligation.pending(SalixAgent.InternalSession.open(notified))

    assert notified.runtime_failure_reply["notification_outcome"] == "delivered"
    assert {:ok, actor} = SalixAgent.InternalSessionFleet.ensure_started(agent_id, session_id)
    GenServer.stop(actor, :normal)
    assert {:ok, _} = SalixAgent.InternalSessionFleet.ensure_started(agent_id, session_id)
    refute_receive {:reply_obligation_llm_request, _, _, _}, 100

    deliver!(
      agent_id,
      @source_a1,
      slack_input(@thread_a, "NEXT independent input"),
      obligation(@thread_a)
    )

    {retry, messages, _} = await_request!()
    refute request_text(messages) =~ "NEXT independent input"

    send(
      retry,
      {:reply_obligation_llm_response, LLM.Error.http("openai_responses", 402, "still credits")}
    )

    refute_receive {:reply_obligation_llm_request, _, _, _}, 200
    refute_receive {:reply_obligation_slack_call, ^agent_id, _}, 100
    for _ <- 1..3, do: SalixAgent.InternalSessionActor.wake(agent_id, session_id)
    refute_receive {:reply_obligation_llm_request, _, _, _}, 100

    deliver!(
      agent_id,
      @source_a2,
      slack_input(@thread_a, "SECOND independent input"),
      obligation(@thread_a)
    )

    {recovered, _, _} = await_request!()
    send(recovered, {:reply_obligation_llm_response, card_post("recovered-card")})
    assert_receive {:reply_obligation_card_post, ^agent_id, _}, 5_000
    {finish, _, _} = await_request!()
    send(finish, {:reply_obligation_llm_response, end_turn("finish-original")})
    {next, messages, _} = await_request!()
    assert request_text(messages) =~ "NEXT independent input"
    refute request_text(messages) =~ "SECOND independent input"
    send(next, {:reply_obligation_llm_response, end_turn("finish-next")})
    {last, messages, _} = await_request!()
    assert request_text(messages) =~ "SECOND independent input"
    send(last, {:reply_obligation_llm_response, end_turn("finish-last")})
    await_source_settled!(agent_id, session_id, @source_a2)
  end

  @tag :model_failure_reply
  test "transient model failures retain the source through retry exhaustion", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    previous = Application.get_env(:salix_agent, :llm_activation_retry_base_ms)
    Application.put_env(:salix_agent, :llm_activation_retry_base_ms, 10)
    on_exit(fn -> put_or_delete_env(:salix_agent, :llm_activation_retry_base_ms, previous) end)
    deliver_telegram!(agent_id, "tg-exhausted-model", "Please answer after retry")

    for attempt <- 1..18 do
      {model, _, _} = await_request!()
      if attempt == 7, do: assert(read_session!(agent_id, session_id).last_ack_message_id == 0)

      send(
        model,
        {:reply_obligation_llm_response,
         LLM.Error.http("openai_responses", 503, "private outage")}
      )
    end

    assert_receive {:telegram_call, ^agent_id, args}, 5_000
    assert args["tool_context"]["source_message_id"] == "tg-exhausted-model"
    refute args["params"]["text"] =~ "private outage"
    await_source_settled!(agent_id, session_id, "tg-exhausted-model")
    refute_receive {:reply_obligation_llm_request, _, _, _}, 200
    refute_receive {:telegram_call, ^agent_id, _}, 100
  end

  @tag :model_failure_reply
  test "a permanent model error sends one safe failure reply and releases the next request",
       %{agent_id: agent_id, session_id: session_id} do
    rounds = attach_round_operations()
    CaptureSlack.telegram_response(:controlled)
    deliver_telegram!(agent_id, "tg-model-failure", "Please answer my request")
    {model, _, _} = await_request!()

    send(
      model,
      {:reply_obligation_llm_response,
       LLM.Error.http(
         "openai_responses",
         402,
         ~s({"error":{"message":"Insufficient credits for private-key-identifier"}})
       )}
    )

    assert_receive {:telegram_call, ^agent_id, args}, 5_000
    assert args["params"]["chat_id"] == "42"
    assert args["tool_context"]["source_message_id"] == "tg-model-failure"
    assert args["params"]["text"] =~ "model"
    refute args["params"]["text"] =~ "private-key-identifier"
    assert_receive {:telegram_reply_pending, sender}, 5_000
    refute_receive {:reply_obligation_llm_request, _, _, _}, 100

    deliver_telegram!(agent_id, "tg-model-next", "A new request after model recovery")
    send(sender, {:complete_telegram_reply, {:ok, %{"ok" => true}}})
    {next, messages, _} = await_request!()
    assert request_text(messages) =~ "A new request after model recovery"
    current = read_session!(agent_id, session_id)
    assert current.last_ack_message_id < find_source_message!(current, "tg-model-next").id

    assert Enum.any?(
             current.events,
             &(&1["kind"] == "runtime_failure_reply_settled" and
                 &1["event"]["source_message_id"] == "tg-model-failure" and
                 &1["event"]["outcome"] == "blocked")
           )

    send(next, {:reply_obligation_llm_response, end_turn("model-next-end")})
    await_source_settled!(agent_id, session_id, "tg-model-next")
    refute_receive {:telegram_call, ^agent_id, _}, 100

    # The failed model round, the guard round that sent the notice, and the
    # next request's round each report one round operation.
    assert [_, _, _] = collect_round_operations(rounds)
  end

  defp attach_round_operations do
    handler_id = {__MODULE__, :round_operations, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:salix, :operation, :stop],
      fn _event, _measurements, meta, _config ->
        if meta.operation == "round", do: send(test_pid, {handler_id, meta.outcome})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp collect_round_operations(handler_id, acc \\ []) do
    receive do
      {^handler_id, outcome} -> collect_round_operations(handler_id, [outcome | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  @tag :model_failure_reply
  test "cold recovery sends the pending model failure without another model call or duplicate reply",
       %{agent_id: agent_id, session_id: session_id} do
    source = "tg-cold-model-failure"

    origin = %{
      "provider" => "telegram",
      "source_actor_type" => "provider_user",
      "source_message_id" => source,
      "provider_context" => %{
        "connect_id" => "telegram-1",
        "chat_id" => "42",
        "message_id" => source
      }
    }

    {:error, failure} = LLM.Error.http("openai_responses", 402, "Insufficient credits")

    # The durable boundary after the provider failure, before reserving a send.
    assert {:ok, pending} =
             InternalSessionStore.prepare_commit(agent_id, session_id, [
               %{"type" => "session_created", "session_id" => session_id},
               %{
                 "type" => "delivery",
                 "from_queue" => true,
                 "message_id" => 1,
                 "role" => "user",
                 "content" => "Please answer",
                 "source_message_id" => source,
                 "trusted_origin" => origin
               },
               %{
                 "type" => "session_event",
                 "kind" => "llm_call_failed",
                 "event" => Map.put(failure, "transcript_hwm", 1),
                 "source" => "internal_runtime"
               },
               %{"type" => "status", "status" => "idle"}
             ])

    assert "runtime_failure_reply" in SalixAgent.InternalSession.query(pending, :work_reasons)

    assert {:ok, actor} = SalixAgent.InternalSessionFleet.ensure_started(agent_id, session_id)
    assert_receive {:telegram_call, ^agent_id, args}, 5_000
    assert args["tool_context"]["source_message_id"] == source
    await_source_settled!(agent_id, session_id, source)
    refute_receive {:reply_obligation_llm_request, _, _, _}, 100

    GenServer.stop(actor, :normal)
    assert {:ok, _} = SalixAgent.InternalSessionFleet.ensure_started(agent_id, session_id)
    refute_receive {:telegram_call, ^agent_id, _}, 200
    refute_receive {:reply_obligation_llm_request, _, _, _}, 100
  end

  for notification <- [:success, :failure] do
    @notification notification
    @tag :guard_failure
    test "the repeated-result guard attempts one failure reply and releases the next request: #{@notification}",
         %{agent_id: agent_id, session_id: session_id} do
      CaptureSlack.telegram_response(:controlled)
      deliver_telegram!(agent_id, "tg-guard", "Please answer my request")

      for n <- 1..5 do
        {pid, _, _} = await_request!()

        send(
          pid,
          {:reply_obligation_llm_response,
           {:assistant, "",
            [
              %{
                id: "same-inspection-#{n}",
                name: "call",
                args: %{"tool" => "help", "params" => %{"tool" => "im_api.telegram.send_message"}}
              }
            ]}}
        )
      end

      assert_receive {:telegram_call, ^agent_id, args}, 5000
      assert args["params"]["chat_id"] == "42"
      assert args["tool_context"]["source_message_id"] == "tg-guard"
      assert args["params"]["text"] =~ "couldn't complete"
      assert_receive {:telegram_reply_pending, sender}, 5000
      deliver_telegram!(agent_id, "tg-after-guard", "A new independent request")

      response =
        if @notification == :success,
          do: {:ok, %{"ok" => true}},
          else: {:error, "provider unavailable"}

      send(sender, {:complete_telegram_reply, response})
      {next, messages, _} = await_request!()
      assert request_text(messages) =~ "A new independent request"
      refute_receive {:telegram_call, ^agent_id, _}, 100
      current = read_session!(agent_id, session_id)

      if @notification == :success do
        assert Enum.any?(
                 current.events,
                 &(&1["kind"] == "terminal_reply_delivered" and
                     &1["event"]["source_message_id"] == "tg-guard" and
                     &1["event"]["outcome"] == "blocked")
               )
      else
        assert Enum.any?(
                 current.events,
                 &(&1["kind"] == "runtime_failure_reply_settled" and
                     &1["event"]["source_message_id"] == "tg-guard" and
                     &1["event"]["notification_outcome"] == "unknown")
               )

        refute Enum.any?(current.events, &(&1["kind"] == "terminal_reply_delivered"))
      end

      assert current.last_ack_message_id < find_source_message!(current, "tg-after-guard").id
      send(next, {:reply_obligation_llm_response, end_turn("next-guard-end")})
      await_source_settled!(agent_id, session_id, "tg-after-guard")
      refute_receive {:telegram_call, ^agent_id, _}, 100
    end
  end

  @tag :guard_failure
  test "Comma guard failure appends one canonical failure and processes queued input", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})
    previous_delivery = Application.get_env(:salix_im, :agent_delivery_mod)
    Application.put_env(:salix_im, :agent_delivery_mod, Salix.Bindings.IMAgentDelivery)
    Application.put_env(:salix_agent, :im_provider_mod, SalixIM.Provider)

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      put_or_delete_env(:salix_im, :agent_delivery_mod, previous_delivery)
    end)

    assert {:ok, input} =
             SalixIM.RouterConversationInput.append_user_message(
               group_id,
               %{"content" => "first request", "client_request_id" => "guard-comma"}
             )

    {first, _, _} = await_request!()

    assert {:ok, following} =
             SalixIM.RouterConversationInput.append_user_message(
               group_id,
               %{
                 "content" => "next independent request",
                 "client_request_id" => "after-guard-comma"
               }
             )

    # Disclosure may change the first help result. Drive a bounded sequence
    # until the guard releases the queued source instead of counting five calls.
    {next, messages, _} =
      Enum.reduce_while(1..8, {first, [], []}, fn n, {pid, _, _} ->
        send(
          pid,
          {:reply_obligation_llm_response,
           {:assistant, "",
            [
              %{
                id: "repeat-envelope-#{n}",
                name: "call",
                args: %{"tool" => "help", "params" => %{"tool" => "im_api.internal.send_message"}}
              }
            ]}}
        )

        request = {_, messages, _} = await_request!()

        if request_text(messages) =~ "next independent request",
          do: {:halt, request},
          else: {:cont, request}
      end)

    assert request_text(messages) =~ "next independent request"

    assert {:ok, replies} =
             SalixIM.Conversations.list_group_conversation_messages(
               group_id,
               input["conversation_id"],
               after_id: following["message_id"]
             )

    assert [failure] = replies
    assert [%{"type" => "text", "text" => text}] = failure["content"]
    assert text =~ "couldn't complete"
    current = read_session!(agent_id, session_id)

    assert Enum.any?(
             current.events,
             &(&1["kind"] == "terminal_reply_delivered" and &1["event"]["outcome"] == "blocked")
           )

    send(next, {:reply_obligation_llm_response, end_turn("next-comma-guard-end")})
    await_settled!(agent_id, session_id)
    refute_receive {:reply_obligation_llm_request, _, _, _}, 300
  end

  @tag :expired_callback
  test "deadline recovery releases an internal location wait and the next queued Telegram request",
       %{
         agent_id: agent_id,
         session_id: session_id
       } do
    previous = Application.get_env(:salix_agent, :capability_request_store_mod)

    Application.put_env(
      :salix_agent,
      :capability_request_store_mod,
      SalixAgent.CapabilityRequests
    )

    on_exit(fn -> put_or_delete_env(:salix_agent, :capability_request_store_mod, previous) end)

    request = %{
      "source_agent_id" => agent_id,
      "source_session_id" => session_id,
      "tool_call_id" => "old-location",
      "request_type" => "location",
      "request_payload" => %{"location" => %{"reason" => "weather"}},
      "expires_at" => System.system_time(:second) + 10
    }

    assert {:ok, persisted_request} =
             SalixAgent.CapabilityRequests.create_capability_request(request)

    origin = %{
      "provider" => "internal",
      "source_actor_type" => "user",
      "source_message_id" => "old-comma-source"
    }

    assert {:ok, _} =
             InternalSessionStore.prepare_commit(agent_id, session_id, [
               %{"type" => "session_created", "session_id" => session_id},
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => session_id,
                 "tool_call_id" => "old-location",
                 "tool_name" => "location.request",
                 "status" => "running",
                 "completion_mode" => "external_callback",
                 "capability_request_id" => persisted_request["request_id"],
                 "capability_deadline_ms" => persisted_request["expires_at"] * 1_000,
                 "input" => "{}",
                 "trusted_origin" => origin,
                 "trusted_origins" => [origin],
                 "trusted_origin_source_message_ids" => ["old-comma-source"],
                 "started_at" => 1
               }
             ])

    deliver_telegram!(agent_id, "tg-parked", "First Telegram request")
    final = %{"reply_mode" => "final", "final_outcome" => "done"}

    {waiting, _, _} = await_request!()
    send(waiting, {:reply_obligation_llm_response, wait_for("wait-for-location", 1800)})
    await_waiting!(agent_id, session_id)

    refute_receive {:reply_obligation_llm_request, _, _, _}, 200
    refute_receive {:telegram_call, ^agent_id, _}, 50

    # Exercise the same durable sweep used by the production recovery tick.
    # No actor wake, new input, or model wait deadline triggers the expiry.
    Process.sleep(
      max(0, persisted_request["expires_at"] * 1_000 - System.system_time(:millisecond))
    )

    assert %{failed: 0} = SalixAgent.SessionWorkRecovery.sweep(session_work_max_keys: 100)
    {resumed, messages, _} = await_request!()
    assert request_text(messages) =~ "First Telegram request"
    refute request_text(messages) =~ "Second Telegram request"

    assert Enum.any?(
             messages,
             &(&1[:type] == "tool_call_failed" and
                 &1[:source_tool_call_id] == "old-location")
           )

    # New input may preempt a generic wait. Queue this request during the
    # recovered round instead, so deadline recovery is the only wake trigger.
    deliver_telegram!(agent_id, "tg-queued", "Second Telegram request")
    queued = read_session!(agent_id, session_id)
    refute Enum.any?(queued.messages, &(&1[:source_message_id] == "tg-queued"))
    send(resumed, {:reply_obligation_llm_response, telegram_post("resumed-final", final)})
    assert_receive {:telegram_call, ^agent_id, _}, 5000
    {finish, _, _} = await_request!()
    send(finish, {:reply_obligation_llm_response, end_turn("resumed-explicit-finish")})

    {next, messages, _} = await_request!()
    assert request_text(messages) =~ "Second Telegram request"
    send(next, {:reply_obligation_llm_response, telegram_post("queued-final", final)})
    assert_receive {:telegram_call, ^agent_id, _}, 5000
    {finish, _, _} = await_request!()
    send(finish, {:reply_obligation_llm_response, end_turn("queued-explicit-finish")})
    settled = await_source_settled!(agent_id, session_id, "tg-queued")
    refute Enum.any?(settled.events, &(&1["kind"] == "terminal_reply_delivered"))
    refute_receive {:telegram_call, ^agent_id, _}, 100
  end

  test "guard release preserves a location callback until deadline and delivers only the next Telegram reply",
       %{
         agent_id: agent_id,
         session_id: session_id
       } do
    ScriptLLM.set_owner(self(), 15_000)
    # Keep this fixture on repeated-tool refusal, not the independent two-round runaway path.
    previous_cap = Application.get_env(:salix_agent, :runaway_unsettled_round_cap)
    Application.put_env(:salix_agent, :runaway_unsettled_round_cap, 8)
    on_exit(fn -> put_or_delete_env(:salix_agent, :runaway_unsettled_round_cap, previous_cap) end)

    previous = Application.get_env(:salix_agent, :capability_request_store_mod)

    Application.put_env(
      :salix_agent,
      :capability_request_store_mod,
      SalixAgent.CapabilityRequests
    )

    on_exit(fn -> put_or_delete_env(:salix_agent, :capability_request_store_mod, previous) end)

    request = %{
      "source_agent_id" => agent_id,
      "source_session_id" => session_id,
      "tool_call_id" => "old-location",
      "request_type" => "location",
      "request_payload" => %{"location" => %{"reason" => "weather"}},
      "expires_at" => System.system_time(:second) + 10
    }

    assert {:ok, persisted_request} =
             SalixAgent.CapabilityRequests.create_capability_request(request)

    origin = %{
      "provider" => "internal",
      "source_actor_type" => "user",
      "source_message_id" => "old-comma-source"
    }

    assert {:ok, _} =
             InternalSessionStore.prepare_commit(agent_id, session_id, [
               %{"type" => "session_created", "session_id" => session_id},
               %{
                 "type" => "async_tool_call_started",
                 "session_id" => session_id,
                 "tool_call_id" => "old-location",
                 "tool_name" => "location.request",
                 "status" => "running",
                 "completion_mode" => "external_callback",
                 "capability_request_id" => persisted_request["request_id"],
                 "capability_deadline_ms" => persisted_request["expires_at"] * 1_000,
                 "input" => "{}",
                 "trusted_origin" => origin,
                 "trusted_origins" => [origin],
                 "trusted_origin_source_message_ids" => ["old-comma-source"],
                 "started_at" => 1
               }
             ])

    deliver_telegram!(agent_id, "tg-parked", "First Telegram request")
    final = %{"reply_mode" => "final", "final_outcome" => "done"}

    for n <- 1..5 do
      {pid, _, _} = await_request!()
      send(pid, {:reply_obligation_llm_response, idle_call("location-blocked-#{n}")})
    end

    stopped = await_source_settled!(agent_id, session_id, "tg-parked")
    assert stopped.async_tool_calls["old-location"]["status"] == "running"

    assert stopped.async_tool_calls["old-location"]["capability_request_id"] ==
             persisted_request["request_id"]

    assert stopped.async_tool_calls["old-location"]["capability_deadline_ms"] ==
             persisted_request["expires_at"] * 1_000

    assert stopped.async_tool_calls["old-location"]["trusted_origin_source_message_ids"] ==
             ["old-comma-source"]

    assert Enum.any?(stopped.events, fn event ->
             event["kind"] == "runtime_failure_disposed" and
               event["event"]["context_source_message_ids"] == ["tg-parked"] and
               event["event"]["notification_reason"] ==
                 "foreign_work_prevents_safe_notification"
           end)

    refute_receive {:telegram_call, ^agent_id, _}, 50

    # The failed source releases its activation while the callback stays owned
    # by the capability lifecycle. Start the next request before expiry, then
    # hold only this model response across the 10s deadline. This fixture gives
    # the scripted response 15s, so it does not need a narrow pre-expiry window.

    deliver_telegram!(agent_id, "tg-queued", "Second Telegram request")
    {next, messages, _} = await_request!()
    assert request_text(messages) =~ "Second Telegram request"
    assert System.system_time(:millisecond) < persisted_request["expires_at"] * 1_000
    refute_receive {:telegram_call, ^agent_id, _}, 50

    Process.sleep(
      max(0, persisted_request["expires_at"] * 1_000 - System.system_time(:millisecond))
    )

    assert %{failed: 0} = SalixAgent.SessionWorkRecovery.sweep(session_work_max_keys: 100)
    # Recovery schedules work but cannot interrupt the pending model request.
    # The location timer delivers its callback independently of that request.
    assert {:ok, _} = SalixCluster.Timers.fire_due()
    send(next, {:reply_obligation_llm_response, idle_call("queued-read")})
    {again, messages, _} = await_request!()

    # The accepted callback's failure reaches the model before final delivery.
    # Its old Comma source supplies provenance, never the Telegram reply target.
    assert Enum.any?(
             messages,
             &(&1[:type] == "tool_call_failed" and
                 &1[:source_tool_call_id] == "old-location")
           )

    send(again, {:reply_obligation_llm_response, telegram_post("queued-retry-final", final)})

    assert_receive {:telegram_call, ^agent_id,
                    %{"tool_context" => %{"source_message_id" => "tg-queued"}}},
                   5000

    {finish, _, _} = await_request!()
    send(finish, {:reply_obligation_llm_response, end_turn("queued-retry-explicit-finish")})
    settled = await_source_settled!(agent_id, session_id, "tg-queued")

    assert {:ok, %{"status" => "expired"}} =
             SalixAgent.CapabilityRequests.get(
               persisted_request["group_id"],
               persisted_request["request_id"],
               persisted_request["tenant_id"]
             )

    refute Enum.any?(settled.events, &(&1["kind"] == "terminal_reply_delivered"))
    refute_receive {:telegram_call, ^agent_id, _}, 100
  end

  @tag :terminal_reply
  test "Comma generic wait yields to a Telegram request that can send a final reply", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})
    previous_delivery = Application.get_env(:salix_im, :agent_delivery_mod)
    Application.put_env(:salix_im, :agent_delivery_mod, Salix.Bindings.IMAgentDelivery)

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()

      if is_nil(previous_delivery),
        do: Application.delete_env(:salix_im, :agent_delivery_mod),
        else: Application.put_env(:salix_im, :agent_delivery_mod, previous_delivery)
    end)

    assert {:ok, comma_message} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" => "Comma A: waiting for the user",
               "client_request_id" => "comma-before-tg"
             })

    {comma_pid, _, _} = await_request!()

    comma_input =
      Enum.find(read_session!(agent_id, session_id).messages, fn message ->
        get_in(message, [:trusted_origin, "message_id"]) == comma_message["message_id"]
      end)

    assert comma_input.trusted_origin["provider"] == "internal"
    assert comma_input.trusted_origin["source_actor_type"] == "user"
    assert comma_input.trusted_origin["conversation_id"] == comma_message["conversation_id"]
    assert SalixAgent.InternalSession.human_source_origin?(comma_input.trusted_origin)
    deliver_telegram!(agent_id, "tg-after-comma", "Telegram B: answer this request")
    send(comma_pid, {:reply_obligation_llm_response, wait_for("comma-wait", 1800)})

    {telegram_pid, messages, _} = await_request!()
    assert request_text(messages) =~ "Telegram B: answer this request"
    session = read_session!(agent_id, session_id)

    assert SalixAgent.VisibleReplyScope.current_source_message_ids(
             SalixAgent.InternalSession.open(session)
           ) == ["tg-after-comma"]

    assert find_source_message!(session, comma_input.source_message_id)
    refute_receive {:telegram_call, ^agent_id, _}, 50

    send(
      telegram_pid,
      {:reply_obligation_llm_response,
       telegram_post("tg-after-comma-final", %{"reply_mode" => "final", "final_outcome" => "done"})}
    )

    assert_receive {:telegram_call, ^agent_id, _}, 5000
    {finish, _, _} = await_request!()
    send(finish, {:reply_obligation_llm_response, end_turn("explicit-finish")})
    await_source_settled!(agent_id, session_id, "tg-after-comma")
    refute_receive {:reply_obligation_llm_request, _, _, _}, 300
  end

  @tag :comma_reply_delivery
  test "Comma answer is explicitly delivered after query and session-only prose", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})
    previous_delivery = Application.get_env(:salix_im, :agent_delivery_mod)
    Application.put_env(:salix_im, :agent_delivery_mod, Salix.Bindings.IMAgentDelivery)
    Application.put_env(:salix_agent, :im_provider_mod, SalixIM.Provider)

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      put_or_delete_env(:salix_im, :agent_delivery_mod, previous_delivery)
    end)

    question = "读取当前对话，解释 codex://threads/example 是什么链接。"
    answer = "这是 Codex 桌面应用用于打开指定会话的链接。"

    assert {:ok, comma_message} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" => question,
               "client_request_id" => "comma-query-answer"
             })

    conversation_id = comma_message["conversation_id"]
    {query_pid, _, _} = await_request!()

    send(query_pid, {
      :reply_obligation_llm_response,
      {:assistant, "",
       [
         %{
           id: "read-comma-source",
           name: "call",
           args: %{
             "tool" => "im_api.internal.read_conversation",
             "params" => %{
               "connect_id" => "internal",
               "conversation_id" => conversation_id,
               "query" => "当前用户询问的链接"
             }
           }
         }
       ]}
    })

    {answer_pid, query_messages, _} = await_request!()
    assert request_text(query_messages) =~ "codex://threads/example"

    assert Enum.any?(read_session!(agent_id, session_id).messages, fn message ->
             message[:source_tool_call_id] == "read-comma-source" and
               get_in(message, [:source_refs, "status"]) == "completed"
           end)

    send(answer_pid, {:reply_obligation_llm_response, {:assistant, answer, []}})
    {send_pid, messages, _} = await_request!()

    # Reproduce the incident boundary: generation has not authored any Message.
    assert {:ok, []} =
             SalixIM.Conversations.list_group_conversation_messages(group_id, conversation_id,
               after_id: comma_message["message_id"]
             )

    assert request_text(messages) =~ conversation_id

    send(send_pid, {
      :reply_obligation_llm_response,
      {:assistant, "",
       [
         %{
           id: "send-comma-answer",
           name: "call",
           args: %{
             "tool" => "im_api.internal.send_message",
             "params" => %{
               "connect_id" => "internal",
               "conversation_id" => conversation_id,
               "content" => [%{"type" => "text", "text" => answer}]
             }
           }
         }
       ]}
    })

    {end_pid, _, _} = await_request!()

    assert {:ok, [delivered]} =
             SalixIM.Conversations.list_group_conversation_messages(group_id, conversation_id,
               after_id: comma_message["message_id"]
             )

    assert delivered["actor_type"] == "agent"
    assert delivered["content"] == [%{"type" => "text", "text" => answer}]
    send(end_pid, {:reply_obligation_llm_response, end_turn("comma-answer-done")})
    await_settled!(agent_id, session_id)
    refute_receive {:reply_obligation_llm_request, _, _, _}, 300

    assert {:ok, [^delivered]} =
             SalixIM.Conversations.list_group_conversation_messages(group_id, conversation_id,
               after_id: comma_message["message_id"]
             )
  end

  @tag :terminal_reply
  test "repeated unsettled Telegram rounds retire without requiring a blocked reply", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    previous_cap = Application.get_env(:salix_agent, :runaway_unsettled_round_cap)
    Application.put_env(:salix_agent, :runaway_unsettled_round_cap, 3)
    on_exit(fn -> put_or_delete_env(:salix_agent, :runaway_unsettled_round_cap, previous_cap) end)

    deliver_telegram!(agent_id, "tg-refused", "Preserve this request")

    for n <- 1..3 do
      {pid, _, _} = await_request!()
      send(pid, {:reply_obligation_llm_response, {:assistant, "Still thinking #{n}.", []}})
    end

    settled = await_source_settled!(agent_id, session_id, "tg-refused")

    assert Enum.any?(
             settled.events,
             &(&1["kind"] == "runtime_runaway_retired" and
                 &1["event"]["outcome"] == "blocked")
           )

    await_settled!(agent_id, session_id)
    refute_receive {:telegram_call, ^agent_id, _}, 100
  end

  for {kind, no_wake, actor_type} <- [
        {"meeting context", true, "provider_system"},
        {"Worker report", false, "agent"}
      ] do
    @tag :reply_path_repro
    test "Telegram can send its final after #{kind} is materialized", %{
      agent_id: agent_id,
      session_id: session_id
    } do
      source = "tg-with-context"
      context_source = "context-for-tg"
      deliver_telegram!(agent_id, source, "Answer this Telegram request")
      {first_pid, _, _} = await_request!()

      assert {:ok, :created} =
               SalixAgent.deliver(
                 agent_id,
                 %{
                   content: unquote(kind),
                   role: "user",
                   trusted_origin: %{
                     "provider" => "internal",
                     "source_actor_type" => unquote(actor_type)
                   }
                 },
                 source_message_id: context_source,
                 no_wake: unquote(no_wake)
               )

      if unquote(no_wake) do
        send(
          first_pid,
          {:reply_obligation_llm_response,
           {:assistant, "",
            [
              %{
                id: "inspect-send",
                name: "call",
                args: %{"tool" => "help", "params" => %{"tool" => "im_api.telegram.send_message"}}
              }
            ]}}
        )
      else
        # A Worker report wakes the model itself. Starting help here can leave
        # unrelated work running when the scripted model sends its final reply.
        send(first_pid, {:reply_obligation_llm_response, wait_for("admit-worker-report")})
      end

      {reply_pid, messages, _} = await_request!()
      assert request_text(messages) =~ unquote(kind)

      assert SalixAgent.VisibleReplyScope.current_source_message_ids(
               SalixAgent.InternalSession.open(read_session!(agent_id, session_id))
             ) == [source, context_source]

      send(
        reply_pid,
        {:reply_obligation_llm_response,
         telegram_post("answer-with-context", %{
           "reply_mode" => "final",
           "final_outcome" => "done"
         })}
      )

      assert_receive {:telegram_call, ^agent_id,
                      %{"params" => %{"chat_id" => "42", "text" => "answer"}}},
                     1000

      {finish, _, _} = await_request!()
      send(finish, {:reply_obligation_llm_response, end_turn("context-explicit-finish")})
      await_source_settled!(agent_id, session_id, source)
    end
  end

  @tag :terminal_reply
  test "a restored mixed Comma and Telegram transcript retires with both sources audited", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    previous_cap = Application.get_env(:salix_agent, :runaway_unsettled_round_cap)
    Application.put_env(:salix_agent, :runaway_unsettled_round_cap, 3)
    on_exit(fn -> put_or_delete_env(:salix_agent, :runaway_unsettled_round_cap, previous_cap) end)

    # Fixture of a transcript admitted by the old binary, not a new queue path.
    inputs =
      Enum.map(1..3, fn id ->
        source = "legacy-source-#{id}"

        origin =
          if id < 3 do
            %{"provider" => "internal", "source_actor_type" => "user"}
          else
            %{
              "provider" => "telegram",
              "source_actor_type" => "provider_user",
              "source_message_id" => source,
              "provider_context" => %{"connect_id" => "telegram-1", "chat_id" => "42"}
            }
          end

        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => id,
          "source_message_id" => source,
          "role" => "user",
          "content" => source,
          "trusted_origin" => origin
        }
      end)

    assert {:ok, _} =
             InternalSessionStore.prepare_commit(agent_id, session_id, [
               %{"type" => "session_created", "session_id" => session_id} | inputs
             ])

    {:ok, owner} = SalixAgent.Placement.ensure_started(agent_id, create: true)
    SalixAgent.Server.wake(owner)

    for n <- 1..3 do
      {pid, _, _} = await_request!()

      send(pid, {:reply_obligation_llm_response, {:assistant, "Still thinking #{n}.", []}})
    end

    retired = await_settled!(agent_id, session_id)
    refute_receive {:telegram_call, ^agent_id, _}, 300
    refute_receive {:reply_obligation_llm_request, _, _, _}, 300
    assert SessionData.query(retired, :consecutive_unsettled_rounds) == 0
    assert retired.status == :idle
    assert SessionData.query(retired, :work_reasons) == []
    assert retired.last_ack_message_id == retired.next_message_id - 1

    fact = Enum.find(retired.events, &(&1["kind"] == "runtime_runaway_retired"))
    assert fact["event"]["outcome"] == "blocked"
    assert fact["event"]["source_message_ids"] == Enum.map(1..3, &"legacy-source-#{&1}")
    assert fact["event"]["consecutive_unsettled_rounds"] == 3
  end

  for completion <- [:sync, :async] do
    @tag :terminal_reply
    test "#{completion} failed final can be repaired by an explicit final send", %{
      agent_id: agent_id,
      session_id: session_id
    } do
      completion = unquote(completion)
      failure = {:error, %Req.TransportError{reason: :closed}}

      CaptureSlack.telegram_response(
        if(unquote(completion == :async), do: :controlled, else: failure)
      )

      source = "tg-repair-#{completion}"

      deliver_telegram!(
        agent_id,
        source,
        ~s({"interaction":"question","response":{"answer":"蓝色"}})
      )

      {pid, _, _} = await_request!()
      final = %{"reply_mode" => "final", "final_outcome" => "done"}
      send(pid, {:reply_obligation_llm_response, telegram_post("failed-final", final)})
      assert_receive {:telegram_call, ^agent_id, _}, 5000

      if unquote(completion == :async) do
        assert_receive {:telegram_reply_pending, sender}, 5000

        assert Enum.any?(1..500, fn _ ->
                 running =
                   get_in(read_session!(agent_id, session_id).async_tool_calls, [
                     "failed-final",
                     "status"
                   ]) == "running"

                 unless running, do: Process.sleep(10)
                 running
               end)

        send(sender, {:complete_telegram_reply, failure})
      end

      {repair, messages, _} = await_request!()
      assert request_text(messages) =~ "private tool diagnostic"
      current = read_session!(agent_id, session_id)

      assert SalixAgent.VisibleReplyPolicy.repair_required?(
               SalixAgent.VisibleReplyPolicy.phase(SalixAgent.InternalSession.open(current))
             )

      refute Enum.any?(current.events, &(&1["kind"] == "terminal_reply_delivered"))
      assert current.last_ack_message_id == 0
      refute_receive {:telegram_call, ^agent_id, _}, 50

      CaptureSlack.telegram_response({:ok, %{"message_id" => 42}})
      send(repair, {:reply_obligation_llm_response, telegram_post("repair-final", final)})
      assert_receive {:telegram_call, ^agent_id, args}, 5000
      assert args["params"]["text"] == "answer"
      {finish, _, _} = await_request!()
      send(finish, {:reply_obligation_llm_response, end_turn("repair-explicit-finish")})
      await_source_settled!(agent_id, session_id, source)
      settled = read_session!(agent_id, session_id)

      assert SalixAgent.VisibleReplyPolicy.phase(SalixAgent.InternalSession.open(settled)) ==
               :clean

      refute Enum.any?(settled.events, &(&1["kind"] == "terminal_reply_delivered"))

      refute_receive {:telegram_call, ^agent_id, _}, 100
      refute_receive {:reply_obligation_llm_request, _, _, _}, 300
    end
  end

  for {label, intent} <- [
        {"undeclared", %{}},
        {"final-labelled", %{"reply_mode" => "final", "final_outcome" => "done"}}
      ] do
    @tag :terminal_reply
    test "#{label} Telegram source sends deliver without guidance and still require end_turn",
         %{agent_id: agent_id, session_id: session_id} do
      source = "tg-#{unquote(label)}"
      deliver_telegram!(agent_id, source, "Answer once")
      {pid, _, _} = await_request!()

      send(
        pid,
        {:reply_obligation_llm_response, telegram_post("send", unquote(Macro.escape(intent)))}
      )

      assert_receive {:telegram_call, ^agent_id, _}, 5000

      {finish, messages, _} = await_request!()
      refute request_text(messages) =~ "Source Telegram replies require"
      refute request_text(messages) =~ "Final reply"
      assert read_session!(agent_id, session_id).last_ack_message_id == 0
      send(finish, {:reply_obligation_llm_response, end_turn("explicit-finish")})
      await_source_settled!(agent_id, session_id, source)
      refute_receive {:telegram_call, ^agent_id, _}, 50
      refute_receive {:reply_obligation_llm_request, _, _, _}, 300
    end
  end

  @tag :comma_reply_delivery
  test "a Router delivers a Worker result to the original Comma user despite final metadata", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})
    previous_delivery = Application.get_env(:salix_im, :agent_delivery_mod)
    Application.put_env(:salix_im, :agent_delivery_mod, Salix.Bindings.IMAgentDelivery)
    Application.put_env(:salix_agent, :im_provider_mod, SalixIM.Provider)

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      put_or_delete_env(:salix_im, :agent_delivery_mod, previous_delivery)
    end)

    assert {:ok, comma_message} =
             SalixIM.RouterConversationInput.append_user_message(group_id, %{
               "content" => "Plan my week",
               "client_request_id" => "comma-deferred-result"
             })

    conversation_id = comma_message["conversation_id"]
    {delegate_pid, _, _} = await_request!()
    send(delegate_pid, {:reply_obligation_llm_response, end_turn("delegated")})
    await_settled!(agent_id, session_id)

    # The Worker result activates the Router from its Task, not from the user chat.
    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: "Worker result: the week plan is ready.",
                 role: "user",
                 created_at: System.system_time(:second),
                 trusted_origin: %{
                   "provider" => "internal",
                   "source_actor_type" => "agent",
                   "conversation_kind" => "agent_task",
                   "conversation_id" => CaptureSlack.task_conversation_id(),
                   "agent_group_id" => group_id,
                   "source_message_id" => "worker-result"
                 }
               },
               source_message_id: "worker-result"
             )

    {send_pid, _, _} = await_request!()
    answer = [%{"type" => "text", "text" => "Your week plan is ready."}]

    send(send_pid, {
      :reply_obligation_llm_response,
      {:assistant, "",
       [
         %{
           id: "deferred-final",
           name: "call",
           args: %{
             "tool" => "im_api.internal.send_message",
             "reply_mode" => "final",
             "final_outcome" => "done",
             "params" => %{
               "connect_id" => "internal",
               "conversation_id" => conversation_id,
               "content" => answer
             }
           }
         }
       ]}
    })

    {end_pid, messages, _} = await_request!()
    refute request_text(messages) =~ "Final reply is only available"

    assert {:ok, [delivered]} =
             SalixIM.Conversations.list_group_conversation_messages(group_id, conversation_id,
               after_id: comma_message["message_id"]
             )

    assert delivered["content"] == answer
    send(end_pid, {:reply_obligation_llm_response, end_turn("deferred-done")})
    await_settled!(agent_id, session_id)
    refute_receive {:reply_obligation_llm_request, _, _, _}, 300
  end

  for outcome <- ["done", "blocked"] do
    @tag :advisory_reply
    test "explicit #{outcome} retires an unanswered source and admits the next Slack thread", %{
      agent_id: agent_id,
      session_id: session_id
    } do
      outcome = unquote(outcome)

      deliver!(
        agent_id,
        @source_a1,
        slack_input(@thread_a, "A: system notice, no reply needed"),
        obligation(@thread_a)
      )

      {a_pid, a_messages, _tools} = await_request!()
      assert request_text(a_messages) =~ @thread_a

      deliver!(
        agent_id,
        @source_b,
        slack_input(@thread_b, "B: independent request"),
        obligation(@thread_b)
      )

      send(
        a_pid,
        {:reply_obligation_llm_response,
         {:assistant, "",
          [
            %{
              id: "end-a",
              name: "end_turn",
              args: %{"outcome" => outcome, "reason" => "No reply is needed to the system notice"}
            }
          ]}}
      )

      {b_pid, b_messages, _tools} = await_request!()
      assert request_text(b_messages) =~ "B: independent request"
      session = read_session!(agent_id, session_id)
      assert session.last_ack_message_id >= find_source_message!(session, @source_a1)[:id]

      assert Enum.map(
               ProviderReplyObligation.pending(SalixAgent.InternalSession.open(session)),
               & &1["thread_ts"]
             ) == [@thread_b]

      refute_receive {:reply_obligation_slack_call, ^agent_id, _}, 50

      send(b_pid, {:reply_obligation_llm_response, slack_post("reply-b", @thread_b)})
      assert_slack_call!(agent_id, @thread_b, @source_b)
      {end_pid, _messages, _tools} = await_request!()
      send(end_pid, {:reply_obligation_llm_response, end_turn("end-b")})
      settled = await_source_settled!(agent_id, session_id, @source_b)
      assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(settled)) == 0
      refute "provider_reply_obligation" in SessionData.query(settled, :work_reasons)
    end
  end

  @tag :source_recovery
  test "an exhausted crashed model notifies its source and admits the next Slack request", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    previous_cap = Application.get_env(:salix_agent, :llm_failure_activation_cap)
    Application.put_env(:salix_agent, :llm_failure_activation_cap, 1)
    on_exit(fn -> put_or_delete_env(:salix_agent, :llm_failure_activation_cap, previous_cap) end)

    deliver!(
      agent_id,
      @source_a1,
      slack_input(@thread_a, "A: interrupted request"),
      obligation(@thread_a)
    )

    {first, _, _} = await_request!()
    Process.exit(first, :kill)
    assert_slack_call!(agent_id, @thread_a, @source_a1)
    await_source_settled!(agent_id, session_id, @source_a1)
    refute_receive {:reply_obligation_llm_request, _, _, _}, 100

    deliver!(
      agent_id,
      @source_b,
      slack_input(@thread_b, "B: independent request"),
      obligation(@thread_b)
    )

    {next, messages, _} = await_request!()
    assert request_text(messages) =~ "B: independent request"
    send(next, {:reply_obligation_llm_response, slack_post("answer-next", @thread_b)})
    assert_slack_call!(agent_id, @thread_b, @source_b)
    {finish, _, _} = await_request!()
    send(finish, {:reply_obligation_llm_response, end_turn("finish-next")})
    await_source_settled!(agent_id, session_id, @source_b)
    refute_receive {:reply_obligation_slack_call, ^agent_id, _}, 100
  end

  @tag :source_recovery
  test "without queued input a generic wait retains its deadline and original source", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    deliver!(
      agent_id,
      @source_a1,
      slack_input(@thread_a, "A: wait for unavailable work"),
      obligation(@thread_a)
    )

    {first_pid, _, _} = await_request!()

    send(first_pid, {:reply_obligation_llm_response, wait_for("deadline-a", 1)})
    await_waiting!(agent_id, session_id)
    # Exercise the actor's deadline recovery even if the timer-delivery worker
    # is not running in this local test supervisor.
    Process.sleep(1_100)
    :ok = SalixAgent.InternalSessionActor.wake(agent_id, session_id)

    {timeout_pid, timeout_messages, _} = await_request!()
    assert request_text(timeout_messages) =~ "wait timeout reached"
    refute request_text(timeout_messages) =~ "B: queued behind the wait"
    timed_out = read_session!(agent_id, session_id)
    assert timed_out.wait == nil
    assert timed_out.last_ack_message_id == 0

    deliver!(
      agent_id,
      @source_b,
      slack_input(@thread_b, "B: queued behind the wait"),
      obligation(@thread_b)
    )

    timed_out = read_session!(agent_id, session_id)
    assert Enum.any?(timed_out.input_queue, &(&1["payload"]["source_message_id"] == @source_b))
    send(timeout_pid, {:reply_obligation_llm_response, slack_post("timeout-a", @thread_a)})
    assert_slack_call!(agent_id, @thread_a, @source_a1)
    {terminal_pid, _, _} = await_request!()
    send(terminal_pid, {:reply_obligation_llm_response, end_turn("settle-timeout-a")})
    {b_pid, b_messages, _} = await_request!()
    assert request_text(b_messages) =~ "B: queued behind the wait"
    send(b_pid, {:reply_obligation_llm_response, slack_post("after-timeout-b", @thread_b)})
    assert_slack_call!(agent_id, @thread_b, @source_b)
    {terminal_pid, _, _} = await_request!()
    send(terminal_pid, {:reply_obligation_llm_response, end_turn("settle-timeout-b")})
    await_source_settled!(agent_id, session_id, @source_b)
  end

  test "a Slack-sourced task.create cannot settle until its card is published", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    deliver!(
      agent_id,
      @source_b,
      slack_input(@thread_b, "B: build the launch report"),
      obligation(@thread_b)
    )

    {pid, messages, _tools} = await_request!()
    assert request_text(messages) =~ "B: build the launch report"

    send(pid, {:reply_obligation_llm_response, task_create("create-task")})
    assert_receive {:reply_obligation_task_create, ^agent_id, _args, task_create_pid}, 5_000
    send(task_create_pid, :reply_obligation_complete_task_create)

    # Reply to the source thread, then try to settle with the card unpublished.
    {reply_pid, _messages, _tools} = await_request!()
    send(reply_pid, {:reply_obligation_llm_response, slack_post("reply-b", @thread_b)})
    assert_slack_call!(agent_id, @thread_b)

    {terminal_pid, _messages, _tools} = await_request!()
    send(terminal_pid, {:reply_obligation_llm_response, end_turn("settle-without-card")})

    {retry_pid, retry_messages, _tools} = await_request!()
    retry_text = request_text(retry_messages)
    assert retry_text =~ "task_card"
    assert retry_text =~ CaptureSlack.task_conversation_id()
    assert retry_text =~ "im_api.slack.post_task_card"

    pending = read_session!(agent_id, session_id)
    b_message = find_source_message!(pending, @source_b)
    assert pending.last_ack_message_id < b_message.id
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(pending)) == 1

    assert [%{"kind" => "task_card"}] =
             ProviderReplyObligation.pending(SalixAgent.InternalSession.open(pending))

    send(retry_pid, {:reply_obligation_llm_response, card_post("publish-card")})
    assert_receive {:reply_obligation_card_post, ^agent_id, _args}, 5_000

    {finish_pid, _messages, _tools} = await_request!()
    send(finish_pid, {:reply_obligation_llm_response, end_turn("settle-after-card")})

    settled = await_settled!(agent_id, session_id)
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(settled)) == 0
  end

  test "a successful background Task does not block a different human reply on card publication",
       %{
         agent_id: agent_id,
         session_id: session_id
       } do
    deliver!(
      agent_id,
      @source_b,
      slack_input(@thread_b, "B needs a reply"),
      obligation(@thread_b)
    )

    {pid, _messages, _tools} = await_request!()

    # CaptureSlack stands in for an already-authorized task.create success.
    # Triage authority/forged-ref rejection is covered at the real IM owner seam.
    ref = "triage-delegation:original:0"
    group = SalixStore.Ids.group_id_from_agent!(agent_id)

    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 role: "user",
                 content: "Background investigation from Triage",
                 trusted_origin: %{
                   "provider" => "slack",
                   "source_actor_type" => "provider_system",
                   "source_message_id" => ref,
                   "agent_group_id" => group,
                   "triage_delegation" => %{
                     "schema" => "comma.triage-delegation-origin.v1",
                     "namespace_key" => "original-namespace",
                     "obligation_id" => "original",
                     "request_id" => ref,
                     "index" => 0,
                     "group_id" => group,
                     "router_agent_id" => agent_id
                   }
                 }
               },
               source_message_id: ref
             )

    send(pid, {:reply_obligation_llm_response, wait_for("admit-background-input")})
    {background_pid, messages, _tools} = await_request!()
    assert request_text(messages) =~ "Background investigation from Triage"

    send(
      background_pid,
      {:reply_obligation_llm_response,
       task_create("background-task", %{"triage_delegation_ref" => ref})}
    )

    assert_receive {:reply_obligation_task_create, ^agent_id, _args, task_pid}, 5_000
    send(task_pid, :reply_obligation_complete_task_create)

    {reply_pid, _messages, _tools} = await_request!()
    send(reply_pid, {:reply_obligation_llm_response, slack_post("reply-b", @thread_b)})
    assert_slack_call!(agent_id, @thread_b)

    {finish_pid, _messages, _tools} = await_request!()
    send(finish_pid, {:reply_obligation_llm_response, end_turn("settle-without-background-card")})
    settled = await_settled!(agent_id, session_id)
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(settled)) == 0
    refute_received {:reply_obligation_card_post, _, _}
  end

  test "compaction preserves advisory replies until an explicit ACK retires them" do
    state = fresh_state("session")

    state =
      SessionData.apply_events(state, [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "session",
          "message_id" => 1,
          "source_message_id" => @source_b,
          "role" => "user",
          "content" => "B request",
          "provider_reply_obligation" => obligation(@thread_b)
        },
        %{
          "type" => "compaction",
          "session_id" => "session",
          "compacted_through" => 1,
          "compacted_seq" => 1,
          "summary" => "B still needs a reply"
        }
      ])

    assert state.last_ack_message_id == 0
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(state)) == 1
    refute ProviderReplyObligation.blocking?(SalixAgent.InternalSession.open(state))

    settled =
      SessionData.apply_event(
        state,
        %{"type" => "ack", "session_id" => "session", "last_ack_message_id" => 1}
      )

    assert settled.last_ack_message_id == 1
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(settled)) == 0
    assert settled.visible_reply_egress_facts == %{}

    assert SessionData.apply_event(
             settled,
             %{"type" => "ack", "session_id" => "session", "last_ack_message_id" => 1}
           ) == settled
  end

  test "archive movement and restart preserve reminders until explicit settlement" do
    state = fresh_state("session")

    state =
      SessionData.apply_events(state, [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => "session",
          "message_id" => 1,
          "source_message_id" => @source_b,
          "role" => "user",
          "content" => "B request",
          "provider_reply_obligation" => obligation(@thread_b)
        },
        %{
          "type" => "compaction",
          "session_id" => "session",
          "compacted_through" => 1,
          "compacted_seq" => 1,
          "summary" => "B still needs a reply"
        },
        %{
          "type" => "archive_advance",
          "session_id" => "session",
          "archived_through" => 1,
          "segments" => [[1, 1, 1, 1]]
        }
      ])

    assert state.messages == []
    assert state.archived_through == 1
    assert "provider_reply_obligation" in SessionData.query(state, :work_reasons)

    {:ok, restored} =
      state
      |> SalixAgent.InternalSession.open()
      |> SalixAgent.InternalSession.persist()
      |> SalixAgent.InternalSession.load()

    restarted =
      restored
      |> SalixAgent.InternalSession.apply_event(%{
        "type" => "ack",
        "session_id" => "session",
        "last_ack_message_id" => 1
      })
      |> SalixAgent.InternalSession.export()

    assert restarted.last_ack_message_id == 1
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(restarted)) == 0
  end

  test "same-thread inputs coalesce and only successful exact-target visible calls resolve" do
    state = fresh_state("session")
    state = add_obligation(state, obligation(@thread_b))
    state = add_obligation(state, obligation(@thread_b))
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(state)) == 1

    [pending] = ProviderReplyObligation.pending(SalixAgent.InternalSession.open(state))

    for operation <- [
          "im_api.slack.reply_message",
          "im_api.slack.upload_file",
          "im_api.slack.post_task_card",
          "im_api.slack.bind_thread_to_task"
        ] do
      assert [%{"obligation_key" => key}] =
               ProviderReplyObligation.resolution_events(
                 "session",
                 successful_provider_result(operation, @thread_b)
               )

      assert key == pending["key"]
    end

    [wrong] =
      ProviderReplyObligation.resolution_events(
        "session",
        successful_provider_result("im_api.slack.reply_message", @thread_a)
      )

    refute wrong["obligation_key"] == pending["key"]

    for mutation <- [
          &Map.put(&1, :error, true),
          &Map.put(&1, :status, "guidance"),
          &Map.put(&1, :status, "async_running")
        ] do
      result = mutation.(successful_provider_result("im_api.slack.reply_message", @thread_b))
      assert ProviderReplyObligation.resolution_events("session", result) == []
    end

    assert ProviderReplyObligation.pending_count(
             SalixAgent.InternalSession.open(SessionData.apply_event(state, wrong))
           ) == 1

    [exact] =
      ProviderReplyObligation.resolution_events(
        "session",
        successful_provider_result("im_api.slack.reply_message", @thread_b)
      )

    assert ProviderReplyObligation.pending_count(
             SalixAgent.InternalSession.open(SessionData.apply_event(state, exact))
           ) == 0
  end

  test "a blocked automatic card returns the committed create before its parent timeout",
       context do
    previous = Application.get_env(:salix_agent, :tool_timeouts)
    Application.put_env(:salix_agent, :tool_timeouts, %{"im_api.internal.task.create" => 2_000})
    on_exit(fn -> put_or_delete_env(:salix_agent, :tool_timeouts, previous) end)

    ctx =
      %{
        agent_id: context.agent_id,
        session_id: context.session_id,
        group_id: "test-group",
        role: "router",
        runtime_kind: :internal,
        source_message_id: "test-human",
        llm_tool_envelope: false,
        trusted_origin: %{
          "provider" => "slack",
          "source_actor_type" => "provider_user",
          "agent_group_id" => "test-group",
          "source_message_id" => "test-human",
          "provider_context" => %{
            "connect_id" => "slack-1",
            "channel_id" => @channel,
            "thread_ts" => "blocked"
          }
        }
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    ctx =
      Map.put(
        ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize("router", :internal, ctx)
      )

    task =
      Task.async(fn ->
        SalixAgent.SessionToolDispatch.execute(
          [
            %{
              id: "bounded-create",
              name: "im_api.internal.task.create",
              args: %{
                "connect_id" => "internal",
                "test_auto_card" => true,
                "content" => "Create a task"
              }
            }
          ],
          ctx
        )
      end)

    assert_receive {:reply_obligation_task_create, _, _, pid}, 1_000
    send(pid, :reply_obligation_complete_task_create)
    assert_receive {:reply_obligation_card_post, _, _}, 1_000
    assert_receive {:blocked_card, card_pid}, 1_000
    ref = Process.monitor(card_pid)
    assert [%{error: false, content: content}] = Task.await(task, 3_000)
    result = Jason.decode!(content)
    assert result["created"]
    assert result["conversation_id"] == CaptureSlack.task_conversation_id()
    assert result["task_card"]["status"] == "failed"
    assert result["task_card"]["next_action"] =~ "Retry only post_task_card"
    assert_receive {:DOWN, ^ref, :process, ^card_pid, _}, 1_000
  end

  test "Telegram task creation opens a topic through disclosed tool dispatch", context do
    ctx =
      %{
        agent_id: context.agent_id,
        session_id: context.session_id,
        group_id: "test-group",
        role: "router",
        runtime_kind: :internal,
        source_message_id: "telegram-human",
        llm_tool_envelope: false,
        trusted_origin: %{
          "provider" => "telegram",
          "source_actor_type" => "provider_user",
          "agent_group_id" => "test-group",
          "source_message_id" => "telegram-human",
          "provider_context" => %{
            "connect_id" => "telegram-1",
            "chat_id" => "42001",
            "chat_type" => "private"
          }
        }
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    ctx =
      Map.put(
        ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize("router", :internal, ctx)
      )

    task =
      Task.async(fn ->
        SalixAgent.SessionToolDispatch.execute(
          [
            %{
              id: "telegram-create",
              name: "im_api.internal.task.create",
              args: %{
                "connect_id" => "internal",
                "test_auto_card" => true,
                "content" => "Create a task"
              }
            }
          ],
          ctx
        )
      end)

    assert_receive {:reply_obligation_task_create, _, _, pid}, 1_000
    send(pid, :reply_obligation_complete_task_create)
    assert_receive {:telegram_topic_open, _, %{"params" => params}}, 2_000
    assert params["chat_id"] == "42001"
    assert params["conversation_id"] == CaptureSlack.task_conversation_id()
    assert [%{error: false, content: content}] = Task.await(task, 3_000)
    assert Jason.decode!(content)["task_topic"]["status"] == "ready"
  end

  test "automatic card receipt settles current and existing promises in sync and async paths" do
    id = "cnv1_2094348809374007296_2094348809378201600"
    result = successful_task_create_result(id)
    target = Map.put(provider_params(@thread_b), "conversation_id", id)

    content = %{
      "created" => true,
      "conversation_id" => id,
      "task_card" => %{"status" => "queued", "target" => target}
    }

    result = Map.put(result, :content, Jason.encode!(content))

    for fallback <- [nil, %{call: %{name: "im_api.internal.task.create", args: %{}}}],
        existing <- [false, true] do
      state = fresh_state("session")
      state = add_obligation(state, obligation(@thread_b))
      state = if existing, do: add_card_obligation(state, id), else: state

      events =
        ProviderReplyObligation.resolution_events("session", result, fallback) ++
          ProviderReplyObligation.card_obligation_events("session", result, fallback)

      assert length(events) == 2
      state = Enum.reduce(events, state, &SessionData.apply_event(&2, &1))
      assert ProviderReplyObligation.blocking_count(SalixAgent.InternalSession.open(state)) == 0
    end

    for status <- ["failed", "guidance", "async_running"] do
      failed = put_in(content, ["task_card", "status"], status)
      result = Map.put(result, :content, Jason.encode!(failed))
      assert ProviderReplyObligation.resolution_events("session", result) == []
      assert length(ProviderReplyObligation.card_obligation_events("session", result)) == 1
    end
  end

  test "a Slack-sourced task.create materializes a card obligation that fences the ACK" do
    conversation_id = "cnv1_2094348809374007296_2094348809378201600"
    state = fresh_state("session")
    state = add_obligation(state, obligation(@thread_b))

    assert [
             %{"type" => "provider_card_obligation_added", "conversation_id" => ^conversation_id} =
               added
           ] =
             ProviderReplyObligation.card_obligation_events(
               "session",
               successful_task_create_result(conversation_id)
             )

    state = SessionData.apply_event(state, added)
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(state)) == 2

    [obligation] =
      Enum.filter(
        ProviderReplyObligation.pending(SalixAgent.InternalSession.open(state)),
        &(&1["kind"] == "task_card")
      )

    assert obligation["conversation_id"] == conversation_id
    assert obligation["connect_id"] == "slack-1"
    assert obligation["channel"] == @channel
    assert obligation["thread_ts"] == @thread_b

    # A visible reply to the exact source resolves only the reply target.
    [reply_resolution] =
      ProviderReplyObligation.resolution_events(
        "session",
        successful_provider_result("im_api.slack.reply_message", @thread_b)
      )

    state = SessionData.apply_event(state, reply_resolution)
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(state)) == 1

    fenced =
      SessionData.apply_event(state, %{
        "type" => "ack",
        "session_id" => "session",
        "last_ack_message_id" => 1
      })

    assert fenced.last_ack_message_id == 0

    # Publishing the card for the exact conversation resolves it and also
    # emits the (already-resolved) reply-target resolution.
    card_result =
      successful_provider_result("im_api.slack.post_task_card", @thread_b)
      |> Map.put(
        :input,
        Jason.encode!(Map.put(provider_params(@thread_b), "conversation_id", conversation_id))
      )

    resolutions = ProviderReplyObligation.resolution_events("session", card_result)
    assert length(resolutions) == 2

    state = Enum.reduce(resolutions, state, &SessionData.apply_event(&2, &1))
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(state)) == 0

    settled =
      SessionData.apply_event(state, %{
        "type" => "ack",
        "session_id" => "session",
        "last_ack_message_id" => 1
      })

    assert settled.last_ack_message_id == 1
  end

  test "authorized background investigation never inherits another human source's card obligation" do
    conversation_id = "cnv1_2094348809374007296_2094348809378201601"
    state = fresh_state("session")
    state = add_obligation(state, obligation(@thread_b))

    result =
      successful_task_create_result(conversation_id)
      |> Map.put(
        :input,
        Jason.encode!(%{"triage_delegation_ref" => "triage-delegation:original:0"})
      )

    # Only successful task.create reaches this seam. Its ordinary authorization
    # already rejects invented/missing Triage refs; caller text is not authority.
    assert ProviderReplyObligation.card_obligation_events("session", result) == []

    assert ProviderReplyObligation.card_obligation_events(
             "session",
             Map.drop(result, [:name, :input]),
             Map.take(result, [:name, :input])
           ) == []

    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(state)) == 1

    assert ProviderReplyObligation.pending(SalixAgent.InternalSession.open(state))
           |> hd()
           |> Map.fetch!("thread_ts") == @thread_b

    assert ProviderReplyObligation.blocking_count(SalixAgent.InternalSession.open(state)) == 0

    # A human-requested Task still adds a card fence in exactly the same state.
    [candidate] =
      ProviderReplyObligation.card_obligation_events(
        "session",
        successful_task_create_result(conversation_id)
      )

    assert ProviderReplyObligation.blocking_count(
             SalixAgent.InternalSession.open(SessionData.apply_event(state, candidate))
           ) == 1
  end

  test "card obligations require a Slack-owing activation and an exact task.create success" do
    conversation_id = "cnv1_2094348809374007296_2094348809378201601"
    no_slack = fresh_state("session")

    [candidate] =
      ProviderReplyObligation.card_obligation_events(
        "session",
        successful_task_create_result(conversation_id)
      )

    # A candidate applied to an activation that owes no Slack reply is a no-op.
    assert ProviderReplyObligation.pending_count(
             SalixAgent.InternalSession.open(SessionData.apply_event(no_slack, candidate))
           ) == 0

    for mutation <- [
          &Map.put(&1, :error, true),
          &Map.put(&1, :status, "guidance"),
          &Map.put(&1, :name, "im_api.internal.send_message"),
          &Map.put(&1, :content, Jason.encode!(%{"ok" => true}))
        ] do
      result = mutation.(successful_task_create_result(conversation_id))
      assert ProviderReplyObligation.card_obligation_events("session", result) == []
    end

    # Several pending source threads: the card obligation keeps only the
    # conversation identity, and a wrong-conversation card publish does not
    # resolve it.
    state =
      no_slack
      |> add_obligation(obligation(@thread_b))
      |> add_obligation(obligation(@thread_a))
      |> SessionData.apply_event(candidate)

    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(state)) == 3

    [obligation] =
      Enum.filter(
        ProviderReplyObligation.pending(SalixAgent.InternalSession.open(state)),
        &(&1["kind"] == "task_card")
      )

    refute Map.has_key?(obligation, "channel")
    refute Map.has_key?(obligation, "thread_ts")

    wrong_card =
      successful_provider_result("im_api.slack.post_task_card", @thread_b)
      |> Map.put(
        :input,
        Jason.encode!(Map.put(provider_params(@thread_b), "conversation_id", "cnv1_other"))
      )

    state =
      "session"
      |> ProviderReplyObligation.resolution_events(wrong_card)
      |> Enum.reduce(state, &SessionData.apply_event(&2, &1))

    # The wrong card publish still resolved its reply target, never the card.
    assert Enum.any?(
             ProviderReplyObligation.pending(SalixAgent.InternalSession.open(state)),
             &(&1["kind"] == "task_card" and &1["conversation_id"] == conversation_id)
           )
  end

  test "card materialization honors the shared admission bound" do
    conversation_id = "cnv1_2094348809374007296_2094348809378201603"
    state = fresh_state("session")
    state = add_obligation(state, obligation(@thread_b))
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(state)) == 1

    # Review reproduction: configured limit 1 with one pending reply target.
    # The candidate must not grow the map past the bound; it drops and the
    # card degrades to prompt-only guidance.
    at_bound = %{
      "type" => "provider_card_obligation_added",
      "session_id" => "session",
      "conversation_id" => conversation_id,
      "limit" => 1
    }

    bounded = SessionData.apply_event(state, at_bound)
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(bounded)) == 1

    refute Enum.any?(
             ProviderReplyObligation.pending(SalixAgent.InternalSession.open(bounded)),
             &(&1["kind"] == "task_card")
           )

    # With room below the bound the same candidate materializes.
    roomy = SessionData.apply_event(state, %{at_bound | "limit" => 2})
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(roomy)) == 2

    # An already-tracked conversation coalesces onto its existing key and is
    # admitted even at the bound because it cannot grow the map.
    again = SessionData.apply_event(roomy, %{at_bound | "limit" => 2})
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(again)) == 2

    # A malformed limit fails closed instead of bypassing the bound.
    for limit <- [0, -1, "9", nil] do
      malformed = SessionData.apply_event(state, %{at_bound | "limit" => limit})

      assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(malformed)) ==
               1
    end

    # Generated candidates freeze the configured admission limit.
    [generated] =
      ProviderReplyObligation.card_obligation_events(
        "session",
        successful_task_create_result(conversation_id)
      )

    assert generated["limit"] == ProviderReplyObligation.admission_limit()
    assert is_integer(generated["limit"]) and generated["limit"] > 0
  end

  test "card admission counts targets still reserved in the input queue" do
    conversation_id = "cnv1_2094348809374007296_2094348809378201604"
    state = fresh_state("session")
    state = add_obligation(state, obligation(@thread_a))

    candidate = %{
      "type" => "provider_card_obligation_added",
      "session_id" => "session",
      "conversation_id" => conversation_id,
      "limit" => 2
    }

    # Review reproduction: limit 2, one hot reply target, one distinct reply
    # target still queued. The queued target already holds its reserved
    # admission slot, so the card must not take it; otherwise the queued
    # target's unguarded materialization would push the hot map to 3.
    queued_distinct = %{
      state
      | input_queue: [
          %{
            "queue_id" => 1,
            "payload" => %{"provider_reply_obligation" => obligation(@thread_b)}
          }
        ]
    }

    fenced = SessionData.apply_event(queued_distinct, candidate)
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(fenced)) == 1

    refute Enum.any?(
             ProviderReplyObligation.pending(SalixAgent.InternalSession.open(fenced)),
             &(&1["kind"] == "task_card")
           )

    # A queued duplicate of the already-hot target holds no extra slot, so
    # the card takes the genuinely free one.
    queued_duplicate = %{
      state
      | input_queue: [
          %{
            "queue_id" => 1,
            "payload" => %{"provider_reply_obligation" => obligation(@thread_a)}
          }
        ]
    }

    admitted = SessionData.apply_event(queued_duplicate, candidate)
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(admitted)) == 2

    assert Enum.any?(
             ProviderReplyObligation.pending(SalixAgent.InternalSession.open(admitted)),
             &(&1["kind"] == "task_card" and &1["conversation_id"] == conversation_id)
           )
  end

  test "card obligations survive the state normalize boundary and render in the reminder" do
    conversation_id = "cnv1_2094348809374007296_2094348809378201602"
    state = fresh_state("session")
    state = add_obligation(state, obligation(@thread_b))

    [added] =
      ProviderReplyObligation.card_obligation_events(
        "session",
        successful_task_create_result(conversation_id)
      )

    state = SessionData.apply_event(state, added)

    normalized = %{
      state
      | provider_reply_obligations:
          ProviderReplyObligation.normalize_map(state.provider_reply_obligations)
    }

    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(normalized)) == 2

    [%{content: reminder}] =
      ProviderReplyObligation.append_reminder([], SalixAgent.InternalSession.open(normalized))

    assert reminder =~ ~s("kind":"task_card")
    assert reminder =~ conversation_id
  end

  test "async recovery terminal resolves but callback handoff and async-running do not" do
    pending = %{
      "session_id" => "session",
      "tool_call_id" => "async-slack",
      "tool_name" => "im_api.slack.upload_file",
      "input" => Jason.encode!(provider_params(@thread_b))
    }

    completed = successful_provider_result("im_api.slack.upload_file", @thread_b)

    assert Enum.any?(
             SalixAgent.SessionToolExecution.recovered_internal_events(pending, completed),
             &(&1["type"] == "provider_reply_obligation_resolved")
           )

    handoff =
      completed
      |> Map.put(:status, "async_running")
      |> Map.put(:events, [
        %{
          "type" => "async_tool_call_started",
          "session_id" => "session",
          "tool_call_id" => "async-slack",
          "tool_name" => "im_api.slack.upload_file",
          "input" => Jason.encode!(provider_params(@thread_b))
        }
      ])

    refute Enum.any?(
             SalixAgent.SessionToolExecution.recovered_internal_events(pending, handoff),
             &(&1["type"] == "provider_reply_obligation_resolved")
           )

    non_provider_pending = %{pending | "tool_name" => "fs.read_file"}

    refute Enum.any?(
             SalixAgent.SessionToolExecution.recovered_internal_events(
               non_provider_pending,
               completed
             ),
             &(&1["type"] == "provider_reply_obligation_resolved")
           )
  end

  test "admission and reminders stay bounded while same-target bursts coalesce" do
    state = fresh_state("session")
    state = add_obligation(state, obligation(@thread_a))

    state = %{
      state
      | input_queue: [
          %{
            "queue_id" => 1,
            "payload" => %{"provider_reply_obligation" => obligation(@thread_b)}
          }
        ]
    }

    refute ProviderReplyObligation.admission_full?(
             SalixAgent.InternalSession.open(state),
             %{provider_reply_obligation: obligation(@thread_b)},
             2
           )

    assert ProviderReplyObligation.admission_full?(
             SalixAgent.InternalSession.open(state),
             %{provider_reply_obligation: obligation("1787629999.000001")},
             2
           )

    many =
      Enum.reduce(1..25, fresh_state("many"), fn index, acc ->
        add_obligation(acc, obligation("thread-#{index}"))
      end)

    [%{content: reminder}] =
      ProviderReplyObligation.append_reminder([], SalixAgent.InternalSession.open(many))

    assert length(Regex.scan(~r/"thread_ts":/, reminder)) == 20
    assert reminder =~ "5 additional target(s)"
  end

  defp fresh_state(session_id),
    do: SalixAgent.InternalSession.export(SalixAgent.InternalSession.new("agent", session_id))

  # Seeds a pending reply target the way a materialized delivery leaves it.
  defp add_obligation(state, raw) do
    %{"key" => key} = target = SalixAgent.InternalSession.normalize_obligation(raw)
    obligations = Map.put(state.provider_reply_obligations || %{}, key, target)
    %{state | provider_reply_obligations: obligations}
  end

  defp add_card_obligation(state, conversation_id) do
    SessionData.apply_event(state, %{
      "type" => "provider_card_obligation_added",
      "session_id" => "session",
      "conversation_id" => conversation_id,
      "limit" => 100
    })
  end

  defp obligation(thread_ts) do
    %{
      "provider" => "slack",
      "connect_id" => "slack-1",
      "channel" => @channel,
      "thread_ts" => thread_ts
    }
  end

  defp slack_input(thread_ts, text) do
    "Slack channel=#{@channel} thread_ts=#{thread_ts}\n#{text}"
  end

  defp slack_post(id, thread_ts) do
    {:assistant, "",
     [
       %{
         id: id,
         name: "call",
         args: %{
           "tool" => "im_api.slack.reply_message",
           "params" => %{
             "connect_id" => "slack-1",
             "channel" => @channel,
             "thread_ts" => thread_ts,
             "text" => "handled #{thread_ts}"
           }
         }
       }
     ]}
  end

  defp task_create(id, extra_params \\ %{}) do
    {:assistant, "",
     [
       %{
         id: id,
         name: "call",
         args: %{
           "tool" => "im_api.internal.task.create",
           "params" =>
             Map.merge(
               %{"connect_id" => "internal", "content" => "Build the launch report"},
               extra_params
             )
         }
       }
     ]}
  end

  defp card_post(id, thread_ts \\ @thread_b) do
    {:assistant, "",
     [
       %{
         id: id,
         name: "call",
         args: %{
           "tool" => "im_api.slack.post_task_card",
           "params" => %{
             "connect_id" => "slack-1",
             "conversation_id" => CaptureSlack.task_conversation_id(),
             "channel" => @channel,
             "thread_ts" => thread_ts
           }
         }
       }
     ]}
  end

  defp end_turn(id),
    do: {:assistant, "", [%{id: id, name: "end_turn", args: %{"outcome" => "done"}}]}

  defp terminal_telegram_reply(id) do
    {:assistant, content, [call]} = telegram_post(id)
    reply = Map.take(call.args, ["tool", "params"])

    {:assistant, content,
     [%{id: id, name: "end_turn", args: %{"outcome" => "done", "reply" => reply}}]}
  end

  defp wait_for(id, timeout_seconds \\ 60) do
    {:assistant, "",
     [
       %{
         id: id,
         name: "wait_for",
         args: %{"reason" => "waiting for the source Task", "timeout_seconds" => timeout_seconds}
       }
     ]}
  end

  # A read that neither delivers nor settles, with the same result each time.
  defp idle_call(id) do
    {:assistant, "",
     [
       %{
         id: id,
         name: "call",
         args: %{"tool" => "help", "params" => %{"tool" => "im_api.telegram.send_message"}}
       }
     ]}
  end

  defp telegram_post(id, intent \\ %{"reply_mode" => "progress"}) do
    {:assistant, "",
     [
       %{
         id: id,
         name: "call",
         args:
           Map.merge(
             %{
               "tool" => "im_api.telegram.send_message",
               "params" => %{"connect_id" => "telegram-1", "chat_id" => "42", "text" => "answer"}
             },
             intent
           )
       }
     ]}
  end

  defp deliver_telegram!(agent_id, source, content, provider_message_id \\ nil) do
    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: content,
                 role: "user",
                 created_at: System.system_time(:second),
                 trusted_origin: %{
                   "provider" => "telegram",
                   "source_actor_type" => "provider_user",
                   "source_message_id" => source,
                   "provider_context" => %{
                     "connect_id" => "telegram-1",
                     "chat_id" => "42",
                     "message_id" => provider_message_id || source
                   }
                 }
               },
               source_message_id: source
             )
  end

  defp successful_provider_result(operation, thread_ts) do
    %{
      id: "provider-call",
      name: operation,
      input: Jason.encode!(provider_params(thread_ts)),
      content: ~s({"ok":true}),
      output: ~s({"ok":true}),
      error: false,
      status: "completed",
      events: []
    }
  end

  defp provider_params(thread_ts) do
    %{
      "connect_id" => "slack-1",
      "channel" => @channel,
      "thread_ts" => thread_ts
    }
  end

  defp successful_task_create_result(conversation_id) do
    %{
      id: "task-create-call",
      name: "im_api.internal.task.create",
      input: Jason.encode!(%{"connect_id" => "internal", "content" => "Ship the artifact"}),
      content:
        Jason.encode!(%{
          "conversation_id" => conversation_id,
          "conversation_kind" => "agent_task"
        }),
      output: "",
      error: false,
      status: "completed",
      events: []
    }
  end

  defp deliver!(agent_id, source_message_id, content, provider_reply_obligation) do
    thread_ts = provider_reply_obligation["thread_ts"]

    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: content,
                 role: "user",
                 created_at: System.system_time(:second),
                 provider_reply_obligation: provider_reply_obligation,
                 trusted_origin: %{
                   "provider" => "slack",
                   "source_actor_type" => "provider_user",
                   "source_message_id" => source_message_id,
                   "provider_context" => %{
                     "connect_id" => provider_reply_obligation["connect_id"],
                     "channel_id" => provider_reply_obligation["channel"],
                     "thread_ts" => thread_ts,
                     "message_ts" => thread_ts
                   }
                 }
               },
               source_message_id: source_message_id
             )
  end

  defp deliver_context!(agent_id, source_message_id, content, thread_ts) do
    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: content,
                 role: "user",
                 created_at: System.system_time(:second),
                 trusted_origin: %{
                   "provider" => "slack",
                   "source_actor_type" => "provider_system",
                   "source_message_id" => source_message_id,
                   "provider_context" => %{
                     "connect_id" => "slack-1",
                     "channel_id" => @channel,
                     "thread_ts" => thread_ts,
                     "message_ts" => thread_ts,
                     "event_type" => "meeting.completed"
                   }
                 }
               },
               source_message_id: source_message_id,
               no_wake: true
             )
  end

  defp deliver_internal!(agent_id, source_message_id, content) do
    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: content,
                 role: "user",
                 created_at: System.system_time(:second)
               },
               source_message_id: source_message_id
             )
  end

  defp await_request! do
    assert_receive {:reply_obligation_llm_request, pid, messages, tools}, 5_000
    {pid, messages, tools}
  end

  defp assert_slack_call!(agent_id, thread_ts) do
    assert_receive {:reply_obligation_slack_call, ^agent_id,
                    %{
                      "params" => %{
                        "channel" => @channel,
                        "thread_ts" => ^thread_ts
                      }
                    }},
                   5_000
  end

  defp assert_slack_call!(agent_id, thread_ts, source_message_id) do
    assert_receive {:reply_obligation_slack_call, ^agent_id,
                    %{
                      "params" => %{
                        "channel" => @channel,
                        "thread_ts" => ^thread_ts
                      },
                      "tool_context" => %{
                        "source_message_id" => ^source_message_id,
                        "source_message_ids" => [^source_message_id]
                      }
                    }},
                   5_000
  end

  defp request_text(messages) do
    Enum.map_join(messages, "\n", &to_string(&1[:content] || &1["content"] || ""))
  end

  # A provider request can be observed before the owner's fence lands; join
  # the owner so the read sees the settled transcript.
  defp read_session!(agent_id, session_id) do
    :ok = SalixAgent.TestSupport.join_session_owner(agent_id, session_id)
    {:ok, session} = InternalSessionStore.read(agent_id, session_id)
    session |> SalixAgent.InternalSession.export()
  end

  defp find_source_message!(session, source_message_id) do
    Enum.find(session.messages, fn message ->
      (message[:source_message_id] || message["source_message_id"]) == source_message_id
    end) || flunk("source message not materialized: #{source_message_id}")
  end

  defp await_settled!(agent_id, session_id, attempts \\ 500)
  defp await_settled!(_agent_id, _session_id, 0), do: flunk("session did not settle")

  defp await_settled!(agent_id, session_id, attempts) do
    session = read_session!(agent_id, session_id)

    if session.status == :idle and session.messages != [] and
         session.last_ack_message_id == List.last(session.messages).id do
      session
    else
      Process.sleep(10)
      await_settled!(agent_id, session_id, attempts - 1)
    end
  end

  defp await_source_settled!(agent_id, session_id, source_message_id, attempts \\ 500)

  defp await_source_settled!(_agent_id, _session_id, source_message_id, 0),
    do: flunk("source did not settle: #{source_message_id}")

  defp await_source_settled!(agent_id, session_id, source_message_id, attempts) do
    session = read_session!(agent_id, session_id)
    source = find_source_message!(session, source_message_id)

    if session.last_ack_message_id >= source.id and
         ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(session)) == 0 do
      session
    else
      Process.sleep(10)
      await_source_settled!(agent_id, session_id, source_message_id, attempts - 1)
    end
  end

  defp await_waiting!(agent_id, session_id, attempts \\ 500)
  defp await_waiting!(_agent_id, _session_id, 0), do: flunk("session did not enter wait")

  defp await_waiting!(agent_id, session_id, attempts) do
    session = read_session!(agent_id, session_id)

    if get_in(session.wait || %{}, ["source"]) == "wait_for" do
      session
    else
      Process.sleep(10)
      await_waiting!(agent_id, session_id, attempts - 1)
    end
  end

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)
end
