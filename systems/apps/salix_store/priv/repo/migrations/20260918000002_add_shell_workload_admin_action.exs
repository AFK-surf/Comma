defmodule SalixStore.Repo.Migrations.AddShellWorkloadAdminAction do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '5s'")
    drop(constraint(:agent_vmm_admin_command_receipts, :agent_vmm_admin_receipt_action_valid))

    create(
      constraint(:agent_vmm_admin_command_receipts, :agent_vmm_admin_receipt_action_valid,
        check:
          "action IN ('retry_agent_vmm_install','enable_agent_vmm_registration','disable_agent_vmm_registration','revoke_agent_vmm_registration','drain_compute_environment','revoke_compute_environment','create_shell_workload')"
      )
    )
  end

  def down do
    raise "Preserve Shell workload command history. Use a forward migration."
  end
end
