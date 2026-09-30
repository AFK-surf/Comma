defmodule SalixStore.Repo.Migrations.CreateSessionWorkCandidates do
  use Ecto.Migration

  # Cross-session recovery discovery belongs in Postgres; authoritative
  # per-session state and the agent-local wake marker remain in S3. Candidate
  # rows are immutable and token-addressed so mark-before-CAS retries can only
  # insert once and cleanup can only delete the exact attempted generation.
  #
  # Text identity columns use bytewise C collation. The recovery cursor uses
  # the same immutable total order as Elixir binary ordering, which keeps a
  # keyset page contiguous across database and BEAM boundaries.
  def change do
    execute(
      """
      CREATE TABLE session_work_candidates (
        candidate_token text COLLATE "C" PRIMARY KEY,
        agent_id text COLLATE "C" NOT NULL,
        runtime_kind text COLLATE "C" NOT NULL,
        session_id text COLLATE "C" NOT NULL,
        base_revision text COLLATE "C",
        due_at_ms bigint,
        reasons text[] NOT NULL,
        inserted_at_ms bigint NOT NULL,
        CONSTRAINT session_work_candidates_runtime_kind
          CHECK (runtime_kind IN ('internal', 'external'))
      )
      """,
      "DROP TABLE session_work_candidates"
    )

    execute(
      """
      CREATE INDEX session_work_candidates_eager_cursor_idx
      ON session_work_candidates
        (agent_id, runtime_kind, session_id, candidate_token)
      WHERE due_at_ms IS NULL
      """,
      "DROP INDEX session_work_candidates_eager_cursor_idx"
    )

    execute(
      """
      CREATE INDEX session_work_candidates_deferred_cursor_idx
      ON session_work_candidates
        (due_at_ms, agent_id, runtime_kind, session_id, candidate_token)
      WHERE due_at_ms IS NOT NULL
      """,
      "DROP INDEX session_work_candidates_deferred_cursor_idx"
    )
  end
end
