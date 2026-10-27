defmodule SalixIM.LarkProviderTest do
  @moduledoc """
  The Lark provider: a connect holds one Lark app's credentials, a verified
  callback of a private chat or a group mention enters the Group's Router
  Conversation once, `lark.send_message` answers in a chat or writes to one
  person, and every delivered message is recorded for `lark.search_messages`
  in a store of its own, which also reads in the history of the bot's chats.
  A file of an earlier message is fetched by a reference only its own connect
  takes. The chats and people of routed messages and the
  organization's directory are read with their own operations, and each
  callback leaves a diagnostic.
  """
  use SystemsClock.Case, async: false

  use SalixStore.QueueCase,
    queues: [:lark_mirror_outbox, :lark_mirror_backfill, :feishu_mirror_outbox]

  alias SalixIM.{Provider, ProviderConnects, ProviderHTTP}
  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.{CasRecord, Ids, Keys, S3}

  @secret "lark-app-secret"
  @token "lark-verification-token"
  @encrypt_key "lark-encrypt-key"
  @bot "ou_bot"
  @user "ou_alice"
  @group "oc_group"
  @private "oc_private"

  defmodule API do
    @moduledoc "A recording stub of the Lark OpenAPI."
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)

      body =
        case Jason.decode(raw) do
          {:ok, body} -> body
          _not_json -> %{"bytes" => byte_size(raw)}
        end

      conn = fetch_query_params(conn)
      ["open-apis" | path] = conn.path_info

      if pid = SystemsRuntime.get_env(:salix_im, :lark_test_pid),
        do: SystemsRuntime.Proc.send(pid, {:lark_api, conn.method, path, body, conn.params})

      case {conn.method, path} do
        # The bytes of a file of a message.
        {"GET", ["im", "v1", "messages", _message_id, "resources", _file_key]} ->
          conn
          |> put_resp_content_type("application/pdf")
          |> put_resp_header("content-disposition", ~s(attachment; filename="plan.pdf"))
          |> send_resp(200, "PLAN-BYTES")

        _json ->
          {status, answer} =
            case {conn.method, path} do
              {"GET", ["im", "v1", "messages"]} -> history(conn.params["container_id"])
              _other -> answer(conn.method, path, body)
            end

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(answer))
      end
    end

    # One page of a chat or a thread: the messages a test put there.
    defp history(container_id) do
      items =
        :salix_im
        |> SystemsRuntime.get_env(:lark_test_history, %{})
        |> Map.get(container_id, [])

      {200, %{"code" => 0, "data" => %{"items" => items, "has_more" => false}}}
    end

    defp answer("GET", ["im", "v1", "chats"], _body) do
      {200,
       %{"code" => 0, "data" => %{"items" => [%{"chat_id" => "oc_group"}], "has_more" => false}}}
    end

    defp answer("POST", ["auth", "v3", "tenant_access_token", "internal"], body) do
      if body["app_secret"] == "wrong",
        do: {200, %{"code" => 10_014, "msg" => "app secret invalid"}},
        else:
          {200, %{"code" => 0, "tenant_access_token" => "t-" <> body["app_id"], "expire" => 7200}}
    end

    # An app without the Bot capability has no bot to name.
    defp answer("GET", ["bot", "v3", "info"], _body) do
      if SystemsRuntime.get_env(:salix_im, :lark_test_no_bot, false),
        do: {200, %{"code" => 0, "msg" => "ok", "bot" => %{}}},
        else:
          {200,
           %{
             "code" => 0,
             "msg" => "ok",
             "bot" => %{"open_id" => "ou_bot", "app_name" => "Bridge"}
           }}
    end

    # A message to a chat is of that chat. A message to a person is of the
    # private chat of the bot and that person.
    defp answer("POST", ["im", "v1", "messages"], body) do
      case body["receive_id"] do
        "oc_" <> _rest = chat_id -> sent(body, chat_id)
        _person -> sent(body, "oc_direct")
      end
    end

    # A reply in a thread is a message of the thread of the message it
    # answers: the thread that message is in, or a new one it opens. A test
    # says which thread a message it delivered is in.
    defp answer("POST", ["im", "v1", "messages", message_id, "reply"], body) do
      {status, answer} = sent(body, "oc_group")
      threads = SystemsRuntime.get_env(:salix_im, :lark_test_threads, %{})

      if body["reply_in_thread"] == true,
        do:
          {status,
           put_in(
             answer,
             ["data", "thread_id"],
             Map.get(threads, message_id, "omt_" <> message_id)
           )},
        else: {status, answer}
    end

    # The chat a message is in, and who wrote it. A message a test put into
    # a chat's history is read as it is there.
    defp answer("GET", ["im", "v1", "messages", message_id], _body) do
      :salix_im
      |> SystemsRuntime.get_env(:lark_test_history, %{})
      |> Map.values()
      |> List.flatten()
      |> Enum.find(&(&1["message_id"] == message_id))
      |> case do
        nil -> earlier_message(message_id)
        message -> {200, %{"code" => 0, "data" => %{"items" => [message]}}}
      end
    end

    defp answer("PUT", ["im", "v1", "messages", _message_id], _body),
      do: {200, %{"code" => 0, "data" => %{}}}

    # One chat as Lark describes it, and its members: what a test put there.
    defp answer("GET", ["im", "v1", "chats", chat_id], _body) do
      case SystemsRuntime.get_env(:salix_im, :lark_test_chats, %{}) do
        %{^chat_id => chat} -> {200, %{"code" => 0, "data" => Map.delete(chat, "members")}}
        _unknown -> {404, %{"code" => 404, "msg" => "not found"}}
      end
    end

    defp answer("GET", ["im", "v1", "chats", chat_id, "members"], _body) do
      case SystemsRuntime.get_env(:salix_im, :lark_test_chats, %{}) do
        %{^chat_id => %{"members" => members} = chat} ->
          {200,
           %{
             "code" => 0,
             "data" => %{
               "items" => Enum.map(members, &%{"member_id" => &1, "member_id_type" => "open_id"}),
               "has_more" => chat["more_members"] == true
             }
           }}

        _unknown ->
          {404, %{"code" => 404, "msg" => "not found"}}
      end
    end

    defp answer("POST", ["im", "v1", "files"], _body),
      do: {200, %{"code" => 0, "data" => %{"file_key" => "file_v2_report"}}}

    defp answer("GET", ["contact", "v3", "scopes"], _body) do
      {200,
       %{
         "code" => 0,
         "data" => %{
           "department_ids" => ["od_eng"],
           "user_ids" => ["ou_alice"],
           "has_more" => false
         }
       }}
    end

    defp answer("GET", ["contact", "v3", "departments", _department_id, "children"], _body) do
      {200,
       %{
         "code" => 0,
         "data" => %{
           "items" => [%{"open_department_id" => "od_eng", "name" => "Engineering"}],
           "has_more" => true,
           "page_token" => "next-departments"
         }
       }}
    end

    defp answer("GET", ["contact", "v3", "users", "find_by_department"], _body) do
      {200,
       %{
         "code" => 0,
         "data" => %{
           "items" => [%{"open_id" => "ou_alice", "name" => "Alice"}],
           "has_more" => false
         }
       }}
    end

    defp answer(_method, _path, _body), do: {404, %{"code" => 404, "msg" => "not found"}}

    defp earlier_message(message_id) do
      {chat_id, sender} =
        case message_id do
          "om_elsewhere" -> {"oc_other", %{"id" => "ou_alice", "sender_type" => "user"}}
          "om_person" -> {"oc_group", %{"id" => "ou_alice", "sender_type" => "user"}}
          _bot -> {"oc_group", %{"id" => "ou_bot", "sender_type" => "app"}}
        end

      {200,
       %{
         "code" => 0,
         "data" => %{
           "items" => [
             %{
               "message_id" => message_id,
               "chat_id" => chat_id,
               "msg_type" => "text",
               "create_time" => "1791900000000",
               "sender" => sender,
               "body" => %{"content" => ~s({"text":"earlier"})}
             }
           ]
         }
       }}
    end

    defp sent(body, chat_id) do
      {200,
       %{
         "code" => 0,
         "data" => %{
           "message_id" => "om_sent#{SystemsRuntime.Proc.unique_integer([:positive])}",
           "chat_id" => chat_id,
           "msg_type" => body["msg_type"],
           "create_time" => "1791900001000",
           "sender" => %{"id" => "ou_bot", "sender_type" => "app"},
           "body" => %{"content" => body["content"]}
         }
       }}
    end
  end

  defmodule RecordStore do
    @moduledoc "Stands in for the ClickHouse table: keeps the rows the drainer writes."
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def rows, do: Agent.get(__MODULE__, & &1)

    # As the table does, keep the newest state of each message.
    def record_batch(rows) do
      Agent.update(__MODULE__, fn stored ->
        (rows ++ stored)
        |> Enum.sort_by(& &1["version"], :desc)
        |> Enum.uniq_by(&{&1["app_id"], &1["chat_id"], &1["message_id"]})
      end)
    end

    def search(scope, opts) do
      messages =
        rows()
        |> Enum.filter(
          &(&1["tenant_id"] == scope["tenant_id"] and &1["app_id"] == scope["app_id"] and
              not &1["deleted"])
        )
        |> Enum.filter(&(is_nil(opts[:chat_id]) or &1["chat_id"] == opts[:chat_id]))
        |> Enum.filter(&(opts[:has_file] != true or &1["file_count"] > 0))
        |> Enum.filter(fn row ->
          Enum.all?(List.wrap(opts[:patterns]), fn pattern ->
            String.contains?(row["text"], String.trim(pattern, "%"))
          end)
        end)
        |> Enum.sort_by(&{&1["create_time_us"], &1["message_id"]}, :desc)
        |> Enum.take(opts[:limit])

      {:ok, %{messages: messages, next_cursor: nil, has_more?: false}}
    end
  end

  defmodule Workspace do
    @moduledoc false
    def read_stream(_agent_id, "/artifacts/report.pdf"),
      do: {:ok, ["%PDF-1.7 ", "report"], 15, "report.pdf"}

    def read_stream(agent_id, path),
      do: SalixIM.TestSupport.AgentWorkspace.read_stream(agent_id, path)

    defdelegate put_ref(agent_id, path, ref), to: SalixIM.TestSupport.AgentWorkspace
    defdelegate read_upload(agent_id, path, title), to: SalixIM.TestSupport.AgentWorkspace
  end

  setup do
    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      api: SystemsRuntime.get_env(:salix_im, :lark_api_base_url),
      sink: SystemsRuntime.get_env(:salix_im, :diagnostic_sink),
      workspace: SystemsRuntime.get_env(:salix_im, :agent_workspace_mod),
      writer: SystemsRuntime.get_env(:salix_im, :lark_message_record_mod),
      reader: SystemsRuntime.get_env(:salix_im, :lark_message_record_reader_mod)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    start_supervised!(RecordStore)
    SalixAgent.TestSupport.configure_control_fixtures!()

    SystemsRuntime.put_env(
      :salix_im,
      :lark_api_base_url,
      BanditServer.serve!(API) <> "/open-apis"
    )

    SystemsRuntime.put_env(:salix_im, :agent_workspace_mod, Workspace)
    SystemsRuntime.put_env(:salix_im, :lark_message_record_mod, RecordStore)
    SystemsRuntime.put_env(:salix_im, :lark_message_record_reader_mod, RecordStore)
    SystemsRuntime.put_env(:salix_im, :lark_test_pid, SystemsRuntime.Proc.self())
    SalixIM.Provider.Lark.API.reset_token_cache()

    SalixStore.Repo.query!(
      "TRUNCATE lark_mirror_outbox, lark_mirror_containers, feishu_mirror_outbox"
    )

    on_exit(fn ->
      restore(:salix_store, :s3_backend, previous.s3)
      restore(:salix_im, :lark_api_base_url, previous.api)
      restore(:salix_im, :diagnostic_sink, previous.sink)
      restore(:salix_im, :agent_workspace_mod, previous.workspace)
      restore(:salix_im, :lark_message_record_mod, previous.writer)
      restore(:salix_im, :lark_message_record_reader_mod, previous.reader)
      SystemsRuntime.delete_env(:salix_im, :lark_test_pid)
      SystemsRuntime.delete_env(:salix_im, :lark_test_no_bot)
      SystemsRuntime.delete_env(:salix_im, :lark_test_threads)
      SystemsRuntime.delete_env(:salix_im, :lark_test_history)
      SystemsRuntime.delete_env(:salix_im, :lark_test_chats)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    {group_id, router_id} = group_with_router(tenant)
    app_id = "cli_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    {:ok, connect} = ProviderConnects.create_lark_im_connect(tenant, group_id, attrs(app_id))

    drain()
    %{tenant: tenant, group_id: group_id, router_id: router_id, app_id: app_id, connect: connect}
  end

  defp attrs(app_id, extra \\ %{}) do
    Map.merge(
      %{
        "app_id" => app_id,
        "app_secret" => @secret,
        "verification_token" => @token,
        "encrypt_key" => @encrypt_key
      },
      extra
    )
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

  # Drops the API calls a setup step made, so a test asserts only its own.
  defp drain do
    receive do
      {:lark_api, _method, _path, _body, _params} -> drain()
    after
      0 -> :ok
    end
  end

  # One callback as Lark sends it without an Encrypt Key in use: the plain
  # envelope, which carries the Verification Token.
  defp deliver(ctx, envelope, headers \\ []),
    do: ProviderHTTP.handle_lark_request(ctx.app_id, envelope, headers, Jason.encode!(envelope))

  defp message_event(message_id, chat_id, chat_type, text, opts \\ []) do
    %{
      "schema" => "2.0",
      "header" => %{
        "event_id" => "evt_" <> message_id,
        "event_type" => "im.message.receive_v1",
        "token" => Keyword.get(opts, :token, @token),
        "tenant_key" => "tenant_key_1"
      },
      "event" => %{
        "sender" =>
          Keyword.get(opts, :sender, %{
            "sender_id" => %{"open_id" => @user, "user_id" => "alice"},
            "sender_type" => "user"
          }),
        "message" => %{
          "message_id" => message_id,
          "chat_id" => chat_id,
          "chat_type" => chat_type,
          "message_type" => "text",
          "create_time" => Integer.to_string(SystemsClock.system_time(:millisecond)),
          "content" => Jason.encode!(%{"text" => text}),
          "mentions" => Keyword.get(opts, :mentions, [])
        }
      }
    }
  end

  defp bot_mention, do: %{"key" => "@_user_1", "name" => "Bridge", "id" => %{"open_id" => @bot}}

  # Lark's wire form with an Encrypt Key: base64(iv ++ AES-256-CBC(pkcs7(json))).
  defp encrypt(envelope, key) do
    json = Jason.encode!(envelope)
    pad = 16 - rem(byte_size(json), 16)
    iv = :binary.copy(<<7>>, 16)

    cipher =
      :crypto.crypto_one_time(
        :aes_256_cbc,
        :crypto.hash(:sha256, key),
        iv,
        json <> :binary.copy(<<pad>>, pad),
        true
      )

    %{"encrypt" => Base.encode64(iv <> cipher)}
  end

  defp origin(ctx, chat_id, message_id) do
    %{
      "provider" => "lark",
      "source_actor_type" => "provider_user",
      "provider_context" => %{
        "connect_id" => ctx.connect["connect_id"],
        "chat_id" => chat_id,
        "message_id" => message_id
      }
    }
  end

  defp call(ctx, api, params, origin \\ nil) do
    Provider.call_api(ctx.router_id, "lark", api, %{
      "connect_id" => ctx.connect["connect_id"],
      "params" => params,
      "tool_context" => %{"trusted_origin" => origin}
    })
  end

  # Sends each diagnostic to the test from here on.
  defp capture_diagnostics do
    test = SystemsRuntime.Proc.self()

    SystemsRuntime.put_env(:salix_im, :diagnostic_sink, fn diagnostic ->
      SystemsRuntime.Proc.send(test, {:diagnostic, diagnostic})
    end)
  end

  defp diagnostics(acc \\ []) do
    receive do
      {:diagnostic, diagnostic} -> diagnostics([diagnostic | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Waits for what a background task writes: `fun` until it returns a
  # non-empty list.
  defp wait_for(fun, attempts \\ 400) do
    case fun.() do
      [] when attempts > 0 ->
        SystemsClock.sleep(25)
        wait_for(fun, attempts - 1)

      result ->
        result
    end
  end

  defp router_inputs(ctx, message_id) do
    {:ok, conversation} = SalixIM.RouterConversationInput.ensure(ctx.group_id)

    {:ok, messages} =
      SalixIM.Conversations.list_group_conversation_messages(
        ctx.group_id,
        conversation["conversation_id"],
        limit: 50
      )

    source_id = "im_provider:lark:#{ctx.connect["connect_id"]}:#{message_id}"

    Enum.filter(messages, fn message ->
      get_in(message, ["agent_input", "trusted_origin", "source_message_id"]) == source_id
    end)
  end

  describe "connect" do
    test "a connect checks the credentials, hides the secrets, and owns its app", ctx do
      assert %{
               "provider" => "lark",
               "status" => "connected",
               "app_name" => "Bridge",
               "bot_open_id" => @bot,
               "app_secret_configured" => true,
               "verification_token_configured" => true,
               "encrypt_key_configured" => true
             } = ctx.connect

      assert ctx.connect["webhook_url"] =~ "/v1/im/lark/events?app_id=#{ctx.app_id}"

      for secret <- [@secret, @token, @encrypt_key],
          do: refute(inspect(ctx.connect) =~ secret)

      # One Lark app serves one Group.
      {other_group, _router} = group_with_router(ctx.tenant)

      assert {:error, {:bad_request, message}} =
               ProviderConnects.create_lark_im_connect(ctx.tenant, other_group, attrs(ctx.app_id))

      assert message =~ "already used by another connect"

      assert {:error, {:bad_request, "Lark credential check failed" <> _}} =
               ProviderConnects.create_lark_im_connect(
                 ctx.tenant,
                 other_group,
                 attrs("cli_other", %{"app_secret" => "wrong"})
               )

      # Without either value no callback could be verified.
      assert {:error, {:bad_request, "verification_token or encrypt_key is required"}} =
               ProviderConnects.create_lark_im_connect(
                 ctx.tenant,
                 other_group,
                 attrs("cli_other", %{"verification_token" => "", "encrypt_key" => " "})
               )

      SystemsRuntime.put_env(:salix_im, :lark_test_no_bot, true)

      assert {:error, {:bad_request, "Lark app has no bot" <> _}} =
               ProviderConnects.create_lark_im_connect(
                 ctx.tenant,
                 other_group,
                 attrs("cli_other")
               )
    end

    test "a Feishu connect and a Lark connect of one tenant do not meet", ctx do
      # The same App ID as a Feishu identity is another app of another platform.
      assert :ok = SalixIM.ProviderIdentity.ensure_available("feishu", ctx.app_id)
      assert {:error, :not_found} = ProviderHTTP.handle_feishu_request(ctx.app_id, %{}, [], "{}")
    end
  end

  describe "webhook" do
    test "the request URL check echoes the challenge only for the app's token", ctx do
      check = %{"type" => "url_verification", "challenge" => "c-123", "token" => @token}
      assert {:ok, %{"challenge" => "c-123"}} = deliver(ctx, check)
      assert {:error, :invalid_token} = deliver(ctx, %{check | "token" => "another"})
      assert {:error, :not_found} = ProviderHTTP.handle_lark_request("cli_unknown", check, [], "")
    end

    test "an encrypted callback is accepted by its key and its signature", ctx do
      # With an Encrypt Key the envelope carries no token of its own.
      event = message_event("om_encrypted", @private, "p2p", "hello", token: "")
      envelope = encrypt(event, @encrypt_key)
      raw = Jason.encode!(envelope)

      signature =
        :crypto.hash(:sha256, "1791900000" <> "nonce" <> @encrypt_key <> raw)
        |> Base.encode16(case: :lower)

      headers = [
        {"x-lark-request-timestamp", "1791900000"},
        {"x-lark-request-nonce", "nonce"},
        {"x-lark-signature", signature}
      ]

      assert {:ok, %{"ok" => true}} =
               ProviderHTTP.handle_lark_request(ctx.app_id, envelope, headers, raw)

      assert [_input] = router_inputs(ctx, "om_encrypted")

      # A wrong signature refuses the callback whatever it holds.
      forged = List.keyreplace(headers, "x-lark-signature", 0, {"x-lark-signature", "00"})

      assert {:error, :invalid_signature} =
               ProviderHTTP.handle_lark_request(ctx.app_id, envelope, forged, raw)

      # An envelope encrypted with another key is not this app's.
      assert {:error, :invalid_signature} = deliver(ctx, encrypt(event, "another-key"))
    end

    test "a callback with a wrong token reaches nobody", ctx do
      event = message_event("om_forged", @private, "p2p", "hello", token: "another")
      assert {:error, :invalid_token} = deliver(ctx, event)
      assert router_inputs(ctx, "om_forged") == []
    end

    test "a private message reaches the Router Conversation once", ctx do
      event = message_event("om_private", @private, "p2p", "what can you do?")
      assert {:ok, %{"ok" => true, "status" => "queued"}} = deliver(ctx, event)
      # Lark can deliver one message again; the answer says it is known.
      assert {:ok, %{"ok" => true, "status" => "duplicate"}} = deliver(ctx, event)

      assert [message] = router_inputs(ctx, "om_private")
      origin = message["agent_input"]["trusted_origin"]
      assert origin["provider"] == "lark"
      assert origin["source_text"] == "what can you do?"

      assert Map.take(
               origin["provider_context"],
               ~w(connect_id chat_id chat_type message_id sender_open_id)
             ) == %{
               "connect_id" => ctx.connect["connect_id"],
               "chat_id" => @private,
               "chat_type" => "p2p",
               "message_id" => "om_private",
               "sender_open_id" => @user
             }
    end

    test "a delivery that failed is handled when Lark delivers it again", ctx do
      event = message_event("om_retry", @private, "p2p", "hello")
      group = Keys.ctl_group(ctx.group_id)

      {:ok, _} = CasRecord.update(group, &Map.delete(&1, "router_agent_id"))
      assert {:error, :router_not_configured} = deliver(ctx, event)

      # The failure left no receipt: the next delivery is not a duplicate.
      {:ok, _} = CasRecord.update(group, &Map.put(&1, "router_agent_id", ctx.router_id))
      assert {:ok, %{"status" => "queued"}} = deliver(ctx, event)
      assert [_input] = router_inputs(ctx, "om_retry")
    end

    test "a delivery that stopped before its receipt is delivered again, as one input", ctx do
      event = message_event("om_stopped", @private, "p2p", "hello")
      receipt = Keys.ctl_im_lark_event_receipt(ctx.connect["connect_id"], "om_stopped")

      # The Router took the message, and the delivery stopped before the
      # receipt: Lark got no answer and delivers again.
      assert {:ok, %{"status" => "queued"}} = deliver(ctx, event)
      assert {:ok, _written} = CasRecord.get(receipt)
      :ok = SalixIM.ProviderReceipts.delete_lark(ctx.connect["connect_id"], "om_stopped")
      assert {:error, :not_found} = CasRecord.get(receipt)

      assert {:ok, %{"status" => "queued"}} = deliver(ctx, event)
      assert [_one_input] = router_inputs(ctx, "om_stopped")
      # With its receipt the next delivery costs nothing.
      assert {:ok, %{"status" => "duplicate"}} = deliver(ctx, event)
    end

    test "a receipt is never ahead of the Router", ctx do
      event = message_event("om_ahead", @private, "p2p", "hello")
      group = Keys.ctl_group(ctx.group_id)
      receipt = Keys.ctl_im_lark_event_receipt(ctx.connect["connect_id"], "om_ahead")

      # A delivery the Router did not take leaves no receipt behind it.
      {:ok, _} = CasRecord.update(group, &Map.delete(&1, "router_agent_id"))
      assert {:error, :router_not_configured} = deliver(ctx, event)
      assert {:error, :not_found} = CasRecord.get(receipt)

      {:ok, _} = CasRecord.update(group, &Map.put(&1, "router_agent_id", ctx.router_id))
      assert {:ok, %{"status" => "queued"}} = deliver(ctx, event)
      assert {:ok, _receipt} = CasRecord.get(receipt)
    end

    test "an envelope with a wrong shape is refused before anything reads it", ctx do
      event = message_event("om_shape", @private, "p2p", "hello")

      malformed = [
        ["not", "an", "object"],
        put_in(event, ["event", "message"], "om_shape"),
        put_in(event, ["event", "message", "chat_id"], %{"id" => @private}),
        put_in(event, ["event", "sender", "sender_id"], [@user]),
        put_in(event, ["event", "sender", "sender_id", "open_id"], 7),
        put_in(event, ["event", "message", "mentions"], %{"key" => "@_user_1"}),
        put_in(event, ["event", "message", "mentions"], [%{"id" => @bot}]),
        put_in(event, ["header", "event_id"], ["evt"])
      ]

      for envelope <- malformed do
        assert {:error, :invalid_envelope} = deliver(ctx, envelope)
      end

      assert router_inputs(ctx, "om_shape") == []
      # The same message in its right shape is a first delivery.
      assert {:ok, %{"status" => "queued"}} = deliver(ctx, event)
    end

    test "each callback leaves a diagnostic with IDs and no content", ctx do
      capture_diagnostics()
      connect_id = ctx.connect["connect_id"]
      source_id = "im_provider:lark:#{connect_id}:om_diag"

      check = %{"type" => "url_verification", "challenge" => "c-123", "token" => @token}
      assert {:ok, _challenge} = deliver(ctx, check)

      assert [%{event_type: "lark.callback.challenge_verified", callback_mode: "challenge"}] =
               diagnostics()

      event = message_event("om_diag", @private, "p2p", "the launch code is tulip")
      assert {:ok, _queued} = deliver(ctx, event, [{"x-request-id", "req-1"}])

      assert [
               %{event_type: "lark.message.received", domain: "conversation"},
               %{event_type: "lark.message.delivered", status: "delivered"},
               %{event_type: "lark.callback.queued", domain: "integration"} = queued
             ] = delivered = diagnostics()

      assert queued == %{
               provider: "lark",
               source: "salix.im",
               domain: "integration",
               event_type: "lark.callback.queued",
               severity: "info",
               status: "queued",
               summary: "Lark callback queued",
               tenant_id: ctx.tenant,
               group_id: ctx.group_id,
               connect_id: connect_id,
               app_id: ctx.app_id,
               provider_event_type: "im.message.receive_v1",
               provider_event_id: "evt_om_diag",
               request_id: "req-1",
               message_id: "om_diag",
               source_message_id: source_id,
               chat_id: @private,
               chat_type: "p2p",
               callback_mode: "message",
               delivery_state: "queued"
             }

      assert {:ok, _duplicate} = deliver(ctx, event)

      assert [%{event_type: "lark.callback.duplicate", reason_class: "duplicate_event"}] =
               duplicate = diagnostics()

      # Group talk that is not for the bot is expected: it is no warning.
      assert {:ok, _ack} = deliver(ctx, message_event("om_talk", @group, "group", "lunch?"))

      assert [
               %{
                 event_type: "lark.callback.ignored",
                 severity: "info",
                 reason_class: "not_for_bot"
               }
             ] = ignored = diagnostics()

      forged = message_event("om_forged", @private, "p2p", "hello", token: "another")
      assert {:error, :invalid_token} = deliver(ctx, forged)

      assert [
               %{
                 event_type: "lark.callback.rejected",
                 severity: "warning",
                 reason_class: "invalid_token"
               }
             ] = rejected = diagnostics()

      {:ok, _} =
        CasRecord.update(Keys.ctl_group(ctx.group_id), &Map.delete(&1, "router_agent_id"))

      assert {:error, :router_not_configured} =
               deliver(ctx, message_event("om_lost", @private, "p2p", "hello"))

      assert [
               %{event_type: "lark.message.received"},
               %{
                 event_type: "lark.message.delivery_failed",
                 severity: "error",
                 reason_class: "router_not_configured"
               },
               %{event_type: "lark.callback.failed", severity: "error"}
             ] = failed = diagnostics()

      all = inspect(delivered ++ duplicate ++ ignored ++ rejected ++ failed, limit: :infinity)
      for hidden <- ["tulip", "lunch", @secret, @token, @encrypt_key], do: refute(all =~ hidden)
    end

    test "a diagnostic sink that fails does not change the answer", ctx do
      SystemsRuntime.put_env(:salix_im, :diagnostic_sink, fn _diagnostic -> raise "sink down" end)

      assert {:ok, %{"status" => "queued"}} =
               deliver(ctx, message_event("om_sink", @private, "p2p", "hello"))

      assert [_input] = router_inputs(ctx, "om_sink")
    end

    test "a group message reaches the Router only when it mentions the bot", ctx do
      assert {:ok, %{"ok" => true}} =
               deliver(ctx, message_event("om_chatter", @group, "group", "lunch?"))

      # A mention of somebody else is not for the bot.
      carol = %{"key" => "@_user_1", "name" => "Carol", "id" => %{"open_id" => "ou_carol"}}

      assert {:ok, %{"ok" => true}} =
               deliver(
                 ctx,
                 message_event("om_other", @group, "group", "@_user_1 lunch?", mentions: [carol])
               )

      mention =
        message_event("om_mention", @group, "group", "@_user_1 summarize @_user_2",
          mentions: [bot_mention(), %{carol | "key" => "@_user_2"}]
        )

      assert {:ok, %{"ok" => true}} = deliver(ctx, mention)

      assert router_inputs(ctx, "om_chatter") == []
      assert router_inputs(ctx, "om_other") == []
      assert [message] = router_inputs(ctx, "om_mention")
      origin = message["agent_input"]["trusted_origin"]
      # The bot's own mention is not part of the request; another person's is.
      assert origin["source_text"] == "summarize @Carol"
    end

    test "a control command is answered under its message and never reaches the Router", ctx do
      previous = SystemsRuntime.get_env(:salix_im, :control_command_execution)
      SystemsRuntime.put_env(:salix_im, :control_command_execution, :sync)
      on_exit(fn -> restore(:salix_im, :control_command_execution, previous) end)

      command =
        message_event("om_cmd", @group, "group", "@_user_1 <salix-command>help</salix-command>")

      command = put_in(command, ["event", "message", "mentions"], [bot_mention()])
      assert {:ok, %{"ok" => true}} = deliver(ctx, command)

      # The answer is literal text, not Markdown.
      assert_received {:lark_api, "POST", ["im", "v1", "messages", "om_cmd", "reply"],
                       %{"msg_type" => "text", "content" => content}, _params}

      assert content =~ "status"
      assert router_inputs(ctx, "om_cmd") == []
    end

    test "a control command delivered again, or twice at once, runs once", ctx do
      previous = SystemsRuntime.get_env(:salix_im, :control_command_execution)
      SystemsRuntime.put_env(:salix_im, :control_command_execution, :sync)
      on_exit(fn -> restore(:salix_im, :control_command_execution, previous) end)

      command = fn id ->
        message_event(id, @group, "group", "@_user_1 <salix-command>help</salix-command>",
          mentions: [bot_mention()]
        )
      end

      answers = fn id ->
        Stream.repeatedly(fn ->
          receive do
            {:lark_api, "POST", ["im", "v1", "messages", ^id, "reply"], _body, _params} -> :answer
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)
        |> length()
      end

      assert {:ok, %{"status" => "command"}} = deliver(ctx, command.("om_cmd_again"))
      assert {:ok, %{"status" => "duplicate"}} = deliver(ctx, command.("om_cmd_again"))
      assert answers.("om_cmd_again") == 1

      # A command whose delivery stopped after its claim is not run again:
      # nothing else says whether it started.
      receipt = Keys.ctl_im_lark_event_receipt(ctx.connect["connect_id"], "om_cmd_claimed")
      {:ok, _} = CasRecord.create(receipt, %{"event_id" => "om_cmd_claimed"})
      assert {:ok, %{"status" => "duplicate"}} = deliver(ctx, command.("om_cmd_claimed"))
      assert answers.("om_cmd_claimed") == 0

      # Two deliveries at the same time: one claim, one run.
      test = SystemsRuntime.Proc.self()
      SystemsRuntime.put_env(:salix_im, :lark_test_pid, test)

      deliveries =
        for _n <- 1..2, do: Task.async(fn -> deliver(ctx, command.("om_cmd_twice")) end)

      statuses =
        Task.await_many(deliveries, :infinity)
        |> Enum.map(fn {:ok, %{"status" => status}} -> status end)
        |> Enum.sort()

      assert statuses == ["command", "duplicate"]
      assert answers.("om_cmd_twice") == 1
      assert router_inputs(ctx, "om_cmd_again") == []
    end

    test "people go on in a thread the bot answered in without another mention", ctx do
      thread = "omt_om_first"

      in_thread = fn id, text, thread_id ->
        id
        |> message_event(@group, "group", text)
        |> put_in(["event", "message", "thread_id"], thread_id)
      end

      # Before the bot answered, a message of a thread is group talk.
      assert {:ok, %{"ok" => true}} = deliver(ctx, in_thread.("om_early", "anyone?", thread))
      assert router_inputs(ctx, "om_early") == []

      first = message_event("om_first", @group, "group", "@_user_1 hi", mentions: [bot_mention()])
      assert {:ok, %{"ok" => true}} = deliver(ctx, first)
      assert [_input] = router_inputs(ctx, "om_first")

      # The bot answers under the mention: the reply opens the thread.
      assert {:ok, %{"message" => %{"thread_id" => ^thread}}} =
               call(
                 ctx,
                 "lark.send_message",
                 %{"text" => "Hello.", "reply_to" => "om_first"},
                 origin(ctx, @group, "om_first")
               )

      # The person goes on in the thread and does not mention the bot.
      SystemsRuntime.put_env(:salix_im, :lark_test_threads, %{
        "om_follow" => thread,
        "om_again" => thread
      })

      follow_up = in_thread.("om_follow", "can you read this document?", thread)
      assert {:ok, %{"ok" => true}} = deliver(ctx, follow_up)
      assert [message] = router_inputs(ctx, "om_follow")
      context = message["agent_input"]["trusted_origin"]["provider_context"]
      assert context["message_thread_id"] == thread

      # The answer to it is a message of the same thread.
      assert {:ok, %{"message" => %{"thread_id" => ^thread}}} =
               call(
                 ctx,
                 "lark.send_message",
                 %{"text" => "Yes.", "reply_to" => "om_follow"},
                 origin(ctx, @group, "om_follow")
               )

      assert_received {:lark_api, "POST", ["im", "v1", "messages", "om_follow", "reply"],
                       %{"reply_in_thread" => true}, _params}

      # And the talk goes on: the next message without a mention arrives too.
      assert {:ok, %{"ok" => true}} = deliver(ctx, in_thread.("om_again", "thanks", thread))
      assert [_input] = router_inputs(ctx, "om_again")

      # Another thread, and the chat outside any thread, still need a mention.
      assert {:ok, %{"ok" => true}} = deliver(ctx, in_thread.("om_other", "lunch?", "omt_other"))

      assert {:ok, %{"ok" => true}} =
               deliver(ctx, message_event("om_top", @group, "group", "lunch?"))

      assert router_inputs(ctx, "om_other") == []
      assert router_inputs(ctx, "om_top") == []
    end

    test "a message of a joined thread runs no control command", ctx do
      previous = SystemsRuntime.get_env(:salix_im, :control_command_execution)
      SystemsRuntime.put_env(:salix_im, :control_command_execution, :sync)
      on_exit(fn -> restore(:salix_im, :control_command_execution, previous) end)

      assert :ok = SalixIM.LarkThreads.join(ctx.connect, @group, "omt_joined")

      command =
        "om_thread_cmd"
        |> message_event(@group, "group", "<salix-command>status</salix-command>")
        |> put_in(["event", "message", "thread_id"], "omt_joined")

      assert {:ok, %{"ok" => true}} = deliver(ctx, command)
      # It is ordinary input for the Router, and nothing answers it by itself.
      assert [_input] = router_inputs(ctx, "om_thread_cmd")
      refute_received {:lark_api, "POST", ["im", "v1", "messages" | _rest], _body, _params}
    end

    test "a reply in a private chat opens no thread", ctx do
      origin = put_in(origin(ctx, @private, "om_dm"), ["provider_context", "chat_type"], "p2p")

      assert {:ok, _sent} =
               call(ctx, "lark.send_message", %{"text" => "Hi.", "reply_to" => "om_dm"}, origin)

      assert_received {:lark_api, "POST", ["im", "v1", "messages", "om_dm", "reply"],
                       %{"reply_in_thread" => false}, _params}
    end

    test "the bot's own message never prompts the Router", ctx do
      own =
        message_event("om_own", @private, "p2p", "done",
          sender: %{"sender_id" => %{"open_id" => @bot}, "sender_type" => "app"}
        )

      assert {:ok, %{"ok" => true}} = deliver(ctx, own)
      assert router_inputs(ctx, "om_own") == []
    end
  end

  describe "lark.send_message" do
    test "a send answers in the chat of the source, under the source message", ctx do
      origin = origin(ctx, @group, "om_ask")

      assert {:ok, %{"chat_id" => @group, "message" => %{"message_id" => "om_sent" <> _}}} =
               call(
                 ctx,
                 "lark.send_message",
                 %{"text" => "**Done.**", "reply_to" => "om_ask"},
                 origin
               )

      # The source message is known to be of its chat: no read comes first.
      # A reply in a group goes into the thread of the message.
      assert_received {:lark_api, "POST", ["im", "v1", "messages", "om_ask", "reply"],
                       %{"msg_type" => "post", "reply_in_thread" => true}, _params}

      refute_received {:lark_api, "GET", ["im", "v1", "messages", _id], _body, _params}

      # Without reply_to the message goes to the chat itself.
      assert {:ok, _sent} = call(ctx, "lark.send_message", %{"text" => "Next."}, origin)

      assert_received {:lark_api, "POST", ["im", "v1", "messages"], %{"receive_id" => @group},
                       %{"receive_id_type" => "chat_id"}}
    end

    test "a reply cannot leave the chat the send names", ctx do
      assert {:error, "reply_to is not a message of this chat"} =
               call(ctx, "lark.send_message", %{
                 "chat_id" => @group,
                 "text" => "secret",
                 "reply_to" => "om_elsewhere"
               })

      refute_received {:lark_api, "POST", _path, _body, _params}

      assert {:error, "chat_id is required outside a Lark source"} =
               call(ctx, "lark.send_message", %{"text" => "hello"})
    end

    test "a file of the workspace goes out after the text", ctx do
      assert {:ok, %{"message" => %{}, "file_message" => %{"msg_type" => "file"}}} =
               call(ctx, "lark.send_message", %{
                 "chat_id" => @group,
                 "text" => "The report.",
                 "path" => "/artifacts/report.pdf"
               })

      assert_received {:lark_api, "POST", ["im", "v1", "files"], _upload, _params}

      assert {:error, "text or path is required"} =
               call(ctx, "lark.send_message", %{"chat_id" => @group, "text" => " "})
    end

    test "only the bot's own message of the named chat can be edited", ctx do
      assert {:ok, _updated} =
               call(ctx, "lark.update_message", %{
                 "chat_id" => @group,
                 "message_id" => "om_bot",
                 "text" => "Corrected."
               })

      assert {:error, "Lark message is not authored by this bot"} =
               call(ctx, "lark.update_message", %{
                 "chat_id" => @group,
                 "message_id" => "om_person",
                 "text" => "Corrected."
               })

      assert {:error, "message_id is not a message of this chat"} =
               call(ctx, "lark.update_message", %{
                 "chat_id" => "oc_other",
                 "message_id" => "om_bot",
                 "text" => "Corrected."
               })
    end
  end

  describe "a question card" do
    defp question_press(card_id, value, form, open_id) do
      %{
        "schema" => "2.0",
        "header" => %{
          "event_id" => "evt_press_" <> open_id,
          "event_type" => "card.action.trigger",
          "token" => @token,
          "tenant_key" => "tenant_key_1"
        },
        "event" => %{
          "operator" => %{"open_id" => open_id},
          "action" => %{"tag" => "button", "value" => value, "form_value" => form},
          "context" => %{"open_message_id" => card_id, "open_chat_id" => @group}
        }
      }
    end

    test "the first answer is the presser's message to the Router, and the card says so", ctx do
      assert {:ok, %{"message" => %{"message_id" => card_id}}} =
               call(ctx, "lark.send_message", %{
                 "chat_id" => @group,
                 "text" => "Which line should the station take?",
                 "question" => %{
                   "type" => "options",
                   "options" => [
                     %{"label" => "Upgrade now", "recommended" => true},
                     %{"label" => "Wait for Electron", "detail" => "Keeps one Node version"}
                   ]
                 }
               })

      assert_received {:lark_api, "POST", ["im", "v1", "messages"],
                       %{"msg_type" => "interactive", "content" => content}, _params}

      %{"body" => %{"elements" => elements}} = Jason.decode!(content)
      %{"elements" => [select, send]} = Enum.find(elements, &(&1["tag"] == "form"))

      # The recommended option is shown last and chosen already.
      assert Enum.map(select["options"], & &1["text"]["content"]) ==
               ["Wait for Electron", "Upgrade now"]

      assert select["initial_option"] == "1"
      [%{"value" => value}] = send["behaviors"]

      # Nothing chosen: only the presser is told, and nothing is said.
      assert {:ok, %{"toast" => %{"type" => "warning"}} = empty} =
               deliver(ctx, question_press(card_id, value, %{}, @user))

      refute Map.has_key?(empty, "card")
      assert router_inputs(ctx, card_id) == []

      assert {:ok, %{"card" => %{"data" => answered}, "toast" => %{"type" => "success"}}} =
               deliver(
                 ctx,
                 question_press(card_id, value, %{"bft_question_choice" => "1"}, @user)
               )

      assert Jason.encode!(answered) =~ "<at id=#{@user}></at> answered: Upgrade now"
      refute Jason.encode!(answered) =~ "select_static"

      assert [message] = router_inputs(ctx, card_id)
      origin = message["agent_input"]["trusted_origin"]
      assert origin["source_text"] == "Upgrade now"
      assert origin["provider_context"]["sender_open_id"] == @user
      assert origin["provider_context"]["chat_id"] == @group

      # A later press is told the card was answered, and says nothing.
      assert {:ok, %{"toast" => %{"type" => "info"}}} =
               deliver(
                 ctx,
                 question_press(card_id, value, %{"bft_question_choice" => "0"}, "ou_bob")
               )

      assert [_one] = router_inputs(ctx, card_id)
    end

    test "a card whose request would pass the size limit is refused before it is sent", ctx do
      assert {:error, reason} =
               call(ctx, "lark.send_message", %{
                 "chat_id" => @group,
                 "text" => String.duplicate("\\", 7_000),
                 "question" => %{"type" => "text"}
               })

      assert reason =~ "interactive request is"
      refute_received {:lark_api, "POST", ["im", "v1", "messages"], _body, _params}
    end
  end

  describe "a private message to one person" do
    test "a send that names a person goes to that person", ctx do
      assert {:ok,
              %{
                "user_id" => @user,
                "user_id_type" => "open_id",
                "chat_id" => "oc_direct",
                "message" => %{"message_id" => "om_sent" <> _}
              }} = call(ctx, "lark.send_message", %{"user_id" => @user, "text" => "A word."})

      assert_received {:lark_api, "POST", ["im", "v1", "messages"], %{"receive_id" => @user},
                       %{"receive_id_type" => "open_id"}}

      # A person can be named by another kind of ID.
      assert {:ok, %{"user_id" => "alice@example.com", "user_id_type" => "email"}} =
               call(ctx, "lark.send_message", %{
                 "user_id" => "alice@example.com",
                 "user_id_type" => "email",
                 "text" => "A word."
               })

      assert_received {:lark_api, "POST", ["im", "v1", "messages"],
                       %{"receive_id" => "alice@example.com"}, %{"receive_id_type" => "email"}}

      # It does not fall back to the chat of the source.
      assert {:ok, %{"user_id" => @user}} =
               call(
                 ctx,
                 "lark.send_message",
                 %{"user_id" => @user, "text" => "A word."},
                 origin(ctx, @group, "om_ask")
               )

      assert_received {:lark_api, "POST", ["im", "v1", "messages"], %{"receive_id" => @user},
                       %{"receive_id_type" => "open_id"}}
    end

    test "a send names a chat or a person, and a reply is of a chat", ctx do
      assert {:error, "pass chat_id or user_id, not both"} =
               call(ctx, "lark.send_message", %{
                 "chat_id" => @group,
                 "user_id" => @user,
                 "text" => "hello"
               })

      assert {:error, "reply_to is not allowed with user_id"} =
               call(ctx, "lark.send_message", %{
                 "user_id" => @user,
                 "reply_to" => "om_person",
                 "text" => "hello"
               })

      assert {:error, "user_id_type must be open_id, user_id, union_id or email"} =
               call(ctx, "lark.send_message", %{
                 "user_id" => @group,
                 "user_id_type" => "chat_id",
                 "text" => "hello"
               })

      refute_received {:lark_api, "POST", _path, _body, _params}
    end
  end

  describe "chats, people and the directory" do
    test "the chat and the sender of a routed message are listed", ctx do
      assert {:ok, _queued} =
               deliver(ctx, message_event("om_seen", @private, "p2p", "hello"))

      # Group talk that is not for the bot adds nothing.
      assert {:ok, _ack} = deliver(ctx, message_event("om_talk", "oc_talk", "group", "lunch?"))

      connect_id = ctx.connect["connect_id"]

      assert {:ok, %{"chats" => [%{"chat_id" => @private, "chat_type" => "p2p"} = chat]}} =
               call(ctx, "lark.list_observed_chats", %{})

      assert chat["connect_id"] == connect_id

      assert {:ok, %{"users" => [%{"open_id" => @user, "user_id" => "alice"}]}} =
               call(ctx, "lark.list_observed_users", %{"query" => "ALICE"})

      assert {:ok, %{"users" => []}} =
               call(ctx, "lark.list_observed_users", %{"query" => "nobody"})

      assert {:ok, %{"users" => [%{"open_id" => @user}], "source" => "observed_inbound_users"}} =
               call(ctx, "lark.lookup_users", %{"query" => "alice", "limit" => 1})

      # The lists are Lark's own: nothing went to the Feishu lists.
      assert {:ok, []} = SalixIM.ProviderObservations.list_feishu_chats(connect_id, "", 50)
      assert {:ok, []} = SalixIM.ProviderObservations.list_feishu_users(connect_id, "", 50)
    end

    test "the directory is read one page at a time", ctx do
      assert {:ok,
              %{
                "department_ids" => ["od_eng"],
                "user_ids" => [@user],
                "group_ids" => [],
                "has_more" => false,
                "guidance" => guidance
              }} = call(ctx, "lark.list_contact_scopes", %{})

      assert guidance =~ "lark.list_departments"

      assert_received {:lark_api, "GET", ["contact", "v3", "scopes"], _body,
                       %{
                         "user_id_type" => "open_id",
                         "department_id_type" => "open_department_id",
                         "page_size" => "100"
                       }}

      # Without a department the walk starts at the root.
      assert {:ok,
              %{
                "departments" => [%{"open_department_id" => "od_eng"}],
                "has_more" => true,
                "next_page_token" => "next-departments"
              }} = call(ctx, "lark.list_departments", %{})

      assert_received {:lark_api, "GET", ["contact", "v3", "departments", "0", "children"], _body,
                       %{"fetch_child" => "false", "page_size" => "50"}}

      assert {:ok, %{"users" => [%{"open_id" => @user, "name" => "Alice"}], "has_more" => false}} =
               call(ctx, "lark.list_department_users", %{
                 "department_id" => "od_eng",
                 "user_id_type" => "union_id"
               })

      assert_received {:lark_api, "GET", ["contact", "v3", "users", "find_by_department"], _body,
                       %{"department_id" => "od_eng", "user_id_type" => "union_id"}}

      assert {:error, "department_id is required"} =
               call(ctx, "lark.list_department_users", %{})
    end
  end

  describe "message record" do
    defp drain_outbox do
      assert :idle = SalixIM.LarkMessageRecord.OutboxDrainer.drain_once()
      # The Lark record has its own outbox: nothing went to the Feishu mirror's.
      assert {:ok, []} = SalixStore.FeishuMirrorOutbox.claim(10, 1_000)
    end

    test "every delivered message is recorded and found by search", ctx do
      assert {:ok, _ack} =
               deliver(
                 ctx,
                 message_event("om_noon", @group, "group", "the deploy finished at noon")
               )

      # Lark can deliver a message again; the record keeps one row for it.
      assert {:ok, _ack} =
               deliver(
                 ctx,
                 message_event("om_noon", @group, "group", "the deploy finished at noon")
               )

      assert {:ok, _ack} =
               deliver(
                 ctx,
                 message_event("om_ask", @group, "group", "@_user_1 what was deployed?",
                   mentions: [bot_mention()]
                 )
               )

      assert {:ok, _sent} =
               call(ctx, "lark.send_message", %{"chat_id" => @group, "text" => "Release 42."})

      drain_outbox()
      rows = RecordStore.rows()
      assert Enum.all?(rows, &(&1["app_id"] == ctx.app_id and &1["chat_id"] == @group))

      assert rows |> Enum.map(&{&1["actor_kind"], &1["ingest_source"]}) |> Enum.sort() == [
               {"app", "send"},
               {"user", "webhook"},
               {"user", "webhook"}
             ]

      assert {:ok, %{"messages" => [%{"message_id" => "om_noon", "text" => text}]}} =
               call(ctx, "lark.search_messages", %{"query" => "deploy noon"})

      assert text == "the deploy finished at noon"

      # What the bot wrote is found as it wrote it.
      assert {:ok, %{"messages" => [%{"text" => "Release 42."}]}} =
               call(ctx, "lark.search_messages", %{"query" => "Release"})

      # A file the bot sent is a message of its own in the record.
      assert {:ok, %{"file_message" => %{"message_id" => file_message_id}}} =
               call(ctx, "lark.send_message", %{
                 "chat_id" => @group,
                 "text" => "The report.",
                 "path" => "/artifacts/report.pdf"
               })

      drain_outbox()

      assert {:ok, %{"messages" => [%{"message_id" => ^file_message_id}]}} =
               call(ctx, "lark.search_messages", %{"query" => "in:#{@group} has:file"})

      # A recalled message leaves the record.
      recall = %{
        "schema" => "2.0",
        "header" => %{"event_type" => "im.message.recalled_v1", "token" => @token},
        "event" => %{
          "message_id" => "om_noon",
          "chat_id" => @group,
          "recall_time" => Integer.to_string(SystemsClock.system_time(:millisecond) + 1_000)
        }
      }

      assert {:ok, %{"ok" => true}} = deliver(ctx, recall)
      drain_outbox()

      assert {:ok, %{"messages" => []}} =
               call(ctx, "lark.search_messages", %{"query" => "deploy noon"})
    end

    test "a callback fails when the record cannot keep the message", ctx do
      defmodule DownOutbox do
        def append(_row, _kind), do: {:error, :down}
      end

      SystemsRuntime.put_env(:salix_im, :lark_message_record_outbox, DownOutbox)
      on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :lark_message_record_outbox) end)

      # Lark delivers again after a failure; nothing reached the Router yet.
      assert {:error, :outbox_unavailable} =
               deliver(ctx, message_event("om_lost", @private, "p2p", "hello"))

      assert router_inputs(ctx, "om_lost") == []
    end

    test "search says so when the record is off", ctx do
      SystemsRuntime.delete_env(:salix_im, :lark_message_record_mod)

      assert {:error, "Lark search is unavailable (message index is not configured)"} =
               call(ctx, "lark.search_messages", %{"query" => "deploy"})
    end
  end

  describe "history in the record" do
    alias SalixIM.LarkMessageRecord.BackfillRunner
    alias SalixStore.LarkMirrorBackfillLedger

    defp history_message(message_id, text, thread_id) do
      %{
        "message_id" => message_id,
        "chat_id" => @group,
        "thread_id" => thread_id,
        "msg_type" => "text",
        "create_time" => "1700000000000",
        "sender" => %{"id" => @user, "sender_type" => "user"},
        "body" => %{"content" => Jason.encode!(%{"text" => text})}
      }
    end

    test "the history of the bot's chats is read in, and search says what is not yet", ctx do
      SystemsRuntime.put_env(:salix_im, :lark_test_history, %{
        @group => [history_message("om_march", "the launch was in March", "omt_launch")],
        "omt_launch" => [history_message("om_reply", "the launch slipped a week", "omt_launch")]
      })

      # Nothing is walked yet: no hit does not mean nothing was said.
      assert {:ok, %{"messages" => [], "incomplete" => %{"reason" => "not_synced"}}} =
               call(ctx, "lark.search_messages", %{"query" => "launch"})

      # The connect is found, and its chat and the thread of it are walked as
      # the connect's own app.
      connect_id = ctx.connect["connect_id"]
      assert {:ok, %{scan_complete: true}} = BackfillRunner.discover_once(nil)
      drain()
      assert {:ok, :more} = BackfillRunner.run_once(pace_ms: 0)
      assert {:ok, :idle} = BackfillRunner.run_once(pace_ms: 0)
      assert :empty = BackfillRunner.run_once(pace_ms: 0)

      assert_received {:lark_api, "GET", ["im", "v1", "chats"], _body, _params}

      assert_received {:lark_api, "GET", ["im", "v1", "messages"], _body,
                       %{"container_id_type" => "chat", "container_id" => @group}}

      assert_received {:lark_api, "GET", ["im", "v1", "messages"], _body,
                       %{"container_id_type" => "thread", "container_id" => "omt_launch"}}

      rows = RecordStore.rows()
      assert Enum.map(rows, & &1["message_id"]) |> Enum.sort() == ~w(om_march om_reply)
      assert Enum.all?(rows, &(&1["app_id"] == ctx.app_id and &1["ingest_source"] == "backfill"))

      assert {:ok, page} = call(ctx, "lark.search_messages", %{"query" => "launch"})

      assert page["messages"] |> Enum.map(& &1["message_id"]) |> Enum.sort() ==
               ~w(om_march om_reply)

      refute Map.has_key?(page, "incomplete")

      # The walk kept its state in the Lark tables, under this connect.
      assert %{rows: [[^connect_id]]} =
               SalixStore.Repo.query!("SELECT connect_id FROM lark_mirror_backfill_connects")

      # Not in the Feishu ones. SalixStore.Repo is not in the sandbox: the
      # table holds the rows other suites of this process wrote, so only this
      # connect's app counts.
      assert %{rows: [[0]]} =
               SalixStore.Repo.query!(
                 "SELECT count(*) FROM feishu_mirror_containers WHERE tenant_id = $1 AND app_id = $2",
                 [ctx.tenant, ctx.app_id]
               )
    end

    test "search names the time before which a chat is not read in yet", ctx do
      scope = %{"tenant_id" => ctx.tenant, "app_id" => ctx.app_id}
      chat = %{"container_type" => "chat", "container_id" => @group, "chat_id" => @group}
      assert :ok = LarkMirrorBackfillLedger.upsert_containers(scope, [chat])

      # One page landed, down to 2023-11-14, and Lark has more below it.
      assert :ok =
               LarkMirrorBackfillLedger.commit_page(scope, chat, %{
                 "oldest_us" => 1_700_000_000_000_000,
                 "observed_us" => 1_791_900_000_000_000,
                 "page_token" => "older",
                 "exhausted" => false
               })

      assert {:ok, page} = call(ctx, "lark.search_messages", %{"query" => "in:#{@group} launch"})

      assert page["incomplete"] == %{
               "reason" => "not_synced",
               "older_than" => "1700000000000"
             }

      # A search of the part that is read in is whole.
      assert {:ok, recent} =
               call(ctx, "lark.search_messages", %{"query" => "launch after:2024-01-01"})

      refute Map.has_key?(recent, "incomplete")

      # Another chat of the app has no walk at all.
      assert {:ok, %{"incomplete" => %{"reason" => "not_synced"}}} =
               call(ctx, "lark.search_messages", %{"query" => "in:oc_other launch"})
    end
  end

  describe "a file of an earlier message" do
    defp file_message do
      %{
        "message_id" => "om_plan",
        "chat_id" => @group,
        "msg_type" => "file",
        "create_time" => "1700000000000",
        "sender" => %{"id" => @user, "sender_type" => "user"},
        "body" => %{
          "content" => Jason.encode!(%{"file_key" => "file_v2_plan", "file_name" => "plan.pdf"})
        }
      }
    end

    test "every read gives the file one reference, and the reference fetches it", ctx do
      SystemsRuntime.put_env(:salix_im, :lark_test_history, %{
        @group => [file_message()],
        "omt_plan" => [file_message()]
      })

      assert {:ok, %{"messages" => [%{"attachments" => [attachment]}]}} =
               call(ctx, "lark.get_chat_history", %{"chat_id" => @group})

      assert %{"file_key" => "file_v2_plan", "resource_type" => "file", "resource_ref" => ref} =
               attachment

      assert String.starts_with?(ref, "lr1.")

      assert {:ok, %{"messages" => [%{"attachments" => [%{"resource_ref" => ^ref}]}]}} =
               call(ctx, "lark.get_thread_replies", %{"thread_id" => "omt_plan"})

      assert {:ok, %{"message" => %{"attachments" => [%{"resource_ref" => ^ref}]}}} =
               call(ctx, "lark.get_message", %{"message_id" => "om_plan"})

      assert {:ok, %{"files" => [%{"message_id" => "om_plan", "resource_ref" => ^ref}]}} =
               call(ctx, "lark.list_chat_files", %{"chat_id" => @group})

      # A hit of the record carries the same reference.
      assert {:ok, %{scan_complete: true}} =
               SalixIM.LarkMessageRecord.BackfillRunner.discover_once(nil)

      assert {:ok, :idle} = SalixIM.LarkMessageRecord.BackfillRunner.run_once(pace_ms: 0)

      assert {:ok, %{"messages" => [%{"attachments" => [%{"resource_ref" => ^ref}]}]}} =
               call(ctx, "lark.search_messages", %{"query" => "in:#{@group} has:file"})

      drain()

      assert {:ok, staged} = call(ctx, "lark.fetch_message_resource", %{"resource_ref" => ref})
      assert staged["file_name"] == "plan.pdf"
      assert staged["mime_type"] == "application/pdf"
      assert staged["size"] == byte_size("PLAN-BYTES")
      assert staged["resource_ref"] == ref
      assert String.starts_with?(staged["vfs_path"], "/lark/files/")

      assert {:ok, %{data: "PLAN-BYTES"}} =
               SalixIM.Ports.AgentWorkspace.read_upload(ctx.router_id, staged["vfs_path"])

      assert_received {:lark_api, "GET",
                       ["im", "v1", "messages", "om_plan", "resources", "file_v2_plan"], _body,
                       %{"type" => "file"}}

      # A caller without a reference still names the file by its three parts.
      assert {:ok, %{"vfs_path" => "/lark/files/" <> _, "resource_ref" => ^ref}} =
               call(ctx, "lark.fetch_message_resource", %{
                 "message_id" => "om_plan",
                 "file_key" => "file_v2_plan",
                 "resource_type" => "file"
               })
    end

    test "a reference one connect listed is refused by another before anything is read",
         ctx do
      SystemsRuntime.put_env(:salix_im, :lark_test_history, %{@group => [file_message()]})

      assert {:ok, %{"files" => [%{"resource_ref" => ref}]}} =
               call(ctx, "lark.list_chat_files", %{"chat_id" => @group})

      # Another Lark app of the same tenant, with the same App Secret.
      {other_group, other_router} = group_with_router(ctx.tenant)
      other_app = "cli_other#{SystemsRuntime.Proc.unique_integer([:positive])}"

      {:ok, other_connect} =
        ProviderConnects.create_lark_im_connect(ctx.tenant, other_group, attrs(other_app))

      other = %{router_id: other_router, connect: other_connect}
      drain()

      assert {:error, reason} =
               call(other, "lark.fetch_message_resource", %{"resource_ref" => ref})

      assert reason =~ "invalid Lark resource_ref"

      # A changed reference, and a reference of another kind, are refused too.
      for bad <- [ref <> "A", String.replace_prefix(ref, "lr1.", "fr2."), "om_plan"] do
        assert {:error, reason} =
                 call(ctx, "lark.fetch_message_resource", %{"resource_ref" => bad})

        assert reason =~ "invalid Lark resource_ref"
      end

      refute_received {:lark_api, "GET", ["im", "v1", "messages" | _rest], _body, _params}
    end
  end

  describe "a confirmation card" do
    setup ctx do
      request = %{
        "request_id" => "req_1",
        "group_id" => ctx.group_id,
        "tenant_id" => ctx.tenant,
        "request_type" => "ifc_declassify",
        "status" => "pending",
        "request_payload" => %{
          "ifc_declassify" => %{
            "capability" => "ifc_declassify",
            "requester" => "provider_user|#{ctx.connect["connect_id"]}|#{@user}",
            "source_names" => ["私聊"],
            "destination_names" => ["项目群"],
            "summary" => "把你私聊里的交接清单发到项目群"
          }
        }
      }

      SalixIM.Test.IFCCapabilityRequestsStub.install(request)
      on_exit(&SalixIM.Test.IFCCapabilityRequestsStub.uninstall/0)
      %{request: request}
    end

    defp card_press(choice, open_id, opts \\ []) do
      %{
        "schema" => "2.0",
        "header" => %{
          "event_id" => "evt_card",
          "event_type" => "card.action.trigger",
          "token" => Keyword.get(opts, :token, @token),
          "tenant_key" => "tenant_key_1"
        },
        "event" => %{
          "operator" => %{"open_id" => open_id},
          "action" => %{
            "tag" => "button",
            "value" =>
              Keyword.get(opts, :value, %{"ifc_declassify" => choice, "request_id" => "req_1"})
          }
        }
      }
    end

    defp router_messages(ctx) do
      {:ok, conversation} = SalixIM.RouterConversationInput.ensure(ctx.group_id)

      {:ok, messages} =
        SalixIM.Conversations.list_group_conversation_messages(
          ctx.group_id,
          conversation["conversation_id"],
          limit: 50
        )

      messages
    end

    test "the requester gets the card in private, and the press decides", ctx do
      capture_diagnostics()
      assert :ok = SalixIM.IFC.Confirmation.post(ctx.request)

      # The question goes to the person, not to a chat other people read.
      assert_received {:lark_api, "POST", ["im", "v1", "messages"],
                       %{"receive_id" => @user, "msg_type" => "interactive", "content" => card},
                       %{"receive_id_type" => "open_id"}}

      # Each button names the request it answers.
      assert card =~ ~s("request_id":"req_1")
      assert card =~ "项目群"

      assert {:ok, %{"card" => %{"type" => "raw", "data" => settled}, "toast" => %{}}} =
               deliver(ctx, card_press("approve", @user))

      group_id = ctx.group_id
      tenant = ctx.tenant
      assert_received {:ifc_stub_decided, ^group_id, "req_1", %{"approved" => true}, ^tenant}
      # The answer to the callback is the card that replaces the question.
      assert Jason.encode!(settled) =~ "已确认转发"
      # A press is no message: the Router gets nothing.
      assert router_messages(ctx) == []

      assert [%{event_type: "lark.callback.card_action", status: "decided"}] = diagnostics()

      assert {:ok, %{"card" => _settled}} = deliver(ctx, card_press("deny", @user))
      assert_received {:ifc_stub_decided, ^group_id, "req_1", %{"approved" => false}, ^tenant}
    end

    test "a press decides nothing unless the requester made it on a verified callback", ctx do
      # Another person of the chat pressed: acknowledged, and the card stays.
      assert {:ok, %{"ok" => true} = ack} = deliver(ctx, card_press("approve", "ou_bob"))
      refute Map.has_key?(ack, "card")

      # A button that is not of the confirmation card asks nothing.
      assert {:ok, %{"ok" => true}} =
               deliver(ctx, card_press("approve", @user, value: %{"other" => "button"}))

      # A callback Lark did not sign for this app is refused like any other.
      assert {:error, :invalid_token} =
               deliver(ctx, card_press("approve", @user, token: "another"))

      press = card_press("approve", @user)

      for malformed <- [
            put_in(press, ["event", "operator"], @user),
            put_in(press, ["event", "operator", "open_id"], %{"id" => @user}),
            put_in(press, ["event", "action"], "approve"),
            put_in(press, ["event", "action", "value"], ["approve", "req_1"])
          ] do
        assert {:error, :invalid_envelope} = deliver(ctx, malformed)
      end

      refute_received {:ifc_stub_decided, _group, _request, _attrs, _tenant}
      assert router_messages(ctx) == []
    end
  end

  describe "a message the runtime sends by itself" do
    defp lark_uuid(api, target, operation_ref) do
      digest =
        :crypto.hash(:sha256, Enum.join([api, target, operation_ref], "\0"))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 40)

      "bft_" <> digest
    end

    defp stored_connect(ctx) do
      {:ok, connect} =
        ProviderConnects.get_active_connect_by_id(ctx.group_id, ctx.connect["connect_id"], "lark")

      connect
    end

    test "a direct delivery names its chat, and the same operation has the same uuid", ctx do
      alias SalixIM.Ports.LarkDirectDelivery

      connect = stored_connect(ctx)
      reminder = "calendar-notify:occurrence-1"
      chat = %{"chat_id" => "oc_calendar", "chat_type" => "group"}
      nobody = %{"mode" => "none", "users" => []}

      assert {:ok, %{"chat_id" => "oc_calendar", "message" => %{"message_id" => _id}}} =
               LarkDirectDelivery.post_text(connect, chat, "Calendar reminder", nobody, reminder)

      uuid = lark_uuid("lark.send_message", "oc_calendar", reminder)

      assert_received {:lark_api, "POST", ["im", "v1", "messages"],
                       %{"receive_id" => "oc_calendar", "uuid" => ^uuid},
                       %{"receive_id_type" => "chat_id"}}

      # The delivery sent again is the same request to Lark.
      assert {:ok, _sent} =
               LarkDirectDelivery.post_text(connect, chat, "Calendar reminder", nobody, reminder)

      assert_received {:lark_api, "POST", ["im", "v1", "messages"], %{"uuid" => ^uuid}, _params}

      # With a root message the text answers it, in the thread of a group.
      joining = "meeting:mtg-1:joining"
      thread = %{"chat_id" => @group, "chat_type" => "group", "root_message_id" => "om_root"}

      assert {:ok, %{"message" => %{"thread_id" => "omt_om_root"}}} =
               LarkDirectDelivery.post_text(
                 connect,
                 thread,
                 "Joining meeting",
                 %{"mode" => "all"},
                 joining
               )

      reply_uuid = lark_uuid("lark.send_message", "om_root", joining)

      assert_received {:lark_api, "POST", ["im", "v1", "messages", "om_root", "reply"],
                       %{"reply_in_thread" => true, "uuid" => ^reply_uuid, "content" => content},
                       _params}

      assert content =~ ~s("user_id":"all")
      # The thread is one the bot answered in, as after any reply of the bot.
      assert SalixIM.LarkThreads.joined?(connect, @group, "omt_om_root")

      # A file of the workspace goes the same way, under its own uuid.
      assert {:ok, %{"file_message" => %{"msg_type" => "file"}}} =
               LarkDirectDelivery.post_file(
                 ctx.router_id,
                 connect,
                 chat,
                 "/artifacts/report.pdf",
                 nil,
                 "meeting:mtg-1:transcript"
               )

      file_uuid = lark_uuid("lark.send_message.file", "oc_calendar", "meeting:mtg-1:transcript")

      assert_received {:lark_api, "POST", ["im", "v1", "messages"],
                       %{"msg_type" => "file", "uuid" => ^file_uuid}, _params}
    end

    test "a direct delivery without its chat, its operation or valid mentions sends nothing",
         ctx do
      alias SalixIM.Ports.LarkDirectDelivery

      connect = stored_connect(ctx)
      chat = %{"chat_id" => @group}

      assert {:error, {:missing, :chat_id}} =
               LarkDirectDelivery.post_text(connect, %{}, "text", nil, "op-1")

      assert {:error, {:missing, :operation_ref}} =
               LarkDirectDelivery.post_text(connect, chat, "text", nil, " ")

      assert {:error, :invalid_lark_delivery_mentions} =
               LarkDirectDelivery.post_text(
                 connect,
                 chat,
                 "text",
                 %{"mode" => "users", "users" => []},
                 "op-1"
               )

      assert {:error, {:missing, :path}} =
               LarkDirectDelivery.post_file(ctx.router_id, connect, chat, "", nil, "op-1")

      refute_received {:lark_api, "POST", _path, _body, _params}
    end

    test "a send of the Router shows in the Home conversation", ctx do
      assert {:ok, _sent} =
               call(
                 ctx,
                 "lark.send_message",
                 %{"chat_id" => @group, "text" => "The report is ready."}
               )

      platform = fn ->
        for %{"platform_message" => %{} = message} <- router_messages(ctx), do: message
      end

      assert [
               %{
                 "provider" => "lark",
                 "role" => "assistant",
                 "content" => [%{"type" => "text", "text" => "The report is ready."}]
               }
             ] = wait_for(platform)
    end
  end

  describe "information flow facts" do
    alias SalixIM.IFC.Projection

    defp ifc_scope(ctx) do
      %{tenant_id: ctx.tenant, group_id: ctx.group_id, connect_id: ctx.connect["connect_id"]}
    end

    test "a Lark chat is what Lark says it is, with the members Lark lists", ctx do
      scope = ifc_scope(ctx)

      SystemsRuntime.put_env(:salix_im, :lark_test_chats, %{
        "oc_room" => %{
          "chat_mode" => "group",
          "chat_type" => "private",
          "name" => "Launch",
          "members" => ["ou_bob", "ou_alice"]
        },
        "oc_public" => %{"chat_mode" => "group", "chat_type" => "public", "members" => []},
        "oc_shared" => %{
          "chat_mode" => "group",
          "chat_type" => "private",
          "external" => true,
          "members" => ["ou_alice"]
        },
        "oc_large" => %{
          "chat_mode" => "group",
          "members" => ["ou_alice"],
          "more_members" => true
        },
        "oc_person" => %{"chat_mode" => "p2p"}
      })

      assert {"oc_room", room} = Projection.facts(scope, "oc_room")
      assert %{kind: "room", display_name: "Launch", members: ["ou_alice", "ou_bob"]} = room
      refute Projection.space_audience?(room)

      # A public group is open to the whole tenant: its audience is the space.
      assert {"oc_public", %{kind: "public"} = public} = Projection.facts(scope, "oc_public")
      assert Projection.space_audience?(public)

      assert {"oc_shared", %{kind: "shared", members: ["ou_alice"]}} =
               Projection.facts(scope, "oc_shared")

      # A page that is not the last is not the member set.
      assert {"oc_large", %{kind: "room", members: :unknown}} =
               Projection.facts(scope, "oc_large")

      # A private chat does not name its person, and has no member list to ask.
      drain()

      assert {"oc_person", %{kind: "direct", members: :unknown}} =
               Projection.facts(scope, "oc_person")

      refute_received {:lark_api, "GET", ["im", "v1", "chats", "oc_person", "members"], _, _}

      # A chat Lark does not show the bot stays unknown.
      assert {"oc_hidden", %{kind: nil, members: :unknown}} = Projection.facts(scope, "oc_hidden")
    end

    test "a Task card's audience is the chat of the message it answers", ctx do
      scope = ifc_scope(ctx)
      connect_id = ctx.connect["connect_id"]

      SystemsRuntime.put_env(:salix_im, :lark_test_chats, %{
        "oc_other" => %{"chat_mode" => "group", "chat_type" => "private", "members" => [@user]}
      })

      # The Group checks information flow, so the resolver answers with facts.
      {:ok, _} =
        CasRecord.update(
          Keys.ctl_group(ctx.group_id),
          &Map.put(&1, "ifc", %{"mode" => "enforce"})
        )

      assert Projection.message_scope_id(scope, "om_elsewhere") == "oc_other"

      {:egress, destination} =
        SalixAgent.IFC.Destination.describe(
          "im_api.lark.post_task_card",
          %{"connect_id" => connect_id, "conversation_id" => "c", "message_id" => "om_elsewhere"},
          %{}
        )

      assert {:ok, reply} =
               SalixIM.IFC.Facts.resolve(%{
                 "tenant_id" => ctx.tenant,
                 "group_id" => ctx.group_id,
                 "atoms" => [],
                 "destination" => destination
               })

      # The members of that chat are the people who may write there.
      assert reply["destination"] == %{
               "label" => ["scope|#{connect_id}|oc_other"],
               "writers" => ["provider_user|#{connect_id}|#{@user}"]
             }
    end
  end

  describe "a turn whose source is a finished meeting" do
    # The sealed origin of the meeting message, as the Router's session keeps
    # it, and the tool context of a turn that has only that source.
    defp meeting_context(ctx, source_id, extra) do
      {:ok, group} = SalixIM.GroupDirectory.get_group(ctx.group_id)
      {:ok, router} = SalixIM.GroupDirectory.get_agent(ctx.router_id)

      metadata =
        Map.merge(
          %{
            "provider" => "lark",
            "connect_id" => ctx.connect["connect_id"],
            "chat_id" => @group,
            "chat_type" => "group",
            "message_id" => "om_meeting_root",
            "root_message_id" => "om_meeting_root",
            "event_type" => "meeting.completed",
            "router_activation_mode" => "context_only"
          },
          extra
        )

      {:ok, %{"trusted_origin" => origin}} =
        SalixIM.AgentDeliveryPayload.provider_router_delivery(
          group,
          router,
          "A meeting just ended",
          metadata,
          source_message_id: source_id
        )

      %{
        "source_message_id" => source_id,
        "source_message_ids" => [source_id],
        "trusted_origin" => origin,
        "trusted_origins" => [origin]
      }
    end

    defp meeting_call(ctx, api, params, tool_context) do
      Provider.call_api(ctx.router_id, "lark", api, %{
        "connect_id" => ctx.connect["connect_id"],
        "params" => params,
        "tool_context" => tool_context
      })
    end

    defp meeting_grant(ctx, expires_at) do
      alias SalixIM.Provider.Lark.{MeetingActivationAuthorization, MeetingActivationRef}

      {:ok, connect} =
        ProviderConnects.get_active_connect_by_id(ctx.group_id, ctx.connect["connect_id"], "lark")

      {:ok, signing_key} = SalixIM.Provider.Lark.API.resource_ref_signing_key(connect)

      {:ok, ref} =
        MeetingActivationRef.encode(
          MeetingActivationAuthorization.ref_scope(ctx.group_id, connect["connect_id"]),
          signing_key,
          %{
            "meeting_id" => "mtg_lark",
            "expires_at" => expires_at,
            "target" => %{
              "chat_id" => @group,
              "chat_type" => "group",
              "reply_to" => "om_meeting_root",
              "reply_in_thread" => true
            },
            "allowed_mentions" => [%{"user_id" => "ou_alice", "name" => "Alice"}]
          }
        )

      ref
    end

    @refused "meeting activation is not authorized for this Lark target"

    test "without a grant it calls nothing in Lark", ctx do
      context = meeting_context(ctx, "meeting-activation:mtg_lark", %{})
      reply = %{"chat_id" => @group, "reply_to" => "om_meeting_root", "text" => "Assigned"}

      assert {:error, @refused} = meeting_call(ctx, "lark.send_message", reply, context)

      assert {:error, @refused} =
               meeting_call(ctx, "lark.get_chat_history", %{"chat_id" => @group}, context)

      refute_received {:lark_api, _method, ["im", "v1", "messages" | _rest], _body, _params}

      # A turn with an ordinary source is not restricted.
      assert {:ok, _sent} =
               call(ctx, "lark.send_message", reply, origin(ctx, @group, "om_meeting_root"))
    end

    test "with a grant it sends only the reply the grant names", ctx do
      now = SystemsClock.system_time(:second)

      context =
        meeting_context(ctx, "meeting-activation:mtg_lark", %{
          "lark_meeting_activation_ref" => meeting_grant(ctx, now + 3600)
        })

      reply = %{
        "chat_id" => @group,
        "reply_to" => "om_meeting_root",
        "text" => "Assigned",
        "mentions" => [%{"user_id" => "ou_alice", "name" => "Alice"}]
      }

      assert {:ok, %{"chat_id" => @group}} =
               meeting_call(ctx, "lark.send_message", reply, context)

      assert_received {:lark_api, "POST", ["im", "v1", "messages", "om_meeting_root", "reply"],
                       %{"reply_in_thread" => true}, _params}

      for changed <- [
            %{"chat_id" => "oc_other"},
            %{"reply_to" => "om_other"},
            %{"reply_in_thread" => false},
            %{"mention_all" => true},
            %{"mentions" => [%{"user_id" => "ou_bob", "name" => "Bob"}]},
            %{"path" => "/artifacts/report.pdf"}
          ] do
        assert {:error, @refused} =
                 meeting_call(ctx, "lark.send_message", Map.merge(reply, changed), context)
      end

      # A private message to one person is not the reply.
      assert {:error, @refused} =
               meeting_call(
                 ctx,
                 "lark.send_message",
                 %{"user_id" => @user, "text" => "Assigned"},
                 context
               )

      assert {:error, @refused} =
               meeting_call(ctx, "lark.get_chat_history", %{"chat_id" => @group}, context)

      refute_received {:lark_api, "POST", ["im", "v1", "messages" | _rest], _body, _params}
    end

    test "a grant that expired, or one of another connect, opens nothing", ctx do
      now = SystemsClock.system_time(:second)
      reply = %{"chat_id" => @group, "reply_to" => "om_meeting_root", "text" => "Assigned"}

      expired =
        meeting_context(ctx, "meeting-activation:mtg_lark", %{
          "lark_meeting_activation_ref" => meeting_grant(ctx, now - 1)
        })

      assert {:error, @refused} = meeting_call(ctx, "lark.send_message", reply, expired)

      {:ok, other} =
        ProviderConnects.create_lark_im_connect(ctx.tenant, ctx.group_id, attrs("cli_other_app"))

      other_ctx = %{ctx | connect: other}

      foreign =
        meeting_context(ctx, "meeting-activation:mtg_lark", %{
          "lark_meeting_activation_ref" => meeting_grant(other_ctx, now + 3600)
        })

      assert {:error, @refused} = meeting_call(ctx, "lark.send_message", reply, foreign)

      # A grant on a message that is no meeting source is refused, not ignored.
      orphan =
        meeting_context(ctx, "im_provider:lark:om_plain", %{
          "lark_meeting_activation_ref" => meeting_grant(ctx, now + 3600)
        })

      assert {:error, @refused} = meeting_call(ctx, "lark.send_message", reply, orphan)
      refute_received {:lark_api, "POST", ["im", "v1", "messages" | _rest], _body, _params}
    end
  end

  test "each operation has its place in information flow control" do
    describe = fn api, args ->
      SalixAgent.IFC.Destination.describe("im_api." <> api, args, %{})
    end

    for api <- ~w(lark.send_message lark.update_message) do
      assert {:egress, %{"kind" => "provider_scope", "provider" => "lark", "scope_id" => @group}} =
               describe.(api, %{"connect_id" => "c", "chat_id" => @group})
    end

    # A send that names a person goes to that person, not to a chat.
    assert {:egress,
            %{
              "kind" => "provider_direct",
              "provider" => "lark",
              "connect_id" => "c",
              "user_id" => @user
            }} = describe.("lark.send_message", %{"connect_id" => "c", "user_id" => @user})

    for api <- ~w(lark.get_chat_history lark.search_messages lark.list_chats
                  lark.fetch_message_resource lark.list_observed_chats
                  lark.list_observed_users lark.lookup_users lark.list_contact_scopes
                  lark.list_departments lark.list_department_users) do
      assert {:read, _descriptor} = describe.(api, %{})
    end

    for api <- ~w(lark.add_reaction lark.pin_message lark.delete_message) do
      assert {:none, _descriptor} = describe.(api, %{})
    end

    # Cloud documents and Minutes. A read is labelled at its result.
    for api <- ~w(lark.fetch_doc lark.list_doc_comments lark.list_doc_members
                  lark.fetch_doc_media lark.list_wiki_spaces lark.list_wiki_nodes
                  lark.get_minute lark.list_minutes lark.fetch_minute_media) do
      assert {:read, _descriptor} = describe.(api, %{})
    end

    # New content in a document reaches the readers of that document.
    for api <- ~w(lark.update_doc lark.insert_doc_media lark.add_doc_comment
                  lark.reply_doc_comment) do
      assert {:egress,
              %{
                "kind" => "provider_document",
                "provider" => "lark",
                "connect_id" => "c",
                "document" => "DocxTok00001",
                "document_type" => "wiki"
              }} =
               describe.(api, %{
                 "connect_id" => "c",
                 "doc" => "DocxTok00001",
                 "doc_type" => "wiki",
                 "command" => "append"
               })
    end

    # A command that only moves or deletes the document's own blocks, and a
    # write with no content, carry nothing.
    assert {:none, _descriptor} =
             describe.("lark.update_doc", %{"doc" => "DocxTok00001", "command" => "block_delete"})

    for api <- ~w(lark.resolve_doc_comment lark.remove_doc_member lark.delete_doc
                  lark.request_minute_access) do
      assert {:none, _descriptor} = describe.(api, %{})
    end

    # A new document is private until it is shared. Its share target, or its
    # parent, is where its content goes.
    assert {:persist, %{"kind" => "agent_private"}} =
             describe.("lark.create_doc", %{"connect_id" => "c", "title" => "Plan"})

    assert [{:egress, %{"kind" => "provider_scope", "provider" => "lark", "scope_id" => @group}}] =
             SalixAgent.IFC.Destination.additional_destinations(
               "im_api.lark.create_doc",
               %{"connect_id" => "c", "share_chat_id" => @group},
               %{}
             )

    assert [{:egress, %{"kind" => "provider_direct", "provider" => "lark", "user_id" => @user}}] =
             SalixAgent.IFC.Destination.additional_destinations(
               "im_api.lark.create_doc",
               %{"connect_id" => "c", "share_user_id" => @user},
               %{}
             )

    assert {:egress,
            %{"kind" => "provider_document", "provider" => "lark", "document_type" => "wiki"}} =
             describe.("lark.create_doc", %{
               "connect_id" => "c",
               "parent" => "https://acme.larksuite.com/wiki/WikiNode0001"
             })

    # Sharing opens the document to the chat, the person, or the whole space.
    assert {:egress, %{"kind" => "provider_scope", "provider" => "lark", "scope_id" => @group}} =
             describe.("lark.share_doc", %{
               "connect_id" => "c",
               "member_type" => "chat",
               "member_id" => @group
             })

    assert {:egress, %{"kind" => "provider_direct", "provider" => "lark", "user_id" => @user}} =
             describe.("lark.share_doc", %{
               "connect_id" => "c",
               "member_type" => "user",
               "member_id" => @user
             })

    assert {:egress, %{"kind" => "provider_space", "provider" => "lark", "connect_id" => "c"}} =
             describe.("lark.share_doc", %{
               "connect_id" => "c",
               "member_type" => "department",
               "member_id" => "od_1"
             })

    assert {:egress, %{"kind" => "provider_space", "provider" => "lark", "connect_id" => "c"}} =
             describe.("lark.update_doc_link_share", %{
               "connect_id" => "c",
               "link_share_entity" => "tenant_readable"
             })

    assert {:none, _descriptor} =
             describe.("lark.update_doc_link_share", %{"link_share_entity" => "closed"})

    # A Task card answers a message: the message is the address, and the chat
    # the Router names is a hint for it.
    assert {:egress,
            %{
              "kind" => "provider_message",
              "provider" => "lark",
              "connect_id" => "c",
              "message_id" => "om_source",
              "scope_id" => @group
            }} =
             describe.("lark.post_task_card", %{
               "connect_id" => "c",
               "conversation_id" => "cnv",
               "chat_id" => @group,
               "message_id" => "om_source"
             })

    # What a send carries from another audience is named at the end of its text.
    assert %{"text" => "Done.\n\nfrom: #launch"} =
             SalixAgent.IFC.Provenance.apply(
               "im_api.lark.send_message",
               %{"chat_id" => @group, "text" => "Done."},
               "from: #launch"
             )
  end
end
