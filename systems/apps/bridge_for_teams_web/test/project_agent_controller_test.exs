defmodule BridgeForTeamsWeb.ProjectAgentControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

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

  defmodule ProviderCallForbiddenClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_group_envs(_group_id, _tenant_id),
      do: raise("project device GET must not call list_group_envs")

    def page_group_envs(_group_id, _tenant_id, _opts),
      do: raise("project device GET must not call page_group_envs")
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
        SystemsRuntime.fetch_env!(:bridge_for_teams_core, :runtime_auth_api_probe)

      SystemsRuntime.Proc.send(test_pid, {:runtime_auth_api_call, operation, args})
      Map.fetch!(results, operation)
    end
  end

  defmodule AgentOwnerUnavailableClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    def page_group_agents(_, _, _), do: {:error, :unavailable}
  end

  setup do
    previous_client = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)

    on_exit(fn ->
      if previous_client do
        SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous_client)
      else
        SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)

    %{user: user, org: org} = org_with_owner_fixture(org: %{slug: "acme", name: "Acme"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Support", "slug" => "support"})

    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, AgentInventorySalixClient)
    insert_device_projection!(project)

    {:ok, worker} =
      BridgeForTeams.TestSupport.LegacyWorker.create_station(project, %{"name" => "codex-bft"}, %{
        "kind" => "station",
        "device_id" => "dev-ready",
        "runtime" => "codex"
      })

    if previous_client do
      SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous_client)
    else
      SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)
    end

    drain_reconcile!()

    {:ok, _, _} =
      SalixEnv.Registry.connect(
        "nonode@nohost",
        %{
          "tenant_id" => org.salix_tenant_id,
          "group_id" => project.salix_group_id,
          "device_id" => "dev-ready",
          "connector_id" => "api-test-" <> SystemsRuntime.Proc.uuid(),
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
              "readiness_checked_at" => SystemsClock.system_time(:millisecond),
              "readiness_valid_until" => SystemsClock.system_time(:millisecond) + 600_000
            }
          ]
        },
        transport_id: "api-test-" <> SystemsRuntime.Proc.uuid()
      )

    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, AgentInventorySalixClient)

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

  test "project agents API exposes where a station-bound worker runs", %{
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

    assert listed["station_binding"] == %{
             "runs_on" => %{"kind" => "station", "device_id" => "dev-ready"},
             "model" => %{"kind" => "runtime", "provider" => "codex"},
             "binding_revision" => 1
           }

    assert listed["runtime"] == %{
             "kind" => "station",
             "runs_on" => %{"kind" => "station", "device_id" => "dev-ready"},
             "provider" => "codex"
           }
  end

  test "project devices API exposes canonical public runtimes", %{
    org: org,
    project: project,
    token: token
  } do
    insert_device_projection!(project)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, ProviderCallForbiddenClient)

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

  test "project runtime auth API is scoped, no-store, and exposes ceremony only on start", %{
    org: org,
    project: project,
    token: token
  } do
    now = SystemsClock.system_time(:millisecond)
    previous_probe = SystemsRuntime.get_env(:bridge_for_teams_core, :runtime_auth_api_probe)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, RuntimeAuthAPIClient)

    on_exit(fn ->
      if previous_probe,
        do:
          SystemsRuntime.put_env(
            :bridge_for_teams_core,
            :runtime_auth_api_probe,
            previous_probe
          ),
        else: SystemsRuntime.delete_env(:bridge_for_teams_core, :runtime_auth_api_probe)
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

    SystemsRuntime.put_env(:bridge_for_teams_core, :runtime_auth_api_probe, %{
      test_pid: SystemsRuntime.Proc.self(),
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

    settle_receive(
      {:runtime_auth_api_call, :read,
       [
         "dev-ready",
         @device_runtime_id,
         ^group_id,
         ^tenant_id
       ]}
    )

    start_conn = api_json(:post, path <> "/login", token, %{"flow" => "device_code"})
    assert get_resp_header(start_conn, "cache-control") == ["no-store"]
    assert json_data(start_conn)["runtime_auth"] == ceremony

    settle_receive(
      {:runtime_auth_api_call, :start,
       [
         "dev-ready",
         @device_runtime_id,
         "device_code",
         ^group_id,
         ^tenant_id
       ]}
    )

    telemetry_handler = {__MODULE__, SystemsRuntime.Proc.make_ref()}
    test_pid = SystemsRuntime.Proc.self()

    :ok =
      SystemsRuntime.Telemetry.attach(
        telemetry_handler,
        [:comma_system, :http, :stop],
        fn _event, _measurements, metadata, _config ->
          if metadata.method == "DELETE",
            do: SystemsRuntime.Proc.send(test_pid, {:runtime_auth_cancel_http, metadata})
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(telemetry_handler) end)

    cancel_conn =
      api_json(:delete, path <> "/login", token, %{"attempt_id" => "rta_api"})

    assert get_resp_header(cancel_conn, "cache-control") == ["no-store"]
    assert cancel_conn.request_path == path <> "/login"

    settle_receive({:runtime_auth_cancel_http, cancel_http_metadata})

    assert cancel_http_metadata.route ==
             "/v1/orgs/:org/projects/:project/devices/:device_id/runtimes/:device_runtime_id/auth/login"

    refute inspect(cancel_http_metadata) =~ "rta_api"
    refute cancel_conn.request_path =~ "rta_api"

    assert json_data(cancel_conn)["runtime_auth"] == %{
             "auth" => auth,
             "canceled" => true
           }

    settle_receive(
      {:runtime_auth_api_call, :cancel,
       [
         "dev-ready",
         @device_runtime_id,
         "rta_api",
         ^group_id,
         ^tenant_id
       ]}
    )
  end

  test "project runtime auth start and cancel require project write access", %{
    org: org,
    project: project
  } do
    previous_probe = SystemsRuntime.get_env(:bridge_for_teams_core, :runtime_auth_api_probe)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, RuntimeAuthAPIClient)

    on_exit(fn ->
      if previous_probe,
        do:
          SystemsRuntime.put_env(
            :bridge_for_teams_core,
            :runtime_auth_api_probe,
            previous_probe
          ),
        else: SystemsRuntime.delete_env(:bridge_for_teams_core, :runtime_auth_api_probe)
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

    SystemsRuntime.put_env(:bridge_for_teams_core, :runtime_auth_api_probe, %{
      test_pid: SystemsRuntime.Proc.self(),
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
    settle_receive({:runtime_auth_api_call, :read, _args})
    start_conn = api_json(:post, path <> "/login", token, %{"flow" => "device_code"})

    cancel_conn =
      api_json(:delete, path <> "/login", token, %{"attempt_id" => "rta_api"})

    assert start_conn.status == 403
    assert cancel_conn.status == 403
    assert get_resp_header(start_conn, "cache-control") == ["no-store"]
    assert get_resp_header(cancel_conn, "cache-control") == ["no-store"]
    settle_refute_receive({:runtime_auth_api_call, :start, _args})
    settle_refute_receive({:runtime_auth_api_call, :cancel, _args})
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

    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, ProviderCallForbiddenClient)
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

  test "project agents API creates, moves or changes no Worker: 410 workers_retired", %{
    org: org,
    project: project,
    worker: worker,
    token: token
  } do
    before_ids = Agents.list_agents(project.id) |> MapSet.new(& &1.id)
    {:ok, before} = SalixAgent.Control.get(worker.salix_agent_id, org.salix_tenant_id)

    for {method, path, body} <- [
          {:post, project_agents_path(org.slug, project.slug),
           %{
             "name" => "codex-direct",
             "station_target" => %{
               "kind" => "station",
               "device_id" => "dev-ready",
               "runtime" => "codex"
             }
           }},
          {:patch, project_agent_runtime_path(org.slug, project.slug, worker.id),
           %{
             "expected_binding_revision" => 1,
             "station_target" => %{"kind" => "cloud_vm", "runtime" => "claude"}
           }},
          {:patch, project_agent_path(org.slug, project.slug, worker.id), %{"role" => "router"}}
        ] do
      conn = api_json(method, path, token, body)
      assert conn.status == 410
      assert %{"error" => %{"code" => "workers_retired"}} = Jason.decode!(conn.resp_body)
    end

    assert Agents.list_agents(project.id) |> MapSet.new(& &1.id) == before_ids
    assert {:ok, %{role: "worker"}} = Agents.get_agent(worker.id)
    assert {:ok, ^before} = SalixAgent.Control.get(worker.salix_agent_id, org.salix_tenant_id)
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
          "station_target" => %{
            "kind" => "station",
            "device_id" => "dev-ready",
            "runtime" => "codex"
          }
        })

      assert conn.status == unquote(status)

      assert %{"ok" => false, "error" => %{"code" => unquote(error)}} =
               Jason.decode!(conn.resp_body)

      assert Agents.list_agents(project.id) |> MapSet.new(& &1.id) == before_ids
    end
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

  defp project_runtime_auth_path(org, project, device_id, device_runtime_id) do
    project_devices_path(org, project) <>
      "/#{device_id}/runtimes/#{device_runtime_id}/auth"
  end

  defp insert_device_projection!(project) do
    now = SystemsClock.utc_now()

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
        ],
        "capabilities" => %{"tasks" => 2}
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
