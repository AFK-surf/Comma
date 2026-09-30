defmodule SalixStore.Repo.Migrations.AddPersonalMeshRegistryGuards do
  use Ecto.Migration

  def change do
    create table(:personal_mesh_rate_buckets, primary_key: false) do
      add(:scope, :text, primary_key: true)
      add(:subject_id, :text, primary_key: true)
      add(:window_start, :bigint, primary_key: true)
      add(:count, :integer, null: false)
    end

    create table(:personal_mesh_registry_audit, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:mesh_id, :text, null: false)
      add(:actor_device_id, :text)
      add(:action, :text, null: false)
      add(:outcome, :text, null: false)
      add(:operation_digest, :binary)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(index(:personal_mesh_registry_audit, [:mesh_id, :created_at]))
  end
end
