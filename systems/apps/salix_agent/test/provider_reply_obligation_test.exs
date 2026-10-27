defmodule SalixAgent.ProviderReplyObligationTest do
  require SystemsRuntime.Proc

  require SystemsClock
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

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

    def set_owner(owner, timeout \\ 30_000),
      do: SystemsRuntime.PersistentTerm.put(@owner_key, {owner, timeout})

    def clear_owner, do: SystemsRuntime.PersistentTerm.erase(@owner_key)

    @impl true
    def complete(messages, tools) do
      {owner, timeout} = SystemsRuntime.PersistentTerm.get(@owner_key)

      SystemsRuntime.Proc.send(
        owner,
        {:reply_obligation_llm_request, SystemsRuntime.Proc.self(), messages, tools}
      )

      _ = timeout

      SystemsRuntime.Proc.receive do
        {:reply_obligation_llm_response, response} -> response
      end
    end
  end

  defmodule CaptureSlack do
    @behaviour SalixAgent.Tools.ImRouter
    @owner_key {__MODULE__, :owner}
    @telegram_response_key {__MODULE__, :telegram_response}

    def set_owner(owner), do: SystemsRuntime.PersistentTerm.put(@owner_key, owner)

    def clear_owner do
      SystemsRuntime.PersistentTerm.erase(@owner_key)
      SystemsRuntime.PersistentTerm.erase(@telegram_response_key)
    end

    def telegram_response(response),
      do: SystemsRuntime.PersistentTerm.put(@telegram_response_key, response)

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
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get(@owner_key),
        {:telegram_topic_open, agent_id, args}
      )

      {:ok,
       %{
         "status" => "ready",
         "message_thread_id" => "812",
         "conversation_id" => get_in(args, ["params", "conversation_id"])
       }}
    end

    def call_api(agent_id, "telegram", "telegram.send_message", args) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get(@owner_key),
        {:telegram_call, agent_id, args}
      )

      case SystemsRuntime.PersistentTerm.get(@telegram_response_key, {:ok, %{"ok" => true}}) do
        :controlled ->
          SystemsRuntime.Proc.send(
            SystemsRuntime.PersistentTerm.get(@owner_key),
            {:telegram_reply_pending, SystemsRuntime.Proc.self()}
          )

          SystemsRuntime.Proc.receive do
            {:complete_telegram_reply, response} -> response
          end

        response ->
          response
      end
    end

    def call_api(agent_id, provider, operation, args)
        when provider in ["feishu", "wechat", "imessage"] do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get(@owner_key),
        {:unified_reply, agent_id, provider, operation, args}
      )

      {:ok, %{"ok" => true, "message_id" => "receipt"}}
    end

    def call_api(agent_id, "slack", "slack.reply_message", args) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get(@owner_key),
        {:reply_obligation_slack_call, agent_id, args}
      )

      {:ok, %{"ok" => true, "channel" => get_in(args, ["params", "channel"])}}
    end

    def call_api(agent_id, "slack", "slack.post_task_card", args) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get(@owner_key),
        {:reply_obligation_card_post, agent_id, args}
      )

      if get_in(args, ["params", "thread_ts"]) == "blocked" do
        SystemsRuntime.Proc.send(
          SystemsRuntime.PersistentTerm.get(@owner_key),
          {:blocked_card, SystemsRuntime.Proc.self()}
        )

        SystemsRuntime.Proc.receive do
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
      owner = SystemsRuntime.PersistentTerm.get(@owner_key)

      SystemsRuntime.Proc.send(
        owner,
        {:reply_obligation_task_create, agent_id, args, SystemsRuntime.Proc.self()}
      )

      SystemsRuntime.Proc.receive do
        :reply_obligation_complete_task_create -> :ok
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

    previous_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    previous_im_provider = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
    previous_idle_ms = SystemsRuntime.get_env(:salix_agent, :session_actor_idle_ms)

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    ScriptLLM.set_owner(SystemsRuntime.Proc.self())
    CaptureSlack.set_owner(SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_agent, :llm, ScriptLLM)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, CaptureSlack)
    SystemsRuntime.put_env(:salix_agent, :session_actor_idle_ms, 5_000)

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
    SystemsRuntime.Proc.send(
      first_pid,
      {:reply_obligation_llm_response, task_create("create-task-a1")}
    )

    settle_receive({:reply_obligation_task_create, ^agent_id, _args, task_create_pid})

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
    SystemsRuntime.Proc.send(task_create_pid, :reply_obligation_complete_task_create)

    assert Enum.reduce_while(1..500, false, fn _, _ ->
             state = read_session!(agent_id, session_id)

             if Enum.any?(state.async_results, &(&1["tool_call_id"] == "create-task-a1")) do
               {:halt, true}
             else
               settle()
               {:cont, false}
             end
           end)

    SystemsRuntime.Proc.send(
      waiting_pid,
      {:reply_obligation_llm_response, wait_for("wait-for-task-a1")}
    )

    {task_result_pid, task_result_messages, _tools} = await_request!()
    task_result_text = request_text(task_result_messages)
    assert task_result_text =~ CaptureSlack.task_conversation_id()
    assert task_result_text =~ "A1 meeting completed context"
    assert task_result_text =~ "group health refreshed"
    refute task_result_text =~ "B: convert this to MP3 and send it"
    refute task_result_text =~ "A2: continue the Home Agent work"

    SystemsRuntime.Proc.send(
      task_result_pid,
      {:reply_obligation_llm_response, slack_post("reply-a1", @thread_a)}
    )

    assert_slack_call!(agent_id, @thread_a, @source_a1)

    {card_pid, card_messages, _tools} = await_request!()
    card_text = request_text(card_messages)
    refute card_text =~ "B: convert this to MP3 and send it"
    refute card_text =~ "A2: continue the Home Agent work"

    SystemsRuntime.Proc.send(
      card_pid,
      {:reply_obligation_llm_response, card_post("publish-card-a1", @thread_a)}
    )

    settle_receive(
      {:reply_obligation_card_post, ^agent_id,
       %{
         "params" => %{"thread_ts" => @thread_a},
         "tool_context" => %{"source_message_id" => @source_a1}
       }}
    )

    # Provider calls are intermediate tool turns. B and A2 must stay queued
    # while A1 continues to its explicit terminal decision.
    {a1_terminal_pid, a1_terminal_messages, _tools} = await_request!()
    a1_terminal_text = request_text(a1_terminal_messages)
    refute a1_terminal_text =~ "B: convert this to MP3 and send it"
    refute a1_terminal_text =~ "A2: continue the Home Agent work"

    SystemsRuntime.Proc.send(
      a1_terminal_pid,
      {:reply_obligation_llm_response, end_turn("settle-a1")}
    )

    {b_pid, b_messages, _tools} = await_request!()
    b_text = request_text(b_messages)
    assert b_text =~ "B: convert this to MP3 and send it"
    refute b_text =~ "A2: continue the Home Agent work"

    SystemsRuntime.Proc.send(
      b_pid,
      {:reply_obligation_llm_response, slack_post("reply-b", @thread_b)}
    )

    assert_slack_call!(agent_id, @thread_b, @source_b)

    {b_terminal_pid, b_terminal_messages, _tools} = await_request!()
    refute request_text(b_terminal_messages) =~ "A2: continue the Home Agent work"

    SystemsRuntime.Proc.send(
      b_terminal_pid,
      {:reply_obligation_llm_response, end_turn("settle-b")}
    )

    {a2_pid, a2_messages, _tools} = await_request!()
    assert request_text(a2_messages) =~ "A2: continue the Home Agent work"

    SystemsRuntime.Proc.send(
      a2_pid,
      {:reply_obligation_llm_response, slack_post("reply-a2", @thread_a)}
    )

    assert_slack_call!(agent_id, @thread_a, @source_a2)

    {a2_terminal_pid, _messages, _tools} = await_request!()

    SystemsRuntime.Proc.send(
      a2_terminal_pid,
      {:reply_obligation_llm_response, end_turn("settle-a2")}
    )

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

    SystemsRuntime.Proc.send(
      a_pid,
      {:reply_obligation_llm_response, slack_post("answer-a", @thread_a)}
    )

    assert_slack_call!(agent_id, @thread_a, @source_a1)
    {wait_pid, _, _} = await_request!()

    SystemsRuntime.Proc.send(
      wait_pid,
      {:reply_obligation_llm_response, wait_for("wait-for-user", 1800)}
    )

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

    SystemsRuntime.Proc.send(
      b_pid,
      {:reply_obligation_llm_response, slack_post("answer-b", @thread_b)}
    )

    assert_slack_call!(agent_id, @thread_b, @source_b)
    {end_pid, _, _} = await_request!()
    SystemsRuntime.Proc.send(end_pid, {:reply_obligation_llm_response, end_turn("end-b")})
    await_source_settled!(agent_id, session_id, @source_b)
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

      SystemsRuntime.Proc.send(
        model,
        {:reply_obligation_llm_response,
         LLM.Error.http("openai_responses", 401, "private credential")}
      )

      args =
        if provider == "slack" do
          settle_receive({:reply_obligation_slack_call, ^agent_id, args})
          args
        else
          settle_receive({:unified_reply, ^agent_id, ^provider, _, args})
          args
        end

      for {key, value} <- unquote(Macro.escape(params)),
          key != "text",
          do: assert(args["params"][key] == value)

      assert args["tool_context"]["source_message_id"] == source
      refute inspect(args["params"]) =~ "private credential"
      await_source_settled!(agent_id, session_id, source)
      settle_refute_receive({:reply_obligation_llm_request, _, _, _}, 100)
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
                   created_at: SystemsClock.system_time(:second),
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

      SystemsRuntime.Proc.send(
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
        settle_receive({:reply_obligation_slack_call, ^agent_id, _})
      else
        settle_receive({:unified_reply, ^agent_id, ^provider, _, _})
      end

      {next, _, _} = await_request!()

      SystemsRuntime.Proc.send(
        next,
        {:reply_obligation_llm_response, end_turn("explicit-finish")}
      )

      settled = await_source_settled!(agent_id, session_id, source)
      refute Enum.any?(settled.events, &(&1["kind"] == "terminal_reply_delivered"))
      settle_refute_receive({:reply_obligation_llm_request, _, _, _}, 300)
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
      previous_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
      SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, Salix.Bindings.IMAgentDelivery)
      SystemsRuntime.put_env(:salix_agent, :im_provider_mod, SalixIM.Provider)

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

      SystemsRuntime.Proc.send(pid, {:reply_obligation_llm_response, response})

      if unquote(adapter) != :model_failure do
        {next, messages, _} = await_request!()
        assert request_text(messages) =~ "I will prepare the calendar."
        current = read_session!(agent_id, session_id)
        assert current.last_ack_message_id < Enum.find(current.messages, &(&1.role == "user")).id

        SystemsRuntime.Proc.send(
          next,
          {:reply_obligation_llm_response, end_turn("comma-explicit-finish")}
        )
      end

      await_settled!(agent_id, session_id)
      settle_refute_receive({:reply_obligation_llm_request, _, _, _}, 300)

      assert {:ok, [message]} =
               SalixIM.Conversations.list_group_conversation_messages(
                 group_id,
                 input["conversation_id"],
                 after_id: input["message_id"]
               )

      if unquote(adapter) == :model_failure do
        # A platform-funded provider out of quota stops as `model_unavailable`.
        assert inspect(message["content"]) =~ "Choose another model"
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

    SystemsRuntime.Proc.send(pid, {:reply_obligation_llm_response, {:assistant, content, [call]}})

    settle_receive({:telegram_call, ^agent_id, _})

    {next, _, _} = await_request!()

    SystemsRuntime.Proc.send(
      next,
      {:reply_obligation_llm_response, end_turn("tg-explicit-finish")}
    )

    settled = await_source_settled!(agent_id, session_id, "tg-final-A")
    assert settled.wait == nil

    deliver_telegram!(agent_id, "tg-final-B", "B: independent next request")
    {next, messages, _} = await_request!()
    assert request_text(messages) =~ "B: independent next request"
    SystemsRuntime.Proc.send(next, {:reply_obligation_llm_response, end_turn("tg-final-end-b")})
    await_source_settled!(agent_id, session_id, "tg-final-B")
    settle_refute_receive({:telegram_call, ^agent_id, _}, 100)
  end

  @tag :terminal_reply
  test "an end_turn reply retains a failed source and admits input queued during its successful retry",
       %{agent_id: agent_id, session_id: session_id} do
    CaptureSlack.telegram_response({:error, "telegram request rejected"})
    deliver_telegram!(agent_id, "tg-terminal-A", "A: answer once")
    {first, _, _} = await_request!()

    SystemsRuntime.Proc.send(
      first,
      {:reply_obligation_llm_response, terminal_telegram_reply("terminal-failed")}
    )

    settle_receive({:telegram_call, ^agent_id, _})

    {repair, messages, _} = await_request!()
    assert request_text(messages) =~ "telegram request rejected"
    failed = read_session!(agent_id, session_id)
    assert failed.last_ack_message_id == 0
    refute Enum.any?(failed.events, &(&1["kind"] == "terminal_reply_delivered"))
    settle_refute_receive({:telegram_call, ^agent_id, _}, 50)

    SystemsRuntime.Proc.send(
      repair,
      {:reply_obligation_llm_response, idle_call("inspect-terminal-failure")}
    )

    {retry, _, _} = await_request!()
    CaptureSlack.telegram_response(:controlled)

    SystemsRuntime.Proc.send(
      retry,
      {:reply_obligation_llm_response, terminal_telegram_reply("terminal-retry")}
    )

    settle_receive(
      {:telegram_call, ^agent_id, %{"tool_context" => %{"source_message_id" => "tg-terminal-A"}}}
    )

    settle_receive({:telegram_reply_pending, sender})
    deliver_telegram!(agent_id, "tg-terminal-B", "B: independent next request")
    SystemsRuntime.Proc.send(sender, {:complete_telegram_reply, {:ok, %{"ok" => true}}})

    {next, messages, _} = await_request!()
    assert request_text(messages) =~ "B: independent next request"
    current = read_session!(agent_id, session_id)
    assert current.last_ack_message_id >= find_source_message!(current, "tg-terminal-A").id
    assert current.last_ack_message_id < find_source_message!(current, "tg-terminal-B").id
    assert Enum.count(current.events, &(&1["kind"] == "terminal_reply_delivered")) == 1
    settle_refute_receive({:telegram_call, ^agent_id, _}, 100)

    SystemsRuntime.Proc.send(
      next,
      {:reply_obligation_llm_response, end_turn("terminal-B-finish")}
    )

    await_source_settled!(agent_id, session_id, "tg-terminal-B")
    settle_refute_receive({:reply_obligation_llm_request, _, _, _}, 100)
    settle_refute_receive({:telegram_call, ^agent_id, _}, 100)
  end

  @tag :terminal_reply
  test "queued human source context does not add a model round to terminal replies", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    context = fn source ->
      [
        %{
          source_message_id: source <> ":source-context",
          role: "summary",
          content: source <> " facts"
        }
      ]
    end

    deliver_telegram!(agent_id, "context-A", "A: answer once", nil, context.("context-A"))
    {first, messages, _} = await_request!()
    assert request_text(messages) =~ "context-A facts"

    # B's context arrives while A's model runs; C arrives while its reply runs.
    # Neither may block A's terminal admission or its result-time settlement.
    deliver_telegram!(agent_id, "context-B", "B: answer once", nil, context.("context-B"))
    CaptureSlack.telegram_response(:controlled)

    SystemsRuntime.Proc.send(
      first,
      {:reply_obligation_llm_response, terminal_telegram_reply("reply-A")}
    )

    first_result =
      settle_until(fn ->
        SystemsRuntime.Proc.receive do
          {:telegram_call, ^agent_id, _} = call -> call
          {:reply_obligation_llm_request, _, _, _} = extra_round -> extra_round
        after
          0 -> nil
        end
      end)

    assert {:telegram_call, ^agent_id,
            %{
              "tool_context" => %{
                "source_message_id" => "context-A",
                "source_message_ids" => ["context-A"]
              }
            }} = first_result

    settle_receive({:telegram_reply_pending, sender})
    deliver_telegram!(agent_id, "context-C", "C: answer once", nil, context.("context-C"))
    SystemsRuntime.Proc.send(sender, {:complete_telegram_reply, {:ok, %{"ok" => true}}})
    CaptureSlack.telegram_response({:ok, %{"ok" => true}})

    for source <- ["context-B", "context-C"] do
      {pid, messages, _} = await_request!()
      text = request_text(messages)
      assert text =~ source <> " facts"
      if source == "context-B", do: refute(text =~ "context-C facts")

      SystemsRuntime.Proc.send(
        pid,
        {:reply_obligation_llm_response, terminal_telegram_reply("reply-" <> source)}
      )

      settle_receive(
        {:telegram_call, ^agent_id,
         %{"tool_context" => %{"source_message_id" => ^source, "source_message_ids" => [^source]}}}
      )
    end

    settled = await_source_settled!(agent_id, session_id, "context-C")
    assert Enum.count(settled.events, &(&1["kind"] == "terminal_reply_delivered")) == 3

    assert Enum.filter(
             settled.messages,
             &(&1.role == "summary" and
                 String.starts_with?(Map.get(&1, :source_message_id, ""), "context-"))
           )
           |> Enum.map(& &1.source_message_id) ==
             ["context-A:source-context", "context-B:source-context", "context-C:source-context"]

    assert settled.input_queue == []
    settle_refute_receive({:reply_obligation_llm_request, _, _, _}, 100)
    settle_refute_receive({:telegram_call, ^agent_id, _}, 100)
  end

  defmodule NativePrompt do
    def capabilities(_), do: %{"question" => true, "location" => true, "permission" => true}

    def request(scope, type, args, call) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:native_prompt, SystemsRuntime.Proc.self(), scope, type, args, call}
      )

      SystemsClock.vreceive do
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
      previous = SystemsRuntime.get_env(:salix_agent, :telegram_interaction_mod)
      SystemsRuntime.put_env(:salix_agent, :telegram_interaction_mod, NativePrompt)
      SystemsRuntime.PersistentTerm.put({NativePrompt, :owner}, SystemsRuntime.Proc.self())

      on_exit(fn ->
        if is_nil(previous),
          do: SystemsRuntime.delete_env(:salix_agent, :telegram_interaction_mod),
          else: SystemsRuntime.put_env(:salix_agent, :telegram_interaction_mod, previous)

        SystemsRuntime.PersistentTerm.erase({NativePrompt, :owner})
      end)

      deliver_telegram!(c.agent_id, "native-A", "A: ask for my city", "501")
      {pid, _, tools} = await_request!()
      assert tools == SalixAgent.ToolDisclosure.internal_llm_specs("router")

      # Replay the old model call: a Chinese question without a locale must not
      # send an English card or settle the source before the model corrects it.
      SystemsRuntime.Proc.send(
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

      settle_refute_receive({:native_prompt, _, _, _, _, _}, 100)
      current = read_session!(c.agent_id, c.session_id)
      refute Enum.any?(current.events, &(&1["kind"] == "terminal_reply_delivered"))

      SystemsRuntime.Proc.send(
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

      settle_receive(
        {:native_prompt, sender, scope, ^type, %{"locale" => "zh-CN"}, "native-question"}
      )

      assert scope["context_source_message_ids"] == ["native-A"]
      assert scope["reply_to_message_id"] == "501"
      deliver_telegram!(c.agent_id, "native-B", "B: independent message")
      SystemsRuntime.Proc.send(sender, :delivered)
      {b_pid, b_messages, _} = await_request!()
      assert request_text(b_messages) =~ "B: independent message"
      current = read_session!(c.agent_id, c.session_id)
      assert current.wait == nil
      refute Enum.any?(current.async_tool_calls, fn {_, call} -> call["status"] == "running" end)
      assert Enum.any?(current.events, &(&1["kind"] == "terminal_reply_delivered"))
      SystemsRuntime.Proc.send(b_pid, {:reply_obligation_llm_response, end_turn("native-B-end")})
      await_source_settled!(c.agent_id, c.session_id, "native-B")
      deliver_telegram!(c.agent_id, "native-C", "Answer to native-A: 杭州")
      {c_pid, c_messages, _} = await_request!()
      assert request_text(c_messages) =~ "Answer to native-A: 杭州"
      SystemsRuntime.Proc.send(c_pid, {:reply_obligation_llm_response, end_turn("native-C-end")})
      await_source_settled!(c.agent_id, c.session_id, "native-C")
      settle_refute_receive({:native_prompt, _, _, _, _, _}, 200)
    end
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

    SystemsRuntime.Proc.send(
      pid,
      {:reply_obligation_llm_response,
       telegram_post("question-send", %{"reply_mode" => "final", "final_outcome" => "blocked"})}
    )

    settle_receive({:telegram_call, ^agent_id, args})
    assert args["params"]["reply_to_message_id"] == "502"
    refute Map.has_key?(args["params"], "reply_mode")
    refute Map.has_key?(args["params"], "final_outcome")
    settle_receive({:telegram_reply_pending, sender})
    # Queue a second source while A's final delivery is still in flight.
    deliver_telegram!(agent_id, "tg-next", "The next independent request")
    SystemsRuntime.Proc.send(sender, {:complete_telegram_reply, {:ok, %{"ok" => true}}})
    {finish, _, _} = await_request!()

    SystemsRuntime.Proc.send(
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
    SystemsRuntime.Proc.send(next, {:reply_obligation_llm_response, end_turn("next-end")})
    await_source_settled!(agent_id, session_id, "tg-next")

    [{actor, _}] =
      SystemsRuntime.Registry.lookup(
        SalixAgent.Registry,
        SalixAgent.InternalSessionActor.key(agent_id, session_id)
      )

    SystemsRuntime.Server.stop(actor, :normal)
    SalixAgent.InternalSessionActor.wake(agent_id, session_id)
    settle_refute_receive({:reply_obligation_llm_request, _, _, _}, 300)
    settle_refute_receive({:telegram_call, ^agent_id, _}, 100)
  end

  @tag :model_failure_reply
  test "transient model failures retain the source through retry exhaustion", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    # Each round's provider retries back off 7.75s in total; rate 20 makes it ~0.4s.
    previous = SystemsRuntime.get_env(:salix_agent, :llm_activation_retry_base_ms)
    SystemsRuntime.put_env(:salix_agent, :llm_activation_retry_base_ms, 10)
    on_exit(fn -> put_or_delete_env(:salix_agent, :llm_activation_retry_base_ms, previous) end)
    deliver_telegram!(agent_id, "tg-exhausted-model", "Please answer after retry")

    for attempt <- 1..18 do
      {model, _, _} = await_request!()
      if attempt == 7, do: assert(read_session!(agent_id, session_id).last_ack_message_id == 0)

      SystemsRuntime.Proc.send(
        model,
        {:reply_obligation_llm_response,
         LLM.Error.http("openai_responses", 503, "private outage")}
      )
    end

    settle_receive({:telegram_call, ^agent_id, args})
    assert args["tool_context"]["source_message_id"] == "tg-exhausted-model"
    refute args["params"]["text"] =~ "private outage"
    await_source_settled!(agent_id, session_id, "tg-exhausted-model")
    settle_refute_receive({:reply_obligation_llm_request, _, _, _}, 200)
    settle_refute_receive({:telegram_call, ^agent_id, _}, 100)
  end

  @tag :model_failure_reply
  test "a permanent model error sends one safe failure reply and releases the next request",
       %{agent_id: agent_id, session_id: session_id} do
    rounds = attach_round_operations()
    CaptureSlack.telegram_response(:controlled)
    deliver_telegram!(agent_id, "tg-model-failure", "Please answer my request")
    {model, _, _} = await_request!()

    SystemsRuntime.Proc.send(
      model,
      {:reply_obligation_llm_response,
       LLM.Error.http(
         "openai_responses",
         402,
         ~s({"error":{"message":"Insufficient credits for private-key-identifier"}})
       )}
    )

    settle_receive({:telegram_call, ^agent_id, args})
    assert args["params"]["chat_id"] == "42"
    assert args["tool_context"]["source_message_id"] == "tg-model-failure"
    assert args["params"]["text"] =~ "model"
    refute args["params"]["text"] =~ "private-key-identifier"
    settle_receive({:telegram_reply_pending, sender})
    settle_refute_receive({:reply_obligation_llm_request, _, _, _}, 100)

    deliver_telegram!(agent_id, "tg-model-next", "A new request after model recovery")
    SystemsRuntime.Proc.send(sender, {:complete_telegram_reply, {:ok, %{"ok" => true}}})
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

    SystemsRuntime.Proc.send(next, {:reply_obligation_llm_response, end_turn("model-next-end")})
    await_source_settled!(agent_id, session_id, "tg-model-next")
    settle_refute_receive({:telegram_call, ^agent_id, _}, 100)

    # The failed model round, the guard round that sent the notice, and the
    # next request's round each report one round operation.
    assert [_, _, _] = collect_round_operations(rounds)
  end

  defp attach_round_operations do
    handler_id = {__MODULE__, :round_operations, SystemsRuntime.Proc.unique_integer([:positive])}
    test_pid = SystemsRuntime.Proc.self()

    SystemsRuntime.Telemetry.attach(
      handler_id,
      [:salix, :operation, :stop],
      fn _event, _measurements, meta, _config ->
        if meta.operation == "round",
          do: SystemsRuntime.Proc.send(test_pid, {handler_id, meta.outcome})
      end,
      nil
    )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler_id) end)
    handler_id
  end

  defp collect_round_operations(handler_id) do
    settle()
    drain_round_operations(handler_id, [])
  end

  defp drain_round_operations(handler_id, acc) do
    SystemsRuntime.Proc.receive do
      {^handler_id, outcome} -> drain_round_operations(handler_id, [outcome | acc])
    after
      0 -> Enum.reverse(acc)
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
    settle_receive({:telegram_call, ^agent_id, args})
    assert args["tool_context"]["source_message_id"] == source
    await_source_settled!(agent_id, session_id, source)
    settle_refute_receive({:reply_obligation_llm_request, _, _, _}, 100)

    SystemsRuntime.Server.stop(actor, :normal)
    assert {:ok, _} = SalixAgent.InternalSessionFleet.ensure_started(agent_id, session_id)
    settle_refute_receive({:telegram_call, ^agent_id, _}, 200)
    settle_refute_receive({:reply_obligation_llm_request, _, _, _}, 100)
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

        SystemsRuntime.Proc.send(
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

      settle_receive({:telegram_call, ^agent_id, args})
      assert args["params"]["chat_id"] == "42"
      assert args["tool_context"]["source_message_id"] == "tg-guard"
      assert args["params"]["text"] =~ "couldn't complete"
      settle_receive({:telegram_reply_pending, sender})
      deliver_telegram!(agent_id, "tg-after-guard", "A new independent request")

      response =
        if @notification == :success,
          do: {:ok, %{"ok" => true}},
          else: {:error, "provider unavailable"}

      SystemsRuntime.Proc.send(sender, {:complete_telegram_reply, response})
      {next, messages, _} = await_request!()
      assert request_text(messages) =~ "A new independent request"
      settle_refute_receive({:telegram_call, ^agent_id, _}, 100)
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
      SystemsRuntime.Proc.send(next, {:reply_obligation_llm_response, end_turn("next-guard-end")})
      await_source_settled!(agent_id, session_id, "tg-after-guard")
      settle_refute_receive({:telegram_call, ^agent_id, _}, 100)
    end
  end

  @tag :expired_callback
  test "deadline recovery releases an internal location wait and the next queued Telegram request",
       %{
         agent_id: agent_id,
         session_id: session_id
       } do
    previous = SystemsRuntime.get_env(:salix_agent, :capability_request_store_mod)

    SystemsRuntime.put_env(
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
      "expires_at" => SystemsClock.system_time(:second) + 3
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

    SystemsRuntime.Proc.send(
      waiting,
      {:reply_obligation_llm_response, wait_for("wait-for-location", 1800)}
    )

    await_waiting!(agent_id, session_id)

    settle_refute_receive({:reply_obligation_llm_request, _, _, _}, 200)
    settle_refute_receive({:telegram_call, ^agent_id, _}, 50)

    # Exercise the same durable sweep used by the production recovery tick.
    # No actor wake, new input, or model wait deadline triggers the expiry.
    settle_after(
      max(0, persisted_request["expires_at"] * 1_000 - SystemsClock.system_time(:millisecond))
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

    SystemsRuntime.Proc.send(
      resumed,
      {:reply_obligation_llm_response, telegram_post("resumed-final", final)}
    )

    settle_receive({:telegram_call, ^agent_id, _})
    {finish, _, _} = await_request!()

    SystemsRuntime.Proc.send(
      finish,
      {:reply_obligation_llm_response, end_turn("resumed-explicit-finish")}
    )

    {next, messages, _} = await_request!()
    assert request_text(messages) =~ "Second Telegram request"

    SystemsRuntime.Proc.send(
      next,
      {:reply_obligation_llm_response, telegram_post("queued-final", final)}
    )

    settle_receive({:telegram_call, ^agent_id, _})
    {finish, _, _} = await_request!()

    SystemsRuntime.Proc.send(
      finish,
      {:reply_obligation_llm_response, end_turn("queued-explicit-finish")}
    )

    settled = await_source_settled!(agent_id, session_id, "tg-queued")
    refute Enum.any?(settled.events, &(&1["kind"] == "terminal_reply_delivered"))
    settle_refute_receive({:telegram_call, ^agent_id, _}, 100)
  end

  @tag :comma_reply_delivery
  test "Comma answer is explicitly delivered after query and session-only prose", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})
    previous_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, Salix.Bindings.IMAgentDelivery)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, SalixIM.Provider)

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

    SystemsRuntime.Proc.send(query_pid, {
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

    SystemsRuntime.Proc.send(
      answer_pid,
      {:reply_obligation_llm_response, {:assistant, answer, []}}
    )

    {send_pid, messages, _} = await_request!()

    # Reproduce the incident boundary: generation has not authored any Message.
    assert {:ok, []} =
             SalixIM.Conversations.list_group_conversation_messages(group_id, conversation_id,
               after_id: comma_message["message_id"]
             )

    assert request_text(messages) =~ conversation_id

    SystemsRuntime.Proc.send(send_pid, {
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

    SystemsRuntime.Proc.send(
      end_pid,
      {:reply_obligation_llm_response, end_turn("comma-answer-done")}
    )

    await_settled!(agent_id, session_id)
    settle_refute_receive({:reply_obligation_llm_request, _, _, _}, 300)

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
    previous_cap = SystemsRuntime.get_env(:salix_agent, :runaway_unsettled_round_cap)
    SystemsRuntime.put_env(:salix_agent, :runaway_unsettled_round_cap, 3)
    on_exit(fn -> put_or_delete_env(:salix_agent, :runaway_unsettled_round_cap, previous_cap) end)

    deliver_telegram!(agent_id, "tg-refused", "Preserve this request")

    for n <- 1..3 do
      {pid, _, _} = await_request!()

      SystemsRuntime.Proc.send(
        pid,
        {:reply_obligation_llm_response, {:assistant, "Still thinking #{n}.", []}}
      )
    end

    settled = await_source_settled!(agent_id, session_id, "tg-refused")

    assert Enum.any?(
             settled.events,
             &(&1["kind"] == "runtime_runaway_retired" and
                 &1["event"]["outcome"] == "blocked")
           )

    await_settled!(agent_id, session_id)
    settle_refute_receive({:telegram_call, ^agent_id, _}, 100)
  end

  for {kind, no_wake, actor_type} <- [
        {"meeting context", true, "provider_system"},
        {"Worker report", false, "agent"}
      ] do
  end

  @tag :terminal_reply
  test "a restored mixed Comma and Telegram transcript retires with both sources audited", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    previous_cap = SystemsRuntime.get_env(:salix_agent, :runaway_unsettled_round_cap)
    SystemsRuntime.put_env(:salix_agent, :runaway_unsettled_round_cap, 3)
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

      SystemsRuntime.Proc.send(
        pid,
        {:reply_obligation_llm_response, {:assistant, "Still thinking #{n}.", []}}
      )
    end

    retired = await_settled!(agent_id, session_id)
    settle_refute_receive({:telegram_call, ^agent_id, _}, 300)
    settle_refute_receive({:reply_obligation_llm_request, _, _, _}, 300)
    assert SessionData.query(retired, :consecutive_unsettled_rounds) == 0
    assert retired.status == :idle
    assert SessionData.query(retired, :work_reasons) == []
    assert retired.last_ack_message_id == retired.next_message_id - 1

    fact = Enum.find(retired.events, &(&1["kind"] == "runtime_runaway_retired"))
    assert fact["event"]["outcome"] == "blocked"
    assert fact["event"]["source_message_ids"] == Enum.map(1..3, &"legacy-source-#{&1}")
    assert fact["event"]["consecutive_unsettled_rounds"] == 3
  end

  for {label, intent} <- [
        {"undeclared", %{}},
        {"final-labelled", %{"reply_mode" => "final", "final_outcome" => "done"}}
      ] do
  end

  @tag :comma_reply_delivery
  test "a Router delivers a Worker result to the original Comma user despite final metadata", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})
    previous_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, Salix.Bindings.IMAgentDelivery)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, SalixIM.Provider)

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

    SystemsRuntime.Proc.send(
      delegate_pid,
      {:reply_obligation_llm_response, end_turn("delegated")}
    )

    await_settled!(agent_id, session_id)

    # The Worker result activates the Router from its Task, not from the user chat.
    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: "Worker result: the week plan is ready.",
                 role: "user",
                 created_at: SystemsClock.system_time(:second),
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

    SystemsRuntime.Proc.send(send_pid, {
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
    SystemsRuntime.Proc.send(end_pid, {:reply_obligation_llm_response, end_turn("deferred-done")})
    await_settled!(agent_id, session_id)
    settle_refute_receive({:reply_obligation_llm_request, _, _, _}, 300)
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

      SystemsRuntime.Proc.send(
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

      settle_refute_receive({:reply_obligation_slack_call, ^agent_id, _}, 50)

      SystemsRuntime.Proc.send(
        b_pid,
        {:reply_obligation_llm_response, slack_post("reply-b", @thread_b)}
      )

      assert_slack_call!(agent_id, @thread_b, @source_b)
      {end_pid, _messages, _tools} = await_request!()
      SystemsRuntime.Proc.send(end_pid, {:reply_obligation_llm_response, end_turn("end-b")})
      settled = await_source_settled!(agent_id, session_id, @source_b)
      assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(settled)) == 0
      refute "provider_reply_obligation" in SessionData.query(settled, :work_reasons)
    end
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

    SystemsRuntime.Proc.send(pid, {:reply_obligation_llm_response, task_create("create-task")})
    settle_receive({:reply_obligation_task_create, ^agent_id, _args, task_create_pid})
    SystemsRuntime.Proc.send(task_create_pid, :reply_obligation_complete_task_create)

    # Reply to the source thread, then try to settle with the card unpublished.
    {reply_pid, _messages, _tools} = await_request!()

    SystemsRuntime.Proc.send(
      reply_pid,
      {:reply_obligation_llm_response, slack_post("reply-b", @thread_b)}
    )

    assert_slack_call!(agent_id, @thread_b)

    {terminal_pid, _messages, _tools} = await_request!()

    SystemsRuntime.Proc.send(
      terminal_pid,
      {:reply_obligation_llm_response, end_turn("settle-without-card")}
    )

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

    SystemsRuntime.Proc.send(
      retry_pid,
      {:reply_obligation_llm_response, card_post("publish-card")}
    )

    settle_receive({:reply_obligation_card_post, ^agent_id, _args})

    {finish_pid, _messages, _tools} = await_request!()

    SystemsRuntime.Proc.send(
      finish_pid,
      {:reply_obligation_llm_response, end_turn("settle-after-card")}
    )

    settled = await_settled!(agent_id, session_id)
    assert ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(settled)) == 0
  end

  # A Slack bot gets no automatic Task card, so its Task must not leave a card
  # obligation that blocks the Router's wait from yielding to a person.
  test "a Task for a Slack bot's request adds no card obligation and its wait yields", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)

    deliver!(
      agent_id,
      @source_a1,
      slack_input(@thread_a, "A: the nightly build is ready for handoff"),
      obligation(@thread_a),
      %{"source_actor_type" => "provider_system", "agent_group_id" => group_id}
    )

    {create_pid, _messages, _tools} = await_request!()

    SystemsRuntime.Proc.send(
      create_pid,
      {:reply_obligation_llm_response, task_create("create-for-bot", %{"test_auto_card" => true})}
    )

    settle_receive({:reply_obligation_task_create, ^agent_id, _args, task_create_pid})
    SystemsRuntime.Proc.send(task_create_pid, :reply_obligation_complete_task_create)

    {reply_pid, _messages, _tools} = await_request!()

    SystemsRuntime.Proc.send(
      reply_pid,
      {:reply_obligation_llm_response, slack_post("reply-bot", @thread_a)}
    )

    assert_slack_call!(agent_id, @thread_a)
    {wait_pid, _messages, _tools} = await_request!()

    SystemsRuntime.Proc.send(
      wait_pid,
      {:reply_obligation_llm_response, wait_for("wait-for-worker", 1800)}
    )

    waiting = await_waiting!(agent_id, session_id)
    assert ProviderReplyObligation.pending(SalixAgent.InternalSession.open(waiting)) == []
    settle_refute_receive({:reply_obligation_card_post, ^agent_id, _args}, 100)

    deliver!(
      agent_id,
      @source_b,
      slack_input(@thread_b, "B: a person asks a question"),
      obligation(@thread_b)
    )

    {b_pid, messages, _tools} = await_request!()
    assert request_text(messages) =~ "B: a person asks a question"
    current = read_session!(agent_id, session_id)
    assert Enum.any?(current.events, &(&1["kind"] == "provider_wait_yielded"))

    SystemsRuntime.Proc.send(
      b_pid,
      {:reply_obligation_llm_response, slack_post("answer-b", @thread_b)}
    )

    assert_slack_call!(agent_id, @thread_b, @source_b)
    {end_pid, _messages, _tools} = await_request!()
    SystemsRuntime.Proc.send(end_pid, {:reply_obligation_llm_response, end_turn("end-b")})
    await_source_settled!(agent_id, session_id, @source_b)
  end

  test "archive movement and restart preserve reply targets until explicit settlement" do
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
      SystemsRuntime.Task.async(fn ->
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

    settle_receive({:reply_obligation_task_create, _, _, pid})
    SystemsRuntime.Proc.send(pid, :reply_obligation_complete_task_create)
    settle_receive({:telegram_topic_open, _, %{"params" => params}})
    assert params["chat_id"] == "42001"
    assert params["conversation_id"] == CaptureSlack.task_conversation_id()
    assert [%{error: false, content: content}] = settled_await(task)
    assert Jason.decode!(content)["task_topic"]["status"] == "ready"
  end

  # A Task created for a Worker report or a schedule has no Slack source. It
  # must not take a person's Slack reply target, admitted later in the same
  # activation, as a card that nobody publishes. A person keeps the card rule.
  internal_origin = fn actor_type ->
    %{
      "provider" => "internal",
      "source_actor_type" => actor_type,
      "agent_group_id" => "test-group",
      "source_message_id" => "worker-report"
    }
  end

  for {label, origin, owes_card?} <- [
        {"a Worker report", internal_origin.("agent"), false},
        {"a schedule", nil, false},
        {"a Comma user", internal_origin.("user"), true},
        {"a provider user in a Task conversation", internal_origin.("provider_user"), true}
      ] do
    test "a Task created for #{label} #{if owes_card?, do: "keeps", else: "owes no"} Slack card candidate",
         context do
      ctx =
        %{
          agent_id: context.agent_id,
          session_id: context.session_id,
          group_id: "test-group",
          role: "router",
          runtime_kind: :internal,
          source_message_id: "worker-report",
          llm_tool_envelope: false,
          trusted_origin: unquote(Macro.escape(origin))
        }
        |> SalixAgent.TestSupport.with_plugin_projection()

      ctx =
        Map.put(
          ctx,
          :tool_disclosure,
          SalixAgent.ToolDisclosure.materialize("router", :internal, ctx)
        )

      args = %{"connect_id" => "internal", "test_auto_card" => true, "content" => "Follow up"}

      task =
        SystemsRuntime.Task.async(fn ->
          SalixAgent.SessionToolDispatch.execute(
            [%{id: "internal-create", name: "im_api.internal.task.create", args: args}],
            ctx
          )
        end)

      settle_receive({:reply_obligation_task_create, _, _, pid})
      SystemsRuntime.Proc.send(pid, :reply_obligation_complete_task_create)
      assert [%{error: false, content: content}] = settled_await(task)

      result = %{
        name: "im_api.internal.task.create",
        status: "completed",
        content: content,
        args: args
      }

      candidates = ProviderReplyObligation.card_obligation_events(context.session_id, result)

      if unquote(owes_card?) do
        refute Map.has_key?(Jason.decode!(content), "task_card")
        assert [%{"type" => "provider_card_obligation_added"}] = candidates
      else
        assert Jason.decode!(content)["task_card"]["status"] == "not_applicable"
        assert candidates == []
      end
    end
  end

  defp fresh_state(session_id),
    do: SalixAgent.InternalSession.export(SalixAgent.InternalSession.new("agent", session_id))

  # Seeds a pending reply target the way a materialized delivery leaves it.
  defp add_obligation(state, raw) do
    %{"key" => key} = target = SalixAgent.InternalSession.normalize_obligation(raw)
    obligations = Map.put(state.provider_reply_obligations || %{}, key, target)
    %{state | provider_reply_obligations: obligations}
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

  defp deliver_telegram!(
         agent_id,
         source,
         content,
         provider_message_id \\ nil,
         pre_deliveries \\ []
       ) do
    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: content,
                 pre_deliveries: pre_deliveries,
                 role: "user",
                 created_at: SystemsClock.system_time(:second),
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

  defp deliver!(agent_id, source_message_id, content, provider_reply_obligation, origin \\ %{}) do
    thread_ts = provider_reply_obligation["thread_ts"]

    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: content,
                 role: "user",
                 created_at: SystemsClock.system_time(:second),
                 provider_reply_obligation: provider_reply_obligation,
                 trusted_origin:
                   Map.merge(
                     %{
                       "provider" => "slack",
                       "source_actor_type" => "provider_user",
                       "source_message_id" => source_message_id,
                       "provider_context" => %{
                         "connect_id" => provider_reply_obligation["connect_id"],
                         "channel_id" => provider_reply_obligation["channel"],
                         "thread_ts" => thread_ts,
                         "message_ts" => thread_ts
                       }
                     },
                     origin
                   )
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
                 created_at: SystemsClock.system_time(:second),
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
                 created_at: SystemsClock.system_time(:second)
               },
               source_message_id: source_message_id
             )
  end

  defp await_request! do
    settle_receive({:reply_obligation_llm_request, pid, messages, tools})
    {pid, messages, tools}
  end

  defp assert_slack_call!(agent_id, thread_ts) do
    settle_receive(
      {:reply_obligation_slack_call, ^agent_id,
       %{
         "params" => %{
           "channel" => @channel,
           "thread_ts" => ^thread_ts
         }
       }}
    )
  end

  defp assert_slack_call!(agent_id, thread_ts, source_message_id) do
    settle_receive(
      {:reply_obligation_slack_call, ^agent_id,
       %{
         "params" => %{
           "channel" => @channel,
           "thread_ts" => ^thread_ts
         },
         "tool_context" => %{
           "source_message_id" => ^source_message_id,
           "source_message_ids" => [^source_message_id]
         }
       }}
    )
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

  defp await_settled!(agent_id, session_id) do
    settle_until(fn ->
      session = read_session!(agent_id, session_id)

      if session.status == :idle and session.messages != [] and
           session.last_ack_message_id == List.last(session.messages).id,
         do: session
    end)
  end

  defp await_source_settled!(agent_id, session_id, source_message_id) do
    settle_until(fn ->
      session = read_session!(agent_id, session_id)
      source = find_source_message!(session, source_message_id)

      if session.last_ack_message_id >= source.id and
           ProviderReplyObligation.pending_count(SalixAgent.InternalSession.open(session)) == 0,
         do: session
    end)
  end

  defp await_waiting!(agent_id, session_id) do
    settle_until(fn ->
      session = read_session!(agent_id, session_id)
      if get_in(session.wait || %{}, ["source"]) == "wait_for", do: session
    end)
  end

  defp put_or_delete_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
