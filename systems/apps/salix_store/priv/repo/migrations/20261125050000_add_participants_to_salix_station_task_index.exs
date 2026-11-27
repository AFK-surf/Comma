defmodule SalixStore.Repo.Migrations.AddParticipantsToSalixStationTaskIndex do
  use Ecto.Migration

  # Emails of people who participated in a still.fail chat, as its station
  # reports them in the Task index. Expand-only: non-null array defaulting to
  # empty so older stations and existing rows work without backfill.
  def change do
    alter table(:salix_station_task_index) do
      add(:participants, {:array, :text}, default: [], null: false)
    end
  end
end
