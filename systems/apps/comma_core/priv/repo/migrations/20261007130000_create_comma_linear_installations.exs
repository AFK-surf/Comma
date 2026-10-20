defmodule Comma.Repo.Migrations.CreateCommaLinearInstallations do
  use Ecto.Migration

  def change do
    # One Linear organization installed Comma as an agent for one Workspace.
    # The OAuth token lives in the Salix OAuth connection store; this row owns
    # the product authorization relationship and its settings.
    create table(:comma_linear_installations, primary_key: false) do
      add(:id, :text, primary_key: true)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:organization_id, :text, null: false)
      add(:organization_name, :text)
      add(:organization_url_key, :text)
      add(:app_user_id, :text, null: false)
      add(:connection_id, :text, null: false)
      add(:worker_agent_id, :text)
      add(:completion_state_policy, :text, null: false, default: "unchanged")
      add(:installed_by_user_id, references(:comma_users, type: :string, on_delete: :nilify_all))
      add(:revoked_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_linear_installations, [:workspace_id]))
    create(unique_index(:comma_linear_installations, [:organization_id]))

    create(
      constraint(:comma_linear_installations, :comma_linear_installations_policy_valid,
        check: "completion_state_policy in ('unchanged', 'in_review', 'done')"
      )
    )

    # A pending OAuth authorization started by a Workspace owner. The state is
    # stored hashed; the callback consumes it once.
    create table(:comma_linear_install_attempts, primary_key: false) do
      add(:state_hash, :text, null: false, primary_key: true)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:owner_user_id, references(:comma_users, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:pkce_verifier, :text, null: false)
      add(:environment, :text)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:comma_linear_install_attempts, [:workspace_id]))
    create(index(:comma_linear_install_attempts, [:expires_at]))

    # Index from a Linear AgentSession to the Task it created. The Task owns
    # the work; this row only routes later prompts and outbound activities.
    create table(:comma_linear_agent_sessions, primary_key: false) do
      add(:agent_session_id, :text, null: false, primary_key: true)

      add(
        :installation_id,
        references(:comma_linear_installations, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:group_id, :text, null: false)
      add(:conversation_id, :text, null: false)
      add(:issue_id, :text)
      add(:issue_identifier, :text)
      add(:issue_url, :text)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:comma_linear_agent_sessions, [:installation_id]))
    create(index(:comma_linear_agent_sessions, [:group_id, :conversation_id]))
  end
end
