defmodule SalixStore.Repo.Migrations.IndexExternalDeviceWaitCandidates do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS session_work_candidates_external_input_idx
    ON session_work_candidates (agent_id, runtime_kind, session_id, candidate_token)
    WHERE runtime_kind = 'external'
      AND reasons && ARRAY['unacked_queue_item', 'runtime_wait']::text[]
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS session_work_candidates_external_input_idx")
  end
end
