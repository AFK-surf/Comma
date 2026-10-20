defmodule CommaWeb.StationPresence do
  @moduledoc """
  Which stations hold a presence socket anywhere in the cluster (contract §3:
  online = an open presence socket on any node). Each socket process tracks
  itself under its Group; Phoenix.Tracker replicates the set across nodes
  and drops entries of a node that goes away. Diffs are re-published
  node-locally so SSE streams re-read the station they name.
  """
  use Phoenix.Tracker

  alias SalixStore.Stations.Events

  def start_link(opts) do
    # The tracker replicates between the nodes that serve stations, over this
    # application's own PubSub; what it sees is told through `Events`.
    pubsub = SystemsRuntime.get_env(:comma_core, :pubsub_server, CommaWeb.PubSub)
    opts = Keyword.merge([name: __MODULE__, pubsub_server: pubsub], opts)
    Phoenix.Tracker.start_link(__MODULE__, opts, opts)
  end

  def track(pid, group_id, station_id, meta),
    do: Phoenix.Tracker.track(__MODULE__, pid, topic(group_id), station_id, meta)

  def untrack(pid, group_id, station_id),
    do: Phoenix.Tracker.untrack(__MODULE__, pid, topic(group_id), station_id)

  def update(pid, group_id, station_id, meta),
    do: Phoenix.Tracker.update(__MODULE__, pid, topic(group_id), station_id, meta)

  @doc """
  Where the online stations of a Group may be reached, by station id: the
  `reach` of their sockets (`%{"home_relay" => url, "addrs" => ["ip:port"]}`,
  each key only when known). A station with no socket, or whose socket said
  nothing, is absent. Of two sockets of one station, the newer one's.
  """
  def reach(group_id) do
    __MODULE__
    |> Phoenix.Tracker.list(topic(group_id))
    |> Enum.sort_by(fn {_station_id, meta} -> Map.get(meta, :at, 0) end)
    |> Enum.reduce(%{}, fn
      {station_id, %{reach: reach}}, acc when is_map(reach) -> Map.put(acc, station_id, reach)
      _entry, acc -> acc
    end)
  catch
    :exit, _ -> %{}
  end

  @doc "Each entry (a map with `\"id\"`) with where its station may be reached, if known."
  def with_reach(entries, reach) when is_map(reach),
    do: Enum.map(entries, &Map.merge(&1, Map.get(reach, &1["id"], %{})))

  @doc """
  Station ids with an open presence socket in a Group. While servers of the
  release before run (`Comma.Stations.Window`), their sockets count too:
  they track under the Group's Comma Workspace id, in this same tracker.
  """
  def online(group_id) do
    case Comma.Stations.Window.workspace_id(group_id) do
      nil -> tracked(group_id)
      workspace_id -> MapSet.union(tracked(group_id), tracked(workspace_id))
    end
  end

  @doc """
  Whether the station's only socket is on a server of the release before,
  which hears Comma's PubSub and not Salix's (`CommaWeb.StationTools`). False
  once none runs.
  """
  def on_earlier_server?(station_id) do
    with true <- Comma.Stations.Window.open?(),
         {:ok, station} <- Comma.Stations.active_station(station_id),
         workspace_id when is_binary(workspace_id) <-
           Comma.Stations.Window.workspace_id(station.group_id) do
      MapSet.member?(tracked(workspace_id), station_id) and
        not MapSet.member?(tracked(station.group_id), station_id)
    else
      _ -> false
    end
  end

  defp tracked(key) do
    __MODULE__
    |> Phoenix.Tracker.list(topic(key))
    |> MapSet.new(fn {station_id, _meta} -> station_id end)
  catch
    :exit, _ -> MapSet.new()
  end

  def online?(group_id, station_id), do: MapSet.member?(online(group_id), station_id)

  @impl true
  def init(opts), do: {:ok, %{pubsub_server: Keyword.fetch!(opts, :pubsub_server)}}

  @impl true
  def handle_diff(diff, state) do
    for {"comma_stations:" <> group_id, {joins, leaves}} <- diff do
      for station_id <- Enum.uniq(Enum.map(joins ++ leaves, &elem(&1, 0))),
          do: Events.presence_changed(group_id, station_id)

      # A socket that went, came or said anew where its station is: the
      # Group's stations are told their peers again. A newer socket replacing
      # an older one with the same hints changes nothing.
      if reached(joins) != reached(leaves), do: Events.reach_changed(group_id)
    end

    {:ok, state}
  end

  defp reached(entries) do
    for {station_id, %{reach: reach}} when is_map(reach) <- entries,
        into: %{},
        do: {station_id, reach}
  end

  defp topic(group_id), do: "comma_stations:" <> group_id
end
