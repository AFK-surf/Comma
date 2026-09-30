defmodule SalixStore.Repo.Migrations.CreateComputeCapacityQueue do
  use Ecto.Migration

  def change do
    alter table(:compute_provider_bindings) do
      add(:capacity_event_epoch, :bigint, null: false, default: 0)
    end

    create table(:compute_capacity_queue, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:provider, :text, null: false)

      add(:workload_id, references(:compute_workloads, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:command_id, references(:compute_commands, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:generation, :bigint, null: false)
      add(:event_epoch, :bigint, null: false)
      add(:reason, :text, null: false)
      add(:status, :text, null: false, default: "queued")
      add(:deadline_at, :utc_datetime_usec, null: false)
      add(:enqueued_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:compute_capacity_queue, [:provider, :workload_id, :generation],
        name: :compute_capacity_queue_current_idx
      )
    )

    create(
      index(:compute_capacity_queue, [:provider, :status, :enqueued_at, :id],
        name: :compute_capacity_queue_fifo_idx
      )
    )

    create(
      index(:compute_capacity_queue, [:deadline_at, :id],
        where: "provider = 'agent_vmm' AND status = 'queued'",
        name: :compute_capacity_queue_due_idx
      )
    )

    create(
      constraint(:compute_capacity_queue, :compute_capacity_queue_status_check,
        check: "status IN ('queued', 'expired')"
      )
    )

    create(
      constraint(:compute_capacity_queue, :compute_capacity_queue_reason_check,
        check:
          "reason IN ('queued_cpu_guarantee', 'queued_cpu_max', 'queued_memory', 'queued_pids', 'queued_writable_storage', 'queued_storage_headroom', 'queued_import_slot')"
      )
    )
  end
end
