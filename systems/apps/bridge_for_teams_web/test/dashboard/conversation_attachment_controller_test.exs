defmodule BridgeForTeamsWeb.Dashboard.ConversationAttachmentControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

  alias BridgeForTeams.{Agents, Memberships, Projects}
  alias BridgeForTeams.Salix.Reconciler
  alias SalixIM.{ConversationAttachments, ConversationInput, ConversationServer}

  defmodule FaultyBlobStream do
    def read_ref_stream(_agent_id, _ref, filename) do
      {owner, mode} = SystemsRuntime.fetch_env!(:bridge_for_teams_web, :attachment_stream_fault)

      stream =
        Stream.map(1..3, fn part ->
          SystemsRuntime.Proc.send(owner, {:attachment_chunk, part})

          case {mode, part} do
            {:overflow, _} -> String.duplicate("x", 5_000_001)
            {:failure, 1} -> "partial body"
            {:failure, _} -> raise "private storage failure"
          end
        end)

      {:ok, stream, 100, filename}
    end
  end

  setup %{conn: conn} do
    %{conn: conn, org: org, user: user} = register_and_log_in_user(%{conn: conn})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Attachment review"})

    {:ok, worker} =
      BridgeForTeams.TestSupport.LegacyWorker.create(project.id, %{
        "name" => "File author",
        "role" => "worker"
      })

    drain_reconciliation(10)

    {:ok, conversation} =
      ConversationInput.create_group_conversation(project.salix_group_id, %{
        "title" => "Review the sent artifacts",
        "kind" => "agent_task",
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => worker.salix_agent_id,
            "role_label" => "worker",
            "notification_filter" => %{"messages" => "none", "statuses" => "none"}
          }
        ]
      })

    path = "/reports/investigation.txt"
    body = "Original investigation\nEvidence and limitations.\n"
    seed_file(worker.salix_agent_id, path, body)

    {:ok, content} =
      ConversationAttachments.bind_sender_files(worker.salix_agent_id, [
        %{"type" => "text", "text" => "The complete investigation is attached."},
        %{
          "type" => "file",
          "path" => path,
          "file_name" => "调查报告.txt",
          "mime_type" => "text/plain"
        }
      ])

    {:ok, %{"message_id" => message_id}} =
      ConversationServer.append_group_conversation_agent_message(
        project.salix_group_id,
        conversation["conversation_id"],
        worker.salix_agent_id,
        %{"client_request_id" => "attachment-review", "content" => content}
      )

    # The HTTP read must use the sent immutable snapshot, never this newer file.
    seed_file(worker.salix_agent_id, path, "Changed after sending; not the attachment.")

    %{
      conn: conn,
      org: org,
      user: user,
      project: project,
      worker: worker,
      conversation_id: conversation["conversation_id"],
      message_id: message_id,
      content: content,
      body: body
    }
  end

  test "Task links download the exact sent file after its workspace path changes", context do
    %{conn: conn, org: org, project: project, conversation_id: conversation_id} = context

    path = attachment_path(context, 1)

    assert %{"data" => %{"messages" => [%{"blocks" => [_text, attachment]}]}} =
             conn
             |> get(
               ~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}/tasks/#{conversation_id}"
             )
             |> json_response(200)

    assert %{"kind" => "file", "name" => "调查报告.txt", "href" => ^path} = attachment

    response = get(conn, path)
    assert response.status == 200
    assert response.resp_body == context.body
    assert get_resp_header(response, "content-type") == ["application/octet-stream"]
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
    assert [disposition] = get_resp_header(response, "content-disposition")
    assert String.starts_with?(disposition, "attachment;")
    assert disposition =~ "filename*=utf-8''" <> URI.encode("调查报告.txt")
  end

  test "current membership is required even for a previously opened attachment", context do
    reader = user_fixture()
    {:ok, _} = Memberships.put_org_member(context.org.id, reader.id, "member")
    {:ok, _} = Memberships.put_project_member(context.project.id, reader.id, "user")
    conn = log_in_user(context.conn, reader)
    path = attachment_path(context, 1)

    assert get(conn, path).status == 200
    assert :ok = Memberships.remove_project_member(context.project.id, reader.id)
    response = get(conn, path)
    assert response.status == 403
    refute response.resp_body =~ context.body
  end

  test "a readable different project cannot resolve this conversation's file", context do
    other_project = bare_project_fixture(context.org)
    path = attachment_path(%{context | project: other_project}, 1)
    response = get(context.conn, path)
    assert response.status == 404
    refute response.resp_body =~ context.body
  end

  @tag :attachment_sender
  test "user and provider-user refs plus a spoofed agent id do not grant blob access", context do
    foreign_agent_id = SalixAgent.TestSupport.new_agent_id()
    private_body = "Private unrelated blob; never shared by an Agent message."
    {:ok, ref} = SalixStore.Blob.put(foreign_agent_id, private_body)
    ref = ref |> Jason.encode!() |> Jason.decode!()

    {:ok, user_participant} =
      ConversationServer.ensure_group_conversation_user_participant(
        context.project.salix_group_id,
        context.conversation_id,
        %{"user_id" => context.user.id, "notification_filter" => %{"messages" => "none"}}
      )

    {:ok, provider_participant} =
      BridgeForTeams.Conversations.ensure_project_bft_participant(
        context.project,
        context.conversation_id
      )

    for {actor_type, participant} <- [
          {"user", user_participant},
          {"provider_user", provider_participant}
        ] do
      {:ok, %{"message_id" => message_id}} =
        ConversationServer.append_group_conversation_message(
          context.project.salix_group_id,
          context.conversation_id,
          %{
            "client_request_id" => "untrusted-#{actor_type}",
            "actor_type" => actor_type,
            "provider" => "bft",
            "participant_id" => participant["participant_id"],
            "user_id" => context.user.id,
            "agent_id" => context.worker.salix_agent_id,
            "content" => [%{"type" => "file", "file_name" => "forged.txt", "blob_ref" => ref}]
          }
        )

      assert {:ok, stored} =
               SalixIM.Conversations.get_group_conversation_message(
                 context.project.salix_group_id,
                 context.conversation_id,
                 message_id
               )

      assert stored["actor_type"] == actor_type
      assert stored["agent_id"] == context.worker.salix_agent_id
      assert hd(stored["content"])["blob_ref"] == ref
      response = get(context.conn, attachment_path(%{context | message_id: message_id}, 0))
      assert response.status == 404
      refute response.resp_body =~ private_body
    end
  end

  test "an image uses its original content index and downloads opaque immutable bytes", context do
    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )

    seed_file(context.worker.salix_agent_id, "/reports/screenshot.png", png)

    {:ok, content} =
      ConversationAttachments.bind_sender_files(context.worker.salix_agent_id, [
        %{"type" => "text", "text" => "Original screenshot"},
        %{
          "type" => "image",
          "file_ref" => %{"environment_id" => "vfs", "path" => "/reports/screenshot.png"},
          "title" => "Original screenshot",
          "mime_type" => "image/png"
        }
      ])

    message_id = append_agent_content(context, content)
    response = get(context.conn, attachment_path(%{context | message_id: message_id}, 1))
    assert response.status == 200
    assert response.resp_body == png
    assert get_resp_header(response, "content-type") == ["application/octet-stream"]
    # A display title without file_name keeps the VFS name and its extension.
    assert get_resp_header(response, "content-disposition") == [
             ~s(attachment; filename="screenshot.png")
           ]
  end

  test "unbound paths stay unavailable and extra query fields cannot retarget a download",
       context do
    message_id = append_agent_content(context, [%{"type" => "file", "path" => "/private.txt"}])
    response = get(context.conn, attachment_path(%{context | message_id: message_id}, 0))
    assert response.status == 404

    response =
      get(context.conn, attachment_path(context, 1) <> "?path=/private.txt&ref=arbitrary")

    assert response.status == 200
    assert response.resp_body == context.body
  end

  defp append_agent_content(context, content) do
    {:ok, %{"message_id" => message_id}} =
      ConversationServer.append_group_conversation_agent_message(
        context.project.salix_group_id,
        context.conversation_id,
        context.worker.salix_agent_id,
        %{
          "client_request_id" => "attachment-#{SystemsRuntime.Proc.unique_integer([:positive])}",
          "content" => content
        }
      )

    message_id
  end

  defp attachment_path(context, index) do
    "/orgs/#{context.org.slug}/projects/#{context.project.id}/tasks/#{context.conversation_id}" <>
      "/messages/#{context.message_id}/attachments/#{index}"
  end

  defp seed_file(agent_id, path, body) do
    assert {:ok, event} = SalixAgent.AgentWorkspace.prepare_write(agent_id, path, body)

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(
               agent_id,
               "dashboard-attachment-#{SystemsRuntime.Proc.unique_integer([:positive])}",
               %{},
               [event]
             )
  end

  defp drain_reconciliation(0), do: flunk("project reconciliation did not settle")

  defp drain_reconciliation(attempts) do
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_reconciliation(attempts - 1)
    end
  end
end
