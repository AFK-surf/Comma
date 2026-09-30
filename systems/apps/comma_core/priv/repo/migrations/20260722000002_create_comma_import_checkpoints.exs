defmodule Comma.Repo.Migrations.CreateCommaImportCheckpoints do
  use Ecto.Migration

  def change do
    create table(:comma_import_checkpoints, primary_key: false) do
      add(:source_key, :string, primary_key: true)
      add(:source_digest, :string, null: false)
      add(:target_relation, :string, null: false)
      add(:target_identity, :string, null: false)
      add(:target_digest, :string, null: false)
      add(:status, :string, null: false)
      add(:imported_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:comma_import_checkpoints, :comma_import_checkpoints_status_check,
        check: "status IN ('imported', 'validated')"
      )
    )

    create(
      unique_index(:comma_import_checkpoints, [:target_relation, :target_identity],
        name: :comma_import_checkpoint_target_idx
      )
    )

    create table(:comma_import_runs, primary_key: false) do
      add(:release_identity, :string, primary_key: true)
      add(:status, :string, null: false)
      add(:evidence, :map, null: false)
      add(:evidence_digest, :string, null: false)
      add(:completed_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:comma_import_runs, :comma_import_runs_status_check, check: "status = 'complete'")
    )

    execute("""
    CREATE FUNCTION comma_reject_import_run_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      RAISE EXCEPTION 'comma_import_runs is append-only';
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER comma_import_runs_append_only
    BEFORE UPDATE OR DELETE ON comma_import_runs
    FOR EACH ROW
    EXECUTE FUNCTION comma_reject_import_run_mutation()
    """)
  end
end
