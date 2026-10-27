defmodule Comma.Repo.Migrations.AddWorkspaceAdminActions do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true
  @constraint "comma_admin_audit_action_valid"
  @table "comma_admin_audit_events"

  @old_actions ~w(
    create_user update_user set_admin_access create_support_session bootstrap_workspace
    update_workspace_vm revoke_user_session revoke_all_user_sessions create_redeem_code
    disable_redeem_code apply_redeem_code issue_workspace_credits create_oauth_client
    rotate_oauth_client_secret disable_oauth_client enable_oauth_client retry_agent_vmm_install
    enable_agent_vmm_registration disable_agent_vmm_registration revoke_agent_vmm_registration
    drain_compute_environment revoke_compute_environment create_shell_workload
    update_workspace_agent_model update_free_router_models update_model_selection_policy
    update_guest_policy create_guest_tenant disable_mini_app enable_mini_app
  )

  @new_actions @old_actions ++ ~w(update_workspace_sandbox_limit update_workspace_signal_number)

  def up, do: swap_constraint(@new_actions)

  # Fails while an audit event with either new action exists.
  def down, do: swap_constraint(@old_actions)

  defp swap_constraint(actions) do
    check = "action IN (" <> Enum.map_join(actions, ",", &"'#{&1}'") <> ")"
    execute("SET lock_timeout TO '5s'")
    execute("ALTER TABLE #{@table} DROP CONSTRAINT IF EXISTS #{@constraint}")

    execute("""
    ALTER TABLE #{@table}
      ADD CONSTRAINT #{@constraint} CHECK (#{check}) NOT VALID
    """)

    execute("ALTER TABLE #{@table} VALIDATE CONSTRAINT #{@constraint}")
    execute("RESET lock_timeout")
  end
end
