defmodule SalixStore.Repo.Migrations.ContractManagedReleaseCatalog do
  use Ecto.Migration

  @lock_timeout "5s"

  def up do
    execute("SET LOCAL lock_timeout TO '#{@lock_timeout}'")

    drop(
      constraint(
        :agent_vmm_install_operations,
        :agent_vmm_install_operations_host_component_release_id_fkey
      )
    )

    drop(
      constraint(
        :agent_vmm_install_operations,
        :agent_vmm_install_operation_platform
      )
    )

    drop(index(:agent_vmm_install_operations, [:host_component_release_id]))

    alter table(:agent_vmm_install_operations) do
      remove(:host_component_release_id)
      remove(:platform)
      remove(:material_digest)
    end

    drop(table(:active_release_catalogs))
    drop(table(:managed_release_catalog_components))
    drop(table(:managed_release_catalogs))
    drop(table(:managed_component_releases))
  end

  def down do
    raise "managed release catalog contract migration is irreversible"
  end
end
