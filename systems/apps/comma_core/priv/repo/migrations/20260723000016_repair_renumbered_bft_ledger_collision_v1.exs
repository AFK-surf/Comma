defmodule Comma.Repo.Migrations.RepairRenumberedBftLedgerCollisionV1 do
  use Ecto.Migration

  @disable_ddl_transaction true

  @colliding_version 20_260_723_000_001
  @renumbered_version 20_260_723_000_011

  def up do
    case comma_workspace_schema_state() do
      :ready ->
        :ok

      :absent ->
        verify_collision!()

        repo().query!(
          """
          DELETE FROM schema_migrations
          WHERE version = 20260723000001
          """,
          [],
          log: false
        )

        raise """
        cleared colliding BFT migration version 20260723000001 after verifying \
        its renumbered schema at version 20260723000011; rerun the release so \
        the Comma-owned workspace VM migration is planned and applied under the \
        original version
        """

      :partial ->
        raise """
        Comma migration 20260723000001 has partial schema without a trustworthy \
        ledger; stop and inspect the serving workspace VM postcondition
        """
    end
  end

  def down do
    raise "shared migration ledger collision repair is forward-only"
  end

  defp comma_workspace_schema_state do
    %{rows: [[vm_exists, vm_compatible]]} =
      repo().query!(
        """
        SELECT
          EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND table_name = 'comma_workspaces'
              AND column_name = 'vm'
          ),
          EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND table_name = 'comma_workspaces'
              AND column_name = 'vm'
              AND data_type = 'jsonb'
              AND is_nullable = 'YES'
              AND column_default IS NULL
          )
        """,
        [],
        log: false
      )

    case {vm_exists, vm_compatible} do
      {true, true} -> :ready
      {false, false} -> :absent
      _ -> :partial
    end
  end

  defp verify_collision! do
    %{rows: rows} =
      repo().query!(
        """
        SELECT version
        FROM schema_migrations
        WHERE version = ANY($1)
        ORDER BY version
        """,
        [[@colliding_version, @renumbered_version]],
        log: false
      )

    unless Enum.map(rows, &hd/1) == [@colliding_version, @renumbered_version] do
      raise "Comma workspace schema is incomplete without the exact colliding and renumbered BFT ledger versions"
    end

    %{rows: [[schema_ready]]} =
      repo().query!(
        """
        SELECT
          to_regclass(current_schema() || '.storage_metering_scans') IS NOT NULL
          AND to_regclass(current_schema() || '.artifact_sweep_scans') IS NOT NULL
          AND NOT EXISTS (
            SELECT 1
            FROM (
              VALUES
                ('storage_metering_scans', 'id', 'text', 'NO'),
                ('storage_metering_scans', 'cursor_project_id', 'uuid', 'YES'),
                ('storage_metering_scans', 'generation', 'bigint', 'NO'),
                ('storage_metering_scans', 'sampled_at', 'timestamp without time zone', 'YES'),
                ('storage_metering_scans', 'lease_token', 'uuid', 'YES'),
                ('storage_metering_scans', 'lease_expires_at', 'timestamp without time zone', 'YES'),
                ('storage_metering_scans', 'created_at', 'timestamp without time zone', 'NO'),
                ('storage_metering_scans', 'updated_at', 'timestamp without time zone', 'NO'),
                ('artifact_sweep_scans', 'id', 'text', 'NO'),
                ('artifact_sweep_scans', 'cursor_agent_id', 'uuid', 'YES'),
                ('artifact_sweep_scans', 'active_agent_id', 'uuid', 'YES'),
                ('artifact_sweep_scans', 'directory_cursor', 'text', 'YES'),
                ('artifact_sweep_scans', 'file_cursor', 'text', 'YES'),
                ('artifact_sweep_scans', 'active_document_path', 'text', 'YES'),
                ('artifact_sweep_scans', 'member_cursor_user_id', 'uuid', 'YES'),
                ('artifact_sweep_scans', 'generation', 'bigint', 'NO'),
                ('artifact_sweep_scans', 'lease_token', 'uuid', 'YES'),
                ('artifact_sweep_scans', 'lease_expires_at', 'timestamp without time zone', 'YES'),
                ('artifact_sweep_scans', 'created_at', 'timestamp without time zone', 'NO'),
                ('artifact_sweep_scans', 'updated_at', 'timestamp without time zone', 'NO')
            ) AS required(table_name, column_name, data_type, is_nullable)
            WHERE NOT EXISTS (
              SELECT 1
              FROM information_schema.columns AS actual
              WHERE actual.table_schema = current_schema()
                AND actual.table_name = required.table_name
                AND actual.column_name = required.column_name
                AND actual.data_type = required.data_type
                AND actual.is_nullable = required.is_nullable
            )
          )
          AND NOT EXISTS (
            SELECT 1
            FROM (
              VALUES
                ('storage_metering_scans'),
                ('artifact_sweep_scans')
            ) AS required(table_name)
            WHERE NOT EXISTS (
              SELECT 1
              FROM pg_constraint
              WHERE conrelid =
                to_regclass(current_schema() || '.' || required.table_name)
                AND contype = 'p'
                AND pg_get_constraintdef(oid) = 'PRIMARY KEY (id)'
            )
          )
          AND EXISTS (
            SELECT 1
            FROM pg_index
            WHERE indexrelid =
              to_regclass(current_schema() || '.storage_metering_scans_lease_expires_at_index')
              AND indrelid = to_regclass(current_schema() || '.storage_metering_scans')
              AND indisvalid
              AND NOT indisunique
              AND indnkeyatts = 1
              AND pg_get_indexdef(indexrelid, 1, true) = 'lease_expires_at'
              AND indpred IS NULL
          )
          AND EXISTS (
            SELECT 1
            FROM pg_index
            WHERE indexrelid =
              to_regclass(current_schema() || '.artifact_sweep_scans_lease_expires_at_index')
              AND indrelid = to_regclass(current_schema() || '.artifact_sweep_scans')
              AND indisvalid
              AND NOT indisunique
              AND indnkeyatts = 1
              AND pg_get_indexdef(indexrelid, 1, true) = 'lease_expires_at'
              AND indpred IS NULL
          )
          AND EXISTS (
            SELECT 1
            FROM pg_index
            WHERE indexrelid =
              to_regclass(current_schema() || '.workspace_items_project_user_vfs_path_uniq')
              AND indrelid = to_regclass(current_schema() || '.workspace_items')
              AND indisvalid
              AND indisunique
              AND indnkeyatts = 3
              AND pg_get_indexdef(indexrelid, 1, true) = 'project_id'
              AND pg_get_indexdef(indexrelid, 2, true) = 'user_id'
              AND pg_get_indexdef(indexrelid, 3, true) = 'vfs_path'
              AND pg_get_expr(indpred, indrelid) =
                '((vfs_path IS NOT NULL) AND (NULLIF((payload ->> ''vfs_path''::text), ''''::text) = vfs_path))'
          )
          AND EXISTS (
            SELECT 1
            FROM pg_index
            WHERE indexrelid = to_regclass(current_schema() || '.users_artifact_suffix_idx')
              AND indrelid = to_regclass(current_schema() || '.users')
              AND indisvalid
              AND NOT indisunique
              AND indnkeyatts = 1
              AND pg_get_indexdef(indexrelid, 1, true) = '"left"(id::text, 8)'
              AND indpred IS NULL
          )
          AND EXISTS (
            SELECT 1
            FROM pg_index
            WHERE indexrelid =
              to_regclass(current_schema() || '.org_memberships_artifact_admin_page_idx')
              AND indrelid = to_regclass(current_schema() || '.org_memberships')
              AND indisvalid
              AND NOT indisunique
              AND indnkeyatts = 2
              AND pg_get_indexdef(indexrelid, 1, true) = 'org_id'
              AND pg_get_indexdef(indexrelid, 2, true) = 'user_id'
              AND pg_get_expr(indpred, indrelid) =
                '((role)::text = ANY ((ARRAY[''owner''::character varying, ''admin''::character varying])::text[]))'
          )
        """,
        [],
        log: false
      )

    unless schema_ready do
      raise "colliding BFT migration version does not have its complete renumbered schema"
    end
  end
end
