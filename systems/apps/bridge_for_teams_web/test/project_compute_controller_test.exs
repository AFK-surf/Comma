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
    device = "binding-device-" <> SystemsRuntime.Proc.uuid()
    runtime = "binding-runtime-" <> SystemsRuntime.Proc.uuid()

    {:ok, _, _} =
      SalixEnv.Registry.connect(
        "nonode@nohost",
        %{
          "tenant_id" => org.salix_tenant_id,
          "group_id" => project.salix_group_id,
          "device_id" => device,
          "connector_id" => SystemsRuntime.Proc.uuid(),
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
              "readiness_checked_at" => SystemsClock.system_time(:millisecond),
              "readiness_valid_until" => SystemsClock.system_time(:millisecond) + 600_000
            }
          ]
        },
        transport_id: SystemsRuntime.Proc.uuid()
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
    key = SystemsRuntime.get_env(:salix_agent, :subscription_storage_key)
    SystemsRuntime.delete_env(:salix_agent, :subscription_storage_key)

    try do
      degraded = owner |> recycle() |> get(path)
      assert degraded.status == 200
      auth = degraded.resp_body |> Jason.decode!() |> get_in(["data", "managed_auth"])
      assert auth["state"] == "unbound"
      assert auth["can_self_configure"]
      assert auth["accounts_unavailable"]
      assert auth["accounts"] == []
    after
      SystemsRuntime.put_env(:salix_agent, :subscription_storage_key, key)
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
        "kind" => "service",
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

  test "Linux command delivery fails before occupying the Project when configuration is unavailable",
       ctx do
    previous = SystemsRuntime.get_env(:salix_web, :public_base_url)
    on_exit(fn -> SystemsRuntime.put_env(:salix_web, :public_base_url, previous) end)
    before_count = Repo.aggregate(AgentVMMInstallations.Operation, :count)

    for origin <- [nil, "http://untrusted.example.test"] do
      SystemsRuntime.put_env(:salix_web, :public_base_url, origin)

      response =
        :post
        |> build_conn(
          "/v1/orgs/#{ctx.org.slug}/projects/#{ctx.project.slug}/compute-nodes/agent-vmm/install-commands",
          "{}"
        )
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{ctx.token}")
        |> put_req_header("idempotency-key", "linux-unavailable")
        |> DashboardEndpoint.call([])

      assert response.status == 503, response.resp_body
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert Repo.aggregate(AgentVMMInstallations.Operation, :count) == before_count
    end
  end

  test "Linux headless delivery fixes the Project and user and cannot be collected by a Runner",
       ctx do
    attrs = %{"request_id" => "linux-install", "runner_id" => "foreign", "group_id" => "foreign"}
    authorize = fn -> :ok end

    assert {:ok, first} =
             Compute.request_agent_vmm_headless_install(
               ctx.org,
               ctx.project,
               ctx.user,
               attrs,
               authorize
             )

    operation = Repo.get!(AgentVMMInstallations.Operation, first.operation.id)
    assert operation.group_id == ctx.project.salix_group_id
    assert operation.delivery_target_type == "headless"
    assert operation.delivery_target_id == ctx.user.id
    assert operation.authorizing_subject_id == ctx.user.id

    assert {:error, :no_pending_operation} =
             AgentVMMInstallations.deliver_next("bft_runner", ctx.user.id)

    assert {:ok, retry} =
             Compute.request_agent_vmm_headless_install(
               ctx.org,
               ctx.project,
               ctx.user,
               attrs,
               authorize
             )

    assert retry.operation.id == first.operation.id
    assert retry.operation.environment_id == first.operation.environment_id

    assert {:error, :scope_host_bound} =
             Compute.request_agent_vmm_headless_install(
               ctx.org,
               ctx.project,
               ctx.user,
               %{"request_id" => "second"},
               authorize
             )

    assert {:error, :authorization_changed} =
             Compute.request_agent_vmm_headless_install(
               ctx.org,
               ctx.project,
               ctx.user,
               attrs,
               fn -> {:error, :forbidden} end
             )

    assert Repo.get!(AgentVMMInstallations.Operation, first.operation.id).ticket_generation ==
             retry.operation.ticket_generation
  end

  test "a lost Linux command is visible and removable through the existing Project Devices API",
       ctx do
    assert {:ok, descriptor} =
             Compute.request_agent_vmm_headless_install(
               ctx.org,
               ctx.project,
               ctx.user,
               %{"request_id" => "lost-command"},
               fn -> :ok end
             )

    path = "/dashboard/api/v1/orgs/#{ctx.org.slug}/projects/#{ctx.project.id}/devices"
    response = ctx.conn |> log_in_user(ctx.user) |> get(path)
    assert response.status == 200, response.resp_body
    cloud = Jason.decode!(response.resp_body)["data"]["cloud_vm"]
    assert cloud["runner"] == %{"name" => "Linux Compute Host", "status" => "processing"}
    assert cloud["runner_removable"]
    refute cloud["runner_choosable"]
    removed = response |> recycle() |> delete(path <> "/cloud-vm/runner")
    assert removed.status == 200, removed.resp_body

    assert Repo.get!(AgentVMMInstallations.Operation, descriptor.operation.id).authorization_status ==
             "revoked"

    assert {:ok, next} =
             Compute.request_agent_vmm_headless_install(
               ctx.org,
               ctx.project,
               ctx.user,
               %{"request_id" => "replacement-command"},
               fn -> :ok end
             )

    refute next.operation.id == descriptor.operation.id
  end

  test "Agent VMM install API binds an exact online runner and never returns its ticket secret",
       %{org: org, project: project, token: token} do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])

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

    # A project uses one runner: another install request is refused until this one is revoked.
    second =
      :post
      |> build_conn(path, Jason.encode!(%{"runner_id" => runner.stable_id}))
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "install-api-second-#{suffix}")
      |> DashboardEndpoint.call([])

    assert second.status == 409
    assert %{"error" => %{"code" => "project_runner_bound"}} = Jason.decode!(second.resp_body)

    revoked = api_json(:post, path <> "/#{operation["id"]}/revoke", token, %{})
    assert revoked.status == 200

    assert revoked.resp_body
           |> Jason.decode!()
           |> get_in(["data", "compute", "authorization_status"]) ==
             "revoked"
  end

  test "terminal Agent VMM retry is actionable without rotating handoff identity",
       %{org: org, project: project, token: token} do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])

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
    terminal_at = SystemsClock.utc_now()

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
