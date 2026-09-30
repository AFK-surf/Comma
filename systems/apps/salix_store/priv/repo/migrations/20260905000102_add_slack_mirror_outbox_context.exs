defmodule SalixStore.Repo.Migrations.AddSlackMirrorOutboxContext do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE slack_mirror_outbox ADD COLUMN IF NOT EXISTS context jsonb NOT NULL DEFAULT '{}'::jsonb"
    )
  end

  def down do
    execute("ALTER TABLE slack_mirror_outbox DROP COLUMN IF EXISTS context")
  end
end
