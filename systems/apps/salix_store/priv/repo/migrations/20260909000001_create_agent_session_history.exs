defmodule SalixStore.Repo.Migrations.CreateAgentSessionHistory do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE agent_session_history_states (
      agent_id text NOT NULL, session_id text NOT NULL,
      indexed_through bigint NOT NULL DEFAULT 0,
      cold_through bigint NOT NULL DEFAULT 0,
      checked_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (agent_id, session_id),
      CHECK (cold_through >= 0 AND indexed_through >= cold_through)
    )
    """)

    execute("""
    CREATE TABLE agent_session_history_documents (
      agent_id text NOT NULL, session_id text NOT NULL,
      seq bigint NOT NULL, part integer NOT NULL,
      text text NOT NULL, kind text NOT NULL, tool_name text NOT NULL,
      label jsonb NOT NULL,
      PRIMARY KEY (agent_id, session_id, seq, part),
      FOREIGN KEY (agent_id, session_id) REFERENCES agent_session_history_states
        ON DELETE CASCADE
    )
    """)

    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    execute(
      "CREATE INDEX agent_session_history_text ON agent_session_history_documents USING gin (text gin_trgm_ops)"
    )

    execute(
      "CREATE INDEX agent_session_history_due ON agent_session_history_states (checked_at, agent_id, session_id)"
    )

    execute(
      "CREATE TABLE agent_session_history_discovery (id integer PRIMARY KEY CHECK (id = 1), cursor text)"
    )

    execute("INSERT INTO agent_session_history_discovery (id) VALUES (1)")
  end

  def down do
    drop(table(:agent_session_history_discovery))
    drop(table(:agent_session_history_documents))
    drop(table(:agent_session_history_states))
  end
end
