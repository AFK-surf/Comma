defmodule Comma.Repo.Migrations.CreateCommaTaskCollaborators do
  use Ecto.Migration

  # A Task Collaborator is one person a Collaborative Task was started with:
  # the host (the Workspace owner) invited them, and they may read and write
  # that one Task while `active`. The rows of a Task are made when it starts
  # and never added to afterwards; a row only moves from `invited` to
  # `active` or `declined`, and from `active` to `left` or `removed`.
  def change do
    create table(:comma_task_collaborators, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:group_id, :text, null: false)
      add(:conversation_id, :text, null: false)
      add(:title, :text, null: false)

      add(:host_user_id, references(:comma_users, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:comma_users, type: :string, on_delete: :delete_all), null: false)

      add(:status, :text, null: false)
      add(:decided_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_task_collaborators, [:conversation_id, :user_id]))
    create(index(:comma_task_collaborators, [:user_id, :status]))
    create(index(:comma_task_collaborators, [:workspace_id, :conversation_id]))

    create(
      constraint(:comma_task_collaborators, :comma_task_collaborators_status_check,
        check: "status IN ('invited', 'active', 'declined', 'left', 'removed')"
      )
    )

    create(
      constraint(:comma_task_collaborators, :comma_task_collaborators_not_host_check,
        check: "user_id <> host_user_id"
      )
    )
  end
end
