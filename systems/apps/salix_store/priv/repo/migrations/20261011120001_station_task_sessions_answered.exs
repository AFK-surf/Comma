defmodule SalixStore.Repo.Migrations.StationTaskSessionsAnswered do
  use Ecto.Migration

  # Through which Message a station's Sessions answered a Task already
  # (`answered`): the seq the station had been given the Task through when one
  # of them last ended a turn, kept as its posts arrive and told to the station
  # with all that it is given (systems/station/docs/tasks.md). Expand-only: a
  # nullable column; a row from before it has none until the Task is read for
  # it once.
  def change do
    alter table(:station_task_sessions) do
      add(:answered, :bigint)
    end
  end
end
