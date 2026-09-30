defmodule SalixStore.AgentVMMProviderTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias SalixStore.{AgentVMM, Compute, Repo}

  setup do
    previous_gate =
      Application.get_env(:salix_store, :agent_vmm_multi_scope_registration_enabled)

    Application.delete_env(:salix_store, :agent_vmm_multi_scope_registration_enabled)

    on_exit(fn ->
      if is_nil(previous_gate) do
        Application.delete_env(:salix_store, :agent_vmm_multi_scope_registration_enabled)
      else
        Application.put_env(
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

  test "observation and disable use one database lock order" do
    assert {:ok, registration} =
             AgentVMM.create_registration(%{
               id: "lock-order-registration",
               tenant_id: "tenant",
               group_id: "group",
               device_id: "device",
               enrollment_token: String.duplicate("a", 32)
             })

    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    assert {:ok, pool} =
             Compute.create_pool(%{
               id: "lock-order-pool",
               tenant_id: "tenant",
               name: "lock-order",
               region: "local",
               provider_policy: %{"providers" => ["agent_vmm"]}
             })

    assert {:ok, environment} =
             Compute.create_environment(%{
               id: "lock-order-environment",
               tenant_id: "tenant",
               owner_type: "project",
               owner_id: "project",
               pool_id: pool.id
             })

    assert {:ok, _binding} =
             Compute.create_provider_binding(%{
               id: "lock-order-binding",
               pool_id: pool.id,
               environment_id: environment.id,
               provider: "agent_vmm",
               provider_ref: registration.id,
               generation: 1
             })

    parent = self()

    blocker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(r in AgentVMM.Registration,
              where: r.id == ^registration.id,
              lock: "FOR UPDATE"
            )
          )

          send(parent, :registration_locked)
          receive do: (:release_registration -> :ok)
        end)
      end)

    assert_receive :registration_locked

    observation =
      Task.async(fn ->
        AgentVMM.observe_registration(registration.id, "gateway", %{
          "connectionEpoch" => "1",
          "inventoryWatermark" => 0,
          "inventory" => []
        })
      end)

    disable =
      Task.async(fn ->
        AgentVMM.configure_registration(registration.id, registration.revision, false)
      end)

    send(blocker.pid, :release_registration)
    assert {:ok, :ok} = Task.await(blocker)

    results = [Task.await(observation), Task.await(disable)]
    refute {:error, :unavailable} in results
    assert Enum.any?(results, &match?({:ok, %AgentVMM.Registration{}}, &1))

    assert Enum.any?(results, &match?({:ok, :ok}, &1)) or
             Enum.any?(results, &match?({:error, :registration_inactive}, &1))
  end

  test "multi-scope registration remains fail closed after the legacy index contract" do
    attrs = %{
      id: "registration-a",
      tenant_id: "tenant",
      group_id: "group-a",
      device_id: "shared-device",
      enrollment_token: String.duplicate("a", 32)
    }

    assert {:ok, _registration} = AgentVMM.create_registration(attrs)

    assert {:error, :multi_scope_disabled} =
             AgentVMM.create_registration(%{
               attrs
               | id: "registration-b",
                 group_id: "group-b",
                 enrollment_token: String.duplicate("b", 32)
             })

    assert Repo.aggregate(AgentVMM.Registration, :count) == 1

    indexes =
      Repo.query!("""
      SELECT index_class.relname, index_meta.indisunique, index_meta.indisvalid, index_meta.indisready
      FROM pg_index AS index_meta
      JOIN pg_class AS table_class ON table_class.oid = index_meta.indrelid
      JOIN pg_class AS index_class ON index_class.oid = index_meta.indexrelid
      JOIN pg_namespace AS namespace ON namespace.oid = table_class.relnamespace
      WHERE namespace.nspname = current_schema()
        AND table_class.relname = 'agent_vmm_registrations'
        AND index_class.relname IN (
          'agent_vmm_registrations_tenant_id_device_id_index',
          'agent_vmm_registrations_tenant_id_group_id_device_id_index'
        )
      ORDER BY index_class.relname
      """).rows

    assert Enum.map(indexes, &hd/1) == [
             "agent_vmm_registrations_tenant_id_group_id_device_id_index"
           ]

    assert Enum.all?(indexes, fn [_name, unique, valid, ready] ->
             unique and valid and ready
           end)
  end

  test "replacement expand keeps the full fence while active-only uniqueness is ready" do
    attrs = %{
      id: "registration-old",
      tenant_id: "tenant",
      group_id: "group",
      device_id: "device",
      enrollment_token: String.duplicate("a", 32)
    }

    assert {:ok, old} = AgentVMM.create_registration(attrs)
    assert {:ok, revoked} = AgentVMM.revoke_registration("tenant", old.id, old.revision)
    assert revoked.status == "revoked"

    assert {:error, :already_exists} =
             AgentVMM.create_registration(%{
               attrs
               | id: "registration-replacement",
                 enrollment_token: String.duplicate("b", 32)
             })

    assert [[true, true, "(status <> 'revoked'::text)"]] =
             Repo.query!("""
             SELECT index_meta.indisvalid, index_meta.indisready,
                    pg_get_expr(index_meta.indpred, index_meta.indrelid)
             FROM pg_index AS index_meta
             JOIN pg_class AS index_class ON index_class.oid = index_meta.indexrelid
             WHERE index_class.relname = 'agent_vmm_registrations_active_scope_device_index'
             """).rows
  end

  test "revoked registrations in another scope do not block a fresh enrollment" do
    attrs = %{
      id: "registration-revoked-scope",
      tenant_id: "tenant",
      group_id: "group-old",
      device_id: "shared-device",
      enrollment_token: String.duplicate("a", 32)
    }

    assert {:ok, old} = AgentVMM.create_registration(attrs)
    assert {:ok, _revoked} = AgentVMM.revoke_registration("tenant", old.id, old.revision)

    assert {:ok, replacement} =
             AgentVMM.create_registration(%{
               attrs
               | id: "registration-new-scope",
                 group_id: "group-new",
                 enrollment_token: String.duplicate("b", 32)
             })

    assert replacement.status == "disabled"
  end

  test "revoked tombstones do not consume the active tenant quota" do
    previous_limit = Application.get_env(:salix_store, :agent_vmm_registration_limit_per_tenant)
    Application.put_env(:salix_store, :agent_vmm_registration_limit_per_tenant, 1)

    on_exit(fn ->
      if is_nil(previous_limit) do
        Application.delete_env(:salix_store, :agent_vmm_registration_limit_per_tenant)
      else
        Application.put_env(
          :salix_store,
          :agent_vmm_registration_limit_per_tenant,
          previous_limit
        )
      end
    end)

    assert {:ok, first} =
             AgentVMM.create_registration(%{
               id: "registration-old",
               tenant_id: "tenant",
               group_id: "group-old",
               device_id: "device-old",
               enrollment_token: String.duplicate("a", 32)
             })

    assert {:ok, _revoked} = AgentVMM.revoke_registration("tenant", first.id, first.revision)

    assert {:ok, _active} =
             AgentVMM.create_registration(%{
               id: "registration-active",
               tenant_id: "tenant",
               group_id: "group-active",
               device_id: "device-active",
               enrollment_token: String.duplicate("b", 32)
             })
  end

  test "scope rollout gate activates only the binding shape safe for the deployed readers" do
    previous_scope_gate =
      Application.get_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled)

    on_exit(fn ->
      if is_nil(previous_scope_gate) do
        Application.delete_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled)
      else
        Application.put_env(
          :salix_store,
          :agent_vmm_environment_scoped_bindings_enabled,
          previous_scope_gate
        )
      end
    end)

    assert {:ok, registration} =
             AgentVMM.create_registration(%{
               id: "rollout-registration",
               tenant_id: "tenant",
               group_id: "group",
               device_id: "device",
               enrollment_token: String.duplicate("a", 32)
             })

    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    assert {:ok, pool} =
             Compute.create_pool(%{
               id: "rollout-pool",
               tenant_id: "tenant",
               name: "rollout",
               region: "local",
               provider_policy: %{"providers" => ["agent_vmm"]}
             })

    assert {:ok, environment} =
             Compute.create_environment(%{
               id: "rollout-environment",
               tenant_id: "tenant",
               owner_type: "project",
               owner_id: "project",
               pool_id: pool.id
             })

    now = DateTime.utc_now()

    {2, _} =
      Repo.insert_all(Compute.ProviderBinding, [
        %{
          id: "rollout-legacy",
          pool_id: pool.id,
          environment_id: nil,
          provider: "agent_vmm",
          provider_ref: registration.id,
          status: "disabled",
          generation: 1,
          revision: 1,
          observation: %{},
          updated_at: now
        },
        %{
          id: "rollout-scoped",
          pool_id: pool.id,
          environment_id: environment.id,
          provider: "agent_vmm",
          provider_ref: registration.id,
          status: "disabled",
          generation: 1,
          revision: 1,
          observation: %{},
          updated_at: now
        }
      ])

    Application.put_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled, false)
    make_registration_available(registration.id, "101")
    assert Repo.get!(Compute.ProviderBinding, "rollout-legacy").status == "available"
    assert Repo.get!(Compute.ProviderBinding, "rollout-scoped").status == "disabled"
    assert Repo.get!(Compute.Environment, environment.id).observed_state == "pending"

    Application.put_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled, true)

    {:ok, replacement_pool} =
      Compute.create_pool(%{
        id: "replacement-pool",
        tenant_id: "tenant",
        name: "replacement",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec"]
      })

    Repo.update_all(from(e in Compute.Environment, where: e.id == ^environment.id),
      set: [generation: 2, pool_id: replacement_pool.id, observed_state: "pending"],
      inc: [revision: 1]
    )

    make_registration_available(registration.id, "102")
    scoped_binding = Repo.get!(Compute.ProviderBinding, "rollout-scoped")
    assert scoped_binding.status == "available"
    assert scoped_binding.generation == 2
    assert Repo.get!(Compute.Environment, environment.id).observed_state == "pending"

    assert {:ok, _replacement_binding} =
             Compute.create_provider_binding(%{
               id: "rollout-replacement",
               pool_id: replacement_pool.id,
               environment_id: environment.id,
               provider: "agent_vmm",
               provider_ref: registration.id,
               generation: 2
             })

    make_registration_available(registration.id, "103")
    assert Repo.get!(Compute.Environment, environment.id).observed_state == "ready"
  end

  test "registration observation admits more than 64 idle bindings without an inventory total gate" do
    Application.put_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled, true)

    assert {:ok, registration} =
             AgentVMM.create_registration(%{
               id: "bounded-registration",
               tenant_id: "tenant",
               group_id: "group",
               device_id: "device",
               enrollment_token: String.duplicate("a", 32)
             })

    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    assert {:ok, pool} =
             Compute.create_pool(%{
               id: "bounded-pool",
               tenant_id: "tenant",
               name: "bounded",
               region: "local",
               provider_policy: %{"providers" => ["agent_vmm"]}
             })

    for index <- 1..65 do
      assert {:ok, environment} =
               Compute.create_environment(%{
                 id: "bounded-environment-#{index}",
                 tenant_id: "tenant",
                 owner_type: "project",
                 owner_id: "project-#{index}",
                 pool_id: pool.id
               })

      assert {:ok, _binding} =
               Compute.create_provider_binding(%{
                 id: "bounded-binding-#{index}",
                 pool_id: pool.id,
                 environment_id: environment.id,
                 provider: "agent_vmm",
                 provider_ref: registration.id,
                 generation: 1
               })
    end

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    assert Repo.aggregate(Compute.ProviderBinding, :count) == 65

    assert Repo.aggregate(
             from(b in Compute.ProviderBinding, where: b.status == "available"),
             :count
           ) ==
             65
  end

  test "gate enable isolates distinct project scopes on one Host" do
    Application.put_env(:salix_store, :agent_vmm_multi_scope_registration_enabled, true)

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
        kind: "external_worker",
        generation: allocation.generation
      })

    deadline = DateTime.add(DateTime.utc_now(), 60, :second)

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
    assert Repo.get!(Compute.ProviderBinding, binding.id).status == "revoked"
    assert Repo.get!(Compute.Allocation, "allocation").status == "draining"
    assert Repo.get!(Compute.Environment, environment.id).desired_state == "ready"
    assert Repo.get!(Compute.Environment, environment.id).generation == 1

    assert {:ok, %{unknown_outcome: 0, pending: 0}} =
             AgentVMM.mark_connection_lost(
               registration.id,
               "gateway-stale-inventory",
               "3"
             )

    assert Repo.get!(Compute.ProviderBinding, binding.id).status == "revoked"

    release =
      Repo.get_by!(Compute.Command, allocation_id: "allocation", kind: "allocation.release")

    expired_at = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.update_all(from(c in Compute.Command, where: c.id == ^release.id),
      set: [deadline_at: expired_at]
    )

    assert {:ok, %{settled: 1, release_retries: 0}} =
             AgentVMM.settle_expired_commands(32, DateTime.utc_now())

    assert {:ok, %{settled: 0, release_retries: 0, release_blocked: 1}} =
             AgentVMM.settle_expired_commands(32, DateTime.add(DateTime.utc_now(), 6, :second))

    failed_allocation = Repo.get!(Compute.Allocation, "allocation")
    failed_release = Repo.get!(Compute.Command, release.id)
    assert failed_allocation.status == "failed"
    assert failed_allocation.operation_outcome == "failed"
    assert failed_release.status == "failed"
    assert failed_release.next_attempt_at == nil

    assert failed_release.evidence == %{
             "reason" => "provider_binding_revoked",
             "action" => "rebuild_provider_scope"
           }
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

  test "an admitted provider command outlives the reconciler claim" do
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

    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    {:ok, allocation} = Compute.observe_allocation(allocation.id, 1, 1, "ready", "succeeded")

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
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

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        spec: %{
          "resources" => %{
            "cpu_max_millis" => 2_000,
            "memory_max_bytes" => 2_147_483_648,
            "pid_max" => 512,
            "writable_quota_bytes" => 2_147_483_648
          },
          "egress_mode" => "public_internet"
        },
        generation: 1
      })

    now = DateTime.utc_now()
    claim_token = "provider-claim-token"

    Repo.insert!(%Compute.ReconcilerClaim{
      id: "agent_vmm:workload:1",
      provider: "agent_vmm",
      workload_id: workload.id,
      generation: workload.generation,
      claim_token: claim_token,
      attempt_count: 1,
      lease_expires_at: DateTime.add(now, 60, :second),
      created_at: now,
      updated_at: now
    })

    assert {:ok, %{outcome: :pending, command: command}} =
             SalixEnv.ComputeProviders.AgentVMM.allocate(
               %{id: allocation.id},
               workload,
               claim_token: claim_token
             )

    refute Map.has_key?(command.payload["command_json"], "claimToken")

    command_id = command.id

    assert {:ok, %{id: ^command_id}} =
             AgentVMM.claim_registration_command(registration.id, "gateway", "7")

    Repo.update_all(Compute.ReconcilerClaim,
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert :ok =
             AgentVMM.commit_registration_result(
               registration.id,
               "gateway",
               "7",
               command.id,
               "succeeded",
               %{
                 "result" => %{
                   "allocation" => %{
                     "allocationId" => allocation.id,
                     "revision" => "2"
                   }
                 }
               }
             )

    assert Repo.get!(Compute.Command, command.id).status == "succeeded"
  end

  test "allocation membership change keeps exact command admission open" do
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

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
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
        generation: allocation.generation
      })

    deadline = DateTime.add(DateTime.utc_now(), 60, :second)

    {:ok, _} =
      Compute.enqueue_command(%{
        id: "ensure",
        allocation_id: allocation.id,
        workload_id: workload.id,
        request_id: "ensure",
        kind: "allocation.ensure",
        classification: "desired_state",
        target_generation: 1,
        target_revision: allocation.revision,
        connection_epoch: "0",
        payload: %{
          "workload_generation" => workload.generation,
          "command_json" => %{"commandId" => "ensure"}
        },
        deadline_at: deadline
      })

    assert {:ok, %{id: "ensure"}} =
             AgentVMM.claim_registration_command(registration.id, "gateway", "1")

    assert :ok =
             AgentVMM.commit_registration_result(
               registration.id,
               "gateway",
               "1",
               "ensure",
               "succeeded",
               %{
                 "result" => %{
                   "allocation" => %{"allocationId" => allocation.id, "revision" => "1"}
                 }
               }
             )

    current_binding = Repo.get!(Compute.ProviderBinding, binding.id)
    assert current_binding.observation["admission"] == "accepting"

    current = Repo.get!(Compute.Allocation, allocation.id)

    {:ok, _} =
      Compute.enqueue_command(%{
        id: "blocked",
        allocation_id: current.id,
        workload_id: workload.id,
        request_id: "blocked",
        kind: "allocation.ensure",
        classification: "desired_state",
        target_generation: 1,
        target_revision: current.revision,
        payload: %{
          "workload_generation" => workload.generation,
          "command_json" => %{"commandId" => "blocked"}
        },
        deadline_at: deadline
      })

    assert {:ok, %{id: "blocked"}} =
             AgentVMM.claim_registration_command(registration.id, "gateway", "1")

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway-next", %{
               "connectionEpoch" => "2",
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => allocation.id,
                   "revision" => "1",
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    reopened = Repo.get!(Compute.ProviderBinding, binding.id)
    assert reopened.observation["admission"] == "accepting"
    assert reopened.observation["inventory_snapshot_bounded"] == true
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
