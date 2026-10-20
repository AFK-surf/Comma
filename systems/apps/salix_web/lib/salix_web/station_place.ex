defmodule SalixWeb.StationPlace do
  @moduledoc """
  Salix is the stations' control plane, and it creates the station of a
  Group's Cloud VM itself. So it places that station in the Group's station
  roster directly, without an enrollment token, when the VM's connector
  connects: it asks the station for its key (`station_identity`), admits it
  through the configured control plane (`config :salix_web,
  :station_control_plane`), and tells the station where it is placed
  (`station_place`). The Group's Workload record keeps the placed key, so a
  VM that comes back with a new key replaces its previous station.

  Without a configured control plane nothing is placed. A station too old to
  answer `station_identity` is left as it is.
  """

  require Logger

  alias SalixEnv.Connector.Live
  alias SalixStore.Compute

  @timeout 20_000

  @doc """
  Admits `station_id` as the station of `group_id`'s Cloud VM, replacing
  `previous_station_id` when it differs. Answers the `station_place` params.
  Every Group has a station roster, whichever product owns it.
  """
  @callback admit(
              tenant_id :: String.t(),
              group_id :: String.t(),
              station_id :: String.t(),
              previous_station_id :: String.t() | nil,
              version :: String.t() | nil
            ) :: {:ok, map()} | {:error, term()}

  @doc "Places the station behind a managed connector run; never raises."
  def push(%{tenant_id: tenant, group_id: group, connector_run_id: run} = connection) do
    case SystemsRuntime.get_env(:salix_web, :station_control_plane) do
      nil ->
        :none

      control_plane ->
        place(control_plane, tenant, group, run, Map.get(connection, :connector_id))
    end
  end

  defp place(control_plane, tenant, group, run, connector_id) do
    with {:ok, %{"station" => station} = identity} when is_binary(station) <-
           identify(run),
         previous = previous(group),
         {:ok, place} <-
           control_plane.admit(tenant, group, station, previous, identity["version"]),
         {:ok, %{"placed" => true}} <-
           Live.request(run, "station_place", place, timeout: @timeout) do
      if previous == station, do: :ok, else: remember(group, connector_id, station)
    else
      {:error, :old_station} ->
        Logger.info("station not placed: run=#{run} the station does not answer station_identity")
        :none

      other ->
        Logger.warning("station not placed: run=#{run} #{inspect(other)}")
        {:error, other}
    end
  end

  defp identify(run) do
    case Live.request(run, "station_identity", %{}, timeout: @timeout) do
      {:error, reason} when is_binary(reason) ->
        if String.contains?(reason, "unknown method"),
          do: {:error, :old_station},
          else: {:error, reason}

      result ->
        result
    end
  end

  defp previous(group) do
    case Compute.group_workload(group) do
      {:ok, record} -> record["station_id"]
      _ -> nil
    end
  end

  # Only the record of the run that was placed keeps its key.
  defp remember(group, connector_id, station) do
    case Compute.update_group_workload(group, fn record ->
           if connector_id && record["connector_id"] != connector_id,
             do: {:error, :connector_replaced},
             else: Map.put(record, "station_id", station)
         end) do
      {:ok, _current, _previous} ->
        :ok

      error ->
        Logger.warning("placed station not recorded: group=#{group} #{inspect(error)}")
        {:error, error}
    end
  end
end
