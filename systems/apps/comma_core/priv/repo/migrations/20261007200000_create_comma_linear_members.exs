defmodule Comma.Repo.Migrations.CreateCommaLinearMembers do
  use Ecto.Migration

  # A Linear installation becomes the organization's, held by the Workspace
  # that installed it. Each person links their own Linear user to their
  # Workspace; the Worker choice and completion policy move to that link, and
  # a session routes to the Workspace of the Linear user who created it.
  def up do
    create table(:comma_linear_members, primary_key: false) do
      add(:id, :text, primary_key: true)

      add(
        :installation_id,
        references(:comma_linear_installations, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:comma_users, type: :string, on_delete: :delete_all), null: false)
      add(:linear_user_id, :text, null: false)
      add(:linear_user_name, :text)
      add(:linear_user_email, :text)
      add(:worker_agent_id, :text)
      add(:completion_state_policy, :text, null: false, default: "unchanged")
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_linear_members, [:workspace_id]))
    create(unique_index(:comma_linear_members, [:installation_id, :linear_user_id]))

    create(
      constraint(:comma_linear_members, :comma_linear_members_policy_valid,
        check: "completion_state_policy in ('unchanged', 'in_review', 'done')"
      )
    )

    drop(unique_index(:comma_linear_installations, [:workspace_id]))
    create(index(:comma_linear_installations, [:workspace_id]))
    drop(constraint(:comma_linear_installations, :comma_linear_installations_policy_valid))

    alter table(:comma_linear_installations) do
      remove(:worker_agent_id)
      remove(:completion_state_policy)
    end

    # The link step learns the Linear user; the chained install step carries
    # that identity so the installer is linked with the installation.
    alter table(:comma_linear_install_attempts) do
      add(:kind, :text, null: false, default: "link")
      add(:linear_organization_id, :text)
      add(:linear_user_id, :text)
      add(:linear_user_name, :text)
      add(:linear_user_email, :text)
    end

    alter table(:comma_linear_agent_sessions) do
      add(:member_id, references(:comma_linear_members, type: :text, on_delete: :nilify_all))
      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all))
    end

    execute("""
    UPDATE comma_linear_agent_sessions AS s
    SET workspace_id = i.workspace_id
    FROM comma_linear_installations AS i
    WHERE s.installation_id = i.id AND s.workspace_id IS NULL
    """)

    alter table(:comma_linear_agent_sessions) do
      modify(:workspace_id, :string, null: false)
    end

    create(index(:comma_linear_agent_sessions, [:member_id]))
  end

  def down do
    alter table(:comma_linear_agent_sessions) do
      remove(:member_id)
      remove(:workspace_id)
    end

    alter table(:comma_linear_install_attempts) do
      remove(:kind)
      remove(:linear_organization_id)
      remove(:linear_user_id)
      remove(:linear_user_name)
      remove(:linear_user_email)
    end

    alter table(:comma_linear_installations) do
      add(:worker_agent_id, :text)
      add(:completion_state_policy, :text, null: false, default: "unchanged")
    end

    create(
      constraint(:comma_linear_installations, :comma_linear_installations_policy_valid,
        check: "completion_state_policy in ('unchanged', 'in_review', 'done')"
      )
    )

    drop(index(:comma_linear_installations, [:workspace_id]))
    create(unique_index(:comma_linear_installations, [:workspace_id]))

    drop(table(:comma_linear_members))
  end
end
