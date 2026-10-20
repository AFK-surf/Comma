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
      json(conn, 200, %{"items" => setting(:photon_test_received, [])})
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

    defp respond(conn, "GET", "/attachments/att-in"),
      do:
        json(conn, 200, %{
          "contentType" => "image/png",
          "filename" => "../in.png",
          "sizeBytes" => 16
        })

    defp respond(conn, "GET", "/attachments/att-in/content"),
      do: conn |> put_resp_content_type("image/png") |> send_resp(200, "test image bytes")

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
          {"imessage.send_image", %{"path" => "/result.png"}}
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
             ["imessage.send_message", "imessage.send_image"]

    for api <- manual["apis"], do: refute(Map.has_key?(api["parameters"], "reply_to_message_id"))

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
             "content" => %{"type" => "reaction", "reaction" => "❤️", "action" => "add"}
           } = Jason.decode!(reaction)

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
