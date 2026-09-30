defmodule BridgeForTeams.Repo.Migrations.AddOrganizationIcon do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE organizations ADD COLUMN IF NOT EXISTS icon text",
      "ALTER TABLE organizations DROP COLUMN IF EXISTS icon"
    )
  end
end
