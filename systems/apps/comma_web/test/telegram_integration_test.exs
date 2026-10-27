defmodule CommaWeb.TelegramIntegrationTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  require SystemsClock

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]
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
          if barrier = SystemsRuntime.get_env(:comma_web, :telegram_get_me_barrier) do
            SystemsRuntime.Proc.send(barrier, {:get_me_paused, SystemsRuntime.Proc.self()})

            SystemsClock.vreceive do
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
          SystemsRuntime.Proc.send(
            SystemsRuntime.fetch_env!(:comma_web, :telegram_test_pid),
            :telegram_provider_sent
          )

          {:ok, raw, conn} = read_body(conn)

          SystemsRuntime.Proc.send(
            SystemsRuntime.fetch_env!(:comma_web, :telegram_test_pid),
            {:telegram_message_sent, Jason.decode!(raw)}
          )

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 2}}))

        {"POST", ["bot" <> _token, "editMessageText"]} ->
          {:ok, raw, conn} = read_body(conn)

          SystemsRuntime.Proc.send(
            SystemsRuntime.fetch_env!(:comma_web, :telegram_test_pid),
            {:telegram_card_edited, Jason.decode!(raw)}
          )

          {status, body} =
            SystemsRuntime.get_env(
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
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :telegram_test_pid),
        {:interaction_input, agent_id, payload, opts}
      )

      {:ok, :queued}
    end
  end

  defmodule OIDCFake do
    @moduledoc false

    def exchange_authorization_code(code, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :telegram_test_pid),
        {:oidc_exchange, code, opts}
      )

      if code == "paused-code" do
        SystemsRuntime.Proc.send(
          SystemsRuntime.fetch_env!(:comma_web, :telegram_test_pid),
          {:oidc_paused, SystemsRuntime.Proc.self()}
        )

        SystemsClock.vreceive do
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
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :telegram_test_pid),
        {:telegram_message, chat_id, text}
      )

      {:ok, %{"message_id" => 1}}
    end

    def edit_device_view(_token, chat_id, message_id, text, buttons) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :telegram_test_pid),
        {:device_edited, chat_id, message_id, text, buttons}
      )

      {:ok, %{"message_id" => message_id}}
    end

    def answer_device_callback(_token, _id, _text), do: {:ok, true}

    def send_card(_token, chat_id, text, rows) do
      message_id = SystemsRuntime.Proc.unique_integer([:positive])

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :telegram_test_pid),
        {:telegram_card, chat_id, message_id, text, rows}
      )

      {:ok, %{"message_id" => message_id}}
    end

    def edit_card(_token, chat_id, message_id, text, rows) do
      result =
        case SystemsRuntime.get_env(:comma_web, :telegram_card_edit_result) do
          fun when is_function(fun, 0) -> fun.()
          _ -> {:ok, %{"message_id" => message_id}}
        end

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :telegram_test_pid),
        {:telegram_card_edit, chat_id, message_id, text, rows}
      )

      result
    end

    def send_force_reply(_token, chat_id, text) do
      message_id = SystemsRuntime.Proc.unique_integer([:positive])

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :telegram_test_pid),
        {:telegram_force_reply, chat_id, message_id, text}
      )

      {:ok, %{"message_id" => message_id}}
    end

    def get_me(_token), do: {:ok, %{"username" => "comma_product_bot"}}

    def send_task_links(_token, chat_id, text, buttons) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :telegram_test_pid),
        {:telegram_task_links, chat_id, text, buttons}
      )

      {:ok, %{"message_id" => 2}}
    end

    def verify_private_chat_access(_token, chat_id) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :telegram_test_pid),
        {:telegram_access_checked, chat_id}
      )

      SystemsRuntime.get_env(:comma_web, :telegram_access_result, {:ok, true})
    end

    def set_webhook(_token, _url, _secret), do: {:ok, true}

    def get_webhook_info(_token),
      do:
        SystemsRuntime.get_env(
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
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo) do
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

    previous_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_telegram = SystemsRuntime.get_env(:comma_web, :telegram)
    previous_test_pid = SystemsRuntime.get_env(:comma_web, :telegram_test_pid)
    previous_api_base = SystemsRuntime.get_env(:salix_im, :telegram_api_base_url)
    previous_barrier = SystemsRuntime.get_env(:comma_web, :telegram_get_me_barrier)

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, previous_s3)
      restore_env(:comma_web, :telegram, previous_telegram)
      restore_env(:comma_web, :telegram_test_pid, previous_test_pid)
      restore_env(:salix_im, :telegram_api_base_url, previous_api_base)
      restore_env(:comma_web, :telegram_get_me_barrier, previous_barrier)
    end)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    port = BanditServer.start!(fn port -> {Bandit, plug: TelegramAPI, port: port} end)
    SystemsRuntime.put_env(:salix_im, :telegram_api_base_url, "http://127.0.0.1:#{port}")
    SystemsRuntime.put_env(:comma_web, :telegram_test_pid, SystemsRuntime.Proc.self())

    SystemsRuntime.put_env(:comma_web, :telegram,
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
        "email" => "telegram-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace =
      user
      |> create_ready_workspace!(%{"name" => "Telegram Team"})
      |> CommaWeb.TestWorkers.with_default_worker!()

    {:ok, session} = Comma.Accounts.create_session(user["id"])

    %{session: session, user: user, workspace: workspace}
  end

  describe "Task review cards" do
    setup c do
      previous_adapter = SystemsRuntime.get_env(:salix_im, :task_status_personal_adapter)
      previous_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
      SystemsRuntime.put_env(:salix_im, :task_status_personal_adapter, CommaWeb.TelegramTaskCards)
      SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, InteractionDelivery)

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

      settle_receive({:telegram_card, "42001", message_id, text, rows})
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
      settle_refute_receive({:telegram_card_edit, _, _, _, _}, 200)
      assert task_status(c, id) == "ready_for_review"

      card_click(accept["callback_data"], message_id) |> expect_json(200)
      settle_receive({:telegram_card_edit, "42001", ^message_id, accepted, ended_rows})
      assert accepted =~ "Ship the launch notes"
      assert [[%{"callback_data" => "tr:" <> _}]] = ended_rows
      assert task_status(c, id) == "completed"

      # A repeated click reports the same result without a second write.
      card_click(accept["callback_data"], message_id) |> expect_json(200)
      settle_receive({:telegram_card_edit, "42001", ^message_id, ^accepted, ^ended_rows})
      assert task_status(c, id) == "completed"
    end

    test "Clear dismisses a settled Task from /tasks until it runs again", c do
      assert complete_login(c.session, c.workspace).status == 200
      id = create_card_task(c, "Draft the release post")
      set_task(c, id, %{"status" => "failed"})

      settle_receive({:telegram_card, "42001", message_id, _text, rows})
      clear = Enum.find(List.flatten(rows), &String.ends_with?(&1["callback_data"] || "", ":d"))
      assert clear["text"] == "Clear"

      # A different Telegram user cannot clear the owner's Task.
      card_click(clear["callback_data"], message_id, 999) |> expect_json(200)
      settle_refute_receive({:telegram_card_edit, _, _, _, _}, 200)
      assert {:ok, []} = Comma.TaskPanelDismissals.list(c.user["id"])

      card_click(clear["callback_data"], message_id) |> expect_json(200)
      settle_receive({:telegram_card_edit, "42001", ^message_id, cleared, []})
      assert cleared =~ "Cleared from your Task list"

      {:ok, task} =
        SalixIM.Conversations.get_group_conversation(c.workspace["default_group_id"], id)

      assert {:ok, [%{"task_id" => ^id, "revision" => revision}]} =
               Comma.TaskPanelDismissals.list(c.user["id"])

      assert revision == task["run_started_at"]

      webhook_request(private_update(961, "/tasks"), @webhook_secret) |> expect_json(200)
      settle_receive({:telegram_message, "42001", "No recent tasks" <> _})

      # The Task runs again: /tasks shows it without anyone lifting the dismissal.
      set_task(c, id, %{"status" => "active"})
      webhook_request(private_update(962, "/tasks"), @webhook_secret) |> expect_json(200)
      settle_receive({:telegram_card, "42001", _list_id, list, _keyboard})
      assert list =~ "Draft the release post"
    end

    test "requested changes reach the Task as the owner and never the Router", c do
      assert complete_login(c.session, c.workspace).status == 200
      settle_receive({:telegram_message, "42001", "Telegram is now connected" <> _})
      issue_billing_grant(c.workspace)
      worker_id = c.worker["agent_id"]
      router_id = c.workspace["router_agent_id"]
      id = create_card_task(c, "Write the intro")
      settle_receive({:interaction_input, ^worker_id, _, _})
      set_task(c, id, %{"status" => "ready_for_review"})
      settle_receive({:telegram_card, "42001", message_id, _text, rows})
      changes = Enum.find(List.flatten(rows), &String.ends_with?(&1["callback_data"] || "", ":r"))

      card_click(changes["callback_data"], message_id) |> expect_json(200)
      settle_receive({:telegram_force_reply, "42001", prompt_id, _prompt})

      webhook_request(reply_update(971, prompt_id, "Use a shorter intro"), @webhook_secret)
      |> expect_json(200)

      settle_receive(
        {:interaction_input, ^worker_id, %{content: "Use a shorter intro"} = payload, _opts}
      )

      # The owner's words enter the Task as a Comma user message, not as a
      # Telegram chat turn for the Router.
      assert payload.trusted_origin["provider"] == "internal"
      assert payload.trusted_origin["source_actor_type"] == "user"

      settle_refute_receive(
        {:interaction_input, ^router_id, %{trusted_origin: %{"provider" => "telegram"}}, _},
        200
      )

      settle_receive({:telegram_message, "42001", "Sent to the Task."})
      # A second reply to the same prompt is a new message, not a duplicate.
      webhook_request(reply_update(974, prompt_id, "Also add a title"), @webhook_secret)
      |> expect_json(200)

      settle_receive({:interaction_input, ^worker_id, %{content: "Also add a title"}, _})
      settle_receive({:telegram_message, "42001", "Sent to the Task."})
      # A reply to an unrelated message stays an ordinary Router message.
      webhook_request(reply_update(972, 123_456, "What else is due?"), @webhook_secret)
      |> expect_json(200)

      settle_receive(
        {:interaction_input, ^router_id, %{trusted_origin: %{"provider" => "telegram"}} = routed,
         _}
      )

      assert inspect(routed) =~ "What else is due?"
    end
  end

  test "background reminders wake only the Router, which replies through its ordinary tool", c do
    assert complete_login(c.session, c.workspace).status == 200
    previous = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, InteractionDelivery)
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

    settle_refute_receive({:telegram_message_sent, _}, 100)
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
    settle_receive({:interaction_input, ^router, delivered, _opts})
    assert delivered.content =~ "Review the delivery pipeline"

    assert {:ok, _} =
             SalixIM.ConversationServer.mail_interaction(
               group,
               home_id,
               c.user["id"],
               router,
               command
             )

    settle_refute_receive({:interaction_input, ^router, _, _}, 100)

    assert {:ok, _} =
             SalixIM.Provider.call_api(router, "telegram", "telegram.send_message", %{
               "connect_id" => link.connect_id,
               "params" => %{
                 "chat_id" => link.telegram_user_id,
                 "text" => "Router decided to ask you"
               }
             })

    settle_receive({:telegram_message_sent, sent})
    assert sent["text"] =~ "Router decided to ask you"
  end

  test "a quoted private reply carries context and the linked owner's reminder authority", c do
    assert complete_login(c.session, c.workspace).status == 200
    previous = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, InteractionDelivery)
    on_exit(fn -> restore_env(:salix_im, :agent_delivery_mod, previous) end)

    update =
      private_update(7771, "Handled this invoice")
      |> put_in(["message", "reply_to_message"], %{
        "message_id" => 22,
        "text" => "Studio invoice $85"
      })

    webhook_request(update, @webhook_secret) |> expect_json(200)
    settle_receive({:interaction_input, agent, payload, _})
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

    settle_receive({:telegram_message, "42001", confirmation})
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

    settle_refute_receive(:telegram_provider_sent)

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

    previous_info = SystemsRuntime.get_env(:comma_web, :telegram_webhook_info)
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
      SystemsRuntime.put_env(:comma_web, :telegram_webhook_info, info)
      assert CommaWeb.AgentTelegramInteraction.capabilities(ctx) == %{}
    end

    SystemsRuntime.delete_env(:comma_web, :telegram_webhook_info)

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

    settle_receive(
      {:telegram_message_sent,
       %{
         "text" => "今天还是明天？",
         "reply_parameters" => %{"message_id" => "801"},
         "reply_markup" => %{"inline_keyboard" => buttons}
       }}
    )

    assert hd(hd(buttons))["text"] == "今天"

    previous = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, InteractionDelivery)
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

    settle_refute_receive({:interaction_input, _, _, _})
    settle_refute_receive({:telegram_card_edited, _})
    webhook_request(update, @webhook_secret) |> expect_json(200)
    settle_receive({:interaction_input, ^agent_id, payload, opts})
    assert inspect(payload) =~ "今天"
    assert opts[:source_message_id] =~ result["request_id"]
    settle_receive({:telegram_card_edited, card})
    assert card["message_id"] == 2
    assert card["chat_id"] == "42001"
    assert String.ends_with?(card["text"], "✅ 已选择：今天")
    assert card["reply_markup"] == %{"inline_keyboard" => []}
    webhook_request(update, @webhook_secret) |> expect_json(200)
    settle_receive({:telegram_card_edited, ^card})
    settle_refute_receive({:interaction_input, _, _, _})
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

    previous = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, InteractionDelivery)
    on_exit(fn -> restore_env(:salix_im, :agent_delivery_mod, previous) end)

    {:ok, conversation} = SalixIM.RouterConversationInput.ensure(group_id)
    key = SalixStore.Keys.ctl_group_conversation(group_id, conversation["conversation_id"])
    :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :put, key})
    on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)

    webhook_request(update, @webhook_secret) |> expect_json(503)
    settle_refute_receive({:interaction_input, _, _, _})
    settle_refute_receive({:telegram_card_edited, _})
    assert {:ok, decided} = SalixStore.TelegramInteractions.get(group_id, result["request_id"])
    assert decided["status"] == "decided"
    assert decided["response"] == %{"status" => "answered", "answer" => "继续"}

    SalixStore.S3.Fake.clear_blackhole()
    webhook_request(update, @webhook_secret) |> expect_json(200)
    settle_receive({:interaction_input, ^agent_id, payload, opts})

    assert opts[:source_message_id] ==
             "im_provider:telegram:#{link.connect_id}:interaction:#{result["request_id"]}"

    assert inspect(payload) =~ "继续"
    assert {:ok, delivered} = SalixStore.TelegramInteractions.get(group_id, result["request_id"])
    assert delivered["status"] == "delivered"
    assert delivered["response"] == decided["response"]
    settle_receive({:telegram_card_edited, card})
    assert card["text"] == "是否继续？\n\n✅ Selected: 继续"
    assert card["reply_markup"] == %{"inline_keyboard" => []}

    webhook_request(update, @webhook_secret) |> expect_json(200)
    settle_refute_receive({:interaction_input, _, _, _})
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

    settle_receive({:oidc_exchange, "telegram-code", opts})
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
        private_update(SystemsRuntime.Proc.unique_integer([:positive]), command),
        @webhook_secret
      )
      |> expect_json(200)

      settle_receive({:telegram_message, "42001", text})
      assert text =~ expected
    end

    assert complete_login(session, workspace).status == 200
    settle_receive({:telegram_message, "42001", _confirmation})

    for {command, expected} <- [
          {"/start", "Welcome to Comma"},
          {"/help@comma_product_bot", "/status"},
          {"/link", "sign in with Telegram"},
          {"/status", "Telegram Team"},
          {"/disconnect extra", "invalid arguments"},
          {"/unknown", "Unknown command"}
        ] do
      webhook_request(
        private_update(SystemsRuntime.Proc.unique_integer([:positive]), command),
        @webhook_secret
      )
      |> expect_json(200)

      settle_receive({:telegram_message, "42001", text})
      assert text =~ expected
    end

    webhook_request(private_update(902, "/disconnect@another_bot"), @webhook_secret)
    |> expect_json(200)

    assert Comma.TelegramLinks.get_link(workspace["id"])
    settle_refute_receive({:telegram_message, _, _})
    settle_refute_receive(:telegram_provider_sent)

    webhook_request(private_update(903, "/disconnect@COMMA_PRODUCT_BOT"), @webhook_secret)
    |> expect_json(200)

    settle_receive({:telegram_message, "42001", "Telegram has been disconnected from Comma."})
    refute Comma.TelegramLinks.get_link(workspace["id"])
  end

  test "device browsing reauthorizes clicks, pages bounded lists and rejects stale choices", c do
    assert complete_login(c.session, c.workspace).status == 200
    settle_receive({:telegram_message, "42001", "Telegram is now connected" <> _})

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
    settle_receive({:telegram_task_links, "42001", text, buttons})
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
    settle_receive({:device_edited, "42001", 2, detail, detail_buttons})
    assert Enum.all?(detail_buttons, &Map.has_key?(&1, "callback_data"))
    assert detail =~ "Device operations"
    assert detail =~ String.replace_prefix(first["text"], "1. ", "")
    refresh = Enum.find(detail_buttons, &(&1["text"] == "Refresh details"))
    webhook_request(callback.(refresh["callback_data"]), @webhook_secret) |> expect_json(200)
    settle_receive({:device_edited, "42001", 2, refreshed, detail_buttons})
    assert refreshed =~ "Device operations"
    back = Enum.find(detail_buttons, &(&1["text"] == "Device list / refresh"))
    webhook_request(callback.(back["callback_data"]), @webhook_secret) |> expect_json(200)
    settle_receive({:device_edited, "42001", 2, list, choices})
    assert list =~ "1. Desk"
    refute list =~ "Device operations"
    next = Enum.find(choices, &(&1["text"] == "Next page"))
    webhook_request(callback.(next["callback_data"]), @webhook_secret) |> expect_json(200)
    settle_receive({:device_edited, "42001", 2, _text, second})
    refute Enum.any?(second, &(&1["text"] == "Next page"))
    webhook_request(callback.(first["callback_data"]), @webhook_secret) |> expect_json(200)
    settle_receive({:telegram_message, "42001", expired})
    assert expired =~ "expired"
    settle_refute_receive({:device_edited, _, _, _, _})
    link = Comma.TelegramLinks.get_link(c.workspace["id"])

    key =
      "comma/chat_device_views/" <> Base.url_encode64(link.connect_id, padding: false) <> ".json"

    assert {:ok, _} = SalixStore.CasRecord.update(key, &Map.put(&1, "expires_at", 0))
    webhook_request(callback.(hd(second)["callback_data"]), @webhook_secret) |> expect_json(200)
    settle_receive({:telegram_message, "42001", ttl_expired})
    assert ttl_expired =~ "expired"
    settle_refute_receive({:device_edited, _, _, _, _})
    api_request(c.session, :delete, telegram_path(c.workspace)) |> expect_json(200)
    webhook_request(callback.(hd(second)["callback_data"]), @webhook_secret) |> expect_json(200)
    settle_receive({:telegram_message, "42001", unlinked})
    assert unlinked =~ "not connected"
    settle_refute_receive({:device_edited, _, _, _, _})
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

    settle_receive(
      {:telegram_card, "42001", _message_id, text,
       [
         [%{"text" => "1", "web_app" => %{"url" => url}}],
         [%{"text" => "All tasks", "web_app" => %{"url" => all_url}}]
       ]}
    )

    assert text =~ "Telegram Team"
    assert text =~ "1. 🔄 Review Telegram design"

    uri = URI.parse(url)

    assert URI.to_string(%{uri | path: nil, query: nil}) ==
             SystemsRuntime.fetch_env!(:comma_web, :web_cookie_origin)

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

  test "tasks command reads past archived Tasks to the ones still shown", %{
    session: session,
    workspace: workspace
  } do
    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    group_id = workspace["default_group_id"]

    create = fn title ->
      {:ok, task} =
        SalixCluster.TaskSchedules.create_task_conversation(
          group_id,
          workspace["router_agent_id"],
          workspace["default_worker_agent_id"],
          %{"title" => title, "content" => title, "client_request_id" => "telegram-#{title}"}
        )

      task["conversation_id"]
    end

    create.("Older open Task")

    # The 8 newest Tasks are archived: they fill the first page.
    for index <- 1..8 do
      id = create.("Archived #{index}")

      {:ok, failed} =
        SalixIM.ConversationServer.update_group_conversation(group_id, id, %{
          "status" => "failed"
        })

      api_request(
        session,
        :post,
        "/v1/comma/groups/#{group_id}/conversations/#{id}/archive",
        %{"expected_updated_at" => failed["updated_at"]}
      )
      |> expect_json(200)
    end

    assert complete_login(session, workspace).status == 200
    webhook_request(private_update(952, "/tasks"), @webhook_secret) |> expect_json(200)

    settle_receive({:telegram_card, "42001", _message_id, text, _keyboard})
    assert text =~ "1. 🔄 Older open Task"
    refute text =~ "Archived"
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

    # The panel's video player asks for a media URL of its Task's attachment, as
    # it reads one: the request passes the panel's checks (this Task has none).
    attachment_path =
      "/v1/comma/groups/#{group_id}/conversations/#{task["conversation_id"]}/messages/msg1/attachments/0"

    assert miniapp_cookie_request(:post, attachment_path <> "/media", cookie.value).status ==
             404

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
    # Nor may it mint a media URL any more.
    assert miniapp_cookie_request(:post, attachment_path <> "/media", cookie.value).status ==
             401

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

  # A Telegram button opens a Comma app in the same panel (`CommaWeb.MiniAppPort.telegram_app_url/3`): its session
  # reaches the app's routes through its own Workspace, and nothing of another Workspace or a share link.
  test "a Telegram panel session runs its Workspace's apps and nothing else of them", %{
    session: session,
    workspace: workspace
  } do
    group_id = workspace["default_group_id"]
    ws = workspace["id"]
    assert complete_login(session, workspace).status == 200
    login = miniapp_login(group_id, signed_init_data(42_001))
    assert %{"session_id" => _} = expect_json(login, 201)
    cookie = login.resp_cookies[CommaWeb.SessionCookie.panel_cookie_name()].value
    app_id = SystemsRuntime.Proc.uuid()
    version_id = SystemsRuntime.Proc.uuid()

    app =
      Comma.Repo.insert!(%Comma.MiniApps.App{
        id: app_id,
        slug: "habits01",
        workspace_id: ws,
        group_id: group_id,
        name: "Habit tracker",
        repo_owner: "ann",
        repo_name: "comma-app-habits01",
        visibility: "workspace",
        next_version: 2
      })

    Comma.Repo.insert!(%Comma.MiniApps.Version{
      id: version_id,
      app_id: app_id,
      number: 1,
      state: "ready",
      digest: "d1",
      deploy_key: "k1",
      commit: "c1"
    })

    app |> Ecto.Changeset.change(live_version_id: version_id) |> Comma.Repo.update!()

    own = [{"x-comma-app-via", "workspace/#{ws}"}]

    # The session reaches the app as its Workspace's member. This Workspace has
    # no billing account, so the app answers that it is paused (not 401 or 403).
    assert %{"error" => "app_paused"} =
             miniapp_cookie_request(:post, "/v1/comma/apps/#{app_id}/open", cookie, own)
             |> expect_json(402)

    assert %{"name" => "Habit tracker"} =
             miniapp_cookie_request(:get, "/v1/comma/workspaces/#{ws}/apps/#{app_id}", cookie)
             |> expect_json(200)

    for {method, path, headers} <- [
          {:post, "/v1/comma/apps/#{app_id}/open", []},
          {:post, "/v1/comma/apps/#{app_id}/open", [{"x-comma-app-via", "workspace/other"}]},
          {:post, "/v1/comma/apps/#{app_id}/open", [{"x-comma-app-via", "link/token"}]},
          {:get, "/v1/comma/apps/links/token", own},
          {:get, "/v1/comma/workspaces/#{ws}/apps", []},
          {:patch, "/v1/comma/workspaces/#{ws}/apps/#{app_id}", []},
          {:post, "/v1/comma/workspaces/#{ws}/apps/#{app_id}/publish", []},
          {:get, "/v1/comma/workspaces/other/apps/#{app_id}", []}
        ] do
      assert miniapp_cookie_request(method, path, cookie, headers).status == 401,
             "#{method} #{path} #{inspect(headers)}"
    end
  end

  test "Mini App login rejects forged, stale, unbound, and wrong-account launches", %{
    session: session,
    workspace: workspace
  } do
    assert complete_login(session, workspace).status == 200
    group_id = workspace["default_group_id"]
    valid = signed_init_data(42_001)

    assert miniapp_login(group_id, valid <> "&user=forged").status == 401

    assert miniapp_login(
             group_id,
             signed_init_data(42_001, SystemsClock.system_time(:second) - 121)
           ).status ==
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
    settle_refute_receive({:telegram_message, _, _})
  end

  test "new fallback intent fences an older OIDC callback", context do
    callback = paused_callback(context)
    settle_receive({:oidc_paused, callback_pid})
    assert complete_login(context.session, context.workspace, "second-user").status == 200

    SystemsRuntime.Proc.send(callback_pid, :continue_oidc)
    assert settled_await(callback).status == 400
    assert Comma.TelegramLinks.get_link(context.workspace["id"]).telegram_user_id == "42002"

    {:ok, [connect]} =
      SalixIM.ProviderConnects.list_tool_connects(
        context.workspace["default_group_id"],
        ["telegram"]
      )

    assert connect["connect_id"] ==
             Comma.TelegramLinks.get_link(context.workspace["id"]).connect_id
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

    settle_refute_receive(:telegram_provider_sent)

    assert {:error, _reason} =
             SalixIM.ProviderConnects.enable_im_connect(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               created["connect_id"]
             )
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

  defp paused_callback(%{session: session, workspace: workspace}) do
    attempt =
      api_request(session, :post, telegram_path(workspace) <> "/connect", %{})
      |> expect_json(201)

    params =
      attempt["authorization_url"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    SystemsRuntime.Task.async(fn ->
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

  defp miniapp_cookie_request(method, path, cookie_token, headers \\ []) do
    {:ok, _user, session} = Comma.Accounts.resolve_session(cookie_token)

    headers
    |> Enum.reduce(conn(method, path), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> put_req_header("cookie", "#{CommaWeb.SessionCookie.panel_cookie_name()}=#{cookie_token}")
    |> miniapp_web_headers(session["id"])
    |> call()
  end

  defp miniapp_web_headers(conn, expected_session) do
    conn
    |> put_req_header("origin", SystemsRuntime.fetch_env!(:comma_web, :web_cookie_origin))
    |> put_req_header("x-comma-session-transport", "cookie")
    |> put_req_header("x-comma-session-lifecycle-version", "1")
    |> put_req_header("x-comma-expected-auth-session-id", expected_session)
  end

  defp signed_init_data(id, auth_date \\ SystemsClock.system_time(:second)) do
    fields = %{
      "auth_date" => Integer.to_string(auth_date),
      "query_id" => "test-#{SystemsRuntime.Proc.unique_integer([:positive])}",
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
        expires_at: DateTime.add(SystemsClock.utc_now(), 30, :day),
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
        "update_id" => SystemsRuntime.Proc.unique_integer([:positive]),
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

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
