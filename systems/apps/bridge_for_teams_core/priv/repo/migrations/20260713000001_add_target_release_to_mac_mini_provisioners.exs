defmodule BridgeForTeams.Repo.Migrations.AddTargetReleaseToMacMiniProvisioners do
  use Ecto.Migration

  def change do
    alter table(:mac_mini_provisioners) do
      add(:target_release_id, :text)
    end
  end
end
