defmodule CommaWeb.RouterTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test
  import Comma.WorkspaceTestSupport

  alias Comma.Accounts.AuthSession
  alias Comma.Repo

  @opts CommaWeb.Router.init([])
  @admin_token "test-token"
  @web_origin "http://127.0.0.1:5174"
  @admin_origin "http://127.0.0.1:4175"

  setup context do
    unless Process.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    comma_owner =
      if context[:database_isolation] do
        CommaWeb.TestRepoSandbox.start_owner!(:multi_connection)
      else
        CommaWeb.TestRepoSandbox.start_owner!(:transaction)
      end

    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_api_token = Application.get_env(:comma_web, :api_token)
    prev_auth = Application.get_env(:comma_core, :auth)
    prev_salix_client = Application.get_env(:comma_core, :salix_client)
    prev_salix_vm = Application.get_env(:comma_core, :salix_vm)
    prev_salix_client_test_pid = Application.get_env(:comma_core, :salix_client_test_pid)
    prev_google_credentials = Application.get_env(:comma_core, :google_adapter_fake_credentials)
    prev_google_exchange_pid = Application.get_env(:comma_core, :google_adapter_fake_exchange_pid)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:comma_web, :api_token, @admin_token)
    Application.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    Comma.PodLifecycle.reset_for_test()

    Application.put_env(:comma_core, :auth,
      challenge_store: Comma.AuthChallengeStore.Memory,
      email_delivery: Comma.EmailDelivery.Logger,
      secret: "comma-web-test-secret",
      rate_limit_secret: "comma-web-test-rate-limit-secret",
      challenge_ttl_seconds: 900,
      max_attempts: 5,
      session_ttl_seconds: 3600,
      auto_create_users: true,
      resend_cooldown_seconds: 0,
      email_request_limit: 1_000_000,
      ip_request_limit: 1_000_000,
      verification_failure_limit: 1_000_000,
      provider_failure_threshold: 1_000_000,
      expose_codes: true
    )

    ensure_fake_s3!()
    Comma.AuthChallengeStore.Memory.reset!()

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, prev_backend)
      restore_env(:comma_web, :api_token, prev_api_token)
      restore_env(:comma_core, :auth, prev_auth)
      restore_env(:comma_core, :salix_client, prev_salix_client)
      restore_env(:comma_core, :salix_vm, prev_salix_vm)
      restore_env(:comma_core, :salix_client_test_pid, prev_salix_client_test_pid)
      restore_env(:comma_core, :google_adapter_fake_credentials, prev_google_credentials)
      restore_env(:comma_core, :google_adapter_fake_exchange_pid, prev_google_exchange_pid)
      Comma.Migrations.LegacyS3Fixture.reset!()
      Comma.PodLifecycle.reset_for_test()
      Comma.AuthChallengeStore.Memory.reset!()
      CommaWeb.TestRepoSandbox.stop_owner(comma_owner)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
    end)

    :ok
  end

  @tag :browser_run
  test "browser endpoints enforce workspace ownership and redact provider credentials" do
    session = email_login!("browser-owner@example.com")
    outsider = email_login!("browser-outsider@example.com")
    workspace = create_ready_workspace!(session["user"]["id"], "Browser")

    owner =
      SalixAgent.Browser.owner(%{
        agent_id: workspace["router_agent_id"],
        session_id: "browser-test"
      })

    settings = %SalixStore.BrowserSettings.Row{
      scope: owner.tenant_id,
      account_id: String.duplicate("a", 32),
      token_ciphertext: "private-ciphertext"
    }

    {:ok, row} = SalixStore.BrowserBindings.reserve(owner, settings)

    {:ok, ready} =
      SalixStore.BrowserBindings.finish(row, %{status: "ready", provider_id: "private-provider"})

    assert {:ok, :saved} =
             SalixStore.BrowserStorage.save(
               ready,
               %{
                 "cookies" => [%{"name" => "login", "value" => "private-login"}],
                 "origins" => %{}
               },
               nil
             )

    on_exit(fn -> SalixStore.Repo.delete_all(SalixStore.BrowserBindings.query(owner)) end)
    path = "/v1/comma/workspaces/#{workspace["id"]}/browsers"

    response =
      :get
      |> conn(path)
      |> put_req_header("authorization", "Bearer " <> session["token"])
      |> call()

    assert response.status == 200
    assert [%{"agent_id" => _}] = Jason.decode!(response.resp_body)["browsers"]
    refute response.resp_body =~ "private-"

    chat =
      :post
      |> json_conn("/v1/comma/groups/#{workspace["default_group_id"]}/assistant-chat", %{})
      |> put_req_header("authorization", "Bearer " <> session["token"])
      |> call()
      |> expect_json(200)

    {:ok, %{"participants" => participants}} =
      SalixIM.Conversations.list_group_conversation_participants(
        workspace["default_group_id"],
        chat["id"]
      )

    participant = Enum.find(participants, &(&1["actor_type"] == "agent"))

    scoped_path =
      path <>
        "?" <>
        URI.encode_query(%{
          "conversation_id" => chat["id"],
          "participant_id" => participant["participant_id"]
        })

    read = fn ->
      :get
      |> conn(scoped_path)
      |> put_req_header("authorization", "Bearer " <> session["token"])
      |> call()
      |> expect_json(200)
    end

    # The ready browser above belongs to a different Runtime Session.
    assert read.()["browsers"] == []
    current_owner = %{owner | session_id: get_in(participant, ["payload", "session_id"])}

    assert {:error, :browser_shared_profile_in_use} =
             SalixStore.BrowserBindings.reserve(current_owner, settings)

    {:ok, closing} = SalixStore.BrowserBindings.claim(owner, :agent, "close")
    {:ok, _} = SalixStore.BrowserBindings.finish(closing, %{status: "closed"})
    {:ok, current_row} = SalixStore.BrowserBindings.reserve(current_owner, settings)
    on_exit(fn -> SalixStore.Repo.delete_all(SalixStore.BrowserBindings.query(current_owner)) end)
    assert read.()["browsers"] == []
    {:ok, _} = SalixStore.BrowserBindings.finish(current_row, %{status: "ready"})
    assert [%{"session_id" => current_session}] = read.()["browsers"]
    assert current_session == current_owner.session_id

    SalixStore.Repo.update_all(SalixStore.BrowserBindings.query(current_owner),
      set: [status: "closed"]
    )

    assert read.()["browsers"] == []

    denied =
      :get
      |> conn(path)
      |> put_req_header("authorization", "Bearer " <> outsider["token"])
      |> call()

    assert denied.status == 403
    unauthenticated = :get |> conn(path) |> call()
    assert unauthenticated.status == 401

    foreign =
      SalixStore.Ids.new_tenant_id()
      |> SalixStore.Ids.new_group_id()
      |> SalixStore.Ids.new_agent_id()

    denied_command =
      :post
      |> json_conn(path <> "/#{foreign}/browser-test", %{
        "operation" => "take_control",
        "viewer_id" => Ecto.UUID.generate()
      })
      |> put_req_header("authorization", "Bearer " <> session["token"])
      |> call()

    assert denied_command.status in [403, 409]
    assert SalixStore.BrowserBindings.get(owner).controller == nil

    denied_clear =
      :post
      |> json_conn(path <> "/#{owner.agent_id}/#{owner.session_id}", %{
        "operation" => "clear_storage",
        "viewer_id" => Ecto.UUID.generate()
      })
      |> put_req_header("authorization", "Bearer " <> outsider["token"])
      |> call()

    assert denied_clear.status == 409
    assert Jason.decode!(denied_clear.resp_body)["error"] == "browser_forbidden"

    clear_idle = fn token ->
      :post
      |> json_conn(path <> "/clear-storage", %{})
      |> put_req_header("authorization", "Bearer " <> token)
      |> call()
    end

    assert clear_idle.(outsider["token"]).status == 403
    assert clear_idle.(session["token"]).status == 200
    assert {:ok, %{"cookies" => [], "origins" => %{}}} = SalixStore.BrowserStorage.load(owner)
    {:ok, _} = SalixStore.BrowserBindings.reserve(owner, settings)
    assert clear_idle.(session["token"]).status == 409
  end

  @tag :task_panel
  test "the Task panel reads its bound Worker only after ordinary Task authorization" do
    session = email_login!("task-panel-owner@example.com")
    other_session = email_login!("task-panel-outsider@example.com")
    workspace = create_ready_workspace!(session["user"]["id"], "Task panel")
    group = workspace["default_group_id"]

    {:ok, task} =
      SalixCluster.TaskSchedules.create_task_conversation(
        group,
        workspace["router_agent_id"],
        workspace["default_worker_agent_id"],
        %{"title" => "Read task properties", "content" => "A read-only panel"}
      )

    task_id = task["conversation_id"]
    path = "/v1/comma/groups/#{group}/conversations/#{task_id}/preview"

    plain = :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)
    refute Map.has_key?(plain, "bound_worker")

    panel =
      :get
      |> conn(path <> "?include_worker=true")
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert panel["id"] == task_id
    assert panel["status"] == plain["status"]
    assert %{"participant_id" => participant_id, "name" => name} = panel["bound_worker"]
    assert is_binary(participant_id) and participant_id != ""
    assert is_binary(name) and name != ""
    refute Map.has_key?(panel, "messages")

    :get |> conn(path <> "?include_worker=true") |> call() |> expect_json(401)

    :get
    |> conn(path <> "?include_worker=true")
    |> user_auth(other_session["token"])
    |> call()
    |> expect_json(404)
  end

  @tag :recording_asr
  test "recording ASR requires a user session and accepts audio rather than JSON" do
    path = "/v1/comma/me/recordings/transcribe"
    anonymous = conn(:post, path, "M4A") |> put_req_header("content-type", "audio/mp4") |> call()
    assert anonymous.status == 401
    session = email_login!("recording-asr@example.com")
    previous = Application.get_env(:salix_web, :meeting_asr_template)
    Application.delete_env(:salix_web, :meeting_asr_template)
    on_exit(fn -> restore_env(:salix_web, :meeting_asr_template, previous) end)

    response =
      conn(:post, path, "M4A")
      |> put_req_header("content-type", "audio/mp4")
      |> user_auth(session["token"])
      |> call()

    assert response.status == 200
    assert response.resp_body =~ "not configured"
    assert get_resp_header(response, "content-type") == ["text/event-stream; charset=utf-8"]
  end

  @tag :task_labels_policy
  test "only the workspace owner can grant label automation and approve a batch through HTTP" do
    session = email_login!("labels-owner@example.com")
    other_session = email_login!("labels-outsider@example.com")
    workspace = create_ready_workspace!(session["user"]["id"], "Task Labels")
    group_id = workspace["default_group_id"]
    path = "/v1/comma/groups/#{group_id}/task-labels"

    assert %{"approval_policy" => "ask", "labels" => labels} =
             :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)

    assert length(labels) == 4

    :patch
    |> json_conn(path <> "/policy", %{"approval_policy" => "auto"})
    |> call()
    |> expect_json(401)

    :patch
    |> json_conn(path <> "/policy", %{"approval_policy" => "auto"})
    |> user_auth(other_session["token"])
    |> call()
    |> expect_json(404)

    :patch
    |> json_conn(path <> "/policy", %{"approval_policy" => "always"})
    |> user_auth(session["token"])
    |> call()
    |> expect_json(400)

    assert %{"approval_policy" => "ask"} =
             :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)

    {:ok, proposal} =
      SalixIM.TaskLabels.propose(
        group_id,
        %{
          "op" => "create",
          "payload" => %{
            "labels" => [
              %{
                "name" => "Invoices",
                "description" => "Add when processing invoices; skip other documents."
              },
              %{
                "name" => "Budgets",
                "description" => "Add when planning budgets; skip unrelated work."
              }
            ]
          }
        },
        %{"agent_id" => workspace["router_agent_id"], "session_id" => "session-labels"}
      )

    resolve_path = path <> "/proposals/#{proposal["id"]}/resolve"

    :post
    |> json_conn(resolve_path, %{"decision" => "approve", "auto_approve" => true})
    |> user_auth(other_session["token"])
    |> call()
    |> expect_json(404)

    :post
    |> json_conn(resolve_path, %{"decision" => "reject", "auto_approve" => true})
    |> user_auth(session["token"])
    |> call()
    |> expect_json(400)

    assert %{
             "approval_policy" => "auto",
             "labels" => approved_labels,
             "proposal" => %{"status" => "approved", "payload" => %{"labels" => created}}
           } =
             :post
             |> json_conn(resolve_path, %{"decision" => "approve", "auto_approve" => true})
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    assert length(approved_labels) == 6
    assert Enum.all?(created, &SalixStore.Ids.valid_task_label_id?(&1["id"]))

    assert %{"approval_policy" => "ask"} =
             :patch
             |> json_conn(path <> "/policy", %{"approval_policy" => "ask"})
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    # Replaying the already approved request cannot restore a revoked grant.
    assert %{"approval_policy" => "ask", "labels" => ^approved_labels} =
             :post
             |> json_conn(resolve_path, %{"decision" => "approve", "auto_approve" => true})
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)
  end

  test "liveness stays healthy while drain rejects readiness and product requests" do
    assert :get |> conn("/live") |> call() |> Map.fetch!(:status) == 200

    Comma.PodLifecycle.begin_drain()

    assert :get |> conn("/live") |> call() |> Map.fetch!(:status) == 200
    assert :get |> conn("/ready") |> call() |> Map.fetch!(:status) == 503
    assert :get |> conn("/v1/comma/admin/users") |> call() |> Map.fetch!(:status) == 503
  end

  test "preStop rejects a concurrent HTTP request during propagation" do
    handler = "comma-web-pre-stop-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:comma, :pod_lifecycle, :pre_stop],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:pre_stop_stage, metadata.stage})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler)

      if Process.whereis(Comma.Oban) do
        for queue <- [:comma_external] do
          Oban.resume_queue(Comma.Oban, queue: queue, local_only: true)
        end
      end
    end)

    task =
      Task.async(fn ->
        Comma.PodLifecycle.pre_stop(propagation_ms: 150, job_grace_ms: 0)
      end)

    assert_receive {:pre_stop_stage, :jobs_quiet}
    assert :get |> conn("/v1/comma/admin/users") |> call() |> Map.fetch!(:status) == 503
    assert :get |> conn("/live") |> call() |> Map.fetch!(:status) == 200
    assert :get |> conn("/ready") |> call() |> Map.fetch!(:status) == 503
    assert {:ok, _result} = Task.yield(task, 5_000)
  end

  test "v1 CORS preflight succeeds before auth" do
    conn =
      :options
      |> conn("/v1/comma/admin/users")
      |> put_req_header("origin", "http://localhost:5173")
      |> put_req_header("access-control-request-method", "GET")
      |> put_req_header("access-control-request-headers", "authorization")
      |> call()

    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:5173"]

    assert get_resp_header(conn, "access-control-allow-headers") == [
             "authorization,content-type,if-none-match,x-comma-session-transport,x-comma-session-lifecycle-version,x-comma-expected-auth-session-id"
           ]

    assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
    assert get_resp_header(conn, "access-control-expose-headers") == ["etag"]
  end

  test "v1 CORS rejects every unapproved browser and Electron renderer origin before auth" do
    for origin <- ["https://untrusted.example", "assets://."] do
      conn =
        :options
        |> conn("/v1/comma/auth/email/verify")
        |> put_req_header("origin", origin)
        |> put_req_header("access-control-request-method", "POST")
        |> put_req_header("access-control-request-headers", "x-comma-session-transport")
        |> call()

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "origin_not_allowed"
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      conn =
        :post
        |> json_conn("/v1/comma/auth/email/login", %{"email" => "origin-spam@example.com"})
        |> put_req_header("origin", origin)
        |> call()

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "origin_not_allowed"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "trusted Web requests hard-cut lifecycle version and Session precondition headers" do
    origin = "http://127.0.0.1:5174"

    missing_version =
      :get
      |> conn("/v1/comma/auth/session")
      |> put_req_header("origin", origin)
      |> put_req_header("x-comma-session-transport", "cookie")
      |> put_req_header("x-comma-expected-auth-session-id", "unknown")
      |> call()

    assert expect_json(missing_version, 428) == %{
             "contract_version" => 1,
             "error" => "session_lifecycle_version_required"
           }

    assert get_resp_header(missing_version, "cache-control") == ["no-store"]

    for version <- ["0", "2", "1, 1", " 1"] do
      response =
        :get
        |> conn("/v1/comma/auth/session")
        |> put_req_header("origin", origin)
        |> put_req_header("x-comma-session-transport", "cookie")
        |> put_req_header("x-comma-session-lifecycle-version", version)
        |> put_req_header("x-comma-expected-auth-session-id", "unknown")
        |> call()

      assert expect_json(response, 400) == %{
               "contract_version" => 1,
               "error" => "unsupported_session_lifecycle_version"
             }
    end

    duplicate_version =
      :get
      |> conn("/v1/comma/auth/session")
      |> web_cookie_request(origin, :unknown)
      |> prepend_req_header("x-comma-session-lifecycle-version", "1")
      |> call()

    assert expect_json(duplicate_version, 400)["error"] ==
             "unsupported_session_lifecycle_version"

    for expectation <- [nil, "not-a-session", "none, none"] do
      request =
        :get
        |> conn("/v1/comma/auth/session")
        |> put_req_header("origin", origin)
        |> put_req_header("x-comma-session-transport", "cookie")
        |> put_req_header("x-comma-session-lifecycle-version", "1")

      request =
        if expectation,
          do: put_req_header(request, "x-comma-expected-auth-session-id", expectation),
          else: request

      assert request |> call() |> expect_json(400) == %{
               "error" => "invalid_session_precondition"
             }
    end

    duplicate_expectation =
      :get
      |> conn("/v1/comma/auth/session")
      |> web_cookie_request(origin, :unknown)
      |> prepend_req_header("x-comma-expected-auth-session-id", "unknown")
      |> call()

    assert expect_json(duplicate_expectation, 400) == %{
             "error" => "invalid_session_precondition"
           }

    invalid_product_expectation =
      :get
      |> conn("/v1/comma/workspaces")
      |> web_cookie_request(origin, :none)
      |> call()

    assert expect_json(invalid_product_expectation, 400)["error"] ==
             "invalid_session_precondition"

    assert get_resp_header(invalid_product_expectation, "cache-control") == ["no-store"]

    invalid_auth_expectation =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "invalid-expectation@example.com"})
      |> web_cookie_request(origin, Ecto.UUID.generate())
      |> call()

    assert expect_json(invalid_auth_expectation, 400)["error"] ==
             "invalid_session_precondition"

    invalid_transport =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "invalid-transport@example.com"})
      |> web_cookie_request(origin, :none)
      |> put_req_header("x-comma-session-transport", "bearer")
      |> call()

    assert expect_json(invalid_transport, 400) == %{"error" => "invalid_session_transport"}
  end

  test "missing or duplicate Web transport headers fence auth mutation side effects" do
    origin = "http://127.0.0.1:5174"

    for {variant, add_transport} <- [
          {:missing,
           fn conn ->
             conn
             |> put_req_header("origin", origin)
             |> put_req_header("x-comma-session-lifecycle-version", "1")
             |> put_req_header("x-comma-expected-auth-session-id", "none")
           end},
          {:duplicate,
           fn conn ->
             conn
             |> web_cookie_request(origin, :none)
             |> prepend_req_header("x-comma-session-transport", "cookie")
           end}
        ] do
      email = "#{variant}-transport@example.com"

      pending =
        :post
        |> json_conn("/v1/comma/auth/email/login", %{"email" => email})
        |> call()
        |> expect_json(200)

      rejected =
        :post
        |> json_conn("/v1/comma/auth/email/verify", %{
          "challenge_id" => pending["challenge_id"],
          "code" => pending["code"]
        })
        |> add_transport.()
        |> call()

      assert expect_json(rejected, 400) == %{"error" => "invalid_session_transport"}
      assert rejected.resp_cookies == %{}
      assert {:error, :not_found} = Comma.Accounts.get_user_by_email(email)

      assert %{"user" => %{"email" => ^email}} =
               :post
               |> json_conn("/v1/comma/auth/email/verify", %{
                 "challenge_id" => pending["challenge_id"],
                 "code" => pending["code"]
               })
               |> web_cookie_request(origin, :none)
               |> call()
               |> expect_json(200)
    end
  end

  test "native auth requires exactly one bearer discriminator before mutation" do
    for {variant, add_transport} <- [
          {:missing, &Function.identity/1},
          {:duplicate,
           fn conn ->
             conn
             |> put_req_header("x-comma-session-transport", "bearer")
             |> prepend_req_header("x-comma-session-transport", "bearer")
           end},
          {:unknown, &put_req_header(&1, "x-comma-session-transport", "legacy")},
          {:conflicting,
           fn conn ->
             conn
             |> put_req_header("x-comma-session-transport", "bearer")
             |> prepend_req_header("x-comma-session-transport", "cookie")
           end}
        ] do
      email = "native-#{variant}-transport@example.com"

      pending =
        :post
        |> json_conn("/v1/comma/auth/email/login", %{"email" => email})
        |> call()
        |> expect_json(200)

      rejected =
        :post
        |> json_conn("/v1/comma/auth/email/verify", %{
          "challenge_id" => pending["challenge_id"],
          "code" => pending["code"]
        })
        |> add_transport.()
        |> raw_call()

      assert expect_json(rejected, 400) == %{"error" => "invalid_session_transport"}
      assert rejected.resp_cookies == %{}
      assert {:error, :not_found} = Comma.Accounts.get_user_by_email(email)

      assert %{"token" => token, "user" => %{"email" => ^email}} =
               :post
               |> json_conn("/v1/comma/auth/email/verify", %{
                 "challenge_id" => pending["challenge_id"],
                 "code" => pending["code"]
               })
               |> put_req_header("x-comma-session-transport", "bearer")
               |> raw_call()
               |> expect_json(200)

      assert is_binary(token)
    end
  end

  test "an allowed secondary origin cannot become a second Web Cookie authority" do
    canonical_origin = "http://127.0.0.1:5174"
    secondary_origin = "http://localhost:5173"

    preflight =
      :options
      |> conn("/v1/comma/auth/email/verify")
      |> put_req_header("origin", secondary_origin)
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header("access-control-request-headers", "x-comma-session-transport")
      |> call()

    assert expect_json(preflight, 403) == %{"error" => "web_cookie_origin_not_allowed"}

    pending =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "secondary-origin@example.com"})
      |> call()
      |> expect_json(200)

    secondary_verify =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => pending["challenge_id"],
        "code" => pending["code"]
      })
      |> web_cookie_request(secondary_origin, :none)
      |> call()

    assert expect_json(secondary_verify, 403) == %{
             "error" => "web_cookie_origin_not_allowed"
           }

    assert secondary_verify.resp_cookies == %{}
    assert {:error, :not_found} = Comma.Accounts.get_user_by_email("secondary-origin@example.com")

    assert %{"user" => %{"email" => "secondary-origin@example.com"}} =
             :post
             |> json_conn("/v1/comma/auth/email/verify", %{
               "challenge_id" => pending["challenge_id"],
               "code" => pending["code"]
             })
             |> web_cookie_request(canonical_origin, :none)
             |> call()
             |> expect_json(200)
  end

  test "Web Session mismatch fences auth consumption, last-seen, product work, and logout" do
    origin = "http://127.0.0.1:5174"
    active = email_login!("web-fence-active@example.com")
    old_last_seen = DateTime.add(DateTime.utc_now(), -600) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(session in AuthSession, where: session.id == ^active["session_id"]),
      set: [last_seen_at: old_last_seen, updated_at: old_last_seen]
    )

    pending =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "web-fence-pending@example.com"})
      |> call()
      |> expect_json(200)

    verify_mismatch =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => pending["challenge_id"],
        "code" => pending["code"]
      })
      |> put_req_header(
        "cookie",
        "#{CommaWeb.SessionCookie.cookie_name()}=#{active["token"]}"
      )
      |> web_cookie_request(origin, :none)
      |> call()

    assert expect_json(verify_mismatch, 409) == %{"error" => "session_changed"}
    assert verify_mismatch.resp_cookies == %{}

    assert {:error, :not_found} =
             Comma.Accounts.get_user_by_email("web-fence-pending@example.com")

    assert DateTime.compare(
             Repo.get!(AuthSession, active["session_id"]).last_seen_at,
             old_last_seen
           ) == :eq

    assert %{"token" => _, "session_id" => _} =
             :post
             |> json_conn("/v1/comma/auth/email/verify", %{
               "challenge_id" => pending["challenge_id"],
               "code" => pending["code"]
             })
             |> call()
             |> expect_json(200)

    wrong_session_id = Ecto.UUID.generate()

    product_mismatch =
      :post
      |> json_conn("/v1/comma/me/bootstrap", %{})
      |> cookie_auth(active["token"], origin, wrong_session_id)
      |> call()

    assert expect_json(product_mismatch, 409) == %{"error" => "session_changed"}
    assert product_mismatch.resp_cookies == %{}
    assert get_resp_header(product_mismatch, "cache-control") == ["no-store"]

    assert Repo.aggregate(
             from(workspace in Comma.Data.Workspace,
               where: workspace.owner_user_id == ^active["user"]["id"]
             ),
             :count
           ) == 0

    assert DateTime.compare(
             Repo.get!(AuthSession, active["session_id"]).last_seen_at,
             old_last_seen
           ) == :eq

    logout_mismatch =
      :post
      |> json_conn("/v1/comma/auth/logout", %{})
      |> cookie_auth(active["token"], origin, wrong_session_id)
      |> call()

    assert expect_json(logout_mismatch, 409) == %{"error" => "session_changed"}
    assert logout_mismatch.resp_cookies == %{}
    assert {:ok, _user, _session} = Comma.Accounts.resolve_session(active["token"])
  end

  test "bearer Session paths do not require or emit the Web cookie protocol" do
    session = email_login!("bearer-hard-cut@example.com")

    assert %{
             "expires_at" => _expires_at,
             "session_id" => session_id,
             "token" => token,
             "user" => %{"email" => "bearer-hard-cut@example.com"}
           } = session

    current_conn =
      :get
      |> conn("/v1/comma/auth/session")
      |> user_auth(token)
      |> call()

    assert %{"session_id" => ^session_id} = expect_json(current_conn, 200)
    assert current_conn.resp_cookies == %{}

    logout_conn =
      :post
      |> json_conn("/v1/comma/auth/logout", %{})
      |> user_auth(token)
      |> call()

    assert expect_json(logout_conn, 200) == %{"signed_out" => true}
    assert logout_conn.resp_cookies == %{}

    assert 401 ==
             (:get
              |> conn("/v1/comma/workspaces")
              |> user_auth(token)
              |> call()).status
  end

  test "unknown personal paths stay inside the Comma product auth boundary" do
    unauthenticated =
      :get
      |> conn("/v1/comma/me/comma-release-unknown")
      |> call()

    assert unauthenticated.halted
    assert expect_json(unauthenticated, 401) == %{"error" => "unauthorized"}

    session = email_login!("unknown-personal-path@example.com")

    authenticated =
      :get
      |> conn("/v1/comma/me/comma-release-unknown")
      |> user_auth(session["token"])
      |> call()

    assert expect_json(authenticated, 404) == %{"error" => "not_found"}
  end

  test "ops admin auth rejects different-length deployment tokens without raising" do
    for invalid_token <- ["x", @admin_token <> "-longer"] do
      response =
        :get
        |> conn("/v1/comma/admin/users")
        |> put_req_header("authorization", "Bearer #{invalid_token}")
        |> call()

      assert response.halted
      assert response.status == 401
      assert Jason.decode!(response.resp_body) == %{"error" => "unauthorized"}
    end

    assert :get
           |> conn("/v1/comma/admin/users")
           |> admin_auth()
           |> call()
           |> expect_json(200)

    response =
      :get
      |> conn("/v1/admin/vm/worker-release")
      |> admin_auth()
      |> call()

    assert response.halted
    assert response.status == 401
    assert Jason.decode!(response.resp_body) == %{"error" => "unauthorized"}
  end

  test "auth success and error responses are never cacheable" do
    login_conn =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "no-store@example.com"})
      |> call()

    login = expect_json(login_conn, 200)
    assert get_resp_header(login_conn, "cache-control") == ["no-store"]

    verify_conn =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => login["challenge_id"],
        "code" => wrong_code(login["code"])
      })
      |> call()

    assert %{"error" => "invalid_verification_code"} = expect_json(verify_conn, 401)
    assert get_resp_header(verify_conn, "cache-control") == ["no-store"]

    session_conn =
      :get
      |> conn("/v1/comma/auth/session")
      |> call()

    assert %{"error" => "unauthorized"} = expect_json(session_conn, 401)
    assert get_resp_header(session_conn, "cache-control") == ["no-store"]
  end

  test "a legacy comma_sessions bearer never authenticates a passwordless request" do
    raw_token = "comma_sess_legacy_imported_bearer"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, user} =
             Comma.Accounts.Repository.ensure_user_by_email("legacy-session@example.com")

    Comma.Repo.insert!(
      Comma.Data.Session.changeset(%Comma.Data.Session{}, %{
        id: "ses_legacy_imported",
        token_hash: :crypto.hash(:sha256, raw_token),
        user_id: user.id,
        expires_at: DateTime.add(now, 3600),
        status: "active",
        restricted: false
      })
    )

    conn =
      :get
      |> conn("/v1/comma/auth/session")
      |> user_auth(raw_token)
      |> call()

    assert %{"error" => "unauthorized"} = expect_json(conn, 401)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "Comma product endpoint creates a user session and exposes workspace API" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "web@example.com", "name" => "Web"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    body =
      :get
      |> conn("/v1/comma/workspaces")
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert [%{"id" => id, "name" => "Workspace"}] = body["data"]
    assert id == workspace["id"]
  end

  test "pre-namespace non-admin paths serve the same Comma endpoints" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "legacy@example.com", "name" => "L"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    create_ready_workspace!(user["id"], "Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    list = fn path ->
      :get
      |> conn(path)
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)
    end

    assert list.("/v1/workspaces") == list.("/v1/comma/workspaces")
  end

  test "the Comma admin API exists only under /v1/comma/admin" do
    # /v1/admin belongs to Salix. Comma treats it as an unknown path inside its
    # user-session boundary: the admin credential does not reach an admin route.
    :post
    |> json_conn("/v1/admin/users", %{"email" => "old-admin@example.com"})
    |> admin_auth()
    |> call()
    |> expect_json(401)

    refute Comma.Repo.exists?(
             from(u in "comma_users",
               where: u.normalized_email == "old-admin@example.com",
               select: 1
             )
           )
  end

  test "the admin origin may send its session headers to every Comma admin section" do
    for path <- [
          "/v1/comma/admin/model-selection-policy/templates",
          "/v1/comma/admin/compute/agent-vmm/overview"
        ] do
      conn =
        :options
        |> conn(path)
        |> put_req_header("origin", @admin_origin)
        |> put_req_header("access-control-request-method", "GET")
        |> put_req_header("access-control-request-headers", "x-comma-session-transport")
        |> call()

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == [@admin_origin]
      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
    end
  end

  test "Synchronicity device ownership conflicts remain HTTP conflicts" do
    previous_config = Application.get_env(:comma_core, :synchronicity)
    previous_client = Application.get_env(:comma_core, :synchronicity_client)

    on_exit(fn ->
      restore_env(:comma_core, :synchronicity, previous_config)
      restore_env(:comma_core, :synchronicity_client, previous_client)
    end)

    Application.delete_env(:comma_core, :synchronicity)
    Application.delete_env(:comma_core, :synchronicity_client)

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "sync-conflict@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Synchronicity Workspace")

    Repo.update_all(
      from(w in Comma.Data.Workspace, where: w.id == ^workspace["id"]),
      set: [sync_org_id: "org-existing", sync_network_id: "net-existing"]
    )

    Application.put_env(:comma_core, :synchronicity,
      base_url: "http://sync.test",
      provisioning_secret: String.duplicate("x", 32)
    )

    Application.put_env(:comma_core, :synchronicity_client, __MODULE__.SynchConflictClient)

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    response =
      :put
      |> json_conn("/v1/comma/me/synchronicity/devices/current", %{
        "nk" => "nk-z32",
        "label" => "laptop"
      })
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()

    assert expect_json(response, 409) == %{"error" => "device_conflict"}
  end

  test "Comma Main authorizes one exact workspace Agent VMM install target" do
    previous =
      Application.get_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled)

    Application.put_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled, true)

    on_exit(fn ->
      restore_env(
        :salix_store,
        :agent_vmm_environment_scoped_bindings_enabled,
        previous
      )
    end)

    suffix = System.unique_integer([:positive])

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "compute-#{suffix}@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Compute Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    path =
      "/v1/comma/workspaces/#{workspace["id"]}/compute-nodes/agent-vmm/install-operations"

    created =
      :post
      |> json_conn(path, %{})
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> put_req_header("idempotency-key", "comma-install-#{suffix}")
      |> call()

    body = expect_json(created, 200)
    assert get_resp_header(created, "cache-control") == ["no-store"]
    assert body["operation"]["status"] == "processing"
    assert body["descriptor"]["operation_id"] == body["operation"]["id"]
    assert is_binary(body["descriptor"]["one_time_secret"])

    assert {:error, :no_pending_operation} =
             SalixStore.AgentVMMInstallations.deliver_next(
               "comma_main_device",
               "another-device"
             )

    assert {:ok, delivered} =
             SalixStore.AgentVMMInstallations.deliver_next(
               "comma_main_device",
               session["id"]
             )

    assert delivered.operation.id == body["operation"]["id"]

    fetched =
      :get
      |> conn(path <> "/#{body["operation"]["id"]}")
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()

    fetched_body = expect_json(fetched, 200)
    assert get_resp_header(fetched, "cache-control") == ["no-store"]
    refute fetched.resp_body =~ "one_time_secret"
    assert fetched_body["operation"]["delivery_target_id"] == session["id"]

    other_session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    foreign_retry =
      :post
      |> json_conn(path <> "/#{body["operation"]["id"]}/retry", %{})
      |> put_req_header("authorization", "Bearer #{other_session["token"]}")
      |> call()

    assert foreign_retry.status == 404
  end

  test "restricted ops sessions return a top-level token without an S3 grant wrapper" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "restricted-session@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => "wsp_restricted",
        "budget" => 3,
        "tool_allowlist" => ["echo"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert "comma_sess_" <> _ = session["token"]
    assert session["restricted"] == true
    assert session["workspace_id"] == "wsp_restricted"
    assert session["interaction_budget_remaining"] == 3
    assert session["tool_allowlist"] == ["echo"]
    refute Map.has_key?(session, "session")
    assert Comma.Migrations.LegacyS3Fixture.all(:grants) == []
  end

  test "admin session issuance rejects contradictory capabilities and unbounded options" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "invalid-session-options@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    contradictory = [
      %{"restricted" => false, "workspace_id" => "wsp_scope"},
      %{"restricted" => false, "conversation_id" => "cnv_scope"},
      %{"restricted" => false, "budget" => 1},
      %{"restricted" => false, "tool_allowlist" => ["echo"]},
      %{"restricted" => false, "expires_in_seconds" => 60},
      %{"budget" => 1},
      %{"tool_allowlist" => []},
      %{"expires_in_seconds" => 60},
      %{"restricted" => true, "ttl_seconds" => 60},
      # Non-boolean restricted values never coerce into a capability.
      %{"restricted" => "true", "workspace_id" => "wsp_invalid_restricted"},
      %{"restricted" => "false", "workspace_id" => "wsp_invalid_restricted"},
      %{"restricted" => 1, "workspace_id" => "wsp_invalid_restricted"},
      %{"restricted" => nil, "workspace_id" => "wsp_invalid_restricted"},
      # A conversation scope needs its owning Group.
      %{
        "restricted" => true,
        "workspace_id" => "wsp_not_conversation_authority",
        "conversation_id" => "cnv_missing_group_scope"
      }
    ]

    for body <- contradictory do
      assert %{"error" => "invalid_restricted"} =
               :post
               |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", body)
               |> admin_auth()
               |> call()
               |> expect_json(400)
    end

    for ttl <- [-1, 0, 3601, "60", nil] do
      assert %{"error" => "invalid_ttl_seconds"} =
               :post
               |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
                 "restricted" => false,
                 "ttl_seconds" => ttl
               })
               |> admin_auth()
               |> call()
               |> expect_json(400)
    end

    for budget <- [-1, 1001, "1"] do
      assert %{"error" => "invalid_budget"} =
               :post
               |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
                 "restricted" => true,
                 "budget" => budget
               })
               |> admin_auth()
               |> call()
               |> expect_json(400)
    end

    assert %{"error" => "invalid_tool_allowlist"} =
             :post
             |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
               "restricted" => true,
               "tool_allowlist" => "echo"
             })
             |> admin_auth()
             |> call()
             |> expect_json(400)

    assert Repo.aggregate(
             from(session in Comma.Accounts.AuthSession, where: session.user_id == ^user["id"]),
             :count
           ) == 0

    assert %{"restricted" => false} =
             :post
             |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
               "restricted" => false,
               "ttl_seconds" => 3600
             })
             |> admin_auth()
             |> call()
             |> expect_json(201)
  end

  test "only an explicitly enabled local developer session may exceed the production ttl" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "local-dev-session@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    previous = Application.get_env(:comma_core, :local_dev_session_ttl_seconds)
    Application.delete_env(:comma_core, :local_dev_session_ttl_seconds)

    on_exit(fn ->
      restore_env(:comma_core, :local_dev_session_ttl_seconds, previous)
    end)

    assert %{"error" => "local_dev_session_unavailable"} =
             :post
             |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
               "local_dev" => true,
               "ttl_seconds" => 31_536_000
             })
             |> admin_auth()
             |> call()
             |> expect_json(400)

    Application.put_env(:comma_core, :local_dev_session_ttl_seconds, 31_536_000)

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "local_dev" => true,
        "ttl_seconds" => 31_536_000
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert session["device_label"] == "Local developer session"
    assert session["expires_at"] - session["authenticated_at"] == 31_536_000

    assert %{"error" => "invalid_ttl_seconds"} =
             :post
             |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
               "local_dev" => false,
               "ttl_seconds" => 31_536_000
             })
             |> admin_auth()
             |> call()
             |> expect_json(400)
  end

  test "restricted sessions cannot list or revoke the user's real sessions" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "restricted-session-management@example.com"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    ordinary =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => "wsp_restricted_session_management"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert %{"error" => "forbidden"} =
             :get
             |> conn("/v1/comma/auth/sessions")
             |> user_auth(restricted["token"])
             |> call()
             |> expect_json(403)

    assert %{"error" => "forbidden"} =
             :delete
             |> conn("/v1/comma/auth/sessions/#{ordinary["id"]}")
             |> user_auth(restricted["token"])
             |> call()
             |> expect_json(403)

    assert %{"error" => "forbidden"} =
             :post
             |> json_conn("/v1/comma/auth/sessions/revoke-all", %{})
             |> user_auth(restricted["token"])
             |> call()
             |> expect_json(403)

    assert %{"signed_out" => true} =
             :post
             |> json_conn("/v1/comma/auth/logout", %{})
             |> user_auth(restricted["token"])
             |> call()
             |> expect_json(200)

    assert %{"user" => %{"id" => user_id}} =
             :get
             |> conn("/v1/comma/auth/session")
             |> user_auth(ordinary["token"])
             |> call()
             |> expect_json(200)

    assert user_id == user["id"]
  end

  test "restricted sessions cannot read or mutate global profile state" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "restricted-profile@example.com",
        "name" => "Original"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => "wsp_restricted_profile"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    for {method, path, body} <- [
          {:get, "/v1/comma/me/profile", nil},
          {:patch, "/v1/comma/me/profile", %{"name" => "Mutated"}},
          {:put, "/v1/comma/me/avatar", %{}},
          {:get, "/v1/comma/me/avatar/avt_restricted", nil},
          {:delete, "/v1/comma/me/avatar", nil}
        ] do
      request = if body, do: json_conn(method, path, body), else: conn(method, path)

      assert %{"error" => "forbidden"} =
               request
               |> user_auth(restricted["token"])
               |> call()
               |> expect_json(403)
    end

    assert {:ok, profile} = Comma.ProfileAvatar.get(user["id"])
    assert profile["name"] == "Original"
    assert profile["avatar_id"] == nil
  end

  test "lifecycle-v1 keeps its released user shape while profile loads separately" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "session-profile-compat@example.com",
        "name" => "Compatibility"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    lifecycle =
      :get
      |> conn("/v1/comma/auth/session")
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert Map.keys(lifecycle["user"]) |> Enum.sort() == ["email", "id", "name", "status"]
    refute Map.has_key?(lifecycle["user"], "avatar_id")

    profile =
      :get
      |> conn("/v1/comma/me/profile")
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert Map.take(profile, ["id", "email", "name", "avatar_id"]) == %{
             "id" => user["id"],
             "email" => "session-profile-compat@example.com",
             "name" => "Compatibility",
             "avatar_id" => nil
           }
  end

  test "revoking a malformed or missing session id is idempotent" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "idempotent-session-revoke@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    for session_id <- ["not-a-uuid", Ecto.UUID.generate()] do
      assert %{"revoked" => true} =
               :delete
               |> conn("/v1/comma/auth/sessions/#{session_id}")
               |> user_auth(session["token"])
               |> call()
               |> expect_json(200)
    end

    assert %{"user" => %{"id" => user_id}} =
             :get
             |> conn("/v1/comma/auth/session")
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    assert user_id == user["id"]
  end

  test "ops user listing uses a signed filter-bound keyset cursor" do
    users =
      for index <- 1..3 do
        assert {:ok, user} =
                 Comma.Accounts.create_user(%{
                   "email" => "admin-page-#{index}@example.com",
                   "name" => "Admin page #{index}"
                 })

        user
      end

    first =
      :get
      |> conn("/v1/comma/admin/users?limit=2")
      |> admin_auth()
      |> call()
      |> expect_json(200)

    assert length(first["data"]) == 2
    assert first["has_more"]
    assert is_binary(first["next_cursor"])

    second =
      :get
      |> conn("/v1/comma/admin/users?limit=2&cursor=#{URI.encode_www_form(first["next_cursor"])}")
      |> admin_auth()
      |> call()
      |> expect_json(200)

    assert length(second["data"]) == 1
    refute second["has_more"]
    assert second["next_cursor"] == nil

    listed_ids = Enum.map(first["data"] ++ second["data"], & &1["id"])
    assert Enum.sort(listed_ids) == users |> Enum.map(& &1["id"]) |> Enum.sort()
    assert Enum.uniq(listed_ids) == listed_ids

    assert %{"error" => "invalid_cursor"} =
             :get
             |> conn(
               "/v1/comma/admin/users?cursor=#{URI.encode_www_form(first["next_cursor"] <> "x")}"
             )
             |> admin_auth()
             |> call()
             |> expect_json(400)

    filtered_email = hd(users)["email"]

    assert %{"data" => [%{"email" => ^filtered_email}], "has_more" => false} =
             :get
             |> conn(
               "/v1/comma/admin/users?email=#{URI.encode_www_form(String.upcase(filtered_email))}"
             )
             |> admin_auth()
             |> call()
             |> expect_json(200)

    assert %{"error" => "invalid_cursor"} =
             :get
             |> conn(
               "/v1/comma/admin/users?email=#{URI.encode_www_form(filtered_email)}&cursor=#{URI.encode_www_form(first["next_cursor"])}"
             )
             |> admin_auth()
             |> call()
             |> expect_json(400)

    assert %{"error" => "invalid_filter"} =
             :get
             |> conn("/v1/comma/admin/users?email=not-an-email")
             |> admin_auth()
             |> call()
             |> expect_json(400)

    assert %{"error" => "invalid_filter"} =
             :get
             |> conn("/v1/comma/admin/users?email=")
             |> admin_auth()
             |> call()
             |> expect_json(400)

    assert %{"error" => "invalid_cursor"} =
             :get
             |> conn("/v1/comma/admin/users?cursor=")
             |> admin_auth()
             |> call()
             |> expect_json(400)
  end

  test "Admin user projections expose bounded login-method metadata without provider subjects" do
    assert {:ok, user} =
             Comma.Accounts.create_user(%{
               "email" => "admin-identity@example.com",
               "name" => "Identity Example"
             })

    assert {:ok, _identity} =
             Comma.Accounts.Repository.ensure_identity(user["id"], %{
               provider: "google",
               issuer: "https://accounts.google.com",
               subject: "admin-route-google-subject",
               email_snapshot: "admin-identity@gmail.com",
               email_verified: true,
               last_authenticated_at: ~U[2026-07-25 08:30:00.000000Z]
             })

    detail =
      :get
      |> conn("/v1/comma/admin/users/#{user["id"]}")
      |> admin_auth()
      |> call()
      |> expect_json(200)

    assert [
             %{"method" => "email_otp", "email" => "admin-identity@example.com"},
             %{
               "method" => "google",
               "email_snapshot" => "admin-identity@gmail.com",
               "email_verified" => true,
               "linked_at" => linked_at,
               "last_authenticated_at" => last_authenticated_at
             }
           ] = detail["login_methods"]

    assert is_integer(linked_at)
    assert last_authenticated_at == DateTime.to_unix(~U[2026-07-25 08:30:00.000000Z])
    refute inspect(detail) =~ "admin-route-google-subject"
    refute inspect(detail) =~ "accounts.google.com"

    list =
      :get
      |> conn("/v1/comma/admin/users?email=admin-identity%40example.com")
      |> admin_auth()
      |> call()
      |> expect_json(200)

    assert [%{"login_methods" => login_methods}] = list["data"]
    assert login_methods == detail["login_methods"]
  end

  test "ops user pagination accepts grandfathered public IDs as cursor boundaries" do
    now = DateTime.utc_now()

    {2, nil} =
      Repo.insert_all(Comma.Accounts.User, [
        %{
          id: "7f659052-4028-460b-b9e8-79dca0d7be3d",
          email: "legacy-uuid-page@example.com",
          name: "Legacy UUID",
          status: "active",
          auth_epoch: 0,
          created_at: DateTime.add(now, 120, :second),
          updated_at: now
        },
        %{
          id: "usr-legacy-imported-account",
          email: "legacy-dash-page@example.com",
          name: "Legacy Dash",
          status: "active",
          auth_epoch: 0,
          created_at: DateTime.add(now, 60, :second),
          updated_at: now
        }
      ])

    assert {:ok, current} =
             Comma.Accounts.create_user(%{"email" => "current-page@example.com"})

    first =
      :get
      |> conn("/v1/comma/admin/users?limit=1")
      |> admin_auth()
      |> call()
      |> expect_json(200)

    assert Enum.map(first["data"], & &1["id"]) == [
             "7f659052-4028-460b-b9e8-79dca0d7be3d"
           ]

    second =
      :get
      |> conn("/v1/comma/admin/users?limit=1&cursor=#{URI.encode_www_form(first["next_cursor"])}")
      |> admin_auth()
      |> call()
      |> expect_json(200)

    assert Enum.map(second["data"], & &1["id"]) == ["usr-legacy-imported-account"]

    third =
      :get
      |> conn(
        "/v1/comma/admin/users?limit=1&cursor=#{URI.encode_www_form(second["next_cursor"])}"
      )
      |> admin_auth()
      |> call()
      |> expect_json(200)

    assert Enum.map(third["data"], & &1["id"]) == [current["id"]]
    refute third["has_more"]
    assert third["next_cursor"] == nil
  end

  test "ops user pagination uses the deployment credential authenticated from config json" do
    token = "config-json-admin-token"

    config_path =
      Path.join(
        System.tmp_dir!(),
        "comma-admin-pagination-#{System.unique_integer([:positive])}.json"
      )

    previous_config_path = System.get_env("SALIX_CONFIG_PATH")
    previous_salix_token = Application.get_env(:salix_web, :api_token)

    File.write!(config_path, Jason.encode!(%{"web" => %{"api_token" => token}}))
    System.put_env("SALIX_CONFIG_PATH", config_path)
    Application.delete_env(:comma_web, :api_token)
    Application.delete_env(:salix_web, :api_token)

    on_exit(fn ->
      case previous_config_path do
        nil -> System.delete_env("SALIX_CONFIG_PATH")
        value -> System.put_env("SALIX_CONFIG_PATH", value)
      end

      restore_env(:salix_web, :api_token, previous_salix_token)
      File.rm(config_path)
    end)

    for index <- 1..2 do
      assert {:ok, _user} =
               Comma.Accounts.create_user(%{
                 "email" => "config-json-page-#{index}@example.com"
               })
    end

    first =
      :get
      |> conn("/v1/comma/admin/users?limit=1")
      |> put_req_header("authorization", "Bearer #{token}")
      |> call()
      |> expect_json(200)

    assert first["has_more"]
    assert is_binary(first["next_cursor"])

    second =
      :get
      |> conn("/v1/comma/admin/users?limit=1&cursor=#{URI.encode_www_form(first["next_cursor"])}")
      |> put_req_header("authorization", "Bearer #{token}")
      |> call()
      |> expect_json(200)

    refute second["has_more"]
    assert second["next_cursor"] == nil
  end

  test "a device can be read and deleted before its first Connector connection" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "device-before-connect@example.com"})
    workspace = create_ready_workspace!(user["id"], "Unconnected devices")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    root = "/v1/comma/workspaces/#{workspace["id"]}"

    token =
      :post
      |> json_conn(root <> "/connector-token", %{
        "scope" => "local_file_read",
        "name" => "Unconnected device"
      })
      |> user_auth(session["token"])
      |> call()
      |> expect_json(201)

    path = root <> "/devices/#{token["device_id"]}"

    page =
      :get
      |> conn(root <> "/devices")
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert Enum.any?(page["devices"], &(&1["device_id"] == token["device_id"]))
    detail = :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)
    assert detail["status"] == "disconnected"
    assert detail["allows_operations"] == false
    assert detail["environments"] == []
    assert Enum.all?(page["devices"], &(&1["allows_operations"] == false))

    assert %{"removed" => true} =
             :delete |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)

    :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(404)

    page =
      :get
      |> conn(root <> "/devices")
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    refute Enum.any?(page["devices"], &(&1["device_id"] == token["device_id"]))
    {:ok, _, credential} = SalixEnv.ConnectorTokens.validate_connector_token(token["token"])
    refute SalixEnv.ConnectorTokens.credential_active?(credential["token_hash"])
  end

  test "device names survive reconnect and deletion removes only the selected workspace device" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "device-manage@example.com"})
    workspace = create_ready_workspace!(user["id"], "Device management")
    {:ok, other_user} = Comma.Accounts.create_user(%{"email" => "other-devices@example.com"})
    other = create_ready_workspace!(other_user["id"], "Other devices")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    :ok = CommaWeb.TestConvergence.workspace!(other["id"])

    {:ok, token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        %{}
      )

    {:ok, retained} =
      SalixEnv.ConnectorTokens.create_group_connector_token(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        %{}
      )

    path = "/v1/comma/workspaces/#{workspace["id"]}/devices/#{token["device_id"]}"

    assert {:ok, _, _} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => workspace["salix_tenant_id"],
                 "group_id" => workspace["default_group_id"],
                 "device_id" => token["device_id"],
                 "connector_id" => token["connector_id"],
                 "name" => "Default workspace Connector",
                 "system_info" => %{"hostname" => "office-mini"}
               },
               connection_generation: 0,
               credential_generation: token["credential_generation"],
               transport_id: "device-name-test"
             )

    discovered = :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)
    assert discovered["name"] == "office-mini"

    for method <- [:put, :delete] do
      method
      |> json_conn("/v1/comma/workspaces/#{other["id"]}/devices/#{token["device_id"]}", %{
        "name" => "Wrong workspace"
      })
      |> user_auth(session["token"])
      |> call()
      |> expect_json(403)
    end

    :put
    |> json_conn(path, %{"name" => "  "})
    |> user_auth(session["token"])
    |> call()
    |> expect_json(400)

    renamed =
      :put
      |> json_conn(path, %{"name" => "  Office Mac  "})
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert renamed["name"] == "Office Mac"

    assert {:ok, _, connected} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => workspace["salix_tenant_id"],
                 "group_id" => workspace["default_group_id"],
                 "device_id" => token["device_id"],
                 "connector_id" => token["connector_id"],
                 "name" => "Old hostname",
                 "system_info" => %{"hostname" => "new-hostname"}
               },
               connection_generation: 1,
               credential_generation: token["credential_generation"],
               transport_id: "device-manage-test"
             )

    {:ok, _} = SalixEnv.Registry.mark_disconnected(connected["connector_run_id"])
    detail = :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)
    assert detail["name"] == "Office Mac"

    assert {:ok, _, reconnected} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => workspace["salix_tenant_id"],
                 "group_id" => workspace["default_group_id"],
                 "device_id" => token["device_id"],
                 "connector_id" => token["connector_id"],
                 "name" => "Old hostname",
                 "system_info" => %{"hostname" => "new-hostname"}
               },
               connection_generation: 2,
               credential_generation: token["credential_generation"],
               transport_id: "device-manage-reconnect"
             )

    assert SalixEnv.Control.environment_json(reconnected)["name"] == "Office Mac"

    assert %{"removed" => true} =
             :delete |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(200)

    :get |> conn(path) |> user_auth(session["token"]) |> call() |> expect_json(404)
    {:ok, _, credential} = SalixEnv.ConnectorTokens.validate_connector_token(token["token"])
    refute SalixEnv.ConnectorTokens.credential_active?(credential["token_hash"])

    assert {:error, :not_found} =
             SalixEnv.Registry.get_by_connector_run_id(reconnected["connector_run_id"])

    assert {:ok, _} =
             SalixEnv.Registry.get_device(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               retained["device_id"]
             )
  end

  test "Comma user session mints a scoped attachment connector token and revokes it" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "scoped-connector@example.com",
        "name" => "Scoped"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Scoped Connector Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    token =
      :post
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
        "expires_in_seconds" => 7_200,
        "scope" => "local_file_read"
      })
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(201)

    assert token["scope"] == "local_file_read"
    assert "salix_conn_" <> _ = token["token"]
    assert "dev_" <> _ = token["device_id"]
    assert is_integer(token["credential_generation"])
    now = System.system_time(:second)
    assert_in_delta token["expires_at"], now + 7_200, 60

    # The stored device identity re-attaches only after the registry proves
    # continuity for this owner. The run carries the credential's own
    # connector identity so a later revocation is fenced to exactly this run.
    assert {:ok, _transport_id, _device} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => workspace["salix_tenant_id"],
                 "group_id" => workspace["default_group_id"],
                 "device_id" => token["device_id"],
                 "connector_id" => token["connector_id"],
                 "owner_user_id" => user["id"],
                 "scope" => "local_file_read",
                 "credential_generation" => token["credential_generation"]
               },
               connection_generation: 1,
               credential_generation: token["credential_generation"],
               token_expires_at: token["expires_at"],
               transport_id: "comma-scoped-endpoint-test"
             )

    page =
      :get
      |> conn("/v1/comma/workspaces/#{workspace["id"]}/devices?limit=20")
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert [visible] = page["devices"]
    assert visible["device_id"] == token["device_id"]
    assert visible["allows_operations"] == false
    refute Map.has_key?(visible, "connector_run_id")
    refute Map.has_key?(visible, "token")

    detail =
      :get
      |> conn("/v1/comma/workspaces/#{workspace["id"]}/devices/#{token["device_id"]}")
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert detail["device_id"] == visible["device_id"]

    {:ok, full_token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(
        workspace["default_group_id"],
        workspace["salix_tenant_id"],
        %{}
      )

    assert {:ok, _, _} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => workspace["salix_tenant_id"],
                 "group_id" => workspace["default_group_id"],
                 "device_id" => full_token["device_id"],
                 "connector_id" => full_token["connector_id"],
                 "owner_user_id" => user["id"],
                 "capabilities" => %{"scope" => ""}
               },
               connection_generation: 1,
               credential_generation: full_token["credential_generation"],
               transport_id: "comma-full-device-read-test"
             )

    full_device =
      :get
      |> conn("/v1/comma/workspaces/#{workspace["id"]}/devices/#{full_token["device_id"]}")
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert full_device["allows_operations"] == true

    :get
    |> conn("/v1/comma/workspaces/#{workspace["id"]}/devices?limit=51")
    |> put_req_header("authorization", "Bearer #{session["token"]}")
    |> call()
    |> expect_json(400)

    reissued =
      :post
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
        "scope" => "local_file_read",
        "stable_device_id" => token["device_id"]
      })
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(201)

    assert reissued["device_id"] == token["device_id"]

    assert %{"revoked" => true} =
             :delete
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
               "token" => token["token"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(200)

    assert {:error, :unauthorized} =
             SalixEnv.ConnectorTokens.validate_connector_token(token["token"])

    assert {:ok, device} =
             SalixEnv.Registry.get_device(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               token["device_id"]
             )

    assert device["status"] == "disconnected"

    # The second credential still validates: revocation is per token.
    assert {:ok, _tenant, _rec} =
             SalixEnv.ConnectorTokens.validate_connector_token(reissued["token"])
  end

  test "direct installation uses workspace authorization without Drive setup" do
    root = Path.join(System.tmp_dir!(), "comma-api-install-#{System.unique_integer([:positive])}")

    for platform <- SalixStore.ConnectorInstall.platforms() do
      File.mkdir_p!(Path.join(root, platform))
      File.write!(Path.join([root, platform, "salix-connect"]), "fixture")
    end

    old = Application.get_env(:salix_env, :device_install_local_artifact_root)
    Application.put_env(:salix_env, :device_install_local_artifact_root, root)

    on_exit(fn ->
      if old,
        do: Application.put_env(:salix_env, :device_install_local_artifact_root, old),
        else: Application.delete_env(:salix_env, :device_install_local_artifact_root)

      File.rm_rf!(root)
    end)

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "direct-install@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Direct installation")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    token =
      :post
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
        "installation" => true,
        "name" => "My computer"
      })
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(201)

    assert is_binary(token["install_command"])
    assert token["install_command"] =~ "Type yes to install and connect"
    assert is_nil(token["expires_at"])
    assert token["registration_expires_at"] > System.system_time(:second)
    {:ok, _, record} = SalixEnv.ConnectorTokens.validate_connector_token(token["token"])
    assert record["meta"]["owner_user_id"] == user["id"]
    assert record["group_id"] == workspace["default_group_id"]

    :post
    |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
      "installation" => true
    })
    |> call()
    |> expect_json(401)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_ids" => [workspace["id"]]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :post
    |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
      "installation" => true
    })
    |> put_req_header("authorization", "Bearer #{restricted["token"]}")
    |> call()
    |> expect_json(403)
  end

  test "Comma user session mints a workspace connector token and bootstraps Salix scope" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "connector@example.com",
        "name" => "Conn"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Connector Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    tenant_id = workspace["salix_tenant_id"]

    token =
      :post
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{"alias" => "mac"})
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(201)

    assert "salix_conn_" <> _ = token["token"]
    assert token["server"] =~ "ws://"
    assert token["alias"] == "mac"
    refute Map.has_key?(token, "tenant_id")
    refute Map.has_key?(token, "group_id")
    refute Map.has_key?(token, "token_hash")

    assert {:ok, _} = Salix.Control.Tenants.get(workspace["salix_tenant_id"])

    assert {:ok, group} =
             Salix.Control.Groups.get(
               workspace["default_group_id"],
               workspace["salix_tenant_id"]
             )

    assert group["router_agent_id"] == workspace["router_agent_id"]

    assert {:ok, %{"role" => "router", "group_id" => group_id}} =
             SalixAgent.Control.get(
               group["router_agent_id"],
               workspace["salix_tenant_id"]
             )

    assert group_id == workspace["default_group_id"]

    assert {:ok, legacy_token} =
             SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
               "name" => "Legacy ownerless Connector"
             })

    assert {:ok, _legacy_tenant_id, legacy_rec} =
             SalixEnv.ConnectorTokens.validate_connector_token(legacy_token["token"])

    assert {:ok, _transport_id, _legacy_device} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => tenant_id,
                 "group_id" => group_id,
                 "device_id" => legacy_rec["device_id"],
                 "connector_id" => legacy_rec["connector_id"],
                 "capabilities" => %{"local_file_import_v1" => true}
               },
               connection_generation: 1,
               transport_id: "comma-ownerless-upgrade-test"
             )

    legacy_ref = "lfi1_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert %{
             "action" => "reissue_connector_token",
             "connector_token_endpoint" => connector_token_endpoint,
             "error" => "connector_reconfiguration_required",
             "reason" => "connector_owner_missing"
           } =
             :post
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
               "local_file_ref" => legacy_ref,
               "stable_device_id" => legacy_rec["device_id"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(409)

    assert connector_token_endpoint ==
             "/v1/comma/workspaces/#{workspace["id"]}/connector-token"

    assert {:ok, %{"role" => "worker", "group_id" => ^group_id}} =
             SalixAgent.Control.get(
               workspace["default_worker_agent_id"],
               workspace["salix_tenant_id"]
             )

    assert :ok = CommaWeb.SalixClient.provision_workspace_scope(workspace)
    assert :ok = CommaWeb.SalixClient.verify_workspace_scope(workspace)

    assert 2 ==
             workspace["salix_tenant_id"]
             |> SalixAgent.Control.list(group_id: workspace["default_group_id"])
             |> length()

    assert {:ok, ^tenant_id, connector_rec} =
             SalixEnv.ConnectorTokens.validate_connector_token(token["token"])

    assert connector_rec["meta"]["owner_user_id"] == user["id"]

    assert {:ok, _transport_id, legacy_reader_device} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => tenant_id,
                 "group_id" => workspace["default_group_id"],
                 "device_id" => connector_rec["device_id"],
                 "connector_id" => connector_rec["connector_id"],
                 "owner_user_id" => user["id"],
                 "capabilities" => %{"local_file_import_v1" => true}
               },
               connection_generation: 9,
               transport_id: "comma-local-file-registration-test"
             )

    legacy_registration_ref =
      "lfi1_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert %{"error" => "invalid_local_file_ref"} =
             :post
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
               "local_file_ref" => legacy_registration_ref,
               "path" => "/Users/owner/secret.txt",
               "stable_device_id" => connector_rec["device_id"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(400)

    assert %{"error" => "invalid_local_file_ref"} =
             :post
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
               "connector_run_id" => legacy_reader_device["connector_run_id"],
               "local_file_ref" => legacy_registration_ref,
               "stable_device_id" => connector_rec["device_id"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(400)

    assert %{"error" => "invalid_local_file_ref"} =
             :post
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
               "connector_run_id" => legacy_reader_device["connector_run_id"],
               "local_file_index_version" => 3,
               "local_file_ref" => legacy_registration_ref,
               "stable_device_id" => connector_rec["device_id"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(400)

    assert %{"error" => "invalid_local_file_ref"} =
             :post
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
               "connector_run_id" => legacy_reader_device["connector_run_id"],
               "extra" => true,
               "local_file_index_version" => 2,
               "local_file_ref" => legacy_registration_ref,
               "stable_device_id" => connector_rec["device_id"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(400)

    legacy_registration =
      :post
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
        "local_file_ref" => legacy_registration_ref,
        "stable_device_id" => connector_rec["device_id"]
      })
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(201)

    assert legacy_registration == %{
             "local_file_ref" => legacy_registration_ref,
             "state" => "registered"
           }

    old_run_id = legacy_reader_device["connector_run_id"]

    assert {:ok, _old_v2_reader} =
             SalixEnv.Registry.update_meta(old_run_id, fn meta ->
               Map.put(meta, "capabilities", %{
                 "local_file_import_v1" => true,
                 "local_file_index_version" => 2
               })
             end)

    assert {:ok, _transport_id, replacement_reader_device} =
             SalixEnv.Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => tenant_id,
                 "group_id" => workspace["default_group_id"],
                 "device_id" => connector_rec["device_id"],
                 "connector_id" => connector_rec["connector_id"],
                 "owner_user_id" => user["id"]
               },
               connection_generation: 10,
               transport_id: "comma-local-file-replacement-registration-test"
             )

    replacement_run_id = replacement_reader_device["connector_run_id"]
    refute replacement_run_id == old_run_id

    # The Registry merge can temporarily preserve the old run's V2 metadata.
    # A private status file for that old run must still fail the exact-run gate.
    assert get_in(replacement_reader_device, [
             "meta",
             "capabilities",
             "local_file_index_version"
           ]) == 2

    stale_status_ref =
      "lfi1_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert %{"error" => "local_file_ref_unavailable"} =
             :post
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
               "connector_run_id" => old_run_id,
               "local_file_index_version" => 2,
               "local_file_ref" => stale_status_ref,
               "stable_device_id" => connector_rec["device_id"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(503)

    assert {:error, :not_found} = SalixStore.LocalFileRefs.get(stale_status_ref)

    assert {:ok, _current_legacy_reader} =
             SalixEnv.Registry.update_meta(replacement_run_id, fn meta ->
               Map.put(meta, "capabilities", %{"local_file_import_v1" => true})
             end)

    current_status_ref =
      "lfi1_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert %{"error" => "local_file_ref_unavailable"} =
             :post
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
               "connector_run_id" => replacement_run_id,
               "local_file_index_version" => 2,
               "local_file_ref" => current_status_ref,
               "stable_device_id" => connector_rec["device_id"]
             })
             |> put_req_header("authorization", "Bearer #{session["token"]}")
             |> call()
             |> expect_json(503)

    assert {:error, :not_found} = SalixStore.LocalFileRefs.get(current_status_ref)

    assert {:ok, _current_v2_reader} =
             SalixEnv.Registry.update_meta(replacement_run_id, fn meta ->
               Map.put(meta, "capabilities", %{
                 "local_file_import_v1" => true,
                 "local_file_index_version" => 2
               })
             end)

    registration =
      :post
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/local-file-refs", %{
        "connector_run_id" => replacement_run_id,
        "local_file_index_version" => 2,
        "local_file_ref" => current_status_ref,
        "stable_device_id" => connector_rec["device_id"]
      })
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(201)

    assert registration == %{
             "local_file_ref" => current_status_ref,
             "state" => "registered"
           }

    refute Map.has_key?(registration, "owner_user_id")
    refute Map.has_key?(registration, "stable_device_id")

    # A recording attachment belongs to the authenticated person, not the
    # Router's historical shared participant named "current".
    chat =
      :post
      |> json_conn("/v1/comma/groups/#{group_id}/assistant-chat", %{})
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert {:ok, _grant} =
             BillingCore.Credits.issue_grant(%{
               repo: BillingCore.Repo,
               billing_account_id: "comma-ba-#{workspace["id"]}",
               credits: 100,
               valid_from: DateTime.add(DateTime.utc_now(), -60, :second),
               expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
               source_type: "manual_contract",
               source_id: current_status_ref,
               source_event_id: current_status_ref,
               idempotency_key: current_status_ref
             })

    summary_request = %{
      "client_request_id" => "recording-summary-#{current_status_ref}",
      "message" => %{
        "content" => [
          %{"type" => "text", "text" => "Summarize this meeting in a Task."},
          %{
            "type" => "local_file",
            "local_file_ref" => current_status_ref,
            "display_name" => "meeting.m4a",
            "media_type" => "audio/mp4",
            "size" => 334_562
          }
        ]
      }
    }

    :post
    |> json_conn(
      "/v1/comma/groups/#{group_id}/conversations/#{chat["id"]}/messages",
      summary_request
    )
    |> user_auth(session["token"])
    |> call()
    |> expect_json(202)

    assert {:ok, route} = SalixStore.LocalFileRefs.get(current_status_ref)
    assert route["state"] == "bound"
    assert route["owner_user_id"] == user["id"]
  end

  test "Chat ensure follows a rotated Salix Group Router without rolling it back" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "router-rotation@example.com",
        "name" => "Router Rotation"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Rotated Router Workspace")

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]
    original_router_id = workspace["router_agent_id"]
    rotated_router_id = SalixStore.Ids.new_agent_id(group_id)

    assert {:ok, _router} =
             SalixAgent.Control.create_preallocated(
               %{
                 "group_id" => group_id,
                 "name" => "Rotated Router",
                 "role" => "router",
                 "purpose" => "router_rotation_regression"
               },
               tenant_id,
               rotated_router_id
             )

    assert {:ok, _group} =
             Salix.Control.Groups.update(
               group_id,
               %{"router_agent_id" => rotated_router_id},
               tenant_id
             )

    assert {:ok, resolved_workspace} = CommaWeb.SalixClient.resolve_workspace_scope(workspace)
    assert resolved_workspace["router_agent_id"] == rotated_router_id
    assert workspace["router_agent_id"] == original_router_id

    assert :ok = CommaWeb.SalixClient.provision_workspace_scope(workspace)

    assert {:error, :workspace_scope_conflict} =
             CommaWeb.SalixClient.verify_workspace_scope(workspace)

    assert {:ok, group_after_provision_retry} =
             Salix.Control.Groups.get(group_id, tenant_id)

    assert group_after_provision_retry["router_agent_id"] == rotated_router_id

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    chat =
      :post
      |> json_conn("/v1/comma/groups/#{group_id}/assistant-chat", %{})
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert chat["group_id"] == group_id
    assert chat["status"] == "active"

    assert {:ok, group} = Salix.Control.Groups.get(group_id, tenant_id)
    assert group["router_agent_id"] == rotated_router_id
    refute group["router_agent_id"] == original_router_id

    assert {:ok, %{"participants" => participants}} =
             SalixIM.Conversations.list_group_conversation_participants(
               group_id,
               chat["id"],
               limit: 50
             )

    assert Enum.any?(participants, fn participant ->
             participant["actor_type"] == "agent" and
               participant["agent_id"] == rotated_router_id and
               participant["state"] == "active"
           end)

    refute Enum.any?(participants, fn participant ->
             participant["actor_type"] == "agent" and
               participant["agent_id"] == original_router_id
           end)
  end

  test "Comma workspace VM mutation is durable and never performs provider I/O inline" do
    Application.put_env(:comma_core, :salix_client, __MODULE__.RecordingSalixClient)
    Application.put_env(:comma_core, :salix_client_test_pid, self())

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "vm@example.com", "name" => "VM"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "VM Workspace")

    assert_receive {:provision_workspace_scope, %{"id" => workspace_id}}
    assert workspace_id == workspace["id"]

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    other_user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "vm-other@example.com",
        "name" => "Other"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    other_session =
      :post
      |> json_conn("/v1/comma/admin/users/#{other_user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace_s3_keys =
      MapSet.new([
        "comma/workspaces/#{workspace["id"]}",
        "comma/user_workspaces/#{user["id"]}",
        SalixStore.Keys.ctl_group(workspace["default_group_id"])
      ])

    :ok = SalixStore.S3.Fake.reset_put_log()
    :ok = SalixStore.S3.Fake.reset_read_log()

    # The fake log is process-global. Keep unrelated traffic in the observation
    # window so this guard cannot regress to asserting global log emptiness.
    assert {:error, :not_found} =
             SalixStore.S3.Fake.get("ctl/groups/unrelated-vm-guard.json", [])

    forbidden =
      :patch
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}", %{
        "vm" => %{"enabled" => true, "provider" => "cloudflare"}
      })
      |> put_req_header("authorization", "Bearer #{other_session["token"]}")
      |> call()
      |> expect_json(403)

    assert forbidden == %{"error" => "forbidden"}

    updated =
      :patch
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}", %{
        "vm" => %{"enabled" => true, "provider" => "cloudflare", "recreate" => true}
      })
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert updated["vm"] == %{"enabled" => true, "provider" => "cloudflare"}
    refute_receive {:update_workspace_vm, _, _}

    operation =
      Repo.get_by!(Comma.Data.ExternalOperation,
        operation_type: "workspace_convergence",
        owner_id: workspace["id"],
        generation: 2
      )

    assert operation.status == "pending"
    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    assert_receive {:update_workspace_vm, %{"id" => ^workspace_id},
                    %{"enabled" => true, "provider" => "cloudflare", "recreate" => true}}

    renamed =
      :patch
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}", %{"name" => "Renamed Workspace"})
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert renamed["name"] == "Renamed Workspace"
    assert Repo.get!(Comma.Data.Workspace, workspace["id"]).name == "Renamed Workspace"

    refute Enum.any?(
             SalixStore.S3.Fake.put_log(),
             &MapSet.member?(workspace_s3_keys, &1)
           )

    refute Enum.any?(SalixStore.S3.Fake.read_log(), fn
             {_operation, key} -> MapSet.member?(workspace_s3_keys, key)
             _other -> false
           end)
  end

  test "Comma user session manages the workspace's inbound API keys" do
    SalixStore.Repo.query!("DELETE FROM agent_group_api_keys")
    prev_public_base_url = Application.get_env(:salix_web, :public_base_url)
    Application.put_env(:salix_web, :public_base_url, "https://api.comma.example/")

    on_exit(fn ->
      if prev_public_base_url == nil,
        do: Application.delete_env(:salix_web, :public_base_url),
        else: Application.put_env(:salix_web, :public_base_url, prev_public_base_url)
    end)

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "inbound-api@example.com",
        "name" => "Inbound"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Inbound API Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    path = "/v1/comma/workspaces/#{workspace["id"]}/router-api-keys"
    auth = &put_req_header(&1, "authorization", "Bearer #{session["token"]}")

    assert [] = conn(:get, path) |> auth.() |> call() |> expect_json(200)

    created =
      :post
      |> json_conn(path, %{"name" => "Zendesk"})
      |> auth.()
      |> call()
      |> expect_json(201)

    assert "salix_gk_" <> _ = created["key"]
    assert created["name"] == "Zendesk"
    assert created["status"] == "active"
    # The key acts as this user under information-flow checking, and the
    # Salix ids never reach the client.
    assert created["created_by"] == "comma_user:" <> user["id"]
    refute Map.has_key?(created, "key_hash")
    refute Map.has_key?(created, "tenant_id")
    refute Map.has_key?(created, "group_id")

    assert {:ok, %{"group_id" => group_id}} =
             Salix.Control.GroupApiKeys.validate(created["key"])

    assert group_id == workspace["default_group_id"]

    # What the client shows is a ready-to-use posting URL on the externally
    # reachable Salix base, since the group id itself never leaves the server.
    assert created["post_message_url"] ==
             "https://api.comma.example/v1/agent-groups/#{group_id}/router/post-message"

    assert [listed] = conn(:get, path) |> auth.() |> call() |> expect_json(200)
    assert listed["key_id"] == created["key_id"]
    assert listed["post_message_url"] == created["post_message_url"]
    refute Map.has_key?(listed, "key")

    updated =
      :patch
      |> json_conn(path <> "/" <> created["key_id"], %{"name" => "Jira", "status" => "disabled"})
      |> auth.()
      |> call()
      |> expect_json(200)

    assert updated["name"] == "Jira"
    assert updated["status"] == "disabled"
    assert {:error, :unauthorized} = Salix.Control.GroupApiKeys.validate(created["key"])

    assert %{"error" => _} =
             :patch
             |> json_conn(path <> "/" <> created["key_id"], %{"status" => "weird"})
             |> auth.()
             |> call()
             |> expect_json(400)

    assert %{"error" => "not_found"} =
             :patch
             |> json_conn(path <> "/gak_missing", %{"name" => "x"})
             |> auth.()
             |> call()
             |> expect_json(404)

    # Another user's session cannot see or touch this workspace's keys.
    stranger =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "stranger-inbound@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    stranger_session =
      :post
      |> json_conn("/v1/comma/admin/users/#{stranger["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    stranger_status =
      conn(:get, path)
      |> put_req_header("authorization", "Bearer #{stranger_session["token"]}")
      |> call()
      |> Map.fetch!(:status)

    assert stranger_status in [403, 404]

    assert %{"deleted" => true} =
             conn(:delete, path <> "/" <> created["key_id"])
             |> auth.()
             |> call()
             |> expect_json(200)

    assert [] = conn(:get, path) |> auth.() |> call() |> expect_json(200)

    # A restricted session is refused, as it is for connector tokens.
    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert %{"error" => "forbidden"} =
             :post
             |> json_conn(path, %{"name" => "Nope"})
             |> put_req_header("authorization", "Bearer #{restricted["token"]}")
             |> call()
             |> expect_json(403)
  end

  # A local stand-in for the Twilio Verify API: `246810` is the only code it
  # approves. Every request is reported to the test process.
  defmodule TwilioVerifyStub do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      form = URI.decode_query(body)

      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil),
        do: send(pid, {:twilio_verify, conn.request_path, form})

      reply =
        if String.ends_with?(conn.request_path, "/VerificationCheck") do
          %{"status" => if(form["Code"] == "246810", do: "approved", else: "pending")}
        else
          %{"status" => "pending"}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, Jason.encode!(reply))
    end
  end

  test "Comma user session verifies voice caller numbers and manages voice agent keys" do
    prev_public_base_url = Application.get_env(:salix_web, :public_base_url)
    prev_verify_base_url = Application.get_env(:salix_web, :twilio_verify_base_url)
    Application.put_env(:salix_web, :public_base_url, "https://api.comma.example/")

    twilio =
      start_supervised!(
        {Bandit, plug: TwilioVerifyStub, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, twilio_port}} = ThousandIsland.listener_info(twilio)
    Application.put_env(:salix_web, :twilio_verify_base_url, "http://127.0.0.1:#{twilio_port}")
    :persistent_term.put({TwilioVerifyStub, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({TwilioVerifyStub, :test_pid})
      _ = SalixStore.S3.delete(SalixStore.Keys.ctl_system_voice())

      for {key, prev} <- [
            public_base_url: prev_public_base_url,
            twilio_verify_base_url: prev_verify_base_url
          ] do
        if prev == nil,
          do: Application.delete_env(:salix_web, key),
          else: Application.put_env(:salix_web, key, prev)
      end
    end)

    line = "+15550001111"

    assert {:ok, _settings} =
             SalixVoice.Settings.update(%{
               "enabled" => true,
               "twilio_account_sid" => "AC_test",
               "twilio_auth_token" => "twilio-auth-secret",
               "twilio_verify_service_sid" => "VA_test",
               "twilio_numbers" => [line]
             })

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "voice@example.com", "name" => "Voice"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Voice Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    group_id = workspace["default_group_id"]
    auth = &put_req_header(&1, "authorization", "Bearer #{session["token"]}")
    voice = "/v1/comma/workspaces/#{workspace["id"]}/integrations/voice"
    keys = "/v1/comma/workspaces/#{workspace["id"]}/voice-api-keys"
    # A fresh caller number per run: Verify rate limits are per number.
    caller = "+1555" <> Integer.to_string(1_000_000 + :rand.uniform(8_999_999))

    # ---- caller numbers ----

    status_conn = conn(:get, voice) |> auth.() |> call()
    status = expect_json(status_conn, 200)
    assert get_resp_header(status_conn, "cache-control") == ["no-store"]
    assert status["lines"] == [line]
    assert status["numbers"] == []
    assert is_boolean(status["readiness"]["ready"])

    assert status["sessions_url"] ==
             "wss://api.comma.example/v1/agent-groups/#{group_id}/voice/sessions"

    refute Map.has_key?(status, "group_id")
    refute Map.has_key?(status, "connect")

    assert %{"e164" => ^caller, "status" => "pending"} =
             :post
             |> json_conn(voice <> "/numbers/verify-start", %{"e164" => caller})
             |> auth.()
             |> call()
             |> expect_json(200)

    assert_receive {:twilio_verify, "/v2/Services/VA_test/Verifications",
                    %{"To" => ^caller, "Channel" => "sms"}}

    # A wrong code binds nothing.
    assert %{"error" => "invalid_code"} =
             :post
             |> json_conn(voice <> "/numbers/verify-check", %{
               "e164" => caller,
               "code" => "111111"
             })
             |> auth.()
             |> call()
             |> expect_json(422)

    assert %{"numbers" => []} = conn(:get, voice) |> auth.() |> call() |> expect_json(200)

    verified =
      :post
      |> json_conn(voice <> "/numbers/verify-check", %{"e164" => caller, "code" => "246810"})
      |> auth.()
      |> call()
      |> expect_json(200)

    assert [%{"e164" => ^caller, "line" => ^line, "pin_set" => false, "status" => "verified"}] =
             verified["numbers"]

    with_pin =
      :put
      |> json_conn(voice <> "/pin", %{"e164" => caller, "pin" => "2468"})
      |> auth.()
      |> call()

    assert [%{"pin_set" => true}] = expect_json(with_pin, 200)["numbers"]
    # The PIN and its hash never leave Salix.
    refute with_pin.resp_body =~ "pbkdf2"
    refute with_pin.resp_body =~ "pin_hash"
    refute with_pin.resp_body =~ "2468"

    assert %{"error" => _} =
             :put
             |> json_conn(voice <> "/pin", %{"e164" => caller, "pin" => "12"})
             |> auth.()
             |> call()
             |> expect_json(400)

    # A number bound to another Group is a conflict before any SMS is sent.
    {:ok, other_tenant} = Salix.Control.Tenants.create(%{"name" => "Other voice tenant"})

    {:ok, other_group} =
      Salix.Control.Groups.create(%{"name" => "Other voice group"}, other_tenant["tenant_id"])

    taken = "+1556" <> Integer.to_string(1_000_000 + :rand.uniform(8_999_999))

    assert {:ok, _connect} =
             SalixIM.ProviderConnects.confirm_voice_number(
               other_tenant["tenant_id"],
               other_group["group_id"],
               "twilio",
               line,
               taken
             )

    assert %{"error" => "voice_number_in_use"} =
             :post
             |> json_conn(voice <> "/numbers/verify-start", %{"e164" => taken})
             |> auth.()
             |> call()
             |> expect_json(409)

    refute_received {:twilio_verify, _path, %{"To" => ^taken}}

    # Removing a number unbinds it; the "+" survives the path segment.
    assert %{"numbers" => []} =
             conn(:delete, voice <> "/numbers/" <> URI.encode_www_form(caller))
             |> auth.()
             |> call()
             |> expect_json(200)

    # Repeated codes to one number hit the Verify rate limit.
    busy = "+1557" <> Integer.to_string(1_000_000 + :rand.uniform(8_999_999))

    statuses =
      for _attempt <- 1..6 do
        :post
        |> json_conn(voice <> "/numbers/verify-start", %{"e164" => busy})
        |> auth.()
        |> call()
        |> Map.fetch!(:status)
      end

    assert List.last(statuses) == 429

    # ---- voice agent API keys ----

    created =
      :post
      |> json_conn(keys, %{"name" => "Front desk"})
      |> auth.()
      |> call()
      |> expect_json(201)

    assert "salix_vk_" <> _ = created["key"]
    assert created["created_by"] == "comma_user:" <> user["id"]
    assert created["sessions_url"] == status["sessions_url"]

    assert created["readiness_url"] ==
             "https://api.comma.example/v1/agent-groups/#{group_id}/voice"

    refute Map.has_key?(created, "key_hash")
    refute Map.has_key?(created, "tenant_id")
    refute Map.has_key?(created, "group_id")

    assert {:ok, %{"group_id" => ^group_id, "kind" => "voice"}} =
             Salix.Control.GroupApiKeys.validate(created["key"])

    assert [listed] = conn(:get, keys) |> auth.() |> call() |> expect_json(200)
    assert listed["key_id"] == created["key_id"]
    refute Map.has_key?(listed, "key")

    # The two kinds stay apart: a voice key is not an inbound key, and an
    # inbound key cannot be managed through the voice routes.
    router_keys = "/v1/comma/workspaces/#{workspace["id"]}/router-api-keys"
    assert [] = conn(:get, router_keys) |> auth.() |> call() |> expect_json(200)

    inbound =
      :post
      |> json_conn(router_keys, %{"name" => "Zendesk"})
      |> auth.()
      |> call()
      |> expect_json(201)

    assert %{"error" => "not_found"} =
             :patch
             |> json_conn(keys <> "/" <> inbound["key_id"], %{"status" => "disabled"})
             |> auth.()
             |> call()
             |> expect_json(404)

    assert {:ok, _} = Salix.Control.GroupApiKeys.validate(inbound["key"])

    disabled =
      :patch
      |> json_conn(keys <> "/" <> created["key_id"], %{"name" => "Lobby", "status" => "disabled"})
      |> auth.()
      |> call()
      |> expect_json(200)

    assert %{"name" => "Lobby", "status" => "disabled"} = disabled
    assert {:error, :unauthorized} = Salix.Control.GroupApiKeys.validate(created["key"])

    assert %{"deleted" => true} =
             conn(:delete, keys <> "/" <> created["key_id"])
             |> auth.()
             |> call()
             |> expect_json(200)

    assert [] = conn(:get, keys) |> auth.() |> call() |> expect_json(200)

    # Another user's session cannot reach this workspace's voice setup.
    stranger =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "stranger-voice@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    stranger_session =
      :post
      |> json_conn("/v1/comma/admin/users/#{stranger["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    for path <- [voice, keys] do
      stranger_status =
        conn(:get, path)
        |> put_req_header("authorization", "Bearer #{stranger_session["token"]}")
        |> call()
        |> Map.fetch!(:status)

      assert stranger_status in [403, 404]
    end

    # A restricted session is refused, as it is for inbound keys.
    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    for {method, path, body} <- [
          {:post, keys, %{"name" => "Nope"}},
          {:post, voice <> "/numbers/verify-start", %{"e164" => caller}}
        ] do
      assert %{"error" => "forbidden"} =
               method
               |> json_conn(path, body)
               |> put_req_header("authorization", "Bearer #{restricted["token"]}")
               |> call()
               |> expect_json(403)
    end
  end

  # A registered Signal account with Comma-chosen identifiers, removed after the test.
  defp signal_account!(scope) do
    n = :rand.uniform(9_999_999)
    identity = SalixSignalProto.Keys.ec_keypair()

    {:ok, id} =
      SalixSignal.Accounts.create(%{
        aci: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0"),
        pni: nil,
        e164: "+1555" <> String.pad_leading(Integer.to_string(n), 7, "0"),
        device_id: 1,
        password: "device-password",
        identities: %{aci: identity, pni: nil},
        registration_ids: %{aci: 1, pni: 0},
        profile_key: :binary.copy(<<7>>, 32),
        pre_keys: %{},
        scope: scope,
        environment: :staging
      })

    on_exit(fn ->
      SalixStore.Repo.query("DELETE FROM signal_accounts WHERE id = $1", [Ecto.UUID.dump!(id)])
    end)

    {:ok, summary} = SalixSignal.Accounts.get(id)
    summary
  end

  test "Comma user session connects Signal chats and sets the workspace Signal number" do
    on_exit(fn -> SalixSignal.Settings.set_platform_number(nil) end)

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "signal@example.com", "name" => "Signal"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    workspace = create_ready_workspace!(user["id"], "Signal Workspace")

    session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    auth = &put_req_header(&1, "authorization", "Bearer #{session["token"]}")
    signal = "/v1/comma/workspaces/#{workspace["id"]}/integrations/signal"
    platform = signal_account!(:platform)
    {:ok, _} = SalixSignal.Settings.set_platform_number(platform.e164)

    status_conn = conn(:get, signal) |> auth.() |> call()
    status = expect_json(status_conn, 200)
    assert get_resp_header(status_conn, "cache-control") == ["no-store"]
    assert status["account"]["e164"] == platform.e164
    assert status["bindings"] == []

    # The code is shown once; the status lists only the pending claim.
    started =
      :post |> json_conn(signal <> "/claims", %{}) |> auth.() |> call() |> expect_json(200)

    assert started["claim"]["number"] == platform.e164
    assert "comma connect " <> _ = started["claim"]["command"]

    listed = conn(:get, signal) |> auth.() |> call()
    assert [%{"claim_id" => claim_id}] = expect_json(listed, 200)["pending_claims"]
    refute listed.resp_body =~ started["claim"]["code"]

    assert %{"pending_claims" => []} =
             conn(:delete, signal <> "/claims/" <> claim_id)
             |> auth.()
             |> call()
             |> expect_json(200)

    # The workspace sets its own number; another tenant's account is refused.
    tenant_id = workspace["salix_tenant_id"]
    own = signal_account!({:organization, tenant_id})
    foreign = signal_account!({:organization, "ten_other_signal"})

    assert %{"error" => "signal_account_scope"} =
             :put
             |> json_conn(signal <> "/number", %{"number" => foreign.e164})
             |> auth.()
             |> call()
             |> expect_json(422)

    number = :put |> json_conn(signal <> "/number", %{"number" => own.e164}) |> auth.() |> call()
    assert %{"effective" => %{"e164" => own_number}} = expect_json(number, 200)
    assert own_number == own.e164
    refute Map.has_key?(expect_json(number, 200), "tenant_id")

    started =
      :post |> json_conn(signal <> "/claims", %{}) |> auth.() |> call() |> expect_json(200)

    assert started["claim"]["number"] == own.e164

    # Comma admin sees and clears the same override.
    admin_path = "/v1/comma/admin/users/#{user["id"]}/workspaces/signal-number"

    assert %{"override" => %{"e164" => ^own_number}, "workspace_id" => workspace_id} =
             conn(:get, admin_path) |> admin_auth() |> call() |> expect_json(200)

    assert workspace_id == workspace["id"]

    assert %{"override" => nil, "effective" => %{"e164" => platform_number}} =
             :put
             |> json_conn(admin_path, %{"number" => ""})
             |> admin_auth()
             |> call()
             |> expect_json(200)

    assert platform_number == platform.e164

    # Another user's session cannot reach this workspace's Signal setup.
    stranger =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "stranger-signal@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    stranger_session =
      :post
      |> json_conn("/v1/comma/admin/users/#{stranger["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    for {method, path} <- [{:get, signal}, {:post, signal <> "/claims"}] do
      status =
        method
        |> json_conn(path, %{})
        |> put_req_header("authorization", "Bearer #{stranger_session["token"]}")
        |> call()
        |> Map.fetch!(:status)

      assert status in [403, 404]
    end
  end

  test "restricted Comma sessions cannot mint workspace connector tokens" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "restricted-connector@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    user_id = user["id"]

    workspace = create_ready_workspace!(user["id"], "Restricted")

    open_session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    conversation =
      :post
      |> json_conn("/v1/comma/groups/#{workspace["default_group_id"]}/assistant-chat", %{})
      |> put_req_header("authorization", "Bearer #{open_session["token"]}")
      |> call()
      |> expect_json(200)

    workspace_restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    conversation_restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"],
        "group_id" => workspace["default_group_id"],
        "conversation_id" => conversation["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    for session <- [workspace_restricted, conversation_restricted] do
      response =
        :post
        |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/connector-token", %{
          "alias" => "mac"
        })
        |> put_req_header("authorization", "Bearer #{session["token"]}")
        |> call()

      assert response.status == 403

      bootstrap =
        :post
        |> json_conn("/v1/comma/me/bootstrap", %{})
        |> put_req_header("authorization", "Bearer #{session["token"]}")
        |> call()

      assert bootstrap.status == 403
    end

    assert Repo.aggregate(
             from(row in Comma.Data.Workspace,
               where: row.owner_user_id == ^user_id
             ),
             :count
           ) == 1

    assert Repo.get!(Comma.Data.Workspace, workspace["id"]).owner_user_id == user_id
  end

  test "public passwordless email login returns a Comma session that can access product API" do
    login =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "public@example.com"})
      |> call()
      |> expect_json(200)

    assert %{"challenge_id" => challenge_id, "code" => code} = login

    session =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => challenge_id,
        "code" => code
      })
      |> call()
      |> expect_json(200)

    assert "comma_sess_" <> _ = session["token"]
    assert %{"email" => "public@example.com"} = session["user"]

    body =
      :get
      |> conn("/v1/comma/workspaces")
      |> put_req_header("authorization", "Bearer #{session["token"]}")
      |> call()
      |> expect_json(200)

    assert %{"data" => []} = body
  end

  test "ordinary sessions bootstrap one default Workspace without provisioning inline" do
    previous_vm = Application.get_env(:salix_agent, :cloud_vm_mod)
    Application.put_env(:salix_agent, :cloud_vm_mod, __MODULE__.WorkspaceVM)
    on_exit(fn -> restore_env(:salix_agent, :cloud_vm_mod, previous_vm) end)
    Application.put_env(:comma_core, :salix_client, __MODULE__.RecordingSalixClient)
    Application.put_env(:comma_core, :salix_client_test_pid, self())

    session = email_login!("workspace-bootstrap-route@example.com")
    user_id = session["user"]["id"]

    managed_creation =
      :post
      |> json_conn("/v1/comma/workspaces", %{"name" => "Client-created workspace"})
      |> user_auth(session["token"])
      |> call()
      |> expect_json(409)

    assert managed_creation == %{"error" => "workspace_creation_managed"}

    assert Repo.aggregate(
             from(row in Comma.Data.Workspace,
               where: row.owner_user_id == ^user_id
             ),
             :count
           ) == 0

    first_conn =
      :post
      |> json_conn("/v1/comma/me/bootstrap", %{})
      |> user_auth(session["token"])
      |> call()

    first = expect_json(first_conn, 202)
    assert get_resp_header(first_conn, "retry-after") == ["2"]
    assert first["status"] == "provisioning"
    assert first["workspace"]["owner_user_id"] == user_id
    assert first["workspace"]["status"] == "provisioning"

    second =
      :post
      |> json_conn("/v1/comma/me/bootstrap", %{})
      |> user_auth(session["token"])
      |> call()
      |> expect_json(202)

    workspace_id = first["workspace"]["id"]
    group_id = first["workspace"]["group_id"]
    assert second["workspace"]["id"] == workspace_id

    assert Repo.aggregate(
             from(row in Comma.Data.Workspace,
               where: row.owner_user_id == ^user_id
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(row in Comma.Data.WorkspaceMembership, where: row.user_id == ^user_id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(row in Comma.Data.ExternalOperation,
               where:
                 row.owner_id == ^workspace_id and row.operation_type == "workspace_convergence"
             ),
             :count
           ) == 1

    pending_workspace =
      :get
      |> conn("/v1/comma/workspaces/#{workspace_id}")
      |> user_auth(session["token"])
      |> call()

    assert expect_json(pending_workspace, 202) == %{
             "error" => "workspace_provisioning",
             "retry_after_seconds" => 2
           }

    assert get_resp_header(pending_workspace, "retry-after") == ["2"]

    pending_calls = [
      {:post, "/v1/comma/groups/#{group_id}/assistant-chat"},
      {:post, "/v1/comma/groups/#{group_id}/files"},
      {:get, "/v1/comma/workspaces/#{workspace_id}/billing/summary"}
    ]

    for {method, path} <- pending_calls do
      conn =
        method
        |> json_conn(path, %{})
        |> user_auth(session["token"])
        |> call()

      assert expect_json(conn, 202) == %{
               "error" => "workspace_provisioning",
               "retry_after_seconds" => 2
             }

      assert get_resp_header(conn, "retry-after") == ["2"]
    end

    refute_received {:provision_workspace_scope, _workspace}

    operation =
      Repo.get_by!(Comma.Data.ExternalOperation,
        owner_id: workspace_id,
        operation_type: "workspace_convergence",
        generation: 1
      )

    job =
      Repo.one!(
        from(job in Oban.Job,
          where:
            job.worker == "Comma.Workers.WorkspaceConvergence" and
              fragment("?->>'operation_id'", job.args) == ^operation.operation_id
        )
      )

    timeout = Application.fetch_env!(:comma_core, :operation_claim_timeout_ms)
    stale_at = DateTime.add(DateTime.utc_now(), -(timeout + 1_000), :millisecond)

    Repo.update_all(
      from(row in Comma.Data.ExternalOperation,
        where: row.operation_id == ^operation.operation_id
      ),
      set: [status: "executing", attempt: job.max_attempts, updated_at: stale_at]
    )

    Repo.update_all(
      from(row in Oban.Job, where: row.id == ^job.id),
      set: [
        state: "executing",
        attempt: job.max_attempts,
        attempted_at: stale_at,
        attempted_by: ["salix@terminated-pod", "terminated-producer"]
      ]
    )

    assert {1, [%{id: rescued_id, max_attempts: rescued_max_attempts}]} =
             Comma.ObanPlugins.OperationLifeline.rescue_jobs(Oban.config(Comma.Oban), timeout)

    assert rescued_id == job.id
    assert rescued_max_attempts == job.max_attempts + 1

    Repo.update_all(
      from(candidate in Oban.Job,
        where:
          candidate.queue == "comma_external" and candidate.state == "available" and
            candidate.id != ^job.id
      ),
      set: [state: "scheduled", scheduled_at: DateTime.add(DateTime.utc_now(), 1, :hour)]
    )

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(Comma.Oban, queue: :comma_external, with_limit: 1)

    assert Repo.get!(Oban.Job, job.id).state == "completed"
    assert Repo.get!(Comma.Data.ExternalOperation, operation.operation_id).status == "succeeded"

    assert Repo.get!(Comma.Data.ExternalOperation, operation.operation_id).attempt ==
             job.max_attempts + 1

    assert_receive {:provision_workspace_scope, %{"id" => ^workspace_id}}
    Application.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)

    ready =
      :post
      |> json_conn("/v1/comma/me/bootstrap", %{})
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert ready["status"] == "ready"
    assert ready["workspace"]["id"] == workspace_id

    assert %{"data" => [%{"id" => ^workspace_id}]} =
             :get
             |> conn("/v1/comma/workspaces")
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    assert %{"id" => ^workspace_id} =
             :get
             |> conn("/v1/comma/workspaces/#{workspace_id}")
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    assert %{"group_id" => ^group_id} =
             :post
             |> json_conn("/v1/comma/groups/#{group_id}/assistant-chat", %{})
             |> user_auth(session["token"])
             |> call()
             |> expect_json(200)

    billing_summary =
      :get
      |> conn("/v1/comma/workspaces/#{workspace_id}/billing/summary")
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert billing_summary["billing_account_id"] == "comma-ba-" <> workspace_id
    assert billing_summary["current_credits"] == 20_000_000
    assert billing_summary["active_subscription"] == nil
  end

  test "v1 workspace HTTP authorization and projection remain owner-only" do
    owner_session = email_login!("workspace-owner-only@example.com")
    attacker_session = email_login!("workspace-future-member@example.com")
    owner_id = owner_session["user"]["id"]
    attacker_id = attacker_session["user"]["id"]
    workspace = create_ready_workspace!(owner_id, "Owner-only Workspace")

    Repo.insert!(
      Comma.Data.WorkspaceMembership.changeset(%Comma.Data.WorkspaceMembership{}, %{
        workspace_id: workspace["id"],
        user_id: attacker_id,
        role: "member",
        status: "active"
      })
    )

    assert %{"data" => []} =
             :get
             |> conn("/v1/comma/workspaces")
             |> user_auth(attacker_session["token"])
             |> call()
             |> expect_json(200)

    assert %{"error" => "forbidden"} =
             :get
             |> conn("/v1/comma/workspaces/#{workspace["id"]}")
             |> user_auth(attacker_session["token"])
             |> call()
             |> expect_json(403)

    assert %{"error" => "forbidden"} =
             :patch
             |> json_conn("/v1/comma/workspaces/#{workspace["id"]}", %{"name" => "Stolen"})
             |> user_auth(attacker_session["token"])
             |> call()
             |> expect_json(403)

    owner_workspace =
      :get
      |> conn("/v1/comma/workspaces/#{workspace["id"]}")
      |> user_auth(owner_session["token"])
      |> call()
      |> expect_json(200)

    assert owner_workspace["name"] == "Owner-only Workspace"

    assert owner_workspace["members"] == [
             %{"role" => "owner", "user_id" => owner_id}
           ]

    workspace["id"]
    |> then(&Repo.get!(Comma.Data.Workspace, &1))
    |> Ecto.Changeset.change(status: "provisioning")
    |> Repo.update!()

    provisioning_response =
      :get
      |> conn("/v1/comma/workspaces/#{workspace["id"]}")
      |> user_auth(attacker_session["token"])
      |> call()

    assert expect_json(provisioning_response, 403) == %{"error" => "forbidden"}
    assert get_resp_header(provisioning_response, "retry-after") == []
  end

  test "ops user update rejects direct email changes" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "fixed-ops-email@example.com"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    conn =
      :patch
      |> json_conn("/v1/comma/admin/users/#{user["id"]}", %{
        "email" => "replacement-ops-email@example.com"
      })
      |> admin_auth()
      |> call()

    assert %{"error" => "email_change_not_supported"} = expect_json(conn, 400)

    assert %{"email" => "fixed-ops-email@example.com"} =
             :get
             |> conn("/v1/comma/admin/users/#{user["id"]}")
             |> admin_auth()
             |> call()
             |> expect_json(200)
  end

  test "browser login keeps the session token in an HttpOnly revocable cookie" do
    origin = "http://127.0.0.1:5174"

    login =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "browser-cookie@example.com"})
      |> web_cookie_request(origin, :none)
      |> call()
      |> expect_json(200)

    verify_conn =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => login["challenge_id"],
        "code" => login["code"]
      })
      |> web_cookie_request(origin, :none)
      |> call()

    session = expect_json(verify_conn, 200)
    assert Map.keys(session) |> Enum.sort() == ["expires_at", "session_id", "user"]
    assert {:ok, _session_id} = Ecto.UUID.cast(session["session_id"])
    refute Map.has_key?(session, "token")
    assert session["user"]["email"] == "browser-cookie@example.com"
    refute Map.has_key?(session["user"], "admin")

    cookie = verify_conn.resp_cookies[CommaWeb.SessionCookie.cookie_name()]
    assert cookie.http_only == true
    assert cookie.secure == false
    assert cookie.same_site == "Lax"
    assert is_binary(cookie.value)
    assert String.starts_with?(cookie.value, "comma_sess_")

    startup_view =
      :get
      |> conn("/v1/comma/auth/session")
      |> cookie_auth(cookie.value, origin, :unknown)
      |> call()
      |> expect_json(200)

    assert Map.keys(startup_view) |> Enum.sort() == ["expires_at", "session_id", "user"]
    refute Map.has_key?(startup_view, "token")
    assert startup_view["session_id"] == session["session_id"]
    assert startup_view["user"]["email"] == "browser-cookie@example.com"

    assert %{"session_id" => session_id} =
             :get
             |> conn("/v1/comma/auth/session")
             |> cookie_auth(cookie.value, origin)
             |> call()
             |> expect_json(200)

    assert session_id == session["session_id"]

    active_none =
      :get
      |> conn("/v1/comma/auth/session")
      |> cookie_auth(cookie.value, origin, :none)
      |> call()

    assert expect_json(active_none, 409) == %{"error" => "session_changed"}
    assert active_none.resp_cookies == %{}

    assert %{"error" => "origin_path_not_allowed"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> cookie_auth(cookie.value, origin)
             |> call()
             |> expect_json(403)

    assert 401 ==
             (:get
              |> conn("/v1/comma/auth/session")
              |> cookie_auth(cookie.value, origin)
              |> user_auth(cookie.value)
              |> call()).status

    logout_conn =
      :post
      |> json_conn("/v1/comma/auth/logout", %{})
      |> cookie_auth(cookie.value, origin)
      |> call()

    assert %{"signed_out" => true} = expect_json(logout_conn, 200)
    assert logout_conn.resp_cookies[CommaWeb.SessionCookie.cookie_name()].max_age == 0

    assert 401 ==
             (:get
              |> conn("/v1/comma/auth/session")
              |> cookie_auth(cookie.value, origin)
              |> call()).status
  end

  test "canonical browser origins reject cross-surface paths regardless of bearer" do
    product_session = email_login!("cross-surface-product@example.com")

    assert :options
           |> conn("/v1/comma/admin/users")
           |> put_req_header("origin", @admin_origin)
           |> put_req_header("access-control-request-method", "GET")
           |> put_req_header(
             "access-control-request-headers",
             "x-comma-session-transport"
           )
           |> call()
           |> Map.fetch!(:status) == 204

    assert %{"error" => "origin_path_not_allowed"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> put_req_header("origin", @web_origin)
             |> admin_auth()
             |> call()
             |> expect_json(403)

    assert %{"error" => "origin_path_not_allowed"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> cookie_auth(
               product_session["token"],
               @web_origin,
               product_session["session_id"]
             )
             |> call()
             |> expect_json(403)

    assert %{"error" => "origin_path_not_allowed"} =
             :get
             |> conn("/v1/comma/workspaces")
             |> put_req_header("origin", @admin_origin)
             |> user_auth(product_session["token"])
             |> call()
             |> expect_json(403)

    for {origin, path} <- [
          {@web_origin, "/v1/comma/admin/users"},
          {@admin_origin, "/v1/comma/workspaces"},
          {@admin_origin, "/v1/admin/vm/worker-release"}
        ] do
      assert %{"error" => "origin_path_not_allowed"} =
               :options
               |> conn(path)
               |> put_req_header("origin", origin)
               |> put_req_header("access-control-request-method", "GET")
               |> put_req_header("access-control-request-headers", "authorization")
               |> call()
               |> expect_json(403)
    end
  end

  test "Agent VMM Admin command replays a succeeded HTTP response from its receipt" do
    {browser_session, token} =
      browser_cookie_login!("compute-operator@comma.surf", @admin_origin)

    registration_id = "registration-#{System.unique_integer([:positive])}"
    tenant_id = "tenant-#{System.unique_integer([:positive])}"

    assert {:ok, registration} =
             SalixStore.AgentVMM.create_registration(%{
               id: registration_id,
               tenant_id: tenant_id,
               group_id: "group-a",
               device_id: "node-a",
               enrollment_token: String.duplicate("a", 32)
             })

    action = "disable_agent_vmm_registration"
    idempotency_key = "agent-vmm-http-#{Ecto.UUID.generate()}"

    body = %{
      "tenant_id" => tenant_id,
      "expected_revision" => registration.revision,
      "reason" => "Drain this registration for maintenance",
      "idempotency_key" => idempotency_key,
      "confirmation" => "#{action}:#{registration_id}:#{registration.revision}"
    }

    path = "/v1/comma/admin/compute/agent-vmm/commands/#{action}/#{registration_id}"

    first =
      :post
      |> json_conn(path, body)
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
      |> expect_json(202)

    second =
      :post
      |> json_conn(path, body)
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
      |> expect_json(202)

    assert second == first
    assert first["accepted"]
    assert first["result_revision"] == registration.revision + 1

    assert SalixStore.Repo.get!(SalixStore.AgentVMM.Registration, registration_id).revision ==
             registration.revision + 1

    assert %{"error" => "forbidden"} =
             :post
             |> json_conn(path, Map.put(body, "idempotency_key", Ecto.UUID.generate()))
             |> admin_auth()
             |> call()
             |> expect_json(403)
  end

  test "exact comma.surf Admin Cookie Sessions can read and run named audited commands" do
    {browser_session, token} = browser_cookie_login!("operator@comma.surf", @admin_origin)
    user_id = browser_session["user"]["id"]
    missing_code_id = Ecto.UUID.generate()

    for path <- [
          "/v1/comma/admin/audit-events",
          "/v1/comma/admin/users",
          "/v1/comma/admin/users/#{user_id}",
          "/v1/comma/admin/users/#{user_id}/sessions",
          "/v1/comma/admin/users/#{user_id}/workspaces",
          "/v1/comma/admin/billing/free-router-models",
          "/v1/comma/admin/billing/package-versions",
          "/v1/comma/admin/billing/redeem-codes",
          "/v1/comma/admin/billing/redemptions?redeem_code_id=#{missing_code_id}"
        ] do
      assert :get
             |> conn(path)
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> Map.fetch!(:status) == 200
    end

    for path <- [
          "/v1/comma/admin/billing/redemptions",
          "/v1/comma/admin/billing/redemptions?redeem_code_id=%20"
        ] do
      assert %{"error" => "invalid_redeem_code_id"} =
               :get
               |> conn(path)
               |> cookie_auth(token, @admin_origin, browser_session["session_id"])
               |> call()
               |> expect_json(400)
    end

    assert %{"error" => "invalid_admin_reason"} =
             :post
             |> json_conn("/v1/comma/admin/users", %{"email" => "missing-contract@example.com"})
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(400)

    created_email = "human-created-#{System.unique_integer([:positive])}@example.com"
    create_key = "human-create-#{Ecto.UUID.generate()}"

    create_body = %{
      "email" => created_email,
      "name" => "Human Created",
      "admin_access" => "allow",
      "reason" => "Create a support-managed account",
      "idempotency_key" => create_key,
      "confirmation" => "create-user:#{created_email}"
    }

    created =
      :post
      |> json_conn("/v1/comma/admin/users", create_body)
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
      |> expect_json(201)

    assert created["admin_access"]["allowed"]
    assert created["admin_access"]["source"] == "explicit_allow"

    assert created["login_methods"] == [
             %{
               "email" => created_email,
               "method" => "email_otp"
             }
           ]

    assert %{"error" => "admin_command_already_succeeded"} =
             :post
             |> json_conn("/v1/comma/admin/users", create_body)
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(409)

    assert {:ok, %{"id" => created_id}} = Comma.Accounts.get_user_by_email(created_email)
    assert created_id == created["id"]

    update_body = %{
      "name" => "Human Updated",
      "reason" => "Correct the account display name",
      "idempotency_key" => "human-update-#{Ecto.UUID.generate()}",
      "confirmation" => "update-user:#{created["id"]}"
    }

    assert %{"name" => "Human Updated"} =
             :patch
             |> json_conn("/v1/comma/admin/users/#{created["id"]}", update_body)
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(200)

    support_conn =
      :post
      |> json_conn("/v1/comma/admin/users/#{created["id"]}/support-sessions", %{
        "reason" => "Investigate the reported account issue",
        "idempotency_key" => "human-support-#{Ecto.UUID.generate()}",
        "confirmation" => "support-session:#{created["id"]}",
        "expires_in_seconds" => 900,
        "budget" => 3
      })
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()

    support_session = expect_json(support_conn, 201)
    assert support_session["restricted"] == true
    assert "comma_sess_" <> _ = support_session["token"]
    assert get_resp_header(support_conn, "cache-control") == ["no-store"]

    assert {:ok, ordinary_session} =
             Comma.Accounts.create_session(created["id"],
               auth_method: "google",
               client_kind: "web",
               device_label: "Web on macOS"
             )

    assert {:ok, expired_session} =
             Comma.Accounts.create_session(created["id"],
               client_kind: "electron",
               device_label: "Comma Desktop on Linux"
             )

    expired_session["id"]
    |> then(&Repo.get!(AuthSession, &1))
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    |> Repo.update!()

    sessions_conn =
      :get
      |> conn("/v1/comma/admin/users/#{created["id"]}/sessions?limit=50")
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()

    sessions = expect_json(sessions_conn, 200)
    assert get_resp_header(sessions_conn, "cache-control") == ["no-store"]
    assert sessions["has_more"] == false
    assert length(sessions["data"]) == 3

    listed_ordinary =
      Enum.find(sessions["data"], &(&1["id"] == ordinary_session["id"]))

    assert listed_ordinary["auth_method"] == "google"
    assert listed_ordinary["client_kind"] == "web"
    assert listed_ordinary["device_label"] == "Web on macOS"
    refute Map.has_key?(listed_ordinary, "token")
    refute Map.has_key?(listed_ordinary, "token_hash")
    refute Map.has_key?(listed_ordinary, "user_id")
    refute Map.has_key?(listed_ordinary, "workspace_id")

    assert %{"revoked" => true, "session_id" => revoked_session_id} =
             :post
             |> json_conn(
               "/v1/comma/admin/users/#{created["id"]}/sessions/#{ordinary_session["id"]}/revoke",
               %{
                 "reason" => "End the stale browser Session",
                 "idempotency_key" => "human-revoke-#{Ecto.UUID.generate()}",
                 "confirmation" => "revoke-session:#{ordinary_session["id"]}"
               }
             )
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(200)

    assert revoked_session_id == ordinary_session["id"]
    assert {:error, :revoked} = Comma.Accounts.validate_session(ordinary_session["token"])

    assert %{"revoked_count" => 1} =
             :post
             |> json_conn("/v1/comma/admin/users/#{created["id"]}/sessions/revoke-all", %{
               "reason" => "End every remaining target Session",
               "idempotency_key" => "human-revoke-all-#{Ecto.UUID.generate()}",
               "confirmation" => "revoke-all-sessions:#{created["id"]}"
             })
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(200)

    assert {:error, :revoked} = Comma.Accounts.validate_session(support_session["token"])
    assert {:error, :expired} = Comma.Accounts.validate_session(expired_session["token"])
    assert Repo.get!(AuthSession, expired_session["id"]).revoked_at == nil

    workspace =
      :post
      |> json_conn("/v1/comma/admin/users/#{created["id"]}/workspaces", %{
        "reason" => "Ensure the account has its default Workspace",
        "idempotency_key" => "human-workspace-#{Ecto.UUID.generate()}",
        "confirmation" => "default-workspace:#{created["id"]}"
      })
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
      |> expect_json(200)

    assert workspace["status"] in ["provisioning", "ready"]

    workspace_overview_conn =
      :get
      |> conn("/v1/comma/admin/users/#{created["id"]}/workspaces")
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()

    assert %{
             "workspace" => %{
               "id" => workspace_id,
               "billing_account_id" => billing_account_id,
               "group_id" => projected_group_id,
               "status" => projected_status,
               "tenant_id" => projected_tenant_id
             },
             "billing" => %{
               "account_id" => projected_account_id,
               "account_status" => "missing",
               "current_credits" => 0,
               "active_grants" => [],
               "has_more" => false
             }
           } = expect_json(workspace_overview_conn, 200)

    assert workspace_id == workspace["workspace"]["id"]
    assert projected_account_id == billing_account_id
    assert projected_status in ["provisioning", "ready"]

    stored_workspace = Repo.get!(Comma.Data.Workspace, workspace_id)

    assert projected_group_id == stored_workspace.salix_group_id
    assert projected_tenant_id == stored_workspace.salix_tenant_id

    assert get_resp_header(workspace_overview_conn, "cache-control") == ["no-store"]
    refute workspace_overview_conn.resp_body =~ "router_agent_id"
    refute workspace_overview_conn.resp_body =~ "policy_snapshot"
    refute workspace_overview_conn.resp_body =~ "metadata"

    assert %{"error" => "forbidden"} =
             :post
             |> json_conn("/v1/comma/admin/users/#{created["id"]}/sessions", %{})
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(403)

    assert Repo.exists?(
             from(event in Comma.Admin.AuditEvent,
               where:
                 event.actor_key == ^user_id and
                   event.action == "create_user" and
                   event.idempotency_key == ^create_key and
                   event.outcome == "succeeded"
             )
           )

    for action <- ["revoke_user_session", "revoke_all_user_sessions"] do
      assert Repo.exists?(
               from(event in Comma.Admin.AuditEvent,
                 where:
                   event.actor_key == ^user_id and
                     event.action == ^action and
                     event.outcome == "succeeded"
               )
             )
    end

    audit_conn =
      :get
      |> conn("/v1/comma/admin/audit-events?limit=1")
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()

    assert %{
             "data" => [audit_event],
             "has_more" => true,
             "next_cursor" => audit_cursor
           } = expect_json(audit_conn, 200)

    assert get_resp_header(audit_conn, "cache-control") == ["no-store"]
    assert audit_event["actor"]["email"] == "operator@comma.surf"
    assert audit_event["actor"]["user_id"] == user_id
    assert audit_event["outcome"] == "succeeded"
    assert is_binary(audit_event["reason"])
    assert is_binary(audit_cursor)

    assert Map.keys(audit_event) |> Enum.sort() ==
             ~w(action actor created_at error_code id outcome reason target updated_at)

    for internal <- [
          "evidence",
          "idempotency_key",
          "lease_expires_at",
          "request_fingerprint"
        ] do
      refute Map.has_key?(audit_event, internal)
    end

    assert %{"data" => [_next_event]} =
             :get
             |> conn(
               "/v1/comma/admin/audit-events?limit=1&cursor=#{URI.encode_www_form(audit_cursor)}"
             )
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(200)

    assert %{"error" => "invalid_cursor"} =
             :get
             |> conn("/v1/comma/admin/audit-events?cursor=tampered")
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(400)

    assert %{"error" => "unauthorized"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> user_auth(token)
             |> call()
             |> expect_json(401)

    assert %{"error" => "unauthorized"} =
             :get
             |> conn("/v1/comma/admin/audit-events")
             |> user_auth(token)
             |> call()
             |> expect_json(401)
  end

  defmodule SubscriptionWorkerStub do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(state), do: {:ok, state}

    def handle_call({:start, id, data, reply_to}, _from, state) do
      command = Jason.decode!(data)

      result =
        case command["op"] do
          "/oauth/begin" ->
            %{"url" => "https://example.com/authorize", "state" => command["body"]["state"]}

          "/models" ->
            %{
              "data" => [
                %{
                  "id" => command["body"]["provider"] <> "-model",
                  "name" => "Subscription model",
                  "supports_images" => false
                }
              ],
              "truncated" => false
            }

          "/quota/reset" ->
            %{"code" => "reset", "windows_reset" => 2}

          "/quota" ->
            %{
              "windows" => [
                %{
                  "period" => "weekly",
                  "remaining_percent" => 75,
                  "reset_at" => "2027-01-01T00:00:00Z"
                }
              ]
            }

          _ ->
            %{
              "email" => "subscriber@example.com",
              "credentials" => %{
                "access_token" => "subscription-secret",
                "refresh_token" => "refresh-secret"
              }
            }
        end

      send(
        reply_to,
        {:subscription, id, %{"type" => "data", "data" => Base.encode64(Jason.encode!(result))}}
      )

      send(reply_to, {:subscription, id, %{"type" => "done"}})
      {:reply, :ok, state}
    end

    def handle_cast(_, state), do: {:noreply, state}
  end

  @tag :subscription_discovery
  test "subscription model discovery uses only an enabled account from the owner's tenant" do
    previous = Application.get_env(:salix_agent, :subscription_worker)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_agent, :subscription_worker, previous),
        else: Application.delete_env(:salix_agent, :subscription_worker)
    end)

    worker = start_supervised!(SubscriptionWorkerStub)
    Application.put_env(:salix_agent, :subscription_worker, worker)
    login = email_login!("model-discovery-pool@example.com")
    workspace = create_ready_workspace!(login["user"])
    path = "/v1/comma/workspaces/#{workspace["id"]}/model-discovery"
    accounts = "/v1/comma/workspaces/#{workspace["id"]}/subscription-accounts"
    token = login["token"]

    missing =
      :post
      |> json_conn(path, %{"account_pool" => "codex"})
      |> user_auth(token)
      |> call()
      |> expect_json(400)

    assert missing["error"] == "model_discovery_no_account"

    for provider <- ["codex", "claude"] do
      account =
        :post
        |> json_conn(accounts, %{
          "provider" => provider,
          "credentials" => %{"access_token" => "import-secret"}
        })
        |> user_auth(token)
        |> call()
        |> expect_json(200)

      :patch
      |> json_conn("#{accounts}/#{account["id"]}", %{
        "version" => account["version"],
        "disabled" => true
      })
      |> user_auth(token)
      |> call()
      |> expect_json(200)

      :post
      |> json_conn(path, %{"account_pool" => provider})
      |> user_auth(token)
      |> call()
      |> expect_json(400)

      listed = :get |> conn(accounts) |> user_auth(token) |> call() |> expect_json(200)
      disabled = Enum.find(listed["accounts"], &(&1["id"] == account["id"]))

      :patch
      |> json_conn("#{accounts}/#{account["id"]}", %{
        "version" => disabled["version"],
        "disabled" => false
      })
      |> user_auth(token)
      |> call()
      |> expect_json(200)

      models =
        :post
        |> json_conn(path, %{"account_pool" => provider})
        |> user_auth(token)
        |> call()
        |> expect_json(200)

      assert models["data"] == [
               %{
                 "id" => provider <> "-model",
                 "name" => "Subscription model",
                 "supports_images" => false
               }
             ]

      assert models["protocol"] == if(provider == "codex", do: "responses", else: "anthropic")
      refute Jason.encode!(models) =~ "secret"
    end

    other = email_login!("model-discovery-other@example.com")
    other_workspace = create_ready_workspace!(other["user"])

    :post
    |> json_conn(path, %{"account_pool" => "codex"})
    |> user_auth(other["token"])
    |> call()
    |> expect_json(403)

    :post
    |> json_conn("/v1/comma/workspaces/#{other_workspace["id"]}/model-discovery", %{
      "account_pool" => "codex"
    })
    |> user_auth(other["token"])
    |> call()
    |> expect_json(400)

    :post
    |> json_conn(path, %{"account_pool" => "codex", "tenant_id" => workspace["salix_tenant_id"]})
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    :post
    |> json_conn(path, %{"account_pool" => "invalid"})
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{login["user"]["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :post
    |> json_conn(path, %{"account_pool" => "codex"})
    |> user_auth(restricted["token"])
    |> call()
    |> expect_json(403)
  end

  @tag :subscription_selection
  test "subscription choices reuse templates and preserve model and effort through assignment" do
    login = email_login!("subscription-choices@example.com")
    workspace = create_ready_workspace!(login["user"])
    tenant = workspace["salix_tenant_id"]
    path = "/v1/comma/workspaces/#{workspace["id"]}/model-templates"
    token = login["token"]

    choice = %{
      "account_pool" => "codex",
      "model" => "gpt-choice",
      "reasoning_effort" => "ultra",
      "model_display_name" => "Choice model",
      "supports_images" => true
    }

    # A manually created subscription template is eligible, with its settings intact.
    existing =
      :post
      |> json_conn(
        path,
        Map.merge(choice, %{
          "name" => "Custom limits",
          "provider" => "openai",
          "context_tokens" => 123_000
        })
      )
      |> user_auth(token)
      |> call()
      |> expect_json(201)

    assert existing["reasoning_effort"] == "ultra"
    custom_image = %{"provider" => "openai", "model" => "custom-image"}

    # Existing native Responses settings take precedence over the generic field.
    assert {:ok, _} =
             SalixAgent.Templates.update_private(
               existing["template_id"],
               %{
                 "image_config" => custom_image,
                 "provider_config" => %{
                   "account_pool" => "codex",
                   "protocol" => "responses",
                   "reasoning_effort" => "low",
                   "reasoning" => %{"effort" => "ultra"}
                 }
               },
               tenant
             )

    resolve = fn input ->
      :post
      |> json_conn(path <> "/resolve-subscription", input)
      |> user_auth(token)
      |> call()
      |> expect_json(200)
    end

    reused = resolve.(choice)
    assert reused["template_id"] == existing["template_id"]
    assert reused["reasoning_effort"] == "ultra"
    assert reused["context_tokens"] == 123_000
    assert reused["name"] == "Custom limits"
    assert {:ok, reused_template} = SalixAgent.Templates.get(existing["template_id"], tenant)
    assert reused_template["image_config"] == custom_image

    # Missing choices are created once, including simultaneous menu requests.
    low = %{choice | "reasoning_effort" => "low"}

    created =
      1..3
      |> Enum.map(fn _ -> Task.async(fn -> resolve.(low) end) end)
      |> Enum.map(&Task.await(&1, 30_000))

    assert [created_id] = created |> Enum.map(& &1["template_id"]) |> Enum.uniq()
    assert created_id != existing["template_id"]
    assert Enum.all?(created, &(&1["context_tokens"] == 500_000))
    assert resolve.(low)["template_id"] == created_id
    assert {:ok, templates} = SalixAgent.Templates.list_private(tenant)
    assert length(templates) == 2
    assert {:ok, created_template} = SalixAgent.Templates.get(created_id, tenant)

    assert created_template["image_config"] == %{
             "provider" => "openai",
             "model" => "gpt-image-2",
             "provider_config" => %{"account_pool" => "codex"}
           }

    assert {:ok, media} = SalixAgent.Templates.resolve_media_for_template(created_id, tenant)
    assert media["image_config"]["account_pool_tenant"] == tenant

    claude = resolve.(%{"account_pool" => "claude", "model" => "claude-choice"})
    assert {:ok, claude_template} = SalixAgent.Templates.get(claude["template_id"], tenant)
    assert claude_template["image_config"] == %{}

    for target <- ["router", "worker"] do
      for _ <- 1..2 do
        selected =
          :put
          |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/agent-models/#{target}", %{
            "template_id" => created_id
          })
          |> user_auth(token)
          |> call()
          |> expect_json(200)

        assert selected["model"] == "gpt-choice"
        assert selected["reasoning_effort"] == "low"
      end
    end

    assert {:ok, llm} = SalixAgent.Templates.resolve_llm_for_agent(workspace["router_agent_id"])
    assert llm["model"] == "gpt-choice"
    assert llm["reasoning_effort"] == "low"
    assert SalixAgent.AccountPool.owns_route?(llm)

    transport = fn url, options ->
      assert url == "subscription://worker/v1/responses"
      body = Jason.decode!(options[:body])
      assert body["model"] == "gpt-choice"
      assert body["reasoning"] == %{"effort" => "low"}

      {:ok,
       %{
         status: 200,
         body: %{
           "output" => [
             %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "ok"}]}
           ]
         }
       }}
    end

    assert {:final, "ok"} =
             SalixLlm.OpenAIResponses.complete(
               [%{role: "user", content: "hello"}],
               [],
               Map.put(llm, "transport", transport)
             )

    :put
    |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/agent-models/worker-default", %{
      "template_id" => created_id
    })
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    assert {:ok, defaults} = SalixAgent.AgentDefaults.tenant(tenant)
    assert defaults["worker_template_id"] == created_id

    # An ordinary edit must preserve the chosen effort.
    edited =
      :patch
      |> json_conn(path <> "/" <> created_id, %{"name" => "Renamed"})
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    assert edited["reasoning_effort"] == "low"

    other = email_login!("subscription-choices-other@example.com")
    other_workspace = create_ready_workspace!(other["user"])

    :post
    |> json_conn(path <> "/resolve-subscription", choice)
    |> user_auth(other["token"])
    |> call()
    |> expect_json(403)

    :post |> json_conn(path <> "/resolve-subscription", choice) |> call() |> expect_json(401)

    :post
    |> json_conn(path <> "/resolve-subscription", %{choice | "reasoning_effort" => []})
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    :post
    |> json_conn(path <> "/resolve-subscription", Map.put(choice, "tenant_id", tenant))
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    other_choice =
      :post
      |> json_conn(
        "/v1/comma/workspaces/#{other_workspace["id"]}/model-templates/resolve-subscription",
        choice
      )
      |> user_auth(other["token"])
      |> call()
      |> expect_json(200)

    assert other_choice["template_id"] != existing["template_id"]
  end

  @tag :subscriptions
  test "workspace owners manage subscriptions and assign pool templates without exposing credentials" do
    # This test owns account versions through explicit HTTP mutations. The
    # background quota poller also changes them, so keep that independent
    # writer out of this request-contract test (manual quota refresh stays covered).
    quota_worker = Process.whereis(SalixAgent.SubscriptionQuotaWorker)
    if quota_worker, do: :sys.suspend(quota_worker)

    on_exit(fn ->
      if quota_worker && Process.alive?(quota_worker), do: :sys.resume(quota_worker)
    end)

    previous = Application.get_env(:salix_agent, :subscription_worker)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_agent, :subscription_worker, previous),
        else: Application.delete_env(:salix_agent, :subscription_worker)
    end)

    worker = start_supervised!(SubscriptionWorkerStub)
    Application.put_env(:salix_agent, :subscription_worker, worker)
    login = email_login!("subscriptions@example.com")
    workspace = create_ready_workspace!(login["user"])
    token = login["token"]
    path = "/v1/comma/workspaces/#{workspace["id"]}/subscription-accounts"

    account =
      :post
      |> json_conn(path, %{
        "provider" => "codex",
        "credentials" => %{"access_token" => "import-secret"}
      })
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    refute Jason.encode!(account) =~ "secret"
    assert account["email"] == "subscriber@example.com"
    id = account["id"]
    listed = :get |> conn(path) |> user_auth(token) |> call() |> expect_json(200)
    assert Enum.any?(listed["accounts"], &(&1["id"] == id))
    refute Jason.encode!(listed) =~ "secret"
    other = email_login!("subscriptions-other@example.com")
    other_workspace = create_ready_workspace!(other["user"])
    other_path = "/v1/comma/workspaces/#{other_workspace["id"]}/subscription-accounts"
    :get |> conn(path) |> user_auth(other["token"]) |> call() |> expect_json(403)

    :patch
    |> json_conn("#{other_path}/#{id}", %{"version" => account["version"], "disabled" => true})
    |> user_auth(other["token"])
    |> call()
    |> expect_json(404)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{login["user"]["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :get |> conn(path) |> user_auth(restricted["token"]) |> call() |> expect_json(403)

    reset_attrs = %{
      "version" => account["version"],
      "request_id" => SalixAgent.SubscriptionStore.id()
    }

    for denied_token <- [other["token"], restricted["token"]] do
      :post
      |> json_conn("#{path}/#{id}/quota/reset", reset_attrs)
      |> user_auth(denied_token)
      |> call()
      |> expect_json(403)
    end

    :post
    |> json_conn("#{other_path}/#{id}/quota/reset", reset_attrs)
    |> user_auth(other["token"])
    |> call()
    |> expect_json(404)

    :post
    |> json_conn(path, %{"provider" => "invalid", "credentials" => %{}})
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    updated =
      :patch
      |> json_conn("#{path}/#{id}", %{"version" => account["version"], "disabled" => true})
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    assert updated["disabled"]

    :patch
    |> json_conn("#{path}/#{id}", %{"version" => account["version"], "disabled" => false})
    |> user_auth(token)
    |> call()
    |> expect_json(409)

    _updated =
      :patch
      |> json_conn("#{path}/#{id}", %{"version" => updated["version"], "disabled" => false})
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    quota =
      :post
      |> json_conn("#{path}/#{id}/quota", %{})
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    assert hd(quota["quota"]["windows"])["remaining_percent"] == 75

    reset_attrs = %{reset_attrs | "version" => quota["version"]}

    reset =
      :post
      |> json_conn("#{path}/#{id}/quota/reset", reset_attrs)
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    assert reset["outcome"] == "reset"
    assert reset["quota_refreshed"]
    refute Jason.encode!(reset) =~ "secret"

    replay =
      :post
      |> json_conn("#{path}/#{id}/quota/reset", reset_attrs)
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    assert replay["outcome"] == "reset"
    quota = replay["account"]

    attempt =
      :post
      |> json_conn("#{path}/oauth", %{
        "provider" => "codex",
        "account_id" => id,
        "version" => quota["version"]
      })
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    :post
    |> json_conn("#{other_path}/oauth/#{attempt["id"]}", %{"code" => "code"})
    |> user_auth(other["token"])
    |> call()
    |> expect_json(400)

    updated =
      :post
      |> json_conn("#{path}/oauth/#{attempt["id"]}", %{"code" => "code"})
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    refute Jason.encode!(updated) =~ "secret"
    template_path = "/v1/comma/workspaces/#{workspace["id"]}/model-templates"

    template =
      :post
      |> json_conn(template_path, %{
        "name" => "Subscription model",
        "model" => "gpt-pool",
        "provider" => "openai",
        "account_pool" => "codex"
      })
      |> user_auth(token)
      |> call()
      |> expect_json(201)

    assert template["account_pool"] == "codex"
    refute template["has_api_key"]

    :put
    |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/agent-models/router", %{
      "template_id" => template["template_id"]
    })
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    assert {:ok, config} =
             SalixAgent.Templates.resolve_llm_for_agent(workspace["router_agent_id"])

    assert SalixAgent.AccountPool.owns_route?(config)
    assert config["account_pool_tenant"] == workspace["salix_tenant_id"]
    refute Map.has_key?(config, "api_key")

    claude =
      :post
      |> json_conn(template_path, %{
        "name" => "Claude pool",
        "model" => "claude-pool",
        "provider" => "anthropic",
        "account_pool" => "claude"
      })
      |> user_auth(token)
      |> call()
      |> expect_json(201)

    assert claude["protocol"] == "anthropic"

    :put
    |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/agent-models/worker", %{
      "template_id" => claude["template_id"]
    })
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    assert {:ok, claude_config} =
             SalixAgent.Templates.resolve_llm_for_agent(workspace["default_worker_agent_id"])

    assert SalixAgent.AccountPool.owns_route?(claude_config)
    assert claude_config["protocol"] == "anthropic"

    :delete
    |> json_conn("#{path}/#{id}", %{"version" => updated["version"]})
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    assert {:error, :not_found} =
             SalixAgent.SubscriptionStore.get(workspace["salix_tenant_id"], id)
  end

  defmodule DiscoveryProvider do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"data" => [%{"id" => "o3"}]}))
    end
  end

  @tag :byok
  test "the Comma-installed Worker port supports a non-Comma tenant" do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Non-Comma tenant"})
    tenant_id = tenant["tenant_id"]
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Non-Comma group"}, tenant_id)

    {:ok, template} =
      SalixAgent.Templates.create(%{
        "name" => "Non-Comma model",
        "model" => "mock",
        "provider" => "mock"
      })

    template_id = template["template_id"]

    {:ok, _} =
      Salix.Control.Tenants.update_config(tenant_id, "agent_defaults", %{
        "worker_template_id" => template_id
      })

    {:ok, router} =
      SalixAgent.Control.create(
        %{
          "group_id" => group["group_id"],
          "role" => "router",
          "template_id" => template_id
        },
        tenant_id
      )

    previous_ports = Application.get_env(:salix_agent, :agent_management_ports)
    Application.put_env(:salix_agent, :agent_management_ports, CommaWeb.AgentManagement)
    on_exit(fn -> restore_env(:salix_agent, :agent_management_ports, previous_ports) end)

    assert {:ok, result} =
             SalixAgent.AgentManagement.run(
               :create,
               %{
                 "name" => "Non-Comma task Worker",
                 "purpose" => "User task",
                 "creation_reason" => "Create a Worker through the shared port",
                 "runtime" => %{"kind" => "internal"}
               },
               %{
                 agent_id: router["agent_id"],
                 session_id: "non-comma-session",
                 tool_call_id: "non-comma-create"
               }
             )

    assert result["agent"]["model"]["template_id"] == template_id
    assert {:ok, created} = SalixAgent.Control.get(result["agent"]["agent_id"], tenant_id)
    assert created["template_id"] == template_id
  end

  @tag :byok
  test "Worker model settings report runtime choices and reject ineffective template writes" do
    login = email_login!("runtime-worker-models@example.com")
    token = login["token"]
    workspace = create_ready_workspace!(login["user"])
    tenant = workspace["salix_tenant_id"]
    group = workspace["default_group_id"]
    path = "/v1/comma/workspaces/#{workspace["id"]}/agent-models"

    runtime = %{
      "kind" => "external",
      "provider" => "codex",
      "device_id" => "model-test-device",
      "runtime_id" => "model-test-codex",
      "device_runtime_id" =>
        SalixStore.RuntimeIds.device_runtime_id("model-test-device", "codex", "model-test-codex")
    }

    {:ok, connected} =
      SalixAgent.Control.create(
        %{
          "group_id" => group,
          "role" => "worker",
          "name" => "Connected Codex",
          "runtime_config" => runtime
        },
        tenant
      )

    {:ok, configured} =
      SalixAgent.Control.create(
        %{
          "group_id" => group,
          "role" => "worker",
          "name" => "Configured Codex",
          "runtime_config" =>
            Map.merge(runtime, %{"model" => "gpt-codex", "reasoning_effort" => "high"})
        },
        tenant
      )

    # Existing Compute records can have an explicit model or inherit a template.
    compute = fn name, spec ->
      id = SalixStore.Ids.new_agent_id(group)

      {:ok, agent} =
        SalixAgent.Control.create_preallocated(
          %{
            "group_id" => group,
            "role" => "worker",
            "name" => name,
            "runtime_config" => %{
              "kind" => "compute_workload",
              "workload_id" => "model-test-workload",
              "runtime_spec" => Map.put(spec, "provider", "codex")
            }
          },
          tenant,
          id
        )

      agent
    end

    explicit =
      compute.("Explicit Compute", %{"model" => "gpt-compute", "reasoning_effort" => "medium"})

    inherited = compute.("Inherited Compute", %{})

    models = :get |> conn(path) |> user_auth(token) |> call() |> expect_json(200)
    by_id = Map.new(models["workers"]["items"], &{&1["agent_id"], &1})
    assert by_id[connected["agent_id"]]["source"] == "runtime_default"
    assert by_id[connected["agent_id"]]["model"] == nil

    assert by_id[connected["agent_id"]]["runtime"] == %{
             "kind" => "connected",
             "provider" => "codex"
           }

    assert by_id[configured["agent_id"]]["source"] == "agent_config"
    assert by_id[configured["agent_id"]]["model"] == "gpt-codex"
    assert by_id[configured["agent_id"]]["reasoning_effort"] == "high"
    assert by_id[explicit["agent_id"]]["model"] == "gpt-compute"
    assert by_id[explicit["agent_id"]]["runtime"]["kind"] == "compute"
    assert by_id[inherited["agent_id"]]["source"] in ~w(pinned platform_default)

    assert by_id[inherited["agent_id"]]["template_id"] ==
             models["platform_defaults"]["worker"]["template_id"]

    for agent <- [connected, configured, explicit] do
      :put
      |> json_conn(path <> "/" <> agent["agent_id"], %{"template_id" => nil})
      |> user_auth(token)
      |> call()
      |> expect_json(400)

      {:ok, unchanged} = SalixAgent.Control.get(agent["agent_id"], tenant)
      assert unchanged["template_id"] == agent["template_id"]
      assert unchanged["runtime_config"] == agent["runtime_config"]
    end
  end

  @tag :byok
  test "Worker creation default and existing Worker choices are independent" do
    login = email_login!("worker-defaults@example.com")
    token = login["token"]
    workspace = create_ready_workspace!(login["user"])
    tenant_id = workspace["salix_tenant_id"]
    worker_id = workspace["default_worker_agent_id"]
    {:ok, chosen} = SalixAgent.Templates.create(%{"name" => "Chosen", "model" => "gpt-chosen"})
    path = "/v1/comma/workspaces/#{workspace["id"]}/agent-models"
    {:ok, before} = SalixAgent.Control.get(worker_id, tenant_id)

    :put
    |> json_conn(path <> "/worker-default", %{"template_id" => chosen["template_id"]})
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    {:ok, unchanged} = SalixAgent.Control.get(worker_id, tenant_id)
    assert unchanged["template_id"] == before["template_id"]

    {:ok, new_worker} =
      SalixAgent.Control.create(
        %{
          "group_id" => workspace["default_group_id"],
          "role" => "worker",
          "name" => "Second Worker"
        },
        tenant_id
      )

    assert new_worker["template_id"] == chosen["template_id"]

    :put
    |> json_conn(path <> "/" <> new_worker["agent_id"], %{"template_id" => nil})
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    {:ok, defaults} = SalixAgent.AgentDefaults.tenant(tenant_id)
    assert defaults["worker_template_id"] == chosen["template_id"]
    models = :get |> conn(path) |> user_auth(token) |> call() |> expect_json(200)
    assert models["worker_default_template_id"] == chosen["template_id"]

    assert Enum.any?(
             models["workers"]["items"],
             &(&1["agent_id"] == new_worker["agent_id"] and &1["source"] == "platform_default")
           )

    assert Enum.any?(models["workers"]["items"], &(&1["agent_id"] == worker_id))
    refute Enum.any?(models["available_models"], &(&1["template_id"] == "default"))

    :put
    |> json_conn(path <> "/worker-default", %{"template_id" => 42})
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    {:ok, other_group} = Salix.Control.Groups.create(%{"name" => "Other group"}, tenant_id)

    {:ok, foreign_worker} =
      SalixAgent.Control.create(
        %{"group_id" => other_group["group_id"], "role" => "worker"},
        tenant_id
      )

    :put
    |> json_conn(path <> "/" <> foreign_worker["agent_id"], %{"template_id" => nil})
    |> user_auth(token)
    |> call()
    |> expect_json(404)

    other = create_ready_workspace!(email_login!("other-worker-defaults@example.com")["user"])

    :put
    |> json_conn(path <> "/" <> other["default_worker_agent_id"], %{"template_id" => nil})
    |> user_auth(token)
    |> call()
    |> expect_json(404)
  end

  @tag :byok
  test "users manage their own keys and select models without revealing credentials" do
    login = email_login!("byok@example.com")
    token = login["token"]
    workspace = create_ready_workspace!(login["user"])
    path = "/v1/comma/workspaces/#{workspace["id"]}/model-templates"

    attrs = %{
      "name" => "My model",
      "model" => "gpt-byok",
      "provider" => "openai",
      "protocol" => "responses",
      "base_url" => "https://example.com/v1",
      "api_key" => "byok-secret",
      "reasoning_effort" => "high"
    }

    created_conn = :post |> json_conn(path, attrs) |> user_auth(token) |> call()
    created = expect_json(created_conn, 201)
    id = created["template_id"]
    assert created["has_api_key"]
    refute created_conn.resp_body =~ "byok-secret"
    refute Map.has_key?(created, "provider_config")

    other = email_login!("byok-other@example.com")
    other_workspace = create_ready_workspace!(other["user"])
    other_path = "/v1/comma/workspaces/#{other_workspace["id"]}/model-templates"

    :patch
    |> json_conn("#{other_path}/#{id}", %{"name" => "stolen"})
    |> user_auth(other["token"])
    |> call()
    |> expect_json(404)

    :get |> conn(path) |> user_auth(other["token"]) |> call() |> expect_json(403)

    assert %{"data" => []} =
             :get |> conn(other_path) |> user_auth(other["token"]) |> call() |> expect_json(200)

    :patch
    |> json_conn("#{path}/#{id}", %{"name" => "Renamed"})
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    assert {:ok, stored} = SalixAgent.Templates.get(id, workspace["salix_tenant_id"])
    assert stored["provider_config"]["api_key"] == "byok-secret"
    assert stored["provider_config"]["reasoning_effort"] == "high"

    discovery_path = "/v1/comma/workspaces/#{workspace["id"]}/model-discovery"
    discovery_input = Map.take(attrs, ~w(base_url api_key protocol))
    :post |> json_conn(discovery_path, discovery_input) |> call() |> expect_json(401)

    :post
    |> json_conn(discovery_path, discovery_input)
    |> user_auth(other["token"])
    |> call()
    |> expect_json(403)

    :post
    |> json_conn(discovery_path, Map.put(discovery_input, "api_key", ""))
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{login["user"]["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => workspace["id"]
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    :post
    |> json_conn(discovery_path, discovery_input)
    |> user_auth(restricted["token"])
    |> call()
    |> expect_json(403)

    server =
      start_supervised!(
        {Bandit, plug: DiscoveryProvider, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    response =
      :post
      |> json_conn(discovery_path, %{
        discovery_input
        | "base_url" => "http://127.0.0.1:#{port}/v1"
      })
      |> user_auth(token)
      |> call()

    assert %{"data" => [%{"id" => "o3"}]} = expect_json(response, 200)
    assert get_resp_header(response, "cache-control") == ["no-store"]
    refute response.resp_body =~ "byok-secret"

    assert %{"data" => [%{"template_id" => ^id}]} =
             :get |> conn(path) |> user_auth(token) |> call() |> expect_json(200)

    :patch
    |> json_conn("#{path}/#{id}", %{"reasoning_effort" => "invalid"})
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    :patch
    |> json_conn("#{path}/#{id}", %{"base_url" => "https://different.example/v1"})
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    :patch
    |> json_conn("#{path}/#{id}", %{"api_key" => ""})
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    :post
    |> json_conn(path, Map.put(attrs, "tenant_id", other_workspace["salix_tenant_id"]))
    |> user_auth(token)
    |> call()
    |> expect_json(400)

    :patch
    |> json_conn("#{path}/#{id}", %{"api_key" => "replacement-secret"})
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    model_path = "/v1/comma/workspaces/#{workspace["id"]}/agent-models"
    original = :get |> conn(model_path) |> user_auth(token) |> call() |> expect_json(200)

    assert Enum.find(original["available_models"], &(&1["template_id"] == id))[
             "reasoning_effort"
           ] == "high"

    original_id = original["agents"]["worker"]["template_id"]
    assert original["agents"]["worker"]["source"] in ["pinned", "platform_default"]
    assert is_map(original["platform_defaults"])

    chosen =
      :put
      |> json_conn("#{model_path}/worker", %{"template_id" => id})
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    assert chosen["source"] == "pinned"
    assert chosen["template_id"] == id

    # Choosing nothing returns the role to the Comma default and names it.
    followed =
      :put
      |> json_conn("#{model_path}/worker", %{"template_id" => nil})
      |> user_auth(token)
      |> call()
      |> expect_json(200)

    assert followed["source"] == "platform_default"
    assert followed["template_id"] == original["platform_defaults"]["worker"]["template_id"]
    assert followed["template_name"] == original["platform_defaults"]["worker"]["name"]

    :put
    |> json_conn("#{model_path}/worker", %{"template_id" => id})
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    assert {:ok, llm} =
             SalixAgent.Templates.resolve_llm_for_agent(workspace["default_worker_agent_id"])

    assert llm["api_key"] == "replacement-secret"
    assert llm["reasoning_effort"] == "high"
    assert llm["credential_scope"] == "tenant"

    :patch
    |> json_conn("#{path}/#{id}", %{"reasoning_effort" => nil})
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    assert {:ok, default_llm} =
             SalixAgent.Templates.resolve_llm_for_agent(workspace["default_worker_agent_id"])

    assert is_nil(default_llm["reasoning_effort"])

    :put
    |> json_conn("#{model_path}/worker-default", %{"template_id" => id})
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    scope = %{tenant_id: workspace["salix_tenant_id"], group_id: workspace["default_group_id"]}
    assert {:ok, ^id} = CommaWeb.AgentManagement.worker_template(scope)
    previous_ports = Application.get_env(:salix_agent, :agent_management_ports)
    Application.put_env(:salix_agent, :agent_management_ports, CommaWeb.AgentManagement)
    on_exit(fn -> restore_env(:salix_agent, :agent_management_ports, previous_ports) end)

    assert {:ok, created_worker} =
             SalixAgent.AgentManagement.run(
               :create,
               %{
                 "name" => "BYOK task worker",
                 "purpose" => "User task",
                 "creation_reason" =>
                   "Exercise an independent Worker with the user-selected BYOK model",
                 "runtime" => %{"kind" => "internal"}
               },
               %{
                 agent_id: workspace["router_agent_id"],
                 session_id: "byok-session",
                 tool_call_id: "byok-create"
               }
             )

    task_worker_id = created_worker["agent"]["agent_id"]
    assert created_worker["agent"]["model"]["template_id"] == id

    :put
    |> json_conn("#{model_path}/router", %{"template_id" => id})
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    assert {:ok, %{fee_control: %{reason: "tenant_credentials"}}} =
             Comma.AgentPolicies.authorize_send(
               workspace,
               %{"id" => "byok-chat", "kind" => "user_chat"},
               %{},
               %{}
             )

    assert :ok = CommaWeb.SalixClient.provision_workspace_scope(workspace)
    assert {:ok, ^id} = CommaWeb.AgentManagement.worker_template(scope)
    :delete |> conn("#{path}/#{id}") |> user_auth(token) |> call() |> expect_json(409)

    :put
    |> json_conn("#{model_path}/worker", %{"template_id" => original_id})
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    assert {:ok, task_llm} = SalixAgent.Templates.resolve_llm_for_agent(task_worker_id)
    assert task_llm["credential_scope"] == "tenant"
    assert task_llm["api_key"] == "replacement-secret"

    :put
    |> json_conn("#{model_path}/router", %{"template_id" => original_id})
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    assert {:ok, _} =
             SalixAgent.Control.configure(
               task_worker_id,
               %{"template_id" => original_id},
               scope.tenant_id
             )

    :put
    |> json_conn("#{model_path}/worker-default", %{"template_id" => nil})
    |> user_auth(token)
    |> call()
    |> expect_json(200)

    :delete |> conn("#{path}/#{id}") |> user_auth(token) |> call() |> expect_json(200)
  end

  @tag :workspace_cloud_vm
  test "Admin audits exact-workspace VM settings and converges both agent configurations" do
    previous = Application.get_env(:salix_agent, :cloud_vm_mod)
    Application.put_env(:salix_agent, :cloud_vm_mod, __MODULE__.WorkspaceVM)
    on_exit(fn -> restore_env(:salix_agent, :cloud_vm_mod, previous) end)

    Application.put_env(:comma_core, :salix_vm, %{
      "providers" => %{"cloudflare" => %{"enabled" => true, "token" => "test-only"}}
    })

    {operator, token} = browser_cookie_login!("vm-operator@comma.surf", @admin_origin)
    {:ok, target} = Comma.Accounts.create_user(%{"email" => "vm-target@example.com"})

    workspace =
      create_ready_workspace!(target, %{"vm" => %{"enabled" => true, "provider" => "cloudflare"}})

    workspace_id = workspace["id"]
    path = "/v1/comma/admin/users/#{target["id"]}/workspaces/#{workspace_id}/vm"
    other_workspace = create_ready_workspace!(operator["user"])
    {outsider, outsider_token} = browser_cookie_login!("vm-outsider@example.com", @admin_origin)

    for enabled <- [false, true] do
      state = if enabled, do: "enable", else: "disable"

      body = %{
        "enabled" => enabled,
        "reason" => "Configure this Workspace Cloud VM",
        "confirmation" => "workspace-vm:#{workspace_id}:#{state}",
        "idempotency_key" => Ecto.UUID.generate()
      }

      :put |> json_conn(path, body) |> call() |> expect_json(401)

      :put
      |> json_conn(path, body)
      |> cookie_auth(outsider_token, @admin_origin, outsider["session_id"])
      |> call()
      |> expect_json(403)

      :put
      |> json_conn(path, Map.put(body, "confirmation", "wrong-workspace"))
      |> cookie_auth(token, @admin_origin, operator["session_id"])
      |> call()
      |> expect_json(400)

      result =
        :put
        |> json_conn(path, body)
        |> cookie_auth(token, @admin_origin, operator["session_id"])
        |> call()

      assert %{
               "workspace_id" => ^workspace_id,
               "enabled" => ^enabled,
               "convergence_status" => "pending"
             } = expect_json(result, 202)

      assert get_resp_header(result, "cache-control") == ["no-store"]
      row = Repo.get!(Comma.Data.Workspace, workspace_id)
      assert row.vm == %{"enabled" => enabled, "provider" => "cloudflare"}
      assert Repo.get!(Comma.Data.Workspace, other_workspace["id"]).vm == %{"enabled" => false}

      operation =
        Repo.get_by!(Comma.Data.ExternalOperation,
          owner_id: workspace_id,
          operation_type: "workspace_convergence",
          generation: row.lock_version
        )

      assert Repo.exists?(
               from(job in Oban.Job,
                 where: fragment("?->>'operation_id'", job.args) == ^operation.operation_id
               )
             )

      assert {:ok, %{status: "succeeded"}} =
               Comma.Workers.WorkspaceConvergence.run(operation.operation_id)

      for agent_id <- [workspace["router_agent_id"], workspace["default_worker_agent_id"]] do
        assert {:ok, %{"vm" => %{"enabled" => ^enabled}}} =
                 SalixAgent.Control.get(agent_id, workspace["salix_tenant_id"])
      end

      assert %{outcome: "succeeded", target_id: ^workspace_id} =
               Repo.get_by!(Comma.Admin.AuditEvent,
                 action: "update_workspace_vm",
                 idempotency_key: body["idempotency_key"]
               )

      :put
      |> json_conn(path, body)
      |> cookie_auth(token, @admin_origin, operator["session_id"])
      |> call()
      |> expect_json(409)

      assert Repo.get!(Comma.Data.Workspace, workspace_id).lock_version == row.lock_version
    end

    :put
    |> json_conn(path, %{
      "enabled" => "yes",
      "reason" => "Reject invalid input",
      "confirmation" => "workspace-vm:#{workspace_id}:disable",
      "idempotency_key" => Ecto.UUID.generate()
    })
    |> cookie_auth(token, @admin_origin, operator["session_id"])
    |> call()
    |> expect_json(400)

    assert %{
             "workspace" => %{
               "cloud_vm" => %{"enabled" => true, "convergence_status" => "succeeded"}
             }
           } =
             :get
             |> conn("/v1/comma/admin/users/#{target["id"]}/workspaces")
             |> cookie_auth(token, @admin_origin, operator["session_id"])
             |> call()
             |> expect_json(200)

    assert {:error, :not_found} =
             Comma.Admin.update_user_workspace_vm(target["id"], other_workspace["id"], true)
  end

  @tag :workspace_cloud_vm
  test "new default Workspace converges with VM enabled for Router and Worker" do
    previous = Application.get_env(:salix_agent, :cloud_vm_mod)
    Application.put_env(:salix_agent, :cloud_vm_mod, __MODULE__.WorkspaceVM)
    on_exit(fn -> restore_env(:salix_agent, :cloud_vm_mod, previous) end)
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "default-vm@example.com"})
    {:ok, pending} = Comma.WorkspaceBootstrap.ensure_default(user["id"])
    id = pending["workspace"]["id"]
    operation = Repo.get_by!(Comma.Data.ExternalOperation, owner_id: id, generation: 1)

    assert {:ok, %{status: "succeeded"}} =
             Comma.Workers.WorkspaceConvergence.run(operation.operation_id)

    {:ok, workspace} = Comma.Workspaces.get(id)
    assert workspace["vm"] == %{"enabled" => true}

    assert {:ok, %{"billing_owner" => %{"vm_profile_key" => "cf-standard-1"}}} =
             Salix.Control.Groups.get(workspace["default_group_id"])

    assert {:error, :not_found} =
             SalixStore.Compute.group_workload(workspace["default_group_id"])

    for agent_id <- [workspace["router_agent_id"], workspace["default_worker_agent_id"]] do
      assert {:ok, %{"vm" => %{"enabled" => true}}} =
               SalixAgent.Control.get(agent_id, workspace["salix_tenant_id"])
    end
  end

  defmodule WorkspaceVM do
    def default_provider(_tenant), do: {:ok, "cloudflare"}
    def validate_enabled(_tenant, _provider), do: :ok
    def validate_group_provider(_group, _provider), do: :ok
    def ensure_provisioning(_agent), do: {:ok, %{}}
    def attach(agent), do: agent
    def mark_agent_settled(_agent), do: :ok
  end

  test "Comma model selection policy limits new global choices and preserves existing choices" do
    {admin_session, admin_token} = browser_cookie_login!("model-policy@comma.surf", @admin_origin)

    {:ok, _} =
      Comma.Admin.set_admin_access(
        admin_session["user"]["id"],
        "allow",
        :ops,
        "Test model policy"
      )

    login = email_login!("model-policy-user@example.com")
    workspace = create_ready_workspace!(login["user"])
    user_token = login["token"]
    model_path = "/v1/comma/workspaces/#{workspace["id"]}/agent-models"
    policy_path = "/v1/comma/admin/model-selection-policy"

    {:ok, first} = SalixAgent.Templates.create(%{"name" => "First", "model" => "gpt-first"})
    {:ok, second} = SalixAgent.Templates.create(%{"name" => "Second", "model" => "gpt-second"})
    first_id = first["template_id"]
    second_id = second["template_id"]

    private =
      :post
      |> json_conn("/v1/comma/workspaces/#{workspace["id"]}/model-templates", %{
        "name" => "Private",
        "model" => "private-model",
        "provider" => "openai",
        "protocol" => "responses",
        "base_url" => "https://example.com/v1",
        "api_key" => "private-key"
      })
      |> user_auth(user_token)
      |> call()
      |> expect_json(201)

    :put
    |> json_conn(model_path <> "/router", %{"template_id" => second_id})
    |> user_auth(user_token)
    |> call()
    |> expect_json(200)

    :put
    |> json_conn(model_path <> "/worker-default", %{"template_id" => second_id})
    |> user_auth(user_token)
    |> call()
    |> expect_json(200)

    initial =
      :get
      |> conn(policy_path)
      |> cookie_auth(admin_token, @admin_origin, admin_session["session_id"])
      |> call()
      |> expect_json(200)

    assert initial["mode"] == "all"

    catalog =
      :get
      |> conn(policy_path <> "/templates")
      |> cookie_auth(admin_token, @admin_origin, admin_session["session_id"])
      |> call()
      |> expect_json(200)

    assert Enum.any?(catalog["data"], &(&1["template_id"] == first_id))

    attrs = %{
      "mode" => "selected",
      "allowed_template_ids" => [first_id],
      "revision" => initial["revision"],
      "reason" => "Limit Comma model choices",
      "confirmation" => "update-model-selection-policy:comma",
      "idempotency_key" => "model-policy-select-1"
    }

    :put |> json_conn(policy_path, attrs) |> user_auth(user_token) |> call() |> expect_json(401)

    :put
    |> json_conn(policy_path, %{
      attrs
      | "allowed_template_ids" => [private["template_id"]],
        "idempotency_key" => "model-policy-private-1"
    })
    |> cookie_auth(admin_token, @admin_origin, admin_session["session_id"])
    |> call()
    |> expect_json(400)

    saved =
      :put
      |> json_conn(policy_path, attrs)
      |> cookie_auth(admin_token, @admin_origin, admin_session["session_id"])
      |> call()
      |> expect_json(200)

    assert saved["allowed_template_ids"] == [first_id]

    visible = :get |> conn(model_path) |> user_auth(user_token) |> call() |> expect_json(200)
    assert Enum.any?(visible["available_models"], &(&1["template_id"] == first_id))
    assert Enum.any?(visible["available_models"], &(&1["template_id"] == private["template_id"]))
    refute Enum.any?(visible["available_models"], &(&1["template_id"] == second_id))
    assert visible["agents"]["router"]["template_id"] == second_id
    assert visible["worker_default_template_id"] == second_id

    assert {:ok, ^second_id} =
             SalixAgent.AgentDefaults.creation_template("worker", workspace["salix_tenant_id"])

    :put
    |> json_conn(model_path <> "/worker", %{"template_id" => second_id})
    |> user_auth(user_token)
    |> call()
    |> expect_json(403)

    :put
    |> json_conn(model_path <> "/worker-default", %{"template_id" => second_id})
    |> user_auth(user_token)
    |> call()
    |> expect_json(403)

    :put
    |> json_conn("/v1/comma/admin/users/#{login["user"]["id"]}/workspaces/agent-models/worker", %{
      "template_id" => second_id,
      "reason" => "Support existing workspace model",
      "confirmation" => "workspace-agent-model:#{login["user"]["id"]}:worker:#{second_id}",
      "idempotency_key" => "model-policy-support-1"
    })
    |> cookie_auth(admin_token, @admin_origin, admin_session["session_id"])
    |> call()
    |> expect_json(200)

    :put
    |> json_conn(model_path <> "/worker", %{"template_id" => private["template_id"]})
    |> user_auth(user_token)
    |> call()
    |> expect_json(200)

    :put
    |> json_conn(model_path <> "/worker", %{"template_id" => nil})
    |> user_auth(user_token)
    |> call()
    |> expect_json(200)

    :put
    |> json_conn(policy_path, Map.put(attrs, "idempotency_key", "model-policy-stale"))
    |> cookie_auth(admin_token, @admin_origin, admin_session["session_id"])
    |> call()
    |> expect_json(409)

    audit =
      Repo.one!(
        from(event in Comma.Admin.AuditEvent,
          where: event.idempotency_key == "model-policy-select-1"
        )
      )

    assert audit.evidence["before"]["mode"] == "all"
    assert audit.evidence["after"]["allowed_template_ids"] == [first_id]

    empty =
      attrs
      |> Map.put("allowed_template_ids", [])
      |> Map.put("revision", saved["revision"])
      |> Map.put("idempotency_key", "model-policy-empty-1")

    :put
    |> json_conn(policy_path, empty)
    |> cookie_auth(admin_token, @admin_origin, admin_session["session_id"])
    |> call()
    |> expect_json(200)

    after_empty = :get |> conn(model_path) |> user_auth(user_token) |> call() |> expect_json(200)
    refute Enum.any?(after_empty["available_models"], &(&1["scope"] == "global"))

    assert Enum.any?(
             after_empty["available_models"],
             &(&1["template_id"] == private["template_id"])
           )

    :put
    |> json_conn(model_path <> "/worker", %{"template_id" => first_id})
    |> user_auth(user_token)
    |> call()
    |> expect_json(403)
  end

  test "Admin free Router policy exempts only main calls and preserves an admitted decision" do
    {browser_session, token} = browser_cookie_login!("router-policy@comma.surf", @admin_origin)
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "router-policy-target@example.com"})
    workspace = create_ready_workspace!(user)
    account_id = workspace["billing_account_id"] || "comma-ba-#{workspace["id"]}"

    assert :ok =
             BillingCore.Accounts.ensure_account(%{
               billing_account_id: account_id,
               surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: workspace["id"]
             })

    path = "/v1/comma/admin/billing/free-router-models"

    initial =
      :get
      |> conn(path)
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
      |> expect_json(200)

    attrs = %{
      "models" => [
        %{"provider" => "OpenAI", "sku" => "gpt-5.6"},
        %{"provider" => "openai", "sku" => "unpriced-router"}
      ],
      "revision" => initial["revision"],
      "reason" => "Free Router rollout",
      "confirmation" => "update-free-router-models:comma",
      "idempotency_key" => "router-policy-add-1"
    }

    {ordinary, ordinary_token} =
      browser_cookie_login!("router-policy-member@example.com", @admin_origin)

    :put
    |> json_conn(path, attrs)
    |> cookie_auth(ordinary_token, @admin_origin, ordinary["session_id"])
    |> call()
    |> expect_json(403)

    oversized =
      Map.merge(attrs, %{
        "models" => List.duplicate(%{"provider" => "openai", "sku" => "gpt-5.6"}, 101),
        "idempotency_key" => "router-policy-invalid"
      })

    :put
    |> json_conn(path, oversized)
    |> cookie_auth(token, @admin_origin, browser_session["session_id"])
    |> call()
    |> expect_json(400)

    saved =
      :put
      |> json_conn(path, attrs)
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
      |> expect_json(200)

    assert saved["models"] == [
             %{"provider" => "openai", "sku" => "gpt-5.6-sol"},
             %{"provider" => "openai", "sku" => "unpriced-router"}
           ]

    assert %{"error" => "billing_policy_conflict"} =
             :put
             |> json_conn(path, Map.put(attrs, "idempotency_key", "router-policy-stale"))
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(409)

    audit =
      Repo.one!(
        from(event in Comma.Admin.AuditEvent,
          where: event.idempotency_key == "router-policy-add-1"
        )
      )

    assert audit.evidence["before"] == initial["models"]
    assert audit.evidence["after"] == saved["models"]

    assert {:ok, _} =
             SalixAgent.Templates.create(%{
               "template_id" => "free-router-test",
               "name" => "Free Router",
               "model" => "gpt-5.6-sol",
               "provider" => "openai"
             })

    assert {:ok, _} =
             SalixAgent.Control.configure(
               workspace["router_agent_id"],
               %{"template_id" => "free-router-test"},
               workspace["salix_tenant_id"]
             )

    billing = %{
      "surface" => "comma",
      "product_owner_type" => "workspace",
      "product_owner_id" => workspace["id"],
      "billing_account_id" => account_id,
      "salix_agent_id" => workspace["router_agent_id"],
      "salix_tenant_id" => workspace["salix_tenant_id"]
    }

    conversation = %{"id" => "router-policy-chat", "internal" => %{"billing_context" => billing}}

    assert {:ok, _} =
             Comma.AgentPolicies.authorize_send(workspace, conversation, %{}, %{
               "client_request_id" => "free-message"
             })

    fact = %{
      model_purpose: :agent_main,
      model: "gpt-5.6",
      provider: "openai",
      billing_context: billing,
      salix_agent_id: workspace["router_agent_id"],
      tenant_id: workspace["salix_tenant_id"],
      estimated_credits: 1,
      source_key: "free-router-call",
      usage: %{prompt_tokens: 10},
      metered_at: DateTime.utc_now()
    }

    assert {:ok, %{billing_exemption: "free_router_model"}} =
             decision = BillingCore.LLMMetering.before_llm_call(fact)

    for other <- [
          Map.put(fact, :salix_agent_id, workspace["default_worker_agent_id"]),
          Map.put(fact, :model_purpose, :tool),
          Map.put(fact, :tenant_id, "foreign"),
          Map.put(fact, :model, "gpt-5.4"),
          Map.put(fact, :provider, "other")
        ] do
      assert {:error, {:billing_unavailable, _}} = BillingCore.LLMMetering.before_llm_call(other)
    end

    unpriced = fact |> Map.put(:model, "unpriced-router") |> Map.put(:source_key, "free-unpriced")

    assert {:ok, %{billing_exemption: "free_router_model"}} =
             unpriced_decision = BillingCore.LLMMetering.before_llm_call(unpriced)

    unpriced = SalixAgent.LLMMetering.capture_decision(unpriced, unpriced_decision)

    assert :ok =
             BillingCore.LLMMetering.deliver(
               BillingCore.LLMMetering.usage_row(unpriced),
               Map.put(unpriced, :typed_sink, SalixAnalytics.Sink.Noop)
             )

    captured = SalixAgent.LLMMetering.capture_decision(fact, decision)

    removed =
      Map.merge(attrs, %{
        "models" => [],
        "revision" => saved["revision"],
        "idempotency_key" => "router-policy-remove"
      })

    :put
    |> json_conn(path, removed)
    |> cookie_auth(token, @admin_origin, browser_session["session_id"])
    |> call()
    |> expect_json(200)

    assert {:error, {:billing_unavailable, _}} = BillingCore.LLMMetering.before_llm_call(fact)
    row = BillingCore.LLMMetering.usage_row(captured)
    assert row["charge_status"] == "free_router_model"

    assert :ok =
             BillingCore.LLMMetering.deliver(
               row,
               Map.put(captured, :typed_sink, SalixAnalytics.Sink.Noop)
             )

    assert %{rows: [[0]]} =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT count(*) FROM credit_ledger WHERE billing_account_id = $1",
               [account_id]
             )

    assert %{rows: [[0]]} =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT count(*) FROM pending_meter_charges WHERE billing_account_id = $1",
               [account_id]
             )

    # The same model on a Worker uses the normal ledger after credits are issued.
    assert {:ok, _} =
             BillingCore.Credits.issue_grant(%{
               repo: BillingCore.Repo,
               billing_account_id: account_id,
               credits: 1000,
               valid_from: DateTime.add(fact.metered_at, -60),
               expires_at: DateTime.add(fact.metered_at, 3600),
               source_type: "manual_contract",
               source_id: "router-test",
               source_event_id: "router-test",
               idempotency_key: "router-test"
             })

    worker =
      fact
      |> Map.put(:salix_agent_id, workspace["default_worker_agent_id"])
      |> Map.put(:source_key, "worker-paid")
      |> Map.put(:typed_sink, SalixAnalytics.Sink.Noop)

    assert {:ok, _} = BillingCore.LLMMetering.before_llm_call(worker)

    assert {:ok, charge} =
             BillingCore.LLMMetering.deliver(BillingCore.LLMMetering.usage_row(worker), worker)

    assert charge.charged_credits == 50
  end

  test "Admin projects and independently updates the effective Workspace Router and Worker models" do
    {browser_session, token} =
      browser_cookie_login!("workspace-model-operator@comma.surf", @admin_origin)

    actor_user_id = browser_session["user"]["id"]

    {:ok, target_user} =
      Comma.Accounts.create_user(%{
        "email" => "workspace-model-target-#{System.unique_integer([:positive])}@example.com"
      })

    workspace = create_ready_workspace!(target_user)
    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]
    worker_agent_id = workspace["default_worker_agent_id"]
    rotated_router_id = SalixStore.Ids.new_agent_id(group_id)

    templates = [
      %{
        "template_id" => "admin-router-initial",
        "name" => "Router Initial",
        "model" => "gpt-router-initial",
        "provider" => "openai",
        "provider_config" => %{
          "api_key" => "router-secret-must-not-cross",
          "base_url" => "https://models.example/v1"
        },
        "request_headers" => %{"x-private" => "must-not-cross"}
      },
      %{
        "template_id" => "admin-worker-initial",
        "name" => "Worker Initial",
        "model" => "gpt-worker-initial",
        "provider" => "openai"
      },
      %{
        "template_id" => "admin-router-next",
        "name" => "Router Next",
        "model" => "gpt-router-next",
        "provider" => "openai"
      },
      %{
        "template_id" => "admin-worker-next",
        "name" => "Worker Next",
        "model" => "gpt-worker-next",
        "provider" => "openai"
      },
      %{
        "template_id" => "admin-hidden-model",
        "name" => "Hidden Model",
        "model" => "hidden-model",
        "provider" => "openai",
        "hidden" => true
      }
    ]

    for template <- templates do
      assert {:ok, _created} = SalixAgent.Templates.create(template)
    end

    assert {:ok, _worker} =
             SalixAgent.Control.configure(
               worker_agent_id,
               %{"template_id" => "admin-worker-initial"},
               tenant_id
             )

    assert {:ok, _router} =
             SalixAgent.Control.create_preallocated(
               %{
                 "group_id" => group_id,
                 "name" => "Rotated Workspace Router",
                 "role" => "router",
                 "purpose" => "workspace_model_admin_test",
                 "template_id" => "admin-router-initial"
               },
               tenant_id,
               rotated_router_id
             )

    assert {:ok, _group} =
             Salix.Control.Groups.update(
               group_id,
               %{"router_agent_id" => rotated_router_id},
               tenant_id
             )

    path = "/v1/comma/admin/users/#{target_user["id"]}/workspaces/agent-models"

    read_conn =
      :get
      |> conn(path)
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()

    assert %{
             "workspace_id" => workspace_id,
             "agents" => %{
               "router" => %{
                 "agent_id" => ^rotated_router_id,
                 "role" => "router",
                 "template_id" => "admin-router-initial",
                 "template_name" => "Router Initial",
                 "model" => "gpt-router-initial",
                 "provider" => "openai"
               },
               "worker" => %{
                 "agent_id" => ^worker_agent_id,
                 "role" => "worker",
                 "template_id" => "admin-worker-initial",
                 "template_name" => "Worker Initial",
                 "model" => "gpt-worker-initial",
                 "provider" => "openai"
               }
             },
             "available_models" => available_models
           } = expect_json(read_conn, 200)

    assert workspace_id == workspace["id"]
    assert get_resp_header(read_conn, "cache-control") == ["no-store"]

    assert Enum.any?(
             available_models,
             &(&1["template_id"] == "admin-router-next" and
                 &1["model"] == "gpt-router-next")
           )

    refute Enum.any?(available_models, &(&1["template_id"] == "admin-hidden-model"))
    refute read_conn.resp_body =~ "router-secret-must-not-cross"
    refute read_conn.resp_body =~ "provider_config"
    refute read_conn.resp_body =~ "request_headers"
    refute read_conn.resp_body =~ tenant_id
    refute read_conn.resp_body =~ group_id

    for {role, template_id, expected_agent_id, expected_model} <- [
          {"router", "admin-router-next", rotated_router_id, "gpt-router-next"},
          {"worker", "admin-worker-next", worker_agent_id, "gpt-worker-next"}
        ] do
      body = %{
        "template_id" => template_id,
        "reason" => "Move the Workspace #{role} to the approved model",
        "idempotency_key" => "workspace-model-#{role}-#{Ecto.UUID.generate()}",
        "confirmation" => "workspace-agent-model:#{target_user["id"]}:#{role}:#{template_id}"
      }

      assert %{
               "agent_id" => ^expected_agent_id,
               "role" => ^role,
               "template_id" => ^template_id,
               "model" => ^expected_model
             } =
               :put
               |> json_conn("#{path}/#{role}", body)
               |> cookie_auth(token, @admin_origin, browser_session["session_id"])
               |> call()
               |> expect_json(200)

      # The Router pins its choice; the Worker choice is the workspace Worker
      # default that the default Worker follows. Both resolve to the choice.
      assert {:ok, record} = SalixAgent.Control.get(expected_agent_id, tenant_id)

      assert {:ok, %{"template_id" => ^template_id}, _source} =
               SalixAgent.Templates.resolve_template_for_record(record)
    end

    assert %{
             "agents" => %{
               "router" => %{"model" => "gpt-router-next"},
               "worker" => %{"model" => "gpt-worker-next"}
             }
           } =
             :get
             |> conn(path)
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(200)

    assert Repo.aggregate(
             from(event in Comma.Admin.AuditEvent,
               where:
                 event.actor_key == ^actor_user_id and
                   event.action == "update_workspace_agent_model" and
                   event.target_type == "user_workspace" and
                   event.target_id == ^target_user["id"] and
                   event.outcome == "succeeded"
             ),
             :count,
             :id
           ) == 2

    assert %{"error" => "invalid_model_template"} =
             :put
             |> json_conn("#{path}/worker", %{
               "template_id" => "admin-hidden-model",
               "reason" => "Verify hidden model rejection",
               "idempotency_key" => "workspace-model-hidden-#{Ecto.UUID.generate()}",
               "confirmation" =>
                 "workspace-agent-model:#{target_user["id"]}:worker:admin-hidden-model"
             })
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(400)

    assert {:ok, worker_record} = SalixAgent.Control.get(worker_agent_id, tenant_id)

    assert {:ok, %{"template_id" => "admin-worker-next"}, _source} =
             SalixAgent.Templates.resolve_template_for_record(worker_record)

    assert %{"error" => "invalid_workspace_agent_role"} =
             :put
             |> json_conn("#{path}/coordinator", %{
               "template_id" => "admin-router-next",
               "reason" => "Verify unknown role rejection",
               "idempotency_key" => "workspace-model-role-#{Ecto.UUID.generate()}",
               "confirmation" =>
                 "workspace-agent-model:#{target_user["id"]}:coordinator:admin-router-next"
             })
             |> cookie_auth(token, @admin_origin, browser_session["session_id"])
             |> call()
             |> expect_json(400)

    assert %{"error" => "unauthorized"} =
             :get
             |> conn(path)
             |> user_auth(token)
             |> call()
             |> expect_json(401)

    assert {:ok, private} =
             SalixAgent.Templates.create_private(
               %{
                 "name" => "Workspace private",
                 "model" => "gpt-workspace-private",
                 "provider" => "openai",
                 "provider_config" => %{"api_key" => "workspace-private-secret"}
               },
               tenant_id
             )

    assert {:ok, foreign} =
             SalixAgent.Templates.create_private(
               %{
                 "name" => "Other workspace private",
                 "model" => "gpt-foreign",
                 "provider" => "openai"
               },
               SalixStore.Ids.new_tenant_id()
             )

    private_read =
      :get
      |> conn(path)
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()

    private_models = expect_json(private_read, 200)["available_models"]
    assert Enum.any?(private_models, &(&1["template_id"] == private["template_id"]))
    refute Enum.any?(private_models, &(&1["template_id"] == foreign["template_id"]))
    refute private_read.resp_body =~ "workspace-private-secret"

    for {template, status} <- [{private, 200}, {foreign, 400}] do
      private_id = template["template_id"]

      response =
        :put
        |> json_conn("#{path}/worker", %{
          "template_id" => private_id,
          "reason" => "Verify tenant-owned template selection",
          "idempotency_key" => "private-model-#{Ecto.UUID.generate()}",
          "confirmation" => "workspace-agent-model:#{target_user["id"]}:worker:#{private_id}"
        })
        |> cookie_auth(token, @admin_origin, browser_session["session_id"])
        |> call()

      expect_json(response, status)
    end

    assert {:ok, worker} = SalixAgent.Control.get(worker_agent_id, tenant_id)
    private_id = private["template_id"]

    assert {:ok, %{"template_id" => ^private_id}, _source} =
             SalixAgent.Templates.resolve_template_for_record(worker)

    assert {:ok, llm} = SalixAgent.Templates.resolve_llm_for_agent(worker_agent_id)
    assert llm["api_key"] == "workspace-private-secret"

    followed =
      :put
      |> json_conn("#{path}/worker", %{
        "template_id" => nil,
        "reason" => "Follow the platform Worker model",
        "idempotency_key" => Ecto.UUID.generate(),
        "confirmation" => "workspace-agent-model:#{target_user["id"]}:worker:default"
      })
      |> cookie_auth(token, @admin_origin, browser_session["session_id"])
      |> call()
      |> expect_json(200)

    assert followed["source"] == "platform_default"
    assert {:ok, cleared} = SalixAgent.Control.get(worker_agent_id, tenant_id)
    assert cleared["template_id"] == nil
  end

  test "human Admin pagination is session-bound and preserves Session mismatch semantics" do
    {browser_session, token} = browser_cookie_login!("pagination@comma.surf", @admin_origin)
    session_id = browser_session["session_id"]

    for email <- ["pagination-a@example.com", "pagination-b@example.com"] do
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => email})
      |> admin_auth()
      |> call()
      |> expect_json(201)
    end

    first =
      :get
      |> conn("/v1/comma/admin/users?limit=1")
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(200)

    assert first["has_more"] == true
    assert is_binary(first["next_cursor"])
    assert [first_user] = first["data"]

    second =
      :get
      |> conn("/v1/comma/admin/users?limit=1&cursor=#{URI.encode_www_form(first["next_cursor"])}")
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(200)

    assert [second_user] = second["data"]
    refute first_user["id"] == second_user["id"]

    ops_page =
      :get
      |> conn("/v1/comma/admin/users?limit=1")
      |> admin_auth()
      |> call()
      |> expect_json(200)

    assert %{"error" => "invalid_cursor"} =
             :get
             |> conn(
               "/v1/comma/admin/users?limit=1&cursor=#{URI.encode_www_form(ops_page["next_cursor"])}"
             )
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(400)

    assert %{"error" => "session_changed"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> cookie_auth(token, @admin_origin, Ecto.UUID.generate())
             |> call()
             |> expect_json(409)
  end

  test "human Admin billing commands use a typed boundary and server operator identity" do
    package_code = "comma_admin_#{System.unique_integer([:positive])}"
    package_version = "2026-07"

    seed_billing_package!(
      package_code,
      package_version,
      "comma",
      "one_time",
      "Admin test package"
    )

    {browser_session, token} =
      browser_cookie_login!("billing-operator@comma.surf", @admin_origin)

    session_id = browser_session["session_id"]
    actor_id = browser_session["user"]["id"]
    create_key = "human-code-#{Ecto.UUID.generate()}"
    short_code_key = "human-short-code-#{Ecto.UUID.generate()}"

    assert %{"error" => "invalid_redeem_code"} =
             :post
             |> json_conn("/v1/comma/admin/billing/redeem-codes", %{
               "code" => "free",
               "package_code" => package_code,
               "package_version" => package_version,
               "reason" => "Reject a code that cannot be safely redacted",
               "idempotency_key" => short_code_key,
               "confirmation" => "create-redeem-code:#{package_code}:#{package_version}"
             })
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(400)

    refute Repo.get_by(Comma.Admin.AuditEvent,
             actor_key: actor_id,
             action: "create_redeem_code",
             idempotency_key: short_code_key
           )

    assert %{"data" => []} =
             :get
             |> conn("/v1/comma/admin/billing/redeem-codes")
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(200)

    create_body = %{
      "code" => "comma-human-code-#{System.unique_integer([:positive])}",
      "package_code" => package_code,
      "package_version" => package_version,
      "max_redemptions" => 5,
      "reason" => "Issue a support redemption",
      "idempotency_key" => create_key,
      "confirmation" => "create-redeem-code:#{package_code}:#{package_version}"
    }

    for forbidden <- [
          %{"admin_command_id" => Ecto.UUID.generate()},
          %{"metadata" => %{"injected" => true}},
          %{"status" => "disabled"},
          %{"surface" => "bridge"}
        ] do
      assert %{"error" => "invalid_redeem_code"} =
               :post
               |> json_conn(
                 "/v1/comma/admin/billing/redeem-codes",
                 Map.merge(create_body, forbidden)
               )
               |> cookie_auth(token, @admin_origin, session_id)
               |> call()
               |> expect_json(400)
    end

    refute Repo.get_by(Comma.Admin.AuditEvent,
             actor_key: actor_id,
             action: "create_redeem_code",
             idempotency_key: create_key
           )

    create_conn =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes", create_body)
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()

    code = expect_json(create_conn, 201)
    assert is_binary(code["code"])
    assert get_resp_header(create_conn, "cache-control") == ["no-store"]

    assert %{"error" => "admin_command_already_succeeded"} =
             :post
             |> json_conn("/v1/comma/admin/billing/redeem-codes", create_body)
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(409)

    assert %{"error" => "admin_command_already_succeeded"} =
             :post
             |> json_conn(
               "/v1/comma/admin/billing/redeem-codes",
               Map.put(create_body, "code", "  #{String.upcase(create_body["code"])}  ")
             )
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(409)

    assert %{"error" => "admin_idempotency_key_conflict"} =
             :post
             |> json_conn(
               "/v1/comma/admin/billing/redeem-codes",
               Map.put(create_body, "code", create_body["code"] <> "-changed")
             )
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(409)

    billing_account_id = "comma-ba-admin-#{System.unique_integer([:positive])}"
    owner_id = "wsp_admin_#{System.unique_integer([:positive])}"
    apply_key = "human-apply-#{Ecto.UUID.generate()}"

    apply_body = %{
      "id" => code["id"],
      "billing_account_id" => billing_account_id,
      "product_owner_type" => "workspace",
      "product_owner_id" => owner_id,
      "idempotency_key" => apply_key,
      "reason" => "Apply the approved support redemption",
      "confirmation" => "apply-redeem-code:#{billing_account_id}"
    }

    assert %{"error" => "invalid_redeem_request"} =
             :post
             |> json_conn(
               "/v1/comma/admin/billing/redeem-codes/apply",
               Map.merge(apply_body, %{
                 "operator" => %{"id" => "spoofed-client-operator"},
                 "surface" => "bridge"
               })
             )
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(400)

    refute Repo.get_by(Comma.Admin.AuditEvent,
             actor_key: actor_id,
             action: "apply_redeem_code",
             idempotency_key: apply_key
           )

    applied =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes/apply", apply_body)
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(201)

    assert applied["redemption"]["operator_snapshot"]["id"] == actor_id
    assert applied["redemption"]["operator_snapshot"]["type"] == "comma_admin_user"

    disabled =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes/#{code["id"]}/disable", %{
        "reason" => "Retire the completed support code",
        "idempotency_key" => "human-disable-#{Ecto.UUID.generate()}",
        "confirmation" => "disable-redeem-code:#{code["id"]}"
      })
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(200)

    assert disabled["status"] == "disabled"

    assert Repo.exists?(
             from(event in Comma.Admin.AuditEvent,
               where:
                 event.actor_key == ^actor_id and
                   event.action == "apply_redeem_code" and
                   event.idempotency_key == ^apply_key and
                   event.outcome == "succeeded"
             )
           )
  end

  test "human Admin issues package-backed credits only to the server-owned Workspace target" do
    package_code = "comma_admin_grant_#{System.unique_integer([:positive])}"
    package_version = "2026-07"

    seed_billing_package!(
      package_code,
      package_version,
      "comma",
      "one_time",
      "Admin direct credit package"
    )

    {:ok, target_user} =
      Comma.Accounts.create_user(%{
        "email" => "billing-grant-target-#{System.unique_integer([:positive])}@example.com"
      })

    workspace = create_ready_workspace!(target_user["id"], "Grant Target")
    workspace_id = workspace["id"]
    billing_account_id = workspace["billing_account_id"]

    {browser_session, token} =
      browser_cookie_login!("billing-grant-operator@comma.surf", @admin_origin)

    session_id = browser_session["session_id"]
    actor_id = browser_session["user"]["id"]
    idempotency_key = "human-grant-#{Ecto.UUID.generate()}"

    body = %{
      "package_code" => package_code,
      "package_version" => package_version,
      "expires_at" => "2099-08-01T00:00:00Z",
      "reason" => "Issue an approved Workspace support grant",
      "idempotency_key" => idempotency_key,
      "confirmation" =>
        "issue-workspace-credits:#{workspace_id}:#{package_code}:#{package_version}"
    }

    assert %{"error" => "forbidden"} =
             :post
             |> json_conn(
               "/v1/comma/admin/users/#{target_user["id"]}/workspace-credits",
               body
             )
             |> admin_auth()
             |> call()
             |> expect_json(403)

    assert %{"error" => "invalid_manual_grant"} =
             :post
             |> json_conn(
               "/v1/comma/admin/users/#{target_user["id"]}/workspace-credits",
               Map.merge(body, %{
                 "billing_account_id" => "comma-ba-spoofed",
                 "workspace_id" => "wsp_spoofed",
                 "operator" => %{"id" => "usr_spoofed"},
                 "source_type" => "manual_contract",
                 "valid_from" => "2026-07-01T00:00:00Z"
               })
             )
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(400)

    refute Repo.get_by(Comma.Admin.AuditEvent,
             actor_key: actor_id,
             action: "issue_workspace_credits",
             idempotency_key: idempotency_key
           )

    result =
      :post
      |> json_conn(
        "/v1/comma/admin/users/#{target_user["id"]}/workspace-credits",
        body
      )
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(201)

    assert result["idempotent"] == false
    assert result["grant"]["billing_account_id"] == billing_account_id
    assert result["grant"]["remaining_credits"] == 100
    assert result["manual_grant"]["package_code"] == package_code
    assert result["manual_grant"]["package_version"] == package_version
    assert result["manual_grant"]["source_type"] == "manual_adjustment"
    assert result["manual_grant"]["source_id"] == "comma_admin:#{workspace_id}"
    assert result["manual_grant"]["operator_snapshot"]["id"] == actor_id
    assert result["manual_grant"]["operator_snapshot"]["type"] == "comma_admin_user"

    audit =
      Repo.get_by!(Comma.Admin.AuditEvent,
        actor_key: actor_id,
        action: "issue_workspace_credits",
        idempotency_key: idempotency_key
      )

    assert audit.outcome == "succeeded"
    assert audit.target_type == "workspace"
    assert audit.target_id == workspace_id
    assert result["manual_grant"]["source_event_id"] == audit.id

    billing_idempotency_key =
      BillingCommerce.ManualGrantCommands.billing_idempotency_key(audit.id)

    assert result["manual_grant"]["idempotency_key"] == nil

    assert %{
             "workspace" => %{"id" => ^workspace_id},
             "billing" => %{
               "account_id" => ^billing_account_id,
               "current_credits" => 100,
               "active_grants" => [
                 %{
                   "source_type" => "manual_adjustment",
                   "source_id" => "comma_admin:" <> ^workspace_id
                 }
               ]
             }
           } =
             :get
             |> conn("/v1/comma/admin/users/#{target_user["id"]}/workspaces")
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(200)

    assert %{"error" => "admin_command_already_succeeded"} =
             :post
             |> json_conn(
               "/v1/comma/admin/users/#{target_user["id"]}/workspace-credits",
               body
             )
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(409)

    assert [[1]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               """
               SELECT count(*)
               FROM billing_manual_grants
               WHERE billing_account_id = $1 AND idempotency_key = $2
               """,
               [billing_account_id, billing_idempotency_key]
             ).rows

    assert [[0]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               """
               SELECT count(*)
               FROM billing_manual_grants
               WHERE billing_account_id = $1 AND idempotency_key = $2
               """,
               [billing_account_id, idempotency_key]
             ).rows
  end

  test "human direct grant recovers the committed owner result after its package is retired" do
    package_code = "comma_admin_recovery_#{System.unique_integer([:positive])}"
    package_version = "2026-07"

    seed_billing_package!(
      package_code,
      package_version,
      "comma",
      "one_time",
      "Admin direct grant recovery package"
    )

    {:ok, target_user} =
      Comma.Accounts.create_user(%{
        "email" => "billing-grant-recovery-#{System.unique_integer([:positive])}@example.com"
      })

    workspace = create_ready_workspace!(target_user["id"], "Grant Recovery Target")
    workspace_id = workspace["id"]
    billing_account_id = workspace["billing_account_id"]

    {browser_session, token} =
      browser_cookie_login!("billing-grant-recovery@comma.surf", @admin_origin)

    session_id = browser_session["session_id"]
    actor_id = browser_session["user"]["id"]
    browser_key = "human-grant-recovery-#{Ecto.UUID.generate()}"
    expires_at = DateTime.utc_now() |> DateTime.add(3, :second) |> DateTime.truncate(:second)

    body = %{
      "package_code" => package_code,
      "package_version" => package_version,
      "expires_at" => DateTime.to_iso8601(expires_at),
      "reason" => "Recover a committed direct grant after audit finalization loss",
      "idempotency_key" => browser_key,
      "confirmation" =>
        "issue-workspace-credits:#{workspace_id}:#{package_code}:#{package_version}"
    }

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE OR REPLACE FUNCTION pg_temp.fail_comma_admin_grant_audit_finalize()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NEW.outcome = 'succeeded' THEN
          RAISE EXCEPTION 'forced direct-grant audit finalize failure';
        END IF;
        RETURN NEW;
      END;
      $$
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER comma_admin_grant_audit_finalize_failure
      BEFORE UPDATE OF outcome ON comma_admin_audit_events
      FOR EACH ROW
      EXECUTE FUNCTION pg_temp.fail_comma_admin_grant_audit_finalize()
      """,
      []
    )

    first =
      :post
      |> json_conn(
        "/v1/comma/admin/users/#{target_user["id"]}/workspace-credits",
        body
      )
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(201)

    event =
      Repo.get_by!(Comma.Admin.AuditEvent,
        actor_key: actor_id,
        action: "issue_workspace_credits",
        idempotency_key: browser_key
      )

    assert event.outcome == "started"
    assert first["idempotent"] == false
    manual_grant_id = first["manual_grant"]["id"]

    Ecto.Adapters.SQL.query!(
      Repo,
      "DROP TRIGGER comma_admin_grant_audit_finalize_failure ON comma_admin_audit_events",
      []
    )

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      UPDATE billing_package_versions
      SET status = 'inactive'
      WHERE package_code = $1 AND version = $2
      """,
      [package_code, package_version]
    )

    wait_ms = max(DateTime.diff(expires_at, DateTime.utc_now(), :millisecond) + 100, 0)
    Process.sleep(wait_ms)
    assert DateTime.compare(DateTime.utc_now(), expires_at) in [:eq, :gt]

    Repo.update_all(
      from(candidate in Comma.Admin.AuditEvent, where: candidate.id == ^event.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    recovered =
      :post
      |> json_conn(
        "/v1/comma/admin/users/#{target_user["id"]}/workspace-credits",
        body
      )
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(201)

    assert recovered["idempotent"] == true
    assert recovered["manual_grant"]["id"] == manual_grant_id
    assert recovered["grant"] == nil

    recovered_event = Repo.get!(Comma.Admin.AuditEvent, event.id)
    assert recovered_event.outcome == "succeeded"
    assert is_nil(recovered_event.lease_expires_at)

    billing_key = BillingCommerce.ManualGrantCommands.billing_idempotency_key(event.id)

    assert [[1]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               """
               SELECT count(*)
               FROM billing_manual_grants
               WHERE billing_account_id = $1
                 AND idempotency_key = $2
                 AND source_event_id = $3
               """,
               [billing_account_id, billing_key, event.id]
             ).rows

    assert [[1]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               """
               SELECT count(*)
               FROM credit_grants
               WHERE billing_account_id = $1 AND idempotency_key = $2
               """,
               [billing_account_id, billing_key]
             ).rows
  end

  test "different human Admin commands cannot collide through a reused browser key" do
    first_package = "comma_admin_first_#{System.unique_integer([:positive])}"
    second_package = "comma_admin_second_#{System.unique_integer([:positive])}"
    package_version = "2026-07"

    seed_billing_package!(
      first_package,
      package_version,
      "comma",
      "one_time",
      "First Admin direct credit package",
      100
    )

    seed_billing_package!(
      second_package,
      package_version,
      "comma",
      "one_time",
      "Second Admin direct credit package",
      900
    )

    {:ok, target_user} =
      Comma.Accounts.create_user(%{
        "email" => "billing-key-target-#{System.unique_integer([:positive])}@example.com"
      })

    workspace = create_ready_workspace!(target_user["id"], "Idempotency Target")
    workspace_id = workspace["id"]
    billing_account_id = workspace["billing_account_id"]
    browser_key = "shared-browser-key-#{Ecto.UUID.generate()}"

    {first_session, first_token} =
      browser_cookie_login!("billing-key-first@comma.surf", @admin_origin)

    {second_session, second_token} =
      browser_cookie_login!("billing-key-second@comma.surf", @admin_origin)

    issue = fn session, token, package_code, reason ->
      :post
      |> json_conn(
        "/v1/comma/admin/users/#{target_user["id"]}/workspace-credits",
        %{
          "package_code" => package_code,
          "package_version" => package_version,
          "expires_at" => "2099-08-01T00:00:00Z",
          "reason" => reason,
          "idempotency_key" => browser_key,
          "confirmation" =>
            "issue-workspace-credits:#{workspace_id}:#{package_code}:#{package_version}"
        }
      )
      |> cookie_auth(token, @admin_origin, session["session_id"])
      |> call()
      |> expect_json(201)
    end

    first =
      issue.(
        first_session,
        first_token,
        first_package,
        "Issue the first approved direct grant"
      )

    second =
      issue.(
        second_session,
        second_token,
        second_package,
        "Issue the second approved direct grant"
      )

    assert first["idempotent"] == false
    assert first["grant"]["remaining_credits"] == 100
    assert second["idempotent"] == false
    assert second["grant"]["remaining_credits"] == 900

    first_actor_id = first_session["user"]["id"]
    second_actor_id = second_session["user"]["id"]

    first_audit =
      Repo.get_by!(Comma.Admin.AuditEvent,
        actor_key: first_actor_id,
        action: "issue_workspace_credits",
        idempotency_key: browser_key
      )

    second_audit =
      Repo.get_by!(Comma.Admin.AuditEvent,
        actor_key: second_actor_id,
        action: "issue_workspace_credits",
        idempotency_key: browser_key
      )

    refute first_audit.id == second_audit.id

    expected_billing_keys =
      MapSet.new([
        BillingCommerce.ManualGrantCommands.billing_idempotency_key(first_audit.id),
        BillingCommerce.ManualGrantCommands.billing_idempotency_key(second_audit.id)
      ])

    rows =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT package_code, idempotency_key, source_event_id
        FROM billing_manual_grants
        WHERE billing_account_id = $1
        ORDER BY package_code
        """,
        [billing_account_id]
      ).rows

    assert length(rows) == 2
    assert MapSet.new(Enum.map(rows, &Enum.at(&1, 1))) == expected_billing_keys

    assert MapSet.new(Enum.map(rows, &Enum.at(&1, 2))) ==
             MapSet.new([first_audit.id, second_audit.id])

    refute Enum.any?(rows, &(Enum.at(&1, 1) == browser_key))

    assert [[balance]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               """
               SELECT COALESCE(SUM(remaining_credits), 0)
               FROM credit_grants
               WHERE billing_account_id = $1
               """,
               [billing_account_id]
             ).rows

    assert Decimal.equal?(balance, Decimal.new("1000"))
  end

  test "ops Billing compatibility is typed without narrowing legacy command fields" do
    package_code = "bridge_ops_#{System.unique_integer([:positive])}"
    package_version = "2026-07"
    organization_id = "org_ops_#{System.unique_integer([:positive])}"
    billing_account_id = "bridge-ba-#{organization_id}"
    code_id = "redeem_code_ops_#{System.unique_integer([:positive])}"
    redemption_id = "redemption_ops_#{System.unique_integer([:positive])}"
    source_event_id = "ops-source-#{Ecto.UUID.generate()}"
    admin_command_id = Ecto.UUID.generate()

    seed_billing_package!(
      package_code,
      package_version,
      "bridge",
      "subscription",
      "Ops compatibility package"
    )

    audit_count = Repo.aggregate(Comma.Admin.AuditEvent, :count)

    create_body = %{
      "id" => code_id,
      "admin_command_id" => admin_command_id,
      "code" => "bridge-ops-code-#{System.unique_integer([:positive])}",
      "package_code" => package_code,
      "package_version" => package_version,
      "code_type" => "internal_subscription",
      "surface" => "bridge",
      "scope_product_owner_type" => "organization",
      "scope_product_owner_id" => organization_id,
      "status" => "active",
      "max_redemptions" => 3,
      "per_account_limit" => 1,
      "valid_from" => "2026-07-01T00:00:00Z",
      "metadata" => %{"source" => "deployment"}
    }

    created =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes", create_body)
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert created["id"] == code_id
    assert created["surface"] == "bridge"
    assert created["scope_product_owner_id"] == organization_id
    assert created["metadata"] == %{"source" => "deployment"}

    replayed =
      :post
      |> json_conn(
        "/v1/comma/admin/billing/redeem-codes",
        Map.put(create_body, "code", "ignored-after-owner-reconciliation")
      )
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert replayed["id"] == code_id
    refute Map.has_key?(replayed, "code")

    assert [[^code_id]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT id FROM billing_redeem_codes WHERE admin_command_id = $1",
               [admin_command_id]
             ).rows

    applied =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes/apply", %{
        "id" => code_id,
        "billing_account_id" => billing_account_id,
        "surface" => "bridge",
        "product_owner_type" => "organization",
        "product_owner_id" => organization_id,
        "idempotency_key" => "ops-apply-#{Ecto.UUID.generate()}",
        "operator" => %{
          "id" => "deployment-bearer",
          "type" => "ops",
          "reason" => "Restore an organization subscription"
        },
        "redemption_id" => redemption_id,
        "source_event_id" => source_event_id,
        "metadata" => %{"ticket" => "OPS-629"}
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert applied["redemption"]["id"] == redemption_id
    assert applied["redemption"]["source_event_id"] == source_event_id
    assert applied["redemption"]["operator_snapshot"]["id"] == "deployment-bearer"
    assert applied["redemption"]["metadata"] == %{"ticket" => "OPS-629"}

    assert %{"status" => "disabled"} =
             :post
             |> json_conn("/v1/comma/admin/billing/redeem-codes/#{code_id}/disable", %{})
             |> admin_auth()
             |> call()
             |> expect_json(200)

    assert Repo.aggregate(Comma.Admin.AuditEvent, :count) == audit_count

    assert %{"error" => "invalid_redeem_code"} =
             :post
             |> json_conn("/v1/comma/admin/billing/redeem-codes", %{
               "code" => "bridge-invalid-ops-code",
               "package_code" => package_code,
               "package_version" => package_version,
               "code_type" => "internal_subscription",
               "surface" => "bridge",
               "max_redemptions" => 2_147_483_648
             })
             |> admin_auth()
             |> call()
             |> expect_json(400)
  end

  test "human Billing command survives audit-finalize failure and reclaims a stale attempt" do
    package_code = "comma_admin_recovery_#{System.unique_integer([:positive])}"
    package_version = "2026-07"

    seed_billing_package!(
      package_code,
      package_version,
      "comma",
      "one_time",
      "Admin recovery package"
    )

    {browser_session, token} =
      browser_cookie_login!("billing-recovery@comma.surf", @admin_origin)

    session_id = browser_session["session_id"]
    actor_id = browser_session["user"]["id"]
    idempotency_key = "human-recovery-#{Ecto.UUID.generate()}"

    body = %{
      "code" => "comma-recovery-#{System.unique_integer([:positive])}",
      "package_code" => package_code,
      "package_version" => package_version,
      "reason" => "Verify recoverable cross-database audit evidence",
      "idempotency_key" => idempotency_key,
      "confirmation" => "create-redeem-code:#{package_code}:#{package_version}"
    }

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE OR REPLACE FUNCTION pg_temp.fail_comma_admin_audit_finalize()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NEW.outcome = 'succeeded' THEN
          RAISE EXCEPTION 'forced admin audit finalize failure';
        END IF;
        RETURN NEW;
      END;
      $$
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER comma_admin_audit_finalize_failure
      BEFORE UPDATE OF outcome ON comma_admin_audit_events
      FOR EACH ROW
      EXECUTE FUNCTION pg_temp.fail_comma_admin_audit_finalize()
      """,
      []
    )

    first_conn =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes", body)
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()

    first_code = expect_json(first_conn, 201)
    assert is_binary(first_code["code"])

    event =
      Repo.get_by!(Comma.Admin.AuditEvent,
        actor_key: actor_id,
        action: "create_redeem_code",
        idempotency_key: idempotency_key
      )

    assert event.outcome == "started"
    assert %DateTime{} = event.lease_expires_at

    assert [[1]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT count(*) FROM billing_redeem_codes WHERE admin_command_id = $1",
               [event.id]
             ).rows

    Ecto.Adapters.SQL.query!(
      Repo,
      "DROP TRIGGER comma_admin_audit_finalize_failure ON comma_admin_audit_events",
      []
    )

    expired_at = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.update_all(
      from(candidate in Comma.Admin.AuditEvent, where: candidate.id == ^event.id),
      set: [lease_expires_at: expired_at]
    )

    recovered_code =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes", body)
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(201)

    assert recovered_code["id"] == first_code["id"]
    refute Map.has_key?(recovered_code, "code")

    recovered = Repo.get!(Comma.Admin.AuditEvent, event.id)
    assert recovered.outcome == "succeeded"
    assert is_nil(recovered.lease_expires_at)

    assert [[1]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT count(*) FROM billing_redeem_codes WHERE admin_command_id = $1",
               [event.id]
             ).rows
  end

  test "human redeem apply reconciles a committed owner result after its code is retired" do
    package_code = "comma_admin_apply_recovery_#{System.unique_integer([:positive])}"
    package_version = "2026-07"

    seed_billing_package!(
      package_code,
      package_version,
      "comma",
      "one_time",
      "Admin apply recovery package"
    )

    assert {:ok, code} =
             BillingCommerce.create_redeem_code(%{
               code: "comma-apply-recovery-#{System.unique_integer([:positive])}",
               package_code: package_code,
               package_version: package_version,
               code_type: "one_time_package",
               surface: "comma"
             })

    {browser_session, token} =
      browser_cookie_login!("billing-apply-recovery@comma.surf", @admin_origin)

    session_id = browser_session["session_id"]
    actor_id = browser_session["user"]["id"]
    billing_account_id = "comma-ba-recovery-#{System.unique_integer([:positive])}"
    owner_id = "wsp_recovery_#{System.unique_integer([:positive])}"
    idempotency_key = "human-apply-recovery-#{Ecto.UUID.generate()}"

    body = %{
      "id" => code.id,
      "billing_account_id" => billing_account_id,
      "product_owner_type" => "workspace",
      "product_owner_id" => owner_id,
      "reason" => "Recover an owner commit after the Admin response was lost",
      "idempotency_key" => idempotency_key,
      "confirmation" => "apply-redeem-code:#{billing_account_id}"
    }

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE OR REPLACE FUNCTION pg_temp.fail_comma_admin_apply_audit_finalize()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NEW.outcome = 'succeeded' THEN
          RAISE EXCEPTION 'forced admin apply audit finalize failure';
        END IF;
        RETURN NEW;
      END;
      $$
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER comma_admin_apply_audit_finalize_failure
      BEFORE UPDATE OF outcome ON comma_admin_audit_events
      FOR EACH ROW
      EXECUTE FUNCTION pg_temp.fail_comma_admin_apply_audit_finalize()
      """,
      []
    )

    first_result =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes/apply", body)
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(201)

    assert first_result["idempotent"] == false
    redemption_id = first_result["redemption"]["id"]

    event =
      Repo.get_by!(Comma.Admin.AuditEvent,
        actor_key: actor_id,
        action: "apply_redeem_code",
        idempotency_key: idempotency_key
      )

    assert event.outcome == "started"

    Ecto.Adapters.SQL.query!(
      Repo,
      "DROP TRIGGER comma_admin_apply_audit_finalize_failure ON comma_admin_audit_events",
      []
    )

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      UPDATE billing_redeem_codes
      SET status = 'disabled',
          expires_at = now() - interval '1 second'
      WHERE id = $1
      """,
      [code.id]
    )

    Repo.update_all(
      from(candidate in Comma.Admin.AuditEvent, where: candidate.id == ^event.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    recovered =
      :post
      |> json_conn("/v1/comma/admin/billing/redeem-codes/apply", body)
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(201)

    assert recovered["idempotent"] == true
    assert recovered["redemption"]["id"] == redemption_id

    recovered_event = Repo.get!(Comma.Admin.AuditEvent, event.id)
    assert recovered_event.outcome == "succeeded"
    assert is_nil(recovered_event.lease_expires_at)

    assert [[1]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               """
               SELECT count(*)
               FROM billing_redemptions
               WHERE redeem_code_id = $1 AND billing_account_id = $2
               """,
               [code.id, billing_account_id]
             ).rows
  end

  test "human Comma command rolls back its effect when audit finalization fails" do
    {browser_session, token} =
      browser_cookie_login!("comma-recovery@comma.surf", @admin_origin)

    session_id = browser_session["session_id"]
    actor_id = browser_session["user"]["id"]
    email = "comma-atomic-recovery-#{System.unique_integer([:positive])}@example.com"
    idempotency_key = "comma-atomic-recovery-#{Ecto.UUID.generate()}"

    body = %{
      "email" => email,
      "name" => "Recovered user",
      "reason" => "Verify atomic Comma effect and audit finalization",
      "idempotency_key" => idempotency_key,
      "confirmation" => "create-user:#{email}"
    }

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE OR REPLACE FUNCTION pg_temp.fail_comma_admin_audit_finalize()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NEW.outcome = 'succeeded' THEN
          RAISE EXCEPTION 'forced admin audit finalize failure';
        END IF;
        RETURN NEW;
      END;
      $$
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER comma_admin_audit_finalize_failure
      BEFORE UPDATE OF outcome ON comma_admin_audit_events
      FOR EACH ROW
      EXECUTE FUNCTION pg_temp.fail_comma_admin_audit_finalize()
      """,
      []
    )

    assert %{"error" => "admin_audit_unavailable"} =
             :post
             |> json_conn("/v1/comma/admin/users", body)
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(503)

    assert {:error, :not_found} = Comma.Accounts.get_user_by_email(email)

    event =
      Repo.get_by!(Comma.Admin.AuditEvent,
        actor_key: actor_id,
        action: "create_user",
        idempotency_key: idempotency_key
      )

    assert event.outcome == "started"

    Ecto.Adapters.SQL.query!(
      Repo,
      "DROP TRIGGER comma_admin_audit_finalize_failure ON comma_admin_audit_events",
      []
    )

    Repo.update_all(
      from(candidate in Comma.Admin.AuditEvent, where: candidate.id == ^event.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    recovered =
      :post
      |> json_conn("/v1/comma/admin/users", body)
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()
      |> expect_json(201)

    assert recovered["email"] == email
    assert {:ok, %{"id" => recovered_id}} = Comma.Accounts.get_user_by_email(email)
    assert recovered_id == recovered["id"]

    recovered_event = Repo.get!(Comma.Admin.AuditEvent, event.id)
    assert recovered_event.outcome == "succeeded"
    assert is_nil(recovered_event.lease_expires_at)
  end

  test "valid non-Admin Cookie Sessions keep lifecycle access and receive route-level 403" do
    {browser_session, token} = browser_cookie_login!("outside@example.com", @admin_origin)
    session_id = browser_session["session_id"]

    assert %{"session_id" => ^session_id} =
             :get
             |> conn("/v1/comma/auth/session")
             |> cookie_auth(token, @admin_origin, session_id)
             |> call()
             |> expect_json(200)

    denied =
      :get
      |> conn("/v1/comma/admin/users")
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()

    assert expect_json(denied, 403) == %{"error" => "forbidden"}
    assert denied.resp_cookies == %{}

    logout =
      :post
      |> json_conn("/v1/comma/auth/logout", %{})
      |> cookie_auth(token, @admin_origin, session_id)
      |> call()

    assert expect_json(logout, 200) == %{"signed_out" => true}
    assert logout.resp_cookies[CommaWeb.SessionCookie.cookie_name()].max_age == 0
  end

  test "restricted, revoked, and disabled comma.surf Sessions cannot read Admin resources" do
    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{"email" => "restricted-admin@comma.surf"})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    restricted =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{
        "restricted" => true,
        "workspace_id" => "wsp_admin_restricted"
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert %{"error" => "forbidden"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> cookie_auth(restricted["token"], @admin_origin, restricted["id"])
             |> call()
             |> expect_json(403)

    {revoked_session, revoked_token} =
      browser_cookie_login!("revoked-admin@comma.surf", @admin_origin)

    :ok = Comma.Accounts.revoke_session_token(revoked_token)

    assert %{"error" => "unauthorized"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> cookie_auth(
               revoked_token,
               @admin_origin,
               revoked_session["session_id"]
             )
             |> call()
             |> expect_json(401)

    {disabled_session, disabled_token} =
      browser_cookie_login!("disabled-admin@comma.surf", @admin_origin)

    :patch
    |> json_conn("/v1/comma/admin/users/#{disabled_session["user"]["id"]}", %{
      "status" => "disabled"
    })
    |> admin_auth()
    |> call()
    |> expect_json(200)

    assert %{"error" => "unauthorized"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> cookie_auth(
               disabled_token,
               @admin_origin,
               disabled_session["session_id"]
             )
             |> call()
             |> expect_json(401)
  end

  test "cookie mutations require an allowed Origin and reject cross-site fetch metadata" do
    for {label, email, authenticate} <- [
          {"missing Origin", "cookie-missing-origin@example.com",
           fn conn, token ->
             put_req_header(conn, "cookie", "#{CommaWeb.SessionCookie.cookie_name()}=#{token}")
           end},
          {"unapproved same-site Origin", "cookie-origin@example.com",
           &cookie_auth(&1, &2, "https://untrusted.comma.surf")}
        ] do
      session = email_login!(email)

      conn =
        :post
        |> json_conn("/v1/comma/auth/logout", %{})
        |> authenticate.(session["token"])
        |> call()

      assert conn.status == 403, label
      assert Jason.decode!(conn.resp_body)["error"] == "origin_not_allowed", label
      assert {:ok, _user, _session} = Comma.Accounts.validate_session(session["token"]), label
    end

    cross_site = email_login!("cookie-cross-site@example.com")

    conn =
      :post
      |> json_conn("/v1/comma/auth/logout", %{})
      |> cookie_auth(cross_site["token"], "http://127.0.0.1:5174")
      |> put_req_header("sec-fetch-site", "cross-site")
      |> call()

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"] == "cross_site_request"
    assert {:ok, _user, _session} = Comma.Accounts.validate_session(cross_site["token"])

    untrusted_cookie_read =
      :get
      |> conn("/v1/comma/auth/session")
      |> put_req_header(
        "cookie",
        "#{CommaWeb.SessionCookie.cookie_name()}=#{cross_site["token"]}"
      )
      |> call()

    assert untrusted_cookie_read.status == 401
    assert untrusted_cookie_read.resp_cookies == %{}
  end

  test "only coordinated current-session and logout 401 clear an invalid cookie" do
    origin = "http://127.0.0.1:5174"
    invalid_cookie = email_login!("invalid-cookie@example.com")
    :ok = Comma.Accounts.revoke_session_token(invalid_cookie["token"])

    for path <- [
          "/v1/comma/workspaces",
          "/v1/comma/groups/grp_missing/conversations/cnv_missing/events"
        ] do
      product_conn =
        :get
        |> conn(path)
        |> cookie_auth(invalid_cookie["token"], origin)
        |> call()

      assert product_conn.status == 401
      assert product_conn.resp_cookies == %{}
    end

    conn =
      :get
      |> conn("/v1/comma/auth/session")
      |> cookie_auth(invalid_cookie["token"], origin)
      |> call()

    assert conn.status == 401
    assert conn.resp_cookies[CommaWeb.SessionCookie.cookie_name()].max_age == 0
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    logout_conn =
      :post
      |> json_conn("/v1/comma/auth/logout", %{})
      |> cookie_auth(invalid_cookie["token"], origin)
      |> call()

    assert logout_conn.status == 401
    assert logout_conn.resp_cookies[CommaWeb.SessionCookie.cookie_name()].max_age == 0

    bearer_conn =
      :get
      |> conn("/v1/comma/auth/session")
      |> user_auth(invalid_cookie["token"])
      |> call()

    assert bearer_conn.status == 401
    assert bearer_conn.resp_cookies == %{}

    valid_cookie = email_login!("valid-cookie@example.com")

    admin_conn =
      :get
      |> conn("/v1/comma/admin/users")
      |> cookie_auth(valid_cookie["token"], origin)
      |> call()

    assert expect_json(admin_conn, 403) == %{"error" => "origin_path_not_allowed"}
    assert admin_conn.resp_cookies == %{}

    ambiguous_conn =
      :get
      |> conn("/v1/comma/auth/session")
      |> cookie_auth(valid_cookie["token"], origin)
      |> user_auth(valid_cookie["token"])
      |> call()

    assert ambiguous_conn.status == 401
    assert ambiguous_conn.resp_cookies == %{}
  end

  @tag database_isolation: "SERIALIZABLE"
  test "Electron Google completion exchanges the code on the server and emits bounded telemetry" do
    Application.put_env(:comma_core, :google_adapter_fake_exchange_pid, self())
    handler_id = "google-desktop-exchange-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:comma_product, :operation, :stop],
        &__MODULE__.handle_google_exchange_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    attempt =
      :post
      |> json_conn("/v1/comma/auth/google/attempt", %{"platform" => "electron"})
      |> call()
      |> expect_json(200)

    authorization_code = "router-desktop-authorization-code"
    code_verifier = "router-desktop-pkce-verifier-012345678901234567890"
    redirect_uri = "http://127.0.0.1:43123/oauth2/callback"

    put_google_credential!(authorization_code, attempt, %{
      "sub" => "router-desktop-google-subject",
      "email" => "router-desktop@gmail.com"
    })

    session =
      :post
      |> json_conn("/v1/comma/auth/google", %{
        "attempt_id" => attempt["attempt_id"],
        "authorization_code" => authorization_code,
        "code_verifier" => code_verifier,
        "nonce" => attempt["nonce"],
        "redirect_uri" => redirect_uri
      })
      |> call()
      |> expect_json(200)

    assert "comma_sess_" <> _ = session["token"]

    assert_receive {:google_authorization_code_exchange, ^authorization_code, exchange_opts}
    assert exchange_opts[:client_id] == attempt["client_id"]
    assert exchange_opts[:client_secret] == "comma-electron-test-client-secret"
    assert exchange_opts[:nonce] == attempt["nonce"]
    assert exchange_opts[:pkce_verifier] == code_verifier
    assert exchange_opts[:redirect_uri] == redirect_uri

    assert_receive {:google_exchange_telemetry, measurements, metadata}
    assert is_integer(measurements.duration)

    assert metadata == %{
             operation: :google_desktop_exchange,
             outcome: :ok,
             provider: "google"
           }
  end

  test "Electron Google completion rejects non-loopback redirects before consuming the attempt" do
    Application.put_env(:comma_core, :google_adapter_fake_exchange_pid, self())

    attempt =
      :post
      |> json_conn("/v1/comma/auth/google/attempt", %{"platform" => "electron"})
      |> call()
      |> expect_json(200)

    authorization_code = "router-desktop-safe-redirect-code"
    code_verifier = "router-desktop-pkce-verifier-012345678901234567890"

    put_google_credential!(authorization_code, attempt, %{
      "sub" => "router-desktop-safe-redirect-subject",
      "email" => "router-desktop-safe-redirect@gmail.com"
    })

    rejected =
      :post
      |> json_conn("/v1/comma/auth/google", %{
        "attempt_id" => attempt["attempt_id"],
        "authorization_code" => authorization_code,
        "code_verifier" => code_verifier,
        "nonce" => attempt["nonce"],
        "redirect_uri" => "https://attacker.example/oauth2/callback"
      })
      |> call()
      |> expect_json(401)

    assert rejected == %{"error" => "invalid_google_credential"}
    refute_receive {:google_authorization_code_exchange, _, _}

    assert {:ok, consumed_attempt} =
             Comma.Auth.GoogleLoginAttempts.consume(
               %{
                 "attempt_id" => attempt["attempt_id"],
                 "nonce" => attempt["nonce"]
               },
               "electron"
             )

    assert consumed_attempt["platform"] == "electron"
  end

  test "Google attempts rate limit the trusted peer and ignore forwarded IP headers" do
    update_auth(ip_request_limit: 2, ip_request_window_seconds: 60)

    electron_attempt =
      :post
      |> json_conn("/v1/comma/auth/google/attempt", %{"platform" => "electron"})
      |> put_req_header("x-forwarded-for", "198.51.100.10")
      |> call()
      |> expect_json(200)

    assert electron_attempt["platform"] == "electron"
    assert electron_attempt["client_id"] == "comma-electron-test.apps.googleusercontent.com"

    web_attempt =
      :post
      |> json_conn("/v1/comma/auth/google/attempt", %{"platform" => "web"})
      |> put_req_header("x-forwarded-for", "198.51.100.11")
      |> call()
      |> expect_json(200)

    assert web_attempt["client_id"] == "comma-web-test.apps.googleusercontent.com"

    limited =
      :post
      |> json_conn("/v1/comma/auth/google/attempt", %{"platform" => "web"})
      |> put_req_header("x-forwarded-for", "203.0.113.99")
      |> call()

    assert %{"error" => "rate_limited"} = expect_json(limited, 429)
    assert [retry_after] = get_resp_header(limited, "retry-after")
    assert {seconds, ""} = Integer.parse(retry_after)
    assert seconds in 1..60

    assert %{"platform" => "web"} =
             :post
             |> json_conn("/v1/comma/auth/google/attempt", %{"platform" => "web"})
             |> put_req_header("x-forwarded-for", "127.0.0.1")
             |> put_remote_ip({198, 51, 100, 12})
             |> call()
             |> expect_json(200)
  end

  @tag database_isolation: "SERIALIZABLE"
  test "public Google GIS endpoints validate a one-time attempt and issue an ordinary session" do
    origin = "http://127.0.0.1:5174"

    attempt =
      :post
      |> json_conn("/v1/comma/auth/google/attempt", %{"platform" => "web"})
      |> web_cookie_request(origin, :none)
      |> call()
      |> expect_json(200)

    assert attempt["client_id"] == "comma-web-test.apps.googleusercontent.com"
    assert is_binary(attempt["attempt_id"])
    assert is_binary(attempt["nonce"])

    credential = "router-google-credential"

    Application.put_env(:comma_core, :google_adapter_fake_credentials, %{
      credential => %{
        "iss" => "https://accounts.google.com",
        "sub" => "router-google-subject",
        "aud" => attempt["client_id"],
        "nonce" => attempt["nonce"],
        "email" => "router@gmail.com",
        "email_verified" => true,
        "name" => "Router Google"
      }
    })

    session_conn =
      :post
      |> json_conn("/v1/comma/auth/google", %{
        "attempt_id" => attempt["attempt_id"],
        "nonce" => attempt["nonce"],
        "credential" => credential
      })
      |> web_cookie_request(origin, :none)
      |> call()

    session = expect_json(session_conn, 200)
    assert Map.keys(session) |> Enum.sort() == ["expires_at", "session_id", "user"]
    refute Map.has_key?(session, "token")

    assert session["user"]["email"] == "router@gmail.com"
    refute Map.has_key?(session["user"], "admin")

    cookie = session_conn.resp_cookies[CommaWeb.SessionCookie.cookie_name()]
    assert cookie.http_only == true
    assert "comma_sess_" <> _ = cookie.value

    assert 200 ==
             (:get
              |> conn("/v1/comma/workspaces")
              |> cookie_auth(cookie.value, origin)
              |> call()).status

    assert %{"error" => "origin_path_not_allowed"} =
             :get
             |> conn("/v1/comma/admin/users")
             |> cookie_auth(cookie.value, origin)
             |> call()
             |> expect_json(403)

    replay =
      :post
      |> json_conn("/v1/comma/auth/google", %{
        "attempt_id" => attempt["attempt_id"],
        "nonce" => attempt["nonce"],
        "credential" => credential
      })
      |> web_cookie_request(origin, :none)
      |> call()
      |> expect_json(401)

    assert replay["error"] == "invalid_google_attempt"
  end

  @tag database_isolation: "SERIALIZABLE"
  test "third-party Google linking requires one OTP through the public HTTP flow" do
    email = "router-google-link@example.com"
    assert {:ok, existing} = Comma.Accounts.Repository.ensure_user_by_email(email)
    previous_delivery_pid = Application.get_env(:comma_core, :email_delivery_test_pid)

    on_exit(fn ->
      restore_env(:comma_core, :email_delivery_test_pid, previous_delivery_pid)
    end)

    Application.put_env(:comma_core, :email_delivery_test_pid, self())
    update_auth(email_delivery: __MODULE__.RecordingEmailDelivery, expose_codes: false)

    attempt = google_attempt!()
    credential = "router-google-link-credential"

    put_google_credential!(credential, attempt, %{
      "sub" => "router-google-link-subject",
      "email" => email,
      "hd" => nil
    })

    pending =
      :post
      |> json_conn("/v1/comma/auth/google", %{
        "attempt_id" => attempt["attempt_id"],
        "nonce" => attempt["nonce"],
        "credential" => credential
      })
      |> call()
      |> expect_json(200)

    assert pending == %{
             "challenge_id" => pending["challenge_id"],
             "email" => email,
             "status" => "otp_required"
           }

    refute Map.has_key?(pending, "code")

    assert_receive {:login_code_delivery, ^email, code, challenge_id}
    assert challenge_id == pending["challenge_id"]
    assert is_binary(code)
    assert is_nil(Comma.Repo.get_by(Comma.Accounts.Identity, user_id: existing.id))

    assert %{"error" => "invalid_verification_code"} =
             :post
             |> json_conn("/v1/comma/auth/google/link/verify", %{
               "challenge_id" => challenge_id,
               "code" => wrong_code(code)
             })
             |> call()
             |> expect_json(401)

    session =
      :post
      |> json_conn("/v1/comma/auth/google/link/verify", %{
        "challenge_id" => challenge_id,
        "code" => code
      })
      |> call()
      |> expect_json(200)

    assert "comma_sess_" <> _ = session["token"]
    assert session["user"]["id"] == existing.id

    assert %Comma.Accounts.Identity{
             user_id: user_id,
             subject: "router-google-link-subject"
           } = Comma.Repo.get_by!(Comma.Accounts.Identity, user_id: existing.id)

    assert user_id == existing.id

    assert %{"error" => "invalid_verification_code"} =
             :post
             |> json_conn("/v1/comma/auth/google/link/verify", %{
               "challenge_id" => challenge_id,
               "code" => code
             })
             |> call()
             |> expect_json(401)
  end

  @tag database_isolation: "SERIALIZABLE"
  test "a new Google subject cannot replace the user's existing Google identity" do
    email = "router-google-takeover@gmail.com"
    first_attempt = google_attempt!()

    put_google_credential!("router-google-first", first_attempt, %{
      "sub" => "router-google-first-subject",
      "email" => email
    })

    first =
      :post
      |> json_conn("/v1/comma/auth/google", %{
        "attempt_id" => first_attempt["attempt_id"],
        "nonce" => first_attempt["nonce"],
        "credential" => "router-google-first"
      })
      |> call()
      |> expect_json(200)

    second_attempt = google_attempt!()

    put_google_credential!("router-google-second", second_attempt, %{
      "sub" => "router-google-second-subject",
      "email" => email
    })

    assert %{"error" => "provider_already_linked"} =
             :post
             |> json_conn("/v1/comma/auth/google", %{
               "attempt_id" => second_attempt["attempt_id"],
               "nonce" => second_attempt["nonce"],
               "credential" => "router-google-second"
             })
             |> call()
             |> expect_json(409)

    assert %Comma.Accounts.Identity{
             user_id: user_id,
             subject: "router-google-first-subject"
           } = Comma.Repo.one!(Comma.Accounts.Identity)

    assert user_id == first["user"]["id"]
  end

  test "session listing never returns credentials or budget idempotency state" do
    session = email_login!("session-lifecycle@example.com")

    page =
      :get
      |> conn("/v1/comma/auth/sessions")
      |> user_auth(session["token"])
      |> call()
      |> expect_json(200)

    assert [%{"id" => session_id, "auth_method" => "email_otp"}] = page["data"]
    assert is_binary(session_id)
    refute Map.has_key?(hd(page["data"]), "token")
    refute Map.has_key?(hd(page["data"]), "consumed_interaction_ids")
  end

  test "neither passwordless nor ops-issued user sessions grant admin access" do
    otp_session = email_login!("not-admin@example.com")

    assert 401 ==
             (:get
              |> conn("/v1/comma/admin/users")
              |> user_auth(otp_session["token"])
              |> call()).status

    user =
      :post
      |> json_conn("/v1/comma/admin/users", %{
        "email" => "legacy-admin-flag@example.com",
        "admin" => true
      })
      |> admin_auth()
      |> call()
      |> expect_json(201)

    refute Map.has_key?(user, "admin")

    ops_session =
      :post
      |> json_conn("/v1/comma/admin/users/#{user["id"]}/sessions", %{})
      |> admin_auth()
      |> call()
      |> expect_json(201)

    assert ops_session["session_source"] == "ops_api"
    assert ops_session["auth_method"] == nil

    assert 401 ==
             (:get
              |> conn("/v1/comma/admin/users")
              |> user_auth(ops_session["token"])
              |> call()).status

    listed =
      :get
      |> conn("/v1/comma/auth/sessions")
      |> user_auth(ops_session["token"])
      |> call()
      |> expect_json(200)

    assert [%{"session_source" => "ops_api"} | _] = listed["data"]
    assert Enum.all?(listed["data"], &(not Map.has_key?(&1, "token")))

    product_conn =
      :get
      |> conn("/v1/comma/workspaces")
      |> admin_auth()
      |> CommaWeb.Auth.call([])

    assert product_conn.halted
    assert product_conn.status == 401
  end

  test "protected product API denies anonymous requests when admin token is unset" do
    Application.delete_env(:comma_web, :api_token)
    Application.delete_env(:salix_web, :api_token)

    login =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "anonymous-auth@example.com"})
      |> call()
      |> expect_json(200)

    assert %{"challenge_id" => _, "code" => _} = login

    response =
      :get
      |> conn("/v1/comma/workspaces")
      |> call()

    assert response.status == 401
    assert Jason.decode!(response.resp_body)["error"] == "unauthorized"
  end

  test "Stripe checkout return page is public and opens the environment-specific client" do
    Application.delete_env(:comma_web, :api_token)
    Application.delete_env(:salix_web, :api_token)

    for {environment, scheme, client_name} <- [
          {"dev", "comma-dev", "Comma Dev"},
          {"staging", "comma-staging", "Comma Staging"},
          {"prod", "comma", "Comma"}
        ] do
      response =
        :get
        |> conn(
          "/v1/comma/billing/stripe/checkout/return?environment=#{environment}&status=success"
        )
        |> call()

      assert response.status == 200
      assert get_resp_header(response, "content-type") == ["text/html; charset=utf-8"]
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert response.resp_body =~ "Payment successful"
      assert response.resp_body =~ "#{scheme}://billing/return?status=success"
      assert response.resp_body =~ "Open #{client_name}"
    end

    cancel =
      :get
      |> conn("/v1/comma/billing/stripe/checkout/cancel?environment=dev")
      |> call()

    assert cancel.status == 200
    assert cancel.resp_body =~ "Checkout canceled"
    assert cancel.resp_body =~ "comma-dev://billing/return?status=cancel"

    invalid =
      :get
      |> conn("/v1/comma/billing/stripe/checkout/return?environment=unknown&status=success")
      |> call()
      |> expect_json(400)

    assert invalid == %{"error" => "invalid_billing_return"}
  end

  test "email login is generic and returns bounded 429 responses" do
    {:ok, _existing} = Comma.Accounts.create_user(%{"email" => "existing-login@example.com"})
    update_auth(expose_codes: false, resend_cooldown_seconds: 60)

    existing =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "existing-login@example.com"})
      |> call()
      |> expect_json(200)

    unknown =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "unknown-login@example.com"})
      |> call()
      |> expect_json(200)

    assert Map.keys(existing) == ["challenge_id"]
    assert Map.keys(unknown) == ["challenge_id"]

    limited =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "existing-login@example.com"})
      |> call()

    assert limited.status == 429
    assert Jason.decode!(limited.resp_body) == %{"error" => "rate_limited"}
    assert [retry_after] = get_resp_header(limited, "retry-after")
    assert {seconds, ""} = Integer.parse(retry_after)
    assert seconds in 1..60
  end

  test "email verification failure windows return 429 and block a later correct guess" do
    update_auth(verification_failure_limit: 1)

    login =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "verify-limit@example.com"})
      |> call()
      |> expect_json(200)

    limited =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => login["challenge_id"],
        "code" => wrong_code(login["code"])
      })
      |> call()

    assert limited.status == 429
    assert Jason.decode!(limited.resp_body) == %{"error" => "rate_limited"}
    assert [_retry_after] = get_resp_header(limited, "retry-after")

    still_limited =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => login["challenge_id"],
        "code" => login["code"]
      })
      |> call()

    assert still_limited.status == 429
  end

  test "email verification hides internal auth configuration failures" do
    update_auth(secret: nil)

    unavailable =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => "comma_auth_test",
        "code" => "123456"
      })
      |> call()

    assert unavailable.status == 503
    assert Jason.decode!(unavailable.resp_body) == %{"error" => "auth_unavailable"}
  end

  test "untrusted forwarded IP headers cannot bypass the peer-IP request window" do
    update_auth(ip_request_limit: 1)

    first =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "peer-limit-1@example.com"})
      |> put_req_header("cf-connecting-ip", "198.51.100.10")
      |> put_req_header("x-forwarded-for", "198.51.100.10")
      |> call()

    assert first.status == 200

    spoofed =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "peer-limit-2@example.com"})
      |> put_req_header("cf-connecting-ip", "198.51.100.11")
      |> put_req_header("x-forwarded-for", "198.51.100.11")
      |> call()

    assert spoofed.status == 429
    assert Jason.decode!(spoofed.resp_body) == %{"error" => "rate_limited"}
  end

  test "Redis and provider outages return generic 503 contracts" do
    update_auth(challenge_store: __MODULE__.UnavailableChallengeStore)

    redis_down =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "redis-down@example.com"})
      |> call()

    assert redis_down.status == 503
    assert Jason.decode!(redis_down.resp_body) == %{"error" => "email_delivery_unavailable"}

    google_redis_down =
      :post
      |> json_conn("/v1/comma/auth/google/attempt", %{"platform" => "web"})
      |> call()

    assert google_redis_down.status == 503
    assert Jason.decode!(google_redis_down.resp_body) == %{"error" => "auth_unavailable"}

    Comma.AuthChallengeStore.Memory.reset!()

    update_auth(
      challenge_store: Comma.AuthChallengeStore.Memory,
      email_delivery: __MODULE__.RejectingEmailDelivery,
      provider_failure_threshold: 1
    )

    rejected =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "provider-down@example.com"})
      |> call()

    assert rejected.status == 503
    assert Jason.decode!(rejected.resp_body) == %{"error" => "email_delivery_unavailable"}

    circuit_open =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => "provider-down-2@example.com"})
      |> call()

    assert circuit_open.status == 503
    assert Jason.decode!(circuit_open.resp_body) == %{"error" => "email_delivery_unavailable"}
    assert [_retry_after] = get_resp_header(circuit_open, "retry-after")
  end

  defp seed_billing_package!(
         package_code,
         package_version,
         surface,
         kind,
         name,
         grant_credits \\ 100
       ) do
    {:ok, _package} =
      BillingCommerce.create_package(%{
        code: package_code,
        surface: surface,
        name: name
      })

    {:ok, _version} =
      BillingCommerce.create_package_version(%{
        package_code: package_code,
        version: package_version,
        surface: surface,
        kind: kind,
        billing_period: "month",
        grant_credits: grant_credits,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 0,
        usage_policy: %{},
        effective_at: ~U[2026-07-01 00:00:00Z],
        status: "active"
      })

    :ok
  end

  defp ensure_fake_s3! do
    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end
  end

  test "the model catalog gives signed-in users each source's request id" do
    conn(:get, "/v1/comma/model-catalog") |> call() |> expect_json(401)

    login = email_login!("model-catalog@example.com")

    catalog =
      conn(:get, "/v1/comma/model-catalog")
      |> user_auth(login["token"])
      |> call()
      |> expect_json(200)

    gpt = Enum.find(catalog["models"], &(&1["id"] == "gpt-5.5"))
    assert gpt["routes"]["openai"]["model"] == "gpt-5.5"
    assert gpt["routes"]["openrouter"]["model"] == "openai/gpt-5.5"
    assert catalog["sources"]["codex"]["kind"] == "subscription"
  end

  defp json_conn(method, path, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
  end

  defp wrong_code(code) do
    if code == "000000", do: "000001", else: "000000"
  end

  defp update_auth(overrides) do
    current = Application.get_env(:comma_core, :auth, [])
    Application.put_env(:comma_core, :auth, Keyword.merge(current, overrides))
  end

  defp google_attempt! do
    :post
    |> json_conn("/v1/comma/auth/google/attempt", %{"platform" => "web"})
    |> call()
    |> expect_json(200)
  end

  defp put_google_credential!(credential, attempt, overrides) do
    claims =
      Map.merge(
        %{
          "iss" => "https://accounts.google.com",
          "sub" => "router-google-subject",
          "aud" => attempt["client_id"],
          "nonce" => attempt["nonce"],
          "email" => "router-google@gmail.com",
          "email_verified" => true,
          "name" => "Router Google"
        },
        overrides
      )

    Application.put_env(:comma_core, :google_adapter_fake_credentials, %{
      credential => claims
    })
  end

  def handle_google_exchange_telemetry(
        [:comma_product, :operation, :stop],
        measurements,
        %{operation: :google_desktop_exchange} = metadata,
        pid
      ) do
    send(pid, {:google_exchange_telemetry, measurements, metadata})
  end

  def handle_google_exchange_telemetry(_event, _measurements, _metadata, _pid), do: :ok

  defp admin_auth(conn), do: put_req_header(conn, "authorization", "Bearer #{@admin_token}")
  defp user_auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
  defp put_remote_ip(conn, address), do: %{conn | remote_ip: address}

  defp cookie_auth(conn, token, origin, expectation \\ nil) do
    expectation = expectation || session_id_for_token(token)

    conn
    |> put_req_header("cookie", "#{CommaWeb.SessionCookie.cookie_name()}=#{token}")
    |> web_cookie_request(origin, expectation)
  end

  defp web_cookie_request(conn, origin, expectation) do
    conn
    |> put_req_header("origin", origin)
    |> put_req_header("x-comma-session-transport", "cookie")
    |> put_req_header("x-comma-session-lifecycle-version", "1")
    |> put_req_header(
      "x-comma-expected-auth-session-id",
      lifecycle_expectation_header(expectation)
    )
  end

  defp lifecycle_expectation_header(:unknown), do: "unknown"
  defp lifecycle_expectation_header(:none), do: "none"
  defp lifecycle_expectation_header(session_id) when is_binary(session_id), do: session_id

  defp prepend_req_header(conn, key, value) do
    %{conn | req_headers: [{String.downcase(key), value} | conn.req_headers]}
  end

  defp session_id_for_token(token) do
    token_hash = :crypto.hash(:sha256, token)

    Repo.one!(
      from(session in AuthSession,
        where: session.token_hash == ^token_hash,
        select: session.id
      )
    )
  end

  defp call(conn) do
    conn
    |> default_native_auth_transport()
    |> raw_call()
  end

  defp raw_call(conn), do: CommaWeb.Router.call(conn, @opts)

  defp default_native_auth_transport(conn) do
    no_origin? = get_req_header(conn, "origin") == []
    no_transport? = get_req_header(conn, "x-comma-session-transport") == []
    native_auth? = String.starts_with?(conn.request_path, "/v1/comma/auth/")

    if conn.method != "OPTIONS" and no_origin? and no_transport? and native_auth? do
      put_req_header(conn, "x-comma-session-transport", "bearer")
    else
      conn
    end
  end

  defp email_login!(email) do
    login =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => email})
      |> call()
      |> expect_json(200)

    :post
    |> json_conn("/v1/comma/auth/email/verify", %{
      "challenge_id" => login["challenge_id"],
      "code" => login["code"]
    })
    |> call()
    |> expect_json(200)
  end

  defp browser_cookie_login!(email, origin) do
    login =
      :post
      |> json_conn("/v1/comma/auth/email/login", %{"email" => email})
      |> web_cookie_request(origin, :none)
      |> call()
      |> expect_json(200)

    verify_conn =
      :post
      |> json_conn("/v1/comma/auth/email/verify", %{
        "challenge_id" => login["challenge_id"],
        "code" => login["code"]
      })
      |> web_cookie_request(origin, :none)
      |> call()

    session = expect_json(verify_conn, 200)
    cookie = verify_conn.resp_cookies[CommaWeb.SessionCookie.cookie_name()]

    assert cookie.http_only == true
    assert "comma_sess_" <> _ = cookie.value

    {session, cookie.value}
  end

  defp expect_json(conn, status) do
    assert conn.status == status
    Jason.decode!(conn.resp_body)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defmodule RejectingEmailDelivery do
    @behaviour Comma.EmailDelivery

    @impl true
    def send_login_code(_email, _code, _opts), do: {:error, {:postmark, 503, 0}}
  end

  defmodule RecordingEmailDelivery do
    @behaviour Comma.EmailDelivery

    @impl true
    def send_login_code(email, code, opts) do
      send(
        Application.fetch_env!(:comma_core, :email_delivery_test_pid),
        {:login_code_delivery, email, code, opts[:challenge_id]}
      )

      :ok
    end
  end

  defmodule UnavailableChallengeStore do
    @behaviour Comma.AuthChallengeStore

    @impl true
    def reserve(_challenge, _ttl_seconds, _opts), do: {:error, :redis_down}

    @impl true
    def reserve_attempt(_challenge, _ttl_seconds, _opts), do: {:error, :redis_down}

    @impl true
    def verify(_id, _code_hash, _max_attempts, _opts), do: {:error, :redis_down}

    @impl true
    def verify(_id, _code_hash, _max_attempts), do: {:error, :redis_down}

    @impl true
    def record_delivery(_outcome, _opts), do: {:error, :redis_down}

    @impl true
    def delete(_id), do: {:error, :redis_down}
  end

  defmodule RecordingSalixClient do
    @behaviour Comma.Salix.Client

    @impl true
    def provision_workspace_scope(workspace) do
      send(test_pid!(), {:provision_workspace_scope, workspace})

      if workspace["provisioning_generation"] == 1 do
        CommaWeb.SalixClient.provision_workspace_scope(workspace)
      else
        :ok
      end
    end

    @impl true
    def resolve_workspace_scope(workspace), do: {:ok, workspace}

    @impl true
    def update_workspace_vm(workspace, vm) do
      send(test_pid!(), {:update_workspace_vm, workspace, vm})
      :ok
    end

    @impl true
    def create_group_conversation(_workspace, _attrs), do: {:error, :not_implemented}

    @impl true
    def get_group_conversation_messages(_workspace, _conversation_id),
      do: {:error, :not_implemented}

    @impl true
    def append_group_conversation_message(_workspace, _conversation_id, _attrs),
      do: {:error, :not_implemented}

    @impl true
    def reconcile_group_conversation_router_participant(_workspace, conversation_id) do
      {:ok, %{"conversation_id" => conversation_id}}
    end

    @impl true
    def conversation_activity_context(_workspace, _conversation_id),
      do: {:error, :not_implemented}

    @impl true
    def list_agent_skills(_workspace), do: {:ok, %{"skills" => []}}

    @impl true
    def write_agent_file(workspace, path, body) do
      send(test_pid!(), {:write_agent_file, workspace, path, body})
      {:ok, %{"path" => path}}
    end

    @impl true
    def read_agent_file(_workspace, _path, _max_bytes), do: {:error, :not_found}

    defp test_pid! do
      Application.fetch_env!(:comma_core, :salix_client_test_pid)
    end
  end

  defmodule SynchConflictClient do
    @behaviour Comma.Synchronicity.Client

    @impl true
    def provision_workspace(_workspace_id, _name, _owner),
      do: {:error, {:retryable, :unused}}

    @impl true
    def enroll_device(_workspace_id, _nk, _label, _owner),
      do: {:error, {:invalid, {:conflict, "device_org_conflict"}}}

    @impl true
    def mint_api_key(_workspace_id, _owner, _name), do: {:error, {:retryable, :unused}}

    @impl true
    def revoke_api_key(_workspace_id, _key_id), do: {:error, {:retryable, :unused}}
  end
end
