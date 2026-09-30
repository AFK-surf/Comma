defmodule BridgeForTeams.Repo.Migrations.AddExternalBindingOutboxLatestIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS reconcile_outbox_agent_external_binding_latest_idx
    ON reconcile_outbox (
      aggregate_id,
      (COALESCE(
        payload #>> '{external_binding,binding_revision}',
        payload #>> '{runtime_config,binding_revision}'
      )),
      created_at DESC,
      id DESC
    )
    INCLUDE (status)
    WHERE aggregate = 'agent'
      AND op IN ('create_agent', 'apply_external_worker_binding')
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS reconcile_outbox_agent_external_binding_latest_idx
    """)
  end
end
