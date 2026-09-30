defmodule SalixStore.Repo.Migrations.BindRuntimeSubscriptionAccounts do
  use Ecto.Migration

  def change do
    execute(
      "CREATE SEQUENCE runtime_subscription_delivery_revision",
      "DROP SEQUENCE runtime_subscription_delivery_revision"
    )

    create table(:runtime_subscription_bindings, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:device_id, :text, primary_key: true)
      add(:device_runtime_id, :text, primary_key: true)
      add(:identity_material, :text, null: false)
      add(:account_id, :text, null: false)
      add(:enabled, :boolean, null: false, default: true)
      add(:connection_generation, :bigint, null: false, default: 0)
      add(:revision, :bigint, null: false, default: 0)
      add(:status, :text, null: false, default: "pending")
      add(:failures, :integer, null: false, default: 0)
      add(:next_delivery_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      index(:runtime_subscription_bindings, [:next_delivery_at],
        where: "status IN ('pending','ready','account_unavailable')",
        name: :runtime_subscription_due
      )
    )

    create(index(:runtime_subscription_bindings, [:tenant_id, :account_id]))

    create(
      unique_index(
        :runtime_subscription_bindings,
        [:tenant_id, :group_id, :device_id, :identity_material],
        name: :runtime_subscription_native_target
      )
    )
  end
end
