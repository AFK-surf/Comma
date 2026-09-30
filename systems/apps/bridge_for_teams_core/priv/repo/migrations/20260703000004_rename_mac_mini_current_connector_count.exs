defmodule BridgeForTeamsCore.Repo.Migrations.RenameMacMiniCurrentConnectorCount do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'mac_mini_provisioners'
          AND column_name = 'current_environment_count'
      ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'mac_mini_provisioners'
          AND column_name = 'current_connector_count'
      ) THEN
        ALTER TABLE mac_mini_provisioners
        RENAME COLUMN current_environment_count TO current_connector_count;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'mac_mini_provisioners'
          AND column_name = 'current_connector_count'
      ) THEN
        ALTER TABLE mac_mini_provisioners
        ADD COLUMN current_connector_count integer NOT NULL DEFAULT 0;
      END IF;
    END $$;
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'mac_mini_provisioners'
          AND column_name = 'current_connector_count'
      ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'mac_mini_provisioners'
          AND column_name = 'current_environment_count'
      ) THEN
        ALTER TABLE mac_mini_provisioners
        RENAME COLUMN current_connector_count TO current_environment_count;
      END IF;
    END $$;
    """)
  end
end
