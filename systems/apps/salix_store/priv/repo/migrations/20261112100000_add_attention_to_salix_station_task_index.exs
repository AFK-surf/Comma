defmodule SalixStore.Repo.Migrations.AddAttentionToSalixStationTaskIndex do
  use Ecto.Migration

  # What a still.fail station says a chat asks of whom, as it sends it in the
  # Task index: the kind of attention (`need`, `done`, `failed`), the people it
  # waits for, the agent's own one-line note and the chat's link. Expand-only:
  # nullable columns old runtimes ignore; no backfill (a row from before has
  # none, as its station sent none).
  def change do
    alter table(:salix_station_task_index) do
      add(:attention, :text)
      add(:waits_for, {:array, :text}, default: [])
      add(:note, :text)
      add(:url, :text)
    end
  end
end
