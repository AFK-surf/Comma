defmodule SalixStore.Repo.Migrations.CreateSalixSessionHandoffs do
  use Ecto.Migration

  # Disposable per-session living handoff projection for zero-stall compaction
  # cutover. Expand-only additive migration: old runtimes ignore this table.
  def up do
    execute("""
    CREATE TABLE salix_session_handoffs (
      agent_id text NOT NULL,
      session_id text NOT NULL,
      revision bigint NOT NULL,
      base_summary_sequence bigint NOT NULL,
      base_compacted_through bigint NOT NULL,
      covered_message_id bigint NOT NULL,
      prefix_digest text NOT NULL,
      value jsonb NOT NULL,
      updated_at timestamptz NOT NULL,
      PRIMARY KEY (agent_id, session_id),
      FOREIGN KEY (agent_id, session_id)
        REFERENCES salix_sessions (agent_id, session_id)
        ON DELETE CASCADE
    )
    """)
  end

  def down do
    drop(table(:salix_session_handoffs))
  end
end
