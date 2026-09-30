defmodule BridgeForTeams.Repo.Migrations.AddAgentConfigurationAuthority do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :configuration_authority, :text, null: false, default: "legacy"
    end
  end
end
