defmodule BridgeForTeams.Repo.Migrations.ContractServerBoundReleaseRefs do
  use Ecto.Migration

  @lock_timeout "5s"

  def up do
    execute("SET LOCAL lock_timeout TO '#{@lock_timeout}'")

    drop(index(:mac_mini_install_codes, [:release_catalog_id]))
    drop(index(:mac_mini_provisioners, [:salix_connect_target_id]))
    drop(index(:mac_mini_provisioners, [:agent_vmm_host_target_id]))

    alter table(:mac_mini_install_codes) do
      remove(:release_catalog_id)
      remove(:release_snapshot)
    end

    alter table(:mac_mini_provisioners) do
      remove(:target_release_id)
      remove(:component_targets)
      remove(:salix_connect_target_id)
      remove(:agent_vmm_host_target_id)
    end
  end

  def down do
    raise "server-bound release refs contract migration is irreversible"
  end
end
