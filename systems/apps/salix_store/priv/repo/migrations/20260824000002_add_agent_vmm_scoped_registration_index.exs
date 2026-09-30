defmodule SalixStore.Repo.Migrations.AddAgentVMMScopedRegistrationIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name :agent_vmm_registrations_tenant_id_group_id_device_id_index

  def up do
    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name}
    ON agent_vmm_registrations (tenant_id, group_id, device_id)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index_name}")
  end
end
