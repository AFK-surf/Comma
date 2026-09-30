defmodule SalixStore.Repo.Migrations.CreateAgentVMMInstallOperations do
  use Ecto.Migration

  def change do
    create table(:agent_vmm_install_operations, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:surface, :text, null: false)
      add(:scope_key, :text, null: false)
      add(:client_request_id, :text, null: false)
      add(:provider, :text, null: false)
      add(:delivery_target_type, :text, null: false)
      add(:delivery_target_id, :text, null: false)
      add(:registration_id, :text, null: false)
      add(:authorization_status, :text, null: false)
      add(:ticket_generation, :bigint, null: false)
      add(:ticket_secret_hash, :binary, null: false)
      add(:ticket_status, :text, null: false)
      add(:ticket_expires_at, :utc_datetime_usec, null: false)
      add(:ticket_consumed_at, :utc_datetime_usec)
      add(:host_identity_digest, :binary)
      add(:material_digest, :binary)
      add(:material_ciphertext, :text)
      add(:material_handoff_expires_at, :utc_datetime_usec)
      add(:material_handed_off_at, :utc_datetime_usec)
      add(:error_code, :text)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(
        :agent_vmm_install_operations,
        [:surface, :scope_key, :client_request_id],
        name: :agent_vmm_install_operations_idempotency
      )
    )

    create(
      index(
        :agent_vmm_install_operations,
        [
          :surface,
          :delivery_target_type,
          :delivery_target_id,
          :authorization_status,
          :updated_at
        ],
        name: :agent_vmm_install_operations_delivery
      )
    )

    create(index(:agent_vmm_install_operations, [:ticket_status, :ticket_expires_at]))

    create(
      index(
        :agent_vmm_install_operations,
        [:authorization_status, :material_handoff_expires_at]
      )
    )

    create(unique_index(:agent_vmm_install_operations, [:ticket_secret_hash]))
    create(unique_index(:agent_vmm_install_operations, [:registration_id]))

    create(
      constraint(:agent_vmm_install_operations, :agent_vmm_install_operation_status,
        check:
          "authorization_status IN ('requested', 'exchange_committed', 'handed_off', 'revoked', 'action_required')"
      )
    )

    create(
      constraint(:agent_vmm_install_operations, :agent_vmm_install_ticket_status,
        check: "ticket_status IN ('active', 'consumed', 'expired', 'revoked')"
      )
    )
  end
end
