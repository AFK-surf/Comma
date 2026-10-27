defmodule SalixWeb.StationPlace do
  @moduledoc """
  Salix admits a Group Workload's Station to the Group roster without an
  enrollment token. The authenticated connector run supplies the Station key
  through `station_identity`.

  Local roster admission and the exact Workload's remembered key commit
  together. The key records control-plane admission, not a peer ACK or proof
  that the Station is online. After commit, the control plane publishes the
  roster change and sends `station_place` to the same run. A lost ACK keeps
  the admitted key, so a new generation replaces only its own previous key.
  Coding Task Workloads retain their separate lifecycle and do not join the
  Group roster.

  Without a configured control plane nothing is placed. A Station too old to
  answer `station_identity` is left as it is.
  """

  require Logger

  alias SalixEnv.{Connector.Live, StationConnection}
  alias SalixStore.{ComputeStation, Repo}

  @timeout 20_000

  @doc """
  Prepares local roster admission without publishing notifications. The
  returned admission includes `place`, the `station_place` parameters, and
  the facts the control plane needs to publish after the owner commits.
  """
  @callback prepare(
              tenant_id :: String.t(),
              group_id :: String.t(),
              station_id :: String.t(),
              previous_station_id :: String.t() | nil,
              version :: String.t() | nil
            ) ::
              {:ok, %{required(:place) => map(), optional(atom()) => term()}} | {:error, term()}

  @callback publish(admission :: map()) :: :ok

  @doc "Places the Station behind a current managed connector run; never raises."
  def push(%{tenant_id: tenant, group_id: group, connector_run_id: run} = connection) do
    case SystemsRuntime.get_env(:salix_web, :station_control_plane) do
      nil -> :none
      control_plane -> place(control_plane, tenant, group, run, connection)
    end
  rescue
    _ ->
      Logger.warning("station not placed: local admission failed")
      {:error, :station_place_failed}
  end

  defp place(control_plane, tenant, group, run, connection) do
    with {:ok, %{"station" => station} = identity} when is_binary(station) <- identify(run),
         {:ok, admission} <-
           StationConnection.with_current(
             connection,
             fn
               %{"owner" => owner} = record when owner in ["group_default", "group_station"] ->
                 prepare(
                   control_plane,
                   tenant,
                   group,
                   station,
                   record["station_id"],
                   identity["version"],
                   connection
                 )

               _ ->
                 :none
             end,
             lock: true
           ),
         :ok <- control_plane.publish(admission),
         {:ok, %{"placed" => true}} <-
           Live.request(run, "station_place", admission.place, timeout: @timeout) do
      :ok
    else
      :none ->
        :none

      {:error, :old_station} ->
        Logger.info("station not placed: run=#{run} the station does not answer station_identity")
        :none

      {:error, reason} ->
        Logger.warning("station not placed: run=#{run} #{inspect(reason)}")
        {:error, reason}

      _ ->
        Logger.warning("station not placed: run=#{run} invalid reply")
        {:error, :invalid_station_reply}
    end
  end

  defp prepare(control_plane, tenant, group, station, previous, version, connection) do
    with {:ok, admission} <- control_plane.prepare(tenant, group, station, previous, version),
         {:ok, :ok} <- ComputeStation.remember(connection, station) do
      {:ok, admission}
    else
      {:error, reason} -> Repo.rollback(reason)
      _ -> Repo.rollback(:station_place_failed)
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
end
