defmodule SalixStore.Repo.Migrations.CreateSalixStationWorkspaces do
  use Ecto.Migration

  # The workspace id a Group's stations and member credentials are told
  # (`SalixStore.Stations.Workspaces`), for a Group told another id than its
  # own, and the ids it was told before. A Group with no row is told its
  # Group id. Expand-only: a new table; Comma migration 20261011100001 writes
  # the Groups whose stations hold a Comma Workspace id.
  def change do
    create table(:salix_station_workspaces, primary_key: false) do
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, primary_key: true)
      add(:workspace_id, :text, null: false)
      add(:previous_ids, {:array, :text}, null: false, default: [])

      timestamps(type: :utc_datetime_usec)
    end

    # An id names one Group's workspace.
    create(unique_index(:salix_station_workspaces, [:workspace_id]))
  end
end
