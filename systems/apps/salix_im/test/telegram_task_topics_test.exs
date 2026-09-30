defmodule SalixIM.TelegramTaskTopicsTest do
  use ExUnit.Case, async: false

  alias SalixIM.{
    Conversations,
    ProviderConnects,
    ProviderHTTP,
    TelegramTaskTopics
  }

  alias SalixStore.{Ids, S3}
  alias SalixIM.TestSupport.BanditServer

  defmodule API do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      {:ok, body, conn} = read_body(conn)
      params = if body == "", do: %{}, else: Jason.decode!(body)
      method = List.last(conn.path_info)
      send(Application.fetch_env!(:salix_im, :topic_test_pid), {:telegram, method, params})

      result =
        case method do
          "getMe" ->
            %{
              "id" => 900,
              "username" => "comma_test_bot",
              "is_bot" => true,
              "has_topics_enabled" => Application.get_env(:salix_im, :topic_test_enabled, true)
            }

          "createForumTopic" ->
            %{"message_thread_id" => System.unique_integer([:positive])}

          "sendMessage" ->
            %{"message_id" => System.unique_integer([:positive])}
        end

      {status, body} =
        if method == "createForumTopic" and
             Application.get_env(:salix_im, :topic_test_create_unknown, false),
           do: {500, %{"ok" => false, "description" => "upstream unavailable"}},
           else: {200, %{"ok" => true, "result" => result}}

      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end

  defmodule AgentDelivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent, payload, opts) do
      send(
        Application.fetch_env!(:salix_im, :topic_test_pid),
        {:agent_input, agent, payload, opts}
      )

      {:ok, :queued}
    end
  end

  setup do
    keys = [:s3_backend]
    previous = for key <- keys, do: {:salix_store, key, Application.get_env(:salix_store, key)}

    previous =
      previous ++
        for key <- [
              :conversation_placement,
              :agent_delivery_mod,
              :telegram_api_base_url,
              :topic_test_pid,
              :topic_test_enabled,
              :topic_test_create_unknown
            ],
            do: {:salix_im, key, Application.get_env(:salix_im, key)}

    SalixIM.TestSupport.Fleet.stop_all!()
    Application.put_env(:salix_store, :s3_backend, S3.Fake)

    Application.put_env(
      :salix_im,
      :conversation_placement,
      SalixIM.ConversationPlacement.LocalFleet
    )

    Application.put_env(:salix_im, :agent_delivery_mod, AgentDelivery)
    Application.put_env(:salix_im, :topic_test_pid, self())
    start_supervised!(S3.Fake)
    port = BanditServer.start!(fn port -> {Bandit, plug: API, port: port} end)
    Application.put_env(:salix_im, :telegram_api_base_url, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()

      for {app, key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group, %{"name" => "Topics"})

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "name" => "Router",
        "role" => "router"
      })

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "name" => "Worker",
        "role" => "worker"
      })

    {:ok, _} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group), fn current ->
        Map.put(current, "router_agent_id", router["agent_id"])
      end)

    {:ok, connect} =
      ProviderConnects.ensure_managed_telegram_im_connect(tenant, group, %{
        "bot_token" => "test",
        "telegram_user_id" => "42001"
      })

    :ok =
      ProviderConnects.activate_managed_telegram_im_connect(tenant, group, connect["connect_id"])

    {:ok, connect} =
      ProviderConnects.get_active_connect_by_id(group, connect["connect_id"], "telegram")

    %{
      tenant: tenant,
      group: group,
      router: router,
      worker: worker,
      connect: connect,
      scope: %{agent: router, agent_id: router["agent_id"], group_id: group}
    }
  end

  test "two Task topics route follow-ups and Worker replies without duplicate creation", ctx do
    first = create_task(ctx, "First")
    second = create_task(ctx, "Second")
    assert {:ok, a} = open(ctx, first)
    assert {:ok, b} = open(ctx, second)
    assert a["message_thread_id"] != b["message_thread_id"]
    assert_receive {:telegram, "createForumTopic", %{"name" => "First"}}
    assert_receive {:telegram, "createForumTopic", %{"name" => "Second"}}
    SalixIM.TestSupport.Fleet.stop_all!()
    assert {:ok, ^a} = open(ctx, first)
    refute_receive {:telegram, "createForumTopic", _}, 50

    update = update(a, 301, "Change only the first task")
    assert {:ok, :queued} = ProviderHTTP.handle_telegram_update(ctx.connect, update)
    assert {:ok, :duplicate} = ProviderHTTP.handle_telegram_update(ctx.connect, update)
    assert task_text(ctx.group, first) =~ "Change only the first task"
    refute task_text(ctx.group, second) =~ "Change only the first task"
    assert_worker_input(ctx.worker["agent_id"], "Change only the first task")

    assert {:ok, _} =
             SalixIM.Provider.call_api(
               ctx.worker["agent_id"],
               "internal",
               "internal.send_message",
               %{
                 "connect_id" => "internal",
                 "params" => %{
                   "conversation_id" => first,
                   "content" => [%{"type" => "text", "text" => "First task result"}],
                   "request_id" => "first-result"
                 }
               }
             )

    topic = a["message_thread_id"]

    assert_receive {:telegram, "sendMessage",
                    %{
                      "chat_id" => "42001",
                      "message_thread_id" => ^topic,
                      "text" => "First task result"
                    }},
                   3_000

    refute_receive {:telegram, "sendMessage", _}, 100
  end

  test "General messages share Router input without creating Task topics", ctx do
    for {id, text} <- [{351, "General first message"}, {352, "General continuation"}] do
      general = update(%{"message_thread_id" => "1"}, id, text)
      general = update_in(general["message"], &Map.delete(&1, "message_thread_id"))
      assert {:ok, :queued} = ProviderHTTP.handle_telegram_update(ctx.connect, general)
      assert_worker_input(ctx.router["agent_id"], text)
    end

    assert {:ok, %{"data" => []}} =
             Conversations.list_group_conversations(ctx.group, kind: "agent_task")

    refute_receive {:telegram, "createForumTopic", _}, 100
  end

  test "a bound Task routes ordinary turns to the Worker without Router echo", ctx do
    task = create_task(ctx, "Direct conversation")
    assert_worker_input(ctx.worker["agent_id"], "Work on Direct conversation")
    assert {:ok, binding} = open(ctx, task)
    router = ctx.router["agent_id"]
    topic = binding["message_thread_id"]

    assert {:ok, :queued} =
             ProviderHTTP.handle_telegram_update(
               ctx.connect,
               update(binding, 801, "Topic follow-up")
             )

    assert_worker_input(ctx.worker["agent_id"], "Topic follow-up")
    refute_receive {:agent_input, ^router, _, _}, 200

    send_task_message(ctx.worker, task, "Worker answer")

    assert_receive {:telegram, "sendMessage",
                    %{"message_thread_id" => ^topic, "text" => "Worker answer"}},
                   3_000

    refute_receive {:agent_input, ^router, _, _}, 200

    # Re-entering the same Task from Comma must use the same delivery policy,
    # including after the Conversation owner restarts.
    SalixIM.TestSupport.Fleet.stop_all!()

    assert {:ok, user} =
             SalixIM.ConversationServer.ensure_group_conversation_user_participant(
               ctx.group,
               task,
               %{"user_id" => "current"}
             )

    assert {:ok, _} =
             SalixIM.ConversationServer.append_group_conversation_message(ctx.group, task, %{
               "actor_type" => "user",
               "participant_id" => user["participant_id"],
               "user_id" => "current",
               "content" => "Comma follow-up"
             })

    assert_worker_input(ctx.worker["agent_id"], "Comma follow-up")

    assert_receive {:telegram, "sendMessage",
                    %{"message_thread_id" => ^topic, "text" => "Comma follow-up"}},
                   3_000

    refute_receive {:agent_input, ^router, _, _}, 200

    send_task_message(ctx.router, task, "Private work instruction")
    assert_worker_input(ctx.worker["agent_id"], "Private work instruction")
    refute_receive {:telegram, "sendMessage", _}, 200

    # Explicit escalation still reaches the delegator; only default broadcast
    # changes for the directly connected Task conversation.
    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(ctx.group, task)

    delegator = Enum.find(participants, &(&1["agent_id"] == router))

    send_task_message(ctx.worker, task, "Need Router help", %{
      "mentions" => %{"participant_ids" => [delegator["participant_id"]]}
    })

    assert_worker_input(router, "Need Router help")
    refute_receive {:telegram, "sendMessage", _}, 200
  end

  test "retiring a Topic connection restores default Worker delivery after owner restart", ctx do
    task = create_task(ctx, "Retired Topic")
    assert_worker_input(ctx.worker["agent_id"], "Work on Retired Topic")
    assert {:ok, _} = open(ctx, task)
    accepted = send_task_message(ctx.worker, task, "Accepted while connected")
    assert_receive {:telegram, "sendMessage", %{"text" => "Accepted while connected"}}, 3_000

    assert :ok =
             ProviderConnects.delete_im_connect(ctx.tenant, ctx.group, ctx.connect["connect_id"])

    SalixIM.TestSupport.Fleet.stop_all!()
    retry = send_task_message(ctx.worker, task, "Accepted while connected")
    assert retry["message_id"] == accepted["message_id"]
    refute retry["inserted"]
    router = ctx.router["agent_id"]
    refute_receive {:agent_input, ^router, _, _}, 200
    send_task_message(ctx.worker, task, "Result after disconnect")
    assert_worker_input(ctx.router["agent_id"], "Result after disconnect")
    refute_receive {:telegram, "sendMessage", _}, 200
  end

  test "a failed connection read does not guess delivery or accept the message", ctx do
    task = create_task(ctx, "Connection read")
    assert_worker_input(ctx.worker["agent_id"], "Work on Connection read")
    assert {:ok, _} = open(ctx, task)
    key = SalixStore.Keys.ctl_im_connect(ctx.group, ctx.connect["connect_id"])
    :ok = S3.Fake.set_fault({:fail, 503, :get, key})

    assert {:error, _} =
             SalixIM.Provider.call_api(
               ctx.worker["agent_id"],
               "internal",
               "internal.send_message",
               %{
                 "connect_id" => "internal",
                 "params" => %{
                   "conversation_id" => task,
                   "content" => [%{"type" => "text", "text" => "Retry connection read"}],
                   "request_id" => "Retry connection read"
                 }
               }
             )

    refute task_text(ctx.group, task) =~ "Retry connection read"
    result = send_task_message(ctx.worker, task, "Retry connection read")
    assert result["inserted"]
    assert_receive {:telegram, "sendMessage", %{"text" => "Retry connection read"}}, 3_000
    :ok = S3.Fake.set_fault({:fail, 503, :get, key})
    retry = send_task_message(ctx.worker, task, "Retry connection read")
    assert retry["message_id"] == result["message_id"]
    refute retry["inserted"]

    assert {:error, _} =
             ProviderConnects.get_active_connect_by_id(
               ctx.group,
               ctx.connect["connect_id"],
               "telegram"
             )

    router = ctx.router["agent_id"]
    refute_receive {:agent_input, ^router, _, _}, 200
  end

  test "a Task without a Topic still delivers Worker results to its delegator", ctx do
    task = create_task(ctx, "Ordinary Task")
    assert_worker_input(ctx.worker["agent_id"], "Work on Ordinary Task")
    send_task_message(ctx.worker, task, "Ordinary result")
    assert_worker_input(ctx.router["agent_id"], "Ordinary result")
  end

  test "attaching a Topic does not change an accepted message retry", ctx do
    task = create_task(ctx, "Retry")
    assert_worker_input(ctx.worker["agent_id"], "Work on Retry")
    first = send_task_message(ctx.worker, task, "Accepted before Topic")
    assert_worker_input(ctx.router["agent_id"], "Accepted before Topic")
    assert {:ok, _} = open(ctx, task)
    retry = send_task_message(ctx.worker, task, "Accepted before Topic")
    assert retry["message_id"] == first["message_id"]
    refute retry["inserted"]
    refute_receive {:telegram, "sendMessage", _}, 200
  end

  test "service events never execute work or change task lifecycle", ctx do
    task = create_task(ctx, "Keep working")
    {:ok, binding} = open(ctx, task)
    {:ok, before} = Conversations.get_group_conversation_record(ctx.group, task)

    event =
      update(binding, 401, "ignored")
      |> update_in(["message"], &(Map.delete(&1, "text") |> Map.put("forum_topic_closed", %{})))

    assert {:error, :ignored} = ProviderHTTP.handle_telegram_update(ctx.connect, event)
    {:ok, after_event} = Conversations.get_group_conversation_record(ctx.group, task)
    assert after_event["status"] == before["status"]
    assert after_event["message_tail_seq"] == before["message_tail_seq"]
  end

  test "wrong peer, Worker caller, and retired connection cannot open or continue a topic", ctx do
    task = create_task(ctx, "Private")

    assert {:error, _} =
             TelegramTaskTopics.open(ctx.scope, ctx.connect, %{
               "conversation_id" => task,
               "chat_id" => "42002"
             })

    assert {:error, _} =
             TelegramTaskTopics.open(
               %{ctx.scope | agent: ctx.worker, agent_id: ctx.worker["agent_id"]},
               ctx.connect,
               %{"conversation_id" => task, "chat_id" => "42001"}
             )

    refute_receive {:telegram, "createForumTopic", _}, 50
    {:ok, binding} = open(ctx, task)
    wrong = update(binding, 501, "private") |> put_in(["message", "from", "id"], 42002)
    assert {:error, :ignored} = ProviderHTTP.handle_telegram_update(ctx.connect, wrong)

    assert :ok =
             ProviderConnects.delete_im_connect(ctx.tenant, ctx.group, ctx.connect["connect_id"])

    assert {:error, _} = open(ctx, task)

    assert {:error, _} =
             ProviderHTTP.handle_telegram_update(ctx.connect, update(binding, 502, "retired"))

    refute task_text(ctx.group, task) =~ "retired"
  end

  test "reconnect cannot reroute an old Task topic into the Router", ctx do
    task = create_task(ctx, "Old connection")
    {:ok, binding} = open(ctx, task)
    :ok = ProviderConnects.delete_im_connect(ctx.tenant, ctx.group, ctx.connect["connect_id"])

    {:ok, next} =
      ProviderConnects.ensure_managed_telegram_im_connect(ctx.tenant, ctx.group, %{
        "bot_token" => "test",
        "telegram_user_id" => "42001"
      })

    :ok =
      ProviderConnects.activate_managed_telegram_im_connect(
        ctx.tenant,
        ctx.group,
        next["connect_id"]
      )

    {:ok, next} =
      ProviderConnects.get_active_connect_by_id(ctx.group, next["connect_id"], "telegram")

    assert next["connect_id"] != ctx.connect["connect_id"]

    assert {:error, :telegram_topic_forbidden} =
             ProviderHTTP.handle_telegram_update(next, update(binding, 601, "old topic"))

    refute task_text(ctx.group, task) =~ "old topic"
  end

  test "disabled topics leave the Task intact and allow setup after enabling", ctx do
    task = create_task(ctx, "Enable later")
    Application.put_env(:salix_im, :topic_test_enabled, false)
    assert {:error, _} = open(ctx, task)
    refute_receive {:telegram, "createForumTopic", _}, 50
    Application.put_env(:salix_im, :topic_test_enabled, true)
    assert {:ok, _} = open(ctx, task)
  end

  test "concurrent setup creates only one external topic", ctx do
    task = create_task(ctx, "Concurrent")
    callers = for _ <- 1..2, do: Task.async(fn -> open(ctx, task) end)
    results = Enum.map(callers, &Task.await(&1, 5_000))
    assert Enum.any?(results, &match?({:ok, _}, &1))
    assert_receive {:telegram, "createForumTopic", _}
    refute_receive {:telegram, "createForumTopic", _}, 100
    assert {:ok, _} = open(ctx, task)
    refute_receive {:telegram, "createForumTopic", _}, 50
  end

  test "uncertain creation never retries the external create", ctx do
    task = create_task(ctx, "Uncertain")
    Application.put_env(:salix_im, :topic_test_create_unknown, true)
    assert {:error, _} = open(ctx, task)
    assert_receive {:telegram, "createForumTopic", _}
    Application.put_env(:salix_im, :topic_test_create_unknown, false)
    SalixIM.TestSupport.Fleet.stop_all!()
    assert {:error, reason} = open(ctx, task)
    assert reason =~ "uncertain"
    refute_receive {:telegram, "createForumTopic", _}, 100

    assert {:ok, %{"kind" => "agent_task"}} =
             Conversations.get_group_conversation_record(ctx.group, task)
  end

  defp assert_worker_input(worker, text, attempts \\ 10)
  defp assert_worker_input(_, _, 0), do: flunk("Worker did not receive the topic follow-up")

  defp assert_worker_input(worker, text, attempts) do
    assert_receive {:agent_input, ^worker, payload, _}, 2_000

    if not String.contains?(inspect(payload[:content]), text),
      do: assert_worker_input(worker, text, attempts - 1)
  end

  defp create_task(ctx, title) do
    id = Ids.new_conversation_id()

    assert {:ok, _} =
             SalixIM.TaskConversationInput.create_with_id(
               ctx.group,
               id,
               ctx.router["agent_id"],
               ctx.worker["agent_id"],
               %{
                 "title" => title,
                 "content" => "Work on " <> title,
                 "schedule" => %{"schedule_id" => nil, "command" => "Work on " <> title},
                 "initial_message_attrs" => %{
                   "kind" => "message",
                   "actor_type" => "agent",
                   "agent_id" => ctx.router["agent_id"],
                   "content" => "Work on " <> title
                 }
               }
             )

    id
  end

  defp send_task_message(agent, task, text, extra \\ %{}) do
    assert {:ok, result} =
             SalixIM.Provider.call_api(agent["agent_id"], "internal", "internal.send_message", %{
               "connect_id" => "internal",
               "params" =>
                 Map.merge(
                   %{
                     "conversation_id" => task,
                     "content" => [%{"type" => "text", "text" => text}],
                     "request_id" => text
                   },
                   extra
                 )
             })

    result
  end

  defp open(ctx, id),
    do:
      TelegramTaskTopics.open(ctx.scope, ctx.connect, %{
        "chat_id" => "42001",
        "conversation_id" => id
      })

  defp update(binding, id, text),
    do: %{
      "update_id" => id,
      "message" => %{
        "message_id" => id,
        "chat" => %{"id" => 42001, "type" => "private"},
        "from" => %{"id" => 42001},
        "message_thread_id" => String.to_integer(binding["message_thread_id"]),
        "text" => text
      }
    }

  defp task_text(group, id) do
    {:ok, messages} = Conversations.list_group_conversation_messages(group, id, limit: 32)
    Enum.map_join(messages, "\n", &SalixIM.ConversationMessage.text_content(&1["content"]))
  end
end
