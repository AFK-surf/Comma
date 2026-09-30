defmodule BridgeForTeams.Repo.Migrations.AddAuditLogsCreatedAtIndexConcurrently do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_logs_created_at_idx
    ON audit_logs (created_at)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS audit_logs_created_at_idx")
  end
end
