defmodule SalixStore.Repo.Migrations.CreateAgentVMMAdminCommandReceipts do
  use Ecto.Migration

  def change do
    alter table(:agent_vmm_install_operations) do
      add(:revision, :bigint, null: false, default: 1)
    end

    create table(:agent_vmm_admin_command_receipts, primary_key: false) do
      add(:command_id, :uuid, primary_key: true)
      add(:action, :text, null: false)
      add(:tenant_id, :text, null: false)
      add(:target, :text, null: false)
      add(:fingerprint, :binary, null: false)
      add(:result_revision, :bigint, null: false)
    end

    create(
      constraint(:agent_vmm_admin_command_receipts, :agent_vmm_admin_receipt_action_valid,
        check:
          "action IN ('retry_agent_vmm_install', 'enable_agent_vmm_registration', 'disable_agent_vmm_registration', 'revoke_agent_vmm_registration', 'drain_compute_environment', 'revoke_compute_environment')"
      )
    )

    create(
      constraint(:agent_vmm_admin_command_receipts, :agent_vmm_admin_receipt_fingerprint_valid,
        check: "octet_length(fingerprint) = 32"
      )
    )
  end
end
