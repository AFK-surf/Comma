defmodule BridgeForTeams.EnvironmentsTest do
  require SystemsRuntime.Proc

  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{
    Accounts,
    Environments,
    Memberships,
    Observability,
    Orgs,
    Projects
  }

  alias BridgeForTeams.EnvironmentProvisioning.Reconciler, as: ProvisioningReconciler
  alias BridgeForTeams.Schema.{EnvironmentProvisionRequest, MacMiniProvisioner}
  alias SalixStore.RuntimeIds

  @device_runtime_id RuntimeIds.device_runtime_id("device-codex", "codex", "runtime-codex")

  defmodule ProvisioningProbeClient do
    @moduledoc false

    def list_group_envs(group_id, tenant_id) do
      %{test_pid: test_pid, list_result: result} =
        SystemsRuntime.fetch_env!(:bridge_for_teams_core, :provisioning_probe)

      SystemsRuntime.Proc.send(test_pid, {:list_group_envs, group_id, tenant_id})
      result
    end

    def page_group_envs(group_id, tenant_id, opts) do
      %{test_pid: test_pid, page_result: result} =
        SystemsRuntime.fetch_env!(:bridge_for_teams_core, :provisioning_probe)

      SystemsRuntime.Proc.send(test_pid, {:page_group_envs, group_id, tenant_id, opts})
      result
    end
  end

  defmodule BlockingProjectionClient do
    @moduledoc false

    def list_group_envs(group_id, tenant_id) do
      config = SystemsRuntime.fetch_env!(:bridge_for_teams_core, :projection_blocking_probe)
      test_pid = if is_map(config), do: config.test_pid, else: config
      result = if is_map(config), do: config.list_result, else: {:ok, []}

      SystemsRuntime.Proc.send(
        test_pid,
        {:provision_list_started, SystemsRuntime.Proc.self(), group_id, tenant_id}
      )

      result
    end

    def page_group_envs(group_id, tenant_id, opts) do
      config = SystemsRuntime.fetch_env!(:bridge_for_teams_core, :projection_blocking_probe)
      test_pid = if is_map(config), do: config.test_pid, else: config

      SystemsRuntime.Proc.send(
        test_pid,
        {:projection_page_started, SystemsRuntime.Proc.self(), group_id, tenant_id, opts}
      )

      SystemsRuntime.Proc.receive do
        {:release_projection_page, result} -> result
      after
        5_000 -> {:error, :projection_probe_timeout}
      end
    end
  end

  defmodule RuntimeAuthClient do
    @moduledoc false

    def runtime_auth_read(device_id, device_runtime_id, group_id, tenant_id) do
      dispatch(:read, [device_id, device_runtime_id, group_id, tenant_id])
    end

    def runtime_auth_login_start(device_id, device_runtime_id, flow, group_id, tenant_id) do
      dispatch(:start, [device_id, device_runtime_id, flow, group_id, tenant_id])
    end

    def runtime_auth_login_cancel(
          device_id,
          device_runtime_id,
          attempt_id,
          group_id,
          tenant_id
        ) do
      dispatch(:cancel, [device_id, device_runtime_id, attempt_id, group_id, tenant_id])
    end

    defp dispatch(operation, args) do
      %{test_pid: test_pid, results: results} =
        SystemsRuntime.fetch_env!(:bridge_for_teams_core, :runtime_auth_probe)

      SystemsRuntime.Proc.send(test_pid, {:runtime_auth_call, operation, args})
      Map.fetch!(results, operation)
    end
  end

  setup do
    SalixStore.S3.Fake.reset()
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
    {:ok, project} = Projects.create_project(org.id, %{name: "P", slug: "p"})
    drain_all()
    %{org: org, project: project}
  end

  defp drain_all do
    case BridgeForTeams.Salix.Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp restore_env(key, nil),
    do: SystemsRuntime.delete_env(:bridge_for_teams_core, key)

  defp restore_env(key, value),
    do: SystemsRuntime.put_env(:bridge_for_teams_core, key, value)

  # Salix is the source of truth: connect one stable group device with a
  # replaceable current connector run.
  defp register_env(project, name, status, meta \\ %{}) do
    org = BridgeForTeams.Repo.get!(BridgeForTeams.Schema.Organization, project.org_id)
    device_id = meta["device_id"] || SalixStore.Ids.new_device_id()

    connector_id =
      meta["connector_id"] || "connector-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _transport_id, record} =
      SalixEnv.Registry.connect(
        "nonode@nohost",
        Map.merge(
          %{
            "tenant_id" => org.salix_tenant_id,
            "group_id" => project.salix_group_id,
            "device_id" => device_id,
            "connector_id" => connector_id,
            "name" => name
          },
          meta
        )
      )

    if status == "disconnected" do
      {:ok, _} = SalixEnv.Registry.mark_disconnected(record["connector_run_id"])
    end

    %{
      device_id: device_id,
      connector_run_id: record["connector_run_id"],
      connector_id: connector_id
    }
  end

  defp environment_runtime_events(org_id, env_id) do
    org_id
    |> Observability.list_events(
      domain: "device",
      resource_type: "salix_device_connector",
      resource_id: env_id,
      source: "salix.env",
      limit: 20
    )
    |> Enum.filter(
      &(&1.event_type in ~w(device.runtime.observed device.runtime.disconnected device.runtime.degraded device.runtime.recovered))
    )
  end

  test "register_mac_mini_provisioner upserts org-scoped heartbeat", %{org: org} do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "mac-mini-1",
               "name" => "Lab Mac mini",
               "host_identity" => "host-a",
               "capabilities" => %{"fin" => true}
             })

    assert provisioner.status == "online"
    assert provisioner.last_seen_at

    assert {:ok, updated} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "mac-mini-1",
               "name" => "Lab Mac mini M2",
               "status" => "degraded"
             })

    assert updated.id == provisioner.id
    assert updated.name == "Lab Mac mini M2"
    assert updated.status == "degraded"

    assert [listed] = Environments.list_mac_mini_provisioners(org.id)
    assert listed.id == provisioner.id
    assert listed.effective_status == "degraded"
  end

  test "create_device_provision_request binds project group and provisioner", %{
    org: org,
    project: project
  } do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "mac-mini-1",
               "name" => "Lab Mac mini",
               "capabilities" => %{"fin" => true}
             })

    assert {:ok, request} =
             Environments.create_device_provision_request(
               project.id,
               %{
                 "provisioner_id" => provisioner.id,
                 "name" => "production",
                 "alias" => "prod-mac"
               },
               actor_label: "project-admin@example.com",
               request_id: "req_env_provision"
             )

    assert request.org_id == org.id
    assert request.project_id == project.id
    assert request.provisioner_id == provisioner.id
    assert request.salix_group_id == project.salix_group_id
    assert request.name == "production"
    assert request.env_alias == "prod-mac"
    assert request.status == "pending"
    assert request.connector_token_hash == nil

    assert [listed] = Environments.list_device_provision_requests(project.id)
    assert listed.id == request.id
    assert listed.provisioner.id == provisioner.id

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "device.provision_requested")

    assert audit.result == "ok"
    assert audit.request_id == "req_env_provision"
    assert audit.resource_type == "device_provision_request"
    assert audit.resource_id == request.id
    assert audit.metadata["project_id"] == project.id
    assert audit.metadata["provisioner_id"] == provisioner.id
  end

  test "runner connector assignment queries are bounded, paginated, and ACL-scoped", %{
    org: org,
    project: project
  } do
    assert {:ok, first_runner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "connector-runner-1",
               "name" => "Connector Runner 1"
             })

    assert {:ok, second_runner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "connector-runner-2",
               "name" => "Connector Runner 2"
             })

    assert {:ok, second_project} =
             Projects.create_project(org.id, %{name: "Second Project", slug: "second-project"})

    assert {:ok, pending} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => first_runner.id,
               "name" => "Pending connector",
               "alias" => "pending-connector"
             })

    assert {:ok, connected_request} =
             Environments.create_device_provision_request(second_project.id, %{
               "provisioner_id" => second_runner.id,
               "name" => "Connected connector",
               "alias" => "connected-connector"
             })

    assert {:ok, connected} =
             Environments.update_device_provision_request_status(
               connected_request,
               "connected",
               %{"connector_run_id" => "connector-run-2"}
             )

    assert {:ok, stopped_request} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => first_runner.id,
               "name" => "Stopped connector"
             })

    assert {:ok, stopped} =
             Environments.update_device_provision_request_status(stopped_request, "stopped")

    assert {:ok, failed_request} =
             Environments.create_device_provision_request(second_project.id, %{
               "provisioner_id" => second_runner.id,
               "name" => "Failed connector",
               "alias" => "failed-connector"
             })

    assert {:ok, failed} =
             Environments.update_device_provision_request_status(failed_request, "failed")

    unique = SystemsRuntime.Proc.unique_integer([:positive])
    assert {:ok, owner} = Accounts.create_user(%{email: "connector-owner-#{unique}@example.com"})
    assert {:ok, _} = Memberships.put_org_member(org.id, owner.id, "owner")

    assert {:ok, member} =
             Accounts.create_user(%{email: "connector-member-#{unique}@example.com"})

    assert {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    assert {:ok, _} = Memberships.put_project_member(second_project.id, member.id, "user")

    assert %{first_runner.id => [{"pending", 1}, {"stopped", 1}]} ==
             Environments.runner_connector_assignment_status_counts(
               org.id,
               [first_runner.id],
               owner.id
             )

    assert %{second_runner.id => [{"connected", 1}, {"failed", 1}]} ==
             Environments.runner_connector_assignment_status_counts(
               org.id,
               [first_runner.id, second_runner.id],
               member.id
             )

    assert %{entries: [], next_cursor: nil} =
             Environments.page_runner_connector_assignments(
               org.id,
               first_runner.id,
               member.id
             )

    assert %{entries: [first_entry], next_cursor: cursor} =
             Environments.page_runner_connector_assignments(
               org.id,
               second_runner.id,
               member.id,
               limit: 1
             )

    assert is_binary(cursor)

    assert %{entries: [second_entry], next_cursor: nil} =
             Environments.page_runner_connector_assignments(
               org.id,
               second_runner.id,
               member.id,
               limit: 1,
               after: cursor
             )

    assert MapSet.new([first_entry.id, second_entry.id]) == MapSet.new([connected.id, failed.id])
    assert Enum.all?([first_entry, second_entry], &(&1.project_name == second_project.name))
    refute pending.id in [first_entry.id, second_entry.id]
    refute stopped.id in [first_entry.id, second_entry.id]
  end

  test "device provision lifecycle records Operations run and events without raw progress",
       %{
         org: org,
         project: project
       } do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "mac-mini-observable",
               "name" => "Observable Mac mini"
             })

    assert {:ok, request} =
             Environments.create_device_provision_request(
               project.id,
               %{
                 "provisioner_id" => provisioner.id,
                 "name" => "production",
                 "alias" => "prod"
               },
               request_id: "req-env-created"
             )

    assert [created_run] =
             Observability.list_operation_runs(org.id,
               run_type: "device_provision",
               external_run_id: request.id
             )

    assert created_run.status == "pending"
    assert created_run.runner_type == "mac_mini_provisioner"
    assert created_run.runner_id == provisioner.id
    assert created_run.evidence["provision_request_id"] == request.id
    assert created_run.evidence["request_id"] == "req-env-created"

    assert {:ok, %{request: claimed}} =
             Environments.claim_device_provision_request(org.id, provisioner.id, %{
               "request_id" => "req-env-claimed"
             })

    assert claimed.id == request.id
    assert claimed.status == "preflight"

    assert {:ok, starting} =
             Environments.update_device_provision_request_from_provisioner(
               org.id,
               provisioner.id,
               request.id,
               "starting_connector",
               %{"progress" => %{"stage" => "starting_connector"}},
               request_id: "req-env-starting"
             )

    assert starting.status == "starting_connector"

    assert {:ok, waiting} =
             Environments.update_device_provision_request_from_provisioner(
               org.id,
               provisioner.id,
               request.id,
               "waiting_for_attach",
               %{
                 "progress" => %{
                   "stage" => "waiting_for_attach",
                   "restart_count" => 1,
                   "root" => "/private/tmp/customer-root",
                   "stdout" => "raw stdout must stay local",
                   "raw_token" => "salix_conn_secret",
                   "launch" => %{
                     "argv" => ["salix-connect", "--connector-token", "salix_conn_secret"],
                     "argv_shape" => ["salix-connect", "--connector-token", "<token>"]
                   }
                 }
               },
               request_id: "req-env-waiting"
             )

    assert waiting.status == "waiting_for_attach"

    assert {:ok, failed} =
             Environments.update_device_provision_request_from_provisioner(
               org.id,
               provisioner.id,
               request.id,
               "failed",
               %{
                 "failure_code" => "connector.start_failed",
                 "failure_message" => "salix-connect could not be started",
                 "progress" => %{
                   "stage" => "connector_start_failed",
                   "exit_code" => 1,
                   "stdout" => "final stdout must stay local"
                 }
               },
               request_id: "req-env-failed"
             )

    assert failed.status == "failed"

    assert [run] =
             Observability.list_operation_runs(org.id,
               run_type: "device_provision",
               external_run_id: request.id
             )

    assert run.id == created_run.id
    assert run.status == "failed"
    assert run.reason_class == "connector.start_failed"
    assert run.finished_at
    assert run.evidence["request_id"] == "req-env-failed"
    assert run.evidence["progress"]["stage"] == "connector_start_failed"
    refute inspect(run.evidence) =~ "salix_conn_secret"
    refute inspect(run.evidence) =~ "/private/tmp/customer-root"
    refute inspect(run.evidence) =~ "stdout must stay local"

    events =
      Observability.list_events(org.id,
        resource_type: "device_provision_request",
        resource_id: request.id
      )

    event_types = Enum.map(events, & &1.event_type) |> Enum.sort()

    assert event_types == [
             "device.provision.claimed",
             "device.provision.connector_starting",
             "device.provision.created",
             "device.provision.failed",
             "device.provision.preflight",
             "device.provision.waiting_for_attach"
           ]

    failed_event = Enum.find(events, &(&1.event_type == "device.provision.failed"))
    assert failed_event.run_record_id == run.id
    assert failed_event.severity == "error"
    assert failed_event.status == "failed"
    assert failed_event.reason_class == "connector.start_failed"
    assert failed_event.evidence["request_id"] == "req-env-failed"

    created_event = Enum.find(events, &(&1.event_type == "device.provision.created"))
    assert created_event.evidence["request_id"] == "req-env-created"

    claimed_event = Enum.find(events, &(&1.event_type == "device.provision.claimed"))
    assert claimed_event.evidence["request_id"] == "req-env-claimed"

    preflight_event = Enum.find(events, &(&1.event_type == "device.provision.preflight"))
    assert preflight_event.evidence["request_id"] == "req-env-claimed"

    starting_event =
      Enum.find(events, &(&1.event_type == "device.provision.connector_starting"))

    assert starting_event.evidence["request_id"] == "req-env-starting"

    waiting_event =
      Enum.find(events, &(&1.event_type == "device.provision.waiting_for_attach"))

    assert waiting_event.evidence["request_id"] == "req-env-waiting"
  end

  test "create_device_provision_request rejects another org provisioner", %{
    project: project
  } do
    {:ok, other_org} = Orgs.create_org(%{name: "Other", slug: "other"})

    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(other_org.id, %{
               "stable_id" => "mac-mini-1",
               "name" => "Other Mac mini"
             })

    assert {:error, :provisioner_not_found} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner.id,
               "name" => "production"
             })
  end

  test "update_device_provision_request_status advances the state machine", %{
    org: org,
    project: project
  } do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "mac-mini-1",
               "name" => "Lab Mac mini"
             })

    assert {:ok, request} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner.id,
               "name" => "production"
             })

    assert {:ok, waiting} =
             Environments.update_device_provision_request_status(
               request,
               "waiting_for_attach",
               %{"connector_token_hash" => "hash-only"}
             )

    assert waiting.status == "waiting_for_attach"
    assert waiting.connector_token_hash == "hash-only"

    assert {:ok, failed} =
             Environments.update_device_provision_request_status(
               waiting.id,
               "failed",
               %{"failure_code" => "preflight.salix_connect_not_executable"}
             )

    assert failed.status == "failed"
    assert failed.failure_code == "preflight.salix_connect_not_executable"
  end

  test "stop request is claimed before new create work even at capacity", %{
    org: org,
    project: project
  } do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "mac-mini-1",
               "name" => "Lab Mac mini"
             })

    assert {:ok, stop_request} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner.id,
               "name" => "production",
               "alias" => "prod"
             })

    assert {:ok, connected} =
             Environments.update_device_provision_request_status(
               stop_request,
               "connected",
               %{"connector_run_id" => "env_prod"}
             )

    assert {:ok, stop_requested} =
             Environments.request_device_provision_stop(
               project.id,
               connected.id,
               actor_label: "project-admin@example.com",
               request_id: "req_env_stop"
             )

    assert stop_requested.status == "stop_requested"

    assert [audit] = Observability.list_audit_logs(org.id, action: "device.stop_requested")
    assert audit.result == "ok"
    assert audit.request_id == "req_env_stop"
    assert audit.resource_type == "device_provision_request"
    assert audit.resource_id == connected.id

    assert {:ok, _pending_create} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner.id,
               "name" => "next-env"
             })

    assert {:ok, %{action: "stop", request: stopping, connect: %{}, launch: launch}} =
             Environments.claim_device_provision_request(org.id, provisioner.id, %{
               "available_capacity" => 0
             })

    assert stopping.id == stop_request.id
    assert stopping.status == "stopping"
    assert launch["provision_request_id"] == stop_request.id
    assert launch["connector_run_id"] == "env_prod"

    assert {:ok, stopped} =
             Environments.update_device_provision_request_from_provisioner(
               org.id,
               provisioner.id,
               stop_request.id,
               "stopped",
               %{}
             )

    assert stopped.status == "stopped"

    assert [run] =
             Observability.list_operation_runs(org.id,
               run_type: "device_provision",
               external_run_id: stop_request.id
             )

    assert run.status == "ok"
    assert run.finished_at

    events =
      Observability.list_events(org.id,
        resource_type: "device_provision_request",
        resource_id: stop_request.id
      )
      |> Enum.reject(&(&1.domain == "audit"))

    assert Enum.map(events, & &1.event_type) |> Enum.sort() == [
             "device.provision.connected",
             "device.provision.created",
             "device.provision.stop_requested",
             "device.provision.stopped",
             "device.provision.stopping"
           ]

    stopped_event = Enum.find(events, &(&1.event_type == "device.provision.stopped"))
    assert stopped_event.source == "bft.provisioner_api"
    assert stopped_event.run_record_id == run.id
  end

  test "provisioner status callbacks cannot spoof connected attach", %{
    org: org,
    project: project
  } do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "mac-mini-1",
               "name" => "Lab Mac mini"
             })

    assert {:ok, request} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner.id,
               "name" => "prod-env"
             })

    assert {:ok, %{request: claimed}} =
             Environments.claim_device_provision_request(org.id, provisioner.id)

    assert claimed.status == "preflight"

    assert {:error, :unsupported_provisioner_status} =
             Environments.update_device_provision_request_from_provisioner(
               org.id,
               provisioner.id,
               request.id,
               "connected",
               %{"connector_run_id" => "env_spoofed"}
             )

    assert {:ok, waiting} =
             Environments.update_device_provision_request_from_provisioner(
               org.id,
               provisioner.id,
               request.id,
               "waiting_for_attach",
               %{"connector_run_id" => "env_spoofed"}
             )

    assert waiting.status == "waiting_for_attach"
    assert waiting.connector_run_id == nil
  end

  test "device request list is bounded PG-only and the worker reconciles Salix attach", %{
    org: org,
    project: project
  } do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "mac-mini-1",
               "name" => "Lab Mac mini"
             })

    assert {:ok, request} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner.id,
               "name" => "production",
               "alias" => "prod-mac"
             })

    assert {:ok, waiting} =
             Environments.update_device_provision_request_status(
               request,
               "waiting_for_attach",
               %{}
             )

    previous_client = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    previous_probe = SystemsRuntime.get_env(:bridge_for_teams_core, :provisioning_probe)

    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, ProvisioningProbeClient)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :provisioning_probe,
      %{
        test_pid: SystemsRuntime.Proc.self(),
        list_result:
          {:ok,
           [
             %{
               "status" => "connected",
               "connector_run_id" => "connector-run-projected",
               "provision_request_id" => waiting.id
             }
           ]},
        page_result:
          {:ok,
           %{
             records: [
               %{
                 "device_id" => "device-projected",
                 "status" => "connected",
                 "connector_run_id" => "connector-run-projected",
                 "device_runtimes" => []
               }
             ],
             next_cursor: nil
           }}
      }
    )

    on_exit(fn ->
      if previous_client,
        do: SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous_client),
        else: SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)

      if previous_probe,
        do: SystemsRuntime.put_env(:bridge_for_teams_core, :provisioning_probe, previous_probe),
        else: SystemsRuntime.delete_env(:bridge_for_teams_core, :provisioning_probe)
    end)

    assert [projected] =
             Environments.list_device_provision_requests(project.id, limit: 1)

    assert projected.id == waiting.id
    assert projected.status == "waiting_for_attach"
    refute_receive {:list_group_envs, _, _}
    refute_receive {:page_group_envs, _, _, _}

    assert {:ok, %{scanned: 1, checked_groups: 1, connected: 1, timed_out: 0, projected: 1}} =
             ProvisioningReconciler.drain_once(limit: 1)

    assert_receive {:list_group_envs, group_id, tenant_id}
    assert group_id == project.salix_group_id
    assert tenant_id == org.salix_tenant_id
    assert_receive {:page_group_envs, ^group_id, ^tenant_id, opts}
    assert opts[:limit] == 50
    assert opts[:cursor] == nil

    assert [connected] =
             Environments.list_device_provision_requests(project.id, limit: 1)

    assert connected.id == waiting.id
    assert connected.status == "connected"
    assert connected.connector_run_id == "connector-run-projected"
    assert connected.provisioner.id == provisioner.id
    refute_receive {:list_group_envs, _, _}
    refute_receive {:page_group_envs, _, _, _}

    assert {:ok, [%{"device_id" => "device-projected"}]} =
             Environments.list_projected_environments(project.id, limit: 1)

    assert {:ok, persisted} = Environments.get_device_provision_request(waiting.id)
    assert persisted.status == "connected"
    assert persisted.connector_run_id == "connector-run-projected"
  end

  test "list_environments reads the worker-owned PostgreSQL projection", %{
    org: org,
    project: project
  } do
    a = register_env(project, "box-a", "connected")
    b = register_env(project, "box-b", "disconnected")
    refresh_device_projection!()

    assert {:ok, envs} = Environments.list_environments(project.id)
    by_id = Map.new(envs, &{&1["device_id"], &1})

    assert by_id[a.device_id]["status"] == "connected"
    assert by_id[a.device_id]["connector_run_id"] == a.connector_run_id
    assert by_id[a.device_id]["name"] == "box-a"
    assert by_id[b.device_id]["status"] == "disconnected"
    assert by_id[b.device_id]["connector_run_id"] == nil

    assert [connected_event] = environment_runtime_events(org.id, a.connector_run_id)
    assert connected_event.event_type == "device.runtime.observed"
    assert connected_event.status == "connected"
    assert connected_event.severity == "info"
    assert connected_event.project_id == project.id
    assert connected_event.evidence["connector_run_id"] == a.connector_run_id
    assert connected_event.evidence["group_id"] == project.salix_group_id
    assert connected_event.evidence["device_name"] == "box-a"

    assert environment_runtime_events(org.id, b.connector_run_id) == []
  end

  test "project runtime auth uses authoritative scope and strips non-start ceremony fields", %{
    org: org,
    project: project
  } do
    now = SystemsClock.system_time(:millisecond)
    previous_client = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    previous_probe = SystemsRuntime.get_env(:bridge_for_teams_core, :runtime_auth_probe)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, RuntimeAuthClient)

    on_exit(fn ->
      restore_env(:salix_client, previous_client)
      restore_env(:runtime_auth_probe, previous_probe)
    end)

    auth = %{
      "schema_version" => 1,
      "status" => "unauthenticated",
      "mode" => "chatgpt",
      "requires_openai_auth" => true,
      "observed_at" => 1_787_020_000_000
    }

    ceremony = %{
      "attempt_id" => "rta_project",
      "flow" => "device_code",
      "verification_url" => "https://auth.openai.com/codex/device",
      "user_code" => "ABCD-EFGH",
      "expires_at" => now + 900_000,
      "reused" => false,
      "auth" => Map.put(auth, "status", "pending")
    }

    SystemsRuntime.put_env(:bridge_for_teams_core, :runtime_auth_probe, %{
      test_pid: SystemsRuntime.Proc.self(),
      results: %{
        read:
          {:ok,
           %{
             "auth" => auth,
             "attempt_id" => "rta_project",
             "flow" => "device_code",
             "expires_at" => ceremony["expires_at"]
           }},
        start: {:ok, ceremony},
        cancel:
          {:ok,
           %{
             "attempt_id" => "rta_project",
             "canceled" => true,
             "auth" => auth
           }}
      }
    })

    group_id = project.salix_group_id
    tenant_id = org.salix_tenant_id

    assert {:ok, %{"auth" => ^auth}} =
             Environments.read_runtime_auth(project.id, "device-codex", @device_runtime_id)

    assert_receive {:runtime_auth_call, :read,
                    [
                      "device-codex",
                      @device_runtime_id,
                      ^group_id,
                      ^tenant_id
                    ]}

    assert {:ok, ^ceremony} =
             Environments.start_runtime_login(
               project.id,
               "device-codex",
               @device_runtime_id,
               "device_code",
               actor_label: "project-admin@example.com",
               request_id: "req_runtime_auth_start"
             )

    assert_receive {:runtime_auth_call, :start,
                    [
                      "device-codex",
                      @device_runtime_id,
                      "device_code",
                      ^group_id,
                      ^tenant_id
                    ]}

    assert {:ok, %{"canceled" => true, "auth" => ^auth}} =
             Environments.cancel_runtime_login(
               project.id,
               "device-codex",
               @device_runtime_id,
               "rta_project",
               actor_label: "project-admin@example.com",
               request_id: "req_runtime_auth_cancel"
             )

    assert_receive {:runtime_auth_call, :cancel,
                    [
                      "device-codex",
                      @device_runtime_id,
                      "rta_project",
                      ^group_id,
                      ^tenant_id
                    ]}

    assert [start_audit] =
             Observability.list_audit_logs(org.id,
               action: "device.runtime_auth_login_started"
             )

    assert start_audit.result == "ok"
    assert start_audit.request_id == "req_runtime_auth_start"
    assert start_audit.resource_type == "device_runtime"
    assert start_audit.resource_id == @device_runtime_id

    assert start_audit.metadata == %{
             "project_id" => project.id,
             "device_id" => "device-codex",
             "device_runtime_id" => @device_runtime_id,
             "device_id_configured" => "true",
             "device_runtime_id_configured" => "true",
             "provider" => "codex",
             "flow" => "device_code",
             "flow_configured" => "true",
             "reused" => "false"
           }

    assert [cancel_audit] =
             Observability.list_audit_logs(org.id,
               action: "device.runtime_auth_login_canceled"
             )

    assert cancel_audit.result == "ok"
    assert cancel_audit.request_id == "req_runtime_auth_cancel"

    assert cancel_audit.metadata == %{
             "project_id" => project.id,
             "device_id" => "device-codex",
             "device_runtime_id" => @device_runtime_id,
             "device_id_configured" => "true",
             "device_runtime_id_configured" => "true",
             "provider" => "codex",
             "flow" => "device_code",
             "attempt_configured" => "true",
             "canceled" => "true"
           }

    audit_payload = Jason.encode!([start_audit.metadata, cancel_audit.metadata])
    refute audit_payload =~ "rta_project"
    refute audit_payload =~ "auth.openai.com"
    refute audit_payload =~ "ABCD-EFGH"

    assert {:error, :not_found} =
             Environments.read_runtime_auth(
               SystemsRuntime.Proc.uuid(),
               "device-codex",
               @device_runtime_id
             )

    refute_receive {:runtime_auth_call, _, _}
  end

  test "project runtime auth rejects caller injection and unsafe Connector responses", %{
    org: org,
    project: project
  } do
    previous_client = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    previous_probe = SystemsRuntime.get_env(:bridge_for_teams_core, :runtime_auth_probe)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, RuntimeAuthClient)

    on_exit(fn ->
      restore_env(:salix_client, previous_client)
      restore_env(:runtime_auth_probe, previous_probe)
    end)

    auth = %{
      "schema_version" => 1,
      "status" => "unauthenticated",
      "requires_openai_auth" => true,
      "observed_at" => 1_787_020_000_000
    }

    SystemsRuntime.put_env(:bridge_for_teams_core, :runtime_auth_probe, %{
      test_pid: SystemsRuntime.Proc.self(),
      results: %{
        read: {:ok, %{"auth" => Map.put(auth, "token", "private-token")}},
        start: {:error, :runtime_auth_conflict},
        cancel: {:error, :timeout}
      }
    })

    assert {:error, :invalid_runtime_auth_flow} =
             Environments.start_runtime_login(
               project.id,
               "device-codex",
               @device_runtime_id,
               "/bin/sh -c evil",
               actor_label: "project-admin@example.com",
               request_id: "req_runtime_auth_rejected"
             )

    assert {:error, :invalid_runtime_auth_attempt_id} =
             Environments.cancel_runtime_login(
               project.id,
               "device-codex",
               @device_runtime_id,
               "unsafe\nvalue"
             )

    refute_receive {:runtime_auth_call, _, _}

    assert {:error, :invalid_runtime_auth_response} =
             Environments.read_runtime_auth(project.id, "device-codex", @device_runtime_id)

    assert {:error, :runtime_auth_conflict} =
             Environments.start_runtime_login(
               project.id,
               "device-codex",
               @device_runtime_id,
               "device_code"
             )

    assert {:error, :runtime_auth_timeout} =
             Environments.cancel_runtime_login(
               project.id,
               "device-codex",
               @device_runtime_id,
               "rta_project"
             )

    SystemsRuntime.put_env(:bridge_for_teams_core, :runtime_auth_probe, %{
      test_pid: SystemsRuntime.Proc.self(),
      results: %{
        read: {:error, :unavailable},
        start: {:error, :runtime_auth_conflict},
        cancel:
          {:ok,
           %{
             "auth" => auth,
             "attempt_id" => "rta_other",
             "canceled" => true
           }}
      }
    })

    assert {:error, :invalid_runtime_auth_response} =
             Environments.cancel_runtime_login(
               project.id,
               "device-codex",
               @device_runtime_id,
               "rta_project"
             )

    assert {:error, :invalid_runtime_auth_response} =
             BridgeForTeams.RuntimeAuth.project_cancel(
               %{
                 "auth" => auth,
                 "attempt_id" => "rta_project",
                 "canceled" => false
               },
               "rta_project"
             )

    assert [rejected_audit] =
             Observability.list_audit_logs(org.id,
               action: "device.runtime_auth_login_started",
               request_id: "req_runtime_auth_rejected"
             )

    assert rejected_audit.result == "failed"
    assert rejected_audit.reason_class == "invalid_runtime_auth_flow"
    refute Jason.encode!(rejected_audit.metadata) =~ "/bin/sh"
  end

  test "disconnect_environment records disconnect and next connector run separately", %{
    org: org,
    project: project
  } do
    env = register_env(project, "box", "connected")
    connector_run_id = env.connector_run_id

    assert {:ok, rec} =
             Environments.disconnect_environment(
               project.id,
               env.device_id,
               actor_label: "project-admin@example.com",
               request_id: "req_env_disconnect"
             )

    assert rec["status"] == "disconnected"

    assert [audit] = Observability.list_audit_logs(org.id, action: "device.disconnected")
    assert audit.result == "ok"
    assert audit.request_id == "req_env_disconnect"
    assert audit.resource_type == "device"
    assert audit.resource_id == env.device_id

    assert [disconnected_event] = environment_runtime_events(org.id, connector_run_id)
    assert disconnected_event.event_type == "device.runtime.disconnected"
    assert disconnected_event.summary == "Device box disconnected"
    assert disconnected_event.evidence["previous_status"] == nil

    refresh_device_projection!()
    assert {:ok, [disconnected]} = Environments.list_environments(project.id)
    assert disconnected["status"] == "disconnected"
    assert length(environment_runtime_events(org.id, connector_run_id)) == 1

    assert {:ok, _transport_id, reconnected} =
             SalixEnv.Registry.connect("nonode@nohost", %{
               "tenant_id" => org.salix_tenant_id,
               "group_id" => project.salix_group_id,
               "device_id" => disconnected["device_id"],
               "connector_id" => disconnected["connector_id"],
               "name" => "box"
             })

    assert reconnected["connector_run_id"] != connector_run_id

    assert {:ok, recovered} =
             Environments.get_environment(project.id, disconnected["device_id"])

    assert recovered["status"] == "connected"
    assert recovered["connector_run_id"] == reconnected["connector_run_id"]

    assert [disconnected_event] = environment_runtime_events(org.id, connector_run_id)
    assert disconnected_event.event_type == "device.runtime.disconnected"

    assert [observed_event] =
             environment_runtime_events(org.id, reconnected["connector_run_id"])

    assert observed_event.event_type == "device.runtime.observed"
    assert observed_event.status == "connected"
    assert observed_event.severity == "info"
    assert observed_event.reason_class == nil
    assert observed_event.evidence["previous_status"] == nil
  end

  test "delete_environment removes the stable device, revokes its credential, and stops its runner request",
       %{org: org, project: project} do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "mac-mini-delete",
               "name" => "Delete Mac mini"
             })

    assert {:ok, request} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner.id,
               "name" => "delete-me"
             })

    assert {:ok, %{connect: %{"token" => token}, request: claimed}} =
             Environments.claim_device_provision_request(org.id, provisioner.id)

    assert {:ok, tenant_id, credential} =
             SalixEnv.ConnectorTokens.validate_connector_token(token)

    assert tenant_id == org.salix_tenant_id

    assert {:ok, _transport_id, device} =
             SalixEnv.Registry.connect("nonode@nohost", %{
               "tenant_id" => credential["tenant_id"],
               "group_id" => credential["group_id"],
               "device_id" => credential["device_id"],
               "connector_id" => credential["connector_id"],
               "name" => "delete-me",
               "provision_request_id" => request.id,
               "provisioner_id" => provisioner.id
             })

    assert {:ok, %{connected: 1}} =
             ProvisioningReconciler.drain_once()

    assert [%{id: request_id, status: "connected"}] =
             Environments.list_device_provision_requests(project.id)

    assert request_id == claimed.id

    assert {:ok, deleted} =
             Environments.delete_environment(
               project.id,
               device["device_id"],
               actor_label: "project-admin@example.com",
               request_id: "req_env_delete"
             )

    assert deleted["device_id"] == device["device_id"]
    assert {:error, :not_found} = Environments.get_environment(project.id, device["device_id"])
    assert {:error, :unauthorized} = SalixEnv.ConnectorTokens.validate_connector_token(token)

    assert {:ok, %{status: "stop_requested"}} =
             Environments.get_device_provision_request(request.id)

    assert [audit] = Observability.list_audit_logs(org.id, action: "device.deleted")
    assert audit.result == "ok"
    assert audit.request_id == "req_env_delete"
    assert audit.resource_type == "device"
    assert audit.resource_id == device["device_id"]
    assert audit.metadata["project_id"] == project.id
    assert audit.metadata["provision_request_id"] == request.id
  end

  defp refresh_device_projection! do
    assert {:ok, _count} =
             Environments.reconcile_device_projection(projection_page_limit: 100)

    :ok
  end
end
