defmodule SalixStore.Repo.Migrations.AddSlackMirrorBackfillConnectKickGeneration do
  use Ecto.Migration

  # A kick bumps this number. A finish defers only if it claimed at that
  # generation, so a stale overlapping finisher cannot consume a newer kick.
  # Model: tla/salix/SlackMirrorConnectKick.tla
  def change do
    execute(
      """
      ALTER TABLE slack_mirror_backfill_connects
        ADD COLUMN IF NOT EXISTS kick_generation bigint NOT NULL DEFAULT 0
      """,
      """
      ALTER TABLE slack_mirror_backfill_connects DROP COLUMN IF EXISTS kick_generation
      """
    )
  end
end
