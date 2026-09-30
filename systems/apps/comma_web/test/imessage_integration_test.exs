defmodule CommaWeb.IMessageIntegrationTest do
  use ExUnit.Case, async: false
  import Comma.WorkspaceTestSupport
  import Plug.Conn
  import Plug.Test

  alias Comma.IMessageLinks
  alias CommaWeb.IMessageIntegration
  alias SalixIM.{IMessageRelay, ProviderConnects}

  defmodule Relay do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      if get_req_header(conn, "authorization") == ["Bearer test-relay-secret"] do
        {:ok, body, conn} = read_body(conn)

        send(
          Application.fetch_env!(:comma_web, :imessage_test_pid),
          {:relay, conn.method, conn.request_path, body}
        )

        case conn.request_path do
          path when path in ["/v1/messages/text", "/v1/messages/image"] ->
            case Application.get_env(:comma_web, :imessage_test_send_response) do
              :timeout ->
                Process.sleep(16_000)
                send_resp(conn, 200, "{}")

              {status, response} ->
                conn |> put_resp_content_type("application/json") |> send_resp(status, response)

              nil ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(200, Jason.encode!(%{"message_id" => "sent-1"}))
            end

          "/v1/events/tail" ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, "{}")

          "/v1/events/stream" ->
            send(
              Application.fetch_env!(:comma_web, :imessage_test_pid),
              {:stream_query, conn.query_string}
            )

            if Application.get_env(:comma_web, :imessage_test_stream_truncated, false) do
              send_resp(conn, 200, ~s({"event_id":"1","type":"mess))
            else
              conn = conn |> put_resp_content_type("application/x-ndjson") |> send_chunked(200)

              Enum.reduce(
                Application.get_env(:comma_web, :imessage_test_events, []),
                conn,
                fn event, conn ->
                  {:ok, conn} = chunk(conn, Jason.encode!(event) <> "\n")
                  conn
                end
              )
            end

          "/v1/attachments/image-1/content" ->
            conn |> put_resp_content_type("image/png") |> send_resp(200, "test image bytes")

          "/v1/attachments/redirect/content" ->
            conn
            |> put_resp_header("location", "/v1/attachments/image-1/content")
            |> send_resp(302, "")

          _ ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              200,
              Jason.encode!(%{"message_id" => "sent-1", "latest_event_id" => "0"})
            )
        end
      else
        send_resp(conn, 401, "")
      end
    end
  end

  defmodule Workspace do
    def read_upload(_agent_id, path, _title),
      do: {:ok, %{path: path, filename: "result.png", data: "result image bytes"}}

    def put_ref(agent_id, path, ref) do
      send(
        Application.fetch_env!(:comma_web, :imessage_test_pid),
        {:published, agent_id, path, ref}
      )

      {:ok, %{path: path, size: ref.size}}
    end
  end

  defmodule Delivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent, payload, opts) do
      send(
        Application.fetch_env!(:comma_web, :imessage_test_pid),
        {:router_input, agent, payload, opts}
      )

      Application.get_env(:comma_web, :imessage_delivery_result, {:ok, :created})
    end
  end

  setup_all do
    unless Process.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)
    :ok
  end

  setup do
    comma_owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    previous =
      for {app, key} <- [
            {:salix_im, :imessage},
            {:salix_im, :agent_delivery_mod},
            {:salix_im, :agent_workspace_mod},
            {:comma_web, :imessage_test_events},
            {:comma_web, :imessage_test_stream_truncated},
            {:comma_web, :imessage_test_pid},
            {:comma_web, :imessage_test_send_response},
            {:comma_web, :imessage_delivery_result}
          ],
          do: {app, key, Application.get_env(app, key)}

    on_exit(fn ->
      CommaWeb.TestRepoSandbox.stop_owner(comma_owner)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)

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
      SalixIM.TestSupport.BanditServer.start!(fn port -> {Bandit, plug: Relay, port: port} end)

    Application.put_env(:salix_im, :imessage,
      enabled: true,
      relay_id: "test-relay",
      base_url: "http://127.0.0.1:#{port}",
      bearer_token: "test-relay-secret",
      shared_handle: "comma@example.test",
      shared_identity: "Comma"
    )

    Application.put_env(:salix_im, :agent_delivery_mod, Delivery)
    Application.put_env(:salix_im, :agent_workspace_mod, Workspace)
    Application.put_env(:comma_web, :imessage_test_pid, self())

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "imessage-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user, %{"name" => "iMessage Test"})
    {:ok, session} = Comma.Accounts.create_session(user["id"])
    %{user: user, workspace: workspace, session: session}
  end

  test "account settings -> one-time private claim -> Router -> exact chat reply -> disconnect",
       context do
    %{workspace: workspace, session: session} = context
    path = path(workspace)
    state = api(session, :get, path) |> json(200)
    assert state["configured"] and state["link"] == nil
    claim = api(session, :post, path <> "/connect", %{}) |> json(201)

    assert :ok =
             IMessageIntegration.handle_event(event("1", "bridgebot connect #{claim["code"]}"))

    assert_receive {:relay, "POST", "/v1/messages/text", confirmation}
    assert Jason.decode!(confirmation)["text"] =~ "connected"

    state = api(session, :get, path) |> json(200)
    assert state["connection_active"]
    assert state["link"]["sender_handle"] == "alice@example.test"
    refute state["pending_claim"]
    refute Jason.encode!(state) =~ "test-relay-secret"

    {:ok, connect} =
      ProviderConnects.get_active_connect_by_id(
        workspace["default_group_id"],
        state["link"]["connection_id"],
        "imessage"
      )

    assert :ok = IMessageIntegration.handle_event(event("2", "hello Comma"))
    assert_receive {:router_input, router, payload, opts}
    assert router == workspace["router_agent_id"]
    assert inspect(payload) =~ "hello Comma"
    assert inspect(payload) =~ "imessage"
    assert opts[:source_message_id] =~ "msg-2"
    assert payload.trusted_origin["provider"] == "imessage"
    assert payload.trusted_origin["source_actor_type"] == "provider_user"
    assert payload.trusted_origin["provider_context"]["chat_id"] == "chat-alice"

    foreign_chat =
      put_in(event("3", "not the bound chat"), ["message", "chat_guid"], "different-chat")

    assert :ok = IMessageIntegration.handle_event(foreign_chat)
    assert_receive {:relay, "POST", "/v1/messages/text", repair}
    assert Jason.decode!(repair)["text"] =~ "Reconnect"
    refute_receive {:router_input, _, _, _}
    assert :ok = IMessageIntegration.handle_event(event("2", "hello Comma"))
    refute_receive {:router_input, ^router, _payload, _opts}, 100

    assert {:ok, %{"message_id" => "sent-1"}} =
             SalixIM.Provider.call_api(router, "imessage", "imessage.send_message", %{
               "connect_id" => connect["connect_id"],
               "params" => %{"chat_id" => "chat-alice", "text" => "Hello Alice"}
             })

    assert_receive {:relay, "POST", "/v1/messages/text", body}

    assert Jason.decode!(body) == %{
             "sender_handle" => "alice@example.test",
             "chat_guid" => "chat-alice",
             "text" => "Hello Alice"
           }

    api(session, :delete, path, %{}) |> json(200)

    assert {:error, _} =
             SalixIM.Provider.call_api(router, "imessage", "imessage.send_message", %{
               "connect_id" => connect["connect_id"],
               "params" => %{"chat_id" => "chat-alice", "text" => "late reply"}
             })

    refute_receive {:relay, "POST", "/v1/messages/text", _}

    assert {:error, :not_found} =
             ProviderConnects.activate_managed_imessage_im_connect(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               connect["connect_id"]
             )
  end

  test "dispatched sends with lost or unusable replies report unknown without HTTP retry", %{
    workspace: workspace,
    session: session
  } do
    claim = api(session, :post, path(workspace) <> "/connect", %{}) |> json(201)

    assert :ok =
             IMessageIntegration.handle_event(event("1", "bridgebot connect #{claim["code"]}"))

    assert_receive {:relay, "POST", "/v1/messages/text", _}
    state = api(session, :get, path(workspace)) |> json(200)

    # The relay has received the send before returning an error or losing its
    # reply. It may already have sent to Apple; only its response is uncertain.
    for response <- [{502, "upstream timed out"}, {200, "{}"}],
        {api_name, params, endpoint} <- [
          {"imessage.send_message", %{"text" => "hello"}, "/v1/messages/text"},
          {"imessage.send_image", %{"path" => "/result.png"}, "/v1/messages/image"}
        ] do
      Application.put_env(:comma_web, :imessage_test_send_response, response)

      assert {:error,
              %{
                "code" => "imessage_delivery_unknown",
                "delivery_status" => "unknown",
                "retryable" => false
              } = error} =
               SalixIM.Provider.call_api(workspace["router_agent_id"], "imessage", api_name, %{
                 "connect_id" => state["link"]["connection_id"],
                 "params" => Map.put(params, "chat_id", "chat-alice")
               })

      refute Map.has_key?(error, "message_id")
      assert_receive {:relay, "POST", ^endpoint, _}
      refute_receive {:relay, "POST", _, _}, 100
    end

    Application.put_env(:comma_web, :imessage_test_send_response, :timeout)

    assert {:error, %{"code" => "imessage_delivery_unknown", "retryable" => false}} =
             IMessageRelay.send_text("alice@example.test", "chat-alice", "delayed reply")

    assert_receive {:relay, "POST", "/v1/messages/text", _}
    refute_receive {:relay, "POST", _, _}, 100

    Application.put_env(:salix_im, :imessage, enabled: false)
    assert {:error, :imessage_unavailable} = IMessageRelay.send_text("alice", "chat", "hello")
    refute_receive {:relay, "POST", _, _}, 100
  end

  test "groups cannot consume claims; replacement and cancellation invalidate old attempts", %{
    user: user,
    workspace: workspace
  } do
    {:ok, first} = IMessageIntegration.start_connect(user, %{}, workspace["id"])

    group =
      put_in(event("1", "bridgebot connect #{first["code"]}"), ["message", "is_group"], true)

    assert :ok = IMessageIntegration.handle_event(group)
    assert :ok = IMessageIntegration.handle_event(put_in(group, ["message", "is_group"], nil))
    refute_receive {:relay, _, _, _}
    assert IMessageLinks.get_active_claim(workspace["id"])

    {:ok, second} = IMessageIntegration.start_connect(user, %{}, workspace["id"])
    assert {:error, :invalid_imessage_claim} = IMessageLinks.take_claim(first["code"])

    assert {:ok, :ok} =
             IMessageIntegration.cancel_connect(user, %{}, workspace["id"], %{
               "code" => first["code"]
             })

    assert IMessageLinks.get_active_claim(workspace["id"]).code == second["code"]
    assert {:ok, _} = IMessageIntegration.disconnect(user, %{}, workspace["id"])
    assert {:error, :invalid_imessage_claim} = IMessageLinks.take_claim(second["code"])
  end

  test "expired claims and another account cannot publish or read a binding", %{
    user: user,
    workspace: workspace,
    session: session
  } do
    {:ok, _, claim} = IMessageLinks.create_claim(user, %{}, workspace["id"])

    claim
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Comma.Repo.update!()

    assert {:error, :invalid_imessage_claim} = IMessageLinks.take_claim(claim.code)

    {:ok, stranger} =
      Comma.Accounts.create_user(%{
        "email" => "other-#{System.unique_integer([:positive])}@comma.test"
      })

    {:ok, stranger_session} = Comma.Accounts.create_session(stranger["id"])
    assert api(stranger_session, :get, path(workspace)).status == 403
    assert api(stranger_session, :post, path(workspace) <> "/connect", %{}).status == 403
    assert api(stranger_session, :delete, path(workspace), %{}).status == 403
    assert api(session, :get, path(workspace)).status == 200
  end

  test "bound route rejects a different chat, changed relay identity and generic activation",
       context do
    %{workspace: workspace, user: user} = context
    {:ok, claim} = IMessageIntegration.start_connect(user, %{}, workspace["id"])

    assert :ok =
             IMessageIntegration.handle_event(event("1", "bridgebot connect #{claim["code"]}"))

    assert_receive {:relay, _, _, _}
    link = IMessageLinks.get_link(workspace["id"])

    {:ok, connect} =
      ProviderConnects.get_active_connect_by_id(
        workspace["default_group_id"],
        link.connect_id,
        "imessage"
      )

    assert {:error, _} =
             SalixIM.Provider.IMessage.call("agent", connect, "imessage.send_message", %{
               "chat_id" => "someone-else",
               "text" => "private"
             })

    assert {:error, _} =
             ProviderConnects.enable_im_connect(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               link.connect_id
             )

    Application.put_env(
      :salix_im,
      :imessage,
      Keyword.put(IMessageRelay.config(), :relay_id, "different-relay")
    )

    assert {:error, _} =
             SalixIM.Provider.IMessage.call("agent", connect, "imessage.send_message", %{
               "chat_id" => "chat-alice",
               "text" => "private"
             })

    refute_receive {:relay, _, _, _}
  end

  test "failed Router admission is retryable and does not checkpoint the event", %{
    workspace: workspace,
    user: user
  } do
    {:ok, claim} = IMessageIntegration.start_connect(user, %{}, workspace["id"])

    assert :ok =
             IMessageIntegration.handle_event(event("1", "bridgebot connect #{claim["code"]}"))

    Comma.Repo.query!(
      "INSERT INTO comma_imessage_relay_cursors (relay_id, event_id, inserted_at, updated_at) VALUES ('test-relay', '1', now(), now())"
    )

    block_router_log(workspace)
    assert {:error, _} = CommaWeb.IMessageRuntime.handle_and_checkpoint(event("2", "retry me"))

    assert Comma.Repo.query!(
             "SELECT event_id FROM comma_imessage_relay_cursors WHERE relay_id = 'test-relay'"
           ).rows == [["1"]]

    SalixStore.S3.Fake.clear_blackhole()
    assert :ok = CommaWeb.IMessageRuntime.handle_and_checkpoint(event("2", "retry me"))

    assert Comma.Repo.query!(
             "SELECT event_id FROM comma_imessage_relay_cursors WHERE relay_id = 'test-relay'"
           ).rows == [["2"]]
  end

  test "HTTP receiver seeds tail, resumes, and stops before a failed admission", %{
    workspace: workspace,
    user: user
  } do
    {:ok, claim} = IMessageIntegration.start_connect(user, %{}, workspace["id"])

    Application.put_env(:comma_web, :imessage_test_events, [
      event("1", "bridgebot connect #{claim["code"]}")
    ])

    assert :ok = CommaWeb.IMessageRuntime.run_once()
    assert_receive {:relay, "GET", "/v1/events/tail", _}
    assert_receive {:stream_query, "after_event_id="}
    assert IMessageLinks.get_link(workspace["id"])

    Application.put_env(:comma_web, :imessage_test_events, [
      event("2", "retry me"),
      event("3", "later")
    ])

    block_router_log(workspace)
    assert {:error, _} = CommaWeb.IMessageRuntime.run_once()
    assert_receive {:stream_query, "after_event_id=1"}
    refute_receive {:router_input, _, _, _}
    assert cursor() == "1"

    SalixStore.S3.Fake.clear_blackhole()
    assert :ok = CommaWeb.IMessageRuntime.run_once()
    assert_receive {:stream_query, "after_event_id=1"}
    assert cursor() == "3"
    assert CommaWeb.IMessageRuntime.online?()
  end

  test "three truncated owning passes pause despite standby and restart resumes the saved cursor" do
    Application.put_env(:comma_web, :imessage_test_stream_truncated, true)
    start_supervised!(CommaWeb.IMessageRuntime)

    assert_receive {:stream_query, "after_event_id="}, 6_000

    contender =
      start_supervised!(
        {Postgrex,
         Keyword.take(Comma.Repo.config(), [:hostname, :port, :database, :username, :password])}
      )

    Postgrex.query!(contender, "SELECT pg_advisory_lock(4412741, 21577)", [])
    refute_receive {:stream_query, _}, 5_500
    Postgrex.query!(contender, "SELECT pg_advisory_unlock(4412741, 21577)", [])

    for _ <- 1..2 do
      assert_receive {:stream_query, "after_event_id="}, 6_000
    end

    refute_receive {:stream_query, _}, 5_500
    assert cursor() == ""
    refute CommaWeb.IMessageRuntime.online?()

    stop_supervised(CommaWeb.IMessageRuntime)
    Application.put_env(:comma_web, :imessage_test_stream_truncated, false)
    start_supervised!(CommaWeb.IMessageRuntime)
    assert_receive {:stream_query, "after_event_id="}, 6_000
  end

  test "inbound image bytes reach VFS and image replies retain the bound private destination", %{
    workspace: workspace,
    user: user
  } do
    {:ok, claim} = IMessageIntegration.start_connect(user, %{}, workspace["id"])

    assert :ok =
             IMessageIntegration.handle_event(event("1", "bridgebot connect #{claim["code"]}"))

    image_event =
      put_in(event("2", "look at this"), ["message", "attachments"], [
        %{
          "attachment_id" => "image-1",
          "name" => "../photo.png",
          "content_type" => "image/png",
          "size" => 16
        }
      ])

    assert :ok = IMessageIntegration.handle_event(image_event)
    assert_receive {:published, agent, path, ref}
    assert agent == workspace["router_agent_id"]
    assert path =~ "/imessage/attachments/"
    assert path =~ "photo.png"
    refute path =~ ".."
    assert {:ok, "test image bytes"} = SalixStore.Blob.get(agent, ref)
    assert_receive {:router_input, ^agent, payload, _}
    assert inspect(payload) =~ path
    refute inspect(payload) =~ "test-relay-secret"

    link = IMessageLinks.get_link(workspace["id"])

    assert {:ok, %{"message_id" => "sent-1"}} =
             SalixIM.Provider.call_api(agent, "imessage", "imessage.send_image", %{
               "connect_id" => link.connect_id,
               "params" => %{
                 "chat_id" => "chat-alice",
                 "path" => "/result.png",
                 "caption" => "result"
               }
             })

    assert_receive {:relay, "POST", "/v1/messages/image", body}
    assert body =~ "alice@example.test"
    assert body =~ "chat-alice"
    assert body =~ "result image bytes"
    assert body =~ "result.png"

    assert {:error, :imessage_image_unavailable} = IMessageRelay.download_image(agent, "redirect")

    assert {:error, :imessage_image_too_large} =
             IMessageRelay.send_image("alice", "chat-alice", %{
               data: :binary.copy("x", 20 * 1024 * 1024 + 1),
               filename: "large.png"
             })

    refute_receive {:relay, "POST", "/v1/messages/image", _}
  end

  defp block_router_log(workspace) do
    group = workspace["default_group_id"]
    {:ok, conversation} = SalixIM.RouterConversationInput.ensure(group)
    key = SalixStore.Keys.ctl_group_conversation(group, conversation["conversation_id"])
    :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :put, key})
    on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)
  end

  defp cursor do
    [[id]] =
      Comma.Repo.query!(
        "SELECT event_id FROM comma_imessage_relay_cursors WHERE relay_id = 'test-relay'"
      ).rows

    id
  end

  defp event(id, text),
    do: %{
      "event_id" => id,
      "type" => "message",
      "message" => %{
        "message_id" => "msg-#{id}",
        "sender_handle" => "alice@example.test",
        "sender_display_name" => "Alice",
        "chat_guid" => "chat-alice",
        "text" => text
      }
    }

  defp path(workspace), do: "/v1/comma/workspaces/#{workspace["id"]}/integrations/imessage"

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
