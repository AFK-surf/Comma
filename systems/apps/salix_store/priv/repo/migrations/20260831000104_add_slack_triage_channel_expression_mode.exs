defmodule SalixStore.Repo.Migrations.AddSlackTriageChannelExpressionMode do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true
  @lock_timeout "5s"
  @constraint "slack_triage_channels_valid_expression_mode"

  def up do
    execute("SET lock_timeout TO '#{@lock_timeout}'")

    # The constant default keeps old INSERT statements valid while making every
    # existing channel conservatively project-only in the same additive step.
    execute("""
    ALTER TABLE slack_triage_channels
    ADD COLUMN IF NOT EXISTS expression_mode text
    NOT NULL DEFAULT 'project'
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = '#{@constraint}'
          AND conrelid = 'slack_triage_channels'::regclass
      ) THEN
        ALTER TABLE slack_triage_channels
        ADD CONSTRAINT #{@constraint}
        CHECK (expression_mode IN ('project', 'social'))
        NOT VALID;
      END IF;
    END
    $$
    """)

    execute("""
    ALTER TABLE slack_triage_channels
    VALIDATE CONSTRAINT #{@constraint}
    """)

    execute("RESET lock_timeout")
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM slack_triage_channels
        WHERE expression_mode IS DISTINCT FROM 'project'
      ) THEN
        RAISE EXCEPTION
          'cannot drop slack triage expression policy while non-project values exist';
      END IF;
    END
    $$
    """)

    execute("SET lock_timeout TO '#{@lock_timeout}'")

    execute("""
    ALTER TABLE slack_triage_channels
    DROP CONSTRAINT IF EXISTS #{@constraint}
    """)

    execute("""
    ALTER TABLE slack_triage_channels
    DROP COLUMN IF EXISTS expression_mode
    """)

    execute("RESET lock_timeout")
  end
end
