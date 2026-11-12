defmodule SalixWeb.StationStatsIndex do
  @moduledoc """
  A station's `stats.index` request on its Connector run: a page of the Stats
  index it keeps (`SalixStore.StationStatsIndex`), as `task.index` is a page of
  its Task index (`SalixWeb.StationTaskIndex`, whose admission and rate it
  shares). Salix answers what it holds afterwards, `{"epoch", "through"}`.

  A Comma station is the one its run proved with `relay_register`. A run of a
  still.fail device (`device_kind` `stillfail`, made by the still.fail
  plugin) proves none: its pages are that device's
  (`SalixStore.StillfailStations`).
  """

  alias SalixEnv.{StationConnection, StillfailDevices}
  alias SalixStore.{StationStatsIndex, Stations}

  @doc """
  Applies a page from the authenticated connection `view`, whose relay
  registration proved `station_id`, while the run is current.
  """
  def receive_page(station_id, view, params) do
    StationConnection.with_current(view, fn _record -> apply_page(station_id, view, params) end,
      lock: true
    )
  end

  defp apply_page(nil, view, params) do
    with {:ok, station} <- StillfailDevices.station(view) do
      case StationStatsIndex.apply_page(station, view.device_id, params) do
        {:error, :station_removed} -> {:error, :not_this_group}
        result -> result
      end
    end
  end

  defp apply_page(station_id, view, params) do
    with true <- is_binary(station_id) || {:error, :not_this_group},
         {:ok, station} <- Stations.active_station(station_id),
         true <-
           {station.tenant_id, station.group_id} == {view.tenant_id, view.group_id} ||
             {:error, :not_this_group} do
      case StationStatsIndex.apply_page(station, view.device_id, params) do
        {:error, :station_removed} -> {:error, :not_this_group}
        result -> result
      end
    else
      {:error, :station_removed} -> {:error, :not_this_group}
      {:error, _reason} = error -> error
    end
  end
end
