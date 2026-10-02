defmodule SalixStore.Repo.Migrations.ContractAgentVMMActiveRegistrationUniqueness do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # The expand migration installs this active-row fence before the full fence is removed.
    execute("""
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = current_schema()
          AND c.relname = 'agent_vmm_registrations_active_scope_device_index'
          AND i.indisunique AND i.indisvalid AND i.indisready
          AND pg_get_expr(i.indpred, i.indrelid) = '(status <> ''revoked''::text)'
      ) THEN
        RAISE EXCEPTION 'active registration uniqueness expand is incomplete';
      END IF;
    END $$
    """)

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS agent_vmm_registrations_tenant_id_group_id_device_id_index"
    )
  end

  def down do
    raise "active registration uniqueness cannot restore the historical full fence after replacements"
  end
end
