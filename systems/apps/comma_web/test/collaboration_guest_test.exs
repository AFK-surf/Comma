defmodule CommaWeb.CollaborationGuestTest do
  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]
  use Oban.Testing, repo: Comma.Repo

  @moduletag :capture_log

  alias Comma.AuthChallengeStore.Redis
  alias Comma.Data.{CollaborationGuestSession, TaskCollaborator}
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

    previous_auth = SystemsRuntime.fetch_env!(:comma_core, :auth)
    prefix = "cguest-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    url = System.get_env("COMMA_TEST_REDIS_URL", "redis://127.0.0.1:6379/0")

    previous =
      for {app, key} <- [
            {:salix_store, :s3_backend},
            {:salix_agent, :im_provider_mod},
            {:salix_agent, :llm},
            {:comma_core, :salix_client},
            {:comma_web, :api_token}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    SystemsRuntime.put_env(
      :comma_core,
      :auth,
      Keyword.merge(previous_auth,
        challenge_store: Redis,
        redis_url: url,
        redis_key_prefix: prefix,
        email_delivery: Comma.EmailDelivery.Logger,
        expose_codes: true,
        resend_cooldown_seconds: 0,
        email_request_limit: 5,
        ip_request_limit: 100,
        verification_failure_limit: 10,
        challenge_ttl_seconds: 60
      )
    )

    start_supervised!({Redix, {url, [name: Redis.connection_name(), sync_connect: true]}})
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:comma_web, :api_token, @admin_token)
    SystemsRuntime.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)
    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:comma_core, :auth, previous_auth)

      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    :ok
  end

  test "full external guest OTP flow, privacy, messages, files, Range download, SSE revocation, and removal" do
    host = person("guest-host", workspace: true)
    comma_member = person("guest-peer")
    linked!(host, comma_member)
    grant_credits!(host.workspace)
    start = "/v1/comma/workspaces/#{host.workspace["id"]}/collaborations"

    %{"task" => %{"id" => task_id, "group_id" => group_id}} =
      req(host, :post, start,
        json: %{
          "people" => [comma_member.user["id"]],
          "emails" => ["alice.secret@example.com", "bob.unnamed@example.com"],
          "title" => "Design Review",
          "content" => "Review the launch checklist",
          "client_request_id" => "g-1"
        }
      )
      |> expect_status(201)

    alice_row =
      Repo.get_by!(TaskCollaborator,
        conversation_id: task_id,
        invited_email: "alice.secret@example.com"
      )

    assert is_binary(alice_row.invite_token)
    assert %DateTime{} = alice_row.invite_expires_at

    # Unknown token -> 404
    public_req(:get, "/v1/comma/public/collaborations/invites/unknown-token")
    |> expect_status(404)

    # Invite preview -> 200 with masked email_hint and no raw email
    preview =
      public_req(:get, "/v1/comma/public/collaborations/invites/#{alice_row.invite_token}")
      |> expect_status(200)

    assert preview["invite"]["status"] == "invited"
    assert preview["invite"]["email_hint"] == "a***@example.com"
    assert preview["invite"]["title"] == "Design Review"
    assert preview["invite"]["host_name"] == "guest-host"
    refute inspect(preview) =~ "alice.secret@example.com"

    # OTP request with wrong email -> 403 email_mismatch
    wrong_email =
      public_req(
        :post,
        "/v1/comma/public/collaborations/invites/#{alice_row.invite_token}/otp/request",
        json: %{"email" => "someone.else@example.com"}
      )

    assert wrong_email.status == 403
    assert wrong_email.body["error"] == "email_mismatch"

    # OTP request with matching email (case-insensitive) -> 200 with debug_code
    otp =
      public_req(
        :post,
        "/v1/comma/public/collaborations/invites/#{alice_row.invite_token}/otp/request",
        json: %{"email" => "ALICE.SECRET@EXAMPLE.COM"}
      )
      |> expect_status(200)

    assert is_binary(otp["challenge_id"])
    assert is_binary(otp["debug_code"])
    assert otp["email_hint"] == "a***@example.com"

    # Wrong OTP code -> 401 invalid_code
    bad_code = if otp["debug_code"] == "000000", do: "111111", else: "000000"

    bad_otp =
      public_req(
        :post,
        "/v1/comma/public/collaborations/invites/#{alice_row.invite_token}/otp/verify",
        json: %{"challenge_id" => otp["challenge_id"], "code" => bad_code}
      )

    assert bad_otp.status == 401
    assert bad_otp.body["error"] == "invalid_code"

    # Valid OTP code -> 200, activates seat, issues cgs_... token
    verified =
      public_req(
        :post,
        "/v1/comma/public/collaborations/invites/#{alice_row.invite_token}/otp/verify",
        json: %{
          "challenge_id" => otp["challenge_id"],
          "code" => otp["debug_code"],
          "name" => "Alice G."
        }
      )
      |> expect_status(200)

    assert String.starts_with?(verified["token"], "cgs_")
    guest_token = verified["token"]
    assert verified["guest"]["name"] == "Alice G."
    assert verified["task"]["conversation_id"] == task_id
    assert verified["task"]["group_id"] == group_id

    # Regular /v1/comma/... routes MUST reject cgs_ tokens with 401!
    http(
      [
        {"authorization", "Bearer " <> guest_token},
        {"x-comma-session-transport", "bearer"}
      ],
      :get,
      "/v1/comma/auth/session",
      []
    )
    |> expect_status(401)

    http(
      [
        {"authorization", "Bearer " <> guest_token},
        {"x-comma-session-transport", "bearer"}
      ],
      :get,
      "/v1/comma/collaborations",
      []
    )
    |> expect_status(401)

    # GET /v1/comma/public/collaborations/task: strict email privacy (ZERO email/email_hint on members!)
    task_view =
      guest_req(guest_token, :get, "/v1/comma/public/collaborations/task")
      |> expect_status(200)

    members = task_view["task"]["members"]

    assert Enum.all?(
             members,
             &(not Map.has_key?(&1, "email") and not Map.has_key?(&1, "email_hint"))
           )

    refute inspect(members) =~ "bob.unnamed@example.com"
    refute inspect(members) =~ "alice.secret@example.com"
    assert Enum.any?(members, &(&1["role"] == "host" and &1["name"] == "guest-host"))

    assert Enum.any?(
             members,
             &(&1["is_guest"] == true and &1["is_self"] == true and &1["name"] == "Alice G.")
           )

    assert Enum.any?(
             members,
             &(&1["is_guest"] == true and &1["is_self"] == false and is_nil(&1["name"]))
           )

    # Oversized message text (> 16 KB) -> 400 text is too long
    too_long =
      guest_req(guest_token, :post, "/v1/comma/public/collaborations/task/messages",
        json: %{"text" => String.duplicate("x", 16_001)}
      )

    assert too_long.status == 400
    assert too_long.body["error"] == "text is too long"

    # POST message without mention_comma -> projected guest shape returned, stored as context_only
    msg1 =
      guest_req(guest_token, :post, "/v1/comma/public/collaborations/task/messages",
        json: %{"text" => "Looks good to me", "mention_comma" => false}
      )
      |> expect_status(201)

    assert msg1["message"]["role"] == "user"
    assert msg1["message"]["sender_name"] == "Alice G."
    assert msg1["message"]["is_guest"] == true
    assert msg1["message"]["is_self"] == true
    assert msg1["message"]["content"] == [%{"type" => "text", "text" => "Looks good to me"}]
    refute Map.has_key?(msg1["message"], "metadata")
    refute Map.has_key?(msg1["message"], "user_id")

    {:ok, stored_msg1} =
      SalixIM.Conversations.get_group_conversation_message(
        group_id,
        task_id,
        msg1["message"]["id"]
      )

    assert get_in(stored_msg1, ["metadata", "context_only"]) == true
    assert get_in(stored_msg1, ["metadata", "author_name"]) == "Alice G."

    # POST message with mention_comma: true -> wakes worker (not context_only)
    msg2 =
      guest_req(guest_token, :post, "/v1/comma/public/collaborations/task/messages",
        json: %{"text" => "Please summarize the budget", "mention_comma" => true}
      )
      |> expect_status(201)

    {:ok, stored_msg2} =
      SalixIM.Conversations.get_group_conversation_message(
        group_id,
        task_id,
        msg2["message"]["id"]
      )

    refute get_in(stored_msg2, ["metadata", "context_only"]) == true

    # Unnamed guest omits author_name (client renders localized Anonymous), NEVER leaks their email!
    bob_row =
      Repo.get_by!(TaskCollaborator,
        conversation_id: task_id,
        invited_email: "bob.unnamed@example.com"
      )

    bob_otp =
      public_req(
        :post,
        "/v1/comma/public/collaborations/invites/#{bob_row.invite_token}/otp/request",
        json: %{}
      )
      |> expect_status(200)

    %{"token" => bob_token} =
      public_req(
        :post,
        "/v1/comma/public/collaborations/invites/#{bob_row.invite_token}/otp/verify",
        json: %{"challenge_id" => bob_otp["challenge_id"], "code" => bob_otp["debug_code"]}
      )
      |> expect_status(200)

    bob_msg =
      guest_req(bob_token, :post, "/v1/comma/public/collaborations/task/messages",
        json: %{"text" => "Hello from Bob"}
      )
      |> expect_status(201)

    assert bob_msg["message"]["role"] == "user"
    assert bob_msg["message"]["sender_name"] == nil
    assert bob_msg["message"]["is_guest"] == true
    assert bob_msg["message"]["is_self"] == true
    refute inspect(bob_msg) =~ "bob.unnamed@example.com"

    {:ok, stored_bob_msg} =
      SalixIM.Conversations.get_group_conversation_message(
        group_id,
        task_id,
        bob_msg["message"]["id"]
      )

    assert get_in(stored_bob_msg, ["metadata", "author_name"]) == nil

    # Append a Worker reply with a /task/ file, a mini_app block (schema version: 1, app_version: 3),
    # a milestone-only message, and an internal system agent_input message to verify guest projection & filtering.
    {:ok, task_rec} = SalixIM.Conversations.get_group_conversation_record(group_id, task_id)
    worker_id = task_rec["task_worker_agent_id"]

    {:ok, _} =
      SalixIM.ConversationServer.append_group_conversation_agent_message(
        group_id,
        task_id,
        worker_id,
        %{
          "content" => [
            %{"type" => "text", "text" => "Here is your report\n[[comma-protocol]]secret"},
            %{
              "type" => "file",
              "path" => "/task/report.pdf",
              "file_name" => "report.pdf",
              "blob_ref" => %{
                "size" => 4096,
                "content_type" => "application/pdf",
                "hash" => "abc"
              }
            }
          ],
          "client_request_id" => "worker-reply-1"
        }
      )

    {:ok, _} =
      SalixIM.ConversationServer.append_group_conversation_agent_message(
        group_id,
        task_id,
        worker_id,
        %{
          "content" => [
            %{"type" => "text", "text" => "Interactive budget"},
            %{
              "type" => "mini_app",
              "version" => 1,
              "app_version" => 3,
              "app_id" => "app_demo",
              "name" => "Budget App",
              "summary" => "Interactive budget"
            }
          ],
          "client_request_id" => "worker-mini-app-1"
        }
      )

    {:ok, _} =
      SalixIM.ConversationServer.append_group_conversation_agent_message(
        group_id,
        task_id,
        worker_id,
        %{
          "content" => [%{"type" => "milestone", "title" => "Hidden milestone"}],
          "client_request_id" => "worker-milestone-only-1"
        }
      )

    {:ok, _} =
      SalixIM.ConversationServer.append_group_conversation_agent_message(
        group_id,
        task_id,
        worker_id,
        %{
          "content" => [
            %{"type" => "text", "text" => "[[comma-context]]INTERNAL PRIVATE CONTEXT"}
          ],
          "client_request_id" => "worker-context-only-1"
        }
      )

    {:ok, _} =
      SalixIM.ConversationServer.append_product_event(
        group_id,
        task_id,
        "collaboration.member_changed",
        %{"member" => %{"user_id" => comma_member.user["id"], "status" => "left"}},
        "sys-event-1"
      )

    # Also verify system agent_input / task_worker_nudge and non-/task/ paths are stripped by projection.
    assert [] ==
             CommaWeb.CollaborationGuestEndpoints.project_guest_messages(
               [
                 %{
                   "message_id" => "msg_sys_1",
                   "actor_type" => "system",
                   "agent_input" => %{"kind" => "subtask_report"},
                   "content" => [%{"type" => "text", "text" => "PRIVATE AGENT INPUT"}],
                   "metadata" => %{"message_type" => "task_worker_nudge"}
                 }
               ],
               alice_row,
               %{}
             )

    # Alice reads GET /task: projected roles/names/is_self/attachments/mini_app, ZERO leaks!
    alice_view =
      guest_req(guest_token, :get, "/v1/comma/public/collaborations/task")
      |> expect_status(200)

    alice_msgs = alice_view["messages"]
    refute inspect(alice_msgs) =~ "INTERNAL PRIVATE CONTEXT"
    refute inspect(alice_msgs) =~ "Hidden milestone"
    refute inspect(alice_msgs) =~ "[[comma-protocol]]"
    refute inspect(alice_msgs) =~ "blob_ref"
    refute inspect(alice_msgs) =~ host.user["id"]
    refute inspect(alice_msgs) =~ comma_member.user["id"]
    refute inspect(alice_msgs) =~ "bob.unnamed@example.com"

    assert Enum.all?(alice_msgs, fn m ->
             not Map.has_key?(m, "metadata") and
               not Map.has_key?(m, "agent_input") and
               not Map.has_key?(m, "user_id") and
               not Map.has_key?(m, "agent_id")
           end)

    host_projected = Enum.find(alice_msgs, &(&1["sender_name"] == "guest-host"))
    assert host_projected["role"] == "user"
    assert host_projected["is_guest"] == false
    assert host_projected["is_self"] == false

    alice_projected = Enum.find(alice_msgs, &(&1["id"] == msg1["message"]["id"]))
    assert alice_projected["role"] == "user"
    assert alice_projected["sender_name"] == "Alice G."
    assert alice_projected["is_guest"] == true
    assert alice_projected["is_self"] == true

    bob_projected = Enum.find(alice_msgs, &(&1["id"] == bob_msg["message"]["id"]))
    assert bob_projected["role"] == "user"
    assert bob_projected["sender_name"] == nil
    assert bob_projected["is_guest"] == true
    assert bob_projected["is_self"] == false

    comma_file_msg =
      Enum.find(
        alice_msgs,
        &(&1["role"] == "assistant" and Enum.any?(&1["content"], fn b -> b["type"] == "file" end))
      )

    assert comma_file_msg["sender_name"] == "Comma"
    assert comma_file_msg["is_guest"] == false
    assert comma_file_msg["is_self"] == false

    assert [
             %{"type" => "text", "text" => "Here is your report"},
             %{
               "type" => "file",
               "file_name" => "report.pdf",
               "path" => "/task/report.pdf",
               "size" => 4096,
               "mime_type" => "application/pdf"
             }
           ] = comma_file_msg["content"]

    comma_app_msg =
      Enum.find(
        alice_msgs,
        &(&1["role"] == "assistant" and
            Enum.any?(&1["content"], fn b -> b["type"] == "mini_app" end))
      )

    assert [
             %{"type" => "text", "text" => "Interactive budget"},
             %{
               "type" => "mini_app",
               "app_id" => "app_demo",
               "name" => "Budget App",
               "summary" => "Interactive budget",
               "version" => 3
             }
           ] = comma_app_msg["content"]

    # Pagination: limit=2 returns has_older=true and numeric next_cursor; before=<next_cursor> loads older page.
    page1 =
      guest_req(guest_token, :get, "/v1/comma/public/collaborations/task?limit=2")
      |> expect_status(200)

    assert page1["has_older"] == true
    assert is_binary(page1["next_cursor"])

    page2 =
      guest_req(
        guest_token,
        :get,
        "/v1/comma/public/collaborations/task?limit=2&before=#{page1["next_cursor"]}"
      )
      |> expect_status(200)

    assert length(page2["messages"]) >= 1
    page1_ids = MapSet.new(page1["messages"], & &1["id"])
    assert Enum.all?(page2["messages"], &(not MapSet.member?(page1_ids, &1["id"])))

    # Files: upload, list (with used_bytes), Range download (200, 206, 416 + ?token=)
    file_body = "abcdefghij0123456789"

    %{"path" => uploaded_path} =
      http(
        [
          {"authorization", "Bearer " <> guest_token},
          {"content-type", "application/octet-stream"}
        ],
        :post,
        "/v1/comma/public/collaborations/task/files?name=notes.txt",
        body: file_body
      )
      |> expect_status(201)

    listed =
      guest_req(guest_token, :get, "/v1/comma/public/collaborations/task/files")
      |> expect_status(200)

    assert listed["used_bytes"] == byte_size(file_body)
    refute Map.has_key?(listed, "quota_bytes")
    assert Enum.any?(listed["entries"], &(&1["path"] == uploaded_path))

    dl_path =
      "/v1/comma/public/collaborations/task/files/download?path=#{URI.encode_www_form(uploaded_path)}&token=#{URI.encode_www_form(guest_token)}"

    full_dl = public_req(:get, dl_path)
    assert full_dl.status == 200
    assert full_dl.body == file_body
    assert Req.Response.get_header(full_dl, "accept-ranges") == ["bytes"]
    assert Req.Response.get_header(full_dl, "x-content-type-options") == ["nosniff"]

    partial_dl = http([{"range", "bytes=0-4"}], :get, dl_path, [])
    assert partial_dl.status == 206
    assert partial_dl.body == "abcde"
    assert Req.Response.get_header(partial_dl, "content-range") == ["bytes 0-4/20"]

    bad_range = http([{"range", "bytes=100-200"}], :get, dl_path, [])
    assert bad_range.status == 416
    assert Req.Response.get_header(bad_range, "content-range") == ["bytes */20"]

    # SSE stream emits resync frame and closes with event: revoked on host removal
    sse_resp =
      public_req(
        :get,
        "/v1/comma/public/collaborations/task/events?token=#{URI.encode_www_form(guest_token)}&wait=50"
      )

    assert sse_resp.status == 200
    assert sse_resp.body =~ "event: resync"

    # Host removes Alice -> immediate guest_session_revoked (401)
    req(host, :delete, "#{start}/#{task_id}/members/#{alice_row.id}") |> expect_status(200)

    revoked = guest_req(guest_token, :get, "/v1/comma/public/collaborations/task")
    assert revoked.status == 401
    assert revoked.body["error"] == "guest_session_revoked"

    # Invite preview for removed collaborator -> 410 invite_expired
    gone = public_req(:get, "/v1/comma/public/collaborations/invites/#{alice_row.invite_token}")
    assert gone.status == 410
    assert gone.body["error"] == "invite_expired"

    # Bob leaves -> 200, session immediately revoked, host notified in Home
    guest_req(bob_token, :post, "/v1/comma/public/collaborations/task/leave")
    |> expect_status(200)

    bob_after = guest_req(bob_token, :get, "/v1/comma/public/collaborations/task")
    assert bob_after.status == 401
    assert bob_after.body["error"] == "guest_session_revoked"
  end

  test "expired invite returns 410, manual resend rotates token and counts toward 20/24h cap" do
    host = person("resend-host", workspace: true)
    start = "/v1/comma/workspaces/#{host.workspace["id"]}/collaborations"

    %{"task" => %{"id" => task_id}} =
      req(host, :post, start,
        json: %{
          "emails" => ["expiring@example.com"],
          "content" => "Check expiry and resend",
          "client_request_id" => "rs-1"
        }
      )
      |> expect_status(201)

    row =
      Repo.get_by!(TaskCollaborator,
        conversation_id: task_id,
        invited_email: "expiring@example.com"
      )

    old_token = row.invite_token

    # Force expiry into the past
    past = DateTime.add(SystemsClock.utc_now(), -60, :second)

    from(c in TaskCollaborator, where: c.id == ^row.id)
    |> Repo.update_all(set: [invite_expires_at: past])

    expired = public_req(:get, "/v1/comma/public/collaborations/invites/#{old_token}")
    assert expired.status == 410
    assert expired.body["error"] == "invite_expired"

    # Host manually resends invite -> rotates token, resets +7d expiry
    resent =
      req(host, :post, "#{start}/#{task_id}/members/#{row.id}/resend")
      |> expect_status(200)

    assert resent["id"] == row.id
    assert is_binary(resent["invite_expires_at"])

    updated = Repo.get!(TaskCollaborator, row.id)
    assert updated.invite_token != old_token

    # Old token no longer resolves
    public_req(:get, "/v1/comma/public/collaborations/invites/#{old_token}")
    |> expect_status(404)

    # New token works!
    public_req(:get, "/v1/comma/public/collaborations/invites/#{updated.invite_token}")
    |> expect_status(200)

    # Resends count toward the 20 / 24h cap (already used 2: 1 initial + 1 resend -> 18 left)
    for _ <- 1..18 do
      req(host, :post, "#{start}/#{task_id}/members/#{row.id}/resend")
      |> expect_status(200)
    end

    # 21st send in 24h -> 429 invite_daily_limit_reached
    capped = req(host, :post, "#{start}/#{task_id}/members/#{row.id}/resend")
    assert capped.status == 429
    assert capped.body["error"] == "invite_daily_limit_reached"
    assert capped.body["limit"] == 20
  end

  test "seat claiming: invited seat stays invited; active guest seat stays active and revokes guest sessions" do
    host = person("claim-host", workspace: true)
    start = "/v1/comma/workspaces/#{host.workspace["id"]}/collaborations"

    %{"task" => %{"id" => invited_task_id}} =
      req(host, :post, start,
        json: %{
          "emails" => ["claimer-collaboration@example.com"],
          "content" => "Task 1 (stays invited)",
          "client_request_id" => "cl-1"
        }
      )
      |> expect_status(201)

    %{"task" => %{"id" => active_task_id, "group_id" => active_group_id}} =
      req(host, :post, start,
        json: %{
          "emails" => ["claimer-collaboration@example.com"],
          "content" => "Task 2 (guest joins via OTP first)",
          "client_request_id" => "cl-2"
        }
      )
      |> expect_status(201)

    active_row =
      Repo.get_by!(TaskCollaborator,
        conversation_id: active_task_id,
        invited_email: "claimer-collaboration@example.com"
      )

    # Guest verifies OTP on Task 2 -> becomes active + gets guest session
    otp =
      public_req(
        :post,
        "/v1/comma/public/collaborations/invites/#{active_row.invite_token}/otp/request",
        json: %{}
      )
      |> expect_status(200)

    %{"token" => guest_token} =
      public_req(
        :post,
        "/v1/comma/public/collaborations/invites/#{active_row.invite_token}/otp/verify",
        json: %{"challenge_id" => otp["challenge_id"], "code" => otp["debug_code"]}
      )
      |> expect_status(200)

    # Guest now signs up for full Comma and lists collaborations (triggers claim)
    claimer = person("claimer")
    %{"data" => items} = req(claimer, :get, "/v1/comma/collaborations") |> expect_status(200)

    invited_item = Enum.find(items, &(&1["task"]["id"] == invited_task_id))
    active_item = Enum.find(items, &(&1["task"]["id"] == active_task_id))

    assert invited_item["status"] == "invited"
    assert active_item["status"] == "active"

    # Full Comma member can immediately read the active task without re-accepting
    req(claimer, :get, "/v1/comma/collaborations/#{active_group_id}/#{active_task_id}")
    |> expect_status(200)

    # Previous guest session was revoked on claim
    assert guest_req(guest_token, :get, "/v1/comma/public/collaborations/task").status == 401
    session = Repo.get_by!(CollaborationGuestSession, collaborator_id: active_row.id)
    assert %DateTime{} = session.revoked_at
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
               source_id: "collaboration-guest-test",
               source_event_id: workspace["id"],
               idempotency_key: workspace["id"]
             })
  end

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

  defp guest_req(token, method, path, opts \\ []),
    do: http([{"authorization", "Bearer " <> token}], method, path, opts)

  defp public_req(method, path, opts \\ []),
    do: http([], method, path, opts)

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

  defp expect_status(resp, status) do
    assert resp.status == status, inspect(resp.body)
    resp.body
  end
end
