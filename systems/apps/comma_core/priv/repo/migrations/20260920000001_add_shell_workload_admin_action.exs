defmodule Comma.Repo.Migrations.AddShellWorkloadAdminAction do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '5s'")
    drop(constraint(:comma_admin_audit_events, :comma_admin_audit_action_valid))

    create(
      constraint(:comma_admin_audit_events, :comma_admin_audit_action_valid,
        check:
          "action IN ('create_user','update_user','set_admin_access','create_support_session','bootstrap_workspace','revoke_user_session','revoke_all_user_sessions','create_redeem_code','disable_redeem_code','apply_redeem_code','issue_workspace_credits','create_oauth_client','rotate_oauth_client_secret','disable_oauth_client','enable_oauth_client','retry_agent_vmm_install','enable_agent_vmm_registration','disable_agent_vmm_registration','revoke_agent_vmm_registration','drain_compute_environment','revoke_compute_environment','update_workspace_agent_model','update_workspace_vm','create_shell_workload')"
      )
    )
  end

  def down do
    raise "Preserve Shell workload command history. Use a forward migration."
  end
end
