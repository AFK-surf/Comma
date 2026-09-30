defmodule BridgeForTeams.Repo.Migrations.ExpandManagedReleaseRefs do
  use Ecto.Migration

  def change do
    alter table(:mac_mini_install_codes) do
      add(:release_catalog_id, :text)
      add(:runner_stable_id, :text)
    end

    create(index(:mac_mini_install_codes, [:release_catalog_id]))

    alter table(:mac_mini_provisioners) do
      add(:salix_connect_target_id, :text)
      add(:agent_vmm_host_target_id, :text)
    end

    create(index(:mac_mini_provisioners, [:salix_connect_target_id]))
    create(index(:mac_mini_provisioners, [:agent_vmm_host_target_id]))
  end
end
