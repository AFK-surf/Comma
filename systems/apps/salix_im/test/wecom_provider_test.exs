defmodule SalixIM.WeComProviderTest do
  @moduledoc """
  The WeCom (企业微信) AI bot provider against a fake WeCom long connection:
  a connect checks the Bot ID and Secret by subscribing once, its socket
  subscribes and joins the cluster group, a message from a private chat or a
  group mention enters the Group's Router Conversation, and
  `wecom.send_message` answers on the socket as a reply to the message or as
  a proactive message.

  The fake answers what the official SDKs expect: `errcode` 0 for a
  subscription with the right Secret, a ping, a send or an upload step, with
  the request's own `req_id`. A test can make it refuse replies.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixIM.{Provider, ProviderConnects, WeComFiles, WeComSocket}
  alias SalixIM.TestSupport.FakeWeCom
  alias SalixStore.{CasRecord, Ids, Keys, S3}

  @secret FakeWeCom.secret()
  @user "zhen"
  @group "wrkSFfCgAAxxxxGroup"

  defmodule Workspace do
    @moduledoc false
    def read_stream(_agent_id, "/out/report.pdf"),
      do:
        {:ok, [String.duplicate("a", 600_000), String.duplicate("b", 100_000)], 700_000,
         "report.pdf"}

    def read_stream(_agent_id, _path), do: {:error, "file not found"}
  end

  setup do
    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      url: SystemsRuntime.get_env(:salix_im, :wecom_socket_url),
      workspace: SystemsRuntime.get_env(:salix_im, :agent_workspace_mod),
      hosts: SystemsRuntime.get_env(:salix_im, :wecom_media_test_hosts)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    fake = FakeWeCom.serve!(SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_im, :wecom_socket_url, fake.url)
    SystemsRuntime.put_env(:salix_im, :agent_workspace_mod, Workspace)
    SystemsRuntime.put_env(:salix_im, :wecom_media_test_hosts, ["127.0.0.1"])

    on_exit(fn ->
      restore(:salix_store, :s3_backend, previous.s3)
      restore(:salix_im, :wecom_socket_url, previous.url)
      restore(:salix_im, :agent_workspace_mod, previous.workspace)
      restore(:salix_im, :wecom_media_test_hosts, previous.hosts)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    {group_id, router_id} = group_with_router(tenant)
    bot_id = "aib#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, connect} =
      ProviderConnects.create_wecom_im_connect(tenant, group_id, %{
        "app_id" => bot_id,
        "app_secret" => @secret
      })

    # The credential check subscribed once.
    settle_receive({:fake_wecom, :socket, _check})
    settle_receive({:fake_wecom, :frame, %{"cmd" => "aibot_subscribe"}})

    %{
      tenant: tenant,
      group_id: group_id,
      router_id: router_id,
      bot_id: bot_id,
      connect: connect,
      behavior: fake.behavior,
      media: fake.media,
      base: fake.base
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

  # The connect's socket, subscribed: the fake socket process to push frames on.
  defp open_socket(ctx) do
    {:ok, connect} = CasRecord.get(Keys.ctl_im_connect(ctx.group_id, ctx.connect["connect_id"]))

    start_supervised!(
      {WeComSocket,
       connect: connect, task_supervisor: start_supervised!(SystemsRuntime.TaskSupervisor)}
    )

    settle_receive({:fake_wecom, :socket, socket})

    settle_receive(
      {:fake_wecom, :frame,
       %{"cmd" => "aibot_subscribe", "body" => %{"bot_id" => bot_id, "secret" => @secret}}}
    )

    assert bot_id == ctx.bot_id
    settle_until(fn -> WeComSocket.connected?(ctx.connect["connect_id"]) end)
    socket
  end

  defp push(socket, frame), do: SystemsRuntime.Proc.send(socket, {:send, frame})

  defp message(id, body) do
    %{
      "cmd" => "aibot_msg_callback",
      "headers" => %{"req_id" => "req-" <> id},
      "body" =>
        Map.merge(
          %{
            "msgid" => id,
            "aibotid" => "aib",
            "chattype" => "single",
            # As WeCom sends them: no `create_time`.
            "from" => %{"userid" => @user}
          },
          body
        )
    }
  end

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

  defp origin(ctx, chat_id, req_id) do
    %{
      "provider" => "wecom",
      "source_actor_type" => "provider_user",
      "source_sent_at_ms" => SystemsClock.system_time(:millisecond),
      "provider_context" => %{
        "connect_id" => ctx.connect["connect_id"],
        "chat_id" => chat_id,
        "event_id" => req_id,
        "from_user_id" => @user
      }
    }
  end

  defp send_message(ctx, params, origin \\ nil) do
    Provider.call_api(ctx.router_id, "wecom", "wecom.send_message", %{
      "connect_id" => ctx.connect["connect_id"],
      "params" => params,
      "tool_context" => %{"trusted_origin" => origin}
    })
  end

  describe "connect" do
    test "checks the credentials by subscribing, hides the secret, owns its bot and is indexed",
         ctx do
      assert %{"provider" => "wecom", "status" => "connected", "app_secret_configured" => true} =
               ctx.connect

      assert ctx.connect["app_id"] == ctx.bot_id
      refute inspect(ctx.connect) =~ @secret

      assert {:ok, connects} = ProviderConnects.list_wecom_connects()
      assert ctx.connect["connect_id"] in Enum.map(connects, & &1["connect_id"])

      {other_group, _router} = group_with_router(ctx.tenant)

      assert {:error, {:bad_request, "WeCom refused this Bot ID and Secret"}} =
               ProviderConnects.create_wecom_im_connect(ctx.tenant, other_group, %{
                 "app_id" => "aib-other",
                 "app_secret" => "wrong"
               })

      # One bot serves one Group.
      assert {:error, {:bad_request, message}} =
               ProviderConnects.create_wecom_im_connect(ctx.tenant, other_group, %{
                 "app_id" => ctx.bot_id,
                 "app_secret" => @secret
               })

      assert message =~ "already used by another connect"

      # A disabled connect keeps no socket.
      _ = ProviderConnects.disable_im_connect(ctx.tenant, ctx.group_id, ctx.connect["connect_id"])

      assert {:ok, connects} = ProviderConnects.list_wecom_connects()
      refute ctx.connect["connect_id"] in Enum.map(connects, & &1["connect_id"])
    end
  end

  describe "credential check" do
    test "an answer split across two reads still proves the credentials" do
      # A real upgrade on the fake, then the socket's reads are handed to the
      # check one at a time, as the network may split a frame.
      %URI{port: port} = URI.parse(SystemsRuntime.get_env(:salix_im, :wecom_socket_url))
      {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/", [])
      {conn, status, headers} = upgraded(conn, ref, nil, [])
      {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, headers)

      payload = Jason.encode!(%{"headers" => %{"req_id" => "req-split"}, "errcode" => 0})
      <<head::binary-size(6), tail::binary>> = <<0x81, byte_size(payload)>> <> payload
      socket = Mint.HTTP.get_socket(conn)
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:tcp, socket, head})
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:tcp, socket, tail})

      deadline = SystemsClock.monotonic_time(:millisecond) + 5_000

      assert :ok =
               SalixIM.Provider.WeCom.await_answer(conn, ref, ws, "req-split", deadline)

      Mint.HTTP.close(conn)
    end
  end

  describe "inbound" do
    test "a private message reaches the Router Conversation once, with its req_id", ctx do
      socket = open_socket(ctx)
      frame = message("m-private", %{"msgtype" => "text", "text" => %{"content" => "你好"}})

      push(socket, frame)
      # WeCom can deliver one message twice; it is the same Router input.
      push(socket, frame)

      source_id = "im_provider:wecom:#{ctx.connect["connect_id"]}:m-private"
      settle_until(fn -> router_inputs(ctx.group_id, source_id) != [] end)
      assert [input] = router_inputs(ctx.group_id, source_id)
      origin = input["agent_input"][:trusted_origin]

      assert origin["provider"] == "wecom"
      assert origin["source_text"] == "你好"

      assert Map.take(
               origin["provider_context"],
               ~w(connect_id chat_id chat_type message_id from_user_id event_id)
             ) == %{
               "connect_id" => ctx.connect["connect_id"],
               "chat_id" => "user:" <> @user,
               "chat_type" => "private",
               "message_id" => "m-private",
               "from_user_id" => @user,
               "event_id" => "req-m-private"
             }
    end

    test "a group mention reaches the Router with the message it quotes as context", ctx do
      socket = open_socket(ctx)

      push(
        socket,
        message("m-group", %{
          "chattype" => "group",
          "chatid" => @group,
          "msgtype" => "text",
          "text" => %{"content" => "@Comma 总结一下"},
          "quote" => %{"msgtype" => "text", "text" => %{"content" => "今日的测试情况"}}
        })
      )

      source_id = "im_provider:wecom:#{ctx.connect["connect_id"]}:m-group"
      settle_until(fn -> router_inputs(ctx.group_id, source_id) != [] end)
      assert [input] = router_inputs(ctx.group_id, source_id)
      origin = input["agent_input"][:trusted_origin]

      assert origin["provider_context"]["chat_id"] == "group:" <> @group
      assert origin["provider_context"]["chat_type"] == "group"
      assert origin["source_text"] == "@Comma 总结一下"
      assert inspect(input) =~ "今日的测试情况"
    end

    test "a message gets a working line at once, which the Router's answer finishes in place",
         ctx do
      socket = open_socket(ctx)

      push(
        socket,
        message("m-ask", %{
          "chattype" => "group",
          "chatid" => @group,
          "msgtype" => "text",
          "text" => %{"content" => "@Comma 在吗"}
        })
      )

      source_id = "im_provider:wecom:#{ctx.connect["connect_id"]}:m-ask"
      settle_until(fn -> router_inputs(ctx.group_id, source_id) != [] end)
      assert [input] = router_inputs(ctx.group_id, source_id)

      # The Router answers as soon as it has the message, with the origin its
      # input carried (no `create_time` in the frame: the ingress time stands
      # in).
      assert {:ok, %{"delivery" => "reply"}} =
               send_message(ctx, %{"text" => "在"}, input["agent_input"][:trusted_origin])

      # The working line went out before the Router had the message; the
      # answer finishes it in place.
      settle_receive({:fake_wecom, :frame, %{"cmd" => "aibot_respond_msg"} = first})

      assert %{
               "headers" => %{"req_id" => "req-m-ask"},
               "body" => %{
                 "msgtype" => "stream",
                 "stream" => %{"id" => "comma_m-ask", "finish" => false, "content" => "正在处理…"}
               }
             } = first

      settle_receive(
        {:fake_wecom, :frame,
         %{
           "cmd" => "aibot_respond_msg",
           "headers" => %{"req_id" => "req-m-ask"},
           "body" => %{
             "msgtype" => "stream",
             "stream" => %{"id" => "comma_m-ask", "finish" => true, "content" => "在"}
           }
         }}
      )

      # A second answer to the same message is a reply of its own.
      assert {:ok, %{"delivery" => "reply"}} =
               send_message(ctx, %{"text" => "还有"}, input["agent_input"][:trusted_origin])

      settle_receive(
        {:fake_wecom, :frame,
         %{
           "cmd" => "aibot_respond_msg",
           "headers" => %{"req_id" => "req-m-ask"},
           "body" => %{"msgtype" => "markdown", "markdown" => %{"content" => "还有"}}
         }}
      )
    end

    test "a message WeCom delivers twice opens one working line, never reopened", ctx do
      socket = open_socket(ctx)
      frame = message("m-twice", %{"msgtype" => "text", "text" => %{"content" => "两次"}})
      push(socket, frame)
      push(socket, frame)

      source_id = "im_provider:wecom:#{ctx.connect["connect_id"]}:m-twice"
      settle_until(fn -> router_inputs(ctx.group_id, source_id) != [] end)
      [input] = router_inputs(ctx.group_id, source_id)

      settle_receive(
        {:fake_wecom, :frame, %{"body" => %{"stream" => %{"id" => "comma_m-twice"}}}}
      )

      assert {:ok, _sent} =
               send_message(ctx, %{"text" => "好"}, input["agent_input"][:trusted_origin])

      settle_receive(
        {:fake_wecom, :frame,
         %{"body" => %{"stream" => %{"id" => "comma_m-twice", "finish" => true}}}}
      )

      # A third delivery after the answer reopens nothing either.
      push(socket, frame)

      settle_refute_receive(
        {:fake_wecom, :frame, %{"body" => %{"stream" => %{"finish" => false}}}},
        1_000
      )
    end

    test "a file-only answer finishes the working line with the file's name", ctx do
      socket = open_socket(ctx)
      push(socket, message("m-file", %{"msgtype" => "text", "text" => %{"content" => "发报告"}}))

      source_id = "im_provider:wecom:#{ctx.connect["connect_id"]}:m-file"
      settle_until(fn -> router_inputs(ctx.group_id, source_id) != [] end)
      [input] = router_inputs(ctx.group_id, source_id)

      assert {:ok, %{"filename" => "report.pdf"}} =
               send_message(
                 ctx,
                 %{"path" => "/out/report.pdf"},
                 input["agent_input"][:trusted_origin]
               )

      settle_receive(
        {:fake_wecom, :frame,
         %{
           "body" => %{
             "stream" => %{
               "id" => "comma_m-file",
               "finish" => true,
               "content" => "文件：report.pdf"
             }
           }
         }}
      )

      settle_receive(
        {:fake_wecom, :frame, %{"cmd" => "aibot_respond_msg", "body" => %{"msgtype" => "file"}}}
      )

      settle_refute_receive(
        {:fake_wecom, :frame, %{"body" => %{"stream" => %{"content" => "处理时间较长，结果会另外发送。"}}}},
        10 * 60_000
      )
    end

    test "a working line no answer finished is closed before WeCom ends the stream", ctx do
      # The socket alone: a Router run would answer (or send its failure
      # notice) and finish the line itself.
      open_socket(ctx)

      assert {:ok, _} =
               WeComSocket.request(
                 ctx.connect["connect_id"],
                 "aibot_respond_msg",
                 "req-slow",
                 WeComSocket.stream_frame("comma_m-slow", false, "正在处理…")
               )

      settle_receive(
        {:fake_wecom, :frame,
         %{"body" => %{"stream" => %{"id" => "comma_m-slow", "finish" => false}}}}
      )

      settle_refute_receive(
        {:fake_wecom, :frame, %{"body" => %{"stream" => %{"finish" => true}}}},
        8 * 60_000
      )

      settle_after(60_000)

      settle_receive(
        {:fake_wecom, :frame,
         %{
           "cmd" => "aibot_respond_msg",
           "headers" => %{"req_id" => "req-slow"},
           "body" => %{
             "stream" => %{
               "id" => "comma_m-slow",
               "finish" => true,
               "content" => "处理时间较长，结果会另外发送。"
             }
           }
         }}
      )
    end

    test "a call from WeCom's own assistant and an event do not reach the Router", ctx do
      socket = open_socket(ctx)

      push(
        socket,
        message("m-assistant", %{
          "chattype" => "group",
          "chatid" => "assistant-chat",
          "msgtype" => "text",
          "text" => %{"content" => "帮我查一下"},
          "compat_info" => %{"source" => "ai_assistant"}
        })
      )

      push(socket, %{
        "cmd" => "aibot_event_callback",
        "headers" => %{"req_id" => "req-enter"},
        "body" => %{
          "msgid" => "m-enter",
          "chattype" => "single",
          "from" => %{"userid" => @user},
          "msgtype" => "event",
          "event" => %{"eventtype" => "enter_chat"}
        }
      })

      settle_refute_receive(:never, 200)

      for id <- ["m-assistant", "m-enter"] do
        assert router_inputs(ctx.group_id, "im_provider:wecom:#{ctx.connect["connect_id"]}:#{id}") ==
                 []
      end
    end
  end

  describe "wecom.send_message" do
    test "answers the current message as a reply, and another chat as a proactive message",
         ctx do
      open_socket(ctx)
      chat = "user:" <> @user

      assert {:ok, %{"delivery" => "reply", "chat_id" => ^chat}} =
               send_message(ctx, %{"text" => "**好的**"}, origin(ctx, chat, "req-1"))

      settle_receive(
        {:fake_wecom, :frame,
         %{
           "cmd" => "aibot_respond_msg",
           "headers" => %{"req_id" => "req-1"},
           "body" => %{"msgtype" => "markdown", "markdown" => %{"content" => "**好的**"}}
         }}
      )

      assert {:ok, %{"delivery" => "proactive"}} =
               send_message(
                 ctx,
                 %{"chat_id" => "group:" <> @group, "text" => "完成了"},
                 origin(ctx, chat, "req-1")
               )

      settle_receive(
        {:fake_wecom, :frame,
         %{
           "cmd" => "aibot_send_msg",
           "body" => %{"chatid" => @group, "chat_type" => 2, "msgtype" => "markdown"}
         }}
      )
    end

    test "a reply WeCom refuses goes out once more as a proactive message", ctx do
      open_socket(ctx)
      Agent.update(ctx.behavior, &Map.put(&1, :refuse_replies, true))
      chat = "user:" <> @user

      assert {:ok, %{"delivery" => "proactive"}} =
               send_message(ctx, %{"text" => "晚到的回答"}, origin(ctx, chat, "req-old"))

      settle_receive({:fake_wecom, :frame, %{"cmd" => "aibot_respond_msg"}})

      settle_receive(
        {:fake_wecom, :frame,
         %{"cmd" => "aibot_send_msg", "body" => %{"chatid" => @user, "chat_type" => 1}}}
      )
    end

    test "a file goes up in parts of 512 KiB and out as its own message after the text", ctx do
      open_socket(ctx)

      assert {:ok, %{"filename" => "report.pdf"}} =
               send_message(ctx, %{
                 "chat_id" => "user:" <> @user,
                 "text" => "报告在这里",
                 "path" => "/out/report.pdf"
               })

      settle_receive(
        {:fake_wecom, :frame, %{"cmd" => "aibot_send_msg", "body" => %{"msgtype" => "markdown"}}}
      )

      settle_receive(
        {:fake_wecom, :frame,
         %{
           "cmd" => "aibot_upload_media_init",
           "body" => %{"type" => "file", "total_size" => 700_000, "total_chunks" => 2}
         }}
      )

      for index <- [0, 1] do
        settle_receive(
          {:fake_wecom, :frame,
           %{"cmd" => "aibot_upload_media_chunk", "body" => %{"chunk_index" => ^index} = chunk}}
        )

        size = if index == 0, do: 512 * 1024, else: 700_000 - 512 * 1024
        assert byte_size(Base.decode64!(chunk["base64_data"])) == size
      end

      settle_receive({:fake_wecom, :frame, %{"cmd" => "aibot_upload_media_finish"}})

      settle_receive(
        {:fake_wecom, :frame,
         %{
           "cmd" => "aibot_send_msg",
           "body" => %{"msgtype" => "file", "file" => %{"media_id" => "media_1"}}
         }}
      )
    end

    test "without an open connection the send fails and says it will open again", ctx do
      assert {:error, message} =
               send_message(ctx, %{"chat_id" => "user:" <> @user, "text" => "hi"})

      assert inspect(message) =~ "connection to WeCom is not open"
    end
  end

  describe "socket" do
    test "requests that answer one message go out one at a time", ctx do
      open_socket(ctx)
      test = SystemsRuntime.Proc.self()
      connect_id = ctx.connect["connect_id"]

      # The fake answers each request at once; the order of the frames is the
      # order of the answers the socket waited for.
      for n <- 1..3 do
        SystemsRuntime.Proc.spawn(fn ->
          result =
            WeComSocket.request(connect_id, "aibot_respond_msg", "req-shared", %{"n" => n})

          SystemsRuntime.Proc.send(test, {:sent, n, result})
        end)
      end

      for _ <- 1..3, do: settle_receive({:sent, _n, {:ok, %{"errcode" => 0}}})

      frames =
        for _ <- 1..3 do
          settle_receive(
            {:fake_wecom, :frame, %{"cmd" => "aibot_respond_msg", "body" => %{"n" => n}}}
          )

          n
        end

      assert Enum.sort(frames) == [1, 2, 3]
    end

    test "a request left unanswered gives the socket up, so its late answer confirms nothing",
         ctx do
      old_socket = open_socket(ctx)
      connect_id = ctx.connect["connect_id"]
      Agent.update(ctx.behavior, &Map.put(&1, :hold_replies, true))

      first =
        SystemsRuntime.Task.async(fn ->
          WeComSocket.request(connect_id, "aibot_respond_msg", "req-late", %{"n" => 1},
            timeout: 1_000
          )
        end)

      settle_receive({:fake_wecom, :frame, %{"headers" => %{"req_id" => "req-late"}}})
      settle_after(1_000)
      assert {:ok, {:error, :timeout}} = SystemsClock.yield(first, 1_000)

      # A new socket subscribes; the answer to the first request comes late
      # on the old one, long after any wait for it.
      settle_receive({:fake_wecom, :socket, new_socket})
      assert new_socket != old_socket
      settle_until(fn -> WeComSocket.connected?(connect_id) end)
      settle_after(60_000)

      push(old_socket, %{"headers" => %{"req_id" => "req-late"}, "errcode" => 0, "errmsg" => "ok"})

      # The next request with that req_id gets its own answer: a refusal.
      Agent.update(ctx.behavior, &Map.merge(&1, %{hold_replies: false, refuse_replies: true}))

      assert {:error, {:wecom, 846_605, _message}} =
               WeComSocket.request(connect_id, "aibot_respond_msg", "req-late", %{"n" => 2})
    end

    test "the connect lists as online only while its socket is subscribed", ctx do
      online? = fn ->
        {:ok, connects} = ProviderConnects.list_group_im_connects(ctx.group_id, "wecom")
        [connect] = connects
        connect["socket_online"]
      end

      assert online?.() == false
      open_socket(ctx)
      assert online?.() == true
    end

    test "another connection taking the bot closes this one, which takes it back later", ctx do
      socket = open_socket(ctx)
      connect_id = ctx.connect["connect_id"]

      push(socket, %{
        "cmd" => "aibot_event_callback",
        "headers" => %{"req_id" => "req-kick"},
        "body" => %{"msgtype" => "event", "event" => %{"eventtype" => "disconnected_event"}}
      })

      settle_until(fn -> not WeComSocket.connected?(connect_id) end)

      assert {:error, :not_connected} =
               WeComSocket.request(connect_id, "aibot_send_msg", nil, %{})

      # It subscribes again after a while.
      settle_refute_receive({:fake_wecom, :frame, %{"cmd" => "aibot_subscribe"}}, 4_000)
      settle_receive({:fake_wecom, :frame, %{"cmd" => "aibot_subscribe"}})
      settle_until(fn -> WeComSocket.connected?(connect_id) end)
    end
  end

  describe "files" do
    test "an attachment is decrypted with its own aeskey as the SDKs read it", ctx do
      key = SystemsRuntime.Proc.random_bytes(32)
      aeskey = Base.encode64(key, padding: false)
      plain = <<0x89, "PNG\r\n", 0x1A, "\n">> <> String.duplicate("WeCom file ", 10_000)

      pad = 32 - rem(byte_size(plain), 32)
      padded = plain <> :binary.copy(<<pad>>, pad)
      <<iv::binary-size(16), _::binary>> = key

      encrypted =
        :crypto.crypto_one_time(:aes_256_cbc, key, iv, padded, encrypt: true, padding: :none)

      assert {:ok, ^plain} = WeComFiles.decrypt(encrypted, key)
      Agent.update(ctx.media, &Map.put(&1, "f1", encrypted))

      # The name comes from the download's Content-Disposition, the type from
      # the bytes.
      assert {:ok, %{ref: ref, size: size, file_name: "淘宝.png", mime_type: "image/png"}} =
               WeComFiles.download(
                 ctx.router_id,
                 ctx.base <> "/media/f1",
                 aeskey,
                 WeComFiles.max_bytes()
               )

      assert size == byte_size(encrypted)
      assert {:ok, ^plain} = SalixStore.Blob.get(ctx.router_id, ref)

      # Only WeCom's own hosts are fetched.
      assert {:error, :missing_download_url} =
               WeComFiles.download(
                 ctx.router_id,
                 "https://example.com/f1",
                 aeskey,
                 WeComFiles.max_bytes()
               )
    end
  end

  # The upgrade response, read until it is whole.
  defp upgraded(conn, ref, status, headers) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            status =
              Enum.find_value(responses, status, fn
                {:status, ^ref, code} -> code
                _other -> nil
              end)

            headers =
              headers ++
                Enum.flat_map(responses, fn
                  {:headers, ^ref, more} -> more
                  _other -> []
                end)

            if Enum.any?(responses, &match?({:done, ^ref}, &1)),
              do: {conn, status, headers},
              else: upgraded(conn, ref, status, headers)

          :unknown ->
            upgraded(conn, ref, status, headers)
        end
    end
  end
end
