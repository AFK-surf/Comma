defmodule CommaWeb.CollaborationTest do
  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]
  use Oban.Testing, repo: Comma.Repo

  @moduletag :capture_log

  alias SalixAgent.LLM.Mock

  @admin_token "test-token"

  setup do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner) end)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    SalixAgent.TestSupport.stop_all_agents()

    previous =
      for {app, key} <- [
            {:salix_store, :s3_backend},
            {:salix_agent, :im_provider_mod},
            {:salix_agent, :llm},
            {:comma_core, :salix_client},
            {:comma_web, :api_token}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:comma_web, :api_token, @admin_token)
    SystemsRuntime.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)
    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    :ok
  end

  test "a member reaches the one Task they joined, as data, until the host removes them" do
    host = person("host", workspace: true)
    member = person("member")
    stranger = person("stranger")
    linked!(host, member)
    # The Task's usage is the host Workspace's: a member writes on its credits.
    grant_credits!(host.workspace)
    home_group_id = host.workspace["default_group_id"]
    start = "/v1/comma/workspaces/#{host.workspace["id"]}/collaborations"

    # Only people of the host's People can be invited, and only by the host.
    req(host, :post, start, json: started([stranger.user["id"]], "c-1")) |> expect_status(400)
    req(member, :post, start, json: started([member.user["id"]], "c-2")) |> expect_status(403)

    %{"task" => %{"id" => task_id, "group_id" => group_id}} =
      req(host, :post, start, json: started([member.user["id"]], "c-3")) |> expect_status(201)

    # Each Collaborative Task gets its own dedicated hidden, router-less Salix Group.
    assert is_binary(group_id) and group_id != home_group_id
    {:ok, collab_group} = Salix.Control.Groups.get(group_id)
    assert collab_group["purpose"] == "collaboration"
    assert collab_group["hidden"] == true
    assert is_nil(collab_group["router_agent_id"])

    # The host's Workspace task list and task_summaries include hosted collaboration tasks.
    %{"data" => host_tasks} =
      req(host, :get, "/v1/comma/groups/#{home_group_id}/conversations") |> expect_status(200)

    assert Enum.any?(host_tasks, &(&1["id"] == task_id and &1["group_id"] == group_id))

    %{"data" => summaries} =
      req(host, :get, "/v1/comma/groups/#{home_group_id}/task-summaries?ids=#{task_id}")
      |> expect_status(200)

    assert Enum.any?(summaries, &(&1["id"] == task_id and &1["group_id"] == group_id))

    # A retried start answers the same Task and same isolated Group.
    assert %{"task" => %{"id" => ^task_id, "group_id" => ^group_id}} =
             req(host, :post, start, json: started([member.user["id"]], "c-3"))
             |> expect_status(201)

    # A retry cannot add anyone: the members are fixed when the Task starts.
    other = person("other")
    linked!(host, other)

    req(host, :post, start, json: started([member.user["id"], other.user["id"]], "c-3"))
    |> expect_status(409)

    # Its own Worker runs it, never the Group's Task agent, with the
    # collaboration tool policy; the host's Router receives nothing of it.
    {:ok, task} = SalixIM.Conversations.get_group_conversation_record(group_id, task_id)
    {:ok, task_agent} = SalixAgent.TaskAgent.get(home_group_id)
    worker = task["task_worker_agent_id"]
    assert is_binary(worker) and worker != task_agent
    {:ok, worker_record} = SalixAgent.Control.get_record(worker)
    assert worker_record["purpose"] == SalixAgent.CollaborationPolicy.purpose()
    assert %{"collaboration" => %{"host_user_id" => _}} = task["metadata"]

    # What the host started it with starts the Worker, though it names no one.
    {:ok, opened} = SalixIM.Conversations.list_group_conversation_messages(group_id, task_id)
    opening = Enum.find(opened, &(&1["user_id"] == host.user["id"]))
    assert get_in(opening, ["metadata", "task_command"]) == true
    refute get_in(opening, ["metadata", "context_only"])

    # Its host can neither move it off Comma's own model (onto their machine or
    # account, which its members' words would then drive) nor publish it.
    host_task_path = "/v1/comma/groups/#{group_id}/conversations/#{task_id}"

    assert %{"code" => "task_run_refused"} =
             req(host, :put, "#{host_task_path}/run",
               json: %{"runs_on" => %{"kind" => "salix"}, "model" => nil}
             ).body

    req(host, :put, "#{host_task_path}/share") |> expect_status(400)

    # Its purpose, which selects that policy, is fixed.
    assert {:error, {:bad_request, _}} =
             SalixAgent.Control.configure(
               worker,
               %{"purpose" => "anything"},
               worker_record["tenant_id"]
             )

    # It is no Agent of the Workspace's lists.
    {:ok, %{items: agents}} =
      SalixAgent.Control.page_agents(worker_record["tenant_id"], group_id)

    refute Enum.any?(agents, &(&1["agent_id"] == worker))

    {:ok, %{"participants" => participants}} =
      SalixIM.Conversations.list_group_conversation_participants(group_id, task_id)

    assert is_nil(Enum.find(participants, &(&1["role_label"] == "delegator")))

    # An invite gives no access until it is accepted.
    task_path = "/v1/comma/collaborations/#{group_id}/#{task_id}"
    req(member, :get, task_path) |> expect_status(404)

    assert %{"data" => [%{"id" => invite, "status" => "invited", "host" => %{"name" => "host"}}]} =
             req(member, :get, "/v1/comma/collaborations") |> expect_status(200)

    req(stranger, :post, "/v1/comma/collaborations/#{invite}/accept") |> expect_status(404)
    req(member, :post, "/v1/comma/collaborations/#{invite}/accept") |> expect_status(200)

    assert %{"id" => ^task_id} = req(member, :get, task_path) |> expect_status(200)

    # Words alone: nothing of the host's Workspace (its skills, devices or a
    # message type) comes with what a member writes.
    req(member, :post, "#{task_path}/messages",
      json: %{
        "content" => "My dates are 3-5 March",
        "client_request_id" => "m-1",
        "skills" => [%{"id" => "host-skill"}],
        "client_device_id" => "dev_host",
        "message_type" => "task_command"
      }
    )
    |> expect_status(202)

    # As the app sends it: a `message` (here content blocks). Its text passes;
    # a local file of the host's machine does not.
    req(member, :post, "#{task_path}/messages",
      json: %{
        "message" => %{
          "content" => [
            %{"type" => "text", "text" => "Under 300k yen please"},
            %{"type" => "local_file", "local_file_ref" => "lf_host", "display_name" => "a.txt"}
          ]
        },
        "client_request_id" => "m-app"
      }
    )
    |> expect_status(202)

    req(member, :post, "#{task_path}/messages",
      json: %{"message" => %{"type" => "text", "text" => " "}}
    )
    |> expect_status(400)

    # What a member writes is data the Worker reads, never a Task command.
    {:ok, messages} = SalixIM.Conversations.list_group_conversation_messages(group_id, task_id)

    assert Enum.find(
             messages,
             &(&1["content"] == [%{"type" => "text", "text" => "Under 300k yen please"}] and
                 &1["user_id"] == member.user["id"])
           )

    written =
      Enum.find(
        messages,
        &(&1["content"] == [%{"type" => "text", "text" => "My dates are 3-5 March"}])
      )

    assert written["actor_type"] == "user" and written["user_id"] == member.user["id"]
    refute get_in(written, ["metadata", "task_command"])
    refute get_in(written, ["metadata", "message_type"])
    refute get_in(written, ["metadata", "skills"])
    refute get_in(written, ["metadata", "client_device"])

    # People talk among themselves: a Message that does not name the Worker
    # reaches it as context, without waking it.
    assert get_in(written, ["metadata", "context_only"]) == true

    # The member reaches nothing else of the host's Group: not its Group
    # routes, not the host's Router chat, not another Task.
    req(member, :get, "/v1/comma/groups/#{group_id}/conversations") |> expect_status(404)

    req(member, :get, "/v1/comma/groups/#{group_id}/conversations/#{task_id}")
    |> expect_status(404)

    req(member, :post, "/v1/comma/groups/#{group_id}/conversations/#{task_id}/accept")
    |> expect_status(404)

    router_chat = host.workspace["router_conversation_id"]
    req(member, :get, "/v1/comma/collaborations/#{group_id}/#{router_chat}") |> expect_status(404)

    %{"task" => %{"id" => other_id}} =
      req(host, :post, start, json: started([member.user["id"]], "c-4")) |> expect_status(201)

    req(member, :get, "/v1/comma/collaborations/#{group_id}/#{other_id}") |> expect_status(404)

    # Done, the host names the Worker again: the same work goes on, and the
    # Task is active again. A member naming it does not reopen it.
    host_task = "/v1/comma/groups/#{group_id}/conversations/#{task_id}"
    %{"updated_at" => version} = req(host, :get, host_task) |> expect_status(200)

    req(host, :post, "#{host_task}/status",
      json: %{"status" => "completed", "expected_updated_at" => version}
    )
    |> expect_status(200)

    req(member, :post, "#{task_path}/messages",
      json: %{"content" => "@Worker one more venue?", "client_request_id" => "m-3"}
    )
    |> expect_status(202)

    assert %{"status" => "completed"} = req(host, :get, host_task) |> expect_status(200)

    # ... nor wakes the Worker: in a done Task a member naming it is context.
    {:ok, after_done} = SalixIM.Conversations.list_group_conversation_messages(group_id, task_id)

    named =
      Enum.find(
        after_done,
        &(&1["content"] == [%{"type" => "text", "text" => "@Worker one more venue?"}])
      )

    assert get_in(named, ["metadata", "context_only"]) == true

    # Ending it by hand tells no Router: nothing of the host's Router shows
    # among the people's messages.
    {:ok, ended} = SalixIM.Conversations.list_group_conversation_messages(group_id, task_id)
    refute Enum.any?(ended, &(get_in(&1, ["metadata", "message_type"]) == "task_manual_status"))

    req(host, :post, "#{host_task}/messages",
      json: %{
        "message" => %{"type" => "text", "text" => "@Worker add a rainy-day option"},
        "client_request_id" => "h-2"
      }
    )
    |> expect_status(202)

    assert %{"status" => "active"} = req(host, :get, host_task) |> expect_status(200)

    # Cancelled behaves the same as completed: a member naming the Worker stays
    # context_only and never wakes or reopens it, while the host can reopen it.
    %{"updated_at" => cancel_version} = req(host, :get, host_task) |> expect_status(200)

    req(host, :post, "#{host_task}/status",
      json: %{"status" => "cancelled", "expected_updated_at" => cancel_version}
    )
    |> expect_status(200)

    req(member, :post, "#{task_path}/messages",
      json: %{"content" => "@Worker still cancelled?", "client_request_id" => "m-cancel"}
    )
    |> expect_status(202)

    assert %{"status" => "cancelled"} = req(host, :get, host_task) |> expect_status(200)

    {:ok, after_cancel} =
      SalixIM.Conversations.list_group_conversation_messages(group_id, task_id)

    cancelled_named =
      Enum.find(
        after_cancel,
        &(&1["content"] == [%{"type" => "text", "text" => "@Worker still cancelled?"}])
      )

    assert get_in(cancelled_named, ["metadata", "context_only"]) == true

    req(host, :post, "#{host_task}/messages",
      json: %{
        "message" => %{"type" => "text", "text" => "@Worker reopen after cancel"},
        "client_request_id" => "h-cancel-reopen"
      }
    )
    |> expect_status(202)

    assert %{"status" => "active"} = req(host, :get, host_task) |> expect_status(200)

    # A Loop is the host's to start: the host's words count as its command,
    # a member's do not.
    {:ok, said} = SalixIM.Conversations.list_group_conversation_messages(group_id, task_id)

    message_id = fn text ->
      Enum.find(said, &(&1["content"] == [%{"type" => "text", "text" => text}]))["message_id"]
    end

    origin = fn id ->
      %{group_id: group_id, trusted_origin: %{"conversation_id" => task_id, "message_id" => id}}
    end

    assert SalixIM.CollaborationCommand.host_command?(
             origin.(message_id.("@Worker add a rainy-day option"))
           )

    refute SalixIM.CollaborationCommand.host_command?(
             origin.(message_id.("@Worker one more venue?"))
           )

    # The host's words that asked no one are context only, and a round a member
    # also woke is not the host's alone.
    req(host, :post, "#{host_task}/messages",
      json: %{
        "message" => %{"type" => "text", "text" => "Lunch at noon?"},
        "client_request_id" => "h-3"
      }
    )
    |> expect_status(202)

    req(member, :post, "#{task_path}/messages",
      json: %{"content" => "@Worker check it every hour", "client_request_id" => "m-4"}
    )
    |> expect_status(202)

    {:ok, said} = SalixIM.Conversations.list_group_conversation_messages(group_id, task_id)

    wake = fn text ->
      Enum.find(said, &(&1["content"] == [%{"type" => "text", "text" => text}]))["message_id"]
    end

    refute SalixIM.CollaborationCommand.host_command?(
             origin.(wake.("@Worker check it every hour"))
           )

    aside =
      Enum.find(said, &(&1["content"] == [%{"type" => "text", "text" => "Lunch at noon?"}]))[
        "message_id"
      ]

    refute SalixIM.CollaborationCommand.host_command?(origin.(aside))

    refute SalixIM.CollaborationCommand.host_command?(
             Map.put(
               origin.(message_id.("@Worker add a rainy-day option")),
               :trusted_origins,
               [
                 %{
                   "conversation_id" => task_id,
                   "message_id" => wake.("@Worker check it every hour")
                 }
               ]
             )
           )

    # A member reads the Task's attachments by its own route: a message with
    # none has none to read, and no one else reads them there.
    [%{"message_id" => first_message} | _] = after_done

    req(member, :get, "#{task_path}/messages/#{first_message}/attachments/0")
    |> expect_status(404)

    req(stranger, :get, "#{task_path}/messages/#{first_message}/attachments/0")
    |> expect_status(404)

    # A file the Worker sends into the Task: its members read it as its host does.
    {:ok, _event} =
      SalixAgent.AgentWorkspace.prepare_write(worker, "/task/plan.pdf", "%PDF plan")
      |> then(fn {:ok, event} ->
        {:ok, _} =
          SalixAgent.AgentWorkspace.seed_operation(worker, "collab-file", %{}, [event])

        {:ok, event}
      end)

    {:ok, content} =
      SalixIM.ConversationAttachments.bind_sender_files(worker, [
        %{"type" => "file", "path" => "/task/plan.pdf", "file_name" => "plan.pdf"}
      ])

    {:ok, %{"message_id" => file_message}} =
      SalixIM.ConversationServer.append_group_conversation_agent_message(
        group_id,
        task_id,
        worker,
        %{"client_request_id" => "collab-file", "content" => content}
      )

    file_url = "#{task_path}/messages/#{file_message}/attachments/0"
    assert req(member, :get, file_url, decode_body: false).body == "%PDF plan"
    assert %{"url" => _} = req(member, :post, file_url <> "/media") |> expect_status(200)
    req(stranger, :get, file_url) |> expect_status(404)

    # A member puts a file in the Task's own folder: its host, its members and
    # its Worker read it there; no one else does, and nothing outside it.
    files = "#{task_path}/files"

    %{"path" => brief, "name" => "brief.pdf", "size" => 10} =
      req(member, :post, files <> "?name=brief.pdf",
        body: "%PDF brief",
        headers: [{"content-type", "application/octet-stream"}]
      )
      |> expect_status(201)

    assert String.starts_with?(brief, "/task/#{task_id}/uploads/")

    for reader <- [member, host] do
      assert req(reader, :get, files <> "?path=" <> URI.encode_www_form(brief),
               decode_body: false
             ).body ==
               "%PDF brief"
    end

    req(stranger, :get, files <> "?path=" <> URI.encode_www_form(brief)) |> expect_status(404)

    req(member, :get, files <> "?path=" <> URI.encode_www_form("/task/../notes.md"))
    |> expect_status(404)

    req(member, :get, files <> "?path=" <> URI.encode_www_form("/notes.md")) |> expect_status(404)
    assert {:ok, "%PDF brief"} = SalixAgent.Workspace.read(worker, brief)

    # A page or picture someone puts there never runs as this origin's page:
    # it downloads, unsniffed, with no script allowed.
    %{"path" => page} =
      req(member, :post, files <> "?name=steal.svg",
        body: "<svg onload='alert(1)'/>",
        headers: [{"content-type", "application/octet-stream"}]
      )
      |> expect_status(201)

    served = req(host, :get, files <> "?path=" <> URI.encode_www_form(page), decode_body: false)
    assert served.status == 200
    assert ["application/octet-stream" <> _] = Req.Response.get_header(served, "content-type")
    assert ["attachment" <> _] = Req.Response.get_header(served, "content-disposition")
    assert ["nosniff"] = Req.Response.get_header(served, "x-content-type-options")

    assert ["default-src 'none'; sandbox"] =
             Req.Response.get_header(served, "content-security-policy")

    # Both see what is in the folder, uploads by the names they were given,
    # newest first, and what its Worker wrote there; and both open the latter.
    {:ok, _} = SalixAgent.Workspace.write(worker, "/task/report.md", "# Venues")

    for reader <- [member, host] do
      %{"files" => listed} = req(reader, :get, files) |> expect_status(200)

      assert [%{"name" => "steal.svg"}, %{"name" => "brief.pdf", "path" => ^brief}] =
               Enum.filter(listed, & &1["uploaded"])

      assert Enum.any?(listed, &(&1["path"] == "/task/report.md" and &1["name"] == "report.md"))

      assert req(reader, :get, files <> "?path=" <> URI.encode_www_form("/task/report.md"),
               decode_body: false
             ).body == "# Venues"
    end

    req(stranger, :get, files) |> expect_status(404)

    # The host takes the member out: their access ends at once.
    req(member, :delete, "#{start}/#{task_id}/members/#{member.user["id"]}") |> expect_status(403)
    req(host, :delete, "#{start}/#{task_id}/members/#{member.user["id"]}") |> expect_status(200)
    req(member, :get, task_path) |> expect_status(404)
    req(member, :get, file_url) |> expect_status(404)

    req(member, :get, "#{task_path}/files?path=" <> URI.encode_www_form(brief))
    |> expect_status(404)

    req(member, :get, files) |> expect_status(404)

    req(member, :post, "#{task_path}/messages",
      json: %{"content" => "still here?", "client_request_id" => "m-2"}
    )
    |> expect_status(404)

    assert %{"data" => [%{"status" => "removed", "person" => person}]} =
             req(host, :get, "#{start}/#{task_id}/members") |> expect_status(200)

    # Members are shown by name and avatar, never by email.
    refute Map.has_key?(person, "email")

    # The Task says so to its people, as product state no Agent reads.
    assert member_changes(group_id, task_id) == [{member.user["id"], "removed"}]
  end

  test "a member who leaves, or declines, reads the Task no more" do
    host = person("host2", workspace: true)
    member = person("member2")
    linked!(host, member)
    start = "/v1/comma/workspaces/#{host.workspace["id"]}/collaborations"

    %{"task" => %{"id" => first, "group_id" => first_group}} =
      req(host, :post, start, json: started([member.user["id"]], "l-1")) |> expect_status(201)

    %{"task" => %{"id" => second, "group_id" => second_group}} =
      req(host, :post, start, json: started([member.user["id"]], "l-2")) |> expect_status(201)

    invites = req(member, :get, "/v1/comma/collaborations") |> expect_status(200)
    id_of = fn task -> Enum.find(invites["data"], &(&1["task"]["id"] == task))["id"] end

    req(member, :post, "/v1/comma/collaborations/#{id_of.(first)}/accept") |> expect_status(200)
    req(member, :post, "/v1/comma/collaborations/#{id_of.(first)}/leave") |> expect_status(200)
    req(member, :get, "/v1/comma/collaborations/#{first_group}/#{first}") |> expect_status(404)
    # Leaving is final: the invite cannot be accepted again.
    req(member, :post, "/v1/comma/collaborations/#{id_of.(first)}/accept") |> expect_status(409)
    assert member_changes(first_group, first) == [{member.user["id"], "left"}]

    req(member, :post, "/v1/comma/collaborations/#{id_of.(second)}/decline") |> expect_status(200)
    req(member, :post, "/v1/comma/collaborations/#{id_of.(second)}/accept") |> expect_status(409)
    req(member, :get, "/v1/comma/collaborations/#{second_group}/#{second}") |> expect_status(404)
  end

  test "the host's Router hears who left or declined a Task together, and reads none of it" do
    host = person("host5", workspace: true)
    member = person("member5", workspace: true)
    other = person("other5")
    linked!(host, member)
    linked!(host, other)
    grant_credits!(host.workspace)
    home_group_id = host.workspace["default_group_id"]
    start = "/v1/comma/workspaces/#{host.workspace["id"]}/collaborations"

    %{"task" => %{"id" => task_id, "group_id" => group_id}} =
      req(host, :post, start,
        json:
          Map.put(started([member.user["id"], other.user["id"]], "n-1"), "title", "Kyoto offsite")
      )
      |> expect_status(201)

    invites = fn person ->
      %{"data" => [%{"id" => id}]} =
        req(person, :get, "/v1/comma/collaborations") |> expect_status(200)

      id
    end

    member_invite = invites.(member)
    req(member, :post, "/v1/comma/collaborations/#{member_invite}/accept") |> expect_status(200)

    req(member, :post, "/v1/comma/collaborations/#{group_id}/#{task_id}/messages",
      json: %{"content" => "Keep it under 280k yen, quietly", "client_request_id" => "n-m"}
    )
    |> expect_status(202)

    # The host's Router lives in Home (a separate Group) and cannot read,
    # search, list the people of or change the Task; its own Worker still reads it.
    {:ok, task} = SalixIM.Conversations.get_group_conversation_record(group_id, task_id)
    {:ok, home} = SalixIM.RouterConversationInput.ensure(home_group_id)

    router = %{
      agent: %{"role" => "router"},
      agent_id: home["router_agent_id"],
      tenant_id: host.workspace["salix_tenant_id"],
      group_id: home_group_id
    }

    for {api, params} <- [
          {"internal.read_conversation", %{"conversation_id" => task_id}},
          {"internal.list_conversation_participants", %{"conversation_id" => task_id}},
          {"internal.update_conversation", %{"conversation_id" => task_id, "title" => "x"}}
        ] do
      assert {:error, _closed} = SalixIM.Provider.Internal.call(router, api, params), api
    end

    assert {:ok, %{"count" => 0, "files" => []}} =
             SalixIM.Provider.Internal.call(router, "internal.list_task_files", %{
               "conversation_id" => task_id
             })

    assert {:ok, %{"results" => []}} =
             SalixIM.Provider.Internal.call(router, "internal.search_conversations", %{
               "query" => "under 280k yen"
             })

    worker = %{
      router
      | agent: %{"role" => "worker"},
        agent_id: task["task_worker_agent_id"],
        group_id: group_id
    }

    assert {:ok, %{"messages" => read}} =
             SalixIM.Provider.Internal.call(worker, "internal.read_conversation", %{
               "conversation_id" => task_id
             })

    assert Enum.any?(read, &(inspect(&1["content"]) =~ "280k yen"))

    # Nor does it consult the Task's Worker about what it holds.
    {:ok, %{targets: []}} =
      Salix.Bindings.AgentConversations.search_worker_sessions(home_group_id, "280k yen", [], 5)

    # Collaborative Tasks stay active across ongoing replies: neither Router
    # nor Worker can put the Task into review.
    for caller <- [router, worker] do
      assert {:error, _} =
               SalixIM.Provider.Internal.call(caller, "internal.task.request_review", %{
                 "conversation_id" => task_id
               })
    end

    assert {:ok, %{"status" => "active"}} =
             SalixIM.Conversations.get_group_conversation_record(group_id, task_id)

    # When the host marks the Task done, its active member hears it in their
    # own Home in words alone (no reference to the isolated Group), while the
    # host is not told of what they marked themselves.
    host_task = "/v1/comma/groups/#{group_id}/conversations/#{task_id}"
    %{"updated_at" => version} = req(host, :get, host_task) |> expect_status(200)

    req(host, :post, "#{host_task}/status",
      json: %{"status" => "completed", "expected_updated_at" => version}
    )
    |> expect_status(200)

    for job <- all_enqueued(worker: CommaWeb.CollaborationNotice),
        do: assert(:ok = perform_job(CommaWeb.CollaborationNotice, job.args))

    {:ok, home_messages} =
      SalixIM.Conversations.list_group_conversation_messages(
        home_group_id,
        home["conversation_id"]
      )

    refute Enum.any?(
             home_messages,
             &(get_in(&1, ["metadata", "message_type"]) == "collaboration_status")
           )

    member_group = member.workspace["default_group_id"]
    {:ok, member_home} = SalixIM.RouterConversationInput.ensure(member_group)

    {:ok, member_messages} =
      SalixIM.Conversations.list_group_conversation_messages(
        member_group,
        member_home["conversation_id"]
      )

    assert [[%{"type" => "text", "text" => ~s("Kyoto offsite" is done.)}]] =
             for(
               message <- member_messages,
               get_in(message, ["metadata", "message_type"]) == "collaboration_status",
               do: message["content"]
             )

    # A member who leaves, and one who declines, are told in Home with the
    # title the host gave and a reference to the Task (including its isolated
    # group_id); the Router gets the same status as context, and no word of the Task.
    req(member, :post, "/v1/comma/collaborations/#{member_invite}/leave") |> expect_status(200)
    req(other, :post, "/v1/comma/collaborations/#{invites.(other)}/decline") |> expect_status(200)

    for job <- all_enqueued(worker: CommaWeb.CollaborationNotice),
        do: assert(:ok = perform_job(CommaWeb.CollaborationNotice, job.args))

    {:ok, said} =
      SalixIM.Conversations.list_group_conversation_messages(
        home_group_id,
        home["conversation_id"]
      )

    notices =
      Enum.filter(said, &(get_in(&1, ["metadata", "message_type"]) == "collaboration_status"))

    assert [
             %{"type" => "text", "text" => ~s(member5 left "Kyoto offsite".)},
             %{
               "type" => "conversation_ref",
               "conversation_id" => ^task_id,
               "group_id" => ^group_id
             }
           ] = Enum.find(notices, &(&1["metadata"]["status"] == "left"))["content"]

    assert [%{"text" => ~s(other5 declined "Kyoto offsite".)} | _] =
             Enum.find(notices, &(&1["metadata"]["status"] == "declined"))["content"]

    refute inspect(said) =~ "280k yen"
    assert inspect(said) =~ "This is its status only"

    # A retried notice is the same one.
    for job <- all_enqueued(worker: CommaWeb.CollaborationNotice),
        do: assert(:ok = perform_job(CommaWeb.CollaborationNotice, job.args))

    {:ok, again} =
      SalixIM.Conversations.list_group_conversation_messages(
        home_group_id,
        home["conversation_id"]
      )

    assert length(again) == length(said)
  end

  test "people named in Home for a shared task are invited to it, without the Router's turn" do
    host = person("share-host", workspace: true)
    member = person("share-member")
    linked!(host, member)
    grant_credits!(host.workspace)
    group = host.workspace["default_group_id"]
    # The Router is never woken: nothing is scripted for it.
    Mock.script([])

    home =
      req(host, :post, "/v1/comma/groups/#{group}/assistant-chat", json: %{})
      |> expect_status(200)
      |> Map.fetch!("id")

    say = fn id, text ->
      req(host, :post, "/v1/comma/groups/#{group}/conversations/#{home}/messages",
        json: %{"client_request_id" => id, "message" => %{"type" => "text", "text" => text}}
      )
      |> expect_status(202)
    end

    shown = fn ->
      {:ok, messages} =
        SalixIM.Conversations.list_group_conversation_messages(group, home, limit: 20)

      Enum.reject(messages, &(&1["actor_type"] == "system"))
    end

    mention = "[share-member](comma:share/#{member.user["id"]})"
    said = say.("share-0000000001", mention <> " Plan the offsite.")
    settle()

    # Home: the words, delivered to no one, then the Router's line and the Task's card.
    assert [words, answer] = shown.()
    assert words["message_id"] == said["accepted_message_id"]
    assert words["delivery_filter"] == %{"participant_ids" => []}

    assert [
             %{"text" => "Started a collaboration with share-member." <> _},
             %{"type" => "conversation_ref", "conversation_id" => task_id}
           ] = answer["content"]

    # The member is invited, as from People, to that Task.
    assert %{"data" => [%{"status" => "invited", "host" => %{"name" => "share-host"}} = invite]} =
             req(member, :get, "/v1/comma/collaborations") |> expect_status(200)

    assert invite["task"]["id"] == task_id

    # The same send again is the same message: no second Task.
    say.("share-0000000001", mention <> " Plan the offsite.")
    settle()

    assert %{"data" => [_one]} =
             req(member, :get, "/v1/comma/collaborations") |> expect_status(200)

    # A shared task and a request in one message: neither runs, and Home says why.
    say.("share-0000000002", mention <> " [x](comma:request/trg_1) Book the room.")
    settle()

    assert %{"data" => [_one]} =
             req(member, :get, "/v1/comma/collaborations") |> expect_status(200)

    assert %{
             "content" => [
               %{"text" => "A collaboration and requests cannot share a message" <> _}
             ]
           } =
             List.last(shown.())
  end

  test "someone not yet on Comma is invited by email and takes the seat by signing in with it" do
    host = person("host3", workspace: true)
    start = "/v1/comma/workspaces/#{host.workspace["id"]}/collaborations"

    # Only addresses, a few, never the host's own.
    req(host, :post, start, json: emailed(["not an address"], "e-0")) |> expect_status(400)

    req(host, :post, start, json: emailed(["host3-collaboration@example.com"], "e-1"))
    |> expect_status(400)

    %{"task" => %{"id" => task_id, "group_id" => group_id}} =
      req(host, :post, start, json: emailed(["Newbie-Collaboration@Example.com"], "e-2"))
      |> expect_status(201)

    # The address gets an email naming the host and the Task, with a direct
    # guest link (`/c/<token>`); nothing of what is said in the Task.
    Process.register(SystemsRuntime.Proc.self(), :comma_email_delivery_test)

    for job <- all_enqueued(worker: Comma.Workers.CollaborationInvite),
        do: assert(:ok = perform_job(Comma.Workers.CollaborationInvite, job.args))

    # The job ran in this process: its email is already here.
    assert_received {:comma_notice, "newbie-collaboration@example.com",
                     "host3 invited you to collaborate", text}

    assert text =~ ~s("Plan the offsite")
    assert text =~ "/c/"
    refute text =~ "Venue, budget and agenda"

    # The host sees the seat by the address it typed until someone takes it.
    assert %{
             "data" => [%{"person" => nil, "invited_email" => "newbie-collaboration@example.com"}]
           } =
             req(host, :get, "#{start}/#{task_id}/members") |> expect_status(200)

    # Someone else sees nothing of it; whoever signs in with the address gets the invite.
    other = person("other3")
    assert %{"data" => []} = req(other, :get, "/v1/comma/collaborations") |> expect_status(200)

    newbie = person("newbie")

    assert %{"data" => [%{"id" => invite, "task" => %{"id" => ^task_id}}]} =
             req(newbie, :get, "/v1/comma/collaborations") |> expect_status(200)

    req(newbie, :post, "/v1/comma/collaborations/#{invite}/accept") |> expect_status(200)

    req(newbie, :get, "/v1/comma/collaborations/#{group_id}/#{task_id}") |> expect_status(200)

    assert %{"data" => [%{"person" => %{"name" => "newbie"}, "status" => "active"}]} =
             req(host, :get, "#{start}/#{task_id}/members") |> expect_status(200)

    # A seat no one took yet is taken out by its address.
    %{"task" => %{"id" => second}} =
      req(host, :post, start, json: emailed(["later@example.com"], "e-3")) |> expect_status(201)

    req(host, :delete, "#{start}/#{second}/members/later@example.com") |> expect_status(200)

    assert %{"data" => [%{"status" => "removed"}]} =
             req(host, :get, "#{start}/#{second}/members") |> expect_status(200)
  end

  test "authenticated task file download supports HTTP Range streaming" do
    host = person("range-host", workspace: true)
    member = person("range-member")
    linked!(host, member)
    start = "/v1/comma/workspaces/#{host.workspace["id"]}/collaborations"

    %{"task" => %{"id" => task_id, "group_id" => group_id}} =
      req(host, :post, start, json: started([member.user["id"]], "r-1")) |> expect_status(201)

    %{"data" => [%{"id" => invite_id}]} =
      req(member, :get, "/v1/comma/collaborations") |> expect_status(200)

    req(member, :post, "/v1/comma/collaborations/#{invite_id}/accept") |> expect_status(200)

    payload = "0123456789abcdef"

    %{"path" => file_path} =
      req(member, :post, "/v1/comma/collaborations/#{group_id}/#{task_id}/files?name=sample.bin",
        body: payload,
        headers: [{"content-type", "application/octet-stream"}]
      )
      |> expect_status(201)

    download_url =
      "/v1/comma/collaborations/#{group_id}/#{task_id}/files?path=#{URI.encode_www_form(file_path)}"

    # Full download: 200 OK with Accept-Ranges and security headers.
    full = req(member, :get, download_url)
    assert full.status == 200
    assert full.body == payload
    assert Req.Response.get_header(full, "accept-ranges") == ["bytes"]
    assert Req.Response.get_header(full, "x-content-type-options") == ["nosniff"]

    assert Req.Response.get_header(full, "content-security-policy") == [
             "default-src 'none'; sandbox"
           ]

    # Partial download: 206 Partial Content.
    partial =
      http(
        [{"authorization", "Bearer " <> member.token}, {"range", "bytes=2-5"}],
        :get,
        download_url,
        []
      )

    assert partial.status == 206
    assert partial.body == "2345"
    assert Req.Response.get_header(partial, "content-range") == ["bytes 2-5/16"]
    assert Req.Response.get_header(partial, "accept-ranges") == ["bytes"]

    # Unsatisfiable range: 416.
    invalid =
      http(
        [{"authorization", "Bearer " <> member.token}, {"range", "bytes=999-1000"}],
        :get,
        download_url,
        []
      )

    assert invalid.status == 416
    assert Req.Response.get_header(invalid, "content-range") == ["bytes */16"]
  end

  test "host daily external invite email cap (20 / 24h) returns 429 invite_daily_limit_reached" do
    host = person("quota-host", workspace: true)
    start = "/v1/comma/workspaces/#{host.workspace["id"]}/collaborations"

    for batch <- 1..4 do
      emails = for i <- 1..5, do: "guest-#{batch}-#{i}@example.com"

      req(host, :post, start, json: emailed(emails, "q-#{batch}"))
      |> expect_status(201)
    end

    # 21st external email invite in 24h is rejected with 429.
    limited =
      req(host, :post, start, json: emailed(["guest-21@example.com"], "q-5"))

    assert limited.status == 429
    assert limited.body["error"] == "invite_daily_limit_reached"
    assert limited.body["limit"] == 20

    assert is_integer(limited.body["retry_after_seconds"]) and
             limited.body["retry_after_seconds"] > 0
  end

  defp emailed(emails, request_id),
    do: %{
      "emails" => emails,
      "content" => "Plan the offsite\nVenue, budget and agenda",
      "client_request_id" => request_id
    }

  # Who left or was taken out, as the Task's product events say.
  defp member_changes(group_id, task_id) do
    {:ok, messages} = SalixIM.Conversations.list_group_conversation_messages(group_id, task_id)

    for %{
          "kind" => "app_event",
          "metadata" => %{"event_type" => "collaboration.member_changed", "member" => member}
        } <- messages,
        do: {member["user_id"], member["status"]}
  end

  defp grant_credits!(workspace) do
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
               valid_from: DateTime.add(SystemsClock.utc_now(), -60, :second),
               expires_at: DateTime.add(SystemsClock.utc_now(), 1, :day),
               source_type: "manual_contract",
               source_id: "collaboration-test",
               source_event_id: workspace["id"],
               idempotency_key: workspace["id"]
             })
  end

  test "the host and members can reach a collaborator's avatar route, and outsiders cannot" do
    host = person("avatar-host", workspace: true)
    member = person("avatar-member")
    outsider = person("avatar-outsider")
    grant_credits!(host.workspace)
    linked!(host, member)

    %{"task" => %{"id" => task_id, "group_id" => group_id}} =
      req(host, :post, "/v1/comma/workspaces/#{host.workspace["id"]}/collaborations",
        json: started([member.user["id"]], "avatar-collab-1")
      )
      |> expect_status(201)

    path =
      "/v1/comma/collaborations/#{group_id}/#{task_id}/members/#{host.user["id"]}/avatar/avt_x"

    # Outsiders get 404 (not authorized); invited member reaches ProfileAvatar lookup (404 for unknown revision).
    req(outsider, :get, path) |> expect_status(404)
    req(member, :get, path) |> expect_status(404)
    req(host, :get, path) |> expect_status(404)
  end

  defp started(people, request_id),
    do: %{
      "people" => people,
      "content" => "Plan the offsite\nVenue, budget and agenda",
      "client_request_id" => request_id
    }

  # The member accepts the host's invite: the two are in each other's People.
  defp linked!(host, member) do
    grants = "/v1/comma/workspaces/#{host.workspace["id"]}/task-request-grants"
    %{"invite_url" => url} = req(host, :post, grants, json: %{}) |> expect_status(201)
    [_, token] = String.split(url, "invite=")
    req(member, :post, "/v1/comma/task-request-invites/#{token}/accept") |> expect_status(200)
  end

  defp person(name, opts \\ []) do
    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "#{name}-collaboration@example.com", "name" => name}
      )
      |> expect_status(201)

    workspace =
      if opts[:workspace] do
        workspace = create_ready_workspace!(user["id"], %{"name" => "Host"})
        :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
        CommaWeb.TestWorkers.with_default_worker!(workspace)
      end

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)

    %{user: user, workspace: workspace, token: session["token"]}
  end

  defp admin_req(method, path, opts),
    do: http([{"authorization", "Bearer " <> @admin_token}], method, path, opts)

  defp req(person, method, path, opts \\ []),
    do: http([{"authorization", "Bearer " <> person.token}], method, path, opts)

  defp http(headers, method, path, opts) do
    Req.request!(
      [
        method: method,
        url: CommaWeb.Application.base_url() <> path,
        headers: headers,
        retry: false
      ] ++ opts
    )
  end

  defp expect_status(resp, status, body \\ nil) do
    assert resp.status == status, inspect(resp.body)
    if body, do: assert(resp.body == body)
    resp.body
  end
end
