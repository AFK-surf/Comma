defmodule BridgeForTeams.Repo.Migrations.AddRunnerComponentTargets do
  use Ecto.Migration

  def up do
    # An unpublished development migration briefly used a colliding version
    # and may already have added the column while recording another owner's
    # ledger entry. The final version must converge those local databases as
    # well as create the column on a clean database.
    execute("""
    ALTER TABLE mac_mini_provisioners
    ADD COLUMN IF NOT EXISTS component_targets jsonb NOT NULL DEFAULT '{}'::jsonb
    """)
  end

  def down do
    alter table(:mac_mini_provisioners) do
      remove(:component_targets)
    end
  end
end
