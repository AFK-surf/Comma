defmodule SalixStore.Repo.Migrations.BindComputeSubscriptions do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE runtime_subscription_bindings DROP CONSTRAINT runtime_subscription_bindings_pkey"
    )

    execute("ALTER TABLE runtime_subscription_bindings ADD COLUMN id bigserial PRIMARY KEY")

    execute(
      "ALTER TABLE runtime_subscription_bindings ALTER COLUMN group_id DROP NOT NULL, ALTER COLUMN device_id DROP NOT NULL, ALTER COLUMN device_runtime_id DROP NOT NULL, ALTER COLUMN identity_material DROP NOT NULL"
    )

    alter table(:runtime_subscription_bindings) do
      add(:last_delivery_revoked, :boolean, null: false, default: false)
      add(:workload_id, :text)
      add(:project_id, :text)
      add(:connection_epoch, :text, null: false, default: "")
    end

    create(
      unique_index(
        :runtime_subscription_bindings,
        [:tenant_id, :group_id, :device_id, :device_runtime_id],
        name: :runtime_subscription_device_key
      )
    )

    create(
      unique_index(:runtime_subscription_bindings, [:tenant_id, :workload_id],
        name: :runtime_subscription_workload_key
      )
    )

    create(
      constraint(:runtime_subscription_bindings, :runtime_subscription_target,
        check:
          "(workload_id IS NULL AND project_id IS NULL AND group_id IS NOT NULL AND device_id IS NOT NULL AND device_runtime_id IS NOT NULL AND identity_material IS NOT NULL) OR (workload_id IS NOT NULL AND project_id IS NOT NULL AND group_id IS NULL AND device_id IS NULL AND device_runtime_id IS NULL AND identity_material IS NULL)"
      )
    )
  end

  def down do
    raise "Workload subscription bindings require forward repair; do not discard account selections"
  end
end
