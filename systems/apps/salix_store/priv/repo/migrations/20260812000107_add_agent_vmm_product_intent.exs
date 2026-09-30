defmodule SalixStore.Repo.Migrations.CreateExternalWorkerBindings do
  use Ecto.Migration

  def change do
    create table(:external_worker_bindings, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:agent_id, :text, null: false)
      add(:source_kind, :text, null: false)
      add(:device_runtime_id, :text)
      add(:workload_id, references(:compute_workloads, type: :text))
      add(:runtime_spec, :map, null: false, default: %{})
      add(:status, :text, null: false)
      add(:binding_revision, :bigint, null: false, default: 1)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:external_worker_bindings, [:tenant_id, :agent_id]))

    create(
      constraint(:external_worker_bindings, :external_worker_binding_exact_source,
        check:
          "(source_kind = 'connected_runtime' AND device_runtime_id IS NOT NULL AND workload_id IS NULL) OR (source_kind = 'compute_workload' AND device_runtime_id IS NULL AND workload_id IS NOT NULL)"
      )
    )
  end
end
