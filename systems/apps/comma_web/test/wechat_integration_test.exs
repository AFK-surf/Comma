defmodule CommaWeb.WeChatIntegrationTest do
  use ExUnit.Case, async: false
  import Comma.WorkspaceTestSupport
  import Plug.Conn
  import Plug.Test
  alias SalixIM.{ProviderConnects, ProviderHTTP, WeChatConnects}

  defmodule Provider do
    import Plug.Conn
    def init(opts), do: opts

    def call(%{request_path: "/download"} = conn, _) do
      send(Application.fetch_env!(:comma_web, :wechat_test_pid), :media_download)

      if Application.get_env(:comma_web, :wechat_test_hold_media, false) do
        send(Application.fetch_env!(:comma_web, :wechat_test_pid), {:media_waiting, self()})

        receive do
          :release_media -> :ok
        after
          5_000 -> raise "media barrier was not released"
        end
      end

      send_resp(conn, 200, Application.fetch_env!(:comma_web, :wechat_test_media))
    end

    def call(conn, _) do
      conn = fetch_query_params(conn)

      send(
        Application.fetch_env!(:comma_web, :wechat_test_pid),
        {:provider, conn.request_path, conn.query_params}
      )

      response =
        case conn.request_path do
          "/ilink/bot/get_bot_qrcode" ->
            %{"qrcode" => "test-qr", "qrcode_img_content" => "https://weixin.qq.com/test-qr"}

          "/ilink/bot/get_qrcode_status" ->
            Application.fetch_env!(:comma_web, :wechat_test_response)

          "/ilink/bot/getupdates" ->
            Application.fetch_env!(:comma_web, :wechat_test_updates)

          "/ilink/bot/sendmessage" ->
            {:ok, body, _} = read_body(conn)

            send(
              Application.fetch_env!(:comma_web, :wechat_test_pid),
              {:wechat_reply, get_req_header(conn, "authorization"), Jason.decode!(body)}
            )

            Application.get_env(:comma_web, :wechat_test_send_response, %{
              "ret" => 0,
              "message_id" => "18446744073709551615"
            })
        end

      conn
      |> put_resp_content_type("application/octet-stream")
      |> send_resp(200, Jason.encode!(response))
    end
  end

  defmodule Delivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent, payload, opts) do
      test_pid = Application.fetch_env!(:comma_web, :wechat_test_pid)
      source = {agent, opts[:source_message_id]}
      send(test_pid, {:router_dispatch, source})

      admitted? =
        Agent.get_and_update(
          Application.fetch_env!(:comma_web, :wechat_test_admissions),
          fn seen ->
            {not MapSet.member?(seen, source), MapSet.put(seen, source)}
          end
        )

      if admitted? do
        send(test_pid, {:router_input, agent, payload, opts})
        {:ok, :created}
      else
        {:ok, :duplicate}
      end
    end
  end

  defmodule Workspace do
    def put_ref(agent, path, ref) do
      send(Application.fetch_env!(:comma_web, :wechat_test_pid), {:published, agent, path, ref})
      {:ok, %{path: path, size: ref.size}}
    end
  end

  setup_all do
    unless Process.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)
    :ok
  end

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    billing = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    keys = [
      {:salix_im, :wechat_api_base_url},
      {:salix_im, :wechat_command_handler},
      {:salix_im, :wechat_cdn_base_url},
      {:salix_im, :agent_workspace_mod},
      {:comma_web, :wechat_test_media},
      {:comma_web, :wechat_test_admissions},
      {:comma_web, :wechat_test_hold_media},
      {:salix_im, :agent_delivery_mod},
      {:comma_web, :wechat_test_pid},
      {:comma_web, :wechat_test_response},
      {:comma_web, :wechat_test_updates},
      {:comma_web, :wechat_test_send_response}
    ]

    previous = for {app, key} <- keys, do: {app, key, Application.get_env(app, key)}

    on_exit(fn ->
      CommaWeb.TestRepoSandbox.stop_owner(owner)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing)

      for {app, key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    if Process.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    port =
      SalixIM.TestSupport.BanditServer.start!(fn port -> {Bandit, plug: Provider, port: port} end)

    base = "http://127.0.0.1:#{port}"
    Application.put_env(:salix_im, :wechat_command_handler, CommaWeb.WeChatCommands)
    Application.put_env(:salix_im, :wechat_api_base_url, base)
    Application.put_env(:salix_im, :wechat_cdn_base_url, base)
    Application.put_env(:salix_im, :agent_workspace_mod, Workspace)
    Application.put_env(:salix_im, :agent_delivery_mod, Delivery)
    Application.put_env(:comma_web, :wechat_test_pid, self())
    admissions = start_supervised!({Agent, fn -> MapSet.new() end})
    Application.put_env(:comma_web, :wechat_test_admissions, admissions)
    Application.put_env(:comma_web, :wechat_test_response, %{"status" => "wait"})

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "wechat-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user, %{"name" => "WeChat Test"})
    {:ok, session} = Comma.Accounts.create_session(user["id"])
    %{user: user, workspace: workspace, session: session, base: base}
  end

  test "device commands use owner binding and stable choices without waking the Router", c do
    attempt = api(c.session, :post, path(c) <> "/connect", %{}) |> json(201)
    confirm(c)
    connected = poll(c, attempt)

    {:ok, connect} =
      ProviderConnects.get_active_connect_by_id(
        c.workspace["default_group_id"],
        connected["connect_id"],
        "wechat"
      )

    {:ok, token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(
        c.workspace["default_group_id"],
        c.workspace["salix_tenant_id"],
        %{}
      )

    {:ok, _} =
      Comma.Devices.rename(c.user, %{}, c.workspace["id"], token["device_id"], %{
        "name" => "Studio Mac"
      })

    message = fn id, text ->
      %{
        "message_id" => id,
        "message_type" => 1,
        "from_user_id" => "alice",
        "to_user_id" => "bot-1",
        "context_token" => "device-context",
        "item_list" => [%{"type" => 1, "text_item" => %{"text" => text}}]
      }
    end

    assert {:error, :ignored} =
             ProviderHTTP.handle_wechat_update(
               connect,
               Map.put(message.("foreign", "设备列表"), "from_user_id", "mallory")
             )

    refute_receive {:wechat_reply, _, _}

    assert {:ok, :queued} =
             ProviderHTTP.handle_wechat_update(connect, message.("device-list", "设备列表"))

    assert_receive {:wechat_reply, _, body}
    assert body["msg"]["context_token"] == "device-context"
    text = get_in(body, ["msg", "item_list"]) |> hd() |> get_in(["text_item", "text"])
    assert text =~ "Studio Mac"
    [command] = Regex.run(~r/设备 [A-F0-9]{12} 1/, text)

    quoted_choice =
      message.("device-detail", "1")
      |> put_in(["item_list", Access.at(0), "ref_msg"], %{"svr_id" => "18446744073709551615"})

    assert {:ok, :queued} = ProviderHTTP.handle_wechat_update(connect, quoted_choice)

    assert_receive {:wechat_reply, _, detail}
    assert Jason.encode!(detail) =~ "设备操作权限"
    refute_receive {:router_input, _, _, _}

    assert {:ok, :duplicate} =
             ProviderHTTP.handle_wechat_update(connect, message.("device-detail", command))

    refute_receive {:wechat_reply, _, _}

    assert {:ok, :queued} =
             ProviderHTTP.handle_wechat_update(connect, message.("device-new-list", "设备列表"))

    assert_receive {:wechat_reply, _, _}

    assert {:ok, :queued} =
             ProviderHTTP.handle_wechat_update(connect, message.("device-old-selection", command))

    assert_receive {:wechat_reply, _, expired}
    assert Jason.encode!(expired) =~ "已过期"
    api(c.session, :delete, path(c)) |> json(200)
    assert {:error, _} = ProviderHTTP.handle_wechat_update(connect, message.("revoked", command))
    refute_receive {:wechat_reply, _, _}
  end

  test "task list command uses the current WeChat binding and opens Comma login", c do
    :ok = CommaWeb.TestConvergence.workspace!(c.workspace["id"])

    {:ok, _task} =
      SalixCluster.TaskSchedules.create_task_conversation(
        c.workspace["default_group_id"],
        c.workspace["router_agent_id"],
        c.workspace["default_worker_agent_id"],
        %{
          "title" => "Review WeChat task panel",
          "content" => "Check the read-only view",
          "client_request_id" => "wechat-tasks-test"
        }
      )

    attempt = api(c.session, :post, path(c) <> "/connect", %{}) |> json(201)
    confirm(c)
    connected = poll(c, attempt)

    {:ok, connect} =
      ProviderConnects.get_active_connect_by_id(
        c.workspace["default_group_id"],
        connected["connect_id"],
        "wechat"
      )

    message = fn id, text ->
      %{
        "message_id" => id,
        "message_type" => 1,
        "from_user_id" => "alice",
        "to_user_id" => "bot-1",
        "context_token" => "task-list-context",
        "item_list" => [%{"type" => 1, "text_item" => %{"text" => text}}]
      }
    end

    assert {:error, :ignored} =
             ProviderHTTP.handle_wechat_update(
               connect,
               Map.put(message.("foreign-task-list", "查看任务列表"), "from_user_id", "mallory")
             )

    refute_receive {:wechat_reply, _, _}

    assert {:ok, :queued} =
             ProviderHTTP.handle_wechat_update(connect, message.("task-list", "查看任务列表"))

    assert_receive {:wechat_reply, _, body}
    assert body["msg"]["context_token"] == "task-list-context"
    text = get_in(body, ["msg", "item_list"]) |> hd() |> get_in(["text_item", "text"])
    assert text =~ "Review WeChat task panel"
    assert text =~ "请使用 Comma 账号登录"
    origin = Application.fetch_env!(:comma_web, :web_cookie_origin) |> String.trim_trailing("/")
    [_, url] = Regex.run(~r/\[查看全部任务\]\(([^)]+)\)/u, text)
    assert String.starts_with?(url, origin)
    assert URI.parse(url).path == "/task-panel.html"

    assert URI.decode_query(URI.parse(url).query) == %{
             "group_id" => c.workspace["default_group_id"],
             "workspace_id" => c.workspace["id"]
           }

    refute url =~ "token"
    refute_receive {:router_input, _, %{trusted_origin: %{"source_text" => "查看任务列表"}}, _}

    assert {:ok, :queued} =
             ProviderHTTP.handle_wechat_update(connect, message.("freeform-task-list", "帮我看看任务"))

    assert_receive {:router_input, _, %{trusted_origin: %{"source_text" => "帮我看看任务"}}, _}

    assert api(c.session, :delete, path(c)) |> json(200) == %{"disconnected" => true}

    assert {:error, _} =
             ProviderHTTP.handle_wechat_update(connect, message.("revoked-task-list", "/tasks"))

    refute_receive {:wechat_reply, _, _}
  end

  test "queued WeChat reminders cannot bypass the Router, whose ordinary reply still works", c do
    attempt = api(c.session, :post, path(c) <> "/connect", %{}) |> json(201)
    confirm(c)
    connected = poll(c, attempt)
    group = c.workspace["default_group_id"]
    router = c.workspace["router_agent_id"]

    {:ok, connect} =
      ProviderConnects.get_active_connect_by_id(group, connected["connect_id"], "wechat")

    assert {:error, :router_reply_required, false} =
             SalixIM.ConversationDelivery.deliver(%{
               "participant_actor_type" => "provider",
               "participant_provider" => "wechat",
               "source_agent_id" => router,
               "agent_group_id" => group,
               "participant_payload" => %{"connect_id" => connect["connect_id"]},
               "message_content" => [%{"type" => "text", "text" => "Legacy reminder"}],
               "message_metadata" => %{"proactive_owner" => c.user["id"]}
             })

    refute_receive {:wechat_reply, _, _}

    # WeChat can only reply: the target is ready once the owner wrote.
    assert [%{"provider" => "wechat", "ready" => false} = target] =
             CommaWeb.ProactiveDelivery.personal_targets(c.workspace, c.user["id"])

    assert target["tool"] == "im_api.wechat.reply_text"
    assert target["connect_id"] == connect["connect_id"]
    refute Map.has_key?(target, "context_token")

    assert {:ok, _} =
             ProviderHTTP.handle_wechat_update(connect, %{
               "message_id" => "reminder-context",
               "message_type" => 1,
               "from_user_id" => "alice",
               "to_user_id" => "bot-1",
               "context_token" => "ctx-reminder",
               "item_list" => [%{"type" => 1, "text_item" => %{"text" => "hello"}}]
             })

    assert {:ok, _} =
             SalixIM.Provider.call_api(router, "wechat", "wechat.reply_text", %{
               "connect_id" => connect["connect_id"],
               "params" => %{"text" => "Router reviewed the invoice"}
             })

    assert_receive {:wechat_reply, _, reply}
    assert reply["msg"]["context_token"] == "ctx-reminder"
    assert inspect(reply) =~ "Router reviewed the invoice"

    assert [%{"provider" => "wechat", "ready" => true}] =
             CommaWeb.ProactiveDelivery.personal_targets(c.workspace, c.user["id"])
  end

  test "QR pairing authorizes one sender, routes official item text and disconnects", c do
    path = path(c)
    assert api(c.session, :get, path) |> json(200) == %{"connection" => nil, "pending" => nil}
    attempt = api(c.session, :post, path <> "/connect", %{}) |> json(201)
    refute attempt["connection_active"]
    assert attempt["qrcode_url"] == "https://weixin.qq.com/test-qr"
    Application.put_env(:comma_web, :wechat_test_response, %{"status" => "need_verifycode"})
    assert poll(c, attempt)["login_status"] == "need_verifycode"
    confirm(c)

    connected =
      api(c.session, :post, path <> "/connect/poll", %{
        "attempt_id" => attempt["connect_id"],
        "verify_code" => "123456"
      })
      |> json(200)

    assert connected["connection_active"]
    refute Jason.encode!(connected) =~ "private-test-token"
    assert_receive {:provider, "/ilink/bot/get_qrcode_status", %{"verify_code" => "123456"}}

    {:ok, connect} =
      ProviderConnects.get_active_connect_by_id(
        c.workspace["default_group_id"],
        connected["connect_id"],
        "wechat"
      )

    message = %{
      "message_id" => "in-1",
      "message_type" => 1,
      "from_user_id" => "alice",
      "to_user_id" => "bot-1",
      "context_token" => "ctx-1",
      "item_list" => [%{"type" => 1, "text_item" => %{"text" => "hello from WeChat"}}]
    }

    assert {:error, :ignored} =
             ProviderHTTP.handle_wechat_update(connect, %{message | "from_user_id" => "mallory"})

    Application.put_env(:comma_web, :wechat_test_updates, %{
      "msgs" => [message],
      "get_updates_buf" => "cursor-1"
    })

    assert {:ok, :polled} = SalixIM.ProviderRuntime.poll_connect(connect)
    assert_receive {:router_input, router, payload, _}
    assert inspect(payload) =~ "hello from WeChat"
    assert {:ok, :duplicate} = ProviderHTTP.handle_wechat_update(connect, message)

    assert {:ok, _} =
             SalixIM.Provider.call_api(router, "wechat", "wechat.reply_text", %{
               "connect_id" => connected["connect_id"],
               "params" => %{"text" => "reply from Comma"}
             })

    assert_receive {:wechat_reply, ["Bearer private-test-token"], reply}
    assert reply["msg"]["to_user_id"] == "alice"
    assert reply["msg"]["context_token"] == "ctx-1"

    assert reply["msg"]["item_list"] == [
             %{"type" => 1, "text_item" => %{"text" => "reply from Comma"}}
           ]

    {:ok, polled} =
      ProviderConnects.fetch_im_connect(connect["group_id"], connect["connect_id"])

    assert polled["updates_buf"] == "cursor-1"
    assert polled["latest_context_token"] == "ctx-1"

    for invalid <- [[], %{"ret" => 42, "get_updates_buf" => "must-not-commit"}] do
      Application.put_env(:comma_web, :wechat_test_updates, invalid)
      assert {:error, _} = SalixIM.ProviderRuntime.poll_connect(polled)

      {:ok, after_error} =
        ProviderConnects.fetch_im_connect(connect["group_id"], connect["connect_id"])

      assert after_error["updates_buf"] == "cursor-1"
      assert after_error["latest_context_token"] == "ctx-1"
    end

    assert api(c.session, :delete, path) |> json(200) == %{"disconnected" => true}

    assert {:error, _} =
             ProviderHTTP.handle_wechat_update(connect, %{message | "message_id" => "in-2"})
  end

  test "authorized media ingress decrypts into Router attachments; duplicates and other peers do not fetch",
       c do
    attempt = api(c.session, :post, path(c) <> "/connect", %{}) |> json(201)
    confirm(c)
    connected = poll(c, attempt)

    {:ok, connect} =
      ProviderConnects.get_active_connect_by_id(
        c.workspace["default_group_id"],
        connected["connect_id"],
        "wechat"
      )

    body = <<0x89, "PNG", 13, 10, 26, 10, "image bytes">>
    key = "0123456789abcdef"
    pad = 16 - rem(byte_size(body), 16)
    cipher = :crypto.crypto_one_time(:aes_128_ecb, key, body <> :binary.copy(<<pad>>, pad), true)
    Application.put_env(:comma_web, :wechat_test_media, cipher)

    message = %{
      "message_id" => "media-1",
      "message_type" => 1,
      "from_user_id" => "alice",
      "to_user_id" => "bot-1",
      "context_token" => "ctx-media",
      "item_list" => [
        %{
          "type" => 2,
          "image_item" => %{
            "media" => %{
              "encrypt_query_param" => "private-query",
              "aes_key" => Base.encode64(key)
            }
          }
        }
      ]
    }

    assert {:error, :ignored} =
             ProviderHTTP.handle_wechat_update(connect, %{message | "from_user_id" => "mallory"})

    refute_receive :media_download, 20
    assert {:ok, _} = ProviderHTTP.handle_wechat_update(connect, message)
    assert_receive :media_download
    assert_receive {:published, agent, media_path, ref}
    assert {:ok, ^body} = SalixStore.Blob.get(agent, ref)
    assert_receive {:router_input, ^agent, payload, _}
    assert inspect(payload) =~ media_path
    refute inspect(payload) =~ "private-query"
    refute inspect(payload) =~ Base.encode64(key)
    assert {:ok, :duplicate} = ProviderHTTP.handle_wechat_update(connect, message)
    refute_receive :media_download, 20
    api(c.session, :delete, path(c)) |> json(200)

    assert {:error, _} =
             ProviderHTTP.handle_wechat_update(connect, %{message | "message_id" => "media-2"})

    refute_receive :media_download, 20
  end

  test "concurrent polls cannot deliver following text before an in-flight image", c do
    connect = ordered_pair(c)

    first = Task.async(fn -> SalixIM.ProviderRuntime.poll_connect(connect) end)
    assert_receive {:media_waiting, downloader}, 2_000

    try do
      # A second node receives the same ordered batch while the first node is fetching media.
      second = Task.async(fn -> SalixIM.ProviderRuntime.poll_connect(connect) end)
      assert {:ok, :busy} = Task.await(second, 2_000)
      refute_receive {:router_input, _, _, _}, 0
    after
      send(downloader, :release_media)
      Task.await(first, 5_000)
    end

    assert_receive {:router_input, _, image_payload, _}
    assert image_payload.trusted_origin["provider_context"]["event_id"] == "ordered-image"
    assert_receive {:router_input, _, text_payload, _}
    assert text_payload.trusted_origin["provider_context"]["event_id"] == "ordered-text"
  end

  test "a killed image poll resumes its durable batch before fetching more updates", c do
    connect = ordered_pair(c)
    {pid, monitor} = spawn_monitor(fn -> SalixIM.ProviderRuntime.poll_connect(connect) end)
    assert_receive {:media_waiting, downloader}, 2_000
    assert_receive {:provider, "/ilink/bot/getupdates", _}
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    send(downloader, :release_media)
    pending = reload_connect(connect)
    assert pending["updates_buf"] == connect["updates_buf"]

    assert Enum.map(pending["pending_wechat_poll"]["messages"], & &1["message_id"]) == [
             "ordered-image",
             "ordered-text"
           ]

    assert {:ok, false} =
             SalixIM.ProviderReceipts.wechat_completed?(connect["connect_id"], "ordered-image")

    # Pre-fix receipts were written before staging. They cannot establish that
    # this image reached the Router and must not suppress recovery.
    assert {:ok, _} =
             SalixStore.CasRecord.create(
               SalixStore.Keys.ctl_im_wechat_event_receipt(
                 connect["connect_id"],
                 "ordered-image"
               ),
               %{
                 "connect_id" => connect["connect_id"],
                 "event_id" => "ordered-image",
                 "created_at" => 1
               }
             )

    expire_poll_lease(connect)
    Application.put_env(:comma_web, :wechat_test_hold_media, false)

    Application.put_env(:comma_web, :wechat_test_updates, %{
      "ret" => 0,
      "msgs" => [],
      "get_updates_buf" => "wrong-new-cursor"
    })

    assert {:ok, :polled} = SalixIM.ProviderRuntime.poll_connect(connect)
    assert_ordered_admissions()
    refute_receive {:provider, "/ilink/bot/getupdates", _}, 20
    assert_finished_pair(connect)
  end

  test "a late poller cannot duplicate admission or regress a successor's cursor and context",
       c do
    connect = ordered_pair(c)
    first = Task.async(fn -> SalixIM.ProviderRuntime.poll_connect(connect) end)
    assert_receive {:media_waiting, downloader}, 2_000
    assert_receive {:provider, "/ilink/bot/getupdates", _}

    try do
      expire_poll_lease(connect)
      Application.put_env(:comma_web, :wechat_test_hold_media, false)
      assert {:ok, :polled} = SalixIM.ProviderRuntime.poll_connect(connect)
      assert_ordered_admissions()
      assert_finished_pair(connect)
      refute_receive {:provider, "/ilink/bot/getupdates", _}, 20
    after
      send(downloader, :release_media)
    end

    assert {:ok, :superseded} = Task.await(first, 5_000)
    # Both pollers use the same log identity, so only one dispatch survives.
    dispatches = drain_dispatches([])

    assert Enum.count(dispatches, fn {_agent, id} -> String.ends_with?(id, ":ordered-image") end) ==
             1

    refute_receive {:router_input, _, _, _}, 20
    assert_finished_pair(connect)
  end

  test "oversized and stale batches cannot acknowledge an unprocessed cursor", c do
    connect = ordered_pair(c)
    [image, text] = Application.fetch_env!(:comma_web, :wechat_test_updates)["msgs"]

    assert {:error, :wechat_poll_batch_limit} =
             ProviderConnects.admit_wechat_poll(connect, List.duplicate(text, 101), "too-many")

    assert {:error, :wechat_poll_batch_limit} =
             ProviderConnects.admit_wechat_poll(
               connect,
               [Map.put(text, "extra", String.duplicate("x", 1_048_576))],
               "too-large"
             )

    assert reload_connect(connect)["updates_buf"] == connect["updates_buf"]
    refute reload_connect(connect)["pending_wechat_poll"]
    Application.put_env(:comma_web, :wechat_test_hold_media, false)
    assert {:ok, :polled} = SalixIM.ProviderRuntime.poll_connect(connect)
    assert_ordered_admissions()

    assert {:error, :stale_wechat_poll} =
             ProviderConnects.admit_wechat_poll(connect, [image], "stale")

    assert_finished_pair(connect)
  end

  test "quoted text and ID-only replies retain context; quoted images reach the actual agent workspace",
       c do
    attempt = api(c.session, :post, path(c) <> "/connect", %{}) |> json(201)
    confirm(c)
    connected = poll(c, attempt)

    {:ok, connect} =
      ProviderConnects.get_active_connect_by_id(
        c.workspace["default_group_id"],
        connected["connect_id"],
        "wechat"
      )

    message = %{
      "message_id" => "original-text",
      "client_id" => "original-client",
      "message_type" => 1,
      "from_user_id" => "alice",
      "to_user_id" => "bot-1",
      "context_token" => "ctx-quote",
      "item_list" => [%{"type" => 1, "text_item" => %{"text" => "the original instruction"}}]
    }

    assert {:ok, _} = ProviderHTTP.handle_wechat_update(connect, message)
    assert_receive {:router_input, agent, _, _}

    quote = %{
      message
      | "message_id" => "quote-text",
        "client_id" => "quote-text-client",
        "item_list" => [
          %{
            "type" => 1,
            "text_item" => %{"text" => "explain this"},
            "ref_msg" => %{"svr_id" => "original-text"}
          }
        ]
    }

    assert {:ok, _} = ProviderHTTP.handle_wechat_update(connect, quote)
    assert_receive {:router_input, ^agent, payload, _}
    assert payload.content =~ "the original instruction"
    assert payload.content =~ "explain this"
    assert payload.trusted_origin["source_text"] == "explain this"

    assert {:ok, _} =
             SalixIM.Provider.call_api(agent, "wechat", "wechat.reply_text", %{
               "connect_id" => connected["connect_id"],
               "params" => %{"text" => "a previous bot answer"}
             })

    assert_receive {:wechat_reply, _, _}

    bot_quote = %{
      quote
      | "message_id" => "quote-bot",
        "client_id" => "quote-bot-client",
        "item_list" => [
          %{
            "type" => 1,
            "text_item" => %{"text" => "clarify"},
            "ref_msg" => %{"svr_id" => "18446744073709551615"}
          }
        ]
    }

    assert {:ok, _} = ProviderHTTP.handle_wechat_update(connect, bot_quote)
    assert_receive {:router_input, ^agent, payload, _}
    assert payload.content =~ "a previous bot answer"

    assert {:ok, _} =
             BillingCore.Credits.issue_grant(%{
               repo: BillingCore.Repo,
               billing_account_id: payload.billing_context["billing_account_id"],
               credits: 100,
               valid_from:
                 DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second),
               expires_at:
                 DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second),
               source_type: "manual_contract",
               source_id: "wechat-storage-test",
               source_event_id: "wechat-storage-test",
               idempotency_key: "wechat-storage-test"
             })

    Application.put_env(:salix_im, :agent_workspace_mod, Salix.Bindings.IMAgentWorkspace)
    body = <<0x89, "PNG", 13, 10, 26, 10, "quoted bytes">>
    Application.put_env(:comma_web, :wechat_test_media, body)

    image_quote = %{
      quote
      | "message_id" => "quote-image",
        "client_id" => "quote-image-client",
        "item_list" => [
          %{
            "type" => 1,
            "text_item" => %{"text" => "describe the quoted image"},
            "ref_msg" => %{
              "message_item" => %{
                "type" => 2,
                "image_item" => %{"media" => %{"encrypt_query_param" => "private-quoted-image"}}
              }
            }
          }
        ]
    }

    assert {:error, :ignored} =
             ProviderHTTP.handle_wechat_update(connect, %{
               image_quote
               | "from_user_id" => "mallory"
             })

    refute_receive :media_download, 20
    assert {:ok, _} = ProviderHTTP.handle_wechat_update(connect, image_quote)
    assert_receive :media_download
    assert_receive {:router_input, ^agent, payload, _}
    [attachment] = payload.trusted_attachment_refs
    media_path = attachment["file_ref"]["path"]
    assert {:ok, ^body} = SalixAgent.Workspace.read(agent, media_path)

    {:ok, other_user} =
      Comma.Accounts.create_user(%{
        "email" => "wechat-other-#{System.unique_integer([:positive])}@comma.test"
      })

    other = create_ready_workspace!(other_user, %{"name" => "Other Scope"})
    {:ok, other_group} = SalixIM.GroupDirectory.get_group(other["default_group_id"])

    assert {:error, _} =
             SalixAgent.Workspace.read(other_group["router_agent_id"], media_path)

    refute inspect(payload) =~ "private-quoted-image"
    assert {:ok, :duplicate} = ProviderHTTP.handle_wechat_update(connect, image_quote)
    refute_receive :media_download, 20
  end

  test "restarting and cancellation invalidate the old attempt", c do
    first = api(c.session, :post, path(c) <> "/connect", %{}) |> json(201)
    second = api(c.session, :post, path(c) <> "/connect", %{}) |> json(201)
    refute first["connect_id"] == second["connect_id"]

    api(c.session, :delete, path(c) <> "/connect", %{"attempt_id" => first["connect_id"]})
    |> json(400)

    confirm(c)

    api(c.session, :post, path(c) <> "/connect/poll", %{"attempt_id" => first["connect_id"]})
    |> json(400)

    api(c.session, :delete, path(c) <> "/connect", %{"attempt_id" => second["connect_id"]})
    |> json(200)

    api(c.session, :post, path(c) <> "/connect/poll", %{"attempt_id" => second["connect_id"]})
    |> json(400)
  end

  test "replayed current polls preserve another session's reconnect attempt", c do
    current = api(c.session, :post, path(c) <> "/connect", %{}) |> json(201)
    confirm(c)
    assert poll(c, current)["connection_active"]
    {:ok, second_session} = Comma.Accounts.create_session(c.user["id"])
    other = %{c | session: second_session}

    pending = api(other.session, :post, path(c) <> "/connect", %{}) |> json(201)
    assert poll(c, current)["connection_active"]
    state = api(other.session, :get, path(c)) |> json(200)
    assert state["pending"]["connect_id"] == pending["connect_id"]

    api(other.session, :delete, path(c) <> "/connect", %{"attempt_id" => pending["connect_id"]})
    |> json(200)

    replacement = api(other.session, :post, path(c) <> "/connect", %{}) |> json(201)
    assert poll(c, current)["connection_active"]
    assert poll(other, replacement)["connection_active"]
    state = api(other.session, :get, path(c)) |> json(200)
    assert state["connection"]["connect_id"] == replacement["connect_id"]
    assert is_nil(state["pending"])

    api(c.session, :post, path(c) <> "/connect/poll", %{"attempt_id" => current["connect_id"]})
    |> json(400)
  end

  test "foreign workspace owner cannot read or mutate a QR connection", c do
    {:ok, other} =
      Comma.Accounts.create_user(%{
        "email" => "other-#{System.unique_integer([:positive])}@comma.test"
      })

    {:ok, session} = Comma.Accounts.create_session(other["id"])

    for {method, suffix, body} <- [
          {:get, "", nil},
          {:post, "/connect", %{}},
          {:post, "/connect/poll", %{"attempt_id" => "x"}},
          {:delete, "", nil}
        ] do
      response = api(session, method, path(c) <> suffix, body)
      assert response.status in [403, 404]
    end

    refute_receive {:provider, _, _}
  end

  test "same-bot reconnect recovers after identity release fails", c do
    old = api(c.session, :post, path(c) <> "/connect", %{}) |> json(201)
    confirm(c)
    assert poll(c, old)["connection_active"]
    replacement = api(c.session, :post, path(c) <> "/connect", %{}) |> json(201)
    key = SalixStore.Keys.ctl_im_provider_identity("wechat", "bot-1")
    SalixStore.S3.Fake.set_fault({:fail, 503, :put, key})

    api(c.session, :post, path(c) <> "/connect/poll", %{"attempt_id" => replacement["connect_id"]})
    |> json(502)

    assert poll(c, replacement)["connection_active"]
    assert {:ok, %{"connect_id" => id}} = SalixStore.CasRecord.get(key)
    assert id == replacement["connect_id"]
  end

  test "foreign bot conflict preserves the working connection", c do
    old = api(c.session, :post, path(c) <> "/connect", %{}) |> json(201)
    confirm(c)
    assert poll(c, old)["connection_active"]

    assert :ok =
             SalixIM.ProviderIdentity.reserve(
               {"wechat", "foreign-bot"},
               "other-tenant",
               "other-group",
               "other-connect"
             )

    replacement = api(c.session, :post, path(c) <> "/connect", %{}) |> json(201)

    Application.put_env(:comma_web, :wechat_test_response, %{
      "status" => "confirmed",
      "bot_token" => "other-token",
      "ilink_bot_id" => "foreign-bot",
      "ilink_user_id" => "alice",
      "baseurl" => c.base
    })

    api(c.session, :post, path(c) <> "/connect/poll", %{"attempt_id" => replacement["connect_id"]})
    |> json(409)

    state = api(c.session, :get, path(c)) |> json(200)
    assert state["connection"]["connect_id"] == old["connect_id"]
    assert state["connection"]["connection_active"]
    assert state["pending"]["status"] == "prepared"

    key =
      SalixStore.Keys.ctl_im_connect(c.workspace["default_group_id"], replacement["connect_id"])

    assert {:ok, _} = SalixStore.CasRecord.update(key, &Map.put(&1, "expires_at", 0))

    assert :ok =
             SalixIM.ProviderIdentity.release_provider("wechat", "foreign-bot", "other-connect")

    assert poll(c, replacement)["connection_active"]
  end

  test "provider redirect cannot send login credentials to another origin", c do
    attempt = api(c.session, :post, path(c) <> "/connect", %{}) |> json(201)

    Application.put_env(:comma_web, :wechat_test_response, %{
      "status" => "scaned_but_redirect",
      "redirect_host" => "attacker.example"
    })

    api(c.session, :post, path(c) <> "/connect/poll", %{"attempt_id" => attempt["connect_id"]})
    |> json(502)

    {:ok, rec} =
      WeChatConnects.fetch(
        c.workspace["salix_tenant_id"],
        c.workspace["default_group_id"],
        attempt["connect_id"]
      )

    assert rec["status"] == "pending"
  end

  defp ordered_pair(c) do
    attempt = api(c.session, :post, path(c) <> "/connect", %{}) |> json(201)
    confirm(c)
    connected = poll(c, attempt)

    {:ok, connect} =
      ProviderConnects.get_active_connect_by_id(
        c.workspace["default_group_id"],
        connected["connect_id"],
        "wechat"
      )

    body = <<0x89, "PNG", 13, 10, 26, 10, "image bytes">>
    key = "0123456789abcdef"
    pad = 16 - rem(byte_size(body), 16)
    cipher = :crypto.crypto_one_time(:aes_128_ecb, key, body <> :binary.copy(<<pad>>, pad), true)
    Application.put_env(:comma_web, :wechat_test_media, cipher)
    Application.put_env(:comma_web, :wechat_test_hold_media, true)

    image = %{
      "message_id" => "ordered-image",
      "message_type" => 1,
      "from_user_id" => "alice",
      "to_user_id" => "bot-1",
      "context_token" => "ctx-image",
      "item_list" => [
        %{
          "type" => 2,
          "image_item" => %{
            "media" => %{
              "encrypt_query_param" => "private-query",
              "aes_key" => Base.encode64(key)
            }
          }
        }
      ]
    }

    text = %{
      image
      | "message_id" => "ordered-text",
        "context_token" => "ctx-text",
        "item_list" => [%{"type" => 1, "text_item" => %{"text" => "what is in this image?"}}]
    }

    Application.put_env(:comma_web, :wechat_test_updates, %{
      "ret" => 0,
      "msgs" => [image, text],
      "get_updates_buf" => "after-image-and-text"
    })

    connect
  end

  defp reload_connect(connect) do
    {:ok, current} =
      ProviderConnects.get_active_connect_by_id(
        connect["group_id"],
        connect["connect_id"],
        "wechat"
      )

    current
  end

  defp expire_poll_lease(connect) do
    key = SalixStore.Keys.ctl_im_wechat_poll_lease(connect["connect_id"])

    assert {:ok, lease} =
             SalixStore.Lease.acquire(key, "test-takeover",
               now: System.system_time(:millisecond) + 60_000
             )

    :ok = SalixStore.Lease.release(lease)
  end

  defp assert_ordered_admissions do
    assert_receive {:router_input, _, image, _}
    assert image.trusted_origin["provider_context"]["event_id"] == "ordered-image"
    assert_receive {:router_input, _, text, _}
    assert text.trusted_origin["provider_context"]["event_id"] == "ordered-text"
  end

  defp assert_finished_pair(connect) do
    current = reload_connect(connect)
    assert current["updates_buf"] == "after-image-and-text"
    assert current["latest_context_token"] == "ctx-text"
    assert current["latest_context_message_id"] == "ordered-text"
    refute current["pending_wechat_poll"]
  end

  defp drain_dispatches(acc) do
    receive do
      {:router_dispatch, source} -> drain_dispatches([source | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp confirm(_c),
    do:
      Application.put_env(:comma_web, :wechat_test_response, %{
        "status" => "confirmed",
        "bot_token" => "private-test-token",
        "ilink_bot_id" => "bot-1",
        "ilink_user_id" => "alice"
      })

  defp poll(c, attempt),
    do:
      api(c.session, :post, path(c) <> "/connect/poll", %{"attempt_id" => attempt["connect_id"]})
      |> json(200)

  defp path(c), do: "/v1/comma/workspaces/#{c.workspace["id"]}/integrations/wechat"

  defp api(session, method, path, body \\ nil) do
    conn =
      if body,
        do:
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    conn
    |> put_req_header("authorization", "Bearer #{session["token"]}")
    |> CommaWeb.Router.call(CommaWeb.Router.init([]))
  end

  defp json(conn, status) do
    assert conn.status == status, conn.resp_body
    Jason.decode!(conn.resp_body)
  end
end
