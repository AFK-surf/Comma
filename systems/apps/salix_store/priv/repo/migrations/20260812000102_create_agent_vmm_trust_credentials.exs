defmodule SalixStore.Repo.Migrations.CreateAgentVMMTrustCredentials do
  use Ecto.Migration

  def change do
    create table(:agent_vmm_membership_credentials, primary_key: false) do
      add(:id, :text, primary_key: true)

      add(:anchor_id, references(:agent_vmm_trust_anchors, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:tenant_id, :text, null: false)
      add(:device_id, :text, null: false)
      add(:root_public_key, :binary, null: false)
      add(:root_key_revision, :bigint, null: false)
      add(:permissions, {:array, :text}, null: false, default: [])
      add(:policy_revision, :bigint, null: false)
      add(:canonical_payload, :binary, null: false)
      add(:signature, :binary, null: false)
      add(:opaque_claims_digest, :binary)
      add(:not_before, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:revoked_at, :utc_datetime_usec)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(
      index(:agent_vmm_membership_credentials, [:tenant_id, :device_id, :expires_at],
        where: "revoked_at IS NULL"
      )
    )

    create(
      constraint(:agent_vmm_membership_credentials, :agent_vmm_membership_claim_digest_size,
        check: "octet_length(opaque_claims_digest) = 32"
      )
    )
  end
end
