defmodule Comma.Repo.Migrations.AddTaskRequestReceipts do
  use Ecto.Migration

  # What an accepted request's Task last told its sender: its status, the
  # words of its latest Agent Message, and when. A request sent from the
  # sender's Router chat (or the New task window of a Workspace) names that
  # Group, whose Router is told the result. The Task status observer finds a
  # request by its Task.
  def change do
    alter table(:comma_task_requests) do
      add(:task_status, :text)
      add(:task_reply, :text)
      add(:task_updated_at, :utc_datetime_usec)
      add(:sender_group_id, :text)
    end

    create(
      index(:comma_task_requests, [:group_id, :task_id],
        where: "task_id IS NOT NULL",
        name: :comma_task_requests_task_index
      )
    )
  end
end
