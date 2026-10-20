defmodule Comma.Repo.Migrations.CreateCommaTaskPanelDismissals do
  use Ecto.Migration

  # The settled Tasks a person cleared out of the chat Task panel, each with
  # the Task version they acknowledged. They belong to the person, so every
  # device and client shows the same panel.
  def change do
    create table(:comma_task_panel_dismissals, primary_key: false) do
      add(:user_id, references(:comma_users, type: :string, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:task_id, :text, null: false, primary_key: true)
      add(:revision, :bigint, null: false)
      add(:dismissed_at, :utc_datetime_usec, null: false)
    end

    create(index(:comma_task_panel_dismissals, [:user_id, :dismissed_at]))
  end
end
