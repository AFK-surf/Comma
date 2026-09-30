defmodule BridgeForTeamsWeb.ProjectAgentControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  import Ecto.Query

  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.CLI.Login, as: CLILogin
  alias BridgeForTeams.{Agents, Memberships, Projects}
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.{Agent, ProjectDeviceProjection, ReconcileOutbox}
  alias BridgeForTeamsWeb.DashboardEndpoint
  alias SalixStore.RuntimeIds

  @device_runtime_id RuntimeIds.device_runtime_id("dev-ready", "codex", "runtime-ready")

  defmodule AgentInventorySalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    alias SalixStore.RuntimeIds

    @device_runtime_id RuntimeIds.device_runtime_id("dev-ready", "codex", "runtime-ready")

    def list_group_envs(_group_id, _tenant_id) do
      {:ok,
       [
         %{
           "connector_run_id" => "run-ready",
           "device_id" => "dev-ready",
           "name" => "mac-mini-2",
           "status" => "connected",
           "device_runtimes" => [
             %{
               "provider" => "connector",
               "runtime_id" => "default",
               "device_runtime_id" =>
                 RuntimeIds.device_runtime_id("dev-ready", "connector", "default"),
               "device_id" => "dev-ready",
               "status" => "connected"
             },
             %{
               "provider" => "codex",
               "runtime_id" => "runtime-ready",
               "device_runtime_id" => @device_runtime_id,
               "status" => "ready",
               "model" => "claude-sonnet-4",
               "model_provider" => "anthropic",
               "version" => "codex-test"
             }
           ]
         }
       ]}
    end

    def create_agent(attrs) do
      {tenant_id, attrs} = Map.pop(attrs, "tenant_id")
      {agent_id, attrs} = Map.pop(attrs, "agent_id")
      SalixAgent.Control.create_preallocated(attrs, tenant_id, agent_id)
    end

    def update_agent(agent_id, tenant_id, attrs) do
      SalixAgent.Control.configure(agent_id, attrs, tenant_id)
    end

    def get_agent(agent_id, tenant_id) do
      SalixAgent.Control.get(agent_id, tenant_id)
    end

    def get_agent_projection(agent_id, tenant_id) do
      SalixAgent.Control.get(agent_id, tenant_id)
    end

    def page_external_worker_targets(
          _tenant_id,
          "project",
          owner_id,
          group_id,
          provider,
          opts
        ) do
      {:ok,
       %{
         "items" => [workload_item(owner_id, group_id, provider)],
         "next_cursor" => nil,
         "read_at" => "2026-09-01T00:00:00Z",
         "echo" => Map.new(opts)
       }}
    end

    def validate_external_worker_target(
          _tenant_id,
          "project",
          owner_id,
          group_id,
          provider,
          workload_id,
          fence
        ) do
      item = workload_item(owner_id, group_id, provider)

      cond do
        workload_id != item["workload_id"] -> {:error, :not_found}
        fence != item["selection_fence"] -> {:error, :selection_changed}
        true -> {:ok, item}
      end
    end

    def apply_external_worker_binding(agent_id, tenant_id, runtime_config),
      do: SalixAgent.Control.apply_external_worker_binding(agent_id, tenant_id, runtime_config)

    defp workload_item(owner_id, group_id, provider) do
      %{
        "workload_id" => "#{owner_id}-#{provider}-workload",
        "label" => "#{provider} workload",
        "provider" => provider,
        "owner_scope" => %{"type" => "project", "id" => owner_id},
        "group_id" => group_id,
        "selectable" => true,
        "reason" => nil,
        "selection_fence" => %{
          "workload_revision" => 7,
          "runtime_connection_epoch" => 3
        }
      }
    end
  end

  defmodule AgentProjectionUnavailableSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_group_envs(group_id, tenant_id) do
      AgentInventorySalixClient.list_group_envs(group_id, tenant_id)
    end

    def create_agent(attrs), do: AgentInventorySalixClient.create_agent(attrs)

    def update_agent(agent_id, tenant_id, attrs),
      do: AgentInventorySalixClient.update_agent(agent_id, tenant_id, attrs)

    def get_agent_projection(_agent_id, _tenant_id),
      do: raise("mutation response must not read an agent provider projection")
  end

  defmodule RosterProjectionSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_group_envs(group_id, tenant_id) do
      AgentInventorySalixClient.list_group_envs(group_id, tenant_id)
    end

    def create_agent(attrs), do: AgentInventorySalixClient.create_agent(attrs)

    def update_agent(agent_id, tenant_id, attrs),
      do: AgentInventorySalixClient.update_agent(agent_id, tenant_id, attrs)

    def get_agent_projection(agent_id, tenant_id),
      do: AgentInventorySalixClient.get_agent_projection(agent_id, tenant_id)
  end

  defmodule ProviderCallForbiddenClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_group_envs(_group_id, _tenant_id),
      do: raise("project device GET must not call list_group_envs")

    def page_group_envs(_group_id, _tenant_id, _opts),
      do: raise("project device GET must not call page_group_envs")
  end

  defmodule WorkloadUnavailableSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def page_external_worker_targets(_, _, _, _, _, _), do: {:error, :unavailable}
  end

  defmodule RuntimeAuthAPIClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def runtime_auth_read(device_id, device_runtime_id, group_id, tenant_id),
      do: dispatch(:read, [device_id, device_runtime_id, group_id, tenant_id])

    def runtime_auth_login_start(device_id, device_runtime_id, flow, group_id, tenant_id),
      do: dispatch(:start, [device_id, device_runtime_id, flow, group_id, tenant_id])

    def runtime_auth_login_cancel(
          device_id,
          device_runtime_id,
          attempt_id,
          group_id,
          tenant_id
        ),
        do: dispatch(:cancel, [device_id, device_runtime_id, attempt_id, group_id, tenant_id])

    defp dispatch(operation, args) do
      %{test_pid: test_pid, results: results} =
        Application.fetch_env!(:bridge_for_teams_core, :runtime_auth_api_probe)

      send(test_pid, {:runtime_auth_api_call, operation, args})
      Map.fetch!(results, operation)
    end
  end

  defmodule AgentOwnerUnavailableClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    def page_group_agents(_, _, _), do: {:error, :unavailable}
  end

  setup do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

    on_exit(fn ->
      if previous_client do
        Application.put_env(:bridge_for_teams_core, :salix_client, previous_client)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)

    %{user: user, org: org} = org_with_owner_fixture(org: %{slug: "acme", name: "Acme"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Support", "slug" => "support"})

    runtime_config = %{
      "kind" => "external",
      "provider" => "codex",
      "device_id" => "dev-ready",
      "runtime_id" => "runtime-ready",
      "device_runtime_id" => @device_runtime_id,
      "model" => "claude-sonnet-4",
      "model_provider" => "anthropic"
    }

    Application.put_env(:bridge_for_teams_core, :salix_client, AgentInventorySalixClient)
    insert_device_projection!(project)

    {:ok, worker} =
      Agents.create_agent(project.id, %{
        "name" => "codex-bft",
        "role" => "worker",
        "runtime_config" => runtime_config
      })

    if previous_client do
      Application.put_env(:bridge_for_teams_core, :salix_client, previous_client)
    else
      Application.delete_env(:bridge_for_teams_core, :salix_client)
    end

    drain_reconcile!()

    {:ok, _, _} =
      SalixEnv.Registry.connect(
        "nonode@nohost",
        %{
          "tenant_id" => org.salix_tenant_id,
          "group_id" => project.salix_group_id,
          "device_id" => "dev-ready",
          "connector_id" => "api-test-" <> Ecto.UUID.generate(),
          "name" => "mac-mini-2",
          "agent_runtimes" => [
            %{
              "kind" => "external",
              "provider" => "codex",
              "runtime_id" => "runtime-ready",
              "device_runtime_id" => @device_runtime_id,
              "version" => "codex-test",
              "version_detected" => true,
              "auth_ready" => true,
              "native_server_startable" => true,
              "ready" => true,
              "readiness_checked_at" => System.system_time(:millisecond),
              "readiness_valid_until" => System.system_time(:millisecond) + 600_000
            }
          ]
        },
        transport_id: "api-test-" <> Ecto.UUID.generate()
      )

    Application.put_env(:bridge_for_teams_core, :salix_client, AgentInventorySalixClient)

    {:ok, %{token: token, session: session}} = Sessions.create(user, device: "bft-cli")
    {:ok, _grants} = CLILogin.grant_cli_session_orgs(session, [org.id], user.id)

    %{org: org, project: project, worker: worker, token: token}
  end

  defp drain_reconcile! do
    case BridgeForTeams.Salix.Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _count} -> drain_reconcile!()
    end
  end

  test "project agents API exposes worker runtime identity and readiness", %{
    org: org,
    project: project,
    worker: worker,
    token: token
  } do
    data =
      :get
      |> api(project_agents_path(org.slug, project.slug) <> "?role=worker", token)
      |> json_data()

    assert data["mode"] == "project_agents_list"
    assert data["role"] == "worker"
    assert [listed] = data["agents"]
    assert listed["id"] == worker.id
    assert listed["salix_agent_id"] == worker.salix_agent_id
    assert listed["role"] == "worker"

    assert listed["runtime_config"] == %{
             "kind" => "external",
             "provider" => "codex",
             "device_id" => "dev-ready",
             "runtime_id" => "runtime-ready",
             "device_runtime_id" => @device_runtime_id,
             "model" => "claude-sonnet-4",
             "model_provider" => "anthropic"
           }

    assert listed["runtime"]["status"] == "ready"
    assert listed["runtime"]["device_id"] == "dev-ready"
    assert listed["runtime"]["runtime_id"] == "runtime-ready"
    assert listed["runtime"]["device_runtime_id"] == @device_runtime_id
    assert listed["runtime"]["connector_run_id"] == "run-ready"
    assert listed["runtime"]["device_name"] == "mac-mini-2"
    refute Map.has_key?(listed["runtime"], "ready")
  end

  for provider <- ~w(codex pi claude) do
    test "project agents API pages project-scoped #{provider} Workloads", %{
      org: org,
      project: project,
      token: token
    } do
      provider = unquote(provider)

      data =
        :get
        |> api(
          project_agent_workloads_path(org.slug, project.slug) <>
            "?provider=#{provider}&limit=500&query=triage",
          token
        )
        |> json_data()

      assert data["mode"] == "project_agent_workloads_page"
      assert data["provider"] == provider
      assert data["page"]["echo"]["limit"] == 50
      assert data["page"]["echo"]["query"] == "triage"
      assert data["page"]["echo"]["include_unavailable"] == false

      workload_id = project.id <> "-" <> provider <> "-workload"

      assert [%{"workload_id" => ^workload_id, "provider" => ^provider}] =
               data["page"]["items"]

      including_unavailable =
        :get
        |> api(
          project_agent_workloads_path(org.slug, project.slug) <>
            "?provider=#{provider}&include_unavailable=true",
          token
        )
        |> json_data()

      assert including_unavailable["page"]["echo"]["include_unavailable"] == true

      invalid =
        api(
          :get,
          project_agent_workloads_path(org.slug, project.slug) <>
            "?provider=#{provider}&include_unavailable=1",
          token
        )

      assert invalid.status == 400

      assert %{"error" => %{"code" => "invalid_include_unavailable"}} =
               Jason.decode!(invalid.resp_body)
    end
  end

  test "project agents API returns an actionable error when Workload discovery is unavailable", %{
    org: org,
    project: project,
    token: token
  } do
    Application.put_env(:bridge_for_teams_core, :salix_client, WorkloadUnavailableSalixClient)

    conn =
      api(
        :get,
        project_agent_workloads_path(org.slug, project.slug) <> "?provider=codex",
        token
      )

    assert conn.status == 503
    assert %{"error" => %{"code" => "unavailable"}} = Jason.decode!(conn.resp_body)
  end

  test "project devices API exposes canonical public runtimes", %{
    org: org,
    project: project,
    token: token
  } do
    insert_device_projection!(project)
    Application.put_env(:bridge_for_teams_core, :salix_client, ProviderCallForbiddenClient)

    data =
      :get
      |> api(project_devices_path(org.slug, project.slug), token)
      |> json_data()

    assert [%{"runtime_count" => 1, "runtimes" => [runtime]}] = data["devices"]
    assert runtime["provider"] == "codex"
    assert runtime["device_runtime_id"] == @device_runtime_id
    assert runtime["status"] == "ready"
    assert runtime["readiness"]["version"] == "codex-test"
    refute Map.has_key?(runtime, "identity_material")
    refute Map.has_key?(runtime, "command")
    refute Map.has_key?(runtime["readiness"], "ready")
    refute Map.has_key?(runtime["readiness"], "last_error")
  end

  test "project devices GET reads a bounded PG projection without provider calls", %{
    org: org,
    project: project,
    token: token
  } do
    insert_device_projection!(project)
    Application.put_env(:bridge_for_teams_core, :salix_client, ProviderCallForbiddenClient)

    data =
      :get
      |> api(project_devices_path(org.slug, project.slug) <> "?limit=1", token)
      |> json_data()

    assert [%{"id" => "dev-ready"}] = data["devices"]
    assert data["limit"] == 1
  end

  test "project runtime auth API is scoped, no-store, and exposes ceremony only on start", %{
    org: org,
    project: project,
    token: token
  } do
    now = System.system_time(:millisecond)
    previous_probe = Application.get_env(:bridge_for_teams_core, :runtime_auth_api_probe)
    Application.put_env(:bridge_for_teams_core, :salix_client, RuntimeAuthAPIClient)

    on_exit(fn ->
      if previous_probe,
        do:
          Application.put_env(
            :bridge_for_teams_core,
            :runtime_auth_api_probe,
            previous_probe
          ),
        else: Application.delete_env(:bridge_for_teams_core, :runtime_auth_api_probe)
    end)

    auth = %{
      "schema_version" => 1,
      "status" => "unauthenticated",
      "mode" => "chatgpt",
      "requires_openai_auth" => true,
      "observed_at" => 1_787_020_000_000
    }

    ceremony = %{
      "attempt_id" => "rta_api",
      "flow" => "device_code",
      "verification_url" => "https://auth.openai.com/codex/device",
      "user_code" => "ABCD-EFGH",
      "expires_at" => now + 900_000,
      "reused" => false,
      "auth" => Map.put(auth, "status", "pending")
    }

    Application.put_env(:bridge_for_teams_core, :runtime_auth_api_probe, %{
      test_pid: self(),
      results: %{
        read:
          {:ok,
           %{
             "auth" => auth,
             "attempt_id" => "rta_api",
             "flow" => "device_code",
             "expires_at" => ceremony["expires_at"]
           }},
        start: {:ok, ceremony},
        cancel: {:ok, %{"attempt_id" => "rta_api", "canceled" => true, "auth" => auth}}
      }
    })

    group_id = project.salix_group_id
    tenant_id = org.salix_tenant_id

    path = project_runtime_auth_path(org.slug, project.slug, "dev-ready", @device_runtime_id)

    unauthorized_conn = api(:get, path, "invalid-runtime-auth-token")
    assert unauthorized_conn.status == 401
    assert get_resp_header(unauthorized_conn, "cache-control") == ["no-store"]

    read_conn = api(:get, path, token)
    assert get_resp_header(read_conn, "cache-control") == ["no-store"]
    assert %{"auth" => ^auth} = json_data(read_conn)["runtime_auth"]
    refute Map.has_key?(json_data(read_conn)["runtime_auth"], "attempt_id")

    assert_receive {:runtime_auth_api_call, :read,
                    [
                      "dev-ready",
                      @device_runtime_id,
                      ^group_id,
                      ^tenant_id
                    ]}

    start_conn = api_json(:post, path <> "/login", token, %{"flow" => "device_code"})
    assert get_resp_header(start_conn, "cache-control") == ["no-store"]
    assert json_data(start_conn)["runtime_auth"] == ceremony

    assert_receive {:runtime_auth_api_call, :start,
                    [
                      "dev-ready",
                      @device_runtime_id,
                      "device_code",
                      ^group_id,
                      ^tenant_id
                    ]}

    telemetry_handler = {__MODULE__, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        telemetry_handler,
        [:comma_system, :http, :stop],
        fn _event, _measurements, metadata, _config ->
          if metadata.method == "DELETE",
            do: send(test_pid, {:runtime_auth_cancel_http, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    cancel_conn =
      api_json(:delete, path <> "/login", token, %{"attempt_id" => "rta_api"})

    assert get_resp_header(cancel_conn, "cache-control") == ["no-store"]
    assert cancel_conn.request_path == path <> "/login"

    assert_receive {:runtime_auth_cancel_http, cancel_http_metadata}

    assert cancel_http_metadata.route ==
             "/v1/orgs/:org/projects/:project/devices/:device_id/runtimes/:device_runtime_id/auth/login"

    refute inspect(cancel_http_metadata) =~ "rta_api"
    refute cancel_conn.request_path =~ "rta_api"

    assert json_data(cancel_conn)["runtime_auth"] == %{
             "auth" => auth,
             "canceled" => true
           }

    assert_receive {:runtime_auth_api_call, :cancel,
                    [
                      "dev-ready",
                      @device_runtime_id,
                      "rta_api",
                      ^group_id,
                      ^tenant_id
                    ]}
  end

  test "project runtime auth start and cancel require project write access", %{
    org: org,
    project: project
  } do
    previous_probe = Application.get_env(:bridge_for_teams_core, :runtime_auth_api_probe)
    Application.put_env(:bridge_for_teams_core, :salix_client, RuntimeAuthAPIClient)

    on_exit(fn ->
      if previous_probe,
        do:
          Application.put_env(
            :bridge_for_teams_core,
            :runtime_auth_api_probe,
            previous_probe
          ),
        else: Application.delete_env(:bridge_for_teams_core, :runtime_auth_api_probe)
    end)

    member = user_fixture(email: "runtime-auth-reader@example.com")
    {:ok, _org_membership} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, _project_membership} = Memberships.put_project_member(project.id, member.id, "user")
    {:ok, %{token: token, session: session}} = Sessions.create(member, device: "bft-cli")
    {:ok, _grants} = CLILogin.grant_cli_session_orgs(session, [org.id], member.id)

    auth = %{
      "schema_version" => 1,
      "status" => "unauthenticated",
      "requires_openai_auth" => true,
      "observed_at" => 1_787_020_000_000
    }

    Application.put_env(:bridge_for_teams_core, :runtime_auth_api_probe, %{
      test_pid: self(),
      results: %{
        read: {:ok, %{"auth" => auth}},
        start: {:error, :forbidden},
        cancel: {:error, :forbidden}
      }
    })

    path = project_runtime_auth_path(org.slug, project.slug, "dev-ready", @device_runtime_id)
    read_conn = api(:get, path, token)
    assert read_conn.status == 200
    assert get_resp_header(read_conn, "cache-control") == ["no-store"]
    assert_receive {:runtime_auth_api_call, :read, _args}

    start_conn = api_json(:post, path <> "/login", token, %{"flow" => "device_code"})

    cancel_conn =
      api_json(:delete, path <> "/login", token, %{"attempt_id" => "rta_api"})

    assert start_conn.status == 403
    assert cancel_conn.status == 403
    assert get_resp_header(start_conn, "cache-control") == ["no-store"]
    assert get_resp_header(cancel_conn, "cache-control") == ["no-store"]
    refute_receive {:runtime_auth_api_call, :start, _args}
    refute_receive {:runtime_auth_api_call, :cancel, _args}
  end

  test "project agents API reads runtime status from project roster projection", %{
    org: org,
    project: project,
    worker: worker,
    token: token
  } do
    Application.put_env(:bridge_for_teams_core, :salix_client, RosterProjectionSalixClient)

    data =
      :get
      |> api(project_agents_path(org.slug, project.slug) <> "?role=worker", token)
      |> json_data()

    assert [listed] = data["agents"]
    assert listed["id"] == worker.id
    assert listed["runtime_config"]["device_runtime_id"] == @device_runtime_id
    assert listed["runtime"]["status"] == "ready"
    assert listed["runtime"]["version"] == "codex-test"
  end

  test "project agents API pages canonical records without reading the rest of a large group", %{
    org: org,
    project: project,
    worker: worker,
    token: token
  } do
    {:ok, base} = SalixAgent.Control.get(worker.salix_agent_id, org.salix_tenant_id)

    for index <- 1..1000 do
      id = SalixStore.Ids.new_agent_id(project.salix_group_id)

      record =
        base
        |> Map.put("agent_id", id)
        |> Map.put("name", "worker-#{index}")
        |> Map.put("db_namespace", "salix:" <> id)
        |> Map.put("heartbeat_schedule_id", SalixStore.Ids.new_schedule_id())

      assert {:ok, _} = SalixStore.S3.put(SalixStore.Keys.ctl_agent(id), Jason.encode!(record))
    end

    BridgeForTeams.EnvironmentRuntimeObserver.drain(30_000)
    Application.put_env(:bridge_for_teams_core, :salix_client, ProviderCallForbiddenClient)
    SalixStore.S3.Fake.reset_read_log()

    data =
      :get |> api(project_agents_path(org.slug, project.slug) <> "?limit=1", token) |> json_data()

    assert [_one] = data["agents"]
    assert data["limit"] == 1
    assert is_binary(data["next_cursor"])
    prefix = SalixStore.Keys.ctl_agents_prefix_for_group(project.salix_group_id)

    reads =
      Enum.filter(SalixStore.S3.Fake.read_log(), fn
        {:get, key} -> String.starts_with?(key, prefix)
        {:list, key, _opts} -> key == prefix
        _ -> false
      end)

    assert Enum.count(reads, &match?({:list, _, _}, &1)) == 1
    assert Enum.count(reads, &match?({:get, _}, &1)) <= 1

    next =
      :get
      |> api(
        project_agents_path(org.slug, project.slug) <>
          "?" <>
          URI.encode_query(%{"limit" => 1, "cursor" => data["next_cursor"]}),
        token
      )
      |> json_data()

    assert [_next] = next["agents"]
    refute next["agents"] == data["agents"]
  end

  test "project agents API reports an unavailable canonical owner instead of serving a cached list",
       %{org: org, project: project, token: token} do
    Application.put_env(:bridge_for_teams_core, :salix_client, AgentOwnerUnavailableClient)
    conn = api(:get, project_agents_path(org.slug, project.slug), token)
    assert conn.status == 503
    assert %{"ok" => false, "error" => %{"code" => "unavailable"}} = Jason.decode!(conn.resp_body)
  end

  test "unknown agent identifiers stay PG-bounded for update and rebind with 1001 rows", %{
    org: org,
    project: project,
    token: token
  } do
    current_count =
      Repo.aggregate(
        from(a in Agent, where: a.project_id == ^project.id),
        :count
      )

    now = DateTime.utc_now()

    rows =
      for index <- 1..(1001 - current_count) do
        %{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          salix_agent_id: "agt-legacy-local-#{index}",
          role: "worker",
          created_at: now,
          updated_at: now
        }
      end

    {inserted, nil} = Repo.insert_all(Agent, rows)
    assert inserted + current_count == 1001
    Application.put_env(:bridge_for_teams_core, :salix_client, ProviderCallForbiddenClient)

    update_conn =
      api_json(
        :patch,
        project_agent_path(org.slug, project.slug, "legacy-provider-ref"),
        token,
        %{"name" => "must-not-update"}
      )

    rebind_conn =
      api_json(
        :patch,
        project_agent_runtime_path(org.slug, project.slug, "legacy-provider-ref"),
        token,
        %{"runtime" => @device_runtime_id}
      )

    assert update_conn.status == 404
    assert rebind_conn.status == 404
  end

  for provider <- ~w(codex pi claude) do
    test "project agents API validates and applies a project-scoped #{provider} Compute Workload rebind",
         %{
           org: org,
           project: project,
           worker: worker,
           token: token
         } do
      provider = unquote(provider)

      SalixStore.TestSupport.ExternalWorkerTargetFixture.create(
        project.id <> "-" <> provider,
        project.id,
        project.salix_group_id,
        provider,
        org.salix_tenant_id
      )

      data =
        :patch
        |> api_json(project_agent_runtime_path(org.slug, project.slug, worker.id), token, %{
          "expected_binding_revision" => 0,
          "external_target" => %{
            "kind" => "compute_workload",
            "workload_id" => "#{project.id}-#{provider}-workload",
            "provider" => if(provider == "pi", do: "claude", else: provider),
            "selection_fence" => %{
              "workload_revision" => 7,
              "runtime_connection_epoch" => 3
            }
          }
        })
        |> json_data()

      assert data["mode"] == "project_agent_runtime_rebind"
      assert data["agent"]["id"] == worker.id

      assert {:ok, record} = SalixAgent.Control.get(worker.salix_agent_id, org.salix_tenant_id)
      refute Repo.get!(Agent, worker.id).salix["runtime_config"]

      assert record["runtime_config"] == %{
               "kind" => "compute_workload",
               "workload_id" => "#{project.id}-#{provider}-workload",
               "runtime_spec" => %{"provider" => provider},
               "owner_scope" => %{"type" => "project", "id" => project.id},
               "binding_revision" => 1
             }
    end
  end

  test "project agents API rejects stale desired revision and stale Workload fence", %{
    org: org,
    project: project,
    worker: worker,
    token: token
  } do
    stale_revision =
      api_json(:patch, project_agent_runtime_path(org.slug, project.slug, worker.id), token, %{
        "expected_binding_revision" => 1,
        "external_target" => %{
          "kind" => "connected_runtime",
          "device_runtime_id" => @device_runtime_id
        }
      })

    assert stale_revision.status == 409

    assert %{"error" => %{"code" => "stale_binding_revision"}} =
             Jason.decode!(stale_revision.resp_body)

    stale_fence =
      api_json(:patch, project_agent_runtime_path(org.slug, project.slug, worker.id), token, %{
        "expected_binding_revision" => 0,
        "external_target" => %{
          "kind" => "compute_workload",
          "workload_id" => "#{project.id}-pi-workload",
          "selection_fence" => %{
            "workload_revision" => 6,
            "runtime_connection_epoch" => 3
          }
        }
      })

    assert stale_fence.status == 409

    assert %{"error" => %{"code" => "selection_changed"}} =
             Jason.decode!(stale_fence.resp_body)
  end

  test "runtime rebind response uses the local agent projection without a provider read", %{
    org: org,
    project: project,
    worker: worker,
    token: token
  } do
    Application.put_env(
      :bridge_for_teams_core,
      :salix_client,
      AgentProjectionUnavailableSalixClient
    )

    data =
      :patch
      |> api_json(project_agent_runtime_path(org.slug, project.slug, worker.id), token, %{
        "expected_binding_revision" => 0,
        "external_target" => %{
          "kind" => "connected_runtime",
          "device_runtime_id" => @device_runtime_id
        }
      })
      |> json_data()

    assert data["mode"] == "project_agent_runtime_rebind"
    assert data["agent"]["id"] == worker.id
    refute Map.has_key?(data, "salix_agent_lookup_error")

    assert {:ok, record} = SalixAgent.Control.get(worker.salix_agent_id, org.salix_tenant_id)
    refute Repo.get!(Agent, worker.id).salix["runtime_config"]

    assert record["runtime_config"] == %{
             "kind" => "connected_runtime",
             "provider" => "codex",
             "device_id" => "dev-ready",
             "runtime_id" => "runtime-ready",
             "device_runtime_id" => @device_runtime_id,
             "owner_scope" => %{"type" => "group", "id" => project.salix_group_id},
             "binding_revision" => 1
           }
  end

  test "project agents API creates external worker through the validated target context", %{
    org: org,
    project: project,
    token: token
  } do
    data =
      :post
      |> api_json(project_agents_path(org.slug, project.slug), token, %{
        "name" => "codex-direct",
        "external_target" => %{
          "kind" => "connected_runtime",
          "device_runtime_id" => @device_runtime_id
        }
      })
      |> json_data(201)

    assert data["mode"] == "project_agent_create"
    assert data["agent"]["name"] == "codex-direct"
    assert data["agent"]["role"] == "worker"
    assert data["agent"]["provisioned"] == false

    assert data["agent"]["runtime_config"] == %{
             "kind" => "connected_runtime",
             "provider" => "codex",
             "device_id" => "dev-ready",
             "runtime_id" => "runtime-ready",
             "device_runtime_id" => @device_runtime_id,
             "owner_scope" => %{"type" => "group", "id" => project.salix_group_id},
             "binding_revision" => 1
           }

    assert data["agent"]["runtime"]["kind"] == "connected_runtime"

    row =
      Repo.one!(
        from(r in ReconcileOutbox,
          where:
            r.aggregate == "agent" and r.aggregate_id == ^data["agent"]["id"] and
              r.op == "create_owned_agent",
          order_by: [desc: r.created_at],
          limit: 1
        )
      )

    assert Map.has_key?(row.payload["attrs"], "runtime_config")

    assert row.payload["attrs"]["runtime_config"] == %{
             "kind" => "connected_runtime",
             "provider" => "codex",
             "device_id" => "dev-ready",
             "runtime_id" => "runtime-ready",
             "device_runtime_id" => @device_runtime_id,
             "owner_scope" => %{"type" => "group", "id" => project.salix_group_id},
             "binding_revision" => 1
           }
  end

  test "project agents API rejects configuration changes until immutable creation is provisioned",
       %{
         org: org,
         project: project,
         token: token
       } do
    {:ok, agent} =
      Agents.create_agent(project.id, %{
        "name" => "vm-worker",
        "role" => "worker",
        "vm" => %{"enabled" => true, "provider" => "cloudflare"}
      })

    conn =
      :patch
      |> api_json(project_agent_path(org.slug, project.slug, agent.id), token, %{
        "vm" => %{"enabled" => true, "provider" => "sprites", "recreate" => true}
      })

    assert conn.status == 503
    assert %{"error" => %{"code" => "agent_provisioning"}} = Jason.decode!(conn.resp_body)
    refute Repo.get!(Agent, agent.id).salix["vm"]
  end

  test "project agents API cannot turn a Worker into a Router by changing the product label", %{
    org: org,
    project: project,
    worker: worker,
    token: token
  } do
    conn =
      api_json(:patch, project_agent_path(org.slug, project.slug, worker.id), token, %{
        "role" => "router"
      })

    assert conn.status == 409
    assert %{"error" => %{"code" => "agent_role_immutable"}} = Jason.decode!(conn.resp_body)
    assert {:ok, %{role: "worker"}} = Agents.get_agent(worker.id)

    assert {:ok, %{"role" => "worker"}} =
             SalixAgent.Control.get(worker.salix_agent_id, org.salix_tenant_id)
  end

  test "project agents API rejects browser supplied raw runtime config", %{
    org: org,
    project: project,
    token: token
  } do
    conn =
      api_json(:post, project_agents_path(org.slug, project.slug), token, %{
        "role" => "router",
        "runtime_config" => %{
          "kind" => "external",
          "provider" => "codex",
          "device_id" => "dev-ready",
          "runtime_id" => "runtime-ready",
          "device_runtime_id" => @device_runtime_id
        }
      })

    assert conn.status == 400

    assert %{"ok" => false, "error" => %{"code" => "raw_runtime_config_forbidden"}} =
             Jason.decode!(conn.resp_body)
  end

  test "project agents API rejects a non-object external target instead of creating internal",
       %{
         org: org,
         project: project,
         token: token
       } do
    before_ids = Agents.list_agents(project.id) |> MapSet.new(& &1.id)

    conn =
      api_json(:post, project_agents_path(org.slug, project.slug), token, %{
        "name" => "must-not-exist",
        "external_target" => "compute-workload"
      })

    assert conn.status == 400

    assert %{"ok" => false, "error" => %{"code" => "invalid_external_target"}} =
             Jason.decode!(conn.resp_body)

    assert Agents.list_agents(project.id) |> MapSet.new(& &1.id) == before_ids
  end

  test "project agents API does not expose projects without read permission", %{
    org: org,
    project: project
  } do
    member = user_fixture(email: "agents-reader@example.com")
    {:ok, _membership} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, %{token: token, session: session}} = Sessions.create(member, device: "bft-cli")
    {:ok, _grants} = CLILogin.grant_cli_session_orgs(session, [org.id], member.id)

    conn = api(:get, project_agents_path(org.slug, project.slug), token)
    assert conn.status == 404
  end

  for {name, project_role, status, error} <- [
        {"project agents API does not create agents without project read permission", nil, 404,
         "project_not_found"},
        {"project agents API does not create agents for a read-only project member", "user", 403,
         "forbidden"}
      ] do
    test name, %{org: org, project: project} do
      member = user_fixture(email: "agents-read-only@example.com")
      {:ok, _org_membership} = Memberships.put_org_member(org.id, member.id, "member")

      if role = unquote(project_role) do
        {:ok, _project_membership} = Memberships.put_project_member(project.id, member.id, role)
      end

      {:ok, %{token: token, session: session}} = Sessions.create(member, device: "bft-cli")
      {:ok, _grants} = CLILogin.grant_cli_session_orgs(session, [org.id], member.id)

      before_ids = Agents.list_agents(project.id) |> MapSet.new(& &1.id)

      conn =
        api_json(:post, project_agents_path(org.slug, project.slug), token, %{
          "name" => "codex-read-only",
          "external_target" => %{
            "kind" => "connected_runtime",
            "device_runtime_id" => @device_runtime_id
          }
        })

      assert conn.status == unquote(status)

      assert %{"ok" => false, "error" => %{"code" => unquote(error)}} =
               Jason.decode!(conn.resp_body)

      assert Agents.list_agents(project.id) |> MapSet.new(& &1.id) == before_ids
    end
  end

  test "project refs only accept id or slug", %{org: org, project: project, token: token} do
    slug_conn = api(:get, project_agents_path(org.slug, project.slug), token)
    assert slug_conn.status == 200

    id_conn = api(:get, project_agents_path(org.slug, project.id), token)
    assert id_conn.status == 200

    name_conn = api(:get, project_agents_path(org.slug, project.name), token)
    assert name_conn.status == 404

    group_conn = api(:get, project_agents_path(org.slug, project.salix_group_id), token)
    assert group_conn.status == 404
  end

  defp project_agents_path(org, project) do
    "/v1/orgs/#{org}/projects/#{project}/agents"
  end

  defp project_devices_path(org, project) do
    "/v1/orgs/#{org}/projects/#{project}/devices"
  end

  defp project_agent_path(org, project, agent) do
    project_agents_path(org, project) <> "/#{agent}"
  end

  defp project_agent_runtime_path(org, project, agent) do
    project_agent_path(org, project, agent) <> "/runtime"
  end

  defp project_agent_workloads_path(org, project) do
    project_agents_path(org, project) <> "/workloads"
  end

  defp project_runtime_auth_path(org, project, device_id, device_runtime_id) do
    project_devices_path(org, project) <>
      "/#{device_id}/runtimes/#{device_runtime_id}/auth"
  end

  defp insert_device_projection!(project) do
    now = DateTime.utc_now()

    %ProjectDeviceProjection{}
    |> ProjectDeviceProjection.changeset(%{
      project_id: project.id,
      device_id: "dev-ready",
      connector_run_id: "run-ready",
      connector_id: "connector-ready",
      name: "mac-mini-2",
      status: "connected",
      source_updated_at: DateTime.to_unix(now, :millisecond),
      observed_generation: 1,
      runtime_inventory: %{
        "items" => [
          %{
            "provider" => "codex",
            "runtime_id" => "runtime-ready",
            "device_runtime_id" => @device_runtime_id,
            "status" => "ready",
            "version" => "codex-test",
            "model" => "claude-sonnet-4",
            "model_provider" => "anthropic"
          }
        ]
      }
    })
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:project_id, :device_id, :created_at]},
      conflict_target: [:project_id, :device_id]
    )
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

  defp json_data(conn, status \\ 200) do
    assert conn.status == status
    assert %{"ok" => true, "data" => data} = Jason.decode!(conn.resp_body)
    data
  end
end
