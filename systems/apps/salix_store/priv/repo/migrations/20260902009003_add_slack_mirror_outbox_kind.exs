defmodule SalixStore.Repo.Migrations.AddSlackMirrorOutboxKind do
  use Ecto.Migration

  # Expand: the outbox already exists on mixed-version fleets that applied the
  # original create without `kind`. Message and reaction rows share one table;
  # the drainer routes on this column. IF NOT EXISTS keeps a fresh create that
  # already has the column a no-op.
  def change do
    execute(
      """
      ALTER TABLE slack_mirror_outbox
        ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'message'
      """,
      """
      ALTER TABLE slack_mirror_outbox DROP COLUMN IF EXISTS kind
      """
    )
  end
end
