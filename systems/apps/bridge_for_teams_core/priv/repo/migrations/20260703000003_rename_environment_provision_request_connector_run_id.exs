defmodule BridgeForTeamsCore.Repo.Migrations.RenameEnvironmentProvisionRequestConnectorRunId do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'environment_provision_requests'
          AND column_name = 'salix_env_id'
      ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'environment_provision_requests'
          AND column_name = 'connector_run_id'
      ) THEN
        ALTER TABLE environment_provision_requests
        RENAME COLUMN salix_env_id TO connector_run_id;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'environment_provision_requests'
          AND column_name = 'connector_run_id'
      ) THEN
        ALTER TABLE environment_provision_requests
        ADD COLUMN connector_run_id text;
      END IF;
    END $$;
    """)

    execute("DROP INDEX IF EXISTS environment_provision_requests_salix_env_id_index")

    create_if_not_exists index(:environment_provision_requests, [:connector_run_id])
  end

  def down do
    drop_if_exists index(:environment_provision_requests, [:connector_run_id])

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'environment_provision_requests'
          AND column_name = 'connector_run_id'
      ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'environment_provision_requests'
          AND column_name = 'salix_env_id'
      ) THEN
        ALTER TABLE environment_provision_requests
        RENAME COLUMN connector_run_id TO salix_env_id;
      END IF;
    END $$;
    """)

    create_if_not_exists index(:environment_provision_requests, [:salix_env_id])
  end
end
