defmodule SalixStore.AgentVMMAdminProjectionContractTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  import Ecto.Query

  alias SalixStore.{AgentVMM, AgentVMMAdminProjection, AgentVMMInstallations, Compute, Repo}

  setup do
    Repo.query!("""
    TRUNCATE agent_vmm_sessions, agent_vmm_audit_events, agent_vmm_install_operations,
      compute_commands, compute_runtime_instances, compute_workloads, compute_allocations,
      compute_provider_bindings, compute_environments, compute_pools,
      agent_vmm_registrations CASCADE
    """)

    :ok
  end

  test "the admin DTO is tenant fenced, complete, and secret free" do
    tenant_a = source_graph_fixture("a", "tenant-a", "shared-device")
    _tenant_b = source_graph_fixture("b", "tenant-b", "shared-device")
    now = SystemsClock.utc_now()

    Repo.insert!(%Compute.ReconcilerClaim{
      id: "agent_vmm:#{tenant_a.workload.id}:#{tenant_a.workload.generation}",
      provider: "agent_vmm",
      workload_id: tenant_a.workload.id,
      generation: tenant_a.workload.generation,
      claim_token: "admin-projection-test",
      attempt_count: 1,
      last_error: %{
        "kind" => "provider_error",
        "code" => "resource_capacity_exhausted",
        "stage" => "import_admission",
        "resource" => "storage_headroom",
        "message" => "Guest storage headroom is unavailable.",
        "available_bytes" => 1_073_741_824,
        "required_bytes" => 2_147_483_648,
        "internal_detail" => "projection-secret"
      },
      created_at: now,
      updated_at: now
    })

    {2, _} =
      Repo.update_all(
        from(c in Compute.Command,
          where: c.id in [^tenant_a.failed_command.id, ^tenant_a.unknown_command.id]
        ),
        set: [
          payload: %{"secret" => "payload-secret"},
          evidence: %{"secret" => "evidence-secret"}
        ]
      )

    assert {:ok, %{nodes: [node], next_cursor: nil}} =
             AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 10)

    assert node["id"] == tenant_a.registration.id
    assert node["device_id"] == "shared-device"
    assert node["connection"]["status"] == "connected"
    assert node["work"]["workloads"] == 1
    assert node["work"]["draining"] == 1
    assert node["operations"]["failed"] == 1
    assert node["operations"]["unknown_outcome"] == 1
    assert node["issue"] == "command_unknown_outcome"

    assert {:ok, %{operations: operations}} =
             AgentVMMAdminProjection.page_operations("tenant-a", tenant_a.registration.id)

    assert {:ok, %{workloads: [workload]}} =
             AgentVMMAdminProjection.page_workloads("tenant-a", tenant_a.registration.id)

    assert workload["id"] == tenant_a.workload.id

    assert workload["reconcile_error"] == %{
             "code" => "resource_capacity_exhausted",
             "stage" => "import_admission",
             "resource" => "storage_headroom",
             "message" => "Guest storage headroom is unavailable.",
             "available_bytes" => 1_073_741_824,
             "required_bytes" => 2_147_483_648
           }

    assert {:ok, %{activity: [activity | _]}} =
             AgentVMMAdminProjection.page_activity("tenant-a", tenant_a.registration.id)

    assert activity["subject"] == "registration"

    encoded =
      Jason.encode!(%{
        node: node,
        operations: operations,
        workloads: [workload],
        activity: activity
      })

    refute encoded =~ "payload-secret"
    refute encoded =~ "evidence-secret"
    refute encoded =~ "enrollment_token"
    refute encoded =~ "credential"
    refute encoded =~ "payload"
    refute encoded =~ "evidence"
    refute encoded =~ "projection-secret"

    assert {:error, :not_found} =
             AgentVMMAdminProjection.get_node("tenant-b", tenant_a.registration.id)

    assert {:error, :not_found} =
             AgentVMMAdminProjection.page_operations("tenant-b", tenant_a.registration.id)
  end

  test "reconcile error projection admits only the finite public contract" do
    valid = %{
      "code" => "resource_capacity_exhausted",
      "stage" => "import_admission",
      "resource" => "storage_headroom",
      "message" => "Guest storage headroom is unavailable.",
      "available_bytes" => 1,
      "required_bytes" => 9_223_372_036_854_775_808
    }

    assert AgentVMM.project_reconcile_error(valid) ==
             Map.drop(valid, ["required_bytes"])

    refute AgentVMM.project_reconcile_error(%{valid | "code" => "attacker_chosen_reason"})
    refute AgentVMM.project_reconcile_error(%{valid | "stage" => "attacker_stage"})
    refute AgentVMM.project_reconcile_error(%{valid | "resource" => "private_path"})
    refute AgentVMM.project_reconcile_error(%{valid | "stage" => "image_import"})
  end

  test "overview binding existence is fenced through the environment tenant" do
    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "registration-tenant-a-only",
        tenant_id: "tenant-a",
        group_id: "group-a",
        device_id: "device-a-only",
        enrollment_token: String.duplicate("a", 32)
      })

    {1, _} =
      Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^registration.id),
        set: [status: "ready", desired_enabled: true]
      )

    tenant_b = source_graph_fixture("foreign", "tenant-b")

    {:ok, foreign_environment} =
      Compute.create_environment(%{
        id: "environment-foreign-reference",
        tenant_id: "tenant-b",
        owner_type: "project",
        owner_id: "project-foreign-reference",
        pool_id: tenant_b.binding.pool_id
      })

    now = SystemsClock.utc_now()

    Repo.insert!(%Compute.ProviderBinding{
      id: "binding-foreign-reference",
      pool_id: tenant_b.binding.pool_id,
      environment_id: foreign_environment.id,
      provider: "agent_vmm",
      provider_ref: registration.id,
      status: "available",
      generation: 1,
      revision: 1,
      observation: %{},
      updated_at: now
    })

    assert {:ok, %{"total" => 1, "ready" => 0, "needs_attention" => 1}} =
             AgentVMMAdminProjection.overview("tenant-a")

    assert {:ok, %{nodes: [node]}} =
             AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 10)

    assert node["issue"] == "observation_missing"
  end

  defp source_graph_fixture(suffix \\ "a", tenant_id \\ "tenant-a", device_id \\ nil) do
    device_id = device_id || "device-#{suffix}"

    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool-#{suffix}",
        tenant_id: tenant_id,
        name: "agent-vmm-#{suffix}",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec"]
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "environment-#{suffix}",
        tenant_id: tenant_id,
        owner_type: "project",
        owner_id: "project-#{suffix}",
        pool_id: pool.id
      })

    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "registration-#{suffix}",
        tenant_id: tenant_id,
        group_id: "shared-group",
        device_id: device_id,
        enrollment_token: String.duplicate("e", 32)
      })

    {1, _} =
      Repo.update_all(
        from(r in AgentVMM.Registration, where: r.id == ^registration.id),
        set: [status: "ready", desired_enabled: true]
      )

    registration = Repo.get!(AgentVMM.Registration, registration.id)

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding-#{suffix}",
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration.id,
        generation: 1
      })

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway-#{suffix}", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 0,
               "inventory" => [],
               "observation" => observation_fixture(1)
             })

    binding = Repo.get!(Compute.ProviderBinding, binding.id)

    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation-#{suffix}",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    {:ok, allocation} = Compute.observe_allocation(allocation.id, 1, 1, "ready", "succeeded")

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload-#{suffix}",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "meeting_runtime",
        generation: 1
      })

    {:ok, workload} = Compute.observe_workload(workload.id, 1, 1, "draining")

    {:ok, runtime} =
      Compute.observe_runtime(%{
        id: "runtime-#{suffix}",
        workload_id: workload.id,
        allocation_id: allocation.id,
        generation: 1,
        connection_epoch: "1"
      })

    {1, _} =
      Repo.update_all(
        from(r in Compute.RuntimeInstance, where: r.id == ^runtime.id),
        set: [readiness: "pending"]
      )

    failed_command = enqueue_command!("command-failed-#{suffix}", allocation, workload)
    unknown_command = enqueue_command!("command-unknown-#{suffix}", allocation, workload)

    {1, _} =
      Repo.update_all(from(c in Compute.Command, where: c.id == ^failed_command.id),
        set: [status: "failed", outcome: "failed"]
      )

    {1, _} =
      Repo.update_all(from(c in Compute.Command, where: c.id == ^unknown_command.id),
        set: [status: "unknown_outcome", outcome: "unknown"]
      )

    now = SystemsClock.utc_now()

    Repo.insert!(%AgentVMMInstallations.Operation{
      id: "install-#{suffix}",
      tenant_id: tenant_id,
      group_id: "shared-group",
      surface: "comma",
      scope_key: "project-#{suffix}",
      client_request_id: "request-#{suffix}",
      provider: "agent_vmm",
      environment_id: environment.id,
      delivery_target_type: "project",
      delivery_target_id: "project-#{suffix}",
      registration_id: registration.id,
      authorization_status: "handed_off",
      ticket_generation: 1,
      ticket_secret_hash: :crypto.hash(:sha256, "ticket-#{suffix}-#{tenant_id}"),
      ticket_status: "consumed",
      ticket_expires_at: DateTime.add(now, 60, :second),
      created_at: now,
      updated_at: now
    })

    Repo.insert!(%AgentVMM.Session{
      id: "session-#{suffix}",
      registration_id: registration.id,
      runtime_instance_id: runtime.id,
      allocation_id: allocation.id,
      allocation_generation: 1,
      connection_epoch: "1",
      gateway_instance_id: "gateway-#{suffix}",
      status: "ready",
      expires_at: DateTime.add(now, 60, :second),
      updated_at: now
    })

    %{
      registration: registration,
      environment: environment,
      binding: binding,
      allocation: allocation,
      workload: workload,
      runtime: Repo.get!(Compute.RuntimeInstance, runtime.id),
      failed_command: Repo.get!(Compute.Command, failed_command.id),
      unknown_command: Repo.get!(Compute.Command, unknown_command.id)
    }
  end

  defp observation_fixture(sequence, overrides \\ %{}) do
    now = SystemsClock.utc_now() |> DateTime.to_unix(:millisecond)

    Map.merge(
      %{
        "sequence" => Integer.to_string(sequence),
        "observedUnixMillis" => Integer.to_string(now),
        "protocolVersion" => "1",
        "hostApiVersion" => "host.v1",
        "connectorRelease" => "test",
        "supportedFeatures" => ["connection-epoch-v1"],
        "capacity" => %{
          "perEnvironmentLimits" => %{},
          "maxEgressMode" => "EGRESS_MODE_DENY_ALL"
        },
        "health" => %{"status" => "healthy", "components" => []},
        "usage" => %{"stale" => false},
        "inventoryWatermark" => "0",
        "inventoryObservedUnixMillis" => Integer.to_string(now)
      },
      overrides
    )
  end

  defp enqueue_command!(id, allocation, workload) do
    {:ok, command} =
      Compute.enqueue_command(%{
        id: id,
        allocation_id: allocation.id,
        workload_id: workload.id,
        request_id: id,
        kind: "observe",
        classification: "read_only",
        target_generation: allocation.generation,
        target_revision: allocation.revision,
        deadline_at: DateTime.add(SystemsClock.utc_now(), 60, :second)
      })

    command
  end
end
