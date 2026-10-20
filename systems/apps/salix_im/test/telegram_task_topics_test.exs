defmodule SalixIM.TelegramTaskTopicsTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle

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

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :topic_test_pid),
        {:telegram, method, params}
      )

      result =
        case method do
          "getMe" ->
            %{
              "id" => 900,
              "username" => "comma_test_bot",
              "is_bot" => true,
              "has_topics_enabled" => SystemsRuntime.get_env(:salix_im, :topic_test_enabled, true)
            }

          "createForumTopic" ->
            %{"message_thread_id" => SystemsRuntime.Proc.unique_integer([:positive])}

          "sendMessage" ->
            %{"message_id" => SystemsRuntime.Proc.unique_integer([:positive])}
        end

      {status, body} =
        if method == "createForumTopic" and
             SystemsRuntime.get_env(:salix_im, :topic_test_create_unknown, false),
           do: {500, %{"ok" => false, "description" => "upstream unavailable"}},
           else: {200, %{"ok" => true, "result" => result}}

      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end

  defmodule AgentDelivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent, payload, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :topic_test_pid),
        {:agent_input, agent, payload, opts}
      )

      {:ok, :queued}
    end
  end

  setup do
    keys = [:s3_backend]
    previous = for key <- keys, do: {:salix_store, key, SystemsRuntime.get_env(:salix_store, key)}

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
            do: {:salix_im, key, SystemsRuntime.get_env(:salix_im, key)}

    SalixIM.TestSupport.Fleet.stop_all!()
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    SystemsRuntime.put_env(
      :salix_im,
      :conversation_placement,
      SalixIM.ConversationPlacement.LocalFleet
    )

    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, AgentDelivery)
    SystemsRuntime.put_env(:salix_im, :topic_test_pid, SystemsRuntime.Proc.self())
    start_supervised!(S3.Fake)
    port = BanditServer.start!(fn port -> {Bandit, plug: API, port: port} end)
    SystemsRuntime.put_env(:salix_im, :telegram_api_base_url, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()

      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
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
    settle_receive({:telegram, "createForumTopic", %{"name" => "First"}})
    settle_receive({:telegram, "createForumTopic", %{"name" => "Second"}})
    SalixIM.TestSupport.Fleet.stop_all!()
    assert {:ok, ^a} = open(ctx, first)
    settle_refute_receive({:telegram, "createForumTopic", _}, 50)
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

    settle_receive(
      {:telegram, "sendMessage",
       %{
         "chat_id" => "42001",
         "message_thread_id" => ^topic,
         "text" => "First task result"
       }}
    )

    settle_refute_receive({:telegram, "sendMessage", _}, 100)
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

    settle_refute_receive({:telegram, "createForumTopic", _}, 50)
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

  defp assert_worker_input(worker, text, attempts \\ 10)
  defp assert_worker_input(_, _, 0), do: flunk("Worker did not receive the topic follow-up")

  defp assert_worker_input(worker, text, attempts) do
    settle_receive({:agent_input, ^worker, payload, _})

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
