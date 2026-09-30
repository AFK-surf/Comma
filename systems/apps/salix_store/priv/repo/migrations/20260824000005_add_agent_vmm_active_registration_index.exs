defmodule SalixStore.Repo.Migrations.AddAgentVMMActiveRegistrationIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name :agent_vmm_registrations_active_scope_device_index

  def up do
    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name}
    ON agent_vmm_registrations (tenant_id, group_id, device_id)
    WHERE status <> 'revoked'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index_name}")
  end
end
