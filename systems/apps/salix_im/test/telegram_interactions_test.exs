defmodule SalixIM.TelegramInteractionsTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  alias SalixIM.TelegramInteractions, as: Interactions
  alias SalixStore.{CasRecord, Keys}
  alias SalixStore.TelegramInteractions, as: Store

  defmodule Runtime do
    use Agent
    @behaviour SalixIM.Ports.AgentDelivery
    def start_link(parent),
      do:
        Agent.start_link(fn -> %{parent: parent, seen: MapSet.new()} end,
          name: __MODULE__
        )

    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent, payload, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        source = opts[:source_message_id]

        cond do
          MapSet.member?(state.seen, source) ->
            {{:ok, :queued}, state}

          true ->
            SystemsRuntime.Proc.send(state.parent, {:delivered, agent, payload, opts})
            {{:ok, :queued}, %{state | seen: MapSet.put(state.seen, source)}}
        end
      end)
    end

    def get_session(_, _, _), do: {:error, :not_supported}
    def get_session_messages(_, _), do: {:error, :not_supported}
  end

  defmodule API do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      {:ok, raw, conn} = read_body(conn)
      body = Jason.decode!(raw)
      method = List.last(conn.path_info)

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :interaction_test_parent),
        {:api, method, body}
      )

      configured_failure = SystemsRuntime.get_env(:salix_im, :interaction_test_failure, false)
      failure = configured_failure == true or configured_failure == method

      response =
        if failure,
          do: %{"ok" => false},
          else: %{
            "ok" => true,
            "result" => if(method == "sendMessage", do: %{"message_id" => 41}, else: true)
          }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(if(failure, do: 503, else: 200), Jason.encode!(response))
    end
  end

  setup do
    SalixStore.S3.Fake.reset()
    start_supervised!({Runtime, SystemsRuntime.Proc.self()})
    port = SalixIM.TestSupport.BanditServer.start!(fn p -> {Bandit, plug: API, port: p} end)

    env = %{
      telegram_api_base_url: "http://127.0.0.1:#{port}",
      interaction_test_parent: SystemsRuntime.Proc.self(),
      interaction_test_failure: false,
      agent_delivery_mod: Runtime
    }

    previous =
      Enum.map(env, fn {k, v} ->
        old = SystemsRuntime.get_env(:salix_im, k)
        SystemsRuntime.put_env(:salix_im, k, v)
        {k, old}
      end)

    on_exit(fn ->
      for {k, v} <- previous do
        if is_nil(v),
          do: SystemsRuntime.delete_env(:salix_im, k),
          else: SystemsRuntime.put_env(:salix_im, k, v)
      end
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)
    agent = SalixStore.Ids.new_agent_id(group)

    router =
      SalixAgent.TestSupport.create_control_agent!(agent, %{
        "tenant_id" => tenant,
        "group_id" => group,
        "role" => "router"
      })

    SalixAgent.TestSupport.create_control_group!(group, %{"router_agent_id" => agent})

    connect = %{
      "tenant_id" => tenant,
      "group_id" => group,
      "connect_id" => "tg-interaction",
      "provider" => "telegram",
      "managed_by" => "comma_product",
      "managed_peer_id" => "123456",
      "status" => "connected",
      "bot_token" => "test-token",
      "connected_at" => 1
    }

    {:ok, _} = CasRecord.create(Keys.ctl_im_connect(group, connect["connect_id"]), connect)

    scope = %{
      "group_id" => group,
      "agent_id" => agent,
      "session_id" => router["router_session_id"],
      "connect_id" => connect["connect_id"],
      "chat_id" => "123456",
      "message_thread_id" => "",
      "reply_to_message_id" => "19",
      "source_message_id" => "source-A"
    }

    %{connect: connect, scope: scope}
  end

  for {locale, selected, cancelled, cancel_button, received} <- [
        {"en", "✅ Selected: 蓝色", "Cancelled", "Decline / Cancel", "Received"},
        {"zh-CN", "✅ 已选择：蓝色", "已取消", "拒绝 / 取消", "已收到"}
      ],
      choice <- ["0", "deny"] do
  end

  test "native question is sent once; callback delivers one request-bound new input", c do
    assert {:ok, result} =
             Interactions.request(
               c.scope,
               "question",
               %{"question" => "哪一天？", "choices" => ["今天", "明天"]},
               "call-A"
             )

    assert result["status"] == "question_delivered"
    settle_receive({:api, "sendMessage", body})
    assert body["text"] == "哪一天？"

    data =
      get_in(body, ["reply_markup", "inline_keyboard"])
      |> hd()
      |> hd()
      |> Map.fetch!("callback_data")

    assert byte_size(data) <= 64

    assert {:ok, ^result} =
             Interactions.request(
               c.scope,
               "question",
               %{"question" => "哪一天？", "choices" => ["今天", "明天"]},
               "call-A"
             )

    settle_refute_receive({:api, "sendMessage", _})
    assert {:handled, {:ok, :queued}} = Interactions.handle_update(c.connect, callback(data))
    settle_receive({:delivered, _, payload, opts})
    assert get_in(payload, [:trusted_origin, "provider_context", "message_id"]) == "41"
    assert inspect(payload) =~ "今天"
    assert opts[:source_message_id] != c.scope["source_message_id"]
    assert opts[:source_message_id] =~ result["request_id"]
    settle_receive({:api, "editMessageText", completed})

    assert completed == %{
             "chat_id" => "123456",
             "message_id" => 41,
             "text" => "哪一天？\n\n✅ Selected: 今天",
             "reply_markup" => %{"inline_keyboard" => []}
           }

    assert {:handled, {:ok, :duplicate}} = Interactions.handle_update(c.connect, callback(data))
    settle_receive({:api, "editMessageText", ^completed})
    settle_refute_receive({:delivered, _, _, _})

    assert {:handled, {:ok, :ignored}} =
             Interactions.handle_update(
               c.connect,
               callback("ci:" <> result["request_id"] <> ":1")
             )

    settle_refute_receive({:delivered, _, _, _})
    settle_refute_receive({:api, "editMessageText", _})
  end

  test "permission uses green approval and a neutral denial with no external grant", c do
    {:ok, result} =
      Interactions.request(c.scope, "permission", %{"capability" => "read file"}, "permission")

    settle_receive({:api, "sendMessage", body})
    [allow, deny] = get_in(body, ["reply_markup", "inline_keyboard"])
    assert hd(allow)["style"] == "success"
    refute Map.has_key?(hd(deny), "style")

    assert {:handled, {:ok, :queued}} =
             Interactions.handle_update(
               c.connect,
               callback("ci:" <> result["request_id"] <> ":deny")
             )

    settle_receive({:delivered, _, payload, _})
    assert inspect(payload) =~ "denied"
    settle_receive({:api, "editMessageText", completed})
    assert completed["text"] =~ "Declined"
    assert completed["reply_markup"] == %{"inline_keyboard" => []}
  end

  test "wrong user, peer, message, expiry and reconnect cannot consume a request", c do
    {:ok, result} =
      Interactions.request(c.scope, "permission", %{"capability" => "read"}, "deny-boundary")

    data = "ci:" <> result["request_id"] <> ":allow"
    original = callback(data)

    for update <- [
          put_in(original, ["callback_query", "from", "id"], 999),
          put_in(original, ["callback_query", "message", "chat", "id"], 999),
          put_in(original, ["callback_query", "message", "message_id"], 999)
        ] do
      assert {:handled, {:ok, :ignored}} = Interactions.handle_update(c.connect, update)
    end

    {:ok, _} =
      Store.update(c.scope["group_id"], result["request_id"], &Map.put(&1, "expires_at", 0))

    assert {:handled, {:ok, :ignored}} = Interactions.handle_update(c.connect, original)

    {:ok, _} =
      Store.update(
        c.scope["group_id"],
        result["request_id"],
        &Map.put(&1, "expires_at", SystemsClock.system_time(:second) + 100)
      )

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_im_connect(c.scope["group_id"], c.connect["connect_id"]),
        &Map.put(&1, "connected_at", 2)
      )

    assert {:handled, {:ok, :ignored}} = Interactions.handle_update(c.connect, original)
    settle_refute_receive({:delivered, _, _, _})
    settle_refute_receive({:api, "editMessageText", _})
  end

  test "prompt lookup is scoped and completed records remain stored", c do
    {:ok, result} = Interactions.request(c.scope, "question", %{"question" => "Q"}, "stored")

    assert {:ok, record} = Store.get_by_reply(c.scope["group_id"], c.scope["connect_id"], 41)
    assert record["id"] == result["request_id"]
    assert {:error, :not_found} = Store.get_by_reply(c.scope["group_id"], "other-connect", 41)
    assert {:error, :not_found} = Store.get_by_reply("other-group", c.scope["connect_id"], 41)

    assert {:handled, {:ok, :queued}} =
             Interactions.handle_update(
               c.connect,
               callback("ci:" <> result["request_id"] <> ":deny")
             )

    assert {:ok, saved} = Store.get(c.scope["group_id"], result["request_id"])
    assert saved["status"] == "delivered"
    assert saved["response"] == %{"status" => "denied"}
    assert {:ok, ^saved} = Store.get_by_reply(c.scope["group_id"], c.scope["connect_id"], 41)
  end

  test "native location without reply metadata completes the unique request once", c do
    {:ok, _} = Interactions.request(c.scope, "location", %{"reason" => "查询天气"}, "location")
    settle_receive({:api, "sendMessage", body})
    assert body["reply_markup"]["force_reply"] == true

    assert get_in(body, ["reply_markup", "keyboard"]) == [
             [
               %{
                 "text" => "Share location",
                 "request_location" => true,
                 "style" => "primary"
               }
             ],
             [%{"text" => "Don't share / Cancel"}]
           ]

    message = %{
      "message_id" => 42,
      "chat" => %{"id" => 123_456, "type" => "private"},
      "from" => %{"id" => 123_456},
      "location" => %{"latitude" => 1.3, "longitude" => 103.8}
    }

    assert {:handled, {:ok, :queued}} =
             Interactions.handle_update(c.connect, %{"message" => message})

    assert {:handled, {:ok, :duplicate}} =
             Interactions.handle_update(c.connect, %{"message" => message})

    settle_receive({:delivered, _, payload, _})
    assert inspect(payload) =~ "latitude"
    settle_refute_receive({:api, "editMessageText", _})
  end

  test "OAuth success requires the persisted browser outcome, never a button assertion", c do
    state = "oauth-browser-test"
    request_id = Interactions.id(c.scope, "oauth")

    assert :ok =
             SalixStore.OAuth.AuthState.create(%{
               "state" => state,
               "tenant" => c.connect["tenant_id"],
               "group_id" => c.scope["group_id"],
               "agent_id" => c.scope["agent_id"],
               "session_id" => c.scope["session_id"],
               "provider" => "google",
               "alias" => "test",
               "telegram_interaction" => %{"group_id" => c.scope["group_id"], "id" => request_id}
             })

    assert {:ok, _} =
             Interactions.request(
               c.scope,
               "oauth",
               %{
                 "reason" => "只读日历",
                 "authorization_url" => "https://example.test/authorize",
                 "oauth_state" => state
               },
               "oauth"
             )

    assert {:handled, {:ok, :ignored}} =
             Interactions.handle_update(c.connect, callback("ci:" <> request_id <> ":verify"))

    assert {:handled, {:ok, :ignored}} =
             Interactions.handle_update(c.connect, callback("ci:" <> request_id <> ":allow"))

    settle_refute_receive({:delivered, _, _, _})
    settle_refute_receive({:api, "editMessageText", _})
    assert {:ok, _} = SalixStore.OAuth.AuthState.consume(state)

    assert :ok =
             SalixStore.OAuth.AuthState.record_completion(state, %{
               "binding_id" => "verified-binding"
             })

    assert {:ok, :queued} = Interactions.oauth_completed(state)
    settle_receive({:delivered, _, payload, _})
    assert inspect(payload) =~ "oauth_completed"
    refute inspect(payload) =~ "verified-binding"
    settle_receive({:api, "editMessageText", card})
    assert card["text"] == "只读日历\n\n✅ Authorization completed"
    assert card["reply_markup"] == %{"inline_keyboard" => []}

    assert {:handled, {:ok, :duplicate}} =
             Interactions.handle_update(c.connect, callback("ci:" <> request_id <> ":verify"))

    settle_refute_receive({:delivered, _, _, _})
  end

  defp callback(data),
    do: %{
      "callback_query" => %{
        "id" => "callback-test",
        "data" => data,
        "from" => %{"id" => 123_456},
        "message" => %{"message_id" => 41, "chat" => %{"id" => 123_456, "type" => "private"}}
      }
    }
end
