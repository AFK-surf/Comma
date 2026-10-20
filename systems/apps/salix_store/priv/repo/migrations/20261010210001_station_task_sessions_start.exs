defmodule SalixStore.Repo.Migrations.StationTaskSessionsStart do
  use Ecto.Migration

  # What each station's Session was invited to a Task with (`start`), so a
  # station that lost the Task is invited again as it was first
  # (systems/station/docs/tasks.md). Expand-only: a nullable column; rows from
  # before it rebuild `start` from the Task's Worker.
  def change do
    alter table(:station_task_sessions) do
      add(:start, :map)
    end
  end
end
