defmodule SalixStore.Repo.Migrations.CreateExternalWorkerOperations do
  use Ecto.Migration

  # The durable operation is created in its final additive shape. In
  # particular, environment_id is intentionally a plain identity: a pending
  # operation may outlive an environment restore and must be repairable before
  # the target row exists.
  def change do
    create table(:external_worker_operations, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:operation_hash, :text, null: false)
      add(:tool_call_id, :text, null: false)
      # This is the requested placement target. It may be temporarily absent
      # while the operation waits for the environment to be created or
      # restored, so the durable operation must not depend on an FK here.
      add(:environment_id, :text, null: false)
      add(:provider, :text, null: false)
      add(:template_key, :text, null: false)
      add(:allocation_id, references(:compute_allocations, type: :text))
      add(:workload_id, references(:compute_workloads, type: :text))
      add(:worker_id, :text)
      add(:state, :text, null: false, default: "placement_pending")
      add(:attempt_count, :bigint, null: false, default: 0)
      add(:next_retry_at, :utc_datetime_usec)
      add(:claim_token, :text)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:last_error, :map, null: false, default: %{})
      add(:revision, :bigint, null: false, default: 1)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:external_worker_operations, [:tenant_id, :group_id, :operation_hash],
        name: :external_worker_operations_idempotency_idx
      )
    )

    create(
      unique_index(:external_worker_operations, [:tenant_id, :group_id, :tool_call_id],
        name: :external_worker_operations_tool_call_idx
      )
    )

    create(
      index(:external_worker_operations, [:state, :next_retry_at, :lease_expires_at, :updated_at])
    )

    create(
      constraint(:external_worker_operations, :external_worker_operation_state,
        check:
          "state IN ('placement_pending', 'placement_ready', 'worker_ready') AND ((state = 'placement_pending') OR (state = 'placement_ready' AND allocation_id IS NOT NULL AND workload_id IS NOT NULL) OR (state = 'worker_ready' AND allocation_id IS NOT NULL AND workload_id IS NOT NULL AND worker_id IS NOT NULL))"
      )
    )
  end
end
