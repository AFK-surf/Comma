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
  alias SalixStore.RuntimeIds

  @device_runtime_id RuntimeIds.device_runtime_id("device-codex", "codex", "runtime-codex")

  defmodule ProvisioningProbeClient do
    @moduledoc false

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

  test "the worker refreshes the device projection from Salix", %{
    org: org,
    project: project
  } do
    previous_client = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    previous_probe = SystemsRuntime.get_env(:bridge_for_teams_core, :provisioning_probe)

    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, ProvisioningProbeClient)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :provisioning_probe,
      %{
        test_pid: SystemsRuntime.Proc.self(),
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
      restore_env(:salix_client, previous_client)
      restore_env(:provisioning_probe, previous_probe)
    end)

    assert {:ok, []} = Environments.list_projected_environments(project.id, limit: 1)
    refute_receive {:page_group_envs, _, _, _}

    assert {:ok, %{projected: 1}} = ProvisioningReconciler.drain_once()

    assert_receive {:page_group_envs, group_id, tenant_id, opts}
    assert group_id == project.salix_group_id
    assert tenant_id == org.salix_tenant_id
    assert opts[:limit] == 50
    assert opts[:cursor] == nil

    assert {:ok, [%{"device_id" => "device-projected", "status" => "connected"}]} =
             Environments.list_projected_environments(project.id, limit: 1)
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

  test "delete_environment removes the stable device and records it", %{
    org: org,
    project: project
  } do
    device = register_env(project, "delete-me", "connected")

    assert {:ok, deleted} =
             Environments.delete_environment(
               project.id,
               device.device_id,
               actor_label: "project-admin@example.com",
               request_id: "req_env_delete"
             )

    assert deleted["device_id"] == device.device_id
    assert {:error, :not_found} = Environments.get_environment(project.id, device.device_id)

    assert [audit] = Observability.list_audit_logs(org.id, action: "device.deleted")
    assert audit.result == "ok"
    assert audit.request_id == "req_env_delete"
    assert audit.resource_type == "device"
    assert audit.resource_id == device.device_id
    assert audit.metadata["project_id"] == project.id
  end

  defp refresh_device_projection! do
    assert {:ok, _count} =
             Environments.reconcile_device_projection(projection_page_limit: 100)

    :ok
  end
end
