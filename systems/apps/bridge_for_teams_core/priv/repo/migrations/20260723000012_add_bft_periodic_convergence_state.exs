defmodule BridgeForTeams.Repo.Migrations.AddBftPeriodicConvergenceState do
  use Ecto.Migration

  def up do
    case schema_state() do
      :complete -> :ok
      :absent -> create_schema()
      :partial -> raise "periodic convergence schema is partially present"
    end
  end

  def down do
    drop_if_exists index(:observability_prune_scans, [:lease_expires_at])
    drop_if_exists constraint(:observability_prune_scans, :observability_prune_phase_range)
    drop_if_exists table(:observability_prune_scans)
    drop_if_exists index(:tenant_config_scans, [:lease_expires_at])
    drop_if_exists table(:tenant_config_scans)

    drop_if_exists(
      index(
        :dashboard_projection_refreshes,
        [:completed_generation, :desired_generation, :next_retry_at, :lease_expires_at]
      )
    )

    drop_if_exists(
      constraint(:dashboard_projection_refreshes, :dashboard_projection_generation_order)
    )

    drop_if_exists table(:dashboard_projection_refreshes)

    alter table(:project_dashboard_snapshots) do
      remove_if_exists :refresh_generation, :bigint
    end
  end

  defp create_schema do
    alter table(:project_dashboard_snapshots) do
      add :refresh_generation, :bigint, null: false, default: 0
    end

    create table(:dashboard_projection_refreshes, primary_key: false) do
      add :project_id,
          references(:projects, type: :uuid, on_delete: :delete_all),
          primary_key: true

      add :desired_generation, :bigint, null: false, default: 1
      add :completed_generation, :bigint, null: false, default: 0
      add :lease_generation, :bigint
      add :lease_token, :uuid
      add :lease_expires_at, :utc_datetime_usec
      add :next_retry_at, :utc_datetime_usec
      add :last_error, :text

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create constraint(:dashboard_projection_refreshes, :dashboard_projection_generation_order,
             check: "desired_generation >= completed_generation"
           )

    create index(:dashboard_projection_refreshes, [
             :completed_generation,
             :desired_generation,
             :next_retry_at,
             :lease_expires_at
           ])

    create table(:tenant_config_scans, primary_key: false) do
      add :id, :text, primary_key: true
      add :cursor_org_id, :uuid
      add :generation, :bigint, null: false, default: 1
      add :lease_token, :uuid
      add :lease_expires_at, :utc_datetime_usec
      add :last_error, :text

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create index(:tenant_config_scans, [:lease_expires_at])

    create table(:observability_prune_scans, primary_key: false) do
      add :id, :text, primary_key: true
      add :phase, :integer, null: false, default: 0
      add :generation, :bigint, null: false, default: 1
      add :lease_token, :uuid
      add :lease_expires_at, :utc_datetime_usec
      add :last_error, :text

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create constraint(:observability_prune_scans, :observability_prune_phase_range,
             check: "phase >= 0 AND phase < 5"
           )

    create index(:observability_prune_scans, [:lease_expires_at])
  end

  defp schema_state do
    %{rows: [[present, valid]]} =
      repo().query!(
        """
        SELECT
          (
            EXISTS (
              SELECT 1
              FROM information_schema.columns
              WHERE table_schema = current_schema()
                AND table_name = 'project_dashboard_snapshots'
                AND column_name = 'refresh_generation'
            )::int
            + (to_regclass(current_schema() || '.dashboard_projection_refreshes') IS NOT NULL)::int
            + (to_regclass(current_schema() || '.tenant_config_scans') IS NOT NULL)::int
            + (to_regclass(current_schema() || '.observability_prune_scans') IS NOT NULL)::int
          ),
          EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND table_name = 'project_dashboard_snapshots'
              AND column_name = 'refresh_generation'
              AND data_type = 'bigint'
              AND is_nullable = 'NO'
          )
          AND to_regclass(current_schema() || '.dashboard_projection_refreshes') IS NOT NULL
          AND to_regclass(current_schema() || '.tenant_config_scans') IS NOT NULL
          AND to_regclass(current_schema() || '.observability_prune_scans') IS NOT NULL
          AND EXISTS (
            SELECT 1
            FROM pg_constraint
            WHERE conrelid = to_regclass(current_schema() || '.dashboard_projection_refreshes')
              AND conname = 'dashboard_projection_generation_order'
          )
          AND EXISTS (
            SELECT 1
            FROM pg_constraint
            WHERE conrelid = to_regclass(current_schema() || '.observability_prune_scans')
              AND conname = 'observability_prune_phase_range'
          )
        """,
        [],
        log: false
      )

    case {present, valid} do
      {0, false} -> :absent
      {4, true} -> :complete
      _ -> :partial
    end
  end
end
