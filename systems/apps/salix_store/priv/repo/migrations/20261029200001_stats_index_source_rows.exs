defmodule SalixStore.Repo.Migrations.StatsIndexSourceRows do
  use Ecto.Migration

  # A Stats index row may also say how an outside source stands on its station
  # (`kind` source: being asked, granted, refused, revoked, failed). Expand-only:
  # the check widens; a runtime from before never sends such a row.
  def change do
    drop(constraint(:salix_station_stats_index, :salix_station_stats_index_kind_valid))

    create(
      constraint(:salix_station_stats_index, :salix_station_stats_index_kind_valid,
        check: "kind in ('usage', 'task', 'source')"
      )
    )
  end
end
