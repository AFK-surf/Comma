defmodule SalixStore.Repo.Migrations.DropAgentSessionHistoryTextIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Hot history searches are scoped to one Session and a bounded seq window, so
  # the planner reads the primary key. The trigram index went unused, while its
  # fastupdate pending-list cleanup ran inside 500 ms index writes and stalled them.
  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS agent_session_history_text")
  end

  def down do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS agent_session_history_text
    ON agent_session_history_documents USING gin (text gin_trgm_ops)
    """)
  end
end
