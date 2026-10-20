defmodule SalixStore.Repo.Migrations.CreateSalixStationTaskIndex do
  use Ecto.Migration

  # The Task index stations send over their Connector (`SalixStore.StationTaskIndex`):
  # one row per station-hosted Task (a station's page chat), no message text.
  # Expand-only: a new table and two nullable columns, which old runtimes ignore.
  def change do
    create table(:salix_station_task_index, primary_key: false) do
      add(:station_id, :text, primary_key: true)
      add(:thread, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:device_id, :text)
      add(:task, :text, null: false)
      add(:title, :text, null: false)
      add(:status, :text, null: false)
      add(:created_by, :text)
      add(:created_at, :bigint, null: false)
      add(:last_activity_at, :bigint, null: false)
      add(:runtime, :text)
      add(:model, :text)
      add(:rev, :bigint, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:salix_station_task_index, :salix_station_task_index_status_valid,
        check: "status in ('in_progress', 'needs_review', 'done', 'cancelled', 'archived')"
      )
    )

    create(
      index(:salix_station_task_index, [:group_id, :status, "last_activity_at DESC"],
        name: :salix_station_task_index_group_status
      )
    )

    # The index generation the station last sent (`epoch`) and the highest
    # row revision Salix holds of it (`through`).
    alter table(:salix_stations) do
      add(:index_epoch, :text)
      add(:index_through, :bigint)
    end
  end
end
