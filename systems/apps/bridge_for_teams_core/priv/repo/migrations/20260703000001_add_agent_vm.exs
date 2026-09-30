defmodule BridgeForTeams.Repo.Migrations.AddAgentVM do
  use Ecto.Migration

  # Create-time VM intent forwarded to SalixAgent.Control. Provider changes are
  # intentionally not reconciled from BridgeForTeams updates.
  def change do
    alter table(:agents) do
      add(:vm, :map)
    end
  end
end
