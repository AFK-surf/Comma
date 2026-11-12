defmodule SalixStore.Repo.Migrations.CreateSalixStillfailStations do
  use Ecto.Migration

  # A still.fail station connected to a Group through a Comma connect (a
  # device of `device_kind` `stillfail`): how much of the Stats index it sends
  # Salix holds. Expand-only: a new table, which old runtimes ignore.
  def change do
    create table(:salix_stillfail_stations, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:device_id, :text, null: false)
      add(:stats_epoch, :text)
      add(:stats_through, :bigint)
      add(:index_epoch, :text)
      add(:index_through, :bigint)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:salix_stillfail_stations, [:group_id]))
  end
end
