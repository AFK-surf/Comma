defmodule SalixStore.Repo.Migrations.ExpandComputePoolBindingScope do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true
  @lock_timeout "5s"

  def up do
    execute("SET lock_timeout TO '#{@lock_timeout}'")

    execute("ALTER TABLE compute_pools ADD COLUMN IF NOT EXISTS managed_key text")
    execute("ALTER TABLE compute_provider_bindings ADD COLUMN IF NOT EXISTS environment_id text")

    execute(
      "ALTER TABLE agent_vmm_install_operations ADD COLUMN IF NOT EXISTS environment_id text"
    )

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'compute_provider_bindings_environment_id_fkey'
      ) THEN
        ALTER TABLE compute_provider_bindings
        ADD CONSTRAINT compute_provider_bindings_environment_id_fkey
        FOREIGN KEY (environment_id) REFERENCES compute_environments(id) NOT VALID;
      END IF;
    END
    $$
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'agent_vmm_install_operations_environment_id_fkey'
      ) THEN
        ALTER TABLE agent_vmm_install_operations
        ADD CONSTRAINT agent_vmm_install_operations_environment_id_fkey
        FOREIGN KEY (environment_id) REFERENCES compute_environments(id) NOT VALID;
      END IF;
    END
    $$
    """)

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS compute_pools_tenant_id_managed_key_index
    ON compute_pools (tenant_id, managed_key)
    WHERE managed_key IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS compute_provider_bindings_environment_provider_status_index
    ON compute_provider_bindings (environment_id, provider, status)
    WHERE environment_id IS NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS compute_provider_bindings_agent_vmm_scope_ref_index
    ON compute_provider_bindings (pool_id, environment_id, provider_ref)
    WHERE provider = 'agent_vmm' AND environment_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS agent_vmm_install_operations_environment_status_index
    ON agent_vmm_install_operations (environment_id, authorization_status, updated_at)
    WHERE environment_id IS NOT NULL
    """)

    execute("""
    ALTER TABLE compute_provider_bindings
    VALIDATE CONSTRAINT compute_provider_bindings_environment_id_fkey
    """)

    execute("""
    ALTER TABLE agent_vmm_install_operations
    VALIDATE CONSTRAINT agent_vmm_install_operations_environment_id_fkey
    """)

    execute("RESET lock_timeout")
  end

  def down do
    execute("SET lock_timeout TO '#{@lock_timeout}'")

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS agent_vmm_install_operations_environment_status_index"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS compute_provider_bindings_agent_vmm_scope_ref_index"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS compute_provider_bindings_environment_provider_status_index"
    )

    execute("DROP INDEX CONCURRENTLY IF EXISTS compute_pools_tenant_id_managed_key_index")

    alter table(:agent_vmm_install_operations) do
      remove(:environment_id)
    end

    alter table(:compute_provider_bindings) do
      remove(:environment_id)
    end

    alter table(:compute_pools) do
      remove(:managed_key)
    end

    execute("RESET lock_timeout")
  end
end
