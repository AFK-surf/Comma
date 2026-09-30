defmodule SalixStore.AgentVMMInstallationsTest do
  use ExUnit.Case, async: false

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

  test "ticket response-loss budget can explicitly reopen only the same pre-handoff operation" do
    assert {:ok, initial} = AgentVMMInstallations.request(request_attrs())

    assert {:ok, second} = AgentVMMInstallations.retry(initial.operation.id)
    assert {:ok, third} = AgentVMMInstallations.retry(initial.operation.id)
    assert {:ok, fourth} = AgentVMMInstallations.retry(initial.operation.id)

    assert [
             second.operation.ticket_generation,
             third.operation.ticket_generation,
             fourth.operation.ticket_generation
           ] == [2, 3, 4]

    assert {:error, :ticket_retry_exhausted} =
             AgentVMMInstallations.retry(initial.operation.id)

    closed = Repo.get!(Operation, initial.operation.id)
    assert closed.authorization_status == "action_required"
    assert closed.ticket_status == "revoked"
    assert closed.error_code == "ticket_retry_exhausted"

    assert {:ok, reopened} = AgentVMMInstallations.retry(initial.operation.id)
    assert reopened.operation.id == initial.operation.id
    assert reopened.operation.registration_id == initial.operation.registration_id
    assert reopened.operation.authorization_status == "requested"
    assert reopened.operation.ticket_status == "active"
    assert reopened.operation.ticket_generation == 1
    assert is_nil(reopened.operation.error_code)

    assert {:error, :invalid_ticket} =
             exchange(initial.operation.id, fourth.one_time_secret, host_identity())

    assert {:ok, exchanged} =
             exchange(initial.operation.id, reopened.one_time_secret, host_identity())

    assert exchanged.operation.authorization_status == "exchange_committed"
  end

  test "runner descriptor delivery is bounded after three lost responses" do
    assert {:ok, initial} = AgentVMMInstallations.request(request_attrs())

    for expected_generation <- 2..4 do
      assert {:ok, delivered} =
               AgentVMMInstallations.deliver_next("bft_runner", "runner-a")

      assert delivered.operation.id == initial.operation.id
      assert delivered.operation.ticket_generation == expected_generation
    end

    assert {:error, :ticket_retry_exhausted} =
             AgentVMMInstallations.deliver_next("bft_runner", "runner-a")

    assert Repo.get!(Operation, initial.operation.id).authorization_status == "action_required"

    assert {:error, :no_pending_operation} =
             AgentVMMInstallations.deliver_next("bft_runner", "runner-a")
  end

  test "reused idempotency key cannot change its authorization binding" do
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())

    changed = %{request_attrs() | delivery_target_id: "runner-b"}
    assert {:error, :idempotency_conflict} = AgentVMMInstallations.request(changed)

    assert {:ok, operation} = AgentVMMInstallations.get(descriptor.operation.id)
    assert operation.delivery_target_id == "runner-a"
    assert operation.ticket_generation == 1
  end

  test "request rejects unbounded product surfaces" do
    assert {:error, :invalid_install_request} =
             AgentVMMInstallations.request(%{request_attrs() | surface: "caller-controlled"})

    assert Repo.aggregate(Operation, :count) == 0
  end

  test "exact delivery target rotates one pending descriptor without a claim lease" do
    assert {:ok, initial} = AgentVMMInstallations.request(request_attrs())

    assert {:error, :no_pending_operation} =
             AgentVMMInstallations.deliver_next("bft_runner", "runner-b")

    assert {:ok, delivered} = AgentVMMInstallations.deliver_next("bft_runner", "runner-a")
    assert delivered.operation.id == initial.operation.id
    assert delivered.operation.ticket_generation == 2
    refute delivered.one_time_secret == initial.one_time_secret

    assert {:error, :invalid_ticket} =
             exchange(initial.operation.id, initial.one_time_secret, host_identity())

    assert {:ok, _result} =
             exchange(delivered.operation.id, delivered.one_time_secret, host_identity())

    assert {:error, :no_pending_operation} =
             AgentVMMInstallations.deliver_next("bft_runner", "runner-a")
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

  test "terminal report after handoff ACK revokes registration and requires action" do
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())

    assert {:ok, _} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity())

    assert {:ok, handed_off} =
             AgentVMMInstallations.acknowledge(
               descriptor.operation.id,
               descriptor.one_time_secret,
               host_identity_digest()
             )

    assert handed_off.authorization_status == "handed_off"

    assert {:ok, apply_failed} =
             AgentVMMInstallations.report_delivery_failure(
               "bft_runner",
               "runner-a",
               descriptor.operation.id,
               "agent_vmm.apply_failed"
             )

    assert apply_failed.authorization_status == "handed_off"
    assert apply_failed.status == "action_required"
    assert apply_failed.error_code == "agent_vmm.apply_failed"
    assert is_nil(Repo.get!(Operation, descriptor.operation.id).material_ciphertext)

    assert {:error, :operation_not_retryable} =
             AgentVMMInstallations.retry(descriptor.operation.id)

    assert Repo.get!(AgentVMM.Registration, descriptor.operation.registration_id).status ==
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

  test "exchange rechecks the exact Environment after authorization and rolls back effects" do
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())

    assert {:ok, environment} =
             Compute.update_environment_intent("environment", 1, %{desired_state: "revoked"})

    assert environment.desired_state == "revoked"

    assert {:error, :invalid_install_environment} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity())

    assert Repo.get(AgentVMM.Registration, descriptor.operation.registration_id) == nil

    assert Repo.get_by(Compute.ProviderBinding,
             provider_ref: descriptor.operation.registration_id
           ) == nil

    stored = Repo.get!(Operation, descriptor.operation.id)
    assert stored.authorization_status == "requested"
    assert stored.ticket_status == "active"
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
            "connection_epoch" => "epoch-a",
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
            "connection_epoch" => "epoch-a",
            "inventory_watermark" => 1,
            "inventory_snapshot_bounded" => true,
            "admission" => "accepting"
          }
        ]
      )

    assert {:ok, ready} = AgentVMMInstallations.get(descriptor.operation.id)
    assert ready.status == "ready"

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
    now = DateTime.utc_now()
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

  test "expired material handoff closes recovery without rematerializing" do
    now = DateTime.utc_now()
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs(), now: now)

    assert {:ok, exchanged} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity(),
               now: now
             )

    expired_at = DateTime.add(now, 16 * 60, :second)

    assert {:error, :handoff_expired} =
             AgentVMMInstallations.acknowledge(
               descriptor.operation.id,
               descriptor.one_time_secret,
               exchanged.host_identity_digest,
               now: expired_at
             )

    stored = Repo.get!(Operation, descriptor.operation.id)
    assert stored.authorization_status == "action_required"
    assert stored.error_code == "material_handoff_expired"
    assert is_nil(stored.material_ciphertext)
    assert {:error, {:operation_exists, _}} = AgentVMMInstallations.request(request_attrs())
  end

  test "bounded expiry closes only committed handoffs" do
    now = DateTime.utc_now()
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs(), now: now)

    assert {:ok, _} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity(),
               now: now
             )

    assert {:ok, 1} =
             AgentVMMInstallations.expire_handoffs(now: DateTime.add(now, 16 * 60, :second))

    assert Repo.get!(Operation, descriptor.operation.id).authorization_status == "action_required"

    assert {:ok, 0} =
             AgentVMMInstallations.expire_handoffs(now: DateTime.add(now, 17 * 60, :second))
  end

  test "revocation closes a pre-handoff operation and old ticket" do
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())
    assert {:ok, revoked} = AgentVMMInstallations.revoke(descriptor.operation.id)
    assert revoked.authorization_status == "revoked"
    assert revoked.ticket_status == "revoked"

    assert {:error, :ticket_revoked} =
             exchange(descriptor.operation.id, descriptor.one_time_secret, host_identity())

    assert {:ok, repeated} = AgentVMMInstallations.revoke(descriptor.operation.id)
    assert repeated.authorization_status == "revoked"
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

  test "oversized material rolls back registration and ticket consumption" do
    assert {:ok, descriptor} = AgentVMMInstallations.request(request_attrs())

    assert {:error, :install_material_too_large} =
             AgentVMMInstallations.exchange(
               descriptor.operation.id,
               descriptor.one_time_secret,
               host_identity(),
               fn _, _ -> {:ok, %{"payload" => String.duplicate("x", 512_001)}} end
             )

    stored = Repo.get!(Operation, descriptor.operation.id)
    assert stored.authorization_status == "requested"
    assert stored.ticket_status == "active"
    assert Repo.get(AgentVMM.Registration, descriptor.operation.registration_id) == nil
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
