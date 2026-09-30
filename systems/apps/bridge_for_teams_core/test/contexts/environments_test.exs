defmodule BridgeForTeams.EnvironmentsTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{
    Accounts,
    Agents,
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
  @device_runtime_id_two RuntimeIds.device_runtime_id(
                           "device-codex",
                           "codex",
                           "runtime-codex-two"
                         )

  defmodule ProvisioningProbeClient do
    @moduledoc false

    def list_group_envs(group_id, tenant_id) do
      %{test_pid: test_pid, list_result: result} =
        Application.fetch_env!(:bridge_for_teams_core, :provisioning_probe)

      send(test_pid, {:list_group_envs, group_id, tenant_id})
      result
    end

    def page_group_envs(group_id, tenant_id, opts) do
      %{test_pid: test_pid, page_result: result} =
        Application.fetch_env!(:bridge_for_teams_core, :provisioning_probe)

      send(test_pid, {:page_group_envs, group_id, tenant_id, opts})
      result
    end
  end

  defmodule BlockingProjectionClient do
    @moduledoc false

    def list_group_envs(group_id, tenant_id) do
      config = Application.fetch_env!(:bridge_for_teams_core, :projection_blocking_probe)
      test_pid = if is_map(config), do: config.test_pid, else: config
      result = if is_map(config), do: config.list_result, else: {:ok, []}
      send(test_pid, {:provision_list_started, self(), group_id, tenant_id})
      result
    end

    def page_group_envs(group_id, tenant_id, opts) do
      config = Application.fetch_env!(:bridge_for_teams_core, :projection_blocking_probe)
      test_pid = if is_map(config), do: config.test_pid, else: config
      send(test_pid, {:projection_page_started, self(), group_id, tenant_id, opts})

      receive do
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
        Application.fetch_env!(:bridge_for_teams_core, :runtime_auth_probe)

      send(test_pid, {:runtime_auth_call, operation, args})
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

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: nil

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(50)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  defp restore_env(key, nil),
    do: Application.delete_env(:bridge_for_teams_core, key)

  defp restore_env(key, value),
    do: Application.put_env(:bridge_for_teams_core, key, value)

  # Salix is the source of truth: connect one stable group device with a
  # replaceable current connector run.
  defp register_env(project, name, status, meta \\ %{}) do
    org = BridgeForTeams.Repo.get!(BridgeForTeams.Schema.Organization, project.org_id)
    device_id = meta["device_id"] || SalixStore.Ids.new_device_id()
    connector_id = meta["connector_id"] || "connector-#{System.unique_integer([:positive])}"

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

  defp age_provision_request(request, seconds) do
    updated_at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    assert {1, nil} =
             Repo.update_all(
               from(r in EnvironmentProvisionRequest, where: r.id == ^request.id),
               set: [updated_at: updated_at]
             )

    %{request | updated_at: updated_at}
  end

  defp age_provisioner(provisioner, seconds) do
    last_seen_at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    assert {1, nil} =
             Repo.update_all(
               from(p in MacMiniProvisioner, where: p.id == ^provisioner.id),
               set: [status: "online", last_seen_at: last_seen_at]
             )

    %{provisioner | status: "online", last_seen_at: last_seen_at}
  end

  defp runner_status_events(org_id, provisioner_id) do
    org_id
    |> Observability.list_events(
      resource_type: "mac_mini_provisioner",
      resource_id: provisioner_id,
      source: "mac_mini.provisioner",
      limit: 20
    )
    |> Enum.filter(
      &(&1.event_type in ~w(runner.registered runner.status_observed runner.status_changed))
    )
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

  defp agent_runtime_events(org_id, agent_id) do
    org_id
    |> Observability.list_events(
      domain: "agent",
      resource_type: "agent",
      resource_id: agent_id,
      source: "salix.env",
      limit: 20
    )
    |> Enum.filter(
      &(&1.event_type in ~w(agent.runtime.observed agent.runtime.degraded agent.runtime.recovered))
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

  test "mac mini runner status events are emitted on class changes only", %{org: org} do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(
               org.id,
               %{
                 "stable_id" => "observable-mac-mini",
                 "name" => "Observable Mac mini",
                 "capabilities" => %{
                   "component_versions" => %{"salix-connect" => "2026.06.18"}
                 }
               },
               request_id: "req-runner-registered"
             )

    assert [registered] = runner_status_events(org.id, provisioner.id)
    assert registered.event_type == "runner.registered"
    assert registered.correlation_id == "req-runner-registered"
    assert registered.status == "online"
    assert registered.evidence["request_id"] == "req-runner-registered"
    assert registered.evidence["stable_id"] == "observable-mac-mini"
    assert registered.evidence["effective_status"] == "online"
    assert registered.evidence["component_versions"] == %{"salix-connect" => "2026.06.18"}

    assert {:ok, _online} =
             Environments.heartbeat_mac_mini_provisioner(org.id, provisioner.id, %{
               "status" => "online"
             })

    assert length(runner_status_events(org.id, provisioner.id)) == 1

    assert {:ok, degraded} =
             Environments.heartbeat_mac_mini_provisioner(
               org.id,
               provisioner.id,
               %{
                 "status" => "degraded"
               },
               request_id: "req-runner-degraded"
             )

    assert degraded.status == "degraded"

    assert [degraded_event, registered] = runner_status_events(org.id, provisioner.id)
    assert degraded_event.event_type == "runner.status_changed"
    assert degraded_event.correlation_id == "req-runner-degraded"
    assert degraded_event.status == "degraded"
    assert degraded_event.severity == "warning"
    assert degraded_event.reason_class == "runner.degraded"
    assert degraded_event.evidence["request_id"] == "req-runner-degraded"
    assert degraded_event.evidence["previous_effective_status"] == "online"
    assert registered.event_type == "runner.registered"

    assert {:ok, _still_degraded} =
             Environments.heartbeat_mac_mini_provisioner(org.id, provisioner.id, %{
               "status" => "degraded"
             })

    assert length(runner_status_events(org.id, provisioner.id)) == 2

    assert {:ok, recovered} =
             Environments.heartbeat_mac_mini_provisioner(
               org.id,
               provisioner.id,
               %{
                 "status" => "online"
               },
               request_id: "req-runner-recovered"
             )

    assert recovered.status == "online"

    assert [recovered_event | _] = runner_status_events(org.id, provisioner.id)
    assert recovered_event.event_type == "runner.status_changed"
    assert recovered_event.correlation_id == "req-runner-recovered"
    assert recovered_event.status == "online"
    assert recovered_event.severity == "info"
    assert recovered_event.reason_class == "runner.recovered"
    assert recovered_event.evidence["request_id"] == "req-runner-recovered"
    assert recovered_event.evidence["previous_effective_status"] == "degraded"
  end

  test "list_mac_mini_provisioners decays stale online heartbeats", %{org: org} do
    {:ok, recent} =
      Environments.register_mac_mini_provisioner(org.id, %{
        "stable_id" => "recent-mac-mini",
        "name" => "Recent Mac mini"
      })

    {:ok, lost} =
      Environments.register_mac_mini_provisioner(org.id, %{
        "stable_id" => "lost-mac-mini",
        "name" => "Lost Mac mini"
      })

    {:ok, offline} =
      Environments.register_mac_mini_provisioner(org.id, %{
        "stable_id" => "offline-mac-mini",
        "name" => "Offline Mac mini"
      })

    age_provisioner(recent, 30)
    age_provisioner(lost, 90)
    age_provisioner(offline, 600)

    provisioners =
      org.id
      |> Environments.list_mac_mini_provisioners()
      |> Map.new(&{&1.stable_id, &1})

    assert provisioners["recent-mac-mini"].status == "online"
    assert provisioners["recent-mac-mini"].effective_status == "online"
    assert provisioners["recent-mac-mini"].last_seen_age_seconds >= 30

    assert provisioners["lost-mac-mini"].status == "online"
    assert provisioners["lost-mac-mini"].effective_status == "recently_lost"
    assert provisioners["lost-mac-mini"].last_seen_age_seconds >= 90

    assert provisioners["offline-mac-mini"].status == "online"
    assert provisioners["offline-mac-mini"].effective_status == "offline"
    assert provisioners["offline-mac-mini"].last_seen_age_seconds >= 600
  end

  test "page_mac_mini_provisioners cursor paginates dashboard order", %{org: org} do
    for index <- 1..12 do
      padded = String.pad_leading(to_string(index), 2, "0")

      assert {:ok, _provisioner} =
               Environments.register_mac_mini_provisioner(org.id, %{
                 "stable_id" => "paged-mac-mini-#{padded}",
                 "name" => "Paged Mac mini #{padded}",
                 "status" => "online"
               })
    end

    assert %{
             entries: first_page,
             next_cursor: cursor,
             total_count: 12
           } = Environments.page_mac_mini_provisioners(org.id, limit: 5)

    assert Enum.map(first_page, & &1.name) == [
             "Paged Mac mini 01",
             "Paged Mac mini 02",
             "Paged Mac mini 03",
             "Paged Mac mini 04",
             "Paged Mac mini 05"
           ]

    assert is_binary(cursor)

    assert %{entries: second_page, next_cursor: next_cursor, total_count: 12} =
             Environments.page_mac_mini_provisioners(org.id, limit: 5, after: cursor)

    assert Enum.map(second_page, & &1.name) == [
             "Paged Mac mini 06",
             "Paged Mac mini 07",
             "Paged Mac mini 08",
             "Paged Mac mini 09",
             "Paged Mac mini 10"
           ]

    assert is_binary(next_cursor)

    assert %{entries: third_page, next_cursor: nil, total_count: 12} =
             Environments.page_mac_mini_provisioners(org.id, limit: 5, after: next_cursor)

    assert Enum.map(third_page, & &1.name) == ["Paged Mac mini 11", "Paged Mac mini 12"]

    assert %{entries: invalid_cursor_page} =
             Environments.page_mac_mini_provisioners(org.id, limit: 5, after: "not-a-cursor")

    assert Enum.map(invalid_cursor_page, & &1.name) == Enum.map(first_page, & &1.name)
  end

  test "provisioning reconciler records stale runner effective status changes", %{org: org} do
    {:ok, provisioner} =
      Environments.register_mac_mini_provisioner(org.id, %{
        "stable_id" => "stale-observable-mac-mini",
        "name" => "Stale Observable Mac mini"
      })

    assert [registered] = runner_status_events(org.id, provisioner.id)
    assert registered.status == "online"

    age_provisioner(provisioner, 90)

    assert {:ok, %{scanned: 0, checked_groups: 0, connected: 0, timed_out: 0}} =
             ProvisioningReconciler.drain_once(now: DateTime.utc_now())

    assert [recently_lost, registered] = runner_status_events(org.id, provisioner.id)
    assert recently_lost.event_type == "runner.status_changed"
    assert recently_lost.status == "recently_lost"
    assert recently_lost.severity == "warning"
    assert recently_lost.reason_class == "runner.recently_lost"
    assert recently_lost.evidence["previous_effective_status"] == "online"
    assert registered.status == "online"

    assert {:ok, %{scanned: 0, checked_groups: 0, connected: 0, timed_out: 0}} =
             ProvisioningReconciler.drain_once(now: DateTime.utc_now())

    assert length(runner_status_events(org.id, provisioner.id)) == 2

    age_provisioner(provisioner, 600)

    assert {:ok, %{scanned: 0, checked_groups: 0, connected: 0, timed_out: 0}} =
             ProvisioningReconciler.drain_once(now: DateTime.utc_now())

    assert [offline | _] = runner_status_events(org.id, provisioner.id)
    assert offline.event_type == "runner.status_changed"
    assert offline.status == "offline"
    assert offline.severity == "error"
    assert offline.reason_class == "runner.offline"
    assert offline.evidence["previous_effective_status"] == "recently_lost"
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

  test "an empty runner claim emits neutral successful telemetry", %{org: org} do
    handler_id = "runner-claim-neutral-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:bridge_for_teams, :operation, :stop],
        fn _event, measurements, metadata, owner ->
          if metadata.operation == :runner_claim do
            send(owner, {:runner_claim_telemetry, measurements, metadata})
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "empty-claim-runner",
               "name" => "Empty Claim Runner"
             })

    assert {:error, :no_pending_request} =
             Environments.claim_device_provision_request(org.id, provisioner.id)

    assert_receive {:runner_claim_telemetry, measurements, %{outcome: "ok"}}, 1_000
    assert is_integer(measurements.duration)
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

    unique = System.unique_integer([:positive])
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

  test "device_provisioning_active? only considers live requests", %{
    org: org,
    project: project
  } do
    refute Environments.device_provisioning_active?(project.id)

    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "mac-mini-active-request",
               "name" => "Active request Mac mini"
             })

    assert {:ok, request} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner.id,
               "name" => "active-request"
             })

    assert Environments.device_provisioning_active?(project.id)

    assert {1, nil} =
             Repo.update_all(
               from(r in EnvironmentProvisionRequest, where: r.id == ^request.id),
               set: [status: "preflight_complete"]
             )

    assert Environments.device_provisioning_active?(project.id)

    assert {1, nil} =
             Repo.update_all(
               from(r in EnvironmentProvisionRequest, where: r.id == ^request.id),
               set: [status: "connected"]
             )

    refute Environments.device_provisioning_active?(project.id)
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

  test "stale provisioners cannot create or claim device requests", %{
    org: org,
    project: project
  } do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "mac-mini-1",
               "name" => "Lab Mac mini"
             })

    assert {:ok, _request} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner.id,
               "name" => "production"
             })

    age_provisioner(provisioner, 90)

    assert {:error, :provisioner_offline} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner.id,
               "name" => "stale-create"
             })

    assert {:error, :provisioner_offline} =
             Environments.claim_device_provision_request(org.id, provisioner.id)
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

  test "restarted starting connector accepts the next starting status callback", %{
    org: org,
    project: project
  } do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "mac-mini-resume-starting",
               "name" => "Resume Starting Mac mini"
             })

    assert {:ok, request} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner.id,
               "name" => "production"
             })

    assert {:ok, _starting} =
             Environments.update_device_provision_request_status(
               request,
               "starting_connector",
               %{"progress" => %{"stage" => "starting_connector"}}
             )

    assert {:ok, restarted} =
             Environments.update_device_provision_request_from_provisioner(
               org.id,
               provisioner.id,
               request.id,
               "starting_connector",
               %{"progress" => %{"stage" => "starting_connector", "restart_count" => 1}}
             )

    assert restarted.status == "starting_connector"
    assert restarted.progress["stage"] == "starting_connector"
    assert restarted.progress["restart_count"] == 1
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

    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    previous_probe = Application.get_env(:bridge_for_teams_core, :provisioning_probe)

    Application.put_env(:bridge_for_teams_core, :salix_client, ProvisioningProbeClient)

    Application.put_env(
      :bridge_for_teams_core,
      :provisioning_probe,
      %{
        test_pid: self(),
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
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous_client),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)

      if previous_probe,
        do: Application.put_env(:bridge_for_teams_core, :provisioning_probe, previous_probe),
        else: Application.delete_env(:bridge_for_teams_core, :provisioning_probe)
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

  test "device projection durable lease admits only one concurrent page fetch", %{
    org: org,
    project: project
  } do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    previous_probe = Application.get_env(:bridge_for_teams_core, :projection_blocking_probe)

    Application.put_env(:bridge_for_teams_core, :salix_client, BlockingProjectionClient)
    Application.put_env(:bridge_for_teams_core, :projection_blocking_probe, self())

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous_client),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)

      if previous_probe,
        do:
          Application.put_env(
            :bridge_for_teams_core,
            :projection_blocking_probe,
            previous_probe
          ),
        else: Application.delete_env(:bridge_for_teams_core, :projection_blocking_probe)
    end)

    first =
      Task.async(fn ->
        Environments.reconcile_device_projection(
          projection_page_limit: 1,
          projection_lease_ms: 5_000
        )
      end)

    assert_receive {:projection_page_started, worker, group_id, tenant_id, opts}
    assert group_id == project.salix_group_id
    assert tenant_id == org.salix_tenant_id
    assert opts[:limit] == 1

    assert {:ok, 0} =
             Environments.reconcile_device_projection(
               projection_page_limit: 1,
               projection_lease_ms: 5_000
             )

    refute_receive {:projection_page_started, _, _, _, _}
    send(worker, {:release_projection_page, {:ok, %{records: [], next_cursor: nil}}})
    assert {:ok, 0} = Task.await(first)
  end

  test "two provision doorbells share one bounded durable scan and one effective attach", %{
    org: org,
    project: project
  } do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "two-pod-provisioner",
               "name" => "Two Pod Provisioner"
             })

    assert {:ok, request} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner.id,
               "name" => "two-pod-device"
             })

    assert {:ok, waiting} =
             Environments.update_device_provision_request_status(
               request,
               "waiting_for_attach",
               %{}
             )

    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    previous_probe = Application.get_env(:bridge_for_teams_core, :projection_blocking_probe)

    Application.put_env(:bridge_for_teams_core, :salix_client, BlockingProjectionClient)

    Application.put_env(:bridge_for_teams_core, :projection_blocking_probe, %{
      test_pid: self(),
      list_result:
        {:ok,
         [
           %{
             "status" => "connected",
             "connector_run_id" => "connector-run-two-pod",
             "provision_request_id" => waiting.id
           }
         ]}
    })

    on_exit(fn ->
      restore_env(:salix_client, previous_client)
      restore_env(:projection_blocking_probe, previous_probe)
    end)

    first =
      Task.async(fn ->
        ProvisioningReconciler.drain_once(
          limit: 1,
          projection_page_limit: 1,
          projection_lease_ms: 5_000
        )
      end)

    assert_receive {:provision_list_started, _, group_id, tenant_id}
    assert group_id == project.salix_group_id
    assert tenant_id == org.salix_tenant_id
    assert_receive {:projection_page_started, worker, ^group_id, ^tenant_id, _opts}

    assert {:ok, %{scanned: 0, checked_groups: 0, connected: 0, timed_out: 0, projected: 0}} =
             ProvisioningReconciler.drain_once(
               limit: 1,
               projection_page_limit: 1,
               projection_lease_ms: 5_000
             )

    refute_receive {:provision_list_started, _, _, _}

    send(worker, {:release_projection_page, {:ok, %{records: [], next_cursor: nil}}})

    assert {:ok, %{scanned: 1, connected: 1, projected: 0}} = Task.await(first)

    assert {:ok, connected} = Environments.get_device_provision_request(waiting.id)
    assert connected.status == "connected"
    assert connected.connector_run_id == "connector-run-two-pod"

    connected_events =
      org.id
      |> Observability.list_events(
        resource_type: "device_provision_request",
        resource_id: waiting.id
      )
      |> Enum.filter(&(&1.event_type == "device.provision.connected"))

    assert length(connected_events) == 1
  end

  test "a crashed provision owner expires and another Pod converges the request", %{
    org: org,
    project: project
  } do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "crash-recovery-provisioner",
               "name" => "Crash Recovery Provisioner"
             })

    assert {:ok, request} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner.id,
               "name" => "crash-recovery-device"
             })

    assert {:ok, waiting} =
             Environments.update_device_provision_request_status(
               request,
               "waiting_for_attach",
               %{}
             )

    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    previous_probe = Application.get_env(:bridge_for_teams_core, :projection_blocking_probe)

    Application.put_env(:bridge_for_teams_core, :salix_client, BlockingProjectionClient)

    Application.put_env(:bridge_for_teams_core, :projection_blocking_probe, %{
      test_pid: self(),
      list_result: {:ok, []}
    })

    on_exit(fn ->
      restore_env(:salix_client, previous_client)
      restore_env(:projection_blocking_probe, previous_probe)
    end)

    crashed =
      Task.async(fn ->
        ProvisioningReconciler.drain_once(
          limit: 1,
          projection_page_limit: 1,
          projection_lease_ms: 20
        )
      end)

    assert_receive {:provision_list_started, _, _, _}
    assert_receive {:projection_page_started, crashed_worker, _, _, _}
    assert crashed_worker == crashed.pid

    Process.unlink(crashed.pid)
    ref = Process.monitor(crashed.pid)
    Process.exit(crashed.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    Process.sleep(30)

    Application.put_env(:bridge_for_teams_core, :projection_blocking_probe, %{
      test_pid: self(),
      list_result:
        {:ok,
         [
           %{
             "status" => "connected",
             "connector_run_id" => "connector-run-after-crash",
             "provision_request_id" => waiting.id
           }
         ]}
    })

    replacement =
      Task.async(fn ->
        ProvisioningReconciler.drain_once(
          limit: 1,
          projection_page_limit: 1,
          projection_lease_ms: 5_000
        )
      end)

    assert_receive {:provision_list_started, _, _, _}
    assert_receive {:projection_page_started, replacement_worker, _, _, _}
    send(replacement_worker, {:release_projection_page, {:ok, %{records: [], next_cursor: nil}}})

    assert {:ok, %{scanned: 1, connected: 1, projected: 0}} = Task.await(replacement)

    assert {:ok, connected} = Environments.get_device_provision_request(waiting.id)
    assert connected.status == "connected"
    assert connected.connector_run_id == "connector-run-after-crash"
  end

  test "expired projection worker failure cannot clear a replacement lease" do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    previous_probe = Application.get_env(:bridge_for_teams_core, :projection_blocking_probe)

    Application.put_env(:bridge_for_teams_core, :salix_client, BlockingProjectionClient)
    Application.put_env(:bridge_for_teams_core, :projection_blocking_probe, self())

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous_client),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)

      if previous_probe,
        do:
          Application.put_env(
            :bridge_for_teams_core,
            :projection_blocking_probe,
            previous_probe
          ),
        else: Application.delete_env(:bridge_for_teams_core, :projection_blocking_probe)
    end)

    stale =
      Task.async(fn ->
        Environments.reconcile_device_projection(
          projection_page_limit: 1,
          projection_lease_ms: 1
        )
      end)

    assert_receive {:projection_page_started, stale_worker, _, _, _}
    Process.sleep(5)

    replacement =
      Task.async(fn ->
        Environments.reconcile_device_projection(
          projection_page_limit: 1,
          projection_lease_ms: 5_000
        )
      end)

    assert_receive {:projection_page_started, replacement_worker, _, _, _}

    send(stale_worker, {:release_projection_page, {:error, :timeout}})
    assert {:error, :timeout} = Task.await(stale)

    assert {:ok, 0} =
             Environments.reconcile_device_projection(
               projection_page_limit: 1,
               projection_lease_ms: 5_000
             )

    refute_receive {:projection_page_started, _, _, _, _}

    send(
      replacement_worker,
      {:release_projection_page, {:ok, %{records: [], next_cursor: nil}}}
    )

    assert {:ok, 0} = Task.await(replacement)
  end

  test "reconcile_device_provision_requests marks stale attach wait as failed", %{
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
               %{}
             )

    _old_waiting = age_provision_request(waiting, 600)

    assert {:ok, %{scanned: 1, checked_groups: 1, connected: 0, timed_out: 1}} =
             ProvisioningReconciler.drain_once(attach_timeout_ms: 300_000)

    assert {:ok, failed} = Environments.get_device_provision_request(request.id)
    assert failed.status == "failed"
    assert failed.failure_code == "connector.attach_timeout"
    assert failed.failure_message == "connector did not attach within 300000ms"

    assert [run] =
             Observability.list_operation_runs(org.id,
               run_type: "device_provision",
               external_run_id: request.id
             )

    assert run.status == "failed"
    assert run.reason_class == "connector.attach_timeout"

    assert [failed_event] =
             Observability.list_events(org.id,
               resource_type: "device_provision_request",
               resource_id: request.id,
               status: "failed"
             )

    assert failed_event.event_type == "device.provision.failed"
    assert failed_event.source == "salix.env"
    assert failed_event.run_record_id == run.id
  end

  test "reconcile_device_provision_requests prefers registry attach over timeout", %{
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

    _old_waiting = age_provision_request(waiting, 600)

    env =
      register_env(project, request.name, "connected", %{
        "alias" => request.env_alias,
        "provision_request_id" => request.id,
        "provisioner_id" => provisioner.id
      })

    assert {:ok, %{scanned: 1, checked_groups: 1, connected: 1, timed_out: 0}} =
             Environments.reconcile_device_provision_requests(attach_timeout_ms: 300_000)

    assert {:ok, connected} = Environments.get_device_provision_request(request.id)
    assert connected.status == "connected"
    assert connected.connector_run_id == env.connector_run_id
    assert connected.failure_code == nil
    assert connected.progress["stage"] == "connected"
    assert connected.progress["connector_run_id"] == env.connector_run_id
  end

  test "create_device_provision_request unknown project" do
    assert {:error, :not_found} =
             Environments.create_device_provision_request(Ecto.UUID.generate(), %{})
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

  test "list_environments queues external agent runtime health observation", %{
    org: org,
    project: project
  } do
    now = System.system_time(:millisecond)

    runtime =
      %{
        "kind" => "external",
        "provider" => "codex",
        "runtime_id" => "runtime-codex",
        "device_runtime_id" => @device_runtime_id,
        "status" => "ready",
        "ready" => true,
        "version" => "1.2.3",
        "version_detected" => true,
        "app_server_startable" => true,
        "native_server_startable" => true,
        "auth_ready" => true,
        "readiness_checked_at" => now,
        "readiness_valid_until" => now + 600_000
      }

    runtime_two =
      runtime
      |> Map.put("runtime_id", "runtime-codex-two")
      |> Map.put("device_runtime_id", @device_runtime_id_two)
      |> Map.put("version", "1.2.4")

    env =
      register_env(project, "box-codex", "connected", %{
        "device_id" => "device-codex",
        "connector_id" => "connector-codex",
        "agent_runtimes" => [runtime, runtime_two]
      })

    runtime_config = %{
      "kind" => "external",
      "provider" => "codex",
      "device_id" => "device-codex",
      "runtime_id" => "runtime-codex",
      "device_runtime_id" => @device_runtime_id
    }

    runtime_config_two =
      runtime_config
      |> Map.put("kind", "connected_runtime")
      |> Map.put("runtime_id", "runtime-codex-two")
      |> Map.put("device_runtime_id", @device_runtime_id_two)
      |> Map.put("owner_scope", %{"type" => "group", "id" => project.salix_group_id})
      |> Map.put("binding_revision", 1)

    compute_runtime_config = %{
      "kind" => "compute_workload",
      "workload_id" => "compute-codex",
      "runtime_spec" => %{"provider" => "codex"},
      "owner_scope" => %{"type" => "project", "id" => project.id},
      "binding_revision" => 1
    }

    refresh_device_projection!()

    assert {:ok, agent} =
             Agents.create_agent(project.id, %{
               "role" => "worker",
               "name" => "codex-worker",
               "runtime_config" => runtime_config
             })

    assert {:ok, agent_two} =
             Agents.create_agent(project.id, %{
               "role" => "worker",
               "name" => "codex-worker-two",
               "runtime_config" => runtime_config_two
             })

    assert {:ok, compute_agent} =
             Agents.create_agent(project.id, %{
               "role" => "worker",
               "name" => "compute-codex-worker",
               "runtime_config" => compute_runtime_config
             })

    drain_all()
    refresh_device_projection!()

    assert {:ok, [_env]} = Environments.list_environments(project.id)

    assert [observed_event] =
             eventually(fn ->
               case agent_runtime_events(org.id, agent.id) do
                 [_event] = events -> events
                 _other -> nil
               end
             end)

    assert observed_event.event_type == "agent.runtime.observed"
    assert observed_event.status == "ready"
    assert observed_event.severity == "info"
    assert observed_event.project_id == project.id
    assert observed_event.evidence["device_runtime_id"] == @device_runtime_id
    assert observed_event.evidence["connector_run_id"] == env.connector_run_id
    assert observed_event.evidence["salix_agent_id"] == agent.salix_agent_id
    assert observed_event.evidence["version"] == "1.2.3"
    refute Map.has_key?(observed_event.evidence, "ready")
    refute Map.has_key?(observed_event.evidence, "auth_ready")

    assert [observed_event_two] =
             eventually(fn ->
               case agent_runtime_events(org.id, agent_two.id) do
                 [_event] = events -> events
                 _other -> nil
               end
             end)

    assert observed_event_two.event_type == "agent.runtime.observed"
    assert observed_event_two.status == "ready"
    assert observed_event_two.evidence["device_runtime_id"] == @device_runtime_id_two
    assert observed_event_two.evidence["connector_run_id"] == env.connector_run_id
    assert observed_event_two.evidence["salix_agent_id"] == agent_two.salix_agent_id
    assert observed_event_two.evidence["version"] == "1.2.4"
    assert agent_runtime_events(org.id, compute_agent.id) == []

    assert {:ok, [_env]} = Environments.list_environments(project.id)

    assert [^observed_event] =
             eventually(fn ->
               case agent_runtime_events(org.id, agent.id) do
                 [_event] = events -> events
                 _other -> nil
               end
             end)

    degraded_runtime =
      runtime
      |> Map.put("ready", false)
      |> Map.put("status", "unavailable")
      |> Map.put("auth_ready", false)
      |> Map.put("readiness_checked_at", now + 1_000)

    degraded_runtime_two =
      runtime_two
      |> Map.put("ready", false)
      |> Map.put("status", "unavailable")
      |> Map.put("auth_ready", false)
      |> Map.put("readiness_checked_at", now + 1_000)

    assert {:ok, _record} =
             SalixEnv.Registry.update_meta(
               env.connector_run_id,
               &Map.put(&1, "agent_runtimes", [degraded_runtime, degraded_runtime_two]),
               now: now + 1_000
             )

    refresh_device_projection!()
    assert {:ok, [_env]} = Environments.list_environments(project.id)

    events =
      eventually(fn ->
        events = agent_runtime_events(org.id, agent.id)
        if length(events) == 2, do: events
      end)

    assert length(events) == 2

    degraded_event = Enum.find(events, &(&1.event_type == "agent.runtime.degraded"))
    assert degraded_event.status == "unavailable"
    assert degraded_event.severity == "warning"
    assert degraded_event.reason_class == "agent_runtime.unavailable"
    assert degraded_event.evidence["previous_status"] == "ready"
    assert degraded_event.evidence["issue"] == "authentication_required"

    events_two =
      eventually(fn ->
        events = agent_runtime_events(org.id, agent_two.id)
        if length(events) == 2, do: events
      end)

    degraded_event_two = Enum.find(events_two, &(&1.event_type == "agent.runtime.degraded"))
    assert degraded_event_two.status == "unavailable"
    assert degraded_event_two.evidence["previous_status"] == "ready"
    assert agent_runtime_events(org.id, compute_agent.id) == []

    recovered_runtime =
      runtime
      |> Map.put("readiness_checked_at", now + 2_000)
      |> Map.put("readiness_valid_until", now + 602_000)

    recovered_runtime_two =
      runtime_two
      |> Map.put("readiness_checked_at", now + 2_000)
      |> Map.put("readiness_valid_until", now + 602_000)

    assert {:ok, _record} =
             SalixEnv.Registry.update_meta(
               env.connector_run_id,
               &Map.put(&1, "agent_runtimes", [recovered_runtime, recovered_runtime_two]),
               now: now + 2_000
             )

    refresh_device_projection!()
    assert {:ok, [_env]} = Environments.list_environments(project.id)

    recovered_events =
      eventually(fn ->
        events = agent_runtime_events(org.id, agent.id)
        if length(events) == 3, do: events
      end)

    recovered_event = Enum.find(recovered_events, &(&1.event_type == "agent.runtime.recovered"))
    assert recovered_event.status == "ready"
    assert recovered_event.evidence["previous_status"] == "unavailable"

    recovered_events_two =
      eventually(fn ->
        events = agent_runtime_events(org.id, agent_two.id)
        if length(events) == 3, do: events
      end)

    recovered_event_two =
      Enum.find(recovered_events_two, &(&1.event_type == "agent.runtime.recovered"))

    assert recovered_event_two.status == "ready"
    assert recovered_event_two.evidence["previous_status"] == "unavailable"
    assert agent_runtime_events(org.id, compute_agent.id) == []
  end

  test "list_environments for an unknown project is empty" do
    assert {:ok, []} = Environments.list_environments(Ecto.UUID.generate())
  end

  test "get_environment returns the live registry record", %{project: project} do
    env = register_env(project, "box", "connected")

    assert {:ok, rec} = Environments.get_environment(project.id, env.device_id)
    assert rec["connector_run_id"] == env.connector_run_id
    assert rec["device_id"] == env.device_id
    assert rec["status"] == "connected"

    assert {:error, :not_found} = Environments.get_environment(project.id, "env_nope")
  end

  test "project runtime auth uses authoritative scope and strips non-start ceremony fields", %{
    org: org,
    project: project
  } do
    now = System.system_time(:millisecond)
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    previous_probe = Application.get_env(:bridge_for_teams_core, :runtime_auth_probe)
    Application.put_env(:bridge_for_teams_core, :salix_client, RuntimeAuthClient)

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

    Application.put_env(:bridge_for_teams_core, :runtime_auth_probe, %{
      test_pid: self(),
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
               Ecto.UUID.generate(),
               "device-codex",
               @device_runtime_id
             )

    refute_receive {:runtime_auth_call, _, _}
  end

  test "project runtime auth rejects caller injection and unsafe Connector responses", %{
    org: org,
    project: project
  } do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    previous_probe = Application.get_env(:bridge_for_teams_core, :runtime_auth_probe)
    Application.put_env(:bridge_for_teams_core, :salix_client, RuntimeAuthClient)

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

    Application.put_env(:bridge_for_teams_core, :runtime_auth_probe, %{
      test_pid: self(),
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

    Application.put_env(:bridge_for_teams_core, :runtime_auth_probe, %{
      test_pid: self(),
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
