defmodule SalixStore.Repo.Migrations.DropAgentVMMLegacyRegistrationIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @legacy_index_name :agent_vmm_registrations_tenant_id_device_id_index

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@legacy_index_name}")
  end

  def down do
    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS #{@legacy_index_name}
    ON agent_vmm_registrations (tenant_id, device_id)
    """)
  end
end
