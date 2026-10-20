defmodule BridgeForTeamsWeb.DashboardAPISwarmDevicesTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The Devices API behind the React Devices page: the swarm's Cloud VM with
  the org Runner it uses, the projected devices, Android setup, adding a
  device on a runner with its provisioning poll, disconnect and delete, and
  the Compute environments.
  Swarm admins write; a swarm member's device write is refused with a denied
  audit; someone outside the swarm gets 404.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

  import Ecto.Query, only: [from: 2]

  alias BridgeForTeams.{Environments, Memberships, Observability, Projects, Repo}
  alias BridgeForTeams.Salix.Reconciler
  alias BridgeForTeams.Schema.{MacMiniProvisioner, ProjectDeviceProjection}

  # The page reads the device projection, never the live device registry.
  defmodule ProjectionOnlyClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def get_tenant_config(_tenant_id, "android_control", default),
      do: {:ok, SystemsRuntime.get_env(:bridge_for_teams_core, :test_android_control, default)}

    def list_group_envs(_group_id, _tenant_id), do: raise("the Devices API must not list envs")

    def page_group_envs(_group_id, _tenant_id, _opts),
      do: raise("the Devices API must not page envs")
  end

  setup %{conn: conn} do
    SalixStore.S3.Fake.reset()
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Acme", "slug" => "acme"})
    drain_all()
    %{conn: conn, user: user, org: org, project: project}
  end

  describe "page" do
    test "lists the Cloud VM and the projected devices with their system facts", %{
      conn: conn,
      org: org,
      project: project
    } do
      with_client(ProjectionOnlyClient)

      project_device(project, "device-mac", %{
        name: "Projected Mac",
        runtime_inventory: %{
          "items" => [codex_runtime("runtime-codex")],
          "system_info" => %{
            "hostname" => "studio.local",
            "os_type" => "macOS",
            "os_release" => "15.4",
            "cpu_model" => "Apple M2",
            "cpu_count" => 8,
            "memory_total" => 17_179_869_184
          }
        }
      })

      data = conn |> get(devices_path(org, project)) |> json_response(200) |> data()

      assert data["project"] == %{"id" => project.id, "name" => "Acme", "role" => "admin"}
      # No Cloud VM and no Runner yet: a new VM goes to Cloudflare.
      assert data["cloud_vm"] == %{
               "enabled" => true,
               "manageable" => true,
               "vm" => nil,
               "runner" => nil,
               "next_location" => %{"kind" => "cloudflare"},
               "runner_choosable" => true,
               "runner_removable" => false
             }

      assert data["provisioning"] == false

      assert [
               %{
                 "id" => "device-mac",
                 "name" => "Projected Mac",
                 "status" => "connected",
                 "disconnectable" => true,
                 "runtimes" => [
                   %{"id" => "runtime-codex", "provider" => "codex", "version" => "codex-test"}
                 ],
                 "host" => "studio.local",
                 "os" => "macOS 15.4",
                 "cpu_model" => "Apple M2",
                 "cpu_count" => 8,
                 "memory_bytes" => 17_179_869_184,
                 "last_seen_at" => last_seen,
                 "android" => nil,
                 "station_notice" => %{
                   "reason" => "device_needs_station",
                   "tasks" => nil,
                   "required_tasks" => 2,
                   "message" => message
                 }
               }
             ] = data["devices"]

      assert {:ok, _at, 0} = DateTime.from_iso8601(last_seen)
      assert message =~ "Comma desktop app"
    end

    test "costs the same queries for one device as for a hundred, and lists at most 100", %{
      conn: conn,
      org: org,
      project: project
    } do
      with_client(ProjectionOnlyClient)
      project_device(project, "device-0")
      conn |> get(devices_path(org, project)) |> json_response(200)
      small = query_count(conn, devices_path(org, project))

      for index <- 1..120, do: project_device(project, "device-#{index}")

      data = conn |> get(devices_path(org, project)) |> json_response(200) |> data()
      assert length(data["devices"]) == 100
      assert query_count(conn, devices_path(org, project)) == small
    end

    test "an org member without a grant, or an outsider, gets 404", %{org: org, project: project} do
      plain = user_fixture()
      {:ok, _} = Memberships.put_org_member(org.id, plain.id, "member")

      for path <- [devices_path(org, project), devices_path(org, project, "/provisioning")] do
        assert %{"error" => %{"code" => "project_not_found"}} =
                 build_conn() |> log_in_user(plain) |> get(path) |> json_response(404)

        assert %{"error" => %{"code" => "org_not_found"}} =
                 build_conn() |> log_in_user(user_fixture()) |> get(path) |> json_response(404)
      end
    end
  end

  describe "cloud computer" do
    test "an admin turns it off and on with audits", %{conn: conn, org: org, project: project} do
      assert %{"enabled" => false, "notice" => "Cloud computer disabled for this Agent Swarm."} =
               conn
               |> put(devices_path(org, project, "/cloud"), %{"enabled" => false})
               |> json_response(200)
               |> data()

      assert {:ok, %{vm_enabled: false}} = Projects.get_project(project.id)
      data = conn |> get(devices_path(org, project)) |> json_response(200) |> data()
      assert data["cloud_vm"]["enabled"] == false

      assert %{"enabled" => true} =
               conn
               |> put(devices_path(org, project, "/cloud"), %{"enabled" => true})
               |> json_response(200)
               |> data()

      assert {:ok, %{vm_enabled: true}} = Projects.get_project(project.id)

      assert length(Observability.list_audit_logs(org.id, action: "project.vm_enabled_changed")) ==
               2
    end

    test "a swarm member is refused with a denied audit; an archived swarm is refused", %{
      conn: conn,
      org: org,
      project: project
    } do
      {member_conn, member} = member_conn(org, project)

      assert %{"error" => %{"code" => "forbidden"}} =
               member_conn
               |> put(devices_path(org, project, "/cloud"), %{"enabled" => false})
               |> json_response(403)

      assert {:ok, %{vm_enabled: true}} = Projects.get_project(project.id)

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project.vm_enabled_changed",
                 result: "denied"
               )

      assert audit.actor_user_id == member.id

      assert %{"error" => %{"code" => "invalid_cloud"}} =
               conn
               |> put(devices_path(org, project, "/cloud"), %{"enabled" => "off"})
               |> json_response(422)

      Repo.update_all(
        from(p in BridgeForTeams.Schema.Project, where: p.id == ^project.id),
        set: [status: "archived"]
      )

      assert %{"error" => %{"code" => "project_archived"}} =
               conn
               |> put(devices_path(org, project, "/cloud"), %{"enabled" => false})
               |> json_response(409)
    end
  end

  describe "Cloud VM runner" do
    test "an admin chooses one org runner; a second one is refused until the first is removed",
         %{conn: conn, org: org, project: project} do
      lab = runner(org, "lab-mac", "Lab Mac mini", SystemsClock.utc_now())
      spare = runner(org, "spare-mac", "Spare Mac mini", SystemsClock.utc_now())
      choose = %{"runner_id" => lab.id, "request_id" => "choice-1"}

      assert %{"notice" => "The runner was asked to get ready for the Cloud VM."} =
               conn
               |> put(devices_path(org, project, "/cloud-vm/runner"), choose)
               |> json_response(200)
               |> data()

      # A retried request is the same choice.
      assert conn
             |> put(devices_path(org, project, "/cloud-vm/runner"), choose)
             |> json_response(200)

      data = conn |> get(devices_path(org, project)) |> json_response(200) |> data()

      assert %{
               "vm" => nil,
               "runner" => %{"name" => "Lab Mac mini", "status" => "processing"},
               # The Host is not installed yet, so a VM created now goes to Cloudflare.
               "next_location" => %{"kind" => "cloudflare"},
               "runner_choosable" => false,
               "runner_removable" => true
             } = data["cloud_vm"]

      assert %{"error" => %{"code" => "runner_already_chosen", "message" => message}} =
               conn
               |> put(devices_path(org, project, "/cloud-vm/runner"), %{
                 "runner_id" => spare.id,
                 "request_id" => "choice-2"
               })
               |> json_response(409)

      assert message =~ "already has a runner"

      assert %{"notice" => "Runner removed from this Agent Swarm."} =
               conn
               |> delete(devices_path(org, project, "/cloud-vm/runner"))
               |> json_response(200)
               |> data()

      assert conn
             |> put(devices_path(org, project, "/cloud-vm/runner"), %{
               "runner_id" => spare.id,
               "request_id" => "choice-2"
             })
             |> json_response(200)

      data = conn |> get(devices_path(org, project)) |> json_response(200) |> data()
      assert data["cloud_vm"]["runner"]["name"] == "Spare Mac mini"
    end

    test "an offline runner or a swarm member is refused", %{
      conn: conn,
      org: org,
      project: project
    } do
      stale = runner(org, "stale-mac", "Stale Mac mini", seconds_ago(90))

      assert %{"error" => %{"code" => "runner_offline"}} =
               conn
               |> put(devices_path(org, project, "/cloud-vm/runner"), %{
                 "runner_id" => stale.id,
                 "request_id" => "choice-1"
               })
               |> json_response(409)

      {member_conn, member} = member_conn(org, project)
      lab = runner(org, "lab-mac", "Lab Mac mini", SystemsClock.utc_now())

      assert %{"error" => %{"code" => "forbidden"}} =
               member_conn
               |> put(devices_path(org, project, "/cloud-vm/runner"), %{
                 "runner_id" => lab.id,
                 "request_id" => "choice-2"
               })
               |> json_response(403)

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "project.cloud_vm_runner_changed",
                 result: "denied"
               )

      assert audit.actor_user_id == member.id

      data = member_conn |> get(devices_path(org, project)) |> json_response(200) |> data()

      assert %{"manageable" => false, "runner" => nil, "runner_choosable" => false} =
               data["cloud_vm"]
    end
  end

  describe "add device" do
    test "offers online runners only and creates a request on one", %{
      conn: conn,
      org: org,
      project: project
    } do
      online = runner(org, "lab-mac", "Lab Mac mini", SystemsClock.utc_now())
      _stale = runner(org, "stale-mac", "Stale Mac mini", seconds_ago(90))

      assert %{
               "runners" => [%{"id" => id, "label" => "Lab Mac mini"}],
               "runners_href" => href
             } =
               conn |> get(devices_path(org, project, "/runners")) |> json_response(200) |> data()

      assert id == online.id
      assert href == "/orgs/#{org.slug}/fin"

      assert %{"notice" => "Device connection request created."} =
               conn
               |> post(devices_path(org, project), %{
                 "name" => "production",
                 "alias" => "prod-mac",
                 "runner_id" => online.id
               })
               |> json_response(201)
               |> data()

      assert [request] = Environments.list_device_provision_requests(project.id)
      assert request.provisioner_id == online.id
      assert request.salix_group_id == project.salix_group_id
      assert {:ok, []} = Environments.list_environments(project.id)

      # The page polls a cheap status until the runner has attached it.
      assert %{"active" => true} = provisioning(conn, org, project)

      assert %{"provisioning" => true} =
               conn |> get(devices_path(org, project)) |> json_response(200) |> data()

      small = query_count(conn, devices_path(org, project, "/provisioning"))

      Environments.update_device_provision_request_status(request, "failed", %{
        "failure_code" => "attach_timeout"
      })

      assert %{"active" => false} = provisioning(conn, org, project)
      assert query_count(conn, devices_path(org, project, "/provisioning")) == small
    end

    test "a stale, foreign or missing runner is refused", %{
      conn: conn,
      org: org,
      project: project
    } do
      stale = runner(org, "stale-mac", "Stale Mac mini", seconds_ago(90))
      other = org_with_owner_fixture().org
      foreign = runner(other, "foreign-mac", "Foreign Mac", SystemsClock.utc_now())

      for runner_id <- [stale.id, foreign.id, "not-a-runner"] do
        assert %{"error" => %{"code" => "runner_offline", "message" => "Runner is offline."}} =
                 conn
                 |> post(devices_path(org, project), %{"name" => "x", "runner_id" => runner_id})
                 |> json_response(409)
      end

      assert %{"error" => %{"code" => "runner_required"}} =
               conn |> post(devices_path(org, project), %{"name" => "x"}) |> json_response(422)

      assert Environments.list_device_provision_requests(project.id) == []
    end

    test "a swarm member cannot list runners or create; the attempt is audited", %{
      org: org,
      project: project
    } do
      {member_conn, member} = member_conn(org, project)
      online = runner(org, "lab-mac", "Lab Mac mini", SystemsClock.utc_now())

      assert %{"error" => %{"code" => "forbidden"}} =
               member_conn |> get(devices_path(org, project, "/runners")) |> json_response(403)

      assert %{"error" => %{"code" => "forbidden"}} =
               member_conn
               |> post(devices_path(org, project), %{"name" => "forged", "runner_id" => online.id})
               |> json_response(403)

      assert Environments.list_device_provision_requests(project.id) == []

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "device.provision_requested",
                 result: "denied"
               )

      assert audit.actor_user_id == member.id
      assert audit.resource_type == "device_provision_request"
      assert audit.reason_class == "forbidden"
      assert audit.metadata["project_id"] == project.id
      assert audit.metadata["surface"] == "device"
      assert audit.metadata["provisioner_id_configured"] in [true, "true"]
      refute inspect(audit) =~ "forged"
    end
  end

  describe "disconnect and delete" do
    test "an admin disconnects and deletes a live device with an audit", %{
      conn: conn,
      org: org,
      project: project
    } do
      device_id = "device-" <> SystemsRuntime.Proc.uuid()
      connect_device(org, project, device_id)

      data = conn |> get(devices_path(org, project)) |> json_response(200) |> data()
      assert [%{"id" => ^device_id, "name" => "staging-box"}] = data["devices"]

      assert %{"notice" => "Device disconnected."} =
               conn
               |> post(devices_path(org, project, "/#{device_id}/disconnect"))
               |> json_response(200)
               |> data()

      assert {:ok, %{"status" => "disconnected"}} =
               Environments.get_environment(project.id, device_id)

      assert %{"notice" => "Device deleted."} =
               conn
               |> delete(devices_path(org, project, "/#{device_id}"))
               |> json_response(200)
               |> data()

      assert {:error, :not_found} = Environments.get_environment(project.id, device_id)

      assert [audit] = Observability.list_audit_logs(org.id, action: "device.deleted")
      assert audit.result == "ok"
      assert audit.resource_id == device_id

      assert %{"error" => %{"code" => "device_not_found"}} =
               conn |> delete(devices_path(org, project, "/#{device_id}")) |> json_response(404)
    end

    test "a swarm member cannot disconnect or delete; the attempts are audited", %{
      org: org,
      project: project
    } do
      {member_conn, member} = member_conn(org, project)

      assert %{"error" => %{"code" => "forbidden"}} =
               member_conn
               |> delete(devices_path(org, project, "/forged-device"))
               |> json_response(403)

      assert %{"error" => %{"code" => "forbidden"}} =
               member_conn
               |> post(devices_path(org, project, "/forged-device/disconnect"))
               |> json_response(403)

      for action <- ~w(device.deleted device.disconnected) do
        assert [audit] = Observability.list_audit_logs(org.id, action: action, result: "denied")
        assert audit.actor_user_id == member.id
        assert audit.resource_type == "device"
        assert audit.metadata["device_id_configured"] in [true, "true"]
        refute inspect(audit) =~ "forged-device"
      end
    end
  end

  describe "Compute environments" do
    test "an admin creates a Shell workload and drains the environment", %{
      conn: conn,
      org: org,
      project: project
    } do
      environment = compute_environment(org, project)

      data = conn |> get(devices_path(org, project)) |> json_response(200) |> data()

      assert %{
               "status" => "ok",
               "environments" => [%{"id" => id, "desired_state" => "ready"}],
               "workloads" => []
             } = data["compute"]

      assert id == environment.id
      refute Jason.encode!(data) =~ "agent_vmm"

      assert %{"notice" => "Shell workload accepted. Refresh to check its runtime status."} =
               conn
               |> post(compute_path(org, project, environment.id, "/shell"))
               |> json_response(201)
               |> data()

      data = conn |> get(devices_path(org, project)) |> json_response(200) |> data()
      assert [%{"kind" => "shell"}] = data["compute"]["workloads"]
      assert [%{"revision" => revision}] = data["compute"]["environments"]

      assert %{"error" => %{"code" => "environment_not_found"}} =
               conn
               |> post(compute_path(org, project, "foreign-environment", "/shell"))
               |> json_response(404)

      # The drain carries the revision the page showed; a stale one is refused.
      assert %{"error" => %{"code" => "environment_changed"}} =
               conn
               |> post(compute_path(org, project, environment.id, "/drain"), %{
                 "expected_revision" => revision + 5
               })
               |> json_response(409)

      assert %{"notice" => "Compute environment updated."} =
               conn
               |> post(compute_path(org, project, environment.id, "/drain"), %{
                 "expected_revision" => revision
               })
               |> json_response(200)
               |> data()

      data = conn |> get(devices_path(org, project)) |> json_response(200) |> data()
      assert [%{"desired_state" => "draining"}] = data["compute"]["environments"]
    end

    test "a swarm member reads the environments but cannot change them", %{
      org: org,
      project: project
    } do
      environment = compute_environment(org, project)
      {member_conn, _member} = member_conn(org, project)

      data = member_conn |> get(devices_path(org, project)) |> json_response(200) |> data()
      assert [%{"id" => id}] = data["compute"]["environments"]
      assert id == environment.id

      for {path, body} <- [
            {"/shell", %{}},
            {"/drain", %{"expected_revision" => 1}},
            {"/revoke", %{"expected_revision" => 1}}
          ] do
        assert %{"error" => %{"code" => "forbidden"}} =
                 member_conn
                 |> post(compute_path(org, project, environment.id, path), body)
                 |> json_response(403)
      end

      data = member_conn |> get(devices_path(org, project)) |> json_response(200) |> data()
      assert [%{"desired_state" => "ready"}] = data["compute"]["environments"]
    end
  end

  defp devices_path(org, project, rest \\ ""),
    do: "/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}/devices#{rest}"

  defp compute_path(org, project, environment, rest),
    do: "/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}/compute/#{environment}#{rest}"

  defp provisioning(conn, org, project),
    do: conn |> get(devices_path(org, project, "/provisioning")) |> json_response(200) |> data()

  defp data(%{"data" => data}), do: data

  defp member_conn(org, project) do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, member.id, "user")
    {log_in_user(build_conn(), member), member}
  end

  defp runner(org, stable_id, name, last_seen_at) do
    {:ok, runner} =
      Environments.register_mac_mini_provisioner(org.id, %{
        "stable_id" => stable_id,
        "name" => name,
        "status" => "online"
      })

    Repo.update_all(
      from(p in MacMiniProvisioner, where: p.id == ^runner.id),
      set: [last_seen_at: last_seen_at]
    )

    runner
  end

  defp seconds_ago(seconds), do: DateTime.add(SystemsClock.utc_now(), -seconds, :second)

  defp project_device(project, device_id, attrs \\ %{}) do
    %ProjectDeviceProjection{}
    |> ProjectDeviceProjection.changeset(
      Map.merge(
        %{
          project_id: project.id,
          device_id: device_id,
          connector_run_id: "run-#{device_id}",
          connector_id: "connector-#{device_id}",
          name: device_id,
          status: "connected",
          source_updated_at: SystemsClock.system_time(:millisecond),
          observed_generation: 1,
          runtime_inventory: %{"items" => []}
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp codex_runtime(device_runtime_id) do
    %{
      "provider" => "codex",
      "runtime_id" => "codex",
      "device_runtime_id" => device_runtime_id,
      "version" => "codex-test",
      "status" => "available"
    }
  end

  defp connect_device(org, project, device_id) do
    {:ok, _transport_id, _record} =
      SalixEnv.Registry.connect(
        "nonode@nohost",
        %{
          "tenant_id" => org.salix_tenant_id,
          "group_id" => project.salix_group_id,
          "device_id" => device_id,
          "connector_id" => "connector-" <> device_id,
          "name" => "staging-box"
        },
        transport_id: "transport-" <> device_id
      )

    refresh_device_projection(project.id, device_id, 20)
  end

  defp refresh_device_projection(_project_id, _device_id, 0),
    do: flunk("device projection did not converge")

  defp refresh_device_projection(project_id, device_id, attempts) do
    assert {:ok, _result} = Environments.reconcile_device_projection(projection_page_limit: 100)

    unless Repo.get_by(ProjectDeviceProjection, project_id: project_id, device_id: device_id),
      do: refresh_device_projection(project_id, device_id, attempts - 1)
  end

  defp compute_environment(org, project) do
    previous = SystemsRuntime.get_env(:salix_store, :runtime_bundle_root)

    SystemsRuntime.put_env(
      :salix_store,
      :runtime_bundle_root,
      Path.expand("../../salix_store/test/fixtures/runtime-bundle", __DIR__)
    )

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_store, :runtime_bundle_root, previous),
        else: SystemsRuntime.delete_env(:salix_store, :runtime_bundle_root)
    end)

    suffix = SystemsRuntime.Proc.unique_integer([:positive])

    {:ok, pool} =
      SalixStore.Compute.create_pool(%{
        id: "devices-pool-#{suffix}",
        tenant_id: org.salix_tenant_id,
        name: "project compute",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec"]
      })

    {:ok, environment} =
      SalixStore.Compute.create_environment(%{
        id: "devices-environment-#{suffix}",
        tenant_id: org.salix_tenant_id,
        owner_type: "project",
        owner_id: project.id,
        pool_id: pool.id
      })

    # Availability is a projection; the exact host retains enrollment authority.
    {:ok, registration} =
      SalixStore.AgentVMM.create_registration(%{
        id: "devices-host-#{suffix}",
        tenant_id: org.salix_tenant_id,
        group_id: project.salix_group_id,
        device_id: "devices-host-device-#{suffix}",
        enrollment_token: String.duplicate("s", 32),
        desired_enabled: true
      })

    registration
    |> Ecto.Changeset.change(status: "ready")
    |> SalixStore.Repo.update!()

    SalixStore.Repo.insert!(%SalixStore.Compute.ProviderBinding{
      id: "devices-binding-#{suffix}",
      pool_id: pool.id,
      environment_id: environment.id,
      provider: "agent_vmm",
      provider_ref: registration.id,
      status: "available",
      generation: 1,
      revision: 1,
      observation: %{},
      updated_at: SystemsClock.utc_now()
    })

    environment
  end

  defp put_env(key, value) do
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, key)
    SystemsRuntime.put_env(:bridge_for_teams_core, key, value)

    on_exit(fn ->
      if is_nil(previous),
        do: SystemsRuntime.delete_env(:bridge_for_teams_core, key),
        else: SystemsRuntime.put_env(:bridge_for_teams_core, key, previous)
    end)
  end

  defp with_client(client), do: put_env(:salix_client, client)

  defp drain_all do
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp query_count(conn, path) do
    test_pid = SystemsRuntime.Proc.self()
    handler = "devices-query-count-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:bridge_for_teams, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if SystemsRuntime.Proc.self() == test_pid,
            do: SystemsRuntime.Proc.send(test_pid, :repo_query)
        end,
        nil
      )

    try do
      conn |> get(path) |> json_response(200)
      count_messages(0)
    after
      SystemsRuntime.Telemetry.detach(handler)
    end
  end

  defp count_messages(count) do
    SystemsRuntime.Proc.receive do
      :repo_query -> count_messages(count + 1)
    after
      0 -> count
    end
  end
end
