defmodule SalixStore.Repo.Migrations.AddLabelsToSalixStationTaskIndex do
  use Ecto.Migration

  # A station-hosted Task's labels, as its station sends them in the Task index
  # (the Group's label ids). Expand-only: a nullable column old runtimes ignore;
  # NULL is no label.
  def change do
    alter table(:salix_station_task_index) do
      add(:labels, {:array, :text})
    end
  end
end
