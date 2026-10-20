defmodule SalixStore.Repo.Migrations.CreateStationTaskSessions do
  use Ecto.Migration

  # The Sessions of other stations taking part in a Task Salix keeps, and the
  # Message seq through which each was given the Task (`sent`), as a station
  # keeps its `task_sessions` (systems/station/docs/tasks.md). Expand-only: a
  # new table.
  def change do
    create table(:station_task_sessions, primary_key: false) do
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false, primary_key: true)
      add(:conversation_id, :text, null: false, primary_key: true)
      add(:device_id, :text, null: false, primary_key: true)
      add(:session, :text, null: false, primary_key: true)
      add(:agent_id, :text, null: false)
      add(:sent, :bigint, null: false, default: 0)
      add(:joined_at, :bigint, null: false)
    end

    create(
      index(:station_task_sessions, [:tenant_id, :group_id, :device_id],
        name: :station_task_sessions_device_index
      )
    )
  end
end
