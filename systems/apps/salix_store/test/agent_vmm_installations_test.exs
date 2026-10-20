defmodule SalixStore.AgentVMMInstallationsTest do
  use SystemsClock.Case, async: false

  import Ecto.Query

  alias SalixStore.{
    AgentVMM,
    AgentVMMInstallations,
    Compute,
    Repo
  }

  alias SalixStore.AgentVMMInstallations.Operation

  setup do
    Repo.query!(
      "TRUNCATE agent_vmm_install_operations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    assert {:ok, pool} =
             Compute.create_pool(%{
               id: "pool",
               tenant_id: "tenant",
               name: "default",
               region: "auto",
               provider_policy: %{"providers" => ["agent_vmm"]},
               capabilities: ["runtime_exec", "runtime_process", "service_private"]
             })

    assert {:ok, _environment} =
             Compute.create_environment(%{
               id: "environment",
               tenant_id: "tenant",
               owner_type: "project",
               owner_id: "project",
               pool_id: pool.id
             })

    :ok
  end

  test "ordinary owner commit rechecks a Session that became inactive after initial validation" do
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())

    options = [
      expected_authorization: descriptor.operation,
      authorize: fn -> {:error, :not_found} end
    ]

    for mutate <- [
          fn -> AgentVMMInstallations.retry(descriptor.operation.id, options) end,
          fn -> AgentVMMInstallations.revoke(descriptor.operation.id, options) end,
          fn ->
            AgentVMMInstallations.configure_registration(descriptor.operation.id, true, options)
          end,
          fn -> AgentVMMInstallations.initialize_workload(descriptor.operation.id, options) end
        ] do
      assert {:error, :authorization_changed} = mutate.()
    end

    assert Repo.get!(Operation, descriptor.operation.id).revision == descriptor.operation.revision
  end

  test "dedicated possession proof recovers the original installation once and fences old management" do
    {identity, private_key} = recovery_identity()

    attrs =
      Map.merge(request_attrs(), %{
        surface: "comma",
        delivery_target_type: "comma_main_device",
        delivery_target_id: "old-session",
        authorizing_subject_id: "original-subject",
        authorizing_audience: "https://api.example.test"
      })

    assert {:ok, descriptor} = AgentVMMInstallations.request(attrs)

    assert {:ok, exchanged} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, identity)

    assert {:ok, original} =
             AgentVMMInstallations.acknowledge(
               descriptor.operation.id,
               descriptor.one_time_secret,
               exchanged.host_identity_digest
             )

    authority = recovery_authority()
    options = [authorize: fn -> :ok end]

    assert {:ok, issued} =
             AgentVMMInstallations.recovery_challenge(original.id, authority, options)

    assert {:ok, wire} = SalixStore.AgentVMMRecovery.wire(issued.challenge)
    proof = recovery_proof(identity, private_key, issued.challenge["nonce"], wire)

    assert {:error, :invalid_recovery_proof} =
             AgentVMMInstallations.recover(
               original.id,
               authority,
               %{proof | "root_key_revision" => 2},
               true,
               options
             )

    assert {:ok, preview} =
             AgentVMMInstallations.recover(original.id, authority, proof, false, options)

    assert preview.delivery_target_id == "old-session"

    assert {:ok, recovered} =
             AgentVMMInstallations.recover(original.id, authority, proof, true, options)

    assert recovered.delivery_target_id == "new-session"
    assert recovered.registration_id == original.registration_id
    assert recovered.environment_id == original.environment_id
    assert recovered.authorization_status == "handed_off"

    assert {:error, :invalid_recovery_challenge} =
             AgentVMMInstallations.recover(original.id, authority, proof, true, options)

    assert {:error, :authorization_changed} =
             AgentVMMInstallations.configure_registration(original.id, false,
               expected_authorization: original
             )

    assert {:error, :authorization_changed} =
             AgentVMMInstallations.revoke(original.id, expected_authorization: original)

    assert {:error, :authorization_changed} =
             AgentVMMInstallations.initialize_workload(original.id,
               expected_authorization: original
             )

    assert {:error, :not_found} =
             AgentVMMInstallations.recovery_challenge(
               original.id,
               %{authority | subject: "another-subject"},
               options
             )

    assert {:error, :not_found} =
             AgentVMMInstallations.recovery_challenge(
               original.id,
               %{authority | audience: "https://other.example.test"},
               options
             )

    assert {:error, :not_found} =
             AgentVMMInstallations.recovery_challenge(original.id, authority,
               authorize: fn -> {:error, :forbidden} end
             )
  end

  test "legacy recovery requires an original Session relationship and expires without transferring authority" do
    {identity, private_key} = recovery_identity()

    attrs =
      Map.merge(request_attrs(), %{
        surface: "comma",
        delivery_target_type: "comma_main_device",
        delivery_target_id: "old-session"
      })

    assert {:ok, descriptor} = AgentVMMInstallations.request(attrs)

    assert {:ok, exchanged} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, identity)

    assert {:ok, original} =
             AgentVMMInstallations.acknowledge(
               descriptor.operation.id,
               descriptor.one_time_secret,
               exchanged.host_identity_digest
             )

    authority = recovery_authority()
    unknown = [authorize: fn -> :ok end, original_subject: fn _, _ -> {:error, :not_found} end]

    assert {:error, :original_subject_unknown} =
             AgentVMMInstallations.recovery_challenge(original.id, authority, unknown)

    assert Repo.get!(Operation, original.id).authorizing_subject_id == nil
    now = SystemsClock.utc_now()

    known = [
      authorize: fn -> :ok end,
      original_subject: fn "comma_main_device", "old-session" -> {:ok, "original-subject"} end,
      now: now
    ]

    assert {:ok, candidates} =
             AgentVMMInstallations.recovery_candidates(
               [original.registration_id, "unrelated"],
               authority,
               known
             )

    assert [issued] = candidates
    assert Repo.get!(Operation, original.id).authorizing_subject_id == "original-subject"
    assert {:ok, wire} = SalixStore.AgentVMMRecovery.wire(issued.challenge)
    proof = recovery_proof(identity, private_key, issued.challenge["nonce"], wire)
    expired = Keyword.put(known, :now, DateTime.add(now, 120, :second))

    assert {:error, :invalid_recovery_challenge} =
             AgentVMMInstallations.recover(original.id, authority, proof, true, expired)

    assert Repo.get!(Operation, original.id).delivery_target_id == "old-session"
    assert {:ok, _} = AgentVMMInstallations.revoke(original.id)

    assert {:error, :recovery_target_unavailable} =
             AgentVMMInstallations.recovery_challenge(original.id, authority, known)
  end

  test "idempotent request rotates only the current secret and preserves identities" do
    assert {:ok, first} = AgentVMMInstallations.request(request_attrs())
    assert {:ok, second} = AgentVMMInstallations.request(request_attrs())

    assert first.operation.id == second.operation.id
    assert first.operation.registration_id == second.operation.registration_id
    assert second.operation.ticket_generation == 2
    refute first.one_time_secret == second.one_time_secret

    stored = Repo.get!(Operation, first.operation.id)
    assert stored.authorization_status == "requested"
    assert stored.ticket_status == "active"
    assert stored.ticket_generation == 2
    refute Map.has_key?(second.operation, :ticket_secret_hash)
    refute Map.has_key?(second.operation, :material_ciphertext)

    assert {:error, :invalid_ticket} =
             exchange(first.operation.id, first.one_time_secret, host_identity())

    assert {:ok, result} = exchange(second.operation.id, second.one_time_secret, host_identity())
    assert result.operation.authorization_status == "exchange_committed"

    assert result.material["remote_enrollment"]["registration_id"] ==
             second.operation.registration_id

    assert %AgentVMM.Registration{device_id: "host-device"} =
             Repo.get(AgentVMM.Registration, second.operation.registration_id)

    assert %Compute.ProviderBinding{
             environment_id: "environment",
             status: "disabled"
           } =
             binding =
             Repo.get_by(Compute.ProviderBinding,
               environment_id: "environment",
               provider_ref: second.operation.registration_id
             )

    assert binding.provider_ref == second.operation.registration_id

    assert {:error, :provider_managed_by_observation} =
             Compute.update_provider_binding(binding.id, binding.revision, %{status: "available"})

    assert {:error, :provider_managed_by_observation} =
             Compute.update_provider_binding(binding.id, binding.revision, %{
               provider_ref: "other-registration"
             })

    assert Repo.get!(Compute.ProviderBinding, binding.id).status == "disabled"
  end

  test "reused idempotency key cannot change its authorization binding" do
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())

    changed = %{request_attrs() | delivery_target_id: "runner-b"}
    assert {:error, :idempotency_conflict} = AgentVMMInstallations.request(changed)

    assert {:ok, operation} = AgentVMMInstallations.get(descriptor.operation.id)
    assert operation.delivery_target_id == "runner-a"
    assert operation.ticket_generation == 1
  end

  test "exact runner terminal report closes redelivery and revokes committed material" do
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())

    assert {:ok, failed} =
             AgentVMMInstallations.report_delivery_failure(
               "bft_runner",
               "runner-a",
               descriptor.operation.id,
               "agent_vmm.install_failed"
             )

    assert failed.authorization_status == "action_required"
    assert failed.error_code == "agent_vmm.install_failed"

    assert {:error, :operation_not_retryable} =
             AgentVMMInstallations.retry(descriptor.operation.id)

    assert {:error, :no_pending_operation} =
             AgentVMMInstallations.deliver_next("bft_runner", "runner-a")

    assert {:ok, repeated} =
             AgentVMMInstallations.report_delivery_failure(
               "bft_runner",
               "runner-a",
               descriptor.operation.id,
               "agent_vmm.install_failed"
             )

    assert repeated.authorization_status == "action_required"

    assert {:error, :delivery_target_mismatch} =
             AgentVMMInstallations.report_delivery_failure(
               "bft_runner",
               "runner-b",
               descriptor.operation.id,
               "agent_vmm.install_failed"
             )

    assert {:ok, committed_descriptor} =
             AgentVMMInstallations.request(%{request_attrs() | client_request_id: "committed"})

    assert {:ok, _} =
             exchange(
               committed_descriptor.operation.id,
               committed_descriptor.one_time_secret,
               host_identity()
             )

    assert {:ok, committed_failed} =
             AgentVMMInstallations.report_delivery_failure(
               "bft_runner",
               "runner-a",
               committed_descriptor.operation.id,
               "agent_vmm.managed_enrollment_invalid"
             )

    assert committed_failed.authorization_status == "action_required"
    assert is_nil(Repo.get!(Operation, committed_descriptor.operation.id).material_ciphertext)

    assert Repo.get!(AgentVMM.Registration, committed_descriptor.operation.registration_id).status ==
             "revoked"
  end

  test "desired registration controls are secret-free, target-scoped, and cursor-bounded" do
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())

    assert {:ok, exchanged} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity())

    assert {:ok, _operation} =
             AgentVMMInstallations.acknowledge(
               descriptor.operation.id,
               descriptor.one_time_secret,
               host_identity_digest()
             )

    assert {:ok, %{controls: [], next_cursor: nil}} =
             AgentVMMInstallations.control_page("bft_runner", "runner-b", nil, 1)

    assert {:ok, %{controls: [enabled], next_cursor: cursor}} =
             AgentVMMInstallations.control_page("bft_runner", "runner-a", nil, 1)

    assert enabled.operation_id == descriptor.operation.id
    assert enabled.registration_id == descriptor.operation.registration_id
    assert enabled.registration_revision == 1
    assert enabled.state == "enabled"
    assert cursor == descriptor.operation.id
    refute Map.has_key?(enabled, :one_time_secret)

    assert {:ok, %{controls: [], next_cursor: nil}} =
             AgentVMMInstallations.control_page("bft_runner", "runner-a", cursor, 1)

    assert {:ok, _operation} =
             AgentVMMInstallations.configure_registration(descriptor.operation.id, false)

    assert {:ok, %{controls: [draining]}} =
             AgentVMMInstallations.control_page("bft_runner", "runner-a", nil, 1)

    assert draining.registration_id == descriptor.operation.registration_id
    assert draining.registration_revision == 2
    assert draining.state == "draining"

    assert {:ok, _operation} = AgentVMMInstallations.revoke(descriptor.operation.id)

    assert {:ok, %{controls: [], next_cursor: nil}} =
             AgentVMMInstallations.control_page("bft_runner", "runner-a", nil, 1)
  end

  test "request requires the exact ready Environment owned by its immutable scope" do
    assert {:error, :invalid_install_environment} =
             AgentVMMInstallations.request(%{request_attrs() | scope_key: "other-project"})

    assert Repo.aggregate(Operation, :count) == 0

    assert {:ok, _wrong_type_environment} =
             Compute.create_environment(%{
               id: "wrong-type-environment",
               tenant_id: "tenant",
               owner_type: "swarm",
               owner_id: "project",
               pool_id: "pool"
             })

    assert {:error, :invalid_install_environment} =
             AgentVMMInstallations.request(%{
               request_attrs()
               | environment_id: "wrong-type-environment",
                 client_request_id: "wrong-type-request"
             })

    assert Repo.aggregate(Operation, :count) == 0

    assert {:ok, environment} =
             Compute.update_environment_intent("environment", 1, %{desired_state: "draining"})

    assert environment.desired_state == "draining"

    assert {:error, :invalid_install_environment} =
             AgentVMMInstallations.request(request_attrs())

    assert Repo.aggregate(Operation, :count) == 0
  end

  test "exchange response recovery is fixed to the current secret and Host" do
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())

    assert {:ok, first} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity())

    assert {:ok, second} =
             AgentVMMInstallations.exchange(
               descriptor.operation.id,
               descriptor.one_time_secret,
               host_identity(),
               fn _, _ -> flunk("recovery must not rematerialize") end
             )

    assert second.material == first.material

    assert {:error, :host_identity_mismatch} =
             exchange(
               descriptor.operation.id,
               descriptor.one_time_secret,
               %{host_identity() | device_id: "other-host"}
             )
  end

  test "durable acknowledgement is capability-bound, idempotent, and clears ciphertext" do
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())

    assert {:ok, exchanged} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity())

    assert {:ok, handed_off} =
             AgentVMMInstallations.acknowledge(
               descriptor.operation.id,
               descriptor.one_time_secret,
               exchanged.host_identity_digest
             )

    assert handed_off.authorization_status == "handed_off"

    assert {:ok, repeated} =
             AgentVMMInstallations.acknowledge(
               descriptor.operation.id,
               descriptor.one_time_secret,
               exchanged.host_identity_digest
             )

    assert repeated.authorization_status == "handed_off"
    assert is_nil(Repo.get!(Operation, descriptor.operation.id).material_ciphertext)

    assert {:error, :handoff_complete} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity())
  end

  test "product readiness comes only from current registration admission observation" do
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())
    assert descriptor.operation.status == "processing"

    assert {:ok, exchanged} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity())

    assert {:ok, handed_off} =
             AgentVMMInstallations.acknowledge(
               descriptor.operation.id,
               descriptor.one_time_secret,
               exchanged.host_identity_digest
             )

    assert handed_off.status == "processing"

    {1, _} =
      Repo.update_all(AgentVMM.Registration,
        set: [status: "ready", desired_enabled: true]
      )

    {1, _} =
      Repo.update_all(Compute.ProviderBinding,
        set: [
          status: "available",
          observation: %{
            "gateway_instance_id" => "gateway-a",
            "connection_epoch" => "1",
            "inventory_watermark" => 1,
            "inventory_snapshot_bounded" => true,
            "admission" => "closed"
          }
        ]
      )

    assert {:ok, closed} = AgentVMMInstallations.get(descriptor.operation.id)
    assert closed.status == "processing"

    {1, _} =
      Repo.update_all(Compute.ProviderBinding,
        set: [
          observation: %{
            "gateway_instance_id" => "gateway-a",
            "connection_epoch" => "1",
            "inventory_watermark" => 1,
            "inventory_snapshot_bounded" => true,
            "admission" => "accepting"
          }
        ]
      )

    assert {:ok, ready} = AgentVMMInstallations.get(descriptor.operation.id)
    assert ready.status == "ready"

    assert {:ok, initialized} =
             AgentVMMInstallations.initialize_workload(ready.id,
               expected_authorization: ready
             )

    initial = initialized.initial_workload_id
    assert is_binary(initial)

    assert {:ok, repeated} =
             AgentVMMInstallations.initialize_workload(ready.id,
               expected_authorization: initialized
             )

    assert repeated.initial_workload_id == initial

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^initial),
      set: [observed_state: "failed"]
    )

    assert {:ok, retried} =
             AgentVMMInstallations.initialize_workload(ready.id,
               expected_authorization: repeated
             )

    assert retried.initial_workload_id == initial
    assert Repo.get!(Compute.Workload, initial).observed_state == "pending"
    now = SystemsClock.utc_now()

    claim =
      Repo.insert!(%Compute.ReconcilerClaim{
        id: "initial-shell-claim",
        provider: "agent_vmm",
        workload_id: initial,
        generation: 1,
        claim_token: "action-required",
        attempt_count: 1,
        last_error: %{"kind" => "action_required", "code" => "resource_capacity_exhausted"},
        created_at: now,
        updated_at: now
      })

    assert {:ok, claim_retried} =
             AgentVMMInstallations.initialize_workload(ready.id,
               expected_authorization: retried
             )

    assert claim_retried.initial_workload_id == initial
    assert Repo.get!(Compute.ReconcilerClaim, claim.id).last_error == %{}
    workload = Repo.get!(Compute.Workload, initial)

    assert {:ok, _} =
             SalixStore.ComputeWorkloadDeletion.start(
               ready.tenant_id,
               ready.scope_key,
               initial,
               workload.revision,
               workload.generation,
               "delete-initial",
               fn -> :ok end
             )

    assert {:ok, after_deletion} =
             AgentVMMInstallations.initialize_workload(ready.id,
               expected_authorization: claim_retried
             )

    assert after_deletion.initial_workload_id == initial
    assert Repo.aggregate(Compute.Workload, :count) == 1

    {1, _} =
      Repo.update_all(Compute.ProviderBinding,
        set: [
          observation: %{
            "gateway_instance_id" => "gateway-a",
            "connection_epoch" => "epoch-a",
            "admission" => "accepting"
          }
        ]
      )

    assert {:ok, invalid} = AgentVMMInstallations.get(descriptor.operation.id)
    assert invalid.status == "action_required"

    {1, _} =
      Repo.update_all(Compute.ProviderBinding,
        set: [
          observation: %{
            "gateway_instance_id" => "gateway-a",
            "connection_epoch" => "1",
            "admission" => "accepting"
          }
        ]
      )

    binding =
      Repo.get_by!(Compute.ProviderBinding, provider_ref: descriptor.operation.registration_id)

    assert {:ok, _allocation} =
             Compute.allocate(%{
               id: "new-allocation",
               environment_id: "environment",
               provider_binding_id: binding.id,
               generation: 1
             })

    {1, _} =
      Repo.update_all(
        from(a in Compute.Allocation, where: a.id == "new-allocation"),
        set: [status: "ready"]
      )

    assert {:ok, still_ready} = AgentVMMInstallations.get(descriptor.operation.id)
    assert still_ready.status == "ready"

    {1, _} = Repo.update_all(AgentVMM.Registration, set: [desired_enabled: false])
    assert {:ok, stopped} = AgentVMMInstallations.get(descriptor.operation.id)
    assert stopped.status == "stopped"
  end

  test "expired unconsumed ticket remains expired and creates no registration" do
    now = SystemsClock.utc_now()
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs(), now: now)

    assert {:error, :ticket_expired} =
             exchange(
               descriptor.operation.id,
               descriptor.one_time_secret,
               host_identity(),
               now: DateTime.add(now, 16 * 60, :second)
             )

    stored = Repo.get!(Operation, descriptor.operation.id)
    assert stored.ticket_status == "expired"
    assert stored.authorization_status == "requested"
    assert Repo.get(AgentVMM.Registration, descriptor.operation.registration_id) == nil

    assert Repo.get_by(Compute.ProviderBinding,
             provider_ref: descriptor.operation.registration_id
           ) ==
             nil
  end

  test "an expired handoff whose Host never enrolled frees the scope for a new install" do
    now = SystemsClock.utc_now()

    assert {:ok, descriptor} =
             AgentVMMInstallations.request(request_attrs(), now: now, one_per_scope: true)

    assert {:ok, _} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity(),
               now: now
             )

    assert {:ok, %{settled: 0}} =
             AgentVMMInstallations.expire_handoffs(now: DateTime.add(now, 14 * 60, :second))

    assert Repo.get!(Operation, descriptor.operation.id).authorization_status ==
             "exchange_committed"

    assert {:error, :scope_host_bound} =
             AgentVMMInstallations.request(%{request_attrs() | client_request_id: "second"},
               one_per_scope: true
             )

    assert {:ok, %{settled: 1}} =
             AgentVMMInstallations.expire_handoffs(now: DateTime.add(now, 16 * 60, :second))

    stored = Repo.get!(Operation, descriptor.operation.id)
    assert stored.authorization_status == "action_required"
    assert stored.error_code == "material_handoff_expired"
    assert is_nil(stored.material_ciphertext)

    assert Repo.get!(AgentVMM.Registration, descriptor.operation.registration_id).status ==
             "revoked"

    assert {:ok, second} =
             AgentVMMInstallations.request(%{request_attrs() | client_request_id: "second"},
               one_per_scope: true
             )

    assert second.operation.id != descriptor.operation.id
  end

  test "an expired handoff whose Host already enrolled settles as handed off" do
    now = SystemsClock.utc_now()
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs(), now: now)

    assert {:ok, exchanged} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity(),
               now: now
             )

    token = Base.decode64!(exchanged.material["remote_enrollment"]["enrollment_token"])

    assert {:ok, enrolled} =
             AgentVMM.enroll(
               descriptor.operation.registration_id,
               token,
               String.duplicate("c", 32)
             )

    assert {:ok, %{settled: 1}} =
             AgentVMMInstallations.expire_handoffs(now: DateTime.add(now, 16 * 60, :second))

    stored = Repo.get!(Operation, descriptor.operation.id)
    assert stored.authorization_status == "handed_off"
    assert is_nil(stored.material_ciphertext)
    assert stored.material_handed_off_at
    assert Repo.get!(AgentVMM.Registration, enrolled.id) == enrolled
  end

  test "the settlement sweeper pass expires due material handoffs" do
    past = DateTime.add(SystemsClock.utc_now(), -20 * 60, :second)
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs(), now: past)

    assert {:ok, _} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity(),
               now: past
             )

    assert {:noreply, _} =
             SalixStore.AgentVMMSettlementSweeper.handle_info(:sweep, {3_600_000, ""})

    assert Repo.get!(Operation, descriptor.operation.id).error_code ==
             "material_handoff_expired"
  end

  test "revocation after exchange closes its exact registration and material" do
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())

    assert {:ok, _} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity())

    assert {:ok, revoked} = AgentVMMInstallations.revoke(descriptor.operation.id)
    assert revoked.authorization_status == "revoked"

    registration = Repo.get!(AgentVMM.Registration, descriptor.operation.registration_id)
    assert registration.status == "revoked"
    assert is_nil(registration.enrollment_token_hash)
    assert is_nil(Repo.get!(Operation, descriptor.operation.id).material_ciphertext)
  end

  test "handed-off registration can stop, resume, and be removed without rewriting authorization" do
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())

    assert {:ok, exchanged} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity())

    assert {:ok, handed_off} =
             AgentVMMInstallations.acknowledge(
               descriptor.operation.id,
               descriptor.one_time_secret,
               exchanged.host_identity_digest
             )

    assert handed_off.authorization_status == "handed_off"

    assert {:ok, stopped} =
             AgentVMMInstallations.configure_registration(descriptor.operation.id, false)

    assert stopped.authorization_status == "handed_off"
    assert stopped.status == "stopped"

    assert {:ok, resumed} =
             AgentVMMInstallations.configure_registration(descriptor.operation.id, true)

    assert resumed.authorization_status == "handed_off"
    assert resumed.status == "processing"

    assert Repo.get_by!(Compute.ProviderBinding,
             provider_ref: descriptor.operation.registration_id
           ).status == "disabled"

    assert {:ok, removed} = AgentVMMInstallations.revoke(descriptor.operation.id)
    assert removed.authorization_status == "handed_off"
    assert removed.status == "removed"

    assert Repo.get!(AgentVMM.Registration, descriptor.operation.registration_id).status ==
             "revoked"

    assert {:ok, repeated} = AgentVMMInstallations.revoke(descriptor.operation.id)
    assert repeated.status == "removed"

    assert {:error, :terminal_registration} =
             AgentVMMInstallations.configure_registration(descriptor.operation.id, true)
  end

  defp exchange(operation_id, secret, identity, opts \\ []) do
    AgentVMMInstallations.exchange(
      operation_id,
      secret,
      identity,
      &issue_material/2,
      opts
    )
  end

  defp request_attrs do
    %{
      tenant_id: "tenant",
      group_id: "group",
      surface: "bft",
      scope_key: "project",
      client_request_id: "request",
      provider: "agent-vmm",
      environment_id: "environment",
      delivery_target_type: "bft_runner",
      delivery_target_id: "runner-a"
    }
  end

  defp host_identity do
    %{
      device_id: "host-device",
      root_public_key: String.duplicate("k", 33),
      root_key_revision: 1
    }
  end

  test "the fixed purpose proof uses the native canonical wire including UTF-8 bindings" do
    vector =
      __DIR__ |> Path.join("testdata/comma_recovery_wire.json") |> File.read!() |> Jason.decode!()

    assert {:ok, wire} = SalixStore.AgentVMMRecovery.wire(vector["challenge"])
    assert wire == vector["wire"]
  end

  defp recovery_authority do
    %{
      tenant_id: "tenant",
      group_id: "group",
      scope_key: "project",
      subject: "original-subject",
      audience: "https://api.example.test",
      session_id: "new-session"
    }
  end

  defp recovery_identity do
    {<<4, x::binary-size(32), y::binary-size(32)>>, private_key} =
      SystemsRuntime.Proc.generate_key(:ecdh, :secp256r1)

    key = <<2 + Bitwise.band(:binary.last(y), 1), x::binary>>
    {%{device_id: "host-device", root_public_key: key, root_key_revision: 1}, private_key}
  end

  defp recovery_proof(identity, private_key, nonce, wire) do
    der = SystemsRuntime.Proc.sign(:ecdsa, :sha256, wire, [private_key, :secp256r1])
    <<0x30, _size, 0x02, r_size, rest::binary>> = der
    <<r::binary-size(^r_size), 0x02, s_size, s::binary-size(s_size)>> = rest
    r = :binary.decode_unsigned(r)
    s = :binary.decode_unsigned(s)
    order = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

    signature =
      <<r::unsigned-big-integer-size(256), min(s, order - s)::unsigned-big-integer-size(256)>>

    %{
      "nonce" => nonce,
      "signature" => Base.encode64(signature),
      "device_id" => identity.device_id,
      "root_public_key" => Base.encode64(identity.root_public_key),
      "root_key_revision" => identity.root_key_revision
    }
  end

  defp host_identity_digest do
    identity = host_identity()

    Jason.encode!([
      identity.device_id,
      Base.encode64(identity.root_public_key),
      identity.root_key_revision
    ])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp issue_material(operation, enrollment) do
    {:ok,
     %{
       "version" => 1,
       "operation_id" => operation.id,
       "remote_enrollment" => %{
         "registration_id" => enrollment.registration_id,
         "enrollment_token" => enrollment.enrollment_token
       }
     }}
  end
end
