defmodule Comma.Repo.Migrations.AddOauthClientAdminActions do
  use Ecto.Migration

  # Online mixed-version contract: a plain DROP+ADD CHECK validates the
  # whole audit table under ACCESS EXCLUSIVE. Instead: short ADD ... NOT
  # VALID (metadata-only), then VALIDATE CONSTRAINT under SHARE UPDATE
  # EXCLUSIVE, each in its own autocommit statement. Idempotent so a
  # partial apply can be retried statement by statement.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @constraint "comma_admin_audit_action_valid"
  @table "comma_admin_audit_events"

  @new_actions """
  action IN (
    'create_user',
    'update_user',
    'set_admin_access',
    'create_support_session',
    'bootstrap_workspace',
    'revoke_user_session',
    'revoke_all_user_sessions',
    'create_redeem_code',
    'disable_redeem_code',
    'apply_redeem_code',
    'issue_workspace_credits',
    'create_oauth_client',
    'rotate_oauth_client_secret',
    'disable_oauth_client',
    'enable_oauth_client'
  )
  """

  @old_actions """
  action IN (
    'create_user',
    'update_user',
    'set_admin_access',
    'create_support_session',
    'bootstrap_workspace',
    'revoke_user_session',
    'revoke_all_user_sessions',
    'create_redeem_code',
    'disable_redeem_code',
    'apply_redeem_code',
    'issue_workspace_credits'
  )
  """

  def up, do: swap_constraint(@new_actions)

  def down, do: swap_constraint(@old_actions)

  defp swap_constraint(check) do
    # Enforce the manifest's lockBudgetSeconds at the database: a
    # waiting ACCESS EXCLUSIVE request queues every later serving query
    # behind it, so each DDL statement may WAIT at most 5s before
    # failing with lock_not_available (diagnosable, and safe to retry
    # exactly — every statement below is idempotent). Session-level SET
    # is correct for this non-transactional migration: the statements
    # share one connection, and on failure the migration process exits
    # and the connection (with its session setting) is discarded, so no
    # RESET is required on the error path.
    execute("SET lock_timeout TO '5s'")

    execute("ALTER TABLE #{@table} DROP CONSTRAINT IF EXISTS #{@constraint}")

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = '#{@constraint}'
          AND conrelid = '#{@table}'::regclass
      ) THEN
        ALTER TABLE #{@table}
          ADD CONSTRAINT #{@constraint}
          CHECK (#{check})
          NOT VALID;
      END IF;
    END
    $$
    """)

    # No-op when the constraint is already validated, SHARE UPDATE
    # EXCLUSIVE otherwise: reads and writes keep flowing.
    execute("ALTER TABLE #{@table} VALIDATE CONSTRAINT #{@constraint}")

    execute("RESET lock_timeout")
  end
end
