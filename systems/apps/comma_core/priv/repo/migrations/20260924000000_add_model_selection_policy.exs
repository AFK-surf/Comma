defmodule Comma.Repo.Migrations.AddModelSelectionPolicy do
  use Ecto.Migration

  def up do
    create table(:comma_model_selection_policy, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:mode, :text, null: false, default: "all")
      add(:allowed_template_ids, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:revision, :bigint, null: false, default: 0)
    end

    create(
      constraint(:comma_model_selection_policy, :comma_model_selection_policy_singleton,
        check: "id = 1"
      )
    )

    create(
      constraint(:comma_model_selection_policy, :comma_model_selection_policy_mode,
        check: "mode IN ('all', 'selected')"
      )
    )

    create(
      constraint(:comma_model_selection_policy, :comma_model_selection_policy_ids_bound,
        check:
          "jsonb_typeof(allowed_template_ids) = 'array' AND jsonb_array_length(allowed_template_ids) <= 100"
      )
    )

    execute("INSERT INTO comma_model_selection_policy (id) VALUES (1)")
    execute("SET LOCAL lock_timeout TO '5s'")
    drop(constraint(:comma_admin_audit_events, :comma_admin_audit_action_valid))

    create(
      constraint(:comma_admin_audit_events, :comma_admin_audit_action_valid,
        check:
          "action IN ('create_user','update_user','set_admin_access','create_support_session','bootstrap_workspace','update_workspace_vm','revoke_user_session','revoke_all_user_sessions','create_redeem_code','disable_redeem_code','apply_redeem_code','issue_workspace_credits','create_oauth_client','rotate_oauth_client_secret','disable_oauth_client','enable_oauth_client','retry_agent_vmm_install','enable_agent_vmm_registration','disable_agent_vmm_registration','revoke_agent_vmm_registration','drain_compute_environment','revoke_compute_environment','create_shell_workload','update_workspace_agent_model','update_free_router_models','update_model_selection_policy')"
      )
    )
  end

  def down do
    raise "Preserve model selection policy and audit history. Use a forward migration."
  end
end
