defmodule CommaWeb.ChannelLinkToolsTest do
  @moduledoc """
  A Workspace owner connects a channel from the Router chat (`channel.link`,
  docs/architecture/DOMAIN_CONCEPTS.md): the Router gets what the user must
  do, the attempt completes where Settings › Channels would complete it, and
  the waiting call returns linked; an attempt that ends without connecting
  fails only its own call. Only the owner connects.
  """

  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]
  import Comma.WorkspaceTestSupport

  alias SalixAgent.{CapabilityRequests, CapabilityRequestStore}
  alias SalixAgent.Tools.ChannelLink
  alias SalixStore.Ids

  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  defmodule Provider do
    @moduledoc false
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      conn = fetch_query_params(conn)

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :channel_link_test_pid),
        {:provider, conn.request_path, conn.query_params}
      )

      response =
        case conn.request_path do
          "/ilink/bot/get_bot_qrcode" ->
            %{"qrcode" => "test-qr", "qrcode_img_content" => "https://weixin.qq.com/test-qr"}

          # A poll that carries the user's verification code is confirmed.
          "/ilink/bot/get_qrcode_status" ->
            if conn.query_params["verify_code"] == "246810",
              do: confirmed(),
              else: SystemsRuntime.fetch_env!(:comma_web, :channel_link_test_response)

          _other ->
            %{"ret" => 0, "msgs" => [], "get_updates_buf" => ""}
        end

      conn
      |> put_resp_content_type("application/octet-stream")
      |> send_resp(200, Jason.encode!(response))
    end

    def confirmed do
      %{
        "status" => "confirmed",
        "bot_token" => "private-test-token",
        "ilink_bot_id" => "bot-1",
        "ilink_user_id" => "alice"
      }
    end
  end

  setup_all do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)
    :ok
  end

  setup do
    # The WeChat watcher and its poll run in their own processes.
    owner = CommaWeb.TestRepoSandbox.start_owner!(:multi_connection)
    billing = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    keys = [
      {:salix_im, :wechat_api_base_url},
      {:salix_store, :s3_backend},
      {:comma_web, :channel_link_test_pid},
      {:comma_web, :channel_link_test_response}
    ]

    previous = for {app, key} <- keys, do: {app, key, SystemsRuntime.get_env(app, key)}

    on_exit(fn ->
      CommaWeb.TestRepoSandbox.stop_owner(owner)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing)

      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    port =
      SalixIM.TestSupport.BanditServer.start!(fn port -> {Bandit, plug: Provider, port: port} end)

    SystemsRuntime.put_env(:salix_im, :wechat_api_base_url, "http://127.0.0.1:#{port}")
    SystemsRuntime.put_env(:comma_web, :channel_link_test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:comma_web, :channel_link_test_response, %{"status" => "wait"})

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "channel-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    {:ok, other} =
      Comma.Accounts.create_user(%{
        "email" => "other-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace =
      user
      |> create_ready_workspace!(%{"name" => "Channel Test"})
      |> CommaWeb.TestWorkers.with_default_worker!()

    # The QR image is a workspace write, which the Workspace's credits meter.
    issue_billing_grant(workspace)

    %{user: user, other: other, workspace: workspace}
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
        source_id: "channel-link-test:#{workspace_id}",
        source_event_id: "channel-link-test:#{workspace_id}",
        idempotency_key: "channel-link-test:#{workspace_id}"
      })

    :ok
  end

  test "the owner connects WeChat from the chat: the QR image goes to the user and the scan ends the waiting call",
       c do
    ctx = tool_ctx(c, c.user, "call-wechat-1")

    assert {content, events} = ChannelLink.link(%{"provider" => "wechat"}, ctx)

    assert [%{"type" => "vfs_write"} = written, %{"type" => "async_tool_call_started"} | _] =
             events

    pending = Jason.decode!(content)
    assert pending["status"] == "pending"
    assert pending["tool_call_id"] == "call-wechat-1"
    assert pending["instructions"] =~ "image content block"
    # The QR code is an image in the Router's workspace, never the payload as text.
    assert "/channels/wechat-qr-" <> _ = pending["qr_image_path"]
    assert written["path"] == pending["qr_image_path"]
    assert <<@png_signature, _::binary>> = qr_bytes(c, written)
    refute Jason.encode!(pending) =~ "weixin.qq.com"
    refute Map.has_key?(pending, "user_id")

    {:ok, [request]} = CapabilityRequests.list_group(group(c), tenant(c), status: "pending")
    assert request["request_type"] == "channel_link"
    assert request["request_payload"]["channel_link"]["provider"] == "wechat"

    # The watcher polls the QR as the Settings page would. Unscanned, it polls again.
    settle_receive({:provider, "/ilink/bot/get_qrcode_status", _})
    settle_receive({:provider, "/ilink/bot/get_qrcode_status", _})
    SystemsRuntime.put_env(:comma_web, :channel_link_test_response, Provider.confirmed())

    ended = settle_until(fn -> finished(c, request["request_id"]) end)
    assert ended["status"] == "completed"

    assert ended["response_payload"] == %{
             "status" => "linked",
             "provider" => "wechat",
             "wechat_id" => "alice"
           }

    refute Jason.encode!(ended) =~ "private-test-token"

    {:ok, state} = CommaWeb.WeChatIntegration.state(c.user, %{}, c.workspace["id"])
    assert state["connection"]["connection_active"]

    settle_until(fn -> watchers() == 0 end)

    # Connected: a second call says so and starts nothing.
    assert %{"status" => "connected", "provider" => "wechat", "wechat_id" => "alice"} =
             ChannelLink.link(%{"provider" => "wechat"}, tool_ctx(c, c.user, "call-wechat-2"))
             |> Jason.decode!()

    assert {:ok, []} = CapabilityRequests.list_group(group(c), tenant(c), status: "pending")
  end

  test "WeChat's verification code goes through the Router: the call returns to ask, a second call brings the code",
       c do
    ctx = tool_ctx(c, c.user, "call-wechat-verify")
    assert {content, _events} = ChannelLink.link(%{"provider" => "wechat"}, ctx)
    %{"attempt_id" => attempt_id} = Jason.decode!(content)
    {:ok, [request]} = CapabilityRequests.list_group(group(c), tenant(c), status: "pending")

    SystemsRuntime.put_env(:comma_web, :channel_link_test_response, %{
      "status" => "need_verifycode"
    })

    asked = settle_until(fn -> finished(c, request["request_id"]) end)
    assert asked["status"] == "completed"

    assert asked["response_payload"] == %{
             "status" => "verification_code_required",
             "provider" => "wechat",
             "attempt_id" => attempt_id
           }

    settle_until(fn -> watchers() == 0 end)

    # A wrong code is refused, and the attempt stays open.
    assert {:tool_failure, _content, "verification_code_rejected", _, _, _} =
             ChannelLink.link(
               %{"provider" => "wechat", "attempt_id" => attempt_id, "verify_code" => "000000"},
               tool_ctx(c, c.user, "call-wechat-wrong-code")
             )

    # The code without its attempt is an argument error, not a WeChat call.
    assert {:tool_failure, _content, "invalid_arguments", _, _, _} =
             ChannelLink.link(
               %{"provider" => "wechat", "verify_code" => "246810"},
               tool_ctx(c, c.user, "call-wechat-no-attempt")
             )

    # The right code connects at once.
    assert %{"status" => "connected", "wechat_id" => "alice"} =
             ChannelLink.link(
               %{"provider" => "wechat", "attempt_id" => attempt_id, "verify_code" => "246810"},
               tool_ctx(c, c.user, "call-wechat-code")
             )
             |> Jason.decode!()

    assert_received {:provider, "/ilink/bot/get_qrcode_status", %{"verify_code" => "246810"}}
    {:ok, state} = CommaWeb.WeChatIntegration.state(c.user, %{}, c.workspace["id"])
    assert state["connection"]["connection_active"]
  end

  test "a WeChat attempt a newer attempt replaces fails only its own call; the newer one connects",
       c do
    first = tool_ctx(c, c.user, "call-wechat-first")
    assert {_content, _events} = ChannelLink.link(%{"provider" => "wechat"}, first)
    settle_receive({:provider, "/ilink/bot/get_qrcode_status", _})
    settle()

    {:ok, [first_request]} = CapabilityRequests.list_group(group(c), tenant(c), status: "pending")

    # The user asks again (another chat, a second QR): the first attempt is retired.
    second = tool_ctx(c, c.user, "call-wechat-second")
    assert {second_content, _events} = ChannelLink.link(%{"provider" => "wechat"}, second)
    %{"attempt_id" => second_attempt} = Jason.decode!(second_content)
    assert second_attempt != first_request["request_payload"]["channel_link"]["attempt_id"]

    first_ended = settle_until(fn -> finished(c, first_request["request_id"]) end)
    assert first_ended["status"] == "failed"
    assert first_ended["response_payload"]["reason"] == "invalid_wechat_connection_attempt"

    {:ok, [second_request]} =
      CapabilityRequests.list_group(group(c), tenant(c), status: "pending")

    assert second_request["request_payload"]["channel_link"]["attempt_id"] == second_attempt

    SystemsRuntime.put_env(:comma_web, :channel_link_test_response, Provider.confirmed())
    second_ended = settle_until(fn -> finished(c, second_request["request_id"]) end)
    assert second_ended["status"] == "completed"
    assert second_ended["response_payload"]["status"] == "linked"
    settle_until(fn -> watchers() == 0 end)
  end

  test "a WeChat attempt the user cancels in Settings ends the waiting call as failed", c do
    ctx = tool_ctx(c, c.user, "call-wechat-cancelled")
    assert {content, _events} = ChannelLink.link(%{"provider" => "wechat"}, ctx)
    %{"attempt_id" => attempt_id} = Jason.decode!(content)
    {:ok, [request]} = CapabilityRequests.list_group(group(c), tenant(c), status: "pending")

    settle_receive({:provider, "/ilink/bot/get_qrcode_status", _})
    # The poll has answered; the watcher waits for its next tick and holds no lock.
    settle()

    assert {:ok, %{"cancelled" => true}} =
             CommaWeb.WeChatIntegration.cancel_connect(c.user, %{}, c.workspace["id"], attempt_id)

    ended = settle_until(fn -> finished(c, request["request_id"]) end)
    assert ended["status"] == "failed"
    assert ended["response_payload"]["reason"] == "invalid_wechat_connection_attempt"
    assert ended["result"]["error_class"] == "channel_link_failed"
    settle_until(fn -> watchers() == 0 end)

    # The code for a cancelled attempt has nowhere to go.
    assert {:tool_failure, _content, "attempt_unknown", _, _, _} =
             ChannelLink.link(
               %{"provider" => "wechat", "attempt_id" => attempt_id, "verify_code" => "246810"},
               tool_ctx(c, c.user, "call-wechat-late-code")
             )
  end

  test "only the Workspace owner connects a channel", c do
    assert {:tool_failure, _content, "forbidden", _, _, _} =
             ChannelLink.link(%{"provider" => "wechat"}, tool_ctx(c, c.other, "call-other"))

    unknown = %{tool_ctx(c, c.user, "call-unknown") | trusted_origin: %{"provider" => "internal"}}

    assert {:tool_failure, _content, "requester_unknown", _, _, _} =
             ChannelLink.link(%{"provider" => "wechat"}, unknown)

    assert {:tool_failure, _content, "invalid_arguments", _, _, _} =
             ChannelLink.link(%{"provider" => "x"}, tool_ctx(c, c.user, "call-x"))

    assert {:ok, []} = CapabilityRequests.list_group(group(c), tenant(c), status: "pending")
    settle_refute_receive({:provider, _, _})
  end

  test "a Signal claim redeemed on the account ends the waiting call", c do
    request = waiting_request(c, "signal", "call-signal", 600)

    :ok =
      CommaWeb.ChannelLinkTools.signal_bound(%{
        "tenant_id" => tenant(c),
        "group_id" => group(c),
        "connect_id" => "con_signal",
        "binding" => %{"kind" => "user", "peer" => "aci-1", "display_name" => "Alice"}
      })

    {:ok, ended} = CapabilityRequests.get(group(c), request["request_id"], tenant(c))
    assert ended["status"] == "completed"

    assert ended["response_payload"] == %{
             "status" => "linked",
             "provider" => "signal",
             "peer" => "Alice"
           }

    # A binding with nothing waiting is nothing.
    :ok =
      CommaWeb.ChannelLinkTools.signal_bound(%{
        "tenant_id" => tenant(c),
        "group_id" => group(c),
        "binding" => %{"peer" => "aci-2"}
      })
  end

  test "an attempt the user never completes expires with its request", c do
    request = waiting_request(c, "telegram", "call-telegram", 600)

    assert {:error, :not_due} =
             CapabilityRequests.expire_location(group(c), request["request_id"], tenant(c))

    SystemsClock.advance(600_000)
    CapabilityRequests.expire_location(group(c), request["request_id"], tenant(c))

    {:ok, ended} = CapabilityRequests.get(group(c), request["request_id"], tenant(c))
    assert ended["status"] == "expired"
    assert ended["result"]["error_class"] == "channel_link_expired"
    assert ended["result"]["content"] =~ "telegram"
  end

  defp waiting_request(c, provider, tool_call_id, ttl_seconds) do
    {:ok, request} =
      CapabilityRequestStore.create_capability_request(%{
        "tenant_id" => tenant(c),
        "group_id" => group(c),
        "source_agent_id" => c.workspace["router_agent_id"],
        "source_session_id" => Ids.new_session_id(),
        "tool_call_id" => tool_call_id,
        "request_type" => "channel_link",
        "request_payload" => %{
          "channel_link" => %{
            "provider" => provider,
            "attempt_id" => "attempt-1",
            "tool_name" => "channel.link"
          }
        },
        "expires_at" => SystemsClock.system_time(:second) + ttl_seconds
      })

    request
  end

  defp finished(c, request_id) do
    case CapabilityRequests.get(group(c), request_id, tenant(c)) do
      {:ok, %{"status" => "pending"}} -> nil
      {:ok, request} -> request
    end
  end

  # The bytes a prepared workspace write carries, from the store it staged them in.
  defp qr_bytes(c, %{"ref" => ref}) do
    {:ok, bytes} = SalixStore.Blob.get(c.workspace["router_agent_id"], ref)
    bytes
  end

  defp watchers,
    do: SystemsRuntime.DynamicSupervisor.count_children(CommaWeb.ChannelLinkWatches).active

  defp tool_ctx(c, user, tool_call_id) do
    %{
      agent_id: c.workspace["router_agent_id"],
      session_id: Ids.new_session_id(),
      tool_call_id: tool_call_id,
      group_id: group(c),
      tenant_id: tenant(c),
      trusted_origin: %{
        "provider" => "internal",
        "principal_ref" => %{"namespace" => "comma_user", "subject_id" => user["id"]}
      }
    }
  end

  defp group(c), do: c.workspace["default_group_id"]
  defp tenant(c), do: c.workspace["salix_tenant_id"]
end
