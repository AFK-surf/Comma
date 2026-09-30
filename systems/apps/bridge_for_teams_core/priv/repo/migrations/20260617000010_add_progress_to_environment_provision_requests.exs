defmodule BridgeForTeams.Repo.Migrations.AddProgressToEnvironmentProvisionRequests do
  use Ecto.Migration

  def change do
    alter table(:environment_provision_requests) do
      add :progress, :map, null: false, default: %{}
    end
  end
end
