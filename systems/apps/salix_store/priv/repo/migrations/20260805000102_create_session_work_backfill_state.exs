defmodule SalixStore.Repo.Migrations.CreateSessionWorkBackfillState do
  use Ecto.Migration

  # Expand-only durable progress for the later exclusive release backfill.
  # The release cursor is a composite pair of physical S3 keys so retries can
  # resume after the last successfully attempted marker without opaque tokens.
  def change do
    execute(
      """
      CREATE TABLE session_work_backfill_state (
        name text COLLATE "C" PRIMARY KEY,
        phase text COLLATE "C" NOT NULL,
        agent_start_after text COLLATE "C",
        current_agent_key text COLLATE "C",
        marker_start_after text COLLATE "C",
        uncovered_authoritative_work bigint NOT NULL DEFAULT 0,
        processed bigint NOT NULL DEFAULT 0,
        updated_at_ms bigint NOT NULL,
        CONSTRAINT session_work_backfill_phase
          CHECK (phase IN ('backfill', 'verify')),
        CONSTRAINT session_work_backfill_uncovered_nonnegative
          CHECK (uncovered_authoritative_work >= 0),
        CONSTRAINT session_work_backfill_processed_nonnegative
          CHECK (processed >= 0)
      )
      """,
      "DROP TABLE session_work_backfill_state"
    )
  end
end
