defmodule BridgeForTeamsWeb.ProjectComputeControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.CLI.Login, as: CLILogin
  alias BridgeForTeams.{Compute, Environments, Memberships, Projects}
  alias BridgeForTeamsWeb.DashboardEndpoint
  alias SalixStore.{AgentVMMInstallations, Repo}

  setup do
    %{user: user, org: org} = org_with_owner_fixture(org: %{slug: "compute-org"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Compute", "slug" => "compute"})
    {:ok, %{token: token, session: session}} = Sessions.create(user, device: "bft-cli")
    {:ok, _grants} = CLILogin.grant_cli_session_orgs(session, [org.id], user.id)

    %{org: org, project: project, token: token, user: user}
  end

  test "device account entry accepts unready inventory and protects organization configuration",
       %{org: org, project: project, user: user, conn: conn} do
    device = "binding-device-" <> Ecto.UUID.generate()
    runtime = "binding-runtime-" <> Ecto.UUID.generate()

    {:ok, _, _} =
      SalixEnv.Registry.connect(
        "nonode@nohost",
        %{
          "tenant_id" => org.salix_tenant_id,
          "group_id" => project.salix_group_id,
          "device_id" => device,
          "connector_id" => Ecto.UUID.generate(),
          "name" => "Unready Mac",
          "agent_runtimes" => [
            %{
              "kind" => "external",
              "provider" => "codex",
              "runtime_id" => runtime,
              "device_runtime_id" => runtime,
              "version_detected" => true,
              "auth_ready" => false,
              "native_server_startable" => true,
              "ready" => false,
              "readiness_checked_at" => System.system_time(:millisecond),
              "readiness_valid_until" => System.system_time(:millisecond) + 600_000
            }
          ]
        },
        transport_id: Ecto.UUID.generate()
      )

    path =
      "/dashboard/orgs/#{org.slug}/projects/#{project.slug}/devices/#{device}/runtimes/#{runtime}/managed-auth"

    owner = conn |> log_in_user(user) |> get(path)
    assert owner.status == 200
    auth = owner.resp_body |> Jason.decode!() |> get_in(["data", "managed_auth"])
    assert auth["state"] == "unbound"
    assert auth["can_configure"]
    assert auth["actions"] == ["bind"]

    # Listing accounts is optional when the binding state is already known.
    key = Application.get_env(:salix_agent, :subscription_storage_key)
    Application.delete_env(:salix_agent, :subscription_storage_key)

    try do
      degraded = owner |> recycle() |> get(path)
      assert degraded.status == 200
      auth = degraded.resp_body |> Jason.decode!() |> get_in(["data", "managed_auth"])
      assert auth["state"] == "unbound"
      assert auth["can_self_configure"]
      assert auth["accounts_unavailable"]
      assert auth["accounts"] == []
    after
      Application.put_env(:salix_agent, :subscription_storage_key, key)
    end

    reader = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, reader.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, reader.id, "admin")
    reader_conn = conn |> log_in_user(reader)
    read = get(reader_conn, path)
    assert read.status == 200
    auth = read.resp_body |> Jason.decode!() |> get_in(["data", "managed_auth"])
    refute auth["can_configure"]
    assert auth["can_self_configure"]
    refute Map.has_key?(auth, "accounts")
    refute Map.has_key?(auth, "binding")

    for method <- [:put, :delete] do
      denied =
        read
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> dispatch(
          DashboardEndpoint,
          method,
          path,
          Jason.encode!(%{"account_id" => "unauthorized"})
        )

      assert denied.status == 403
      assert get_resp_header(denied, "cache-control") == ["no-store"]
    end

    missing = conn |> log_in_user(user) |> get(String.replace(path, device, "foreign-device"))
    assert missing.status == 404
  end

  test "managed-auth HTTP binds a compatible account and never returns its key", %{
    org: org,
    project: project,
    user: user,
    conn: conn
  } do
    {:ok, _} =
      Compute.configure_default_provider(org, %{
        "provider" => "cloudflare",
        "config_ref" => "test"
      })

    {:ok, environment} = Compute.create_environment(org, project, %{})

    {:ok, %{"workload" => workload}} =
      Compute.create_workload(org, project, %{
        "environment_id" => environment.id,
        "kind" => "external_worker"
      })

    workload.id
    |> then(&Repo.get!(SalixStore.Compute.Workload, &1))
    |> Ecto.Changeset.change(template_key: "external.pi")
    |> Repo.update!()

    {:ok, account} =
      SalixAgent.AccountPool.create(org.salix_tenant_id, %{
        "credential_kind" => "provider_api_key",
        "name" => "Team provider",
        "connection" => %{
          "endpoint" => "https://models.example.test",
          "protocol" => "openai_responses",
          "auth_scheme" => "bearer"
        },
        "credentials" => %{"api_key" => "never-return-this-key"}
      })

    path =
      "/dashboard/orgs/#{org.slug}/projects/#{project.slug}/workloads/#{workload.id}/managed-auth"

    conn = log_in_user(conn, user)
    read = get(conn, path)
    assert read.status == 200
    assert get_resp_header(read, "cache-control") == ["no-store"]
    body = Jason.decode!(read.resp_body)
    assert get_in(body, ["data", "managed_auth", "state"]) == "unbound"
    assert [%{"id" => account_id}] = get_in(body, ["data", "managed_auth", "accounts"])
    assert account_id == account["id"]
    refute read.resp_body =~ "never-return-this-key"

    bound =
      read
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> put(
        path,
        Jason.encode!(%{
          "account_id" => account["id"],
          "expected_account_version" => account["version"],
          "expected_binding" => nil
        })
      )

    assert bound.status == 202
    bound_auth = bound.resp_body |> Jason.decode!() |> get_in(["data", "managed_auth"])
    assert bound_auth["source"] == "organization"
    assert bound_auth["state"] == "installing"
    refute bound.resp_body =~ "never-return-this-key"

    removed =
      bound
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> delete(path, Jason.encode!(%{"expected_binding" => bound_auth["binding"]}))

    assert removed.status in [200, 202]
    refute removed.resp_body =~ "never-return-this-key"
  end

  test "managed-auth readers get redacted state and writes require organization administration",
       %{
         org: org,
         project: project,
         conn: conn
       } do
    {:ok, _} =
      Compute.configure_default_provider(org, %{
        "provider" => "cloudflare",
        "config_ref" => "test"
      })

    {:ok, environment} = Compute.create_environment(org, project, %{})

    {:ok, %{"workload" => workload}} =
      Compute.create_workload(org, project, %{
        "environment_id" => environment.id,
        "kind" => "external_worker"
      })

    workload.id
    |> then(&Repo.get!(SalixStore.Compute.Workload, &1))
    |> Ecto.Changeset.change(template_key: "external.claude")
    |> Repo.update!()

    reader = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, reader.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, reader.id, "admin")

    path =
      "/dashboard/orgs/#{org.slug}/projects/#{project.slug}/workloads/#{workload.id}/managed-auth"

    conn = log_in_user(conn, reader)
    read = get(conn, path)
    assert read.status == 200
    auth = read.resp_body |> Jason.decode!() |> get_in(["data", "managed_auth"])

    assert auth == %{
             "source" => "self_configured",
             "state" => "unbound",
             "provider" => "claude",
             "issue" => nil,
             "can_configure" => false
           }

    denied =
      read
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> put(path, Jason.encode!(%{"account_id" => "not-authorized"}))

    assert denied.status == 403
    assert get_resp_header(denied, "cache-control") == ["no-store"]
  end

  test "project and org APIs drive one bounded Compute domain without exposing provider identity",
       %{org: org, project: project, token: token} do
    org_path = "/v1/orgs/#{org.slug}/compute"
    project_path = "/v1/orgs/#{org.slug}/projects/#{project.slug}/compute"

    onboarding =
      api_json(:post, org_path <> "/providers", token, %{
        "provider" => "cloudflare",
        "config_ref" => "secure-config-ref"
      })
      |> json_data()

    pool = onboarding["pool"]
    provider = onboarding["provider"]

    assert pool["managed_key"] == "default"
    assert provider["configured"]
    refute Map.has_key?(provider, "provider_ref")
    refute inspect(provider) =~ "secure-config-ref"

    environment =
      api_json(:post, project_path <> "/environments", token, %{})
      |> json_data()
      |> get_in(["compute"])

    workload =
      api_json(:post, project_path <> "/workloads", token, %{
        "environment_id" => environment["id"],
        "kind" => "external_worker",
        "capability_requirements" => ["runtime_exec"]
      })
      |> json_data()
      |> get_in(["compute", "workload"])

    assert workload["environment_id"] == environment["id"]

    projection = api(:get, project_path, token) |> json_data() |> get_in(["compute"])
    assert [%{"id" => environment_id}] = projection["environments"]
    assert environment_id == environment["id"]
    assert [%{"id" => workload_id}] = projection["workloads"]
    assert workload_id == workload["id"]
    refute inspect(projection) =~ "agent_vmm"
    refute inspect(projection) =~ "secure-config-ref"

    drained =
      api_json(
        :post,
        project_path <> "/environments/#{environment["id"]}/drain",
        token,
        %{"expected_revision" => environment["revision"]}
      )
      |> json_data()
      |> get_in(["compute"])

    assert drained["desired_state"] == "draining"

    revoked =
      api_json(
        :post,
        project_path <> "/environments/#{environment["id"]}/revoke",
        token,
        %{"expected_revision" => drained["revision"]}
      )
      |> json_data()
      |> get_in(["compute"])

    assert revoked["desired_state"] == "revoked"
  end

  test "Agent VMM install API binds an exact online runner and never returns its ticket secret",
       %{org: org, project: project, token: token} do
    suffix = System.unique_integer([:positive])

    assert {:ok, runner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "runner-api-#{suffix}",
               "name" => "Runner API"
             })

    path =
      "/v1/orgs/#{org.slug}/projects/#{project.slug}/compute-nodes/agent-vmm/install-operations"

    created =
      :post
      |> build_conn(path, Jason.encode!(%{"runner_id" => runner.stable_id}))
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "install-api-#{suffix}")
      |> DashboardEndpoint.call([])

    assert created.status == 200, created.resp_body
    assert get_resp_header(created, "cache-control") == ["no-store"]
    operation = created.resp_body |> Jason.decode!() |> get_in(["data", "compute"])
    assert operation["delivery_target_id"] == runner.stable_id
    refute inspect(operation) =~ "secret"

    fetched = api(:get, path <> "/#{operation["id"]}", token)
    assert fetched.status == 200
    refute fetched.resp_body =~ "ticket_secret"

    retried = api_json(:post, path <> "/#{operation["id"]}/retry", token, %{})
    assert retried.status == 200

    assert retried.resp_body |> Jason.decode!() |> get_in(["data", "compute", "id"]) ==
             operation["id"]

    refute retried.resp_body =~ "one_time_secret"

    revoked = api_json(:post, path <> "/#{operation["id"]}/revoke", token, %{})
    assert revoked.status == 200

    assert revoked.resp_body
           |> Jason.decode!()
           |> get_in(["data", "compute", "authorization_status"]) ==
             "revoked"
  end

  test "terminal Agent VMM retry is actionable without rotating handoff identity",
       %{org: org, project: project, token: token} do
    suffix = System.unique_integer([:positive])

    assert {:ok, runner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "runner-terminal-retry-#{suffix}",
               "name" => "Runner terminal retry"
             })

    path =
      "/v1/orgs/#{org.slug}/projects/#{project.slug}/compute-nodes/agent-vmm/install-operations"

    created =
      :post
      |> build_conn(path, Jason.encode!(%{"runner_id" => runner.stable_id}))
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "terminal-retry-#{suffix}")
      |> DashboardEndpoint.call([])

    assert created.status == 200, created.resp_body
    operation = created.resp_body |> Jason.decode!() |> get_in(["data", "compute"])

    before = Repo.get!(AgentVMMInstallations.Operation, operation["id"])
    terminal_at = DateTime.utc_now()

    assert {:ok, _terminal} =
             before
             |> Ecto.Changeset.change(%{
               authorization_status: "handed_off",
               ticket_status: "consumed",
               ticket_consumed_at: terminal_at,
               material_handed_off_at: terminal_at,
               error_code: "agent_vmm.apply_failed"
             })
             |> Repo.update()

    retried = api_json(:post, path <> "/#{operation["id"]}/retry", token, %{})

    assert retried.status == 409

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "operation_not_retryable",
               "message" => "This install operation is terminal; start a new install operation."
             }
           } = Jason.decode!(retried.resp_body)

    after_retry = Repo.get!(AgentVMMInstallations.Operation, operation["id"])
    assert after_retry.id == before.id
    assert after_retry.registration_id == before.registration_id
    assert after_retry.ticket_generation == before.ticket_generation
    assert after_retry.ticket_secret_hash == before.ticket_secret_hash
    assert after_retry.authorization_status == "handed_off"
    assert after_retry.material_handed_off_at == terminal_at
  end

  defp api(method, path, token) do
    method
    |> build_conn(path)
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> DashboardEndpoint.call([])
  end

  defp api_json(method, path, token, body) do
    method
    |> build_conn(path, Jason.encode!(body))
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> DashboardEndpoint.call([])
  end

  defp json_data(conn) do
    assert conn.status == 200, conn.resp_body
    assert %{"ok" => true, "data" => data} = Jason.decode!(conn.resp_body)
    data
  end
end
