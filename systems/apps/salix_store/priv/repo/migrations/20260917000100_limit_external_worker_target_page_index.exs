defmodule SalixStore.Repo.Migrations.LimitExternalWorkerTargetPageIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "compute_workloads_environment_page_idx"
  @replacement "compute_workloads_active_target_page_idx"

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@replacement}
    ON compute_workloads (environment_id, updated_at DESC, id DESC)
    WHERE desired_state = 'ready'
    """)

    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")
    execute("ALTER INDEX #{@replacement} RENAME TO #{@index}")
  end

  def down do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@replacement}
    ON compute_workloads (environment_id, updated_at DESC, id DESC)
    """)

    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")
    execute("ALTER INDEX #{@replacement} RENAME TO #{@index}")
  end
end
