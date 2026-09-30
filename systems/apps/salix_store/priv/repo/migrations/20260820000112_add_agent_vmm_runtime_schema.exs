defmodule SalixStore.Repo.Migrations.AddAgentVMMRuntimeSchema do
  use Ecto.Migration

  @lock_timeout "5s"

  def up do
    execute("SET LOCAL lock_timeout TO '#{@lock_timeout}'")

    alter table(:compute_workloads) do
      add(:template_key, :text)
      add(:runtime_revision, :text)
    end

    alter table(:compute_runtime_instances) do
      add(:bootstrap_consumed_epoch, :text)
      add(:input_cursor, :text)
      add(:event_cursor, :text)
    end

    create table(:compute_runtime_inputs, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:source_dispatch_id, :text, null: false)
      add(:workload_id, references(:compute_workloads, type: :text), null: false)
      add(:runtime_instance_id, references(:compute_runtime_instances, type: :text), null: false)
      add(:generation, :bigint, null: false)
      add(:connection_epoch, :text, null: false)
      add(:payload, :map, null: false)
      add(:runtime_capability_ciphertext, :text)
      add(:status, :text, null: false, default: "pending")
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:compute_runtime_inputs, [:workload_id, :generation, :source_dispatch_id],
        name: :compute_runtime_inputs_workload_generation_dispatch_idx
      )
    )

    create(index(:compute_runtime_inputs, [:runtime_instance_id, :connection_epoch, :status]))

    create table(:runtime_bundle_release_state, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:active_revision, :text, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:runtime_bundle_release_state, :runtime_bundle_release_state_singleton,
        check: "id = 'active'"
      )
    )
  end

  def down do
    execute("SET LOCAL lock_timeout TO '#{@lock_timeout}'")

    drop(table(:runtime_bundle_release_state))
    drop(table(:compute_runtime_inputs))

    alter table(:compute_runtime_instances) do
      remove(:event_cursor)
      remove(:input_cursor)
      remove(:bootstrap_consumed_epoch)
    end

    alter table(:compute_workloads) do
      remove(:runtime_revision)
      remove(:template_key)
    end
  end
end
