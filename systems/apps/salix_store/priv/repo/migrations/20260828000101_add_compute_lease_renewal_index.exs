defmodule SalixStore.Repo.Migrations.AddComputeLeaseRenewalIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true
  @lock_timeout "5s"

  def up do
    execute("SET lock_timeout TO '#{@lock_timeout}'")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS compute_allocations_ready_lease_expiry_idx
    ON compute_allocations (lease_expires_at, id)
    WHERE status = 'ready' AND lease_expires_at IS NOT NULL
    """)

    execute("RESET lock_timeout")
  end

  def down do
    execute("SET lock_timeout TO '#{@lock_timeout}'")
    execute("DROP INDEX CONCURRENTLY IF EXISTS compute_allocations_ready_lease_expiry_idx")
    execute("RESET lock_timeout")
  end
end
