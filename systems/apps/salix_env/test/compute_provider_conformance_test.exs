defmodule SalixEnv.ComputeProviderConformanceTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias SalixEnv.ComputeProvider
  alias SalixEnv.ComputeProviders.AgentVMM
  alias SalixWeb.ComputeProviders.Cloudflare
  alias SalixStore.{Compute, Repo}

  setup do
    SalixStore.RepoTestSetup.ensure!()

    Repo.query!(
      "TRUNCATE agent_vmm_audit_events, agent_vmm_sessions, compute_commands, compute_grants, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    :ok
  end

  test "Agent VMM satisfies lifecycle through current Compute generation only" do
    fixture = compute_fixture()
    workload = fixture.workload
    allocation = %{id: fixture.allocation.id, provider_ref: "registration"}

    assert {:ok, %{outcome: :pending}} = AgentVMM.observe(allocation, [])

    assert {:ok, _} =
             Compute.observe_allocation(
               fixture.allocation.id,
               fixture.allocation.revision,
               fixture.allocation.generation,
               "ready",
               "succeeded"
             )

    assert {:ok, %{outcome: :pending}} = AgentVMM.allocate(allocation, workload, [])

    assert {:ok, :ok} =
             SalixStore.AgentVMM.observe_registration("registration", "gateway", %{
               "connectionEpoch" => "9223372036854775808",
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => fixture.allocation.id,
                   "revision" => "1",
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    assert_conformance(AgentVMM, allocation, workload, credential(workload.id), [],
      checkpoint_restore: false,
      required_capabilities: [:runtime_exec, :runtime_process, :service_private]
    )

    assert {:error, :revision_conflict} =
             Compute.update_environment_intent(fixture.environment.id, 1, %{
               desired_state: "draining"
             })

    # Inventory observations can advance revision without changing generation.
    # Read and update under one lock so this checks generation fencing deterministically.
    assert {:ok, {:ok, advanced}} =
             Repo.transaction(fn ->
               current =
                 Repo.one!(
                   from(e in Compute.Environment,
                     where: e.id == ^fixture.environment.id,
                     lock: "FOR UPDATE"
                   )
                 )

               Compute.update_environment_intent(current.id, current.revision, %{
                 desired_state: "draining"
               })
             end)

    assert advanced.generation == 2
    assert {:error, :stale_generation} = AgentVMM.allocate(allocation, workload, [])
  end

  test "Agent VMM claims persist the delivery epoch before committing an outcome" do
    fixture = compute_fixture()

    assert {:ok, allocation} =
             Compute.observe_allocation(
               fixture.allocation.id,
               fixture.allocation.revision,
               fixture.allocation.generation,
               "ready",
               "succeeded"
             )

    assert {:ok, :ok} =
             SalixStore.AgentVMM.observe_registration("registration", "gateway", %{
               "connectionEpoch" => "7",
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => allocation.id,
                   "revision" => "1",
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    assert {:ok, %{outcome: :pending, command: %{id: command_id}}} =
             AgentVMM.allocate(%{id: allocation.id}, fixture.workload, [])

    persisted = Repo.get!(Compute.Command, command_id)
    assert persisted.connection_epoch == "0"
    refute Map.has_key?(persisted.payload["command_json"], "leaseGeneration")

    assert {:ok, %{id: ^command_id}} =
             SalixStore.AgentVMM.claim_registration_command("registration", "gateway", "7")

    assert Repo.get!(Compute.Command, command_id).connection_epoch == "7"

    assert :ok =
             SalixStore.AgentVMM.commit_registration_result(
               "registration",
               "gateway",
               "7",
               command_id,
               "unknown_outcome",
               %{"reason" => "transport_lost"}
             )

    assert %{status: "unknown_outcome", outcome: "unknown"} =
             Repo.get!(Compute.Command, command_id)
  end

  test "controller sequences restart at one for each connection epoch" do
    fixture = compute_fixture()

    assert {:ok, allocation} =
             Compute.observe_allocation(
               fixture.allocation.id,
               fixture.allocation.revision,
               fixture.allocation.generation,
               "ready",
               "succeeded"
             )

    assert {:ok, :ok} =
             SalixStore.AgentVMM.observe_registration("registration", "gateway", %{
               "connectionEpoch" => "7",
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => allocation.id,
                   "revision" => Integer.to_string(allocation.revision),
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    assert {:ok, %{command: first}} =
             AgentVMM.allocate(%{id: allocation.id}, fixture.workload, [])

    assert {:ok, %{command: second}} =
             AgentVMM.allocate(%{id: allocation.id}, fixture.workload, [])

    assert second.id == first.id
    assert first.connection_epoch == "0"
    assert second.connection_epoch == "0"
    refute Map.has_key?(first.payload["command_json"], "connectionEpoch")
    refute Map.has_key?(first.payload["command_json"], "sequence")
    refute Map.has_key?(second.payload["command_json"], "connectionEpoch")
    refute Map.has_key?(second.payload["command_json"], "sequence")

    assert Repo.get!(SalixStore.AgentVMM.Registration, "registration").next_controller_sequence ==
             1

    assert {:ok, %{id: first_id} = claimed_first} =
             SalixStore.AgentVMM.claim_registration_command("registration", "gateway", "7")

    assert first_id == first.id
    assert claimed_first.payload["command_json"]["connectionEpoch"] == "7"
    assert claimed_first.payload["command_json"]["sequence"] == 1

    assert Repo.get!(SalixStore.AgentVMM.Registration, "registration").next_controller_sequence ==
             2

    assert :ok =
             SalixStore.AgentVMM.commit_registration_result(
               "registration",
               "gateway",
               "7",
               first.id,
               "succeeded",
               %{
                 "result" => %{
                   "allocation" => %{
                     "allocationId" => allocation.id,
                     "revision" => 1
                   }
                 }
               }
             )

    current = Repo.get!(Compute.Allocation, allocation.id)

    assert {:ok, %{command: old_epoch}} =
             AgentVMM.bootstrap(
               current,
               fixture.workload,
               credential(fixture.workload.id),
               []
             )

    refute Map.has_key?(old_epoch.payload["command_json"], "connectionEpoch")
    refute Map.has_key?(old_epoch.payload["command_json"], "sequence")

    assert {:ok, %{id: old_epoch_id} = claimed_old_epoch} =
             SalixStore.AgentVMM.claim_registration_command("registration", "gateway", "7")

    assert old_epoch_id == old_epoch.id
    assert claimed_old_epoch.payload["command_json"]["connectionEpoch"] == "7"
    assert claimed_old_epoch.payload["command_json"]["sequence"] == 2

    assert {:ok, :ok} =
             SalixStore.AgentVMM.observe_registration("registration", "gateway-next", %{
               "connectionEpoch" => "8",
               "inventoryWatermark" => 2,
               "inventory" => [
                 %{
                   "allocationId" => current.id,
                   "revision" => "1",
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    assert Repo.get!(Compute.Command, old_epoch.id).status == "pending"

    assert {:error, :stale_command} =
             SalixStore.AgentVMM.commit_registration_result(
               "registration",
               "gateway",
               "7",
               old_epoch.id,
               "succeeded",
               %{"result" => %{"lease" => %{}}}
             )

    assert {:error, :stale_command} =
             SalixStore.AgentVMM.commit_registration_result(
               "registration",
               "gateway-next",
               "8",
               old_epoch.id,
               "succeeded",
               %{"result" => %{"lease" => %{}}}
             )

    Repo.update_all(from(c in Compute.Command, where: c.id == ^old_epoch.id),
      set: [deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:ok, %{settled: 1, more?: false}} =
             SalixStore.AgentVMM.settle_expired_commands(32, DateTime.utc_now())

    assert {:ok, %{command: next_epoch}} =
             AgentVMM.bootstrap(
               Repo.get!(Compute.Allocation, allocation.id),
               fixture.workload,
               credential(fixture.workload.id),
               []
             )

    refute Map.has_key?(next_epoch.payload["command_json"], "connectionEpoch")
    refute Map.has_key?(next_epoch.payload["command_json"], "sequence")
    assert next_epoch.connection_epoch == "0"
    refute next_epoch.id == old_epoch.id

    assert {:ok, %{id: next_epoch_id} = claimed_next_epoch} =
             SalixStore.AgentVMM.claim_registration_command(
               "registration",
               "gateway-next",
               "8"
             )

    assert next_epoch_id == next_epoch.id
    assert claimed_next_epoch.payload["command_json"]["connectionEpoch"] == "8"
    assert claimed_next_epoch.payload["command_json"]["sequence"] == 1
  end

  test "a rejected delivery consumes one slot without pre-claim gaps" do
    fixture = compute_fixture()

    assert {:ok, allocation} =
             Compute.observe_allocation(
               fixture.allocation.id,
               fixture.allocation.revision,
               fixture.allocation.generation,
               "ready",
               "succeeded"
             )

    assert {:ok, :ok} =
             SalixStore.AgentVMM.observe_registration("registration", "gateway", %{
               "connectionEpoch" => "7",
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => allocation.id,
                   "revision" => Integer.to_string(allocation.revision),
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    assert {:ok, %{command: first}} =
             AgentVMM.allocate(%{id: allocation.id}, fixture.workload, [])

    refute Map.has_key?(first.payload["command_json"], "connectionEpoch")
    refute Map.has_key?(first.payload["command_json"], "sequence")
    assert first.connection_epoch == "0"

    assert Repo.get!(SalixStore.AgentVMM.Registration, "registration").next_controller_sequence ==
             1

    assert {:ok, claimed_first} =
             SalixStore.AgentVMM.claim_registration_command("registration", "gateway", "7")

    assert claimed_first.payload["command_json"]["connectionEpoch"] == "7"
    assert claimed_first.payload["command_json"]["sequence"] == 1

    assert :ok =
             SalixStore.AgentVMM.commit_registration_result(
               "registration",
               "gateway",
               "7",
               claimed_first.id,
               "failed",
               %{"reason" => "semantic_rejection"}
             )

    assert {:ok, %{command: retried}} =
             AgentVMM.allocate(%{id: allocation.id}, fixture.workload, [])

    refute retried.id == first.id
    assert retried.connection_epoch == "0"
    refute Map.has_key?(retried.payload["command_json"], "sequence")

    assert Repo.get!(SalixStore.AgentVMM.Registration, "registration").next_controller_sequence ==
             2

    assert {:ok, claimed_retry} =
             SalixStore.AgentVMM.claim_registration_command("registration", "gateway", "7")

    assert claimed_retry.id == retried.id
    assert claimed_retry.payload["command_json"]["sequence"] == 2
  end

  test "Cloudflare rejects a credential scoped to another Workload" do
    allocation = %{id: "allocation", provider_ref: "resource"}
    workload = %{id: "workload", spec: %{}}
    secret = String.duplicate("s", 40)

    wrong = %{
      "token" => secret,
      "workload_id" => "other",
      "expires_at" => DateTime.add(DateTime.utc_now(), 60)
    }

    assert {:error, :invalid_workload_credential} =
             Cloudflare.bootstrap(allocation, workload, wrong,
               client: :fake,
               client_module: nil
             )
  end

  defp assert_conformance(provider, allocation, workload, credential, opts, expectations) do
    for capability <- expectations[:required_capabilities] do
      assert capability in provider.capabilities()
    end

    allocated_outcome = if provider == AgentVMM, do: :pending, else: :succeeded

    assert {:ok, %{outcome: ^allocated_outcome} = allocated} =
             provider.allocate(allocation, workload, opts) |> ComputeProvider.validate_result()

    refute inspect(allocated) =~ credential["token"]

    assert {:ok, %{outcome: :succeeded}} =
             provider.observe(allocation, opts) |> ComputeProvider.validate_result()

    bootstrap_outcome = if provider == AgentVMM, do: :pending, else: :succeeded

    assert {:ok, %{outcome: ^bootstrap_outcome} = bootstrapped} =
             provider.bootstrap(allocation, workload, credential, opts)
             |> ComputeProvider.validate_result()

    refute inspect(bootstrapped) =~ credential["token"]

    if expectations[:checkpoint_restore] do
      assert {:ok, %{outcome: :succeeded, checkpoint: checkpoint}} =
               provider.checkpoint(allocation, opts) |> ComputeProvider.validate_result()

      assert {:ok, %{outcome: :succeeded}} =
               provider.restore(allocation, checkpoint, opts) |> ComputeProvider.validate_result()
    else
      assert {:error, :unsupported} = provider.checkpoint(allocation, opts)
      assert {:error, :unsupported} = provider.restore(allocation, %{}, opts)
    end

    release_outcome = if provider == AgentVMM, do: :pending, else: :succeeded

    if provider == AgentVMM do
      stored_workload = Repo.get!(Compute.Workload, workload.id)

      assert {:ok, _stopped} =
               Compute.stop_workload(
                 stored_workload.id,
                 stored_workload.revision,
                 "provider_conformance"
               )
    end

    assert {:ok, %{outcome: ^release_outcome}} =
             provider.release(allocation, opts) |> ComputeProvider.validate_result()
  end

  defp credential(workload_id) do
    {:ok, credential} =
      SalixStore.Compute.WorkloadCredential.issue(workload_id, nil, ["runtime"], 60)

    credential
  end

  defp compute_fixture do
    {:ok, registration} =
      SalixStore.AgentVMM.create_registration(%{
        id: "registration",
        tenant_id: "tenant",
        group_id: "group",
        device_id: "device",
        enrollment_token: String.duplicate("a", 32)
      })

    Repo.update_all(
      SalixStore.AgentVMM.Registration,
      set: [status: "ready", desired_enabled: true]
    )

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

    assert {:ok, :ok} =
             SalixStore.AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        spec: resource_v2_spec(),
        generation: 1
      })

    %{environment: environment, allocation: allocation, workload: workload}
  end

  defp resource_v2_spec do
    %{
      "resources" => %{
        "cpu_max_millis" => 1_000,
        "memory_max_bytes" => 536_870_912,
        "pid_max" => 512,
        "writable_quota_bytes" => 2_147_483_648
      }
    }
  end
end
