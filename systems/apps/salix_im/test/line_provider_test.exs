defmodule SalixIM.LineProviderTest do
  @moduledoc """
  The LINE provider for Comma's product LINE account: a managed connect serves
  one LINE user, that user's private messages and group mentions enter the
  Group's Router Conversation, and `line.send_message` answers with the
  message's free reply token first and pushes afterwards.
  """
  use SystemsClock.Case, async: false

  alias SalixIM.{LineInbound, Provider, ProviderConnects, ProviderHTTP}
  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.{CasRecord, Ids, Keys, S3}

  @secret "8c570fa6dd201bb328f1c1eac23a96d8"
  @token "line-channel-access-token"
  @user "U4af4980629a1b2c3d4e5f6a1b2c3d4e5"
  @group "Ca56f94637c1b2c3d4e5f6a1b2c3d4e5f"
  @stranger "U9999980629a1b2c3d4e5f6a1b2c3d4e5"

  defmodule API do
    @moduledoc "A recording stub of the LINE Messaging API."
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)

      if pid = SystemsRuntime.get_env(:salix_im, :line_test_pid),
        do:
          SystemsRuntime.Proc.send(
            pid,
            {:line_api, conn.method, conn.request_path, body, get_req_header(conn, "authorization")}
          )

      {status, answer} = answer(conn.method, conn.path_info, body, conn)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(answer))
    end

    defp answer("GET", ["v2", "bot", "info"], _body, conn) do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> "line-channel-access-token" <> suffix] ->
          {200,
           %{
             "userId" => "Ubot" <> suffix <> "0123456789abcdef0123456789",
             "basicId" => "@123abcde",
             "displayName" => "Acme helper"
           }}

        _other ->
          {401, %{"message" => "Authentication failed. Confirm that the access token is valid."}}
      end
    end

    defp answer("POST", ["v2", "bot", "message", "reply"], %{"replyToken" => "expired"}, _conn),
      do: {400, %{"message" => "Invalid reply token"}}

    defp answer("POST", ["v2", "bot", "message", "reply"], _body, _conn),
      do: {200, %{"sentMessages" => [%{"id" => "461230966842064897"}]}}

    defp answer("POST", ["v2", "bot", "message", "push"], _body, _conn),
      do: {200, %{"sentMessages" => [%{"id" => "461230966842064898"}]}}

    defp answer(_method, _path, _body, _conn), do: {404, %{"message" => "Not found"}}
  end

  setup do
    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      api: SystemsRuntime.get_env(:salix_im, :line_api_base_url)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()
    SystemsRuntime.put_env(:salix_im, :line_api_base_url, BanditServer.serve!(API))
    SystemsRuntime.put_env(:salix_im, :line_test_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      restore(:salix_store, :s3_backend, previous.s3)
      restore(:salix_im, :line_api_base_url, previous.api)
      SystemsRuntime.delete_env(:salix_im, :line_test_pid)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    {group_id, router_id} = group_with_router(tenant)
    suffix = Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))

    {:ok, connect} =
      ProviderConnects.ensure_managed_line_im_connect(tenant, group_id, %{
        "channel_secret" => @secret,
        "channel_access_token" => @token <> suffix,
        "line_user_id" => @user
      })

    :ok =
      ProviderConnects.activate_managed_line_im_connect(tenant, group_id, connect["connect_id"])

    drain()

    %{
      tenant: tenant,
      group_id: group_id,
      router_id: router_id,
      suffix: suffix,
      connect: connect
    }
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp group_with_router(tenant) do
    group_id = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent!(Ids.new_agent_id(group_id), %{
        "tenant_id" => tenant,
        "group_id" => group_id,
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_group(group_id),
        &Map.put(&1, "router_agent_id", router["agent_id"])
      )

    {group_id, router["agent_id"]}
  end

  defp drain do
    receive do
      {:line_api, _method, _path, _body, _authorization} -> drain()
    after
      0 -> :ok
    end
  end

  # The events of one verified request, as Comma hands them over.
  defp deliver(ctx, events) do
    {:ok, connect} =
      ProviderConnects.get_active_connect_by_id(ctx.group_id, ctx.connect["connect_id"], "line")

    Enum.reduce_while(events, :ok, fn event, :ok ->
      case ProviderHTTP.handle_line_event(connect, event) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp message_event(id, text, source, extra \\ %{}) do
    %{
      "type" => "message",
      "mode" => "active",
      "timestamp" => SystemsClock.system_time(:millisecond),
      "webhookEventId" => "01H" <> id,
      "replyToken" => "reply-" <> id,
      "source" => source,
      "message" => Map.merge(%{"type" => "text", "id" => id, "text" => text}, extra)
    }
  end

  defp private_source, do: %{"type" => "user", "userId" => @user}
  defp group_source, do: %{"type" => "group", "groupId" => @group, "userId" => @user}

  defp router_inputs(group_id, source_id) do
    {:ok, conversation} = SalixIM.RouterConversationInput.ensure(group_id)

    {:ok, messages} =
      SalixIM.Conversations.list_group_conversation_messages(
        group_id,
        conversation["conversation_id"],
        limit: 50
      )

    Enum.filter(messages, fn message ->
      get_in(message, ["agent_input", :trusted_origin, "source_message_id"]) == source_id
    end)
  end

  defp send_message(ctx, params, origin) do
    Provider.call_api(ctx.router_id, "line", "line.send_message", %{
      "connect_id" => ctx.connect["connect_id"],
      "params" => params,
      "tool_context" => %{"trusted_origin" => origin}
    })
  end

  defp origin(ctx, chat_id) do
    %{
      "provider" => "line",
      "source_actor_type" => "provider_user",
      "provider_context" => %{"connect_id" => ctx.connect["connect_id"], "chat_id" => chat_id}
    }
  end

  test "a managed connect checks the token, hides the secrets, and serves one LINE user",
       ctx do
    assert %{
             "provider" => "line",
             "status" => "connected",
             "bot_username" => "@123abcde",
             "bot_display_name" => "Acme helper",
             "managed_by" => "comma_product",
             "managed_peer_id" => @user,
             "channel_secret_configured" => true,
             "channel_access_token_configured" => true
           } = ctx.connect

    refute inspect(ctx.connect) =~ @secret
    refute inspect(ctx.connect) =~ @token

    # The product account serves many Groups, one LINE user each.
    {other_group, _router} = group_with_router(ctx.tenant)

    assert {:ok, %{"managed_peer_id" => @stranger, "disabled_at" => disabled_at}} =
             ProviderConnects.ensure_managed_line_im_connect(ctx.tenant, other_group, %{
               "channel_secret" => @secret,
               "channel_access_token" => @token <> ctx.suffix,
               "line_user_id" => @stranger
             })

    # Prepared disabled: Comma activates it after its binding commits.
    assert disabled_at

    assert {:error, {:bad_request, "LINE credential check failed" <> _}} =
             ProviderConnects.ensure_managed_line_im_connect(ctx.tenant, other_group, %{
               "channel_secret" => @secret,
               "channel_access_token" => "wrong",
               "line_user_id" => @user
             })

    # The Comma for Teams pages cannot change it.
    assert {:error, {:bad_request, "Manage this LINE connection in Comma Settings"}} =
             ProviderConnects.enable_im_connect(ctx.tenant, ctx.group_id, ctx.connect["connect_id"])
  end

  test "the signature check accepts only the channel secret's signature" do
    raw = Jason.encode!(%{"destination" => "Ubot", "events" => []})
    signature = :hmac |> :crypto.mac(:sha256, @secret, raw) |> Base.encode64()

    assert :ok = LineInbound.verify_signature(@secret, [{"X-Line-Signature", signature}], raw)

    assert {:error, :invalid_signature} =
             LineInbound.verify_signature(@secret, [{"x-line-signature", "forged"}], raw)

    assert {:error, :invalid_signature} = LineInbound.verify_signature(@secret, [], raw)
    assert {:error, :invalid_signature} = LineInbound.verify_signature("", [], raw)
  end

  test "another LINE user's message never reaches this Group's Router", ctx do
    stranger = %{"type" => "user", "userId" => @stranger}
    assert :ok = deliver(ctx, [message_event("100001", "hello", stranger)])

    assert router_inputs(ctx.group_id, "im_provider:line:#{ctx.connect["connect_id"]}:100001") ==
             []
  end

  test "a private message reaches the Router Conversation once", ctx do
    event = message_event("100002", "營業時間是幾點？", private_source())
    assert :ok = deliver(ctx, [event])
    # LINE can deliver one event again; it is the same Router input.
    assert :ok = deliver(ctx, [event])

    source_id = "im_provider:line:#{ctx.connect["connect_id"]}:100002"
    assert [message] = router_inputs(ctx.group_id, source_id)
    origin = message["agent_input"][:trusted_origin]

    assert origin["provider"] == "line"
    assert origin["source_text"] == "營業時間是幾點？"

    assert Map.take(
             origin["provider_context"],
             ~w(connect_id chat_id chat_type message_id from_user_id)
           ) == %{
             "connect_id" => ctx.connect["connect_id"],
             "chat_id" => "user:" <> @user,
             "chat_type" => "private",
             "message_id" => "100002",
             "from_user_id" => @user
           }
  end

  test "the linked user's group mention reaches the Router; other group messages do not", ctx do
    mention =
      message_event("100003", "@Acme helper 幫我整理今天的訂單", group_source(), %{
        "mention" => %{
          "mentionees" => [
            %{"index" => 0, "length" => 12, "type" => "user", "userId" => "U0", "isSelf" => true}
          ]
        }
      })

    chatter = message_event("100004", "午餐吃什麼", group_source())

    other_mention =
      message_event(
        "100008",
        "@Acme helper hi",
        %{"type" => "group", "groupId" => @group, "userId" => @stranger},
        %{"mention" => %{"mentionees" => [%{"type" => "user", "isSelf" => true}]}}
      )

    standby = Map.put(message_event("100005", "hi", private_source()), "mode", "standby")

    assert :ok = deliver(ctx, [mention, chatter, standby, other_mention])

    prefix = "im_provider:line:#{ctx.connect["connect_id"]}:"
    assert [message] = router_inputs(ctx.group_id, prefix <> "100003")
    context = message["agent_input"][:trusted_origin]["provider_context"]
    assert context["chat_id"] == "group:" <> @group
    assert context["chat_type"] == "group"

    assert router_inputs(ctx.group_id, prefix <> "100004") == []
    assert router_inputs(ctx.group_id, prefix <> "100005") == []
    assert router_inputs(ctx.group_id, prefix <> "100008") == []
  end

  test "a send spends the message's reply token once, then pushes", ctx do
    assert :ok = deliver(ctx, [message_event("100006", "hi", private_source())])
    chat_id = "user:" <> @user
    authorization = ["Bearer " <> @token <> ctx.suffix]

    assert {:ok, %{"delivery" => "reply", "chat_id" => ^chat_id}} =
             send_message(ctx, %{"text" => "您好！"}, origin(ctx, chat_id))

    assert_received {:line_api, "POST", "/v2/bot/message/reply",
                     %{
                       "replyToken" => "reply-100006",
                       "messages" => [%{"type" => "text", "text" => "您好！"}]
                     }, ^authorization}

    assert {:ok, %{"delivery" => "push"}} =
             send_message(ctx, %{"text" => "整理好了。"}, origin(ctx, chat_id))

    assert_received {:line_api, "POST", "/v2/bot/message/push",
                     %{"to" => @user, "messages" => [%{"text" => "整理好了。"}]}, ^authorization}

    # LINE refusing a token means nothing went out: the send pushes instead.
    expired = Map.put(message_event("100007", "again", private_source()), "replyToken", "expired")
    assert :ok = deliver(ctx, [expired])

    assert {:ok, %{"delivery" => "push"}} =
             send_message(ctx, %{"text" => "收到。"}, origin(ctx, chat_id))

    assert_received {:line_api, "POST", "/v2/bot/message/reply", %{"replyToken" => "expired"},
                     _authorization}

    assert_received {:line_api, "POST", "/v2/bot/message/push", %{"to" => @user},
                     _authorization}

    # A chat that never wrote to the account is pushed to directly; a text
    # over one message's limit goes out as several.
    long = String.duplicate("a", 5_001)

    assert {:ok, %{"delivery" => "push"}} =
             send_message(ctx, %{"chat_id" => "group:" <> @group, "text" => long}, nil)

    assert_received {:line_api, "POST", "/v2/bot/message/push",
                     %{"to" => @group, "messages" => [_first, %{"text" => "a"}]}, _authorization}
  end
end
