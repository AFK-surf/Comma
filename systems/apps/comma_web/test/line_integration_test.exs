defmodule CommaWeb.LineIntegrationTest do
  @moduledoc """
  Comma product LINE: Settings starts a claim, the person sends `link <code>`
  to Comma's LINE account, and the binding then carries their private
  messages and group mentions to the Workspace's Router.
  """
  use SystemsClock.Case, async: false
  import Comma.WorkspaceTestSupport
  import Plug.Conn
  import Plug.Test

  alias SalixIM.ProviderConnects

  @secret "4c9e1f0a7b3d2e6f8a1c5b9d0e2f4a6b"
  @token "comma-line-channel-access-token"
  @alice "U1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"
  @bob "U9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c"
  @group "Cb1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6"

  defmodule API do
    @moduledoc "A recording stub of the LINE Messaging API."
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :line_test_pid),
        {:line_api, conn.method, conn.request_path, body}
      )

      {status, answer} =
        case {conn.method, conn.path_info} do
          {"GET", ["v2", "bot", "info"]} ->
            {200,
             %{
               "userId" => "Ubot0123456789abcdef0123456789ab",
               "basicId" => "@comma",
               "displayName" => "Comma"
             }}

          {"GET", ["v2", "bot", "profile", _user]} ->
            {200, %{"displayName" => "Alice"}}

          {"POST", ["v2", "bot", "message", _kind]} ->
            {200, %{"sentMessages" => [%{"id" => "1"}]}}

          _other ->
            {404, %{"message" => "Not found"}}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(answer))
    end
  end

  defmodule Delivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent, payload, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :line_test_pid),
        {:router_input, agent, payload, opts}
      )

      {:ok, :created}
    end
  end

  setup_all do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)
    :ok
  end

  setup do
    comma_owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    previous =
      for {app, key} <- [
            {:comma_web, :line},
            {:comma_web, :line_test_pid},
            {:salix_im, :line_api_base_url},
            {:salix_im, :agent_delivery_mod}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    on_exit(fn ->
      CommaWeb.TestRepoSandbox.stop_owner(comma_owner)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)

      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    SystemsRuntime.put_env(
      :salix_im,
      :line_api_base_url,
      SalixIM.TestSupport.BanditServer.serve!(API)
    )

    SystemsRuntime.put_env(:comma_web, :line,
      enabled: true,
      channel_secret: @secret,
      channel_access_token: @token,
      basic_id: "@comma"
    )

    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, Delivery)
    SystemsRuntime.put_env(:comma_web, :line_test_pid, SystemsRuntime.Proc.self())

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "line-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user, %{"name" => "LINE Test"})
    {:ok, session} = Comma.Accounts.create_session(user["id"])
    %{user: user, workspace: workspace, session: session}
  end

  test "settings claim -> link message -> private chat and group mention reach the Router -> disconnect",
       %{workspace: workspace, session: session} do
    path = path(workspace)
    state = api(session, :get, path) |> json(200)
    assert state["configured"] and state["link"] == nil
    assert state["add_friend_url"] == "https://line.me/R/ti/p/%40comma"

    claim = api(session, :post, path <> "/connect", %{}) |> json(201)
    assert claim["message_url"] == "https://line.me/R/oaMessage/%40comma/?link%20" <> claim["code"]
    assert (api(session, :get, path) |> json(200))["pending_claim"]["code"] == claim["code"]

    # Someone without the code gets the guide, not the Router.
    assert :ok = webhook([text_event("m0", "hello", private(@bob))])
    assert_received {:line_api, "POST", "/v2/bot/message/reply", %{"messages" => [guide]}}
    assert guide["text"] =~ "Settings › Channels › LINE"

    assert :ok = webhook([text_event("m1", "link #{claim["code"]}", private(@alice))])

    assert_received {:line_api, "POST", "/v2/bot/message/reply",
                     %{"replyToken" => "reply-m1", "messages" => [confirmation]}}

    assert confirmation["text"] =~ "LINE Test"

    state = api(session, :get, path) |> json(200)
    assert state["connection_active"]

    assert %{"line_user_id" => @alice, "line_display_name" => "Alice"} = state["link"]
    refute state["pending_claim"]
    refute Jason.encode!(state) =~ @secret
    refute Jason.encode!(state) =~ @token

    # The used code connects nothing again.
    assert :ok = webhook([text_event("m2", "link #{claim["code"]}", private(@bob))])
    assert_received {:line_api, "POST", "/v2/bot/message/reply", %{"messages" => [failed]}}
    assert failed["text"] =~ "Could not connect LINE"

    group_id = workspace["default_group_id"]
    connect_id = state["link"]["connection_id"]
    assert :ok = webhook([text_event("m3", "營業時間是幾點？", private(@alice))])
    assert [message] = router_inputs(group_id, "im_provider:line:#{connect_id}:m3")
    origin = message["agent_input"][:trusted_origin]
    assert origin["provider"] == "line"
    assert origin["provider_context"]["chat_id"] == "user:" <> @alice

    mention =
      text_event("m4", "@Comma 幫我整理", %{"type" => "group", "groupId" => @group, "userId" => @alice})
      |> put_in(["message", "mention"], %{"mentionees" => [%{"type" => "user", "isSelf" => true}]})

    bob_mention =
      put_in(mention, ["source", "userId"], @bob) |> put_in(["message", "id"], "m5")

    assert :ok = webhook([mention, bob_mention])
    assert [group_message] = router_inputs(group_id, "im_provider:line:#{connect_id}:m4")

    assert group_message["agent_input"][:trusted_origin]["provider_context"]["chat_id"] ==
             "group:" <> @group

    assert router_inputs(group_id, "im_provider:line:#{connect_id}:m5") == []
    # A stranger's group mention gets no reply either.
    refute_received {:line_api, "POST", "/v2/bot/message/reply", _body}

    api(session, :delete, path, %{}) |> json(200)

    assert {:error, :not_found} =
             ProviderConnects.get_active_connect_by_id(group_id, connect_id, "line")

    assert :ok = webhook([text_event("m6", "still there?", private(@alice))])
    assert router_inputs(group_id, "im_provider:line:#{connect_id}:m6") == []
    assert_received {:line_api, "POST", "/v2/bot/message/reply", %{"messages" => [guide]}}
    assert guide["text"] =~ "Settings › Channels › LINE"
  end

  test "a request without the channel's signature is refused" do
    body = Jason.encode!(%{"destination" => "Ubot", "events" => []})

    conn =
      conn(:post, "/v1/comma/integrations/line/webhook", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-line-signature", "forged")
      |> CommaWeb.Router.call(CommaWeb.Router.init([]))

    assert conn.status == 401

    # LINE's webhook check: no events, signed.
    assert :ok = webhook([])
  end

  test "settings answer unavailable when LINE is not configured", %{
    workspace: workspace,
    session: session
  } do
    SystemsRuntime.put_env(:comma_web, :line, enabled: false)
    assert %{"configured" => false} = api(session, :get, path(workspace)) |> json(200)
    api(session, :post, path(workspace) <> "/connect", %{}) |> json(503)
  end

  defp webhook(events) do
    body = Jason.encode!(%{"destination" => "Ubot0123456789abcdef0123456789ab", "events" => events})
    signature = :hmac |> :crypto.mac(:sha256, @secret, body) |> Base.encode64()

    conn =
      conn(:post, "/v1/comma/integrations/line/webhook", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-line-signature", signature)
      |> CommaWeb.Router.call(CommaWeb.Router.init([]))

    if conn.status == 200, do: :ok, else: {:error, conn.status, conn.resp_body}
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

  defp private(user_id), do: %{"type" => "user", "userId" => user_id}

  defp text_event(id, text, source) do
    %{
      "type" => "message",
      "mode" => "active",
      "timestamp" => SystemsClock.system_time(:millisecond),
      "webhookEventId" => "01H" <> id,
      "replyToken" => "reply-" <> id,
      "source" => source,
      "message" => %{"type" => "text", "id" => id, "text" => text}
    }
  end

  defp path(workspace), do: "/v1/comma/workspaces/#{workspace["id"]}/integrations/line"

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
