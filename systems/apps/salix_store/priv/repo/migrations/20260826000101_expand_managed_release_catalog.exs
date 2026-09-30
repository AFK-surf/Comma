defmodule SalixStore.Repo.Migrations.ExpandManagedReleaseCatalog do
  use Ecto.Migration

  def change do
    create table(:managed_component_releases, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:component, :text, null: false)
      add(:revision, :bigint)
      add(:targets, :map, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:managed_component_releases, [:id, :component]))

    create(
      unique_index(:managed_component_releases, [:component, :revision],
        where: "revision IS NOT NULL"
      )
    )

    create(
      constraint(:managed_component_releases, :managed_component_release_shape,
        check: """
        (component IN ('salix-connect', 'agent-vmm-host') AND revision > 0)
        OR
        (component IN ('runner', 'fin-manifest') AND revision IS NULL)
        """
      )
    )

    create table(:managed_release_catalogs, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create table(:managed_release_catalog_components, primary_key: false) do
      add(
        :catalog_id,
        references(:managed_release_catalogs,
          column: :id,
          type: :text,
          on_delete: :restrict
        ),
        primary_key: true,
        null: false
      )

      add(:component, :text, primary_key: true, null: false)
      add(:component_release_id, :text, null: false)
    end

    execute(
      """
      ALTER TABLE managed_release_catalog_components
      ADD CONSTRAINT managed_release_catalog_components_release_fkey
      FOREIGN KEY (component_release_id, component)
      REFERENCES managed_component_releases (id, component)
      ON DELETE RESTRICT
      """,
      """
      ALTER TABLE managed_release_catalog_components
      DROP CONSTRAINT managed_release_catalog_components_release_fkey
      """
    )

    create table(:active_release_catalogs, primary_key: false) do
      add(:purpose, :text, primary_key: true)

      add(
        :catalog_id,
        references(:managed_release_catalogs,
          column: :id,
          type: :text,
          on_delete: :restrict
        ),
        null: false
      )

      add(:activated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:active_release_catalogs, :active_release_catalog_purpose,
        check: "purpose = 'runner_install'"
      )
    )

    alter table(:agent_vmm_install_operations) do
      add(
        :host_component_release_id,
        references(:managed_component_releases,
          column: :id,
          type: :text,
          on_delete: :restrict
        )
      )

      add(:platform, :text)
    end

    create(index(:agent_vmm_install_operations, [:host_component_release_id]))

    create(
      constraint(:agent_vmm_install_operations, :agent_vmm_install_operation_platform,
        check: "platform IS NULL OR platform = 'darwin-arm64'"
      )
    )
  end
end
