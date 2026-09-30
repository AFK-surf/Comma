defmodule SalixStore.Repo.Migrations.RewriteSessionWorkBackfill do
  use Ecto.Migration

  # Existing release attempts may have persisted a cursor under the original
  # two-pass S3 strategy. Versioning lets the new one-pass strategy restart
  # from a clean durable prefix instead of interpreting that cursor under a
  # different access pattern.
  def up do
    execute("""
    ALTER TABLE session_work_backfill_state
      ADD COLUMN strategy_version integer NOT NULL DEFAULT 1,
      ADD COLUMN projection_gaps bigint NOT NULL DEFAULT 0,
      ADD CONSTRAINT session_work_backfill_strategy_version_positive
        CHECK (strategy_version > 0),
      ADD CONSTRAINT session_work_backfill_projection_gaps_nonnegative
        CHECK (projection_gaps >= 0)
    """)

    execute("""
    CREATE TABLE session_work_backfill_expected_candidates (
      agent_id text COLLATE "C" NOT NULL,
      runtime_kind text COLLATE "C" NOT NULL,
      session_id text COLLATE "C" NOT NULL,
      candidate_token text COLLATE "C" NOT NULL,
      base_revision text COLLATE "C",
      due_at_ms bigint,
      reasons text[] NOT NULL,
      PRIMARY KEY (agent_id, runtime_kind, session_id),
      UNIQUE (candidate_token),
      CONSTRAINT session_work_backfill_expected_runtime_kind
        CHECK (runtime_kind IN ('internal', 'external'))
    )
    """)
  end

  def down do
    execute("DROP TABLE session_work_backfill_expected_candidates")

    execute("""
    ALTER TABLE session_work_backfill_state
      DROP CONSTRAINT session_work_backfill_projection_gaps_nonnegative,
      DROP CONSTRAINT session_work_backfill_strategy_version_positive,
      DROP COLUMN projection_gaps,
      DROP COLUMN strategy_version
    """)
  end
end
