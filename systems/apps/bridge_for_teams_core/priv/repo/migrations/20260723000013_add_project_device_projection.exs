defmodule BridgeForTeams.Repo.Migrations.AddProjectDeviceProjection do
  use Ecto.Migration

  def up do
    case schema_state() do
      :complete -> :ok
      :absent -> create_schema()
      :partial -> raise "device projection schema is partially present"
    end
  end

  def down do
    drop_if_exists index(:project_device_projection_scans, [:lease_expires_at])
    drop_if_exists table(:project_device_projection_scans)

    drop_if_exists(index(:project_device_projections, [:project_id, :updated_at, :device_id]))

    drop_if_exists table(:project_device_projections)
  end

  defp create_schema do
    create table(:project_device_projections, primary_key: false) do
      add :project_id,
          references(:projects, type: :uuid, on_delete: :delete_all),
          primary_key: true

      add :device_id, :text, primary_key: true
      add :connector_run_id, :text
      add :connector_id, :text
      add :name, :text
      add :status, :text, null: false
      add :source_updated_at, :bigint
      add :runtime_inventory, :map, null: false, default: %{"items" => []}
      add :observed_generation, :bigint, null: false

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create index(:project_device_projections, [:project_id, :updated_at, :device_id])

    create table(:project_device_projection_scans, primary_key: false) do
      add :id, :text, primary_key: true
      add :cursor_project_id, :uuid
      add :active_project_id, :uuid
      add :device_cursor, :text
      add :project_generation, :bigint, null: false, default: 0
      add :generation, :bigint, null: false, default: 0
      add :lease_token, :uuid
      add :lease_expires_at, :utc_datetime_usec
      add :last_error, :text

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create index(:project_device_projection_scans, [:lease_expires_at])
  end

  defp schema_state do
    %{rows: [[present, valid]]} =
      repo().query!(
        """
        SELECT
          (
            (to_regclass(current_schema() || '.project_device_projections') IS NOT NULL)::int
            + (to_regclass(current_schema() || '.project_device_projection_scans') IS NOT NULL)::int
          ),
          to_regclass(current_schema() || '.project_device_projections') IS NOT NULL
          AND to_regclass(current_schema() || '.project_device_projection_scans') IS NOT NULL
          AND EXISTS (
            SELECT 1
            FROM pg_constraint
            WHERE conrelid = to_regclass(current_schema() || '.project_device_projections')
              AND contype = 'p'
          )
          AND EXISTS (
            SELECT 1
            FROM pg_constraint
            WHERE conrelid = to_regclass(current_schema() || '.project_device_projections')
              AND contype = 'f'
          )
          AND EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND table_name = 'project_device_projections'
              AND column_name = 'observed_generation'
              AND data_type = 'bigint'
              AND is_nullable = 'NO'
          )
        """,
        [],
        log: false
      )

    case {present, valid} do
      {0, false} -> :absent
      {2, true} -> :complete
      _ -> :partial
    end
  end
end
