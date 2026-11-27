defmodule Comma.Repo.Migrations.SharedTasksPhase2 do
  use Ecto.Migration

  # Shared Tasks Phase 2:
  # - Direct external email guest invites (7-day token, expiry, optional guest display name)
  # - Guest sessions (`comma_collaboration_guest_sessions`) bound to a single Task
  # - Invite send log (`comma_collaboration_invite_sends`) for the 20/24h host cap (initial + resends)
  # - Mini App association to a collaborative Task (`comma_mini_apps.collaboration_conversation_id`)
  def change do
    alter table(:comma_task_collaborators) do
      add(:invite_token, :text)
      add(:invite_expires_at, :utc_datetime_usec)
      add(:guest_name, :text)
    end

    create(
      unique_index(:comma_task_collaborators, [:invite_token],
        where: "invite_token IS NOT NULL",
        name: :comma_task_collaborators_invite_token_index
      )
    )

    create(index(:comma_task_collaborators, [:host_user_id, :inserted_at]))
    create(index(:comma_task_collaborators, [:workspace_id, :group_id]))
    create(index(:comma_task_collaborators, [:group_id, :host_user_id]))

    create table(:comma_collaboration_guest_sessions, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(
        :collaborator_id,
        references(:comma_task_collaborators, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:group_id, :text, null: false)
      add(:conversation_id, :text, null: false)
      add(:email, :text, null: false)
      add(:token_hash, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:revoked_at, :utc_datetime_usec)
      add(:last_used_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_collaboration_guest_sessions, [:token_hash]))
    create(index(:comma_collaboration_guest_sessions, [:collaborator_id]))
    create(index(:comma_collaboration_guest_sessions, [:group_id, :conversation_id]))

    create table(:comma_collaboration_invite_sends, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(:host_user_id, references(:comma_users, type: :string, on_delete: :delete_all),
        null: false
      )

      add(
        :collaborator_id,
        references(:comma_task_collaborators, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:comma_collaboration_invite_sends, [:host_user_id, :inserted_at]))

    alter table(:comma_mini_apps) do
      add(:collaboration_conversation_id, :text)
    end

    create(index(:comma_mini_apps, [:group_id, :collaboration_conversation_id]))

    execute(
      "ALTER TABLE comma_mini_apps DROP CONSTRAINT comma_mini_apps_visibility_check",
      "ALTER TABLE comma_mini_apps ADD CONSTRAINT comma_mini_apps_visibility_check CHECK (visibility IN ('private', 'workspace', 'link'))"
    )

    execute(
      "ALTER TABLE comma_mini_apps ADD CONSTRAINT comma_mini_apps_visibility_check CHECK (visibility IN ('private', 'workspace', 'link', 'collaboration'))",
      "ALTER TABLE comma_mini_apps DROP CONSTRAINT comma_mini_apps_visibility_check"
    )
  end
end
