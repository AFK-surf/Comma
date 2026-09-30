defmodule BridgeForTeamsCore.Repo.Migrations.DropRunnerInstallCodeAction do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = current_schema()
          AND tablename = 'mac_mini_install_codes'
          AND indexname = 'mac_mini_install_codes_org_id_action_index'
      ) THEN
        DROP INDEX mac_mini_install_codes_org_id_action_index;
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'mac_mini_install_codes'
          AND column_name = 'action'
      ) THEN
        ALTER TABLE mac_mini_install_codes
        DROP COLUMN action;
      END IF;
    END $$;
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'mac_mini_install_codes'
          AND column_name = 'action'
      ) THEN
        ALTER TABLE mac_mini_install_codes
        ADD COLUMN action text NOT NULL DEFAULT 'install';
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = current_schema()
          AND tablename = 'mac_mini_install_codes'
          AND indexname = 'mac_mini_install_codes_org_id_action_index'
      ) THEN
        CREATE INDEX mac_mini_install_codes_org_id_action_index
          ON mac_mini_install_codes (org_id, action);
      END IF;
    END $$;
    """)
  end
end
