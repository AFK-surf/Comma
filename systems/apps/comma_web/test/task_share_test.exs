defmodule CommaWeb.TaskShareTest do
  use Comma.DataCase, async: false

  @moduletag :capture_log

  alias SalixAgent.LLM.Mock

  @admin_token "test-token"

  setup do
    unless Process.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner) end)
    ensure_fake_s3!()
    SalixAgent.TestSupport.stop_all_agents()

    previous =
      for {app, key} <- [
            {:salix_store, :s3_backend},
            {:salix_agent, :im_provider_mod},
            {:salix_agent, :llm},
            {:comma_core, :salix_client},
            {:comma_core, :task_share_rate_limit},
            {:comma_web, :api_token},
            {:salix_im, :conversation_notifier}
          ],
          do: {app, key, Application.get_env(app, key)}

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:comma_web, :api_token, @admin_token)
    Application.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    Application.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)
    # Fresh buckets per test: every test shares the loopback peer.
    Application.put_env(:comma_core, :task_share_rate_limit,
      peer: [burst: 10_000, rate: 1_000.0],
      share: [burst: 10_000, rate: 1_000.0]
    )

    CommaWeb.Application.register_im_notifier()
    start_supervised!(Mock)
    Application.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      for {app, key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    :ok
  end

  test "a public link shows the Task and its artifacts up to the cutoff until it is revoked" do
    %{workspace: workspace, session: session, task_id: task_id} = shared_task_fixture("share")
    group_id = workspace["default_group_id"]
    worker_id = workspace["default_worker_agent_id"]
    share_url = "/v1/comma/groups/#{group_id}/conversations/#{task_id}/share"

    user_req(session["token"], :get, share_url) |> expect_status(404)

    shared = user_req(session["token"], :put, share_url) |> expect_status(200)
    assert %{"url" => url, "artifact_count" => 1, "has_newer_messages" => false} = shared.body
    assert "http://127.0.0.1:5174/s/" <> token = url
    refute Map.has_key?(shared.body, "token")

    # Publishing again keeps the same link.
    assert (user_req(session["token"], :put, share_url) |> expect_status(200)).body["url"] == url

    listed =
      user_req(session["token"], :get, "/v1/comma/groups/#{group_id}/conversations")
      |> expect_status(200)

    assert Enum.find(listed.body["data"], &(&1["id"] == task_id))["shared"] == true

    summary = public_req(:get, "/v1/comma/public/shares/#{token}") |> expect_status(200)
    assert summary.body["title"] == "Quarterly report"
    assert Req.Response.get_header(summary, "cache-control") == ["no-store"]
    assert Req.Response.get_header(summary, "access-control-allow-origin") == ["*"]

    assert [%{"type" => "file", "file_name" => "report.txt", "seq" => report_seq, "index" => 1}] =
             summary.body["artifacts"]

    page = public_req(:get, "/v1/comma/public/shares/#{token}/messages") |> expect_status(200)
    assert page.body["next_after_seq"] == nil
    texts = page |> public_texts()

    assert "Here is the report." in texts
    assert "Summarize the numbers." in texts
    refute Enum.any?(texts, &String.contains?(&1, "workspace file"))
    refute Enum.any?(texts, &String.contains?(&1, "[[comma-"))
    refute Enum.any?(texts, &String.contains?(&1, "private plan"))
    refute inspect(page.body) =~ "blob_ref"
    refute inspect(page.body) =~ "/artifacts/"
    refute inspect(page.body) =~ worker_id

    for message <- page.body["messages"] do
      assert Map.keys(message) |> Enum.sort() == ["content", "created_at", "role", "seq"]
    end

    download =
      public_req(:get, "/v1/comma/public/shares/#{token}/attachments/#{report_seq}/1")
      |> expect_status(200)

    assert download.body == "report body"
    assert Req.Response.get_header(download, "content-security-policy") == ["sandbox"]

    assert Req.Response.get_header(download, "content-disposition") == [
             "attachment; filename*=UTF-8''report.txt"
           ]

    # The text block is not an artifact, and the user's own message has none.
    public_req(:get, "/v1/comma/public/shares/#{token}/attachments/#{report_seq}/0")
    |> expect_status(404)

    # A Message after the cutoff stays private until the owner updates the link.
    later_seq = send_agent_file!(workspace, task_id, "later.txt", "later body")

    assert (user_req(session["token"], :get, share_url)
            |> expect_status(200)).body[
             "has_newer_messages"
           ]

    public_req(:get, "/v1/comma/public/shares/#{token}/attachments/#{later_seq}/1")
    |> expect_status(404)

    refute "later.txt ready." in public_texts(
             public_req(:get, "/v1/comma/public/shares/#{token}/messages")
           )

    user_req(session["token"], :put, share_url) |> expect_status(200)

    assert "later.txt ready." in public_texts(
             public_req(:get, "/v1/comma/public/shares/#{token}/messages")
           )

    public_req(:get, "/v1/comma/public/shares/#{token}/attachments/#{later_seq}/1")
    |> expect_status(200)

    # Reset replaces the link; revoke removes it.
    reset =
      user_req(session["token"], :post, share_url <> "/reset") |> expect_status(200)

    assert "http://127.0.0.1:5174/s/" <> new_token = reset.body["url"]
    refute new_token == token
    public_req(:get, "/v1/comma/public/shares/#{token}") |> expect_status(404)
    public_req(:get, "/v1/comma/public/shares/#{new_token}") |> expect_status(200)

    user_req(session["token"], :delete, share_url) |> expect_status(200)
    user_req(session["token"], :delete, share_url) |> expect_status(200)
    public_req(:get, "/v1/comma/public/shares/#{new_token}") |> expect_status(404)
    public_req(:get, "/v1/comma/public/shares/#{new_token}/messages") |> expect_status(404)
  end

  test "the owner lists the Group's active shares, most recently shared first" do
    %{workspace: workspace, session: session, task_id: first_id, user: user} =
      shared_task_fixture("list")

    group_id = workspace["default_group_id"]
    second_id = create_task!(workspace, user, "Launch notes", "list-second")
    list_url = "/v1/comma/groups/#{group_id}/task-shares"
    share_url = &"/v1/comma/groups/#{group_id}/conversations/#{&1}/share"

    assert (user_req(session["token"], :get, list_url) |> expect_status(200)).body == %{
             "data" => [],
             "has_more" => false,
             "next_cursor" => nil
           }

    first = user_req(session["token"], :put, share_url.(first_id)) |> expect_status(200)
    second = user_req(session["token"], :put, share_url.(second_id)) |> expect_status(200)

    listed = user_req(session["token"], :get, list_url) |> expect_status(200)

    assert [
             %{"conversation" => %{"id" => ^second_id, "title" => "Launch notes"}} = newest,
             %{"conversation" => %{"id" => ^first_id, "title" => "Quarterly report"}} = oldest
           ] = listed.body["data"]

    assert newest["url"] == second.body["url"]
    assert oldest["url"] == first.body["url"]
    assert oldest["artifact_count"] == 1
    refute Map.has_key?(newest, "token")

    # A bounded page continues after its last share.
    page = user_req(session["token"], :get, list_url, params: [limit: 1]) |> expect_status(200)
    assert [%{"conversation" => %{"id" => ^second_id}}] = page.body["data"]
    assert page.body["has_more"]

    next =
      user_req(session["token"], :get, list_url,
        params: [limit: 1, cursor: page.body["next_cursor"]]
      )
      |> expect_status(200)

    assert [%{"conversation" => %{"id" => ^first_id}}] = next.body["data"]
    refute next.body["has_more"]

    user_req(session["token"], :get, list_url, params: [limit: 51]) |> expect_status(400)
    user_req(session["token"], :get, list_url, params: [cursor: "nope"]) |> expect_status(400)

    # A stopped link leaves the list.
    user_req(session["token"], :delete, share_url.(second_id)) |> expect_status(200)

    assert [%{"conversation" => %{"id" => ^first_id}}] =
             (user_req(session["token"], :get, list_url) |> expect_status(200)).body["data"]

    %{session: outsider} = create_workspace_session("share-list-outsider@example.com", "Outsider")
    user_req(outsider["token"], :get, list_url) |> expect_status(404)
  end

  test "only the Workspace owner shares a Task, and the link ends with their ownership" do
    %{workspace: workspace, session: session, task_id: task_id, user: user} =
      shared_task_fixture("owner")

    group_id = workspace["default_group_id"]
    share_url = "/v1/comma/groups/#{group_id}/conversations/#{task_id}/share"
    %{session: outsider} = create_workspace_session("share-outsider@example.com", "Outsider")

    user_req(outsider["token"], :put, share_url) |> expect_status(404)

    router_chat =
      user_req(session["token"], :post, "/v1/comma/groups/#{group_id}/assistant-chat", json: %{})
      |> expect_status(200)

    user_req(
      session["token"],
      :put,
      "/v1/comma/groups/#{group_id}/conversations/#{router_chat.body["id"]}/share"
    )
    |> expect_status(404)

    "http://127.0.0.1:5174/s/" <> token =
      (user_req(session["token"], :put, share_url) |> expect_status(200)).body["url"]

    public_req(:get, "/v1/comma/public/shares/#{token}") |> expect_status(200)

    Comma.Repo.update_all(
      from(m in Comma.Data.WorkspaceMembership,
        where: m.workspace_id == ^workspace["id"] and m.user_id == ^user["id"]
      ),
      set: [status: "removed"]
    )

    public_req(:get, "/v1/comma/public/shares/#{token}") |> expect_status(404)
    public_req(:get, "/v1/comma/public/shares/not-a-token") |> expect_status(404)
  end

  test "private text and other Tasks stay out of a public link across content blocks" do
    %{workspace: workspace, session: session, task_id: task_id, user: user} =
      shared_task_fixture("private-blocks")

    group_id = workspace["default_group_id"]
    text = &%{"type" => "text", "text" => &1}

    # A protocol marker hides the rest of the Message, including later blocks.
    # The file after it keeps its original block index.
    protocol_seq =
      send_agent_content!(
        workspace,
        task_id,
        "protocol-across-blocks",
        [text.("Visible [[comma-protocol]] PRIVATE-PROTOCOL-A"), text.("PRIVATE-PROTOCOL-B")],
        {"kept.txt", "kept body"}
      )

    # A `comma:` fence stays private until the block that closes it.
    send_agent_content!(workspace, task_id, "fence-across-blocks", [
      text.("Before ```comma:plan\nPRIVATE-FENCE-A"),
      text.("PRIVATE-FENCE-B\n```\nAfter the fence.")
    ])

    assert {:ok, _} =
             SalixIM.ConversationServer.append_group_conversation_message(group_id, task_id, %{
               "actor_type" => "user",
               "user_id" => user["id"],
               "content" =>
                 "See [Secret launch plan](comma:task/cnv1_secret123) and comma:task/cnv1_bare456 next.",
               "delivery_filter" => %{"participant_ids" => []}
             })

    "http://127.0.0.1:5174/s/" <> token =
      user_req(
        session["token"],
        :put,
        "/v1/comma/groups/#{group_id}/conversations/#{task_id}/share"
      )
      |> expect_status(200)
      |> then(& &1.body["url"])

    page = public_req(:get, "/v1/comma/public/shares/#{token}/messages") |> expect_status(200)
    body = inspect(page.body)

    for secret <- ~w(PRIVATE-PROTOCOL PRIVATE-FENCE Secret cnv1_secret123 cnv1_bare456 comma:task) do
      refute body =~ secret
    end

    texts = public_texts(page)
    assert "Visible" in texts
    assert "Before" in texts
    assert "After the fence." in texts

    mention =
      Enum.find(page.body["messages"], &("See" in public_texts(%{body: %{"messages" => [&1]}})))

    assert mention["content"] == [
             %{"type" => "text", "text" => "See"},
             %{"type" => "task_ref"},
             %{"type" => "text", "text" => "and"},
             %{"type" => "task_ref"},
             %{"type" => "text", "text" => "next."}
           ]

    protocol = Enum.find(page.body["messages"], &(&1["seq"] == protocol_seq))

    assert [%{"type" => "text", "text" => "Visible"}, %{"type" => "file", "index" => 2}] =
             protocol["content"]

    assert (public_req(:get, "/v1/comma/public/shares/#{token}/attachments/#{protocol_seq}/2")
            |> expect_status(200)).body == "kept body"
  end

  test "public reads are rate limited per peer and fail closed" do
    Application.put_env(:comma_core, :task_share_rate_limit,
      peer: [burst: 1, rate: 0.001],
      share: [burst: 10_000, rate: 1_000.0]
    )

    # A fresh peer bucket would be shared with other tests, so use a new key.
    peer = {:test_peer, System.unique_integer([:positive])}
    assert Comma.TaskShares.RateLimit.check(peer, :invalid) == :allow
    assert {:deny, retry_after} = Comma.TaskShares.RateLimit.check(peer, :invalid)
    assert retry_after > 0

    Application.put_env(:comma_core, :task_share_rate_limit, peer: [burst: 0, rate: 1.0])
    assert {:unavailable, _} = Comma.TaskShares.RateLimit.check(peer, :invalid)
  end

  test "the public projection keeps only visible user and Agent content" do
    internal = %{
      "seq" => 1,
      "actor_type" => "system",
      "kind" => "message",
      "agent_input" => %{"x" => 1},
      "content" => [%{"type" => "text", "text" => "internal"}]
    }

    event = %{
      "seq" => 2,
      "actor_type" => "agent",
      "kind" => "app_event",
      "content" => [%{"type" => "text", "text" => "event"}]
    }

    context = %{
      "seq" => 3,
      "actor_type" => "user",
      "content" => "  [[comma-context]] hidden"
    }

    widget = %{
      "seq" => 4,
      "actor_type" => "agent",
      "kind" => "message",
      "agent_id" => "agent",
      "content" => [
        %{"type" => "dynamic_ui", "summary" => "Weather: 27 °C", "ui_ref" => "x"},
        %{"type" => "conversation_ref", "conversation_id" => "c_other", "title" => "Secret"},
        %{"type" => "local_file", "display_name" => "mine.pdf"},
        %{
          "type" => "text",
          "text" => "Done.\n```comma:plan\nprivate\n```\n[[comma-protocol]] tail"
        }
      ]
    }

    assert Comma.TaskShares.public_message(internal) == []
    assert Comma.TaskShares.public_message(event) == []
    assert Comma.TaskShares.public_message(context) == []

    assert [
             %{
               "role" => "assistant",
               "content" => [
                 %{"type" => "text", "text" => "Weather: 27 °C"},
                 %{"type" => "task_ref"},
                 %{"type" => "text", "text" => "Done."}
               ]
             }
           ] = Comma.TaskShares.public_message(widget)
  end

  defp shared_task_fixture(prefix) do
    %{workspace: workspace, session: session, user: user} =
      create_workspace_session("#{prefix}-task-share@example.com", "Task Share")

    group_id = workspace["default_group_id"]
    task_id = create_task!(workspace, user, "Quarterly report", "#{prefix}-task")

    for content <- [
          "[[comma-context]] private plan",
          "See this.\n\nAttached files in your workspace:\n- a.txt (workspace file: /uploads/a.txt)"
        ] do
      assert {:ok, _} =
               SalixIM.ConversationServer.append_group_conversation_message(group_id, task_id, %{
                 "actor_type" => "user",
                 "user_id" => user["id"],
                 "content" => content,
                 "delivery_filter" => %{"participant_ids" => []}
               })
    end

    send_agent_file!(workspace, task_id, "report.txt", "report body", "Here is the report.")
    %{workspace: workspace, session: session, user: user, task_id: task_id}
  end

  defp create_task!(workspace, user, title, request_id) do
    group_id = workspace["default_group_id"]

    assert {:ok, task} =
             SalixCluster.TaskSchedules.create_task_conversation(
               group_id,
               workspace["router_agent_id"],
               workspace["default_worker_agent_id"],
               %{
                 "title" => title,
                 "content" => "Summarize the numbers.",
                 "client_request_id" => request_id
               }
             )

    task_id = task["conversation_id"]

    assert {:ok, _participant} =
             SalixIM.ConversationServer.ensure_group_conversation_user_participant(
               group_id,
               task_id,
               %{
                 "user_id" => user["id"],
                 "state" => "active",
                 "notification_filter" => %{"messages" => "none", "statuses" => "none"}
               }
             )

    task_id
  end

  defp send_agent_file!(workspace, task_id, name, body, text \\ nil) do
    text_blocks = [
      %{"type" => "text", "text" => text || "#{name} ready. [[comma-protocol]] private"}
    ]

    send_agent_content!(workspace, task_id, "send-" <> name, text_blocks, {name, body})
  end

  # Appends one Agent Message: the given blocks, then an optional VFS file.
  defp send_agent_content!(workspace, task_id, request_id, blocks, file \\ nil) do
    worker_id = workspace["default_worker_agent_id"]

    file_blocks =
      case file do
        {name, body} ->
          path = "/artifacts/" <> name
          seed_agent_vfs!(worker_id, %{path => body})

          [
            %{
              "type" => "file",
              "path" => path,
              "file_name" => name,
              "mime_type" => "text/plain",
              "size" => byte_size(body)
            }
          ]

        nil ->
          []
      end

    assert {:ok, content} =
             SalixIM.ConversationAttachments.bind_sender_files(worker_id, blocks ++ file_blocks)

    assert {:ok, %{"message_id" => message_id}} =
             SalixIM.ConversationServer.append_group_conversation_agent_message(
               workspace["default_group_id"],
               task_id,
               worker_id,
               %{
                 "client_request_id" => request_id,
                 "content" => content,
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    assert {:ok, message} =
             SalixIM.Conversations.get_group_conversation_message(
               workspace["default_group_id"],
               task_id,
               message_id
             )

    message["seq"]
  end

  defp public_texts(response) do
    for message <- response.body["messages"],
        %{"type" => "text", "text" => text} <- message["content"],
        do: text
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

  defp seed_agent_vfs!(agent_id, files) do
    events =
      Enum.map(files, fn {path, body} ->
        assert {:ok, event} = SalixAgent.AgentWorkspace.prepare_write(agent_id, path, body)
        event
      end)

    assert {:ok, _result} =
             SalixAgent.AgentWorkspace.seed_operation(
               agent_id,
               "task-share-test:" <> Integer.to_string(System.unique_integer([:positive])),
               %{},
               events
             )
  end

  defp admin_req(method, path, opts),
    do: req([{"authorization", "Bearer " <> @admin_token}], method, path, opts)

  defp user_req(token, method, path, opts \\ []),
    do: req([{"authorization", "Bearer " <> token}], method, path, opts)

  defp public_req(method, path), do: req([], method, path, [])

  defp req(headers, method, path, opts) do
    Req.request!(
      [
        method: method,
        url: CommaWeb.Application.base_url() <> path,
        headers: headers,
        retry: false
      ] ++
        opts
    )
  end

  defp expect_status(resp, status) do
    assert resp.status == status, inspect(resp.body)
    resp
  end

  defp ensure_fake_s3! do
    if Process.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)
  end
end
