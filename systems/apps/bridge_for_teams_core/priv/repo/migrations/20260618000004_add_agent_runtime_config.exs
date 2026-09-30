defmodule BridgeForTeams.Repo.Migrations.AddAgentRuntimeConfig do
  use Ecto.Migration

  # External Bridge agents reconcile into Salix by carrying the Salix
  # runtime_config payload selected from a connected environment's advertised
  # Codex runtime.
  def change do
    alter table(:agents) do
      add :runtime_config, :map
    end
  end
end
