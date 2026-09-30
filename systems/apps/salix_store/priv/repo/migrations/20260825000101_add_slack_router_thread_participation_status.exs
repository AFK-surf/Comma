defmodule SalixStore.Repo.Migrations.AddSlackRouterThreadParticipationStatus do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true
  @lock_timeout "5s"
  @status_expiry_index :slack_router_thread_participations_status_expiry_idx

  def up do
    execute("SET lock_timeout TO '#{@lock_timeout}'")

    execute("""
    ALTER TABLE slack_router_thread_participations
    ADD COLUMN IF NOT EXISTS participation_status text
    NOT NULL DEFAULT 'participating'
    """)

    execute("""
    ALTER TABLE slack_router_thread_participations
    ADD COLUMN IF NOT EXISTS status_expires_at timestamp(6) without time zone
    """)

    execute("""
    ALTER TABLE slack_router_thread_participations
    ALTER COLUMN status_expires_at
    SET DEFAULT (timezone('UTC', statement_timestamp()) + interval '30 days')
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'slack_router_thread_participations_valid_status'
      ) THEN
        ALTER TABLE slack_router_thread_participations
        ADD CONSTRAINT slack_router_thread_participations_valid_status
        CHECK (participation_status IN ('participating', 'not_participating'))
        NOT VALID;
      END IF;
    END
    $$
    """)

    drop_invalid_status_expiry_index()

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@status_expiry_index}
    ON slack_router_thread_participations (
      status_expires_at,
      group_id,
      connect_id,
      workspace_id,
      bot_user_id,
      channel_id,
      thread_ts
    )
    WHERE status_expires_at IS NOT NULL
    """)

    execute("RESET lock_timeout")
  end

  def down do
    execute("SET lock_timeout TO '#{@lock_timeout}'")

    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS #{@status_expiry_index}
    """)

    execute("""
    ALTER TABLE slack_router_thread_participations
    DROP CONSTRAINT IF EXISTS slack_router_thread_participations_valid_status
    """)

    execute("""
    ALTER TABLE slack_router_thread_participations
    DROP COLUMN IF EXISTS status_expires_at,
    DROP COLUMN IF EXISTS participation_status
    """)

    execute("RESET lock_timeout")
  end

  # PostgreSQL leaves an INVALID catalog entry behind when CREATE INDEX
  # CONCURRENTLY fails. IF NOT EXISTS considers that name occupied and would
  # otherwise turn a release retry into a false success.
  defp drop_invalid_status_expiry_index do
    invalid? =
      repo().query!(
        """
        SELECT NOT index_metadata.indisvalid
        FROM pg_index AS index_metadata
        JOIN pg_class AS index_class ON index_class.oid = index_metadata.indexrelid
        JOIN pg_namespace AS index_namespace ON index_namespace.oid = index_class.relnamespace
        WHERE index_namespace.nspname = current_schema()
          AND index_class.relname = $1
        """,
        [Atom.to_string(@status_expiry_index)]
      ).rows

    if invalid? == [[true]] do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{@status_expiry_index}")
    end
  end
end
