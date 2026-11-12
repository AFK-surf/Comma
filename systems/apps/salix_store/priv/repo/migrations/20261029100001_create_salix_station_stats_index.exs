defmodule SalixStore.Repo.Migrations.CreateSalixStationStatsIndex do
  use Ecto.Migration

  # The Stats index stations send over their Connector (`SalixStore.StationStatsIndex`):
  # each station's statistics in one structure, its own (`source` self) and those
  # of outside sources it brings in (still.fail on the same machine). Expand-only:
  # a new table and two nullable columns, which old runtimes ignore.
  def change do
    create table(:salix_station_stats_index, primary_key: false) do
      add(:station_id, :text, primary_key: true)
      add(:key, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:device_id, :text)
      add(:source, :text, null: false)
      add(:kind, :text, null: false)
      add(:day, :text)
      add(:person, :text)
      add(:model, :text)
      add(:calls, :bigint, null: false, default: 0)
      add(:input, :bigint, null: false, default: 0)
      add(:cache_read, :bigint, null: false, default: 0)
      add(:cache_write, :bigint, null: false, default: 0)
      add(:output, :bigint, null: false, default: 0)
      add(:cost, :float)
      add(:row, :map, null: false)
      add(:rev, :bigint, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:salix_station_stats_index, :salix_station_stats_index_kind_valid,
        check: "kind in ('usage', 'task')"
      )
    )

    create(
      index(:salix_station_stats_index, [:group_id, :kind, :day],
        name: :salix_station_stats_index_group_kind_day
      )
    )

    # The Stats index generation the station last sent and the highest revision Salix holds of it.
    alter table(:salix_stations) do
      add(:stats_epoch, :text)
      add(:stats_through, :bigint)
    end
  end
end
