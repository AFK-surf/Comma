defmodule SalixStore.Repo.Migrations.AddSessionWorkRecertificationState do
  use Ecto.Migration

  # Strategy v3 certifies PG-only crash residue before the existing marker
  # traversal. These three columns are the bounded exact-address keyset cursor.
  def up do
    execute("""
    ALTER TABLE session_work_backfill_state
      DROP CONSTRAINT session_work_backfill_phase,
      ADD COLUMN candidate_agent_start_after text COLLATE "C",
      ADD COLUMN candidate_runtime_kind_start_after text COLLATE "C",
      ADD COLUMN candidate_session_start_after text COLLATE "C",
      ADD CONSTRAINT session_work_backfill_phase
        CHECK (phase IN ('candidate_backfill', 'backfill', 'verify'))
    """)
  end

  def down do
    execute("""
    ALTER TABLE session_work_backfill_state
      DROP CONSTRAINT session_work_backfill_phase,
      DROP COLUMN candidate_session_start_after,
      DROP COLUMN candidate_runtime_kind_start_after,
      DROP COLUMN candidate_agent_start_after,
      ADD CONSTRAINT session_work_backfill_phase
        CHECK (phase IN ('backfill', 'verify'))
    """)
  end
end
