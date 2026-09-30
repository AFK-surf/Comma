defmodule Comma.Repo.Migrations.AddIssueWorkspaceCreditsAdminAction do
  use Ecto.Migration

  @constraint :comma_admin_audit_action_valid

  def up do
    drop(constraint(:comma_admin_audit_events, @constraint))

    create(
      constraint(:comma_admin_audit_events, @constraint,
        check: """
        action IN (
          'create_user',
          'update_user',
          'set_admin_access',
          'create_support_session',
          'bootstrap_workspace',
          'revoke_user_session',
          'revoke_all_user_sessions',
          'create_redeem_code',
          'disable_redeem_code',
          'apply_redeem_code',
          'issue_workspace_credits'
        )
        """
      )
    )
  end

  def down do
    drop(constraint(:comma_admin_audit_events, @constraint))

    create(
      constraint(:comma_admin_audit_events, @constraint,
        check: """
        action IN (
          'create_user',
          'update_user',
          'set_admin_access',
          'create_support_session',
          'bootstrap_workspace',
          'revoke_user_session',
          'revoke_all_user_sessions',
          'create_redeem_code',
          'disable_redeem_code',
          'apply_redeem_code'
        )
        """
      )
    )
  end
end
