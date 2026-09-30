defmodule Comma.Repo.Migrations.RepairRenumberedBftLedgerCollision do
  use Ecto.Migration

  @disable_ddl_transaction true

  @colliding_versions [20_260_723_000_002, 20_260_723_000_003]
  @renumbered_versions [20_260_723_000_012, 20_260_723_000_013]

  def up do
    unless comma_conversation_schema_ready?() do
      verify_collision!()

      repo().query!(
        """
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1
            FROM schema_migrations
            WHERE version = 20260723000012
          ) OR NOT EXISTS (
            SELECT 1
            FROM schema_migrations
            WHERE version = 20260723000013
          ) THEN
            RAISE EXCEPTION 'renumbered BFT migrations must be recorded before ledger repair';
          END IF;

          DELETE FROM schema_migrations
          WHERE version IN (20260723000002, 20260723000003);
        END
        $$;
        """,
        [],
        log: false
      )

      raise """
      cleared colliding BFT migration versions 20260723000002/20260723000003 \
      after verifying their renumbered schema; rerun the release so the Comma-owned \
      migrations are planned and applied under those versions
      """
    end
  end

  def down do
    raise "shared migration ledger collision repair is forward-only"
  end

  defp comma_conversation_schema_ready? do
    %{rows: [[ready]]} =
      repo().query!(
        """
        SELECT
          EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND table_name = 'comma_import_checkpoints'
              AND column_name = 'release_identity'
              AND is_nullable = 'NO'
          )
          AND EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND table_name = 'comma_conversation_bindings'
              AND column_name = 'salix_group_id'
              AND is_nullable = 'NO'
          )
          AND EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND table_name = 'comma_conversation_bindings'
              AND column_name = 'group_generation'
              AND is_nullable = 'NO'
          )
          AND EXISTS (
            SELECT 1
            FROM pg_constraint
            WHERE conrelid = to_regclass(current_schema() || '.comma_assistant_chat_bindings')
              AND conname = 'comma_assistant_chat_bindings_state_check'
          )
          AND EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND table_name = 'comma_conversation_adoption_attempts'
              AND column_name = 'metadata'
              AND is_nullable = 'NO'
          )
        """,
        [],
        log: false
      )

    ready
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
        [@colliding_versions],
        log: false
      )

    unless Enum.map(rows, &hd/1) == @colliding_versions do
      raise "Comma conversation schema is incomplete without the exact colliding BFT ledger versions"
    end

    %{rows: renumbered_rows} =
      repo().query!(
        """
        SELECT version
        FROM schema_migrations
        WHERE version = ANY($1)
        ORDER BY version
        """,
        [@renumbered_versions],
        log: false
      )

    unless Enum.map(renumbered_rows, &hd/1) == @renumbered_versions do
      raise "colliding BFT ledger versions cannot be cleared before their renumbered versions are recorded"
    end

    %{rows: [[schema_ready]]} =
      repo().query!(
        """
        SELECT
          to_regclass(current_schema() || '.dashboard_projection_refreshes') IS NOT NULL
          AND to_regclass(current_schema() || '.tenant_config_scans') IS NOT NULL
          AND to_regclass(current_schema() || '.observability_prune_scans') IS NOT NULL
          AND to_regclass(current_schema() || '.project_device_projections') IS NOT NULL
          AND to_regclass(current_schema() || '.project_device_projection_scans') IS NOT NULL
        """,
        [],
        log: false
      )

    unless schema_ready do
      raise "colliding BFT ledger versions do not have their required schema"
    end
  end
end
