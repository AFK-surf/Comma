defmodule SalixStore.Repo.Migrations.CreateComputeMigrationControl do
  use Ecto.Migration

  def change do
    create table(:compute_migration_runs, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:phase, :text, null: false)
      add(:authority, :text, null: false)
      add(:revision, :bigint, null: false)
      add(:snapshot_generation, :bigint)
      add(:high_watermark, :text, null: false)
      add(:cursor, :text)
      add(:copied_components, {:array, :text}, null: false, default: [])
      add(:legacy_writer_quiesced, :boolean, null: false, default: false)
      add(:pending_legacy_writes, :bigint, null: false, default: 0)
      add(:reader_inventory, :map, null: false, default: %{})
      add(:postconditions, :map, null: false, default: %{})
      add(:last_error, :text)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:compute_migration_runs, :compute_migration_phase,
        check:
          "phase IN ('legacy_only','shadow','new_authoritative','legacy_read_disabled','legacy_deleted')"
      )
    )

    create table(:compute_migration_items, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:run_id, references(:compute_migration_runs, type: :text), null: false)
      add(:legacy_id, :text, null: false)
      add(:legacy_state, :text, null: false)
      add(:generation, :bigint, null: false)
      add(:component, :text, null: false)
      add(:snapshot, :map, null: false)
      add(:checksum, :text, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:compute_migration_items, [:run_id, :legacy_id, :generation, :component]))
    create(index(:compute_migration_items, [:run_id, :legacy_id]))
  end
end
