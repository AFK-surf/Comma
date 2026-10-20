defmodule SalixStore.AgentVMMProviderTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SystemsClock.Test, scope: ["Elixir.SalixStore"]
  import Ecto.Query

  alias SalixStore.{AgentVMM, Compute, Repo}

  setup do
    previous_gate =
      SystemsRuntime.get_env(:salix_store, :agent_vmm_multi_scope_registration_enabled)

    SystemsRuntime.delete_env(:salix_store, :agent_vmm_multi_scope_registration_enabled)

    on_exit(fn ->
      if is_nil(previous_gate) do
        SystemsRuntime.delete_env(:salix_store, :agent_vmm_multi_scope_registration_enabled)
      else
        SystemsRuntime.put_env(
          :salix_store,
          :agent_vmm_multi_scope_registration_enabled,
          previous_gate
        )
      end
    end)

    Repo.query!(
      "TRUNCATE agent_vmm_audit_events, agent_vmm_sessions, compute_commands, compute_grants, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    :ok
  end

  test "reenabling an enrolled registration preserves credentials and accepts reconnection" do
    token = String.duplicate("a", 32)
    credential = String.duplicate("b", 32)

    assert {:ok, registration} =
             AgentVMM.create_registration(%{
               id: "resume-registration",
               tenant_id: "tenant",
               group_id: "group",
               device_id: "device",
               enrollment_token: token
             })

    assert {:ok, disabled} =
             AgentVMM.configure_registration(registration.id, registration.revision, false)

    assert {:ok, pending} =
             AgentVMM.configure_registration(registration.id, disabled.revision, true)

    assert pending.status == "enrolling"
    assert {:ok, enrolled} = AgentVMM.enroll(registration.id, token, credential)

    assert {:ok, disabled} =
             AgentVMM.configure_registration(registration.id, enrolled.revision, false)

    hello = %{"connectionEpoch" => "1", "inventoryWatermark" => 0, "inventory" => []}

    assert {:error, :registration_inactive} =
             AgentVMM.observe_registration(registration.id, "gateway", hello)

    assert {:ok, resumed} =
             AgentVMM.configure_registration(registration.id, disabled.revision, true)

    assert :ok = AgentVMM.authenticate_registration(registration.id, credential)
    assert {:ok, :ok} = AgentVMM.observe_registration(registration.id, "gateway", hello)
    assert resumed.status == "ready"

    assert {:ok, revoked} =
             AgentVMM.revoke_registration("tenant", registration.id, resumed.revision)

    assert {:error, :revision_conflict} =
             AgentVMM.configure_registration(registration.id, revoked.revision, true)
  end

  test "gate enable isolates distinct project scopes on one Host" do
    SystemsRuntime.put_env(:salix_store, :agent_vmm_multi_scope_registration_enabled, true)

    attrs = %{
      id: "registration-a",
      tenant_id: "tenant",
      group_id: "group-a",
      device_id: "shared-device",
      enrollment_token: String.duplicate("a", 32)
    }

    assert {:ok, registration_a} = AgentVMM.create_registration(attrs)

    assert {:error, :already_exists} =
             AgentVMM.create_registration(%{
               attrs
               | id: "registration-a-retry",
                 enrollment_token: String.duplicate("c", 32)
             })

    assert {:ok, registration_b} =
             AgentVMM.create_registration(%{
               attrs
               | id: "registration-b",
                 group_id: "group-b",
                 enrollment_token: String.duplicate("b", 32)
             })

    assert Repo.aggregate(AgentVMM.Registration, :count) == 2

    assert {:ok, revoked_a} =
             AgentVMM.revoke_registration("tenant", registration_a.id, registration_a.revision)

    assert revoked_a.status == "revoked"
    assert Repo.get!(AgentVMM.Registration, registration_b.id).status == registration_b.status
    assert Repo.get!(AgentVMM.Registration, registration_b.id).revision == registration_b.revision
  end

  test "registration is Provider-private and revoke fences the referenced Compute generation" do
    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "registration",
        tenant_id: "tenant",
        group_id: "group",
        device_id: "device",
        enrollment_token: String.duplicate("a", 32)
      })

    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool",
        tenant_id: "tenant",
        name: "default",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]}
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "project",
        pool_id: pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding",
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration.id,
        generation: 1
      })

    make_registration_available(registration.id, "90")

    {:ok, _allocation} =
      Compute.allocate(%{
        id: "allocation",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    {1, _} =
      Repo.update_all(
        from(a in Compute.Allocation, where: a.id == "allocation"),
        set: [status: "ready"]
      )

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "91",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    omitted = Repo.get!(Compute.ProviderBinding, binding.id)
    assert omitted.status == "available"
    assert omitted.observation["admission"] == "accepting"

    duplicate = %{
      "allocationId" => "allocation",
      "revision" => "1",
      "state" => "ALLOCATION_STATE_READY"
    }

    assert {:error, :invalid_observation} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "92",
               "inventoryWatermark" => 0,
               "inventory" => [duplicate, duplicate]
             })

    assert {:error, :invalid_observation} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "93",
               "inventoryWatermark" => 0,
               "inventory" => [Map.put(duplicate, "allocationId", "unknown-allocation")]
             })

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => "allocation",
                   "revision" => "1",
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    assert Repo.get!(Compute.Allocation, "allocation").status == "ready"

    allocation = Repo.get!(Compute.Allocation, "allocation")

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "meeting_runtime",
        generation: allocation.generation
      })

    deadline = DateTime.add(SystemsClock.utc_now(), 60, :second)

    for {id, classification} <- [{"side", "side_effecting"}, {"read", "read_only"}] do
      assert {:ok, _} =
               Compute.enqueue_command(%{
                 id: id,
                 allocation_id: allocation.id,
                 workload_id: workload.id,
                 request_id: id,
                 kind: id,
                 classification: classification,
                 target_generation: allocation.generation,
                 target_revision: allocation.revision,
                 connection_epoch: "0",
                 payload: %{
                   "workload_generation" => workload.generation,
                   "command_json" => %{"commandId" => id}
                 },
                 deadline_at: deadline
               })

      assert {:ok, %{id: ^id}} =
               AgentVMM.claim_registration_command(registration.id, "gateway", "1")
    end

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway-next", %{
               "connectionEpoch" => "2",
               "inventoryWatermark" => 2,
               "inventory" => [
                 %{
                   "allocationId" => "allocation",
                   "revision" => "2",
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    assert Repo.get!(Compute.Command, "side").status == "unknown_outcome"
    assert Repo.get!(Compute.Command, "read").status == "pending"

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway-stale-inventory", %{
               "connectionEpoch" => "3",
               "inventoryWatermark" => 3,
               "inventory" => [
                 %{
                   "allocationId" => "allocation",
                   "revision" => "1",
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    assert Repo.get!(Compute.Allocation, "allocation").provider_observation[
             "allocation_revision"
           ] == 2

    assert {:ok, disabled} = AgentVMM.configure_registration(registration.id, 1, false)
    assert disabled.status == "disabled"
    assert disabled.desired_enabled == false
    assert Repo.get!(Compute.ProviderBinding, binding.id).status == "disabled"
    assert Repo.get!(Compute.Allocation, "allocation").status == "draining"
    assert Repo.get!(Compute.Environment, environment.id).desired_state == "ready"

    assert {:ok, revoked} = AgentVMM.revoke_registration("tenant", registration.id, 2)
    assert revoked.status == "revoked"
    # Registration seals authority immediately; provider projections do not own it.
    assert {:error, :revision_conflict} =
             AgentVMM.configure_registration(registration.id, revoked.revision, true)

    assert {:error, :registration_inactive} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "4",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    assert {:ok, %{unknown_outcome: 0, pending: 0}} =
             AgentVMM.mark_connection_lost(registration.id, "gateway-stale-inventory", "3")

    assert {:ok, _} = SalixStore.ComputeWorkloadDeletion.retire_revoked()
    retired = Repo.get!(Compute.Allocation, "allocation")
    assert retired.status == "released"
    assert retired.provider_observation["cloud_retired"]
    assert retired.provider_observation["data_deleted"] != true
    assert Repo.get!(Compute.Environment, environment.id).desired_state == "ready"
    assert Repo.get!(Compute.Environment, environment.id).generation == 1
    assert {:ok, %{settled: 0, release_retries: 0}} = AgentVMM.settle_expired_commands()

    release =
      Repo.get_by!(Compute.Command, allocation_id: "allocation", kind: "allocation.release")

    assert release.status == "cancelled"
  end

  test "reconnect preserves the current durable allocation" do
    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "registration",
        tenant_id: "tenant",
        group_id: "group",
        device_id: "device",
        enrollment_token: String.duplicate("a", 32)
      })

    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool",
        tenant_id: "tenant",
        name: "default",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]}
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "project",
        pool_id: pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding",
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration.id,
        generation: 1
      })

    make_registration_available(registration.id, "90")

    {:ok, _allocation} =
      Compute.allocate(%{
        id: "allocation",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => "allocation",
                   "revision" => "1",
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    assert {:error, :stale_connection} =
             AgentVMM.observe_registration(registration.id, "gateway-replay", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => "allocation",
                   "revision" => "1",
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    allocation = Repo.get!(Compute.Allocation, "allocation")
    allocation_revision = allocation.provider_observation["allocation_revision"]

    inventory = %{
      "allocationId" => allocation.id,
      "revision" => Integer.to_string(allocation_revision),
      "state" => "ALLOCATION_STATE_READY"
    }

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway-next", %{
               "connectionEpoch" => "2",
               "inventoryWatermark" => 2,
               "inventory" => [inventory]
             })

    reconnected = Repo.get!(Compute.Allocation, allocation.id)
    assert reconnected.status == "ready"
    assert reconnected.generation == allocation.generation
    assert reconnected.provider_observation["allocation_revision"] == allocation_revision

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway-next-2", %{
               "connectionEpoch" => "3",
               "inventoryWatermark" => 3,
               "inventory" => []
             })

    assert Repo.get!(Compute.ProviderBinding, binding.id).status == "available"
    assert Repo.get!(Compute.Allocation, allocation.id).status == "ready"

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [status: "released"]
    )

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway-after-release", %{
               "connectionEpoch" => "4",
               "inventoryWatermark" => 4,
               "inventory" => [inventory]
             })

    assert Repo.get!(Compute.Allocation, allocation.id).status == "released"
  end

  defp make_registration_available(registration_id, epoch) do
    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration_id, "bootstrap-gateway", %{
               "connectionEpoch" => epoch,
               "inventoryWatermark" => 0,
               "inventory" => []
             })
  end
end
