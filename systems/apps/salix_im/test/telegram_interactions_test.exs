defmodule SalixIM.TelegramInteractionsTest do
  use ExUnit.Case, async: false
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
            send(state.parent, {:delivered, agent, payload, opts})
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
      send(Application.fetch_env!(:salix_im, :interaction_test_parent), {:api, method, body})
      configured_failure = Application.get_env(:salix_im, :interaction_test_failure, false)
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
    start_supervised!({Runtime, self()})
    port = SalixIM.TestSupport.BanditServer.start!(fn p -> {Bandit, plug: API, port: p} end)

    env = %{
      telegram_api_base_url: "http://127.0.0.1:#{port}",
      interaction_test_parent: self(),
      interaction_test_failure: false,
      agent_delivery_mod: Runtime
    }

    previous =
      Enum.map(env, fn {k, v} ->
        old = Application.get_env(:salix_im, k)
        Application.put_env(:salix_im, k, v)
        {k, old}
      end)

    on_exit(fn ->
      for {k, v} <- previous do
        if is_nil(v),
          do: Application.delete_env(:salix_im, k),
          else: Application.put_env(:salix_im, k, v)
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
    test "#{locale} #{choice} card labels and completion preserve the original option", c do
      locale = unquote(locale)
      choice = unquote(choice)
      ending = if choice == "0", do: unquote(selected), else: unquote(cancelled)

      {:ok, _} =
        Interactions.request(
          c.scope,
          "question",
          %{
            "question" => "Choose a colour",
            "choices" => ["蓝色", "Green"],
            "locale" => locale
          },
          "locale-#{locale}-#{choice}"
        )

      assert_receive {:api, "sendMessage", body}

      assert body["reply_parameters"] == %{
               "message_id" => "19",
               "allow_sending_without_reply" => true
             }

      rows = body["reply_markup"]["inline_keyboard"]
      assert List.last(rows) |> hd() |> Map.fetch!("text") == unquote(cancel_button)
      data = rows |> hd() |> hd() |> Map.fetch!("callback_data")
      data = if choice == "deny", do: String.replace_suffix(data, ":0", ":deny"), else: data
      update = put_in(callback(data), ["callback_query", "from", "language_code"], "de")
      assert {:handled, {:ok, :queued}} = Interactions.handle_update(c.connect, update)
      assert_receive {:api, "editMessageText", card}
      assert card["text"] == "Choose a colour\n\n" <> ending
      assert card["reply_markup"] == %{"inline_keyboard" => []}
      assert_receive {:api, "answerCallbackQuery", toast}
      assert toast["text"] == unquote(received)
    end
  end

  test "a historical card without locale keeps its original Chinese completion", c do
    {:ok, receipt} =
      Interactions.request(
        c.scope,
        "question",
        %{
          "question" => "颜色？",
          "choices" => ["Blue"],
          "locale" => "zh-CN"
        },
        "legacy-locale"
      )

    assert_receive {:api, "sendMessage", body}
    {:ok, _} = Store.update(c.scope["group_id"], receipt["request_id"], &Map.delete(&1, "locale"))
    data = body["reply_markup"]["inline_keyboard"] |> hd() |> hd() |> Map.fetch!("callback_data")
    assert {:handled, {:ok, :queued}} = Interactions.handle_update(c.connect, callback(data))
    assert_receive {:api, "editMessageText", card}
    assert card["text"] == "颜色？\n\n✅ 已选择：Blue"
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
    assert_receive {:api, "sendMessage", body}
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

    refute_receive {:api, "sendMessage", _}
    assert {:handled, {:ok, :queued}} = Interactions.handle_update(c.connect, callback(data))
    assert_receive {:delivered, _, payload, opts}
    assert get_in(payload, [:trusted_origin, "provider_context", "message_id"]) == "41"
    assert inspect(payload) =~ "今天"
    assert opts[:source_message_id] != c.scope["source_message_id"]
    assert opts[:source_message_id] =~ result["request_id"]
    assert_receive {:api, "editMessageText", completed}

    assert completed == %{
             "chat_id" => "123456",
             "message_id" => 41,
             "text" => "哪一天？\n\n✅ Selected: 今天",
             "reply_markup" => %{"inline_keyboard" => []}
           }

    assert {:handled, {:ok, :duplicate}} = Interactions.handle_update(c.connect, callback(data))
    assert_receive {:api, "editMessageText", ^completed}
    refute_receive {:delivered, _, _, _}

    assert {:handled, {:ok, :ignored}} =
             Interactions.handle_update(
               c.connect,
               callback("ci:" <> result["request_id"] <> ":1")
             )

    refute_receive {:delivered, _, _, _}
    refute_receive {:api, "editMessageText", _}
  end

  test "question cancellation closes the original card without inventing an answer", c do
    {:ok, result} =
      Interactions.request(
        c.scope,
        "question",
        %{"question" => "颜色？", "choices" => ["绿"]},
        "cancel-card"
      )

    assert {:handled, {:ok, :queued}} =
             Interactions.handle_update(
               c.connect,
               callback("ci:" <> result["request_id"] <> ":deny")
             )

    assert_receive {:api, "editMessageText", body}
    assert body["text"] == "颜色？\n\nCancelled"
    assert body["reply_markup"] == %{"inline_keyboard" => []}
  end

  test "card edit failure cannot undo delivery; same selection repairs without another input",
       c do
    {:ok, result} =
      Interactions.request(
        c.scope,
        "question",
        %{"question" => "颜色？", "choices" => ["绿"]},
        "repair-card"
      )

    data = "ci:" <> result["request_id"] <> ":0"
    Application.put_env(:salix_im, :interaction_test_failure, "editMessageText")
    assert {:handled, {:ok, :queued}} = Interactions.handle_update(c.connect, callback(data))
    assert_receive {:delivered, _, _, _}
    assert_receive {:api, "editMessageText", body}

    assert {:ok, %{"status" => "delivered"}} =
             Store.get(c.scope["group_id"], result["request_id"])

    Application.put_env(:salix_im, :interaction_test_failure, false)
    assert {:handled, {:ok, :duplicate}} = Interactions.handle_update(c.connect, callback(data))
    assert_receive {:api, "editMessageText", ^body}
    refute_receive {:delivered, _, _, _}
    refute_receive {:api, "sendMessage", %{"text" => "绿"}}
  end

  test "observations exclude content and a failing handler cannot break prompt delivery", c do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:salix, :operation, :stop],
        fn _, _, metadata, parent ->
          if metadata[:operation] == "telegram_interaction_prompt" do
            send(parent, {:observed, metadata})
            raise "observer unavailable"
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _} =
             Interactions.request(
               c.scope,
               "question",
               %{"question" => "private-question"},
               "observation"
             )

    assert_receive {:observed, metadata}

    assert metadata == %{
             component: "salix_im",
             operation: "telegram_interaction_prompt",
             surface: "comma",
             outcome: "ok"
           }

    refute inspect(metadata) =~ "private-question"
    refute inspect(metadata) =~ c.scope["agent_id"]
  end

  test "typed answer to an inline card keeps a bounded plain-text preview", c do
    question = String.duplicate("Q", 2000)

    {:ok, _} =
      Interactions.request(
        c.scope,
        "question",
        %{"question" => question, "choices" => ["<green>"]},
        "typed-card"
      )

    answer = String.duplicate("🌿", 900)

    message = %{
      "message_id" => 42,
      "chat" => %{"id" => 123_456, "type" => "private"},
      "from" => %{"id" => 123_456},
      "text" => answer,
      "reply_to_message" => %{"message_id" => 41}
    }

    assert {:handled, {:ok, :queued}} =
             Interactions.handle_update(c.connect, %{"message" => message})

    assert_receive {:delivered, _, payload, _}
    assert get_in(payload, [:trusted_origin, "provider_context", "message_id"]) == "42"
    assert_receive {:api, "editMessageText", card}
    assert card["text"] == question <> "\n\n✅ Selected: " <> String.duplicate("🌿", 500) <> "…"

    assert byte_size(:unicode.characters_to_binary(card["text"], :utf8, {:utf16, :little})) / 2 <
             4096

    refute Map.has_key?(card, "parse_mode")
    assert card["reply_markup"] == %{"inline_keyboard" => []}
  end

  test "permission uses green approval and a neutral denial with no external grant", c do
    {:ok, result} =
      Interactions.request(c.scope, "permission", %{"capability" => "read file"}, "permission")

    assert_receive {:api, "sendMessage", body}
    [allow, deny] = get_in(body, ["reply_markup", "inline_keyboard"])
    assert hd(allow)["style"] == "success"
    refute Map.has_key?(hd(deny), "style")

    assert {:handled, {:ok, :queued}} =
             Interactions.handle_update(
               c.connect,
               callback("ci:" <> result["request_id"] <> ":deny")
             )

    assert_receive {:delivered, _, payload, _}
    assert inspect(payload) =~ "denied"
    assert_receive {:api, "editMessageText", completed}
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
        &Map.put(&1, "expires_at", System.system_time(:second) + 100)
      )

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_im_connect(c.scope["group_id"], c.connect["connect_id"]),
        &Map.put(&1, "connected_at", 2)
      )

    assert {:handled, {:ok, :ignored}} = Interactions.handle_update(c.connect, original)
    refute_receive {:delivered, _, _, _}
    refute_receive {:api, "editMessageText", _}
  end

  test "enqueue failure preserves decision; retry delivers same input and opposite choice cannot win",
       c do
    {:ok, result} =
      Interactions.request(c.scope, "permission", %{"capability" => "read"}, "retry")

    data = "ci:" <> result["request_id"] <> ":allow"
    fail_router_append(c.scope["group_id"])
    assert {:handled, {:error, _}} = Interactions.handle_update(c.connect, callback(data))
    :ok = SalixStore.S3.Fake.clear_blackhole()
    refute_receive {:api, "editMessageText", _}

    # Expiry prevents a new decision, not retry of a decision already committed.
    {:ok, _} =
      Store.update(c.scope["group_id"], result["request_id"], &Map.put(&1, "expires_at", 0))

    assert {:handled, {:ok, :ignored}} =
             Interactions.handle_update(
               c.connect,
               callback("ci:" <> result["request_id"] <> ":deny")
             )

    assert {:handled, {:ok, :queued}} = Interactions.handle_update(c.connect, callback(data))
    assert_receive {:api, "editMessageText", completed}
    assert completed["text"] =~ "✅ Allowed this time"
    assert_receive {:delivered, _, _, _}
    assert {:handled, {:ok, :duplicate}} = Interactions.handle_update(c.connect, callback(data))
    refute_receive {:delivered, _, _, _}
  end

  test "ambiguous HTTP failure does not blindly resend a prompt", c do
    Application.put_env(:salix_im, :interaction_test_failure, true)

    assert {:error, :provider_delivery_unconfirmed} =
             Interactions.request(c.scope, "question", %{"question" => "Q"}, "ambiguous")

    assert_receive {:api, "sendMessage", _}
    Application.put_env(:salix_im, :interaction_test_failure, false)

    assert {:error, :send_outcome_unknown} =
             Interactions.request(c.scope, "question", %{"question" => "Q"}, "ambiguous")

    refute_receive {:api, "sendMessage", _}
  end

  test "a conflicting prompt receipt rolls back atomically without resending", c do
    {:ok, _} =
      Store.create(%{
        "id" => "another-request",
        "scope" => c.scope,
        "message_id" => 41,
        "status" => "pending"
      })

    assert {:error, :prompt_index_conflict} =
             Interactions.request(c.scope, "question", %{"question" => "Q"}, "index-conflict")

    assert_receive {:api, "sendMessage", _}

    assert {:error, :send_outcome_unknown} =
             Interactions.request(c.scope, "question", %{"question" => "Q"}, "index-conflict")

    refute_receive {:api, "sendMessage", _}

    assert {:ok, %{"id" => "another-request"}} =
             Store.get_by_reply(c.scope["group_id"], c.scope["connect_id"], 41)

    assert {:ok, claim} =
             Store.get(c.scope["group_id"], Interactions.id(c.scope, "index-conflict"))

    assert claim["status"] == "sending"
    refute Map.has_key?(claim, "message_id")
  end

  test "concurrent opposing responses preserve one decision and one Router input", c do
    {:ok, result} = Interactions.request(c.scope, "permission", %{"capability" => "read"}, "race")

    outcomes =
      ["allow", "deny"]
      |> Task.async_stream(fn choice ->
        Interactions.handle_update(
          c.connect,
          callback("ci:" <> result["request_id"] <> ":" <> choice)
        )
      end)
      |> Enum.map(fn {:ok, outcome} -> outcome end)

    assert {:handled, {:ok, :queued}} in outcomes
    assert {:handled, {:ok, :ignored}} in outcomes
    assert_receive {:delivered, _, _, _}
    refute_receive {:delivered, _, _, _}
    assert {:ok, saved} = Store.get(c.scope["group_id"], result["request_id"])
    assert saved["status"] == "delivered"
    assert saved["response"]["status"] in ["approved", "denied"]
    assert_receive {:api, "editMessageText", card}

    expected =
      if saved["response"]["status"] == "approved", do: "✅ Allowed this time", else: "Declined"

    assert String.ends_with?(card["text"], expected)
    refute_receive {:api, "editMessageText", _}
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
    assert_receive {:api, "sendMessage", body}
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

    assert_receive {:delivered, _, payload, _}
    assert inspect(payload) =~ "latitude"
    refute_receive {:api, "editMessageText", _}
  end

  test "free text replies remain bound to the question", c do
    {:ok, _} = Interactions.request(c.scope, "question", %{"question" => "哪个城市？"}, "free-text")

    message = %{
      "message_id" => 42,
      "chat" => %{"id" => 123_456, "type" => "private"},
      "from" => %{"id" => 123_456},
      "text" => "杭州",
      "reply_to_message" => %{"message_id" => 41}
    }

    assert {:handled, {:ok, :queued}} =
             Interactions.handle_update(c.connect, %{"message" => message})

    assert_receive {:delivered, _, payload, _}
    assert inspect(payload) =~ "杭州"
    refute_receive {:api, "editMessageText", _}
  end

  test "a Mac user can answer a location request with a city without sharing coordinates", c do
    {:ok, receipt} =
      Interactions.request(
        c.scope,
        "location",
        %{"reason" => "查询当地天气", "locale" => "zh-CN"},
        "mac-city"
      )

    assert_receive {:api, "sendMessage", body}
    assert body["text"] =~ "回复这条消息告诉我城市"
    refute body["text"] =~ "Mac"
    assert body["reply_markup"]["input_field_placeholder"] == "回复城市，或分享位置"

    assert get_in(body, ["reply_markup", "keyboard"]) |> hd() |> hd() |> Map.fetch!("text") ==
             "分享位置"

    assert {:ok, %{"status" => "pending"}} = Store.get(c.scope["group_id"], receipt["request_id"])
    refute_receive {:delivered, _, _, _}

    reply = %{
      "message_id" => 42,
      "chat" => %{"id" => 123_456, "type" => "private"},
      "from" => %{"id" => 123_456},
      "text" => "杭州",
      "reply_to_message" => %{"message_id" => 41}
    }

    assert {:handled, {:ok, :queued}} =
             Interactions.handle_update(c.connect, %{"message" => reply})

    assert_receive {:delivered, _, payload, _}
    assert inspect(payload) =~ "杭州"
    refute inspect(payload) =~ "latitude"

    assert {:ok, %{"status" => "delivered", "response" => %{"answer" => "杭州"}}} =
             Store.get(c.scope["group_id"], receipt["request_id"])

    assert {:handled, {:ok, :duplicate}} =
             Interactions.handle_update(c.connect, %{"message" => reply})

    refute_receive {:delivered, _, _, _}
  end

  test "location cancellation delivers a denial without coordinates", c do
    {:ok, _} = Interactions.request(c.scope, "location", %{"reason" => "查询天气"}, "location-cancel")

    message = %{
      "message_id" => 42,
      "chat" => %{"id" => 123_456, "type" => "private"},
      "from" => %{"id" => 123_456},
      "text" => "Don't share / Cancel"
    }

    assert {:handled, {:ok, :queued}} =
             Interactions.handle_update(c.connect, %{"message" => message})

    assert_receive {:delivered, _, payload, _}
    assert inspect(payload) =~ "denied"
    refute inspect(payload) =~ "latitude"
  end

  test "location completion removes the keyboard once without exposing coordinates", c do
    {:ok, receipt} =
      Interactions.request(
        c.scope,
        "location",
        %{"reason" => "Location", "locale" => "zh-CN"},
        "cleanup"
      )

    assert_receive {:api, "sendMessage", _}

    message = %{
      "message_id" => 42,
      "chat" => %{"id" => 123_456, "type" => "private"},
      "from" => %{"id" => 123_456},
      "location" => %{"latitude" => 1.3, "longitude" => 103.8}
    }

    assert {:handled, {:ok, :queued}} =
             Interactions.handle_update(c.connect, %{"message" => message})

    assert_receive {:api, "sendMessage",
                    %{"text" => "已收到", "reply_markup" => %{"remove_keyboard" => true}}}

    assert {:ok, %{"keyboard_completion" => "sent"}} =
             Store.get(c.scope["group_id"], receipt["request_id"])

    assert {:handled, {:ok, :duplicate}} =
             Interactions.handle_update(c.connect, %{"message" => message})

    refute_receive {:api, "sendMessage", _}
  end

  test "failed keyboard acknowledgement is never blindly sent twice", c do
    {:ok, receipt} =
      Interactions.request(c.scope, "location", %{"reason" => "Location"}, "cleanup-failure")

    assert_receive {:api, "sendMessage", _}
    Application.put_env(:salix_im, :interaction_test_failure, "sendMessage")

    message = %{
      "message_id" => 42,
      "chat" => %{"id" => 123_456, "type" => "private"},
      "from" => %{"id" => 123_456},
      "text" => "Don't share / Cancel"
    }

    assert {:handled, {:ok, :queued}} =
             Interactions.handle_update(c.connect, %{"message" => message})

    assert_receive {:api, "sendMessage", %{"text" => "Cancelled"}}

    assert {:ok, %{"status" => "delivered", "keyboard_completion" => "unknown"}} =
             Store.get(c.scope["group_id"], receipt["request_id"])

    assert {:handled, {:ok, :duplicate}} =
             Interactions.handle_update(c.connect, %{"message" => message})

    refute_receive {:api, "sendMessage", _}
  end

  test "unbound location rejects ambiguity and preserves explicit reply ownership", c do
    {:ok, receipt} = Interactions.request(c.scope, "location", %{"reason" => "Location"}, "first")
    {:ok, first} = Store.get(c.scope["group_id"], receipt["request_id"])
    {:ok, _} = Store.create(first |> Map.put("id", "second") |> Map.put("message_id", 40))

    message = %{
      "message_id" => 42,
      "chat" => %{"id" => 123_456, "type" => "private"},
      "from" => %{"id" => 123_456},
      "location" => %{"latitude" => 1.3, "longitude" => 103.8}
    }

    assert {:handled, {:ok, :ignored}} =
             Interactions.handle_update(c.connect, %{"message" => message})

    refute_receive {:delivered, _, _, _}
    assert {:ok, %{"status" => "pending"}} = Store.get(c.scope["group_id"], receipt["request_id"])

    assert {:handled, {:ok, :queued}} =
             Interactions.handle_update(c.connect, %{
               "message" => Map.put(message, "reply_to_message", %{"message_id" => 41})
             })
  end

  test "ordinary text, other senders, old messages, and wrong replies cannot answer location",
       c do
    {:ok, _} = Interactions.request(c.scope, "location", %{"reason" => "Location"}, "isolation")

    message = %{
      "message_id" => 42,
      "chat" => %{"id" => 123_456, "type" => "private"},
      "from" => %{"id" => 123_456},
      "location" => %{"latitude" => 1.3, "longitude" => 103.8}
    }

    for candidate <- [
          Map.put(message, "from", %{"id" => 999}),
          Map.put(message, "message_id", 40),
          Map.put(message, "reply_to_message", %{"message_id" => 999}),
          message |> Map.delete("location") |> Map.put("text", "杭州")
        ] do
      assert :unhandled = Interactions.handle_update(c.connect, %{"message" => candidate})
    end

    refute_receive {:delivered, _, _, _}
  end

  test "native webhook retry resumes the saved decision after Router failure", c do
    {:ok, receipt} =
      Interactions.request(c.scope, "location", %{"reason" => "Location"}, "retry-native")

    assert_receive {:api, "sendMessage", _}

    update = %{
      "update_id" => 100,
      "message" => %{
        "message_id" => 42,
        "chat" => %{"id" => 123_456, "type" => "private"},
        "from" => %{"id" => 123_456},
        "location" => %{"latitude" => 1.3, "longitude" => 103.8}
      }
    }

    fail_router_append(c.scope["group_id"])
    assert {:error, _} = SalixIM.ProviderHTTP.handle_telegram_update(c.connect, update)
    :ok = SalixStore.S3.Fake.clear_blackhole()

    assert {:ok, %{"status" => "decided", "response_message_id" => 42}} =
             Store.get(c.scope["group_id"], receipt["request_id"])

    refute_receive {:api, "sendMessage", _}
    assert {:ok, :queued} = SalixIM.ProviderHTTP.handle_telegram_update(c.connect, update)
    assert_receive {:delivered, _, _, _}
    assert {:ok, :duplicate} = SalixIM.ProviderHTTP.handle_telegram_update(c.connect, update)
    refute_receive {:delivered, _, _, _}
  end

  test "expired and reconnected requests cannot own an unbound location", c do
    {:ok, receipt} =
      Interactions.request(c.scope, "location", %{"reason" => "Location"}, "stale-native")

    message = %{
      "message_id" => 42,
      "chat" => %{"id" => 123_456, "type" => "private"},
      "from" => %{"id" => 123_456},
      "location" => %{"latitude" => 1.3, "longitude" => 103.8}
    }

    {:ok, original} = Store.get(c.scope["group_id"], receipt["request_id"])

    {:ok, _} =
      Store.update(c.scope["group_id"], receipt["request_id"], &Map.put(&1, "expires_at", 0))

    assert :unhandled = Interactions.handle_update(c.connect, %{"message" => message})

    {:ok, _} =
      Store.update(c.scope["group_id"], receipt["request_id"], fn _ ->
        put_in(original, ["connect_epoch", "connected_at"], 0)
      end)

    assert :unhandled = Interactions.handle_update(c.connect, %{"message" => message})
    refute_receive {:delivered, _, _, _}
  end

  test "answering an older card does not remove a newer location keyboard", c do
    {:ok, receipt} =
      Interactions.request(c.scope, "location", %{"reason" => "Location"}, "old-card")

    assert_receive {:api, "sendMessage", _}
    {:ok, first} = Store.get(c.scope["group_id"], receipt["request_id"])
    {:ok, _} = Store.create(first |> Map.put("id", "new-card") |> Map.put("message_id", 42))

    message = %{
      "message_id" => 43,
      "chat" => %{"id" => 123_456, "type" => "private"},
      "from" => %{"id" => 123_456},
      "text" => "杭州",
      "reply_to_message" => %{"message_id" => 41}
    }

    assert {:handled, {:ok, :queued}} =
             Interactions.handle_update(c.connect, %{"message" => message})

    refute_receive {:api, "sendMessage", _}
    assert {:ok, %{"status" => "pending"}} = Store.get(c.scope["group_id"], "new-card")
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

    refute_receive {:delivered, _, _, _}
    refute_receive {:api, "editMessageText", _}
    assert {:ok, _} = SalixStore.OAuth.AuthState.consume(state)

    assert :ok =
             SalixStore.OAuth.AuthState.record_completion(state, %{
               "binding_id" => "verified-binding"
             })

    assert {:ok, :queued} = Interactions.oauth_completed(state)
    assert_receive {:delivered, _, payload, _}
    assert inspect(payload) =~ "oauth_completed"
    refute inspect(payload) =~ "verified-binding"
    assert_receive {:api, "editMessageText", card}
    assert card["text"] == "只读日历\n\n✅ Authorization completed"
    assert card["reply_markup"] == %{"inline_keyboard" => []}

    assert {:handled, {:ok, :duplicate}} =
             Interactions.handle_update(c.connect, callback("ci:" <> request_id <> ":verify"))

    refute_receive {:delivered, _, _, _}
  end

  test "OAuth decline cannot revoke an exchange already claimed by the callback", c do
    state = "oauth-claimed-test"
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

    {:ok, _} =
      Interactions.request(
        c.scope,
        "oauth",
        %{
          "reason" => "授权",
          "authorization_url" => "https://example.test/authorize",
          "oauth_state" => state
        },
        "oauth"
      )

    assert {:ok, _} = SalixStore.OAuth.AuthState.consume(state)

    assert {:handled, {:ok, :ignored}} =
             Interactions.handle_update(c.connect, callback("ci:" <> request_id <> ":deny"))

    assert {:ok, %{"status" => "consumed"}} = SalixStore.OAuth.AuthState.get(state)
    refute_receive {:delivered, _, _, _}
  end

  test "competing callbacks persist one immutable decision", c do
    {:ok, result} = Interactions.request(c.scope, "permission", %{"capability" => "read"}, "race")

    tasks =
      for choice <- ["allow", "deny"],
          do:
            Task.async(fn ->
              Interactions.handle_update(
                c.connect,
                callback("ci:" <> result["request_id"] <> ":" <> choice)
              )
            end)

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &(&1 == {:handled, {:ok, :queued}})) == 1
    assert_receive {:delivered, _, _, _}
    refute_receive {:delivered, _, _, _}
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

  defp fail_router_append(group) do
    {:ok, conversation} = SalixIM.RouterConversationInput.ensure(group)

    key =
      SalixStore.Keys.ctl_group_conversation_message_segment(
        group,
        conversation["conversation_id"],
        "000000000000000001"
      )

    :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :put, key})
  end
end
