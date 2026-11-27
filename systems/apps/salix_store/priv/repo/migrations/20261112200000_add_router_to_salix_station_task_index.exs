defmodule SalixStore.Repo.Migrations.AddRouterToSalixStationTaskIndex do
  use Ecto.Migration

  # Whether Comma's Router wrote a message in a still.fail chat, as the
  # still.fail station sends it in the Task index; members' clients list a
  # still.fail chat only when it did. Expand-only: a column with a constant
  # default (no table rewrite) that old runtimes ignore; no backfill (a row
  # from before reads false, as its station sent none).
  def change do
    alter table(:salix_station_task_index) do
      add(:router, :boolean, null: false, default: false)
    end
  end
end
