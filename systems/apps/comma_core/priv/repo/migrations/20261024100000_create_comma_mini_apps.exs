defmodule Comma.Repo.Migrations.CreateCommaMiniApps do
  use Ecto.Migration

  @audit_actions ~w(create_user update_user set_admin_access create_support_session bootstrap_workspace update_workspace_vm revoke_user_session revoke_all_user_sessions create_redeem_code disable_redeem_code apply_redeem_code issue_workspace_credits create_oauth_client rotate_oauth_client_secret disable_oauth_client enable_oauth_client retry_agent_vmm_install enable_agent_vmm_registration disable_agent_vmm_registration revoke_agent_vmm_registration drain_compute_environment revoke_compute_environment create_shell_workload update_workspace_agent_model update_free_router_models update_model_selection_policy update_guest_policy create_guest_tenant disable_mini_app enable_mini_app)

  def up do
    execute("SET LOCAL lock_timeout TO '5s'")

    create table(:comma_mini_apps, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:slug, :text, null: false)

      # Restrict: a Workspace's apps go through Comma.MiniApps.delete_workspace_apps/1
      # first, so their Workers for Platforms scripts and objects are removed too.
      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :restrict),
        null: false
      )

      add(:group_id, :text, null: false)
      add(:created_by, references(:comma_users, type: :string, on_delete: :nilify_all))
      add(:name, :text, null: false)
      add(:description, :text, null: false, default: "")
      add(:repo_owner, :text, null: false)
      add(:repo_name, :text, null: false)
      add(:visibility, :text, null: false, default: "private")
      add(:status, :text, null: false, default: "active")
      add(:disabled_by, :text)
      add(:live_version_id, :binary_id)
      add(:next_version, :integer, null: false, default: 1)
      add(:grants, {:array, :text}, null: false, default: [])
      add(:secrets, :map, null: false, default: %{})
      add(:data_script, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_mini_apps, [:slug]))
    create(index(:comma_mini_apps, [:workspace_id, :updated_at]))
    create(index(:comma_mini_apps, [:status], where: "status = 'deleted'"))

    create(
      constraint(:comma_mini_apps, :comma_mini_apps_visibility_check,
        check: "visibility IN ('private', 'workspace', 'link')"
      )
    )

    create(
      constraint(:comma_mini_apps, :comma_mini_apps_status_check,
        check: "status IN ('active', 'disabled', 'deleted')"
      )
    )

    create(
      constraint(:comma_mini_apps, :comma_mini_apps_slug_check, check: "slug ~ '^[a-z0-9]{8}$'")
    )

    create table(:comma_mini_app_versions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:app_id, references(:comma_mini_apps, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:number, :integer, null: false)
      add(:state, :text, null: false, default: "uploading")
      add(:deploy_key, :text, null: false)
      add(:commit, :text, null: false)
      add(:digest, :text)
      add(:manifest, :map, null: false, default: %{})
      add(:script_name, :text)
      add(:bundle_size, :bigint, null: false, default: 0)
      add(:conversation_id, :text)
      add(:message_seq, :bigint)
      add(:notes, :text)
      add(:error, :text)
      add(:failed_at, :utc_datetime_usec)
      add(:blobs_deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_mini_app_versions, [:app_id, :number]))
    create(unique_index(:comma_mini_app_versions, [:app_id, :deploy_key]))
    create(index(:comma_mini_app_versions, [:app_id, :commit]))
    create(index(:comma_mini_app_versions, [:failed_at], where: "state = 'failed'"))

    create(
      constraint(:comma_mini_app_versions, :comma_mini_app_versions_state_check,
        check: "state IN ('uploading', 'ready', 'failed')"
      )
    )

    alter table(:comma_mini_apps) do
      modify(
        :live_version_id,
        references(:comma_mini_app_versions, type: :binary_id, on_delete: :nilify_all)
      )
    end

    create table(:comma_mini_app_links, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:app_id, references(:comma_mini_apps, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:token, :text, null: false)
      add(:created_by, references(:comma_users, type: :string, on_delete: :nilify_all))
      add(:revoked_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_mini_app_links, [:token]))

    create(
      unique_index(:comma_mini_app_links, [:app_id],
        where: "revoked_at IS NULL",
        name: :comma_mini_app_links_active_app_index
      )
    )

    create table(:comma_mini_app_installs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:app_id, references(:comma_mini_apps, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:installed_by, references(:comma_users, type: :string, on_delete: :nilify_all))
      add(:pinned_version, :integer)
      add(:grants, {:array, :text}, null: false, default: [])
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_mini_app_installs, [:app_id, :workspace_id]))
    create(index(:comma_mini_app_installs, [:workspace_id]))

    drop(constraint(:comma_admin_audit_events, :comma_admin_audit_action_valid))

    create(
      constraint(:comma_admin_audit_events, :comma_admin_audit_action_valid,
        check: "action IN (#{Enum.map_join(@audit_actions, ",", &"'#{&1}'")})"
      )
    )
  end

  def down do
    raise "Preserve Mini Apps and audit history. Use a forward migration."
  end
end
