defmodule SalixIM.TelegramTaskStatusCardsTest do
  use ExUnit.Case, async: false

  alias SalixIM.{Conversations, ProviderConnects}
  alias SalixStore.{Ids, S3}
  alias SalixIM.TestSupport.BanditServer

  defmodule API do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      result = %{"id" => 900, "username" => "comma_test_bot", "is_bot" => true}

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"ok" => true, "result" => result}))
    end
  end

  defmodule Adapter do
    def task_status_targets(group_id) do
      case Application.get_env(:salix_im, :status_card_test_targets) do
        :raise -> raise "Comma binding lookup failed"
        fun when is_function(fun, 1) -> fun.(group_id)
        _ -> []
      end
    end

    def deliver(rec, connect) do
      send(Application.fetch_env!(:salix_im, :status_card_test_pid), {:deliver, rec, connect})
      Application.get_env(:salix_im, :status_card_test_result, {:ok, %{"message_id" => 77}})
    end
  end

  defmodule AgentDelivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(_agent, _payload, _opts), do: {:ok, :queued}
  end

  setup do
    previous =
      [{:salix_store, :s3_backend, Application.get_env(:salix_store, :s3_backend)}] ++
        for key <- [
              :conversation_placement,
              :agent_delivery_mod,
              :telegram_api_base_url,
              :task_status_personal_adapter,
              :status_card_test_pid,
              :status_card_test_targets,
              :status_card_test_result
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
    Application.put_env(:salix_im, :task_status_personal_adapter, Adapter)
    Application.put_env(:salix_im, :status_card_test_pid, self())
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
    SalixAgent.TestSupport.create_control_group!(group, %{"name" => "Status cards"})

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

    target = %{
      "provider" => "telegram",
      "connect_id" => connect["connect_id"],
      "chat_id" => "42001",
      "chat_type" => "private"
    }

    %{group: group, router: router, worker: worker, connect: connect, target: target}
  end

  test "a Task created for a bound owner subscribes its Telegram card to status changes only",
       ctx do
    Application.put_env(:salix_im, :status_card_test_targets, fn
      group when group == ctx.group -> [ctx.target]
      _other -> []
    end)

    id = create_task(ctx, "Draft launch notes")
    participant = status_participant(ctx.group, id)

    assert participant["provider"] == "telegram"
    assert participant["role_label"] == "task_status_personal"
    assert participant["payload"]["chat_id"] == "42001"
    assert participant["notification_filter"]["messages"] == "none"

    assert participant["notification_filter"]["statuses"] == "all"
  end

  test "a failing Comma binding lookup never blocks Task creation", ctx do
    Application.put_env(:salix_im, :status_card_test_targets, :raise)

    id = create_task(ctx, "Still created")

    assert {:ok, %{"kind" => "agent_task"}} = Conversations.get_group_conversation(ctx.group, id)
    assert status_participant(ctx.group, id) == nil
  end

  test "ready for review hands the status record to the Comma card adapter", ctx do
    Application.put_env(:salix_im, :status_card_test_targets, fn _ -> [ctx.target] end)
    id = create_task(ctx, "Review me")

    assert {:ok, _} =
             SalixIM.Provider.call_api(
               ctx.router["agent_id"],
               "internal",
               "internal.update_conversation",
               %{
                 "connect_id" => "internal",
                 "params" => %{"conversation_id" => id, "status" => "ready_for_review"}
               }
             )

    assert_receive {:deliver, %{"conversation_status" => "ready_for_review"} = rec, connect},
                   3_000

    assert rec["conversation_id"] == id
    assert rec["conversation_status"] == "ready_for_review"
    assert is_integer(rec["conversation_updated_at"])
    assert rec["participant_role_label"] == "task_status_personal"
    assert connect["connect_id"] == ctx.connect["connect_id"]
  end

  defp status_participant(group, id) do
    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(group, id)

    Enum.find(participants, &(&1["role_label"] == "task_status_personal"))
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
                 "workflow" => nil,
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
end
