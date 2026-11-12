defmodule CommaWeb.IMessagePhotonTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]
  import Comma.WorkspaceTestSupport
  import Plug.Conn
  import Plug.Test

  alias Comma.IMessageLinks
  alias CommaWeb.{IMessageIntegration, IMessagePhotonRuntime}
  alias SalixIM.PhotonIMessage

  @webhook_secret "whsec_" <> Base.encode64("photon webhook test secret")
  @webhook_id "evt-photon-test"
  @project "pho_prj_00000000000000000000000001"
  @alice "+15550100"
  @line "+15559990000"
  @alice_user "pho_usr_0000000000000000000000alice"
  @agent_user "pho_usr_0000000000000000000000agent"
  @space "pho_spc_000000000000000000000000001"

  # Scripted Photon REST API. Paths are relative to /v1/projects/<project>.
  defmodule Photon do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      prefix = "/v1/projects/pho_prj_00000000000000000000000001"

      if get_req_header(conn, "authorization") == ["Bearer pho_sk_test"] do
        {:ok, body, conn} = read_body(conn)
        conn = conn |> fetch_query_params() |> assign(:request_body, body)
        path = String.replace_prefix(conn.request_path, prefix, "")
        notify({:photon, conn.method, path, body, get_req_header(conn, "idempotency-key")})
        respond(conn, conn.method, path)
      else
        send_resp(conn, 401, "")
      end
    end

    defp respond(conn, "GET", "/platforms/imessage"),
      do: json(conn, 200, %{"mode" => setting(:photon_test_mode, "shared")})

    defp respond(conn, "GET", "/platforms/resources") do
      notify({:photon_resources, conn.query_params})
      json(conn, 200, %{"resources" => setting(:photon_test_resources, [])})
    end

    defp respond(conn, "POST", "/users"),
      do: json(conn, 200, %{"id" => "pho_usr_0000000000000000000000alice"})

    defp respond(conn, "POST", "/platforms/imessage/assignments") do
      if setting(:photon_test_assignments, []) == [] do
        json(conn, 201, %{
          "assignmentId" => "asg-1",
          "assignedPhoneNumber" => "+15559990000",
          "handle" => "+15550100",
          "platform" => "imessage"
        })
      else
        json(conn, 409, %{"code" => "ASSIGNMENT_EXISTS"})
      end
    end

    defp respond(conn, "GET", "/platforms/imessage/assignments"),
      do: json(conn, 200, %{"assignments" => setting(:photon_test_assignments, [])})

    defp respond(conn, "DELETE", "/platforms/imessage/assignments/" <> _id),
      do: json(conn, 200, %{"assignmentId" => "asg-1"})

    defp respond(conn, "GET", "/messages") do
      notify({:photon_list, conn.query_params})

      case setting(:photon_test_list_status, 200) do
        200 -> json(conn, 200, %{"items" => setting(:photon_test_received, [])})
        status -> json(conn, status, %{"code" => "UPSTREAM_FAILURE"})
      end
    end

    # Messages a reply, a reaction or a quote can name.
    defp respond(conn, "GET", "/messages/" <> id) do
      space = "pho_spc_000000000000000000000000001"
      agent = "pho_usr_0000000000000000000000agent"
      alice = "pho_usr_0000000000000000000000alice"

      case id do
        "pho_msg_parent" ->
          json(conn, 200, %{
            "id" => id,
            "space" => %{"id" => space},
            "sentBy" => %{"id" => agent},
            "content" => %{"type" => "text", "text" => "Which plan do you want?"}
          })

        "pho_msg_mine" ->
          json(conn, 200, %{
            "id" => id,
            "space" => %{"id" => space},
            "sentBy" => %{"id" => alice},
            "content" => %{"type" => "text", "text" => "the blue one"}
          })

        "pho_msg_elsewhere" ->
          json(conn, 200, %{"id" => id, "space" => %{"id" => "pho_spc_other"}})

        _ ->
          json(conn, 404, %{"code" => "MESSAGE_NOT_FOUND"})
      end
    end

    defp respond(conn, "POST", "/messages") do
      response =
        case setting(:photon_test_send_response, nil) do
          %{with_parent: parent, without_parent: plain} ->
            if Map.has_key?(Jason.decode!(conn.assigns.request_body), "parentMessageId"),
              do: parent,
              else: plain

          response ->
            response
        end

      case response do
        :reject_caption ->
          if get_in(Jason.decode!(conn.assigns.request_body), ["content", "type"]) == "text",
            do: json(conn, 403, %{"code" => "SENDER_NOT_SENDABLE"}),
            else: json(conn, 202, %{"id" => "pho_msg_sent", "status" => "dispatched"})

        {status, body} ->
          json(conn, status, body)

        nil ->
          json(conn, 202, %{"id" => "pho_msg_sent", "status" => "dispatched"})
      end
    end

    defp respond(conn, "POST", "/attachments") do
      [content_type] = get_req_header(conn, "content-type")

      case Plug.Conn.Utils.media_type(content_type) do
        {:ok, "multipart", "related", %{"boundary" => _} = params} when map_size(params) == 1 ->
          json(conn, 201, %{"id" => "att-out", "contentType" => "image/png"})

        _ ->
          json(conn, 400, %{"code" => "INVALID_ATTACHMENT_REQUEST"})
      end
    end

    # Received attachments: content type, file name, declared size and bytes.
    @attachments %{
      "att-in" => {"image/png", "../in.png", 16, "test image bytes"},
      "att-video" => {"video/quicktime", "IMG_0001.MOV", 16, "test video bytes"},
      "att-voice" => {"audio/x-caf", nil, 16, "test voice bytes"},
      "att-big" => {"video/mp4", "long.mp4", 100 * 1024 * 1024 + 1, nil}
    }

    defp respond(conn, "GET", "/attachments/" <> rest) do
      case String.split(rest, "/") do
        [id] when is_map_key(@attachments, id) ->
          {type, name, size, _bytes} = @attachments[id]

          json(
            conn,
            200,
            %{"contentType" => type, "filename" => name, "sizeBytes" => size}
            |> Map.reject(fn {_key, value} -> is_nil(value) end)
          )

        [id, "content"] when is_map_key(@attachments, id) ->
          {type, _name, _size, bytes} = @attachments[id]
          conn |> put_resp_content_type(type) |> send_resp(200, bytes)

        _ ->
          json(conn, 404, %{"code" => "ATTACHMENT_NOT_FOUND"})
      end
    end

    defp respond(conn, _method, _path), do: json(conn, 404, %{"code" => "NOT_FOUND"})

    defp json(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end

    defp setting(key, default), do: SystemsRuntime.get_env(:comma_web, key, default)

    defp notify(message),
      do:
        SystemsRuntime.Proc.send(SystemsRuntime.fetch_env!(:comma_web, :photon_test_pid), message)
  end

  defmodule Workspace do
    def read_upload(_agent_id, path, _title),
      do: {:ok, %{path: path, filename: "result.png", data: "result image bytes"}}

    # The size comes before the bytes. Reading an oversized file is a test failure.
    def read_stream(_agent_id, "/huge.mp4") do
      stream =
        Stream.map([nil], fn _ ->
          SystemsRuntime.Proc.send(
            SystemsRuntime.fetch_env!(:comma_web, :photon_test_pid),
            :huge_file_read
          )

          ""
        end)

      {:ok, stream, 100 * 1024 * 1024 + 1, "huge.mp4"}
    end

    def read_stream(_agent_id, "/clip.mp4"),
      do: {:ok, ["video ", "bytes"], 11, "clip.mp4"}

    def put_ref(agent_id, path, ref) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :photon_test_pid),
        {:published, agent_id, path, ref}
      )

      {:ok, %{path: path, size: ref.size}}
    end
  end

  defmodule Delivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent, payload, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_web, :photon_test_pid),
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
            {:salix_im, :imessage},
            {:salix_im, :imessage_photon},
            {:salix_im, :agent_delivery_mod},
            {:salix_im, :agent_workspace_mod},
            {:comma_web, :photon_test_pid},
            {:comma_web, :photon_test_received},
            {:comma_web, :photon_test_assignments},
            {:comma_web, :photon_test_mode},
            {:comma_web, :photon_test_resources},
            {:comma_web, :photon_test_send_response}
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

    port =
      SalixIM.TestSupport.BanditServer.start!(fn port -> {Bandit, plug: Photon, port: port} end)

    SystemsRuntime.put_env(:salix_im, :imessage, enabled: false)

    SystemsRuntime.put_env(:salix_im, :imessage_photon,
      enabled: true,
      project_id: @project,
      api_key: "pho_sk_test",
      webhook_secret: @webhook_secret,
      base_url: "http://127.0.0.1:#{port}"
    )

    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, Delivery)
    SystemsRuntime.put_env(:salix_im, :agent_workspace_mod, Workspace)
    SystemsRuntime.put_env(:comma_web, :photon_test_pid, SystemsRuntime.Proc.self())

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "photon-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    workspace = create_ready_workspace!(user, %{"name" => "Photon Test"})
    {:ok, session} = Comma.Accounts.create_session(user["id"])
    %{user: user, workspace: workspace, session: session}
  end

  test "phone attempt -> reply from that phone binds -> Router -> bound-space reply -> disconnect",
       %{workspace: workspace, session: session} do
    path = path(workspace)
    assert api(session, :post, path <> "/connect", %{"handle" => "not a phone"}).status == 400

    attempt = api(session, :post, path <> "/connect", %{"handle" => "+1 555-0100"}) |> json(201)
    assert attempt["transport"] == "photon"
    assert attempt["sender_handle"] == @alice
    assert attempt["line_handle"] == @line
    settle_receive({:photon, "POST", "/users", users, _})
    assert Jason.decode!(users) == %{"platform" => "imessage", "handle" => @alice}
    settle_receive({:photon, "POST", "/platforms/imessage/assignments", assign, [_key]})
    assert Jason.decode!(assign) == %{"handle" => @alice}

    state = api(session, :get, path) |> json(200)
    assert state["photon_configured"] and state["pending_claim"]["line_handle"] == @line
    refute Jason.encode!(state) =~ "pho_sk_test"

    # Before confirmation, the phone's messages do not reach the Agent.
    assert :ok = IMessageIntegration.handle_event(event("m1", @alice, "hello?"))
    settle_receive({:photon, "POST", "/messages", hint, _})
    assert Jason.decode!(hint)["content"]["text"] =~ "Connect iMessage"
    settle_refute_receive({:router_input, _, _, _})

    # Another handle cannot use the code, and the attempt stays open.
    assert :ok = IMessageIntegration.handle_event(event("m2", "+15550199", attempt["code"]))
    settle_receive({:photon, "POST", "/messages", _, _})
    refute IMessageLinks.get_link(workspace["id"])

    assert :ok = IMessageIntegration.handle_event(event("m3", @alice, attempt["code"]))
    settle_receive({:photon, "POST", "/messages", confirmation, [_key]})

    assert %{
             "spaceId" => @space,
             "senderId" => @agent_user,
             "content" => %{"type" => "text", "format" => "plain", "text" => text}
           } = Jason.decode!(confirmation)

    assert text =~ "connected"

    state = api(session, :get, path) |> json(200)
    assert state["connection_active"]
    assert state["link"]["transport"] == "photon"
    assert state["link"]["sender_handle"] == @alice
    refute state["pending_claim"]

    assert :ok = IMessageIntegration.handle_event(event("m4", @alice, "hello Comma"))
    settle_receive({:router_input, router, payload, opts})
    assert router == workspace["router_agent_id"]
    assert inspect(payload) =~ "hello Comma"
    assert opts[:source_message_id] =~ "m4"
    assert payload.trusted_origin["provider_context"]["chat_id"] == @space

    connect_id = state["link"]["connection_id"]

    assert {:ok, %{"message_id" => "pho_msg_sent"}} =
             SalixIM.Provider.call_api(router, "imessage", "imessage.send_message", %{
               "connect_id" => connect_id,
               "params" => %{"chat_id" => @space, "text" => "Hello Alice"}
             })

    settle_receive({:photon, "POST", "/messages", reply, _})
    assert %{"spaceId" => @space, "senderId" => @agent_user} = Jason.decode!(reply)

    assert {:error, _} =
             SalixIM.Provider.call_api(router, "imessage", "imessage.send_message", %{
               "connect_id" => connect_id,
               "params" => %{"chat_id" => "pho_spc_someone_else", "text" => "private"}
             })

    settle_refute_receive({:photon, "POST", "/messages", _, _})

    api(session, :delete, path, %{}) |> json(200)
    settle_receive({:photon, "DELETE", "/platforms/imessage/assignments/asg-1", _, _})
    refute IMessageLinks.get_link(workspace["id"])

    assert {:error, _} =
             SalixIM.Provider.call_api(router, "imessage", "imessage.send_message", %{
               "connect_id" => connect_id,
               "params" => %{"chat_id" => @space, "text" => "late reply"}
             })

    settle_refute_receive({:photon, "POST", "/messages", _, _})
  end

  test "connect reuses a shared line already assigned to this account", %{
    workspace: workspace,
    session: session
  } do
    SystemsRuntime.put_env(:comma_web, :photon_test_assignments, [
      %{"assignmentId" => "asg-existing", "assignedPhoneNumber" => @line, "handle" => @alice}
    ])

    attempt =
      api(session, :post, path(workspace) <> "/connect", %{"handle" => @alice}) |> json(201)

    assert attempt["line_handle"] == @line
    assert attempt["sender_handle"] == @alice
  end

  test "a dedicated project binds on its own line, with no assignment", %{
    workspace: workspace,
    session: session
  } do
    SystemsRuntime.put_env(:comma_web, :photon_test_mode, "dedicated")

    SystemsRuntime.put_env(:comma_web, :photon_test_resources, [
      %{"resourceId" => "pho_res_1", "detail" => %{"phoneNumber" => @line}}
    ])

    attempt =
      api(session, :post, path(workspace) <> "/connect", %{"handle" => @alice}) |> json(201)

    assert attempt["line_handle"] == @line
    assert_received {:photon_resources, %{"ability" => "imessage", "state" => "active"}}
    refute_received {:photon, "POST", "/users", _, _}
    refute_received {:photon, "POST", "/platforms/imessage/assignments", _, _}

    assert :ok = IMessageIntegration.handle_event(event("m-code", @alice, attempt["code"]))

    assert %{transport: "photon", sender_handle: @alice, assignment_id: nil} =
             IMessageLinks.get_link(workspace["id"])

    assert api(session, :delete, path(workspace)) |> json(200) == %{"disconnected" => true}
    refute_received {:photon, "DELETE", "/platforms/imessage/assignments/" <> _, _, _}
  end

  test "a dedicated project attempt with no handle binds whoever sends the code", %{
    workspace: workspace,
    session: session
  } do
    SystemsRuntime.put_env(:comma_web, :photon_test_mode, "dedicated")

    SystemsRuntime.put_env(:comma_web, :photon_test_resources, [
      %{"resourceId" => "pho_res_1", "detail" => %{"phoneNumber" => @line}}
    ])

    attempt =
      api(session, :post, path(workspace) <> "/connect", %{"transport" => "photon"})
      |> json(201)

    assert attempt["line_handle"] == @line
    assert attempt["sender_handle"] == nil
    assert api(session, :get, path(workspace)) |> json(200) |> get_in(["pending_claim", "code"])
    refute MapSet.member?(IMessageLinks.photon_handles_in_use(), nil)

    assert :ok = IMessageIntegration.handle_event(event("d1", @alice, "hello?"))
    assert [hint] = drain_sends()
    assert Jason.decode!(hint)["content"]["text"] =~ "Connect iMessage"
    refute IMessageLinks.get_link(workspace["id"])

    assert :ok = IMessageIntegration.handle_event(event("d2", @alice, attempt["code"]))

    assert %{transport: "photon", sender_handle: @alice, assignment_id: nil} =
             IMessageLinks.get_link(workspace["id"])

    # The attempt is spent: nobody else can take the binding with the same code.
    assert :ok = IMessageIntegration.handle_event(event("d3", "+15550199", attempt["code"]))
    assert %{sender_handle: @alice} = IMessageLinks.get_link(workspace["id"])
  end

  test "a taken attempt stays pending while its binding is made", %{
    workspace: workspace,
    session: session
  } do
    SystemsRuntime.put_env(:comma_web, :photon_test_mode, "dedicated")

    SystemsRuntime.put_env(:comma_web, :photon_test_resources, [
      %{"resourceId" => "pho_res_1", "detail" => %{"phoneNumber" => @line}}
    ])

    attempt =
      api(session, :post, path(workspace) <> "/connect", %{"transport" => "photon"})
      |> json(201)

    assert {:ok, _taken} = IMessageLinks.take_claim(attempt["code"], "photon", @alice)

    state = api(session, :get, path(workspace)) |> json(200)
    assert state["pending_claim"]["code"] == attempt["code"]
    assert state["link"] == nil

    # The code is spent: it binds nobody while it is shown.
    refute IMessageLinks.photon_claim_code?(@alice, attempt["code"])

    # A binding that never completes ends the wait.
    Comma.Repo.update_all(Comma.Data.IMessageDMClaimCode,
      set: [consumed_at: DateTime.add(SystemsClock.utc_now(), -61, :second)]
    )

    refute api(session, :get, path(workspace)) |> json(200) |> Map.get("pending_claim")
  end

  test "a shared project needs a handle", %{workspace: workspace, session: session} do
    conn = api(session, :post, path(workspace) <> "/connect", %{"transport" => "photon"})

    assert conn.status == 409
    assert Jason.decode!(conn.resp_body)["error"] =~ "imessage_handle_required"
    refute IMessageLinks.get_active_claim(workspace["id"])
    refute_received {:photon, "POST", "/platforms/imessage/assignments", _, _}
  end

  test "a sender with no binding gets one guidance reply a day" do
    stranger = "+15550199"

    assert :ok = IMessageIntegration.handle_event(event("g1", stranger, "hello"))
    assert [guidance] = drain_sends()
    assert Jason.decode!(guidance)["content"]["text"] =~ "Connect iMessage"

    assert :ok = IMessageIntegration.handle_event(event("g2", stranger, "hello again"))
    assert :ok = IMessageIntegration.handle_event(event("g3", stranger, "bridgebot status"))
    assert :ok = IMessageIntegration.handle_event(event("g4", stranger, "bridgebot connect nope"))
    assert [] = drain_sends()

    assert :ok = IMessageIntegration.handle_event(event("g5", "+15550198", "hello"))
    assert [_] = drain_sends()

    Comma.Repo.query!(
      "UPDATE comma_imessage_guidance_replies SET replied_at = replied_at - interval '25 hours' WHERE sender_handle = $1",
      [stranger]
    )

    assert :ok = IMessageIntegration.handle_event(event("g6", stranger, "hello later"))
    assert [_] = drain_sends()
  end

  test "NUL characters in a pasted code do not stop the receiver", %{
    workspace: workspace,
    user: user
  } do
    {:ok, attempt} =
      IMessageIntegration.start_connect(user, %{}, workspace["id"], %{"handle" => @alice})

    pasted = attempt["code"] <> String.duplicate(<<0>>, 12)

    SystemsRuntime.put_env(:comma_web, :photon_test_received, [
      received(
        "m-nul",
        @alice,
        %{"type" => "text", "format" => "plain", "text" => pasted},
        DateTime.to_iso8601(SystemsClock.utc_now())
      )
    ])

    assert :ok = IMessagePhotonRuntime.run_once()
    assert %{sender_handle: @alice} = IMessageLinks.get_link(workspace["id"])
  end

  test "a code sent from another account says so, every time", %{
    workspace: workspace,
    user: user
  } do
    {:ok, attempt} =
      IMessageIntegration.start_connect(user, %{}, workspace["id"], %{"handle" => "+15550111"})

    flush_requests()

    for id <- ["w1", "w2"] do
      assert :ok = IMessageIntegration.handle_event(event(id, @alice, attempt["code"]))
      assert [reply] = drain_sends()
      assert Jason.decode!(reply)["content"]["text"] =~ "different iMessage account"
    end

    assert is_nil(IMessageLinks.get_link(workspace["id"]))
  end

  test "disconnecting gives the sender a new guidance reply", %{
    workspace: workspace,
    user: user,
    session: session
  } do
    assert :ok = IMessageIntegration.handle_event(event("r1", @alice, "hello"))
    assert [_guidance] = drain_sends()

    bind(workspace, user)
    assert api(session, :delete, path(workspace)) |> json(200) == %{"disconnected" => true}
    flush_requests()

    assert :ok = IMessageIntegration.handle_event(event("r2", @alice, "still there?"))
    assert [guidance] = drain_sends()
    assert Jason.decode!(guidance)["content"]["text"] =~ "Connect iMessage"
  end

  test "a dedicated project with no active line reports no capacity" do
    SystemsRuntime.put_env(:comma_web, :photon_test_mode, "dedicated")
    SystemsRuntime.put_env(:comma_web, :photon_test_resources, [])

    assert {:error, :imessage_capacity_reached} = PhotonIMessage.line_for(@alice)
  end

  test "webhook needs a fresh Photon signature over the raw body" do
    body = ~s({ "type": "message.received", "data": {} })
    now = DateTime.to_unix(SystemsClock.utc_now())

    assert webhook(body, now, sign(body, now)).status == 200

    assert webhook(body, now, sign(body, now, "whsec_" <> Base.encode64("other secret"))).status ==
             401

    assert webhook(body <> " ", now, sign(body, now)).status == 401
    assert webhook(body, now - 301, sign(body, now - 301)).status == 401
    assert webhook(body, now, "").status == 401
    assert webhook(body, now + 301, sign(body, now + 301)).status == 401
    assert webhook(body, now, sign(body, now), "other-id").status == 401
    assert webhook(body, now, sign(body, now), "").status == 401
    assert webhook(body, now, "v1,invalid " <> sign(body, now)).status == 200

    SystemsRuntime.put_env(:salix_im, :imessage_photon, enabled: false)
    assert webhook(body, now, sign(body, now)).status == 503
  end

  test "a pushed Message is handled before it is listed, and once", %{
    workspace: workspace,
    session: session
  } do
    SystemsRuntime.put_env(:comma_web, :photon_test_mode, "dedicated")

    SystemsRuntime.put_env(:comma_web, :photon_test_resources, [
      %{"resourceId" => "pho_res_1", "detail" => %{"phoneNumber" => @line}}
    ])

    attempt =
      api(session, :post, path(workspace) <> "/connect", %{"transport" => "photon"})
      |> json(201)

    message =
      received(
        "m-pushed",
        @alice,
        %{"type" => "text", "format" => "plain", "text" => attempt["code"]},
        DateTime.to_iso8601(SystemsClock.utc_now())
      )

    body =
      Jason.encode!(%{
        "type" => "message.received",
        "data" => %{"object" => Map.put(message, "platform", "imessage")}
      })

    assert %{"id" => "m-pushed"} = pushed = PhotonIMessage.webhook_message(body)
    refute PhotonIMessage.webhook_message(~s({ "type": "message.received", "data": {} }))
    refute PhotonIMessage.webhook_message("not json")

    # The list does not answer: the Message still binds.
    SystemsRuntime.put_env(:comma_web, :photon_test_list_status, 502)
    assert :ok = IMessagePhotonRuntime.run_once(pushed: [pushed])
    assert %{sender_handle: @alice} = IMessageLinks.get_link(workspace["id"])
    assert [_connected] = drain_sends()

    # The same Message listed later is not handled again.
    SystemsRuntime.put_env(:comma_web, :photon_test_list_status, 200)
    SystemsRuntime.put_env(:comma_web, :photon_test_received, [message])
    assert :ok = IMessagePhotonRuntime.run_once()
    assert [] = drain_sends()
  end

  test "a pushed Message stays until a pass handles it" do
    ref = make_ref()

    running = %{
      task: %{ref: ref},
      kind: :poke,
      failures: 0,
      again: false,
      busy: 0,
      timer: nil,
      pushed: %{},
      passing: ["m-old"]
    }

    message = %{"id" => "m-new"}

    assert {:noreply, state} = IMessagePhotonRuntime.handle_info({:webhook, message}, running)
    assert state.again
    assert state.pushed == %{"m-new" => message}

    state = %{state | again: false, passing: ["m-new"]}

    assert {:noreply, %{pushed: kept}} =
             IMessagePhotonRuntime.handle_info({ref, {:hold, 1_000}}, state)

    assert Map.has_key?(kept, "m-new")

    assert {:noreply, %{pushed: kept}} =
             IMessagePhotonRuntime.handle_info({ref, {:error, :failed}}, state)

    assert Map.has_key?(kept, "m-new")

    assert {:noreply, %{pushed: pushed}} = IMessagePhotonRuntime.handle_info({ref, :ok}, state)
    assert pushed == %{}
  end

  test "receiver reads received Messages once across overlapping passes", %{
    workspace: workspace,
    user: user
  } do
    {:ok, attempt} =
      IMessageIntegration.start_connect(user, %{}, workspace["id"], %{"handle" => @alice})

    now = SystemsClock.utc_now() |> DateTime.to_iso8601()

    SystemsRuntime.put_env(:comma_web, :photon_test_received, [
      received(
        "m1",
        @alice,
        %{"type" => "text", "format" => "plain", "text" => attempt["code"]},
        now
      ),
      received("m2", @alice, %{"type" => "message.read"}, now),
      received("m3", @alice, %{"type" => "text", "format" => "plain", "text" => "first"}, now)
    ])

    assert :ok = IMessagePhotonRuntime.run_once()
    settle_receive({:photon_list, query})
    assert query["direction"] == "received" and query["order"] == "asc"
    assert IMessageLinks.get_link(workspace["id"]).transport == "photon"
    settle_receive({:router_input, _, payload, _})
    assert inspect(payload) =~ "first"
    assert IMessagePhotonRuntime.online?()

    # The next list still returns the same Messages inside the overlap.
    assert :ok = IMessagePhotonRuntime.run_once()
    settle_receive({:photon_list, _})
    settle_refute_receive({:router_input, _, _, _})
    assert [_confirmation] = drain_sends()
  end

  test "image in and out; refused and unacknowledged sends", %{workspace: workspace, user: user} do
    {:ok, attempt} =
      IMessageIntegration.start_connect(user, %{}, workspace["id"], %{"handle" => @alice})

    assert :ok = IMessageIntegration.handle_event(event("m1", @alice, attempt["code"]))
    link = IMessageLinks.get_link(workspace["id"])

    {:ok, image} =
      PhotonIMessage.to_event(
        received("m2", @alice, %{"type" => "attachment", "attachmentId" => "att-in"}, nil)
      )

    assert :ok = IMessageIntegration.handle_event(image)
    settle_receive({:published, agent, path, ref})
    assert path =~ "/imessage/attachments/" and path =~ "in.png"
    refute path =~ ".."
    assert {:ok, "test image bytes"} = SalixStore.Blob.get(agent, ref)
    settle_receive({:router_input, ^agent, _payload, _})

    params = %{"chat_id" => @space, "path" => "/result.png", "caption" => "result"}

    assert {:ok, _} =
             SalixIM.Provider.call_api(agent, "imessage", "imessage.send_image", %{
               "connect_id" => link.connect_id,
               "params" => params
             })

    settle_receive({:photon, "POST", "/attachments", upload, _})
    assert upload =~ "result image bytes" and upload =~ ~s("filename":"result.png")
    drain_sends()

    for {response, code} <- [
          {{403, %{"code" => "SHARED_LINE_INBOUND_REQUIRED"}}, "imessage_send_rejected"},
          {{502, %{"code" => "UPSTREAM_FAILURE"}}, "imessage_delivery_unknown"},
          {{202, %{}}, "imessage_delivery_unknown"}
        ] do
      SystemsRuntime.put_env(:comma_web, :photon_test_send_response, response)

      assert {:error, %{"code" => ^code, "retryable" => false}} =
               SalixIM.Provider.call_api(agent, "imessage", "imessage.send_message", %{
                 "connect_id" => link.connect_id,
                 "params" => %{"chat_id" => @space, "text" => "hello"}
               })

      assert [_one_attempt] = drain_sends()
    end
  end

  test "a refused inline reply sends one ordinary message and reports the downgrade", %{
    workspace: workspace,
    user: user
  } do
    agent = bind(workspace, user)
    connect_id = IMessageLinks.get_link(workspace["id"]).connect_id

    SystemsRuntime.put_env(:comma_web, :photon_test_send_response, %{
      with_parent: replies_unsupported(),
      without_parent: nil
    })

    for {api, params} <- [
          {"imessage.send_message", %{"text" => "The blue plan."}},
          {"imessage.send_image", %{"path" => "/result.png"}},
          {"imessage.send_file", %{"path" => "/clip.mp4"}}
        ] do
      assert {:ok, %{"message_id" => "pho_msg_sent", "reply_fallback" => "ordinary_message"}} =
               imessage_call(
                 agent,
                 connect_id,
                 api,
                 Map.put(params, "reply_to_message_id", "pho_msg_mine")
               )

      settle_receive({:photon, "POST", "/messages", rejected, [first_key]})
      settle_receive({:photon, "POST", "/messages", accepted, [second_key]})
      assert first_key != second_key
      rejected = Jason.decode!(rejected)
      assert rejected["parentMessageId"] == "pho_msg_mine"
      assert Jason.decode!(accepted) == Map.delete(rejected, "parentMessageId")
      assert [] = drain_sends()
    end

    {:ok, manual} = SalixIM.Provider.provider_manual("imessage", agent)

    assert Enum.map(manual["apis"], & &1["name"]) ==
             ["imessage.send_message", "imessage.send_image", "imessage.send_file"]

    for api <- manual["apis"], do: assert(Map.has_key?(api["parameters"], "reply_to_message_id"))

    # An uncertain ordinary send must not be tried again after the refused reply.
    SystemsRuntime.put_env(:comma_web, :photon_test_send_response, %{
      with_parent: replies_unsupported(),
      without_parent: {502, %{"code" => "UPSTREAM_FAILURE"}}
    })

    assert {:error, %{"code" => "imessage_delivery_unknown", "retryable" => false}} =
             imessage_call(agent, connect_id, "imessage.send_message", %{
               "text" => "One attempt only.",
               "reply_to_message_id" => "pho_msg_mine"
             })

    assert [_, _] = drain_sends()
  end

  test "unsupported reactions and other reply failures send nothing else", %{
    workspace: workspace,
    user: user
  } do
    agent = bind(workspace, user)
    connect_id = IMessageLinks.get_link(workspace["id"]).connect_id
    SystemsRuntime.put_env(:comma_web, :photon_test_send_response, replies_unsupported())

    assert {:error,
            %{
              "code" => "imessage_reaction_unsupported",
              "delivery_status" => "not_sent",
              "retryable" => false,
              "provider_request_id" => "pho_req_reply_refused"
            }} =
             imessage_call(agent, connect_id, "imessage.react", %{
               "emoji" => "👍",
               "message_id" => "pho_msg_mine"
             })

    assert [_] = drain_sends()

    SystemsRuntime.put_env(
      :comma_web,
      :photon_test_send_response,
      {422, %{"code" => "UNSUPPORTED_CONTENT", "detail" => "Cannot be sent to this Space."}}
    )

    assert {:error, %{"code" => "imessage_reaction_unsupported", "delivery_status" => "not_sent"}} =
             imessage_call(agent, connect_id, "imessage.react", %{
               "emoji" => "👍",
               "message_id" => "pho_msg_mine"
             })

    assert [_] = drain_sends()

    assert {:error, %{"code" => "imessage_reaction_unsupported", "delivery_status" => "not_sent"}} =
             imessage_call(agent, connect_id, "imessage.react", %{
               "emoji" => "👍",
               "message_id" => "pho_msg_mine",
               "remove" => true
             })

    assert [] = drain_sends()

    for {response, code} <- [
          {{409, %{"code" => "SPACE_NOT_SENDABLE", "detail" => "Space is not active"}},
           "imessage_send_rejected"},
          {{502, %{"code" => "UPSTREAM_FAILURE"}}, "imessage_delivery_unknown"}
        ] do
      SystemsRuntime.put_env(:comma_web, :photon_test_send_response, response)

      assert {:error, %{"code" => ^code, "retryable" => false}} =
               imessage_call(agent, connect_id, "imessage.send_message", %{
                 "text" => "Do not send twice.",
                 "reply_to_message_id" => "pho_msg_mine"
               })

      assert [_] = drain_sends()
    end
  end

  test "an accepted image with a refused caption must not be sent again", %{
    workspace: workspace,
    user: user
  } do
    agent = bind(workspace, user)
    connect_id = IMessageLinks.get_link(workspace["id"]).connect_id

    SystemsRuntime.put_env(:comma_web, :photon_test_send_response, %{
      with_parent: replies_unsupported(),
      without_parent: :reject_caption
    })

    assert {:error, %{"code" => "imessage_delivery_unknown", "retryable" => false}} =
             imessage_call(agent, connect_id, "imessage.send_image", %{
               "path" => "/result.png",
               "caption" => "result",
               "reply_to_message_id" => "pho_msg_mine"
             })

    assert [rejected_image, accepted_image, rejected_caption] =
             Enum.map(drain_sends(), &Jason.decode!/1)

    assert rejected_image["parentMessageId"] == "pho_msg_mine"
    assert accepted_image == Map.delete(rejected_image, "parentMessageId")
    assert rejected_caption["content"]["type"] == "text"
  end

  defp replies_unsupported do
    {409,
     %{
       "code" => "SPACE_NOT_SENDABLE",
       "detail" => "Replies are not supported for this Space",
       "requestId" => "pho_req_reply_refused"
     }}
  end

  test "replies inline, reacts, and quotes the message a reply names", %{
    workspace: workspace,
    user: user
  } do
    agent = bind(workspace, user)
    connect_id = IMessageLinks.get_link(workspace["id"]).connect_id
    call = fn api, params -> imessage_call(agent, connect_id, api, params) end

    # An inline reply names a Message of this Space as its parent.
    assert {:ok, _} =
             call.("imessage.send_message", %{
               "text" => "The blue plan.",
               "reply_to_message_id" => "pho_msg_mine"
             })

    settle_receive({:photon, "GET", "/messages/pho_msg_mine", _, _})
    assert [reply] = drain_sends()

    assert %{"parentMessageId" => "pho_msg_mine", "content" => %{"text" => "The blue plan."}} =
             Jason.decode!(reply)

    # Without a target the answer is an ordinary message, as on Telegram.
    assert {:ok, _} = call.("imessage.send_message", %{"text" => "Done."})
    assert [plain] = drain_sends()
    refute Map.has_key?(Jason.decode!(plain), "parentMessageId")

    # A Message of another Space, or none at all, sends nothing.
    for target <- ["pho_msg_elsewhere", "pho_msg_missing"] do
      assert {:error, reason} =
               call.("imessage.send_message", %{"text" => "x", "reply_to_message_id" => target})

      assert reason =~ "this chat"
      assert [] = drain_sends()
    end

    # A tapback on a named Message; without a source message the target is required.
    assert {:ok, _} =
             call.("imessage.react", %{"emoji" => "❤️", "message_id" => "pho_msg_mine"})

    assert [reaction] = drain_sends()

    assert %{
             "parentMessageId" => "pho_msg_mine",
             "content" => content
           } = Jason.decode!(reaction)

    assert content == %{"type" => "reaction", "reaction" => "❤️"}

    assert {:error, reason} = call.("imessage.react", %{"emoji" => "👍"})
    assert reason =~ "message_id is required"
    assert [] = drain_sends()

    # The person replies to Comma's earlier question: the quote comes first, as context.
    reply_event =
      received("m10", @alice, %{"type" => "text", "format" => "plain", "text" => "this one"}, nil)
      |> Map.put("parentMessageId", "pho_msg_parent")
      |> PhotonIMessage.to_event()
      |> elem(1)

    assert :ok = IMessageIntegration.handle_event(reply_event)
    settle_receive({:router_input, ^agent, payload, _})

    assert inspect(payload) =~
             "[Replying to message pho_msg_parent by Comma: Which plan do you want?]\\nthis one"

    lost =
      received("m11", @alice, %{"type" => "text", "format" => "plain", "text" => "and this"}, nil)
      |> Map.put("parentMessageId", "pho_msg_missing")
      |> PhotonIMessage.to_event()
      |> elem(1)

    assert :ok = IMessageIntegration.handle_event(lost)
    settle_receive({:router_input, ^agent, payload, _})

    assert inspect(payload) =~
             "[Replying to message pho_msg_missing: the original is unavailable]"

    # A real Photon reply can omit its parent ID. Never substitute a recent message.
    assert :ok = IMessageIntegration.handle_event(event("m12", @alice, "What did I quote?"))
    settle_receive({:router_input, ^agent, payload, _})
    assert inspect(payload) =~ "[iMessage reply target: not supplied by Photon]"
    refute inspect(payload) =~ "Which plan do you want?"
  end

  test "an image and its text sent together reach the Agent as one input", %{
    workspace: workspace,
    user: user
  } do
    agent = bind(workspace, user)
    image_at = SystemsClock.utc_now()
    text_at = DateTime.add(image_at, 150, :millisecond)

    image =
      received(
        "pho_msg_00000000000000000000000001",
        @alice,
        %{"type" => "attachment", "attachmentId" => "att-in"},
        DateTime.to_iso8601(image_at)
      )

    text =
      received(
        "pho_msg_00000000000000000000000002",
        @alice,
        %{"type" => "text", "format" => "plain", "text" => "这是啥"},
        DateTime.to_iso8601(text_at)
      )

    # The first pass sees only the image; the next one sees the text as well.
    SystemsRuntime.put_env(:comma_web, :photon_test_received, [image])
    assert {:hold, _} = IMessagePhotonRuntime.run_once()
    SystemsRuntime.put_env(:comma_web, :photon_test_received, [image, text])
    assert {:hold, wait} = IMessagePhotonRuntime.run_once()
    assert wait <= 2_000
    settle_refute_receive({:router_input, _, _, _})

    SystemsClock.run_for(2_100)
    assert :ok = IMessagePhotonRuntime.run_once()
    settle_receive({:router_input, ^agent, payload, opts})
    assert inspect(payload) =~ "这是啥"
    assert inspect(payload) =~ "/imessage/attachments/"
    assert opts[:source_message_id] =~ "burst:"

    # Both Messages are checkpointed: the next pass delivers nothing.
    assert :ok = IMessagePhotonRuntime.run_once()
    settle_refute_receive({:router_input, _, _, _})

    # A later burst must retain real-length IDs from the overlap and its hold.
    later =
      received(
        "pho_msg_00000000000000000000000003",
        @alice,
        %{"type" => "text", "format" => "plain", "text" => "Next question"},
        DateTime.to_iso8601(SystemsClock.utc_now())
      )

    SystemsRuntime.put_env(:comma_web, :photon_test_received, [image, text, later])
    assert {:hold, _} = IMessagePhotonRuntime.run_once()
    SystemsClock.run_for(2_100)
    assert :ok = IMessagePhotonRuntime.run_once()
    settle_receive({:router_input, ^agent, next_payload, _})
    assert inspect(next_payload) =~ "Next question"
    refute inspect(next_payload) =~ "这是啥"
    assert :ok = IMessagePhotonRuntime.run_once()
    settle_refute_receive({:router_input, _, _, _})
  end

  test "a video goes out as one streamed upload; an oversized file sends nothing", %{
    workspace: workspace,
    user: user
  } do
    agent = bind(workspace, user)
    connect_id = IMessageLinks.get_link(workspace["id"]).connect_id

    assert {:ok, %{"message_id" => "pho_msg_sent"}} =
             imessage_call(agent, connect_id, "imessage.send_file", %{
               "path" => "/clip.mp4",
               "caption" => "Here is the clip."
             })

    settle_receive({:photon, "POST", "/attachments", upload, _})
    [_preamble, meta, file | _] = String.split(upload, ~r/--[0-9a-f]{32}(--)?\r\n/)
    [_headers, meta] = String.split(meta, "\r\n\r\n", parts: 2)

    assert Jason.decode!(String.trim_trailing(meta, "\r\n")) == %{
             "contentType" => "video/mp4",
             "sizeBytes" => 11,
             "filename" => "clip.mp4"
           }

    assert file == "content-type: video/mp4\r\n\r\nvideo bytes\r\n"

    assert [attachment, caption] = Enum.map(drain_sends(), &Jason.decode!/1)
    assert attachment["content"] == %{"type" => "attachment", "attachmentId" => "att-out"}
    assert caption["content"]["text"] == "Here is the clip."

    # The workspace size refuses the file before any byte is read or sent.
    flush_requests()

    assert {:error,
            %{
              "code" => "imessage_file_too_large",
              "delivery_status" => "not_sent",
              "retryable" => false
            }} = imessage_call(agent, connect_id, "imessage.send_file", %{"path" => "/huge.mp4"})

    settle_refute_receive({:photon, "POST", _, _, _})
    refute_received :huge_file_read
  end

  test "a video and its text reach the Agent as one input; an oversized file is named, not read",
       %{workspace: workspace, user: user} do
    agent = bind(workspace, user)
    video_at = SystemsClock.utc_now()

    video =
      received(
        "pho_msg_00000000000000000000000011",
        @alice,
        %{"type" => "attachment", "attachmentId" => "att-video"},
        DateTime.to_iso8601(video_at)
      )

    text =
      received(
        "pho_msg_00000000000000000000000012",
        @alice,
        %{"type" => "text", "format" => "plain", "text" => "Watch this"},
        DateTime.to_iso8601(DateTime.add(video_at, 150, :millisecond))
      )

    SystemsRuntime.put_env(:comma_web, :photon_test_received, [video, text])
    assert {:hold, _} = IMessagePhotonRuntime.run_once()
    SystemsClock.run_for(2_100)
    assert :ok = IMessagePhotonRuntime.run_once()

    settle_receive({:published, ^agent, path, ref})
    assert path =~ "/imessage/attachments/" and path =~ "IMG_0001.MOV"
    assert {:ok, "test video bytes"} = SalixStore.Blob.get(agent, ref)
    settle_receive({:router_input, ^agent, payload, opts})
    assert opts[:source_message_id] =~ "burst:"
    assert inspect(payload) =~ "Watch this"
    assert inspect(payload) =~ path
    assert inspect(payload) =~ "video/quicktime"
    settle_refute_receive({:router_input, _, _, _})

    # A voice memo alone is named by its kind. An oversized file is not downloaded.
    for {id, attachment_id, placeholder} <- [
          {"pho_msg_00000000000000000000000013", "att-voice", "[iMessage audio]"},
          {"pho_msg_00000000000000000000000014", "att-big", "[iMessage video]"}
        ] do
      {:ok, event} =
        PhotonIMessage.to_event(
          received(id, @alice, %{"type" => "attachment", "attachmentId" => attachment_id}, nil)
        )

      assert :ok = IMessageIntegration.handle_event(event)
      settle_receive({:router_input, ^agent, payload, _})
      assert inspect(payload) =~ placeholder

      if attachment_id == "att-big" do
        assert inspect(payload) =~ "size_limit"
        assert inspect(payload) =~ "long.mp4"
        settle_refute_receive({:published, _, _, _})
        refute_received {:photon, "GET", "/attachments/att-big/content", _, _}
      else
        assert_received {:published, ^agent, voice_path, _}
        assert voice_path =~ "audio.caf"
      end
    end
  end

  defp bind(workspace, user) do
    {:ok, attempt} =
      IMessageIntegration.start_connect(user, %{}, workspace["id"], %{"handle" => @alice})

    assert :ok = IMessageIntegration.handle_event(event("m-code", @alice, attempt["code"]))
    drain_sends()
    workspace["router_agent_id"]
  end

  defp imessage_call(agent, connect_id, api, params) do
    SalixIM.Provider.call_api(agent, "imessage", api, %{
      "connect_id" => connect_id,
      "params" => Map.put(params, "chat_id", @space)
    })
  end

  defp flush_requests do
    receive do
      {:photon, _, _, _, _} -> flush_requests()
    after
      0 -> :ok
    end
  end

  defp drain_sends(acc \\ []) do
    receive do
      {:photon, "POST", "/messages", body, _} -> drain_sends([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp event(id, handle, text) do
    {:ok, event} =
      PhotonIMessage.to_event(
        received(id, handle, %{"type" => "text", "format" => "plain", "text" => text}, nil)
      )

    event
  end

  defp received(id, handle, content, created_at) do
    user_id = if handle == @alice, do: @alice_user, else: "pho_usr_00000000000000000000000other"

    %{
      "id" => id,
      "status" => "received",
      "platform" => "imessage",
      "createdAt" => created_at,
      "sentBy" => %{"id" => user_id, "handle" => handle, "kind" => "human"},
      "receivedBy" => %{"id" => @agent_user, "handle" => @line, "kind" => "agent"},
      "space" => %{"id" => @space, "kind" => "direct", "participantIds" => [@agent_user, user_id]},
      "content" => content
    }
  end

  defp sign(body, timestamp, secret \\ @webhook_secret) do
    key = secret |> String.replace_prefix("whsec_", "") |> Base.decode64!()

    "v1," <>
      Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{@webhook_id}.#{timestamp}." <> body))
  end

  defp webhook(body, timestamp, signature, id \\ @webhook_id) do
    conn(:post, "/v1/comma/integrations/imessage/photon/webhook", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("webhook-id", id)
    |> put_req_header("webhook-timestamp", Integer.to_string(timestamp))
    |> put_req_header("webhook-signature", signature)
    |> CommaWeb.Router.call(CommaWeb.Router.init([]))
  end

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
