defmodule Comma.Repo.Migrations.AddCommaGuestMode do
  use Ecto.Migration

  @audit_actions ~w(create_user update_user set_admin_access create_support_session bootstrap_workspace update_workspace_vm revoke_user_session revoke_all_user_sessions create_redeem_code disable_redeem_code apply_redeem_code issue_workspace_credits create_oauth_client rotate_oauth_client_secret disable_oauth_client enable_oauth_client retry_agent_vmm_install enable_agent_vmm_registration disable_agent_vmm_registration revoke_agent_vmm_registration drain_compute_environment revoke_compute_environment create_shell_workload update_workspace_agent_model update_free_router_models update_model_selection_policy update_guest_policy create_guest_tenant)

  def up do
    execute("SET LOCAL lock_timeout TO '5s'")

    alter table(:comma_users) do
      add(:kind, :text, null: false, default: "registered")
      add(:guest_pow_id, :text)
      add(:guest_claim_hash, :binary)
      add(:guest_claim_expires_at, :utc_datetime_usec)

      add(
        :guest_imported_into_user_id,
        references(:comma_users, type: :text, on_delete: :nilify_all)
      )
    end

    execute("""
    ALTER TABLE comma_users
    ADD CONSTRAINT comma_users_kind_valid CHECK (
      kind IN ('registered', 'guest')
      AND (kind = 'guest') = (normalized_email LIKE '%@guest.comma.invalid')
      AND (kind = 'guest' OR (
        guest_pow_id IS NULL AND guest_claim_hash IS NULL AND guest_claim_expires_at IS NULL
        AND guest_imported_into_user_id IS NULL
      ))
      AND (guest_claim_hash IS NULL) = (guest_claim_expires_at IS NULL)
    ) NOT VALID
    """)

    execute("ALTER TABLE comma_users VALIDATE CONSTRAINT comma_users_kind_valid")

    # One solved proof-of-work challenge creates at most one guest.
    create(
      unique_index(:comma_users, [:guest_pow_id],
        name: :comma_users_guest_pow_id_index,
        where: "guest_pow_id IS NOT NULL"
      )
    )

    create(
      unique_index(:comma_users, [:guest_claim_hash],
        name: :comma_users_guest_claim_hash_index,
        where: "guest_claim_hash IS NOT NULL"
      )
    )

    create(
      index(:comma_users, [:inserted_at],
        name: :comma_users_guest_created_index,
        where: "kind = 'guest'"
      )
    )

    alter table(:comma_workspaces) do
      add(:kind, :text, null: false, default: "standard")
      modify(:salix_worker_agent_id, :string, null: true, from: {:string, null: false})
    end

    execute("""
    ALTER TABLE comma_workspaces
    ADD CONSTRAINT comma_workspaces_kind_valid CHECK (
      kind IN ('standard', 'guest')
      AND (kind = 'guest') = (salix_worker_agent_id IS NULL)
    ) NOT VALID
    """)

    execute("ALTER TABLE comma_workspaces VALIDATE CONSTRAINT comma_workspaces_kind_valid")

    # Guest Workspaces share the dedicated guest Salix Tenant; every other
    # Workspace keeps its own Tenant.
    drop(unique_index(:comma_workspaces, [:salix_tenant_id]))

    create(
      unique_index(:comma_workspaces, [:salix_tenant_id],
        name: :comma_workspaces_salix_tenant_id_index,
        where: "kind = 'standard'"
      )
    )

    drop(constraint(:comma_auth_sessions, :comma_auth_sessions_source_method_valid))

    execute("""
    ALTER TABLE comma_auth_sessions
    ADD CONSTRAINT comma_auth_sessions_source_method_valid CHECK (
      (session_source = 'user_login' AND auth_method IN ('email_otp', 'google', 'ssh_public_key', 'guest')) OR
      (session_source = 'ops_api' AND auth_method IS NULL) OR
      (session_source = 'channel_task_panel' AND auth_method = 'telegram_miniapp')
    ) NOT VALID
    """)

    create table(:comma_guest_policy, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:enabled, :boolean, null: false, default: false)
      add(:salix_tenant_id, :text)
      add(:daily_creation_limit, :integer, null: false, default: 1000)
      add(:tenant_concurrency, :integer, null: false, default: 32)
      add(:session_ttl_seconds, :integer, null: false, default: 604_800)
      add(:pow_difficulty, :integer, null: false, default: 12)
      add(:revision, :bigint, null: false, default: 0)
    end

    execute("""
    ALTER TABLE comma_guest_policy
    ADD CONSTRAINT comma_guest_policy_valid CHECK (
      id = 1
      AND (NOT enabled OR salix_tenant_id IS NOT NULL)
      AND daily_creation_limit BETWEEN 0 AND 100000
      AND tenant_concurrency BETWEEN 1 AND 512
      AND session_ttl_seconds BETWEEN 3600 AND 2592000
      AND pow_difficulty BETWEEN 8 AND 24
      AND revision >= 0
    )
    """)

    execute("INSERT INTO comma_guest_policy (id) VALUES (1)")

    drop(constraint(:comma_admin_audit_events, :comma_admin_audit_action_valid))

    create(
      constraint(:comma_admin_audit_events, :comma_admin_audit_action_valid,
        check: "action IN (#{Enum.map_join(@audit_actions, ",", &"'#{&1}'")})"
      )
    )
  end

  def down do
    raise "Preserve guest accounts, imports and audit history. Use a forward migration."
  end
end
