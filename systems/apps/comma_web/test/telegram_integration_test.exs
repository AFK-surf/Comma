defmodule CommaWeb.TelegramIntegrationTest do
  use ExUnit.Case, async: false

  import Comma.WorkspaceTestSupport
  import Plug.Conn
  import Plug.Test

  alias SalixIM.TestSupport.BanditServer

  @router_opts CommaWeb.Router.init([])
  @webhook_secret "telegram-webhook-secret-32-bytes-long"

  defmodule TelegramAPI do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case {conn.method, conn.path_info} do
        {"GET", ["bot" <> _token, "getMe"]} ->
          if barrier = Application.get_env(:comma_web, :telegram_get_me_barrier) do
            send(barrier, {:get_me_paused, self()})

            receive do
              :continue_get_me -> :ok
            after
              5_000 -> raise "Telegram getMe test barrier timed out"
            end
          end

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => true,
              "result" => %{
                "id" => 900,
                "is_bot" => true,
                "first_name" => "Comma",
                "username" => "comma_product_bot"
              }
            })
          )

        {"POST", ["bot" <> _token, "sendMessage"]} ->
          send(Application.fetch_env!(:comma_web, :telegram_test_pid), :telegram_provider_sent)
          {:ok, raw, conn} = read_body(conn)

          send(
            Application.fetch_env!(:comma_web, :telegram_test_pid),
            {:telegram_message_sent, Jason.decode!(raw)}
          )

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 2}}))

        {"POST", ["bot" <> _token, "editMessageText"]} ->
          {:ok, raw, conn} = read_body(conn)

          send(
            Application.fetch_env!(:comma_web, :telegram_test_pid),
            {:telegram_card_edited, Jason.decode!(raw)}
          )

          {status, body} =
            Application.get_env(
              :comma_web,
              :telegram_edit_response,
              {200, %{"ok" => true, "result" => %{"message_id" => 2}}}
            )

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(body))

        {"POST", ["bot" <> _token, "answerCallbackQuery"]} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"ok" => true, "result" => true}))

        _other ->
          send_resp(conn, 404, "")
      end
    end
  end

  defmodule InteractionDelivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent_id, payload, opts) do
      send(
        Application.fetch_env!(:comma_web, :telegram_test_pid),
        {:interaction_input, agent_id, payload, opts}
      )

      {:ok, :queued}
    end
  end

  defmodule OIDCFake do
    @moduledoc false

    def exchange_authorization_code(code, opts) do
      send(Application.fetch_env!(:comma_web, :telegram_test_pid), {:oidc_exchange, code, opts})

      if code == "paused-code" do
        send(Application.fetch_env!(:comma_web, :telegram_test_pid), {:oidc_paused, self()})

        receive do
          :continue_oidc -> :ok
        after
          5_000 -> raise "OIDC test barrier timed out"
        end
      end

      claims = %{
        "sub" => "opaque-authentication-subject",
        "id" => if(code == "second-user", do: 42002, else: 42001),
        "preferred_username" => "alice"
      }

      {:ok, if(code == "missing-id", do: Map.delete(claims, "id"), else: claims)}
    end
  end

  defmodule BotFake do
    @moduledoc false

    def send_message(_token, chat_id, text) do
      send(
        Application.fetch_env!(:comma_web, :telegram_test_pid),
        {:telegram_message, chat_id, text}
      )

      {:ok, %{"message_id" => 1}}
    end

    def edit_device_view(_token, chat_id, message_id, text, buttons) do
      send(
        Application.fetch_env!(:comma_web, :telegram_test_pid),
        {:device_edited, chat_id, message_id, text, buttons}
      )

      {:ok, %{"message_id" => message_id}}
    end

    def answer_device_callback(_token, _id, _text), do: {:ok, true}

    def send_card(_token, chat_id, text, rows) do
      message_id = System.unique_integer([:positive])

      send(
        Application.fetch_env!(:comma_web, :telegram_test_pid),
        {:telegram_card, chat_id, message_id, text, rows}
      )

      {:ok, %{"message_id" => message_id}}
    end

    def edit_card(_token, chat_id, message_id, text, rows) do
      result =
        case Application.get_env(:comma_web, :telegram_card_edit_result) do
          fun when is_function(fun, 0) -> fun.()
          _ -> {:ok, %{"message_id" => message_id}}
        end

      send(
        Application.fetch_env!(:comma_web, :telegram_test_pid),
        {:telegram_card_edit, chat_id, message_id, text, rows}
      )

      result
    end

    def send_force_reply(_token, chat_id, text) do
      message_id = System.unique_integer([:positive])

      send(
        Application.fetch_env!(:comma_web, :telegram_test_pid),
        {:telegram_force_reply, chat_id, message_id, text}
      )

      {:ok, %{"message_id" => message_id}}
    end

    def get_me(_token), do: {:ok, %{"username" => "comma_product_bot"}}

    def send_task_links(_token, chat_id, text, buttons) do
      send(
        Application.fetch_env!(:comma_web, :telegram_test_pid),
        {:telegram_task_links, chat_id, text, buttons}
      )

      {:ok, %{"message_id" => 2}}
    end

    def verify_private_chat_access(_token, chat_id) do
      send(
        Application.fetch_env!(:comma_web, :telegram_test_pid),
        {:telegram_access_checked, chat_id}
      )

      Application.get_env(:comma_web, :telegram_access_result, {:ok, true})
    end

    def set_webhook(_token, _url, _secret), do: {:ok, true}

    def get_webhook_info(_token),
      do:
        Application.get_env(
          :comma_web,
          :telegram_webhook_info,
          {:ok,
           %{
             "url" => "https://comma.test/v1/comma/integrations/telegram/webhook",
             "allowed_updates" => ["message", "callback_query"]
           }}
        )
  end

  setup_all do
    unless Process.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    # 单跑也使用整组测试的严格隔离，防止 workspace convergence 绕过 Billing sandbox。
    :ok = Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)
    :ok
  end

  setup context do
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner) end)

    mode = if context[:multi_connection], do: :multi_connection, else: :transaction
    comma_owner = CommaWeb.TestRepoSandbox.start_owner!(mode)
    on_exit(fn -> CommaWeb.TestRepoSandbox.stop_owner(comma_owner) end)

    previous_s3 = Application.get_env(:salix_store, :s3_backend)
    previous_telegram = Application.get_env(:comma_web, :telegram)
    previous_test_pid = Application.get_env(:comma_web, :telegram_test_pid)
    previous_api_base = Application.get_env(:salix_im, :telegram_api_base_url)
    previous_barrier = Application.get_env(:comma_web, :telegram_get_me_barrier)

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, previous_s3)
      restore_env(:comma_web, :telegram, previous_telegram)
      restore_env(:comma_web, :telegram_test_pid, previous_test_pid)
      restore_env(:salix_im, :telegram_api_base_url, previous_api_base)
      restore_env(:comma_web, :telegram_get_me_barrier, previous_barrier)
    end)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    port = BanditServer.start!(fn port -> {Bandit, plug: TelegramAPI, port: port} end)
    Application.put_env(:salix_im, :telegram_api_base_url, "http://127.0.0.1:#{port}")
    Application.put_env(:comma_web, :telegram_test_pid, self())

    Application.put_env(:comma_web, :telegram,
      enabled: true,
      oidc_enabled: true,
      bot_token: "test-telegram-token",
      bot_username: "comma_product_bot",
      public_base_url: "https://comma.test",
      webhook_secret: @webhook_secret,
      client_id: "telegram-client",
      client_secret: "telegram-client-secret",
      bot_adapter: BotFake,
      oidc_adapter: OIDCFake
    )

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "telegram-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user, %{"name" => "Telegram Team"})
    {:ok, session} = Comma.Accounts.create_session(user["id"])

    %{session: session, user: user, workspace: workspace}
  end

  describe "Task review cards" do
    setup c do
      previous_adapter = Application.get_env(:salix_im, :task_status_personal_adapter)
      previous_delivery = Application.get_env(:salix_im, :agent_delivery_mod)
      Application.put_env(:salix_im, :task_status_personal_adapter, CommaWeb.TelegramTaskCards)
      Application.put_env(:salix_im, :agent_delivery_mod, InteractionDelivery)

      on_exit(fn ->
        restore_env(:salix_im, :task_status_personal_adapter, previous_adapter)
        restore_env(:salix_im, :agent_delivery_mod, previous_delivery)
      end)

      worker =
        SalixAgent.TestSupport.create_control_agent_in_group!(
          c.workspace["salix_tenant_id"],
          c.workspace["default_group_id"],
          %{"name" => "Card Worker", "role" => "worker"}
        )

      %{worker: worker}
    end

    test "the bound owner accepts a reviewed Task once from its card", c do
      assert complete_login(c.session, c.workspace).status == 200
      id = create_card_task(c, "Ship the launch notes")
      set_task(c, id, %{"status" => "ready_for_review"})

      assert_receive {:telegram_card, "42001", message_id, text, rows}, 3_000
      assert text =~ "Ship the launch notes"
      buttons = List.flatten(rows)
      assert Enum.all?(buttons, &(byte_size(&1["callback_data"] || "") <= 64))
      accept = Enum.find(buttons, &String.ends_with?(&1["callback_data"] || "", ":a"))
      changes = Enum.find(buttons, &String.ends_with?(&1["callback_data"] || "", ":r"))
      open = Enum.find(buttons, &Map.has_key?(&1, "web_app"))
      assert accept && changes && open
      assert open["web_app"]["url"] =~ "/task-panel.html?"
      assert open["web_app"]["url"] =~ "conversation_id=" <> id

      # A different Telegram user cannot act through the owner's card.
      card_click(accept["callback_data"], message_id, 999) |> expect_json(200)
      refute_receive {:telegram_card_edit, _, _, _, _}, 200
      assert task_status(c, id) == "ready_for_review"

      card_click(accept["callback_data"], message_id) |> expect_json(200)
      assert_receive {:telegram_card_edit, "42001", ^message_id, accepted, []}, 3_000
      assert accepted =~ "Ship the launch notes"
      assert task_status(c, id) == "completed"

      # A repeated click reports the same result without a second write.
      card_click(accept["callback_data"], message_id) |> expect_json(200)
      assert_receive {:telegram_card_edit, "42001", ^message_id, ^accepted, []}, 3_000
      assert task_status(c, id) == "completed"
    end

    test "a card for an older review version cannot complete the changed Task", c do
      assert complete_login(c.session, c.workspace).status == 200
      id = create_card_task(c, "Draft the plan")
      set_task(c, id, %{"status" => "ready_for_review"})
      assert_receive {:telegram_card, "42001", message_id, _text, rows}, 3_000
      accept = Enum.find(List.flatten(rows), &String.ends_with?(&1["callback_data"] || "", ":a"))

      # The Router may restate the status with other changes. A Task that
      # stays in review keeps its one card.
      set_task(c, id, %{"status" => "ready_for_review", "title" => "Draft the revised plan"})
      refute_receive {:telegram_card, "42001", _, _, _}, 2_000
      refute_receive {:telegram_card_edit, "42001", ^message_id, _, _}, 50
      card_click(accept["callback_data"], message_id) |> expect_json(200)

      assert_receive {:telegram_card_edit, "42001", ^message_id, text, rows}, 3_000
      assert text =~ "updated"
      assert Enum.all?(List.flatten(rows), &Map.has_key?(&1, "web_app"))
      assert task_status(c, id) == "ready_for_review"
    end

    @tag :card_regression
    test "a new review round sends a new card that accepts the revised Task", c do
      assert complete_login(c.session, c.workspace).status == 200
      issue_billing_grant(c.workspace)
      id = create_card_task(c, "Revise the plan")
      set_task(c, id, %{"status" => "ready_for_review"})
      assert_receive {:telegram_card, "42001", first_id, _, rows}, 3_000
      changes = Enum.find(List.flatten(rows), &String.ends_with?(&1["callback_data"] || "", ":r"))
      card_click(changes["callback_data"], first_id) |> expect_json(200)
      assert_receive {:telegram_force_reply, "42001", prompt_id, _}, 3_000

      webhook_request(reply_update(975, prompt_id, "Revise the conclusion"), @webhook_secret)
      |> expect_json(200)

      assert_receive {:telegram_message, "42001", "Sent to the Task."}, 3_000
      set_task(c, id, %{"status" => "active"})
      set_task(c, id, %{"status" => "ready_for_review"})
      assert_receive {:telegram_card, "42001", second_id, _, revised_rows}, 3_000
      assert second_id != first_id

      accept =
        Enum.find(List.flatten(revised_rows), &String.ends_with?(&1["callback_data"] || "", ":a"))

      card_click(accept["callback_data"], second_id) |> expect_json(200)
      assert task_status(c, id) == "completed"
    end

    @tag :card_regression
    test "a failed terminal edit retries the same card through delivery", c do
      assert complete_login(c.session, c.workspace).status == 200
      id = create_card_task(c, "Retire the card")
      set_task(c, id, %{"status" => "ready_for_review"})
      assert_receive {:telegram_card, "42001", message_id, _, _}, 3_000
      {:ok, attempts} = start_supervised({Agent, fn -> 0 end})
      previous_backoff = Application.get_env(:salix_im, :conversation_delivery_retry_backoff_ms)
      Application.put_env(:salix_im, :conversation_delivery_retry_backoff_ms, 10)

      on_exit(fn ->
        restore_env(:salix_im, :conversation_delivery_retry_backoff_ms, previous_backoff)
      end)

      previous = Application.get_env(:comma_web, :telegram_card_edit_result)
      on_exit(fn -> restore_env(:comma_web, :telegram_card_edit_result, previous) end)

      Application.put_env(:comma_web, :telegram_card_edit_result, fn ->
        Agent.get_and_update(attempts, fn
          0 -> {{:error, :telegram_unavailable}, 1}
          n -> {{:ok, %{"message_id" => message_id}}, n + 1}
        end)
      end)

      set_task(c, id, %{"status" => "cancelled"})
      assert_receive {:telegram_card_edit, "42001", ^message_id, text, []}, 3_000
      assert text =~ "Cancelled"
      assert_receive {:telegram_card_edit, "42001", ^message_id, ^text, []}, 5_000
      assert Agent.get(attempts, & &1) == 2
      refute_receive {:telegram_card, "42001", _, _, _}, 100
    end

    @tag :card_regression
    test "exhausted retirement keeps its failure without suppressing a later review", c do
      assert complete_login(c.session, c.workspace).status == 200
      id = create_card_task(c, "Review after outage")
      set_task(c, id, %{"status" => "ready_for_review"})
      assert_receive {:telegram_card, "42001", first_id, _, _}, 3_000
      previous = Application.get_env(:comma_web, :telegram_card_edit_result)
      previous_backoff = Application.get_env(:salix_im, :conversation_delivery_retry_backoff_ms)

      on_exit(fn ->
        restore_env(:comma_web, :telegram_card_edit_result, previous)
        restore_env(:salix_im, :conversation_delivery_retry_backoff_ms, previous_backoff)
      end)

      Application.put_env(:salix_im, :conversation_delivery_retry_backoff_ms, 10)

      Application.put_env(:comma_web, :telegram_card_edit_result, fn ->
        {:error, :telegram_unavailable}
      end)

      set_task(c, id, %{"status" => "active"})
      set_task(c, id, %{"status" => "ready_for_review"})
      assert_receive {:telegram_card, "42001", second_id, _, _}, 3_000
      assert second_id != first_id

      {:ok, %{"participants" => participants}} =
        SalixIM.Conversations.list_group_conversation_participants(
          c.workspace["default_group_id"],
          id
        )

      participant = Enum.find(participants, &(&1["role_label"] == "task_status_personal"))

      {:ok, %{"deliveries" => deliveries}} =
        SalixIM.Conversations.group_conversation_delivery_status(
          c.workspace["default_group_id"],
          id,
          participant_id: participant["participant_id"],
          limit: 10
        )

      assert Enum.any?(
               deliveries,
               &(&1["status"] == "failed" and get_in(&1, ["delivery", "attempts"]) == 3)
             )
    end

    test "requested changes reach the Task as the owner and never the Router", c do
      assert complete_login(c.session, c.workspace).status == 200
      assert_receive {:telegram_message, "42001", "Telegram is now connected" <> _}
      issue_billing_grant(c.workspace)
      worker_id = c.worker["agent_id"]
      router_id = c.workspace["router_agent_id"]
      id = create_card_task(c, "Write the intro")
      assert_receive {:interaction_input, ^worker_id, _, _}, 3_000
      set_task(c, id, %{"status" => "ready_for_review"})
      assert_receive {:telegram_card, "42001", message_id, _text, rows}, 3_000
      changes = Enum.find(List.flatten(rows), &String.ends_with?(&1["callback_data"] || "", ":r"))

      card_click(changes["callback_data"], message_id) |> expect_json(200)
      assert_receive {:telegram_force_reply, "42001", prompt_id, _prompt}, 3_000

      webhook_request(reply_update(971, prompt_id, "Use a shorter intro"), @webhook_secret)
      |> expect_json(200)

      assert_receive {:interaction_input, ^worker_id, %{content: "Use a shorter intro"} = payload,
                      _opts},
                     3_000

      # The owner's words enter the Task as a Comma user message, not as a
      # Telegram chat turn for the Router.
      assert payload.trusted_origin["provider"] == "internal"
      assert payload.trusted_origin["source_actor_type"] == "user"

      refute_receive {:interaction_input, ^router_id,
                      %{trusted_origin: %{"provider" => "telegram"}}, _},
                     200

      assert_receive {:telegram_message, "42001", "Sent to the Task."}, 3_000

      # A second reply to the same prompt is a new message, not a duplicate.
      webhook_request(reply_update(974, prompt_id, "Also add a title"), @webhook_secret)
      |> expect_json(200)

      assert_receive {:interaction_input, ^worker_id, %{content: "Also add a title"}, _}, 3_000
      assert_receive {:telegram_message, "42001", "Sent to the Task."}, 3_000

      # A reply to an unrelated message stays an ordinary Router message.
      webhook_request(reply_update(972, 123_456, "What else is due?"), @webhook_secret)
      |> expect_json(200)

      assert_receive {:interaction_input, ^router_id,
                      %{trusted_origin: %{"provider" => "telegram"}} = routed, _},
                     3_000

      assert inspect(routed) =~ "What else is due?"
    end

    test "an expired change prompt is not forwarded anywhere", c do
      assert complete_login(c.session, c.workspace).status == 200
      assert_receive {:telegram_message, "42001", "Telegram is now connected" <> _}
      id = create_card_task(c, "Fix the footer")
      set_task(c, id, %{"status" => "ready_for_review"})
      assert_receive {:telegram_card, "42001", message_id, _text, rows}, 3_000
      changes = Enum.find(List.flatten(rows), &String.ends_with?(&1["callback_data"] || "", ":r"))
      card_click(changes["callback_data"], message_id) |> expect_json(200)
      assert_receive {:telegram_force_reply, "42001", prompt_id, _prompt}, 3_000

      {:ok, _} =
        SalixStore.CasRecord.update(
          CommaWeb.TelegramTaskCards.prompt_key("42001", prompt_id),
          &Map.put(&1, "expires_at", 0)
        )

      webhook_request(reply_update(973, prompt_id, "Too late"), @webhook_secret)
      |> expect_json(200)

      assert_receive {:telegram_message, "42001", expired}, 3_000
      assert expired =~ "expired"
      refute_receive {:interaction_input, _, %{content: "Too late"}, _}, 200
      refute_receive {:interaction_input, _, %{content: "Too late" <> _}, _}, 50
    end

    test "a Workspace without a Telegram link creates Tasks without cards", c do
      id = create_card_task(c, "Unlinked task")

      {:ok, %{"participants" => participants}} =
        SalixIM.Conversations.list_group_conversation_participants(
          c.workspace["default_group_id"],
          id
        )

      refute Enum.any?(participants, &(&1["role_label"] == "task_status_personal"))
    end
  end

  test "background reminders wake only the Router, which replies through its ordinary tool", c do
    assert complete_login(c.session, c.workspace).status == 200
    previous = Application.get_env(:salix_im, :agent_delivery_mod)
    Application.put_env(:salix_im, :agent_delivery_mod, InteractionDelivery)
    on_exit(fn -> restore_env(:salix_im, :agent_delivery_mod, previous) end)
    group = c.workspace["default_group_id"]
    router = c.workspace["router_agent_id"]
    {:ok, home} = SalixIM.RouterConversationInput.ensure(group)
    home_id = home["conversation_id"]
    link = Comma.TelegramLinks.get_link(c.workspace["id"])

    target = %{
      "provider" => "telegram",
      "connect_id" => link.connect_id,
      "chat_id" => link.telegram_user_id,
      "chat_type" => "private"
    }

    assert {:ok, participant} =
             SalixIM.ConversationServer.ensure_group_conversation_provider_participant(
               group,
               home_id,
               SalixIM.ProviderConversationInput.provider_participant(target, %{
                 "role_label" => "proactive_personal",
                 "notification_filter" => %{"messages" => "all", "statuses" => "none"}
               })
             )

    assert {:ok, _} =
             SalixIM.ConversationServer.append_group_conversation_message(group, home_id, %{
               "actor_type" => "agent",
               "agent_id" => router,
               "content" => [%{"type" => "text", "text" => "Earlier Router reply"}],
               "delivery_filter" => %{"participant_ids" => []}
             })

    command = %{
      "action" => "present",
      "automatic" => true,
      "key" => SalixIM.MailInteraction.key("internal", "delivery-pipeline"),
      "request_id" => "delivery-pipeline-present",
      "text" => "Review the delivery pipeline",
      "subject" => "Delivery pipeline",
      "account_id" => "internal",
      "thread_id" => "delivery-pipeline",
      "message_id" => "v1",
      "source_url" => "",
      "participant_ids" => [participant["participant_id"]]
    }

    assert {:ok, _} =
             SalixIM.ConversationServer.mail_interaction(
               group,
               home_id,
               c.user["id"],
               router,
               command
             )

    refute_receive {:telegram_message_sent, _}, 100
    {:ok, messages} = SalixIM.Conversations.list_group_conversation_messages(group, home_id)
    [event] = Enum.filter(messages, &is_map(&1["agent_input"]))
    assert event["actor_type"] == "system"
    assert event["delivery_filter"] == %{"participant_ids" => [home["router_participant_id"]]}
    assert SalixIM.ConversationMessage.visible_text(event) == ""

    {:ok, binding} =
      SalixIM.ConversationSource.binding(router, %{
        group_id: group,
        conversation_id: home_id,
        participant_id: home["router_participant_id"]
      })

    assert {:ok, %{payload: payload}} = SalixIM.ConversationSource.entry(binding, event)
    refute payload.no_wake
    assert payload.session_id == binding.session_id
    assert SalixAgent.IFC.principal(payload.trusted_origin) == {:comma_user, c.user["id"]}
    assert_receive {:interaction_input, ^router, delivered, _opts}, 3_000
    assert delivered.content =~ "Review the delivery pipeline"

    assert {:ok, _} =
             SalixIM.ConversationServer.mail_interaction(
               group,
               home_id,
               c.user["id"],
               router,
               command
             )

    refute_receive {:interaction_input, ^router, _, _}, 100

    assert {:ok, _} =
             SalixIM.Provider.call_api(router, "telegram", "telegram.send_message", %{
               "connect_id" => link.connect_id,
               "params" => %{
                 "chat_id" => link.telegram_user_id,
                 "text" => "Router decided to ask you"
               }
             })

    assert_receive {:telegram_message_sent, sent}, 3_000
    assert sent["text"] =~ "Router decided to ask you"
  end

  test "queued personal reminders cannot send even when attributed to the Router", c do
    assert complete_login(c.session, c.workspace).status == 200
    link = Comma.TelegramLinks.get_link(c.workspace["id"])

    for metadata <- [%{"proactive_owner" => c.user["id"]}, %{"proactive_automatic" => true}, %{}] do
      assert {:error, :router_reply_required, false} =
               SalixIM.ConversationDelivery.deliver(%{
                 "participant_actor_type" => "provider",
                 "participant_provider" => "telegram",
                 "participant_role_label" => "proactive_personal",
                 "source_actor_type" => "agent",
                 "source_agent_id" => c.workspace["router_agent_id"],
                 "agent_group_id" => c.workspace["default_group_id"],
                 "participant_payload" => %{
                   "connect_id" => link.connect_id,
                   "chat_id" => link.telegram_user_id
                 },
                 "message_content" => [%{"type" => "text", "text" => "Legacy reminder"}],
                 "message_metadata" => metadata
               })
    end

    refute_receive {:telegram_message_sent, _}, 100
  end

  test "a quoted private reply carries context and the linked owner's reminder authority", c do
    assert complete_login(c.session, c.workspace).status == 200
    previous = Application.get_env(:salix_im, :agent_delivery_mod)
    Application.put_env(:salix_im, :agent_delivery_mod, InteractionDelivery)
    on_exit(fn -> restore_env(:salix_im, :agent_delivery_mod, previous) end)

    update =
      private_update(7771, "Handled this invoice")
      |> put_in(["message", "reply_to_message"], %{
        "message_id" => 22,
        "text" => "Studio invoice $85"
      })

    webhook_request(update, @webhook_secret) |> expect_json(200)
    assert_receive {:interaction_input, agent, payload, _}, 2000
    assert inspect(payload) =~ "Handled this invoice"
    assert inspect(payload) =~ "Studio invoice $85"
    origin = payload[:trusted_origin] || payload["trusted_origin"]
    {:ok, facts} = SalixIM.GroupDirectory.scope_for_agent(agent)

    ctx = %{
      agent_id: agent,
      session_id: facts.agent["router_session_id"],
      group_id: c.workspace["default_group_id"],
      tenant_id: c.workspace["salix_tenant_id"],
      trusted_origin: origin
    }

    assert {:ok, _, owner} = CommaWeb.Proactive.scope(ctx)
    assert owner == c.user["id"]
    assert {:ok, state} = CommaWeb.Proactive.state(%{}, ctx)
    assert is_list(state["sources"])

    # The Router learns where a reminder it decided on also reaches the owner.
    link = Comma.TelegramLinks.get_link(c.workspace["id"])

    assert [
             %{
               "provider" => "telegram",
               "tool" => "im_api.telegram.send_message",
               "connect_id" => connect_id,
               "chat_id" => chat_id,
               "ready" => true
             }
           ] = state["personal_targets"]

    assert connect_id == link.connect_id
    assert chat_id == link.telegram_user_id
  end

  test "OIDC binds one private Telegram identity and disconnect retires it", %{
    session: session,
    workspace: workspace
  } do
    state =
      api_request(session, :get, telegram_path(workspace))
      |> expect_json(200)

    assert state["configured"]
    assert state["official_login_available"]
    assert state["link"] == nil
    assert state["bot_url"] == "https://t.me/comma_product_bot"

    assert complete_login(session, workspace).status == 200

    assert_receive {:telegram_message, "42001", confirmation}
    assert confirmation =~ "Telegram Team"

    linked =
      api_request(session, :get, telegram_path(workspace))
      |> expect_json(200)

    assert linked["pending_claim"] == nil
    assert linked["link"]["telegram_user_id"] == "42001"
    assert linked["link"]["telegram_username"] == "alice"

    {:ok, runtime_connects} =
      SalixIM.ProviderConnects.list_runtime_provider_connects(["telegram"])

    refute Enum.any?(runtime_connects, &(&1["managed_by"] == "comma_product"))

    {:ok, [tool_connect]} =
      SalixIM.ProviderConnects.list_tool_connects(workspace["default_group_id"], ["telegram"])

    connect_id = tool_connect["connect_id"]

    api_request(session, :delete, telegram_path(workspace), %{})
    |> expect_json(200)
    |> then(&assert &1["disconnected"])

    assert {:error, :not_found} =
             SalixIM.ProviderConnects.get_active_connect_by_id(
               workspace["default_group_id"],
               connect_id,
               "telegram"
             )
  end

  test "product callback webhook resumes the bound request once and rejects another sender", c do
    assert complete_login(c.session, c.workspace).status == 200
    link = Comma.TelegramLinks.get_link(c.workspace["id"])
    agent_id = c.workspace["router_agent_id"]
    {:ok, facts} = SalixIM.GroupDirectory.scope_for_agent(agent_id)

    scope = %{
      "agent_id" => agent_id,
      "session_id" => facts.agent["router_session_id"],
      "connect_id" => link.connect_id,
      "chat_id" => "42001",
      "message_thread_id" => "",
      "source_message_id" => "source-question"
    }

    ctx = %{
      agent_id: agent_id,
      session_id: scope["session_id"],
      role: "router",
      source_message_id: "source-question",
      source_message_ids: ["source-question", "meeting-context"],
      trusted_origin: %{
        "provider" => "telegram",
        "source_actor_type" => "provider_user",
        "source_message_id" => "source-question",
        "provider_context" => Map.put(scope, "message_id", "801")
      }
    }

    source_session =
      SalixAgent.InternalSession.new(agent_id, scope["session_id"], %{})
      |> SalixAgent.InternalSession.apply_events([
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 1,
          "role" => "user",
          "source_message_id" => ctx.source_message_id,
          "trusted_origin" => ctx.trusted_origin,
          "content" => "Ask a question"
        },
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 2,
          "role" => "user",
          "source_message_id" => "meeting-context",
          "no_wake" => true,
          "trusted_origin" => %{
            "provider" => "internal",
            "source_actor_type" => "provider_system"
          },
          "content" => "Both dates are available"
        }
      ])

    ctx = Map.put(ctx, :reply_source_scope, SalixAgent.TerminalReply.source_scope(source_session))

    assert CommaWeb.AgentTelegramInteraction.capabilities(ctx)["question"]
    refute CommaWeb.AgentTelegramInteraction.capabilities(ctx)["location"]

    entry = %{"name" => "location.request", "callable" => true, "helpable" => true}
    config = %{role: "router", tool_specs: [], tool_disclosure: %{"tools" => [entry]}}

    assert SalixAgent.PlatformCapabilities.scope_config(config, ctx).tool_disclosure["tools"] ==
             []

    stale = Map.put(ctx, :tool_disclosure, config.tool_disclosure)
    refute SalixAgent.ToolDisclosure.callable?(stale, "location.request")
    refute SalixAgent.ToolDisclosure.helpable?(stale, "location.request")

    assert {:error, :location_request_unavailable} =
             CommaWeb.AgentTelegramInteraction.request(
               %{},
               "location",
               %{"reason" => "Share location", "locale" => "en"},
               "stale-location"
             )

    refute_receive :telegram_provider_sent

    assert CommaWeb.AgentTelegramInteraction.capabilities(%{
             ctx
             | source_message_ids: ["source-question"]
           }) == %{}

    for origin <- [nil, %{"provider" => "internal", "source_actor_type" => "user"}] do
      ambiguous =
        SalixAgent.InternalSession.apply_events(source_session, [
          %{
            "type" => "delivery",
            "from_queue" => true,
            "message_id" => 3,
            "role" => "user",
            "source_message_id" => "other-input",
            "trusted_origin" => origin,
            "content" => "Another input"
          }
        ])

      assert CommaWeb.AgentTelegramInteraction.capabilities(%{
               ctx
               | source_message_ids: ctx.source_message_ids ++ ["other-input"],
                 reply_source_scope: SalixAgent.TerminalReply.source_scope(ambiguous)
             }) == %{}
    end

    previous_info = Application.get_env(:comma_web, :telegram_webhook_info)
    on_exit(fn -> restore_env(:comma_web, :telegram_webhook_info, previous_info) end)

    for info <- [
          {:ok,
           %{
             "url" => "https://comma.test/v1/comma/integrations/telegram/webhook",
             "allowed_updates" => ["message"]
           }},
          {:ok,
           %{
             "url" => "https://another.test/webhook",
             "allowed_updates" => ["message", "callback_query"]
           }},
          {:error, :telegram_unavailable}
        ] do
      Application.put_env(:comma_web, :telegram_webhook_info, info)
      assert CommaWeb.AgentTelegramInteraction.capabilities(ctx) == %{}
    end

    Application.delete_env(:comma_web, :telegram_webhook_info)

    assert CommaWeb.AgentTelegramInteraction.capabilities(%{ctx | session_id: "another-session"}) ==
             %{}

    scope = SalixAgent.TerminalReply.context(source_session, ctx, 3, 1)
    assert scope["eligible"]

    {:ok, result} =
      CommaWeb.AgentTelegramInteraction.request(
        scope,
        "question",
        %{"question" => "今天还是明天？", "choices" => ["今天", "明天"], "locale" => "zh-CN"},
        "native-product"
      )

    assert_receive {:telegram_message_sent,
                    %{
                      "text" => "今天还是明天？",
                      "reply_parameters" => %{"message_id" => "801"},
                      "reply_markup" => %{"inline_keyboard" => buttons}
                    }}

    assert hd(hd(buttons))["text"] == "今天"

    previous = Application.get_env(:salix_im, :agent_delivery_mod)
    Application.put_env(:salix_im, :agent_delivery_mod, InteractionDelivery)
    on_exit(fn -> restore_env(:salix_im, :agent_delivery_mod, previous) end)

    update = %{
      "update_id" => 801,
      "callback_query" => %{
        "id" => "callback-801",
        "data" => "ci:" <> result["request_id"] <> ":0",
        "from" => %{"id" => 42001, "is_bot" => false},
        "message" => %{"message_id" => 2, "chat" => %{"id" => 42001, "type" => "private"}}
      }
    }

    webhook_request(put_in(update, ["callback_query", "from", "id"], 999), @webhook_secret)
    |> expect_json(200)

    refute_receive {:interaction_input, _, _, _}
    refute_receive {:telegram_card_edited, _}
    webhook_request(update, @webhook_secret) |> expect_json(200)
    assert_receive {:interaction_input, ^agent_id, payload, opts}
    assert inspect(payload) =~ "今天"
    assert opts[:source_message_id] =~ result["request_id"]
    assert_receive {:telegram_card_edited, card}
    assert card["message_id"] == 2
    assert card["chat_id"] == "42001"
    assert String.ends_with?(card["text"], "✅ 已选择：今天")
    assert card["reply_markup"] == %{"inline_keyboard" => []}
    webhook_request(update, @webhook_secret) |> expect_json(200)
    assert_receive {:telegram_card_edited, ^card}
    refute_receive {:interaction_input, _, _, _}
  end

  test "callback webhook retries a saved decision after Router delivery is unavailable", c do
    assert complete_login(c.session, c.workspace).status == 200
    link = Comma.TelegramLinks.get_link(c.workspace["id"])
    agent_id = c.workspace["router_agent_id"]
    group_id = c.workspace["default_group_id"]
    {:ok, facts} = SalixIM.GroupDirectory.scope_for_agent(agent_id)

    scope = %{
      "agent_id" => agent_id,
      "session_id" => facts.agent["router_session_id"],
      "connect_id" => link.connect_id,
      "chat_id" => "42001",
      "message_thread_id" => "",
      "source_message_id" => "source-question-retry"
    }

    {:ok, result} =
      CommaWeb.AgentTelegramInteraction.request(
        scope,
        "question",
        %{"question" => "是否继续？", "choices" => ["继续", "取消"]},
        "native-product-retry"
      )

    update = %{
      "update_id" => 802,
      "callback_query" => %{
        "id" => "callback-802",
        "data" => "ci:" <> result["request_id"] <> ":0",
        "from" => %{"id" => 42001, "is_bot" => false},
        "message" => %{
          "message_id" => result["message_id"],
          "chat" => %{"id" => 42001, "type" => "private"}
        }
      }
    }

    previous = Application.get_env(:salix_im, :agent_delivery_mod)
    Application.put_env(:salix_im, :agent_delivery_mod, InteractionDelivery)
    on_exit(fn -> restore_env(:salix_im, :agent_delivery_mod, previous) end)

    {:ok, conversation} = SalixIM.RouterConversationInput.ensure(group_id)
    key = SalixStore.Keys.ctl_group_conversation(group_id, conversation["conversation_id"])
    :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :put, key})
    on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)

    webhook_request(update, @webhook_secret) |> expect_json(503)
    refute_receive {:interaction_input, _, _, _}
    refute_receive {:telegram_card_edited, _}

    assert {:ok, decided} = SalixStore.TelegramInteractions.get(group_id, result["request_id"])
    assert decided["status"] == "decided"
    assert decided["response"] == %{"status" => "answered", "answer" => "继续"}

    SalixStore.S3.Fake.clear_blackhole()
    webhook_request(update, @webhook_secret) |> expect_json(200)
    assert_receive {:interaction_input, ^agent_id, payload, opts}

    assert opts[:source_message_id] ==
             "im_provider:telegram:#{link.connect_id}:interaction:#{result["request_id"]}"

    assert inspect(payload) =~ "继续"
    assert {:ok, delivered} = SalixStore.TelegramInteractions.get(group_id, result["request_id"])
    assert delivered["status"] == "delivered"
    assert delivered["response"] == decided["response"]
    assert_receive {:telegram_card_edited, card}
    assert card["text"] == "是否继续？\n\n✅ Selected: 继续"
    assert card["reply_markup"] == %{"inline_keyboard" => []}

    webhook_request(update, @webhook_secret) |> expect_json(200)
    refute_receive {:interaction_input, _, _, _}
  end

  test "OIDC URL uses PKCE and callback state is single-use", %{
    session: session,
    workspace: workspace
  } do
    attempt =
      api_request(session, :post, telegram_path(workspace) <> "/connect", %{})
      |> expect_json(201)

    uri = URI.parse(attempt["authorization_url"])
    params = URI.decode_query(uri.query)

    assert uri.host == "oauth.telegram.org"
    assert params["scope"] == "openid profile telegram:bot_access"
    assert params["code_challenge_method"] == "S256"
    assert is_binary(params["code_challenge"])
    refute attempt["authorization_url"] =~ "private-pkce-verifier"

    response =
      :get
      |> conn(
        "/v1/comma/integrations/telegram/connect/callback?" <>
          URI.encode_query(%{"code" => "telegram-code", "state" => params["state"]})
      )
      |> call()

    assert response.status == 200
    assert response.resp_body =~ "Telegram connected"
    assert response.resp_body =~ ~s(data-status="connected")
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert [csp] = get_resp_header(response, "content-security-policy")
    assert csp =~ "default-src 'none'"
    assert csp =~ "frame-ancestors 'none'"
    assert response.resp_body =~ "comma://telegram/return?workspace_id=#{workspace["id"]}"
    refute response.resp_body =~ params["state"]
    assert Comma.TelegramLinks.get_link(workspace["id"]).telegram_user_id == "42001"

    assert_receive {:oidc_exchange, "telegram-code", opts}
    assert Keyword.fetch!(opts, :pkce_verifier) != params["state"]

    assert Keyword.fetch!(opts, :redirect_uri) ==
             "https://comma.test/v1/comma/integrations/telegram/connect/callback"

    replay =
      :get
      |> conn(
        "/v1/comma/integrations/telegram/connect/callback?" <>
          URI.encode_query(%{"code" => "telegram-code", "state" => params["state"]})
      )
      |> call()

    assert replay.status == 400
    assert replay.resp_body =~ "Telegram connection failed"
    assert replay.resp_body =~ "expired or is no longer active"
  end

  test "expired login explains how to restart without exchanging a code", %{
    session: session,
    workspace: workspace
  } do
    state = start_login(session, workspace)

    Comma.Repo.update_all(Comma.Data.TelegramOIDCAttempt,
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    response = login_callback(state)
    assert response.status == 400
    assert response.resp_body =~ ~s(data-status="expired")
    assert response.resp_body =~ "expired or is no longer active"
    assert response.resp_body =~ "start a new Telegram connection"
    refute response.resp_body =~ state
    refute_receive {:oidc_exchange, _, _}
    assert Comma.TelegramLinks.get_link(workspace["id"]) == nil
  end

  test "OIDC never falls back to the authentication subject when the Bot API id is missing", %{
    session: session,
    workspace: workspace
  } do
    attempt =
      api_request(session, :post, telegram_path(workspace) <> "/connect", %{}) |> expect_json(201)

    params =
      attempt["authorization_url"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert {:error, :invalid_telegram_identity} =
             CommaWeb.TelegramIntegration.complete_connect("missing-id", params["state"])

    assert is_nil(Comma.TelegramLinks.get_link(workspace["id"]))
    refute_receive {:telegram_message, _, _}
  end

  test "commands give deterministic guidance before and after binding without reaching the agent",
       %{
         session: session,
         workspace: workspace
       } do
    for {command, expected} <- [
          {"/start", "Welcome to Comma"},
          {"/help", "/disconnect"},
          {"/link", "sign in with Telegram"},
          {"/link a b", "sign in with Telegram"},
          {"/status", "not connected"},
          {"/made_up", "Unknown command"}
        ] do
      webhook_request(
        private_update(System.unique_integer([:positive]), command),
        @webhook_secret
      )
      |> expect_json(200)

      assert_receive {:telegram_message, "42001", text}
      assert text =~ expected
    end

    assert complete_login(session, workspace).status == 200
    assert_receive {:telegram_message, "42001", _confirmation}

    for {command, expected} <- [
          {"/start", "Welcome to Comma"},
          {"/help@comma_product_bot", "/status"},
          {"/link", "sign in with Telegram"},
          {"/status", "Telegram Team"},
          {"/disconnect extra", "invalid arguments"},
          {"/unknown", "Unknown command"}
        ] do
      webhook_request(
        private_update(System.unique_integer([:positive]), command),
        @webhook_secret
      )
      |> expect_json(200)

      assert_receive {:telegram_message, "42001", text}
      assert text =~ expected
    end

    webhook_request(private_update(902, "/disconnect@another_bot"), @webhook_secret)
    |> expect_json(200)

    assert Comma.TelegramLinks.get_link(workspace["id"])
    refute_receive {:telegram_message, _, _}
    refute_receive :telegram_provider_sent

    webhook_request(private_update(903, "/disconnect@COMMA_PRODUCT_BOT"), @webhook_secret)
    |> expect_json(200)

    assert_receive {:telegram_message, "42001", "Telegram has been disconnected from Comma."}
    refute Comma.TelegramLinks.get_link(workspace["id"])
  end

  test "legacy codes and Start payloads cannot bind; claim endpoint is removed", %{
    user: user,
    session: session,
    workspace: workspace
  } do
    # Model a still-valid code issued before this release. Neither webhook
    # command may consume it or mutate an existing OIDC binding.
    assert {:ok, _, claim} = Comma.TelegramLinks.create_claim(user, session, workspace["id"])

    state = api_request(session, :get, telegram_path(workspace)) |> expect_json(200)
    assert state["pending_claim"] == nil

    assert api_request(session, :post, telegram_path(workspace) <> "/claim-code", %{}).status ==
             404

    for command <- ["/link " <> claim.code, "/start link_" <> claim.code] do
      webhook_request(
        private_update(System.unique_integer([:positive]), command),
        @webhook_secret
      )
      |> expect_json(200)

      assert_receive {:telegram_message, "42001", guidance}
      assert guidance =~ "sign in with Telegram"
      assert is_nil(Comma.TelegramLinks.get_link(workspace["id"]))
    end

    assert complete_login(session, workspace).status == 200
    original = Comma.TelegramLinks.get_link(workspace["id"])

    for command <- ["/link " <> claim.code, "/start link_" <> claim.code] do
      private_update(System.unique_integer([:positive]), command)
      |> put_in(["message", "chat", "id"], 42_002)
      |> put_in(["message", "from", "id"], 42_002)
      |> webhook_request(@webhook_secret)
      |> expect_json(200)

      assert Comma.TelegramLinks.get_link(workspace["id"]).connect_id == original.connect_id
    end
  end

  test "cancelling a stale OIDC attempt cannot remove a newer attempt", %{
    session: session,
    workspace: workspace
  } do
    old = start_login(session, workspace)
    current = start_login(session, workspace)

    api_request(session, :delete, telegram_path(workspace) <> "/connect", %{"state" => old})
    |> expect_json(200)

    assert login_callback(current).status == 200
  end

  test "OIDC bot access failure does not publish a binding", %{
    session: session,
    workspace: workspace
  } do
    Application.put_env(
      :comma_web,
      :telegram_access_result,
      {:error, {:telegram_http_error, 403}}
    )

    on_exit(fn -> Application.delete_env(:comma_web, :telegram_access_result) end)

    attempt =
      api_request(session, :post, telegram_path(workspace) <> "/connect", %{}) |> expect_json(201)

    params =
      attempt["authorization_url"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert {:error, {:telegram_http_error, 403}} =
             CommaWeb.TelegramIntegration.complete_connect("telegram-code", params["state"])

    assert_receive {:telegram_access_checked, "42001"}
    assert is_nil(Comma.TelegramLinks.get_link(workspace["id"]))
    refute_receive {:telegram_message, _, _}
  end

  test "cancel fences an OIDC callback already exchanging its authorization code", %{
    session: session,
    workspace: workspace
  } do
    attempt =
      api_request(session, :post, telegram_path(workspace) <> "/connect", %{}) |> expect_json(201)

    params =
      attempt["authorization_url"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    callback =
      Task.async(fn ->
        CommaWeb.TelegramIntegration.complete_connect("paused-code", params["state"])
      end)

    assert_receive {:oidc_paused, process}

    api_request(session, :delete, telegram_path(workspace) <> "/connect", %{
      "state" => params["state"]
    })
    |> expect_json(200)

    send(process, :continue_oidc)
    assert {:error, :invalid_telegram_connection_attempt} = Task.await(callback)
    assert is_nil(Comma.TelegramLinks.get_link(workspace["id"]))
  end

  test "device refresh accepts unchanged Telegram content but retains other failures" do
    config = Application.fetch_env!(:comma_web, :telegram)

    Application.put_env(
      :comma_web,
      :telegram,
      Keyword.put(
        config,
        :api_base_url,
        Application.fetch_env!(:salix_im, :telegram_api_base_url)
      )
    )

    on_exit(fn -> Application.delete_env(:comma_web, :telegram_edit_response) end)

    Application.put_env(
      :comma_web,
      :telegram_edit_response,
      {400,
       %{
         "ok" => false,
         "error_code" => 400,
         "description" => "Bad Request: message is not modified"
       }}
    )

    assert {:ok, :unchanged} =
             CommaWeb.TelegramBot.Req.edit_device_view("test", "42001", 2, "same", [])

    Application.put_env(
      :comma_web,
      :telegram_edit_response,
      {400,
       %{
         "ok" => false,
         "error_code" => 400,
         "description" => "Bad Request: message to edit not found"
       }}
    )

    assert {:error, {:telegram_http_error, 400}} =
             CommaWeb.TelegramBot.Req.edit_device_view("test", "42001", 2, "same", [])
  end

  test "device browsing reauthorizes clicks, pages bounded lists and rejects stale choices", c do
    assert complete_login(c.session, c.workspace).status == 200
    assert_receive {:telegram_message, "42001", "Telegram is now connected" <> _}

    for i <- 1..7 do
      {:ok, token} =
        SalixEnv.ConnectorTokens.create_group_connector_token(
          c.workspace["default_group_id"],
          c.workspace["salix_tenant_id"],
          %{}
        )

      {:ok, _} =
        Comma.Devices.rename(c.user, %{}, c.workspace["id"], token["device_id"], %{
          "name" => "Desk #{i}"
        })
    end

    webhook_request(private_update(961, "/devices"), @webhook_secret) |> expect_json(200)
    assert_receive {:telegram_task_links, "42001", text, buttons}
    assert text =~ "Read at"
    assert Enum.all?(buttons, &Map.has_key?(&1, "callback_data"))
    choices = Enum.filter(buttons, &Map.has_key?(&1, "callback_data"))
    assert length(choices) == 8
    assert Enum.all?(choices, &(byte_size(&1["callback_data"]) <= 64))
    [first | _] = choices

    callback = fn data ->
      %{
        "update_id" => 962,
        "callback_query" => %{
          "id" => "device-click",
          "data" => data,
          "from" => %{"id" => 42001},
          "message" => %{"message_id" => 2, "chat" => %{"id" => 42001, "type" => "private"}}
        }
      }
    end

    webhook_request(callback.(first["callback_data"]), @webhook_secret) |> expect_json(200)
    assert_receive {:device_edited, "42001", 2, detail, detail_buttons}
    assert Enum.all?(detail_buttons, &Map.has_key?(&1, "callback_data"))
    assert detail =~ "Device operations"
    assert detail =~ String.replace_prefix(first["text"], "1. ", "")
    refresh = Enum.find(detail_buttons, &(&1["text"] == "Refresh details"))
    webhook_request(callback.(refresh["callback_data"]), @webhook_secret) |> expect_json(200)
    assert_receive {:device_edited, "42001", 2, refreshed, detail_buttons}
    assert refreshed =~ "Device operations"
    back = Enum.find(detail_buttons, &(&1["text"] == "Device list / refresh"))
    webhook_request(callback.(back["callback_data"]), @webhook_secret) |> expect_json(200)
    assert_receive {:device_edited, "42001", 2, list, choices}
    assert list =~ "1. Desk"
    refute list =~ "Device operations"
    next = Enum.find(choices, &(&1["text"] == "Next page"))
    webhook_request(callback.(next["callback_data"]), @webhook_secret) |> expect_json(200)
    assert_receive {:device_edited, "42001", 2, _text, second}
    refute Enum.any?(second, &(&1["text"] == "Next page"))
    webhook_request(callback.(first["callback_data"]), @webhook_secret) |> expect_json(200)
    assert_receive {:telegram_message, "42001", expired}
    assert expired =~ "expired"
    refute_receive {:device_edited, _, _, _, _}
    link = Comma.TelegramLinks.get_link(c.workspace["id"])

    key =
      "comma/chat_device_views/" <> Base.url_encode64(link.connect_id, padding: false) <> ".json"

    assert {:ok, _} = SalixStore.CasRecord.update(key, &Map.put(&1, "expires_at", 0))
    webhook_request(callback.(hd(second)["callback_data"]), @webhook_secret) |> expect_json(200)
    assert_receive {:telegram_message, "42001", ttl_expired}
    assert ttl_expired =~ "expired"
    refute_receive {:device_edited, _, _, _, _}

    api_request(c.session, :delete, telegram_path(c.workspace)) |> expect_json(200)
    webhook_request(callback.(hd(second)["callback_data"]), @webhook_secret) |> expect_json(200)
    assert_receive {:telegram_message, "42001", unlinked}
    assert unlinked =~ "not connected"
    refute_receive {:device_edited, _, _, _, _}
  end

  test "tasks command reads canonical Tasks only from the bound workspace", %{
    session: session,
    workspace: workspace
  } do
    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    {:ok, task} =
      SalixCluster.TaskSchedules.create_task_conversation(
        workspace["default_group_id"],
        workspace["router_agent_id"],
        workspace["default_worker_agent_id"],
        %{
          "title" => "Review Telegram design",
          "content" => "Review the binding UI",
          "client_request_id" => "telegram-tasks-test"
        }
      )

    assert complete_login(session, workspace).status == 200
    webhook_request(private_update(951, "/tasks"), @webhook_secret) |> expect_json(200)

    assert_receive {:telegram_card, "42001", _message_id, text,
                    [
                      [%{"text" => "1", "web_app" => %{"url" => url}}],
                      [%{"text" => "All tasks", "web_app" => %{"url" => all_url}}]
                    ]}

    assert text =~ "Telegram Team"
    assert text =~ "1. 🔄 Review Telegram design"

    uri = URI.parse(url)

    assert URI.to_string(%{uri | path: nil, query: nil}) ==
             Application.fetch_env!(:comma_web, :web_cookie_origin)

    assert uri.path == "/task-panel.html"

    assert URI.decode_query(uri.query) == %{
             "group_id" => workspace["default_group_id"],
             "conversation_id" => task["conversation_id"],
             "workspace_id" => workspace["id"],
             "source" => "telegram"
           }

    refute url =~ "token"

    assert URI.decode_query(URI.parse(all_url).query) == %{
             "group_id" => workspace["default_group_id"],
             "workspace_id" => workspace["id"],
             "source" => "telegram"
           }

    refute all_url =~ "token"
  end

  test "a retained binding with a retired provider connection is not reported as active", %{
    session: session,
    workspace: workspace
  } do
    assert complete_login(session, workspace).status == 200
    linked = api_request(session, :get, telegram_path(workspace)) |> expect_json(200)
    assert linked["connection_active"]
    link = Comma.TelegramLinks.get_link(workspace["id"])

    assert :ok =
             SalixIM.ProviderConnects.delete_im_connect(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               link.connect_id
             )

    state = api_request(session, :get, telegram_path(workspace)) |> expect_json(200)
    assert state["link"]["telegram_user_id"] == "42001"
    refute state["connection_active"]
  end

  test "signed Mini App data issues only a short Task-panel cookie and revocation stops reads", %{
    session: session,
    workspace: workspace
  } do
    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    group_id = workspace["default_group_id"]

    {:ok, task} =
      SalixCluster.TaskSchedules.create_task_conversation(
        group_id,
        workspace["router_agent_id"],
        workspace["default_worker_agent_id"],
        %{
          "title" => "Verified Telegram Task",
          "content" => "Check the Task panel",
          "client_request_id" => "telegram-miniapp-auth-test"
        }
      )

    assert complete_login(session, workspace).status == 200
    login = miniapp_login(group_id, signed_init_data(42_001))
    projection = expect_json(login, 201)
    assert projection["user"]["id"] == session["user_id"]
    refute Map.has_key?(projection, "token")

    cookie = login.resp_cookies[CommaWeb.SessionCookie.panel_cookie_name()]
    refute Map.has_key?(login.resp_cookies, CommaWeb.SessionCookie.cookie_name())
    assert cookie.http_only
    assert cookie.secure
    assert cookie.same_site == "None"
    assert cookie.extra == "Partitioned"
    assert "comma_panel_" <> _ = cookie.value
    assert cookie.max_age > 15 * 60 and cookie.max_age <= 24 * 60 * 60

    assert %{"session_id" => session_id} =
             miniapp_cookie_request(:get, "/v1/comma/auth/session", cookie.value)
             |> expect_json(200)

    assert session_id == projection["session_id"]

    assert %{"data" => _} =
             miniapp_cookie_request(
               :get,
               "/v1/comma/groups/#{group_id}/conversations",
               cookie.value
             )
             |> expect_json(200)

    assert %{"id" => task_id} =
             miniapp_cookie_request(
               :get,
               "/v1/comma/groups/#{group_id}/conversations/#{task["conversation_id"]}/preview?include_worker=true",
               cookie.value
             )
             |> expect_json(200)

    assert task_id == task["conversation_id"]

    {:ok, router_chat} = SalixIM.RouterConversationInput.ensure(group_id)
    router_chat_id = router_chat["conversation_id"]

    assert api_request(
             session,
             :get,
             "/v1/comma/groups/#{group_id}/conversations/#{router_chat_id}"
           ).status ==
             200

    assert miniapp_cookie_request(
             :get,
             "/v1/comma/groups/#{group_id}/conversations/#{router_chat_id}",
             cookie.value
           ).status == 404

    assert miniapp_cookie_request(
             :get,
             "/v1/comma/groups/#{group_id}/conversations/#{router_chat_id}/messages/msg1/attachments/0",
             cookie.value
           ).status == 404

    assert miniapp_cookie_request(:get, "/v1/comma/workspaces", cookie.value).status == 401

    assert (:get
            |> conn("/v1/comma/workspaces")
            |> put_req_header(
              "cookie",
              "#{CommaWeb.SessionCookie.panel_cookie_name()}=#{session["token"]}"
            )
            |> miniapp_web_headers(session["id"])
            |> call()).status == 401

    assert miniapp_cookie_request(
             :get,
             "/v1/comma/groups/#{group_id}/conversations/search",
             cookie.value
           ).status ==
             401

    assert miniapp_cookie_request(
             :get,
             "/v1/comma/groups/#{group_id}/conversations/events",
             cookie.value
           ).status ==
             401

    assert miniapp_cookie_request(
             :post,
             "/v1/comma/groups/#{group_id}/conversations",
             cookie.value
           ).status ==
             401

    assert miniapp_cookie_request(
             :get,
             "/v1/comma/groups/another-group/conversations",
             cookie.value
           ).status ==
             401

    assert api_request(
             %{"token" => cookie.value},
             :get,
             "/v1/comma/groups/#{group_id}/conversations"
           ).status ==
             401

    old_connect_id = Comma.TelegramLinks.get_link(workspace["id"]).connect_id
    assert complete_login(session, workspace).status == 200
    link = Comma.TelegramLinks.get_link(workspace["id"])
    refute link.connect_id == old_connect_id
    assert miniapp_cookie_request(:get, "/v1/comma/auth/session", cookie.value).status == 401

    relogin = miniapp_login(group_id, signed_init_data(42_001), cookie.value)
    assert %{"session_id" => _} = expect_json(relogin, 201)
    new_cookie = relogin.resp_cookies[CommaWeb.SessionCookie.panel_cookie_name()].value
    refute new_cookie == cookie.value
    assert miniapp_cookie_request(:get, "/v1/comma/auth/session", new_cookie).status == 200

    comma_login =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "invalid"})
      |> miniapp_web_headers("none")
      |> put_req_header("cookie", "#{CommaWeb.SessionCookie.panel_cookie_name()}=#{new_cookie}")
      |> call()

    assert comma_login.status == 400
    assert comma_login.resp_cookies[CommaWeb.SessionCookie.panel_cookie_name()].max_age == 0

    assert :ok =
             SalixIM.ProviderConnects.delete_im_connect(
               workspace["salix_tenant_id"],
               group_id,
               link.connect_id
             )

    revoked = miniapp_cookie_request(:get, "/v1/comma/auth/session", new_cookie)
    assert revoked.status == 401
    assert revoked.resp_cookies[CommaWeb.SessionCookie.panel_cookie_name()].max_age == 0

    assert revoked.resp_cookies[CommaWeb.SessionCookie.panel_cookie_name()].extra ==
             "Partitioned"

    assert miniapp_login(group_id, signed_init_data(42_001)).status == 401
  end

  test "Mini App login rejects forged, stale, unbound, and wrong-account launches", %{
    session: session,
    workspace: workspace
  } do
    assert complete_login(session, workspace).status == 200
    group_id = workspace["default_group_id"]
    valid = signed_init_data(42_001)

    assert miniapp_login(group_id, valid <> "&user=forged").status == 401

    assert miniapp_login(group_id, signed_init_data(42_001, System.system_time(:second) - 121)).status ==
             401

    assert miniapp_login(group_id, signed_init_data(42_002)).status == 401
    assert miniapp_login("another-group", valid).status == 401

    existing = miniapp_login(group_id, valid, session["token"])
    assert expect_json(existing, 200)["session_id"] == session["id"]
    assert existing.resp_cookies == %{}

    non_web_request =
      :post
      |> json_conn("/v1/comma/auth/telegram-miniapp", %{
        "group_id" => group_id,
        "init_data" => valid
      })
      |> put_req_header("x-comma-session-transport", "bearer")
      |> call()

    assert non_web_request.status == 401
    assert non_web_request.resp_cookies == %{}

    {:ok, other_user} = Comma.Accounts.create_user(%{"email" => "other-telegram-web@comma.test"})
    {:ok, other_session} = Comma.Accounts.create_session(other_user["id"])
    conflict = miniapp_login(group_id, valid, other_session["token"])
    assert expect_json(conflict, 409) == %{"error" => "account_mismatch"}
    assert conflict.resp_cookies == %{}
  end

  test "Mini App exchange clears a revoked Comma cookie when it issues a panel cookie", %{
    session: session,
    workspace: workspace
  } do
    assert complete_login(session, workspace).status == 200
    assert :ok = Comma.Accounts.revoke_session_token(session["token"])

    login =
      miniapp_login(
        workspace["default_group_id"],
        signed_init_data(42_001),
        session["token"]
      )

    %{"session_id" => panel_session_id} = expect_json(login, 201)
    panel_cookie = login.resp_cookies[CommaWeb.SessionCookie.panel_cookie_name()].value
    user_cookie_name = CommaWeb.SessionCookie.cookie_name()
    panel_cookie_name = CommaWeb.SessionCookie.panel_cookie_name()

    user_cookies =
      case login.resp_cookies[user_cookie_name] do
        %{max_age: 0} -> []
        _ -> ["#{user_cookie_name}=#{session["token"]}"]
      end

    cookies = Enum.join(user_cookies ++ ["#{panel_cookie_name}=#{panel_cookie}"], "; ")

    read =
      :get
      |> conn("/v1/comma/auth/session")
      |> put_req_header("cookie", cookies)
      |> miniapp_web_headers(panel_session_id)
      |> call()

    assert read.status == 200
    assert login.resp_cookies[user_cookie_name].max_age == 0
    assert login.resp_cookies[user_cookie_name].same_site == "Lax"
    assert login.resp_cookies[user_cookie_name].path == "/"
    assert panel_session_id != session["id"]
  end

  test "Chinese command guidance follows Telegram's language code and ignores non-private input" do
    update = put_in(private_update(904, "/help")["message"]["from"]["language_code"], "zh-Hans")
    webhook_request(update, @webhook_secret) |> expect_json(200)
    assert_receive {:telegram_message, "42001", text}
    assert text =~ "欢迎使用 Comma"
    assert text =~ "消息渠道"
    assert text =~ "/disconnect"

    webhook_request(put_in(update["message"]["chat"]["type"], "group"), @webhook_secret)
    |> expect_json(200)

    refute_receive {:telegram_message, _, _}
  end

  test "webhook requires Telegram's secret header and ignores non-private chats", %{
    workspace: workspace
  } do
    webhook_request(private_update(201, "/status"), "wrong-secret")
    |> expect_json(401)

    group_update =
      private_update(202, "/link invalid")
      |> put_in(["message", "chat", "type"], "supergroup")

    webhook_request(group_update, @webhook_secret)
    |> expect_json(200)

    assert Comma.TelegramLinks.get_link(workspace["id"]) == nil
    refute_receive {:telegram_message, _, _}
  end

  test "disconnect fences an already exchanging OIDC callback", context do
    callback = paused_callback(context)
    assert_receive {:oidc_paused, callback_pid}, 2_000

    api_request(context.session, :delete, telegram_path(context.workspace), %{})
    |> expect_json(200)

    send(callback_pid, :continue_oidc)
    assert Task.await(callback).status == 400
    assert Comma.TelegramLinks.get_link(context.workspace["id"]) == nil
    refute_receive {:telegram_message, _, _}
  end

  test "new fallback intent fences an older OIDC callback", context do
    callback = paused_callback(context)
    assert_receive {:oidc_paused, callback_pid}, 2_000

    assert complete_login(context.session, context.workspace, "second-user").status == 200

    send(callback_pid, :continue_oidc)
    assert Task.await(callback).status == 400
    assert Comma.TelegramLinks.get_link(context.workspace["id"]).telegram_user_id == "42002"

    {:ok, [connect]} =
      SalixIM.ProviderConnects.list_tool_connects(
        context.workspace["default_group_id"],
        ["telegram"]
      )

    assert connect["connect_id"] ==
             Comma.TelegramLinks.get_link(context.workspace["id"]).connect_id
  end

  @tag multi_connection: true
  test "disconnect returns busy during prepare and a superseded prepare stays disabled",
       context do
    state = start_login(context.session, context.workspace)

    Application.put_env(:comma_web, :telegram_get_me_barrier, self())

    callback =
      Task.async(fn ->
        login_callback(state)
      end)

    assert_receive {:get_me_paused, provider_pid}, 2_000

    busy = api_request(context.session, :delete, telegram_path(context.workspace), %{})
    assert busy.status == 409

    cancel =
      api_request(context.session, :delete, telegram_path(context.workspace) <> "/connect", %{
        "state" => state
      })

    assert cancel.status == 409

    # A fresh user intent is a short, independent DB transaction; no provider
    # HTTP call holds a workspace row lock. The old prepare may finish, but
    # must not commit/activate after this supersession.
    api_request(context.session, :post, telegram_path(context.workspace) <> "/connect", %{})
    |> expect_json(201)

    send(provider_pid, :continue_get_me)
    assert Task.await(callback).status in 400..599
    assert Comma.TelegramLinks.get_link(context.workspace["id"]) == nil

    assert {:ok, []} =
             SalixIM.ProviderConnects.list_tool_connects(context.workspace["default_group_id"], [
               "telegram"
             ])
  end

  @tag multi_connection: true
  test "coordinator crash releases the database session lock", context do
    parent = self()

    {holder, monitor} =
      spawn_monitor(fn ->
        Comma.TelegramLinks.with_lifecycle_lock(fn ->
          send(parent, :lifecycle_locked)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :lifecycle_locked, 2_000

    assert {:error, :telegram_link_busy} =
             Comma.TelegramLinks.with_lifecycle_lock(fn -> :unexpected end)

    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}
    assert_lifecycle_unlocked(100)

    api_request(context.session, :delete, telegram_path(context.workspace), %{})
    |> expect_json(200)
  end

  test "a provider connect without a committed Comma binding cannot send", %{workspace: workspace} do
    assert {:ok, created} =
             SalixIM.ProviderConnects.ensure_managed_telegram_im_connect(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               %{"bot_token" => "test-telegram-token", "telegram_user_id" => "42001"}
             )

    assert {:error, _reason} =
             SalixIM.Provider.call_api(
               workspace["router_agent_id"],
               "telegram",
               "telegram.send_message",
               %{
                 "connect_id" => created["connect_id"],
                 "params" => %{"chat_id" => "42001", "text" => "must not leave Comma"}
               }
             )

    refute_receive :telegram_provider_sent

    assert {:error, _reason} =
             SalixIM.ProviderConnects.enable_im_connect(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               created["connect_id"]
             )
  end

  test "webhook setup is a dry-run unless the release command explicitly applies it" do
    assert {:ok, plan} = CommaWeb.TelegramWebhook.apply()
    assert plan["dry_run"]
    assert plan["webhook_url"] == "https://comma.test/v1/comma/integrations/telegram/webhook"

    assert {:ok, applied} = CommaWeb.TelegramWebhook.apply(dry_run: false)
    refute applied["dry_run"]
  end

  test "a retired managed connect cannot be updated or activated again", %{workspace: workspace} do
    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]

    assert {:ok, prepared} =
             SalixIM.ProviderConnects.ensure_managed_telegram_im_connect(
               tenant_id,
               group_id,
               %{"bot_token" => "test-telegram-token", "telegram_user_id" => "42001"}
             )

    connect_id = prepared["connect_id"]

    assert {:error, {:bad_request, _}} =
             SalixIM.ProviderConnects.update_telegram_im_connect(
               tenant_id,
               group_id,
               connect_id,
               %{"bot_token" => "replacement-token"}
             )

    assert :ok = SalixIM.ProviderConnects.delete_im_connect(tenant_id, group_id, connect_id)

    assert {:error, :not_found} =
             SalixIM.ProviderConnects.activate_managed_telegram_im_connect(
               tenant_id,
               group_id,
               connect_id
             )

    assert {:ok, []} = SalixIM.ProviderConnects.list_tool_connects(group_id, ["telegram"])
  end

  defp start_login(session, workspace) do
    attempt =
      api_request(session, :post, telegram_path(workspace) <> "/connect", %{}) |> expect_json(201)

    attempt["authorization_url"]
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("state")
  end

  defp login_callback(state, code \\ "telegram-code") do
    :get
    |> conn(
      "/v1/comma/integrations/telegram/connect/callback?" <>
        URI.encode_query(%{"code" => code, "state" => state})
    )
    |> call()
  end

  defp complete_login(session, workspace, code \\ "telegram-code"),
    do: session |> start_login(workspace) |> login_callback(code)

  defp telegram_path(workspace),
    do: "/v1/comma/workspaces/#{workspace["id"]}/integrations/telegram"

  defp assert_lifecycle_unlocked(0), do: flunk("database session lock survived coordinator death")

  defp assert_lifecycle_unlocked(attempts) do
    case Comma.TelegramLinks.with_lifecycle_lock(fn -> :unlocked end) do
      :unlocked ->
        :ok

      {:error, :telegram_link_busy} ->
        Process.sleep(10)
        assert_lifecycle_unlocked(attempts - 1)
    end
  end

  defp paused_callback(%{session: session, workspace: workspace}) do
    attempt =
      api_request(session, :post, telegram_path(workspace) <> "/connect", %{})
      |> expect_json(201)

    params =
      attempt["authorization_url"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    Task.async(fn ->
      :get
      |> conn(
        "/v1/comma/integrations/telegram/connect/callback?" <>
          URI.encode_query(%{"code" => "paused-code", "state" => params["state"]})
      )
      |> call()
    end)
  end

  defp api_request(session, method, path, body \\ nil) do
    conn = if is_nil(body), do: conn(method, path), else: json_conn(method, path, body)

    conn
    |> put_req_header("authorization", "Bearer #{session["token"]}")
    |> call()
  end

  defp webhook_request(update, secret) do
    :post
    |> json_conn("/v1/comma/integrations/telegram/webhook", update)
    |> put_req_header("x-telegram-bot-api-secret-token", secret)
    |> call()
  end

  defp miniapp_login(group_id, init_data, cookie_token \\ nil) do
    conn =
      :post
      |> json_conn("/v1/comma/auth/telegram-miniapp", %{
        "group_id" => group_id,
        "init_data" => init_data
      })
      |> miniapp_web_headers("unknown")

    conn =
      if cookie_token do
        cookie_name =
          if String.starts_with?(cookie_token, "comma_panel_"),
            do: CommaWeb.SessionCookie.panel_cookie_name(),
            else: CommaWeb.SessionCookie.cookie_name()

        put_req_header(conn, "cookie", "#{cookie_name}=#{cookie_token}")
      else
        conn
      end

    call(conn)
  end

  defp miniapp_cookie_request(method, path, cookie_token) do
    {:ok, _user, session} = Comma.Accounts.resolve_session(cookie_token)

    method
    |> conn(path)
    |> put_req_header("cookie", "#{CommaWeb.SessionCookie.panel_cookie_name()}=#{cookie_token}")
    |> miniapp_web_headers(session["id"])
    |> call()
  end

  defp miniapp_web_headers(conn, expected_session) do
    conn
    |> put_req_header("origin", Application.fetch_env!(:comma_web, :web_cookie_origin))
    |> put_req_header("x-comma-session-transport", "cookie")
    |> put_req_header("x-comma-session-lifecycle-version", "1")
    |> put_req_header("x-comma-expected-auth-session-id", expected_session)
  end

  defp signed_init_data(id, auth_date \\ System.system_time(:second)) do
    fields = %{
      "auth_date" => Integer.to_string(auth_date),
      "query_id" => "test-#{System.unique_integer([:positive])}",
      "user" => Jason.encode!(%{"id" => id, "first_name" => "Alice"})
    }

    check_string =
      fields
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {key, value} -> "#{key}=#{value}" end)

    secret = :crypto.mac(:hmac, :sha256, "WebAppData", "test-telegram-token")
    hash = :crypto.mac(:hmac, :sha256, secret, check_string) |> Base.encode16(case: :lower)
    URI.encode_query(Map.put(fields, "hash", hash))
  end

  defp private_update(update_id, text) do
    %{
      "update_id" => update_id,
      "message" => %{
        "message_id" => update_id,
        "text" => text,
        "chat" => %{"id" => 42_001, "type" => "private"},
        "from" => %{"id" => 42_001, "is_bot" => false, "username" => "alice"}
      }
    }
  end

  defp json_conn(method, path, body) do
    method
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
  end

  defp call(conn), do: CommaWeb.Router.call(conn, @router_opts)

  defp expect_json(conn, status) do
    assert conn.status == status, conn.resp_body
    Jason.decode!(conn.resp_body)
  end

  defp issue_billing_grant(%{"billing_account_id" => account_id, "id" => workspace_id}) do
    :ok =
      BillingCore.Accounts.ensure_account(%{
        repo: BillingCore.Repo,
        billing_account_id: account_id,
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: workspace_id
      })

    {:ok, _grant} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: account_id,
        credits: 100,
        valid_from: ~U[2026-06-17 00:00:00Z],
        expires_at: DateTime.add(DateTime.utc_now(), 30, :day),
        source_type: "manual_contract",
        source_id: "telegram-card-test:#{workspace_id}",
        source_event_id: "telegram-card-test:#{workspace_id}",
        idempotency_key: "telegram-card-test:#{workspace_id}"
      })

    :ok
  end

  defp create_card_task(c, title) do
    id = SalixStore.Ids.new_conversation_id()
    router = c.workspace["router_agent_id"]

    assert {:ok, _} =
             SalixIM.TaskConversationInput.create_with_id(
               c.workspace["default_group_id"],
               id,
               router,
               c.worker["agent_id"],
               %{
                 "title" => title,
                 "content" => "Work on " <> title,
                 "schedule" => %{"schedule_id" => nil, "command" => "Work on " <> title},
                 "workflow" => nil,
                 "initial_message_attrs" => %{
                   "kind" => "message",
                   "actor_type" => "agent",
                   "agent_id" => router,
                   "content" => "Work on " <> title
                 }
               }
             )

    id
  end

  defp set_task(c, id, changes) do
    assert {:ok, _} =
             SalixIM.Provider.call_api(
               c.workspace["router_agent_id"],
               "internal",
               "internal.update_conversation",
               %{"connect_id" => "internal", "params" => Map.put(changes, "conversation_id", id)}
             )
  end

  defp task_status(c, id) do
    {:ok, conversation} =
      SalixIM.Conversations.get_group_conversation(c.workspace["default_group_id"], id)

    conversation["status"]
  end

  defp card_click(data, message_id, from \\ 42_001) do
    webhook_request(
      %{
        "update_id" => System.unique_integer([:positive]),
        "callback_query" => %{
          "id" => "card-callback",
          "data" => data,
          "from" => %{"id" => from, "is_bot" => false, "language_code" => "en"},
          "message" => %{
            "message_id" => message_id,
            "chat" => %{"id" => from, "type" => "private"}
          }
        }
      },
      @webhook_secret
    )
  end

  defp reply_update(update_id, reply_to, text) do
    update = private_update(update_id, text)
    put_in(update, ["message", "reply_to_message"], %{"message_id" => reply_to})
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
