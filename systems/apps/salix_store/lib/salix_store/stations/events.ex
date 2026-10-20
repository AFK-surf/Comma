defmodule SalixStore.Stations.Events do
  @moduledoc """
  Cluster-wide station change notifications over Phoenix.PubSub, for whoever
  changed the roster (`SalixStore.Stations`) to tell the node that holds a
  station's presence socket. A Group is the workspace, so the roster and
  presence topics are per Group id. Messages carry no authority: presence
  sockets and SSE streams re-read the owner rows they need. Revocation frames
  carry their own `{kind, id, at}`, which is the committed fact.

  The PubSub server is this application's own (`SalixStore.Stations.PubSub`,
  started by `SalixStore.Application`): whoever can write the roster depends
  on `:salix_store`, so every node that writes it runs the server, whichever
  subsystems the node serves, and a notification published on any of them
  reaches the node that holds the socket. A node with no such server cannot
  write the roster either; publishing there raises.
  """

  @pubsub SalixStore.Stations.PubSub

  def station_topic(station_id), do: "comma_station:" <> station_id
  def group_topic(group_id), do: "comma_station_ws:" <> group_id
  def presence_topic(group_id), do: "comma_station_presence:" <> group_id
  def keys_topic, do: "comma_station_keys"

  def subscribe(topic), do: Phoenix.PubSub.subscribe(pubsub(), topic)
  def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(pubsub(), topic)

  @doc "A station's own row changed (renamed, moved, re-enrolled): its socket re-reads it."
  def station_changed(station_id),
    do: broadcast(station_topic(station_id), {:comma_station, :changed})

  @doc "A station was removed: its socket closes with 4004."
  def station_removed(station_id),
    do: broadcast(station_topic(station_id), {:comma_station, :removed})

  @doc "A newer presence socket of the station took over: older ones close."
  def station_replaced(station_id, pid),
    do: broadcast(station_topic(station_id), {:comma_station, :replaced, pid})

  @doc "A Group's roster changed: its stations get new state, clients refetch."
  def roster_changed(group_id),
    do: broadcast(group_topic(group_id), {:comma_station_ws, :roster})

  @doc "A committed revocation of the Group: its stations get a `revoke` frame."
  def revoked(group_id, revocation),
    do: broadcast(group_topic(group_id), {:comma_station_ws, :revoke, revocation})

  @doc "Tells what `SalixStore.Stations.Revocations.revoke/4` answered, once it is committed."
  def publish(revocations) do
    Enum.each(revocations, fn {{_tenant_id, group_id}, revocation} ->
      revoked(group_id, revocation)
    end)
  end

  def keys_changed, do: broadcast(keys_topic(), {:comma_station_keys, :changed})

  @doc "A device tool call for the station's presence socket (`CommaWeb.StationTools`)."
  def tool_request(station_id, message), do: broadcast(station_topic(station_id), message)

  @doc "Node-local: the presence tracker reports a join or leave seen by this node."
  def presence_changed(group_id, station_id) do
    Phoenix.PubSub.local_broadcast(
      @pubsub,
      presence_topic(group_id),
      {:comma_station_presence, station_id}
    )
  end

  @doc """
  Node-local: where a station of the Group may be reached changed (its
  presence socket said so, or went): the Group's sockets re-send `peers`.
  """
  def reach_changed(group_id) do
    Phoenix.PubSub.local_broadcast(@pubsub, group_topic(group_id), {:comma_station_ws, :reach})
  end

  defp broadcast(topic, message), do: Phoenix.PubSub.broadcast(@pubsub, topic, message)

  @doc "The PubSub server stations are told through."
  def pubsub, do: @pubsub
end
