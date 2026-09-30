defmodule Comma.Repo.Migrations.AddAgentVMMAdminActions do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true
  @constraint "comma_admin_audit_action_valid"
  @table "comma_admin_audit_events"

  @new_actions ~w(
    create_user update_user set_admin_access create_support_session bootstrap_workspace
    revoke_user_session revoke_all_user_sessions create_redeem_code disable_redeem_code
    apply_redeem_code issue_workspace_credits create_oauth_client rotate_oauth_client_secret
    disable_oauth_client enable_oauth_client retry_agent_vmm_install
    enable_agent_vmm_registration disable_agent_vmm_registration revoke_agent_vmm_registration
    drain_compute_environment revoke_compute_environment
  )

  @old_actions ~w(
    create_user update_user set_admin_access create_support_session bootstrap_workspace
    revoke_user_session revoke_all_user_sessions create_redeem_code disable_redeem_code
    apply_redeem_code issue_workspace_credits create_oauth_client rotate_oauth_client_secret
    disable_oauth_client enable_oauth_client
  )

  def up, do: swap_constraint(@new_actions)
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
