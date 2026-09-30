defmodule SalixStore.Repo.Migrations.CreateAgentVMMRouteCapabilities do
  use Ecto.Migration

  def change do
    create table(:agent_vmm_route_capabilities, primary_key: false) do
      add(:id, :text, primary_key: true)

      add(:anchor_id, references(:agent_vmm_trust_anchors, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:tenant_id, :text, null: false)
      add(:source_device_id, :text, null: false)
      add(:source_allocation_id, :text)
      add(:destination_device_id, :text, null: false)
      add(:destination_export_id, :text, null: false)
      add(:allowed_protocol, :text, null: false)
      add(:allowed_verbs, {:array, :text}, null: false, default: [])
      add(:route_class, :text, null: false)
      add(:route_generation, :bigint, null: false)
      add(:policy_revision, :bigint, null: false)
      add(:connection_limit, :integer, null: false)
      add(:byte_limit, :bigint, null: false)
      add(:concurrency_limit, :integer, null: false)
      add(:audience, :text, null: false)
      add(:issuer_key_id, :text, null: false)
      add(:canonical_payload, :binary, null: false)
      add(:signature, :binary, null: false)
      add(:not_before, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:revoked_at, :utc_datetime_usec)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(
      index(:agent_vmm_route_capabilities, [:tenant_id, :source_device_id, :expires_at],
        where: "revoked_at IS NULL"
      )
    )

    create(
      unique_index(:agent_vmm_route_capabilities, [
        :tenant_id,
        :destination_export_id,
        :route_generation
      ])
    )

    create(
      constraint(:agent_vmm_route_capabilities, :agent_vmm_route_capability_class,
        check: "route_class IN ('local', 'device', 'compute', 'lan', 'public_http')"
      )
    )
  end
end
