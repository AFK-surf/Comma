defmodule SalixStore.Repo.Migrations.AddSlackMirrorBackfillConnectNudge do
  use Ecto.Migration

  # A channel join or a go-live kick can land while a pass still holds the
  # courtesy lease. `nudge` keeps that due-now across `finish_connect`.
  def change do
    execute(
      """
      ALTER TABLE slack_mirror_backfill_connects
        ADD COLUMN IF NOT EXISTS nudge boolean NOT NULL DEFAULT false
      """,
      """
      ALTER TABLE slack_mirror_backfill_connects DROP COLUMN IF EXISTS nudge
      """
    )
  end
end
