defmodule CommaWeb.CommaMessageResourceTest do
  use Comma.DataCase, async: false

  @admin_token "test-token"

  test "dynamic UI bytes survive history reload and reject another workspace reader" do
    %{workspace: workspace, session: session} =
      create_workspace_session("dynamic-ui@example.com", "Dynamic UI")

    conversation = create_conversation(session, workspace)
    unless Process.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)

    :ok =
      BillingCore.Accounts.ensure_account(%{
        repo: BillingCore.Repo,
        billing_account_id: workspace["billing_account_id"],
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: workspace["id"]
      })

    assert {:ok, _grant} =
             BillingCore.Credits.issue_grant(%{
               repo: BillingCore.Repo,
               billing_account_id: workspace["billing_account_id"],
               credits: 100,
               valid_from: DateTime.add(DateTime.utc_now(), -60, :second),
               expires_at: DateTime.add(DateTime.utc_now(), 1, :day),
               source_type: "manual_contract",
               source_id: "ui-test",
               source_event_id: workspace["id"],
               idempotency_key: workspace["id"]
             })

    agent_id = workspace["router_agent_id"]
    group_id = workspace["default_group_id"]
    worker_id = workspace["default_worker_agent_id"]

    assert {:ok, payload} =
             SalixAgent.Tools.DynamicUI.validate(%{
               "html" => "<p id='weather'>Singapore</p>",
               "script" => "",
               "data" => %{"temperature" => 27},
               "summary" => "Singapore: 27 °C"
             })

    bytes = Jason.encode!(payload)
    {result, events} = SalixAgent.Tools.DynamicUI.create(payload, %{agent_id: worker_id})
    block = Jason.decode!(result)["content"]
    ui_ref = block["ui_ref"]
    path = block["path"]

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(worker_id, "ui-create-test", %{}, events)

    assert {:ok, worker_content} =
             SalixIM.ConversationAttachments.bind_sender_files(worker_id, [block])

    assert {:ok, [projected]} =
             SalixIM.ConversationAttachments.materialize_messages(agent_id, [
               %{
                 "actor_type" => "agent",
                 "agent_id" => worker_id,
                 "message_id" => SalixStore.Ids.new_message_id(),
                 "content" => worker_content
               }
             ])

    assert {:ok, content} =
             SalixIM.ConversationAttachments.bind_sender_files(agent_id, projected["content"])

    assert hd(content)["blob_ref"] == hd(worker_content)["blob_ref"]

    assert {:ok, %{"message_id" => message_id}} =
             SalixIM.ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation["id"],
               agent_id,
               %{"client_request_id" => "dynamic-ui-1", "content" => content}
             )

    seed_agent_vfs!(worker_id, %{path => "later source change"})
    assert {:error, _} = SalixIM.ConversationAttachments.bind_sender_files(worker_id, [block])
    url = "/v1/comma/groups/#{group_id}/conversations/#{conversation["id"]}"
    detail = user_req(session["token"], :get, url) |> expect_status(200)
    message = Enum.find(detail.body["messages"], &(&1["message_id"] == message_id))

    assert [%{"type" => "dynamic_ui", "ui_ref" => ^ui_ref, "blob_ref" => ref}] =
             message["content"]

    assert ref["uuid"] == hd(content)["blob_ref"]["uuid"]
    resource_url = url <> "/messages/#{message_id}/attachments/0"

    assert (user_req(session["token"], :get, resource_url, decode_body: false)
            |> expect_status(200)).body == bytes

    user_req(session["token"], :post, url <> "/messages",
      json: %{
        "message" => %{"type" => "text", "text" => "Refresh this card"},
        "client_request_id" => "ui-followup",
        "reply_to_message_id" => message_id
      }
    )
    |> expect_status(202)

    updated = user_req(session["token"], :get, url) |> expect_status(200)

    assert Enum.any?(
             updated.body["messages"],
             &(&1["actor_type"] == "user" and &1["reply_to_message_id"] == message_id)
           )

    %{session: outsider} = create_workspace_session("dynamic-ui-outsider@example.com", "Other")
    assert user_req(outsider["token"], :get, resource_url).status in [403, 404]
  end

  setup do
    unless Process.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner) end)
    ensure_fake_s3!()
    SalixAgent.TestSupport.stop_all_agents()

    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_im_provider = Application.get_env(:salix_agent, :im_provider_mod)
    prev_salix_client = Application.get_env(:comma_core, :salix_client)
    prev_api_token = Application.get_env(:comma_web, :api_token)
    prev_heartbeat_ms = Application.get_env(:comma_web, :comma_sse_heartbeat_ms)
    prev_im_notifier = Application.get_env(:salix_im, :conversation_notifier)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:comma_web, :api_token, @admin_token)
    Application.put_env(:comma_web, :comma_sse_heartbeat_ms, 50)
    Application.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    Application.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)
    CommaWeb.Application.register_im_notifier()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_backend)
      restore_env(:salix_agent, :im_provider_mod, prev_im_provider)
      restore_env(:comma_web, :api_token, prev_api_token)
      restore_env(:comma_web, :comma_sse_heartbeat_ms, prev_heartbeat_ms)
      restore_env(:comma_core, :salix_client, prev_salix_client)
      restore_env(:salix_im, :conversation_notifier, prev_im_notifier)
    end)

    :ok
  end

  test "an Agent image reference from the canonical Message renders the immutable bytes" do
    %{workspace: workspace, session: session} =
      create_workspace_session("message-resource@example.com", "Message Resource")

    conversation = create_conversation(session, workspace)
    agent_id = workspace["router_agent_id"]
    image_path = "/artifacts/client-visible.png"
    file_path = "/artifacts/report.txt"

    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )

    seed_agent_vfs!(agent_id, %{image_path => png, file_path => "report body"})

    assert {:ok, content} =
             SalixIM.ConversationAttachments.bind_sender_files(agent_id, [
               %{"type" => "text", "text" => "The artifacts are ready."},
               %{
                 "type" => "image",
                 "file_ref" => %{"environment_id" => "vfs", "path" => image_path},
                 "file_name" => "client-visible.png",
                 "mime_type" => "image/png",
                 "size" => byte_size(png)
               },
               %{
                 "type" => "file",
                 "path" => file_path,
                 "file_name" => "report.txt",
                 "mime_type" => "text/plain",
                 "size" => byte_size("report body")
               }
             ])

    assert {:ok, %{"inserted" => true, "message_id" => message_id}} =
             SalixIM.ConversationServer.append_group_conversation_agent_message(
               workspace["default_group_id"],
               salix_conversation_id(conversation),
               agent_id,
               %{
                 "client_request_id" => "message-resource-1",
                 "content" => content
               }
             )

    # The canonical block's blob ref is the sent snapshot, not a later read of
    # the mutable VFS path.
    seed_agent_vfs!(agent_id, %{image_path => "changed after send"})

    body =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}"
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    message = Enum.find(body["messages"], &(&1["message_id"] == message_id))
    image = Enum.find(message["content"], &(&1["type"] == "image"))
    file = Enum.find(message["content"], &(&1["type"] == "file"))

    assert message["agent_id"] == agent_id
    assert image["file_ref"] == %{"environment_id" => "vfs", "path" => image_path}
    assert image["file_name"] == "client-visible.png"

    assert %{"kind" => "blob", "uuid" => uuid, "hash" => hash, "size" => size} =
             image["blob_ref"]

    assert byte_size(uuid) == 32
    assert byte_size(hash) == 64
    assert size == byte_size(png)
    assert file["file_name"] == "report.txt"
    assert file["blob_ref"]["kind"] == "blob"

    resource =
      user_req(
        session["token"],
        :post,
        "/v1/comma/groups/#{workspace["default_group_id"]}/agents/#{agent_id}/resources",
        json: %{"ref" => image["blob_ref"]}
      )
      |> expect_status(200)

    assert resource.body == png
  end

  @tag :worker_file_delivery
  test "Agent file binding rejects missing VFS paths and corrected PDF bytes download through Comma HTTP" do
    %{workspace: workspace, session: session} =
      create_workspace_session("pdf-delivery@example.com", "PDF Delivery")

    conversation = create_conversation(session, workspace)
    agent_id = workspace["router_agent_id"]
    group_id = workspace["default_group_id"]
    conversation_id = conversation["id"]
    path = "/artifacts/Apple_Report_2026.pdf"
    pdf = File.read!(Path.expand("../../salix_agent/test/fixtures/attached-report.pdf", __DIR__))
    seed_agent_vfs!(agent_id, %{path => pdf})
    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)

    base = %{
      "type" => "file",
      "file_name" => "Apple_Report_2026.pdf",
      "mime_type" => "application/pdf"
    }

    forged_ref = %{
      "kind" => "blob",
      "uuid" => String.duplicate("a", 32),
      "hash" => String.duplicate("b", 64),
      "size" => 1
    }

    send_file = fn block, request_id ->
      Salix.Bindings.AgentIMProvider.call_api(agent_id, "internal", "internal.send_message", %{
        "connect_id" => "internal",
        "tool_call_id" => request_id,
        "params" => %{
          "conversation_id" => conversation_id,
          "request_id" => request_id,
          "content" => [%{"type" => "text", "text" => "The PDF is ready."}, block]
        },
        "tool_context" => %{"runtime_kind" => "internal", "session_id" => session_id}
      })
    end

    for {block, index} <-
          [
            base,
            Map.put(base, "path", "  "),
            Map.put(base, "path", 123),
            Map.put(base, "file_ref", %{"environment_id" => "vfs", "path" => path}),
            Map.put(base, "blob_ref", forged_ref)
          ]
          |> Enum.with_index() do
      assert {:error, reason} = send_file.(block, "invalid-file-#{index}")
      assert reason =~ "path"
      assert reason =~ "VFS"
    end

    detail =
      user_req(session["token"], :get, "/v1/comma/groups/#{group_id}/conversations/#{conversation_id}")
      |> expect_status(200)

    assert detail.body["messages"] == []

    assert {:ok, sent} =
             send_file.(
               base |> Map.put("path", path) |> Map.put("blob_ref", forged_ref),
               "corrected-pdf"
             )

    # A later VFS edit cannot replace the bytes of the canonical sent Message.
    seed_agent_vfs!(agent_id, %{path => "changed after send"})

    detail =
      user_req(session["token"], :get, "/v1/comma/groups/#{group_id}/conversations/#{conversation_id}")
      |> expect_status(200)

    assert [message] = detail.body["messages"]
    assert message["message_id"] == sent["message_id"]
    assert [_, file] = message["content"]
    refute file["blob_ref"] == forged_ref
    assert file["path"] == path

    download =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{group_id}/conversations/#{conversation_id}/messages/#{message["message_id"]}/attachments/1"
      )
      |> expect_status(200)

    assert download.body == pdf
    assert Req.Response.get_header(download, "content-type") == ["application/pdf"]

    assert Req.Response.get_header(download, "content-disposition") == [
             "attachment; filename*=UTF-8''Apple_Report_2026.pdf"
           ]
  end

  test "explicit replies preserve their target through provider sends, retries, and Comma HTTP reads" do
    %{workspace: workspace, session: session} =
      create_workspace_session("message-replies@example.com", "Message Replies")

    conversation = create_conversation(session, workspace)
    group_id = workspace["default_group_id"]
    conversation_id = conversation["id"]
    agent_id = workspace["router_agent_id"]
    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)

    assert {:ok, %{"message_id" => user_message_id}} =
             SalixIM.ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "actor_type" => "user",
                 "user_id" => "current",
                 "content" => "Please review this result.",
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    send_reply = fn target_id, request_id ->
      Salix.Bindings.AgentIMProvider.call_api(agent_id, "internal", "internal.send_message", %{
        "connect_id" => "internal",
        "tool_call_id" => request_id,
        "params" => %{
          "conversation_id" => conversation_id,
          "request_id" => request_id,
          "reply_to_message_id" => target_id,
          "delivery_filter" => %{"participant_ids" => []},
          "content" => [%{"type" => "text", "text" => "Reviewed."}]
        },
        "tool_context" => %{"runtime_kind" => "internal", "session_id" => session_id}
      })
    end

    assert {:ok, %{"message_id" => assistant_id}} = send_reply.(user_message_id, "reply-user")
    assert {:ok, %{"message_id" => ^assistant_id}} = send_reply.(user_message_id, "reply-user")
    assert {:ok, %{"message_id" => followup_id}} = send_reply.(assistant_id, "reply-assistant")
    assert {:error, conflict} = send_reply.(assistant_id, "reply-user")
    assert conflict =~ "different content"

    for invalid <- ["not-a-message", SalixStore.Ids.new_message_id(), 123] do
      assert {:error, _} = send_reply.(invalid, "invalid-#{inspect(invalid)}")
    end

    {:ok, %{"participants" => participants}} =
      SalixIM.Conversations.list_group_conversation_participants(group_id, conversation_id)

    participant = Enum.find(participants, &(&1["agent_id"] == agent_id))

    {:ok, source} =
      SalixIM.ConversationSourceIdentity.encode(
        conversation_id,
        user_message_id,
        participant["participant_id"]
      )

    assert {:ok, %{"message_id" => ordinary_id}} =
             Salix.Bindings.AgentIMProvider.call_api(
               agent_id,
               "internal",
               "internal.send_message",
               %{
                 "connect_id" => "internal",
                 "tool_call_id" => "ordinary-reply",
                 "params" => %{
                   "conversation_id" => conversation_id,
                   "content" => [
                     %{"type" => "text", "text" => "An ordinary reply without routing metadata."}
                   ],
                   "delivery_filter" => %{"participant_ids" => []}
                 },
                 "tool_context" => %{
                   "runtime_kind" => "internal",
                   "session_id" => session_id,
                   "source_message_id" => source,
                   "source_message_ids" => [source]
                 }
               }
             )

    detail =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{group_id}/conversations/#{conversation_id}/messages"
      )
      |> expect_status(200)

    messages = detail.body["data"]
    assert length(messages) == 4
    assert Enum.all?(messages, &(&1["thread_root_message_id"] == user_message_id))

    assert Enum.find(messages, &(&1["message_id"] == ordinary_id))["reply_to_message_id"] ==
             user_message_id

    assert Enum.find(messages, &(&1["message_id"] == assistant_id))["reply_to_message_id"] ==
             user_message_id

    assert Enum.find(messages, &(&1["message_id"] == followup_id))["reply_to_message_id"] ==
             assistant_id

    refute Map.has_key?(hd(messages), "reply_to_message_id")

    assert {:ok, canonical} =
             SalixIM.Conversations.get_group_conversation_message(
               group_id,
               conversation_id,
               followup_id
             )

    assert canonical["reply_to_message_id"] == assistant_id
    assert canonical["thread_root_message_id"] == user_message_id

    later_ids =
      for index <- 1..24 do
        assert {:ok, %{"message_id" => id}} = send_reply.(user_message_id, "later-#{index}")
        id
      end

    target_id = Enum.at(later_ids, 20)

    context =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{group_id}/conversations/#{conversation_id}/messages/#{target_id}/context?limit=100000"
      )
      |> expect_status(200)

    assert length(context.body["data"]) == 17
    assert Enum.all?(context.body["data"], &(&1["thread_root_message_id"] == user_message_id))
    assert List.last(context.body["data"])["message_id"] == target_id
    refute Enum.any?(context.body["data"], &(&1["message_id"] == List.last(later_ids)))

    user_req(
      session["token"],
      :get,
      "/v1/comma/groups/#{group_id}/conversations/#{conversation_id}/messages/#{SalixStore.Ids.new_message_id()}/context"
    )
    |> expect_status(404)
  end

  test "the message list reads one sequence page with its covered span and bounds" do
    %{workspace: workspace, session: session} =
      create_workspace_session("message-pages@example.com", "Message Pages")

    conversation = create_conversation(session, workspace)
    group_id = workspace["default_group_id"]
    conversation_id = conversation["id"]

    # Message 5 is a context Message: the chat hides it, but it holds a seq.
    for index <- 1..9 do
      content = if index == 5, do: "[[comma-context]]\nhidden", else: "page message #{index}"

      assert {:ok, %{"seq" => ^index}} =
               SalixIM.ConversationServer.append_group_conversation_message(
                 group_id,
                 conversation_id,
                 %{
                   "actor_type" => "user",
                   "user_id" => "current",
                   "content" => content,
                   "delivery_filter" => %{"participant_ids" => []}
                 }
               )
    end

    base = "/v1/comma/groups/#{group_id}/conversations/#{conversation_id}/messages"
    read = fn query -> user_req(session["token"], :get, base <> query) |> expect_status(200) end
    seqs = fn resp -> Enum.map(resp.body["data"], & &1["seq"]) end
    bounds = %{"first" => 1, "last" => 9}

    # Without page parameters the read is unchanged.
    unpaged = read.("")
    assert seqs.(unpaged) == Enum.to_list(1..9)
    assert Map.keys(unpaged.body) == ["data"]

    around = read.("?around=5&limit=3")
    assert seqs.(around) == [4, 5, 6]

    assert Map.delete(around.body, "data") == %{
             "covered" => %{"first" => 4, "last" => 6},
             "has_older" => true,
             "has_newer" => true,
             "bounds" => bounds
           }

    head = read.("?before=3&limit=5")
    assert seqs.(head) == [1, 2]
    assert %{"covered" => %{"first" => 1, "last" => 2}, "has_older" => false} = head.body

    caught_up = read.("?after=9")

    assert caught_up.body == %{
             "data" => [],
             "covered" => nil,
             "has_older" => true,
             "has_newer" => false,
             "bounds" => bounds
           }

    assert seqs.(read.("?limit=4")) == [6, 7, 8, 9]
    assert seqs.(read.("?after=7&limit=500")) == [8, 9]

    user_req(session["token"], :get, base <> "?around=10") |> expect_status(404)

    # Errors name the HTTP parameters.
    for {query, error} <- [
          {"?before=3&after=1", "at most one of before, after, around is allowed"},
          {"?before=0", "before must be a positive integer"},
          {"?after=abc", "after must be a positive integer"},
          {"?around=-1", "around must be a positive integer"},
          {"?limit=0", "limit must be a positive integer"},
          # Nested query parameters decode to maps and lists, not strings.
          {"?before[x]=3", "before must be a positive integer"},
          {"?after[]=3", "after must be a positive integer"},
          {"?limit[x]=5", "limit must be a positive integer"}
        ] do
      response = user_req(session["token"], :get, base <> query) |> expect_status(400)
      assert response.body == %{"error" => error}
    end
  end

  test "the message page read has the list read's authorization" do
    %{workspace: workspace, session: session} =
      create_workspace_session("message-pages-owner@example.com", "Message Page Owner")

    %{session: outsider} =
      create_workspace_session("message-pages-outsider@example.com", "Message Page Outsider")

    conversation = create_conversation(session, workspace)
    group_id = workspace["default_group_id"]

    assert {:ok, _} =
             SalixIM.ConversationServer.append_group_conversation_message(
               group_id,
               conversation["id"],
               %{
                 "actor_type" => "user",
                 "user_id" => "current",
                 "content" => "private",
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    base = "/v1/comma/groups/#{group_id}/conversations/#{conversation["id"]}/messages"
    unpaged = user_req(outsider["token"], :get, base)
    assert unpaged.status in [403, 404]

    for query <- ["?limit=1", "?around=1", "?after=1", "?before=1"] do
      response = user_req(outsider["token"], :get, base <> query)
      assert response.status == unpaged.status
      refute Map.has_key?(response.body, "data")
    end
  end

  test "the message list never pages another Conversation's Messages" do
    %{workspace: workspace, session: session} =
      create_workspace_session("message-pages-scope@example.com", "Message Page Scope")

    conversation = create_conversation(session, workspace)
    group_id = workspace["default_group_id"]

    # Same Group, different Conversation, and longer: its Message ids are well
    # formed and its tail seq is beyond the reader's tail.
    assert {:ok, %{"conversation_id" => other_id}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "title" => "Other Conversation",
               "participants" => [
                 %{
                   "actor_type" => "user",
                   "user_id" => "current",
                   "state" => "active",
                   "notification_filter" => %{"messages" => "all", "statuses" => "none"},
                   "created_at" => System.system_time(:millisecond),
                   "updated_at" => System.system_time(:millisecond)
                 }
               ]
             })

    for {conversation_id, count} <- [{conversation["id"], 2}, {other_id, 4}],
        index <- 1..count do
      assert {:ok, _} =
               SalixIM.ConversationServer.append_group_conversation_message(
                 group_id,
                 conversation_id,
                 %{
                   "actor_type" => "user",
                   "user_id" => "current",
                   "content" => "#{conversation_id} #{index}",
                   "delivery_filter" => %{"participant_ids" => []}
                 }
               )
    end

    assert {:ok, %{"messages" => [%{"message_id" => foreign_id} | _] = foreign}} =
             SalixIM.Conversations.list_group_conversation_message_page(group_id, other_id,
               limit: 4
             )

    foreign_ids = Enum.map(foreign, & &1["message_id"])
    base = "/v1/comma/groups/#{group_id}/conversations/#{conversation["id"]}/messages"

    for position <- ["before", "after", "around"] do
      response =
        user_req(session["token"], :get, base <> "?#{position}=#{foreign_id}&limit=3")
        |> expect_status(400)

      assert response.body == %{"error" => "#{position} must be a positive integer"}

      response =
        user_req(session["token"], :get, base <> "?#{position}=4&limit=3")
        |> expect_status(404)

      refute Map.has_key?(response.body, "data")

      page =
        user_req(session["token"], :get, base <> "?#{position}=2&limit=3")
        |> expect_status(200)

      refute Enum.any?(page.body["data"], &(&1["message_id"] in foreign_ids))
    end
  end

  defp create_workspace_session(email, title) do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => email, "name" => title})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"], %{"name" => title})

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    %{user: user, workspace: workspace, session: session}
  end

  defp create_conversation(session, workspace) do
    user_req(
      session["token"],
      :post,
      "/v1/comma/groups/#{workspace["default_group_id"]}/assistant-chat",
      json: %{}
    )
    |> expect_status(200)
    |> Map.fetch!(:body)
  end

  defp salix_conversation_id(%{"id" => conversation_id}), do: conversation_id

  defp admin_req(method, path, opts), do: req(@admin_token, method, path, opts)
  defp user_req(token, method, path, opts \\ []), do: req(token, method, path, opts)

  defp req(token, method, path, opts) do
    headers = [{"authorization", "Bearer " <> token}]
    Req.request!([method: method, url: base() <> path, headers: headers] ++ opts)
  end

  defp seed_agent_vfs!(agent_id, files) do
    events =
      Enum.map(files, fn {path, body} ->
        assert {:ok, event} = SalixAgent.AgentWorkspace.prepare_write(agent_id, path, body)
        event
      end)

    assert {:ok, _result} =
             SalixAgent.AgentWorkspace.seed_operation(
               agent_id,
               "comma-message-resource-test:" <>
                 Integer.to_string(System.unique_integer([:positive])),
               %{},
               events
             )
  end

  defp expect_status(resp, status) do
    assert resp.status == status, inspect(resp.body)
    resp
  end

  defp base, do: CommaWeb.Application.base_url()

  defp ensure_fake_s3! do
    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
