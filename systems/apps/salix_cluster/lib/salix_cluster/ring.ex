defmodule SalixCluster.Ring do
  @moduledoc """
  Consistent-hash placement ring. A `libring` `HashRing` over the
  connected, visible, ready nodes; `owner/1` names the node that should own the
  agent server. Agent-below-owner resources should only start on that owner node.

  Maintained via `:net_kernel.monitor_nodes/2`: nodes are added/removed as the
  mesh changes. Includes `Node.self()` unless this node is draining while
  another ready node is in the ring.

  A peer enters the ring only once it is ready. A pod connects to the mesh while
  its applications are still starting; placing keys on it then sent requests to
  owners that could not answer yet (a rolling release answered a live
  conversation's events with 404). A node is ready while
  `config :salix_cluster, :placement_ready` is not false: the launcher sets it
  false before it starts the applications and true once they are all up, then
  calls `ready/0`. The ring reads that flag on each peer that connects, and
  `ready/0` tells the connected peers that this node is now ready.

  A draining node leaves the ring the same way (`leave/0`, called by
  `SalixCluster.NodeLifecycle.mark_draining/0`): it sets the flag false, tells
  the connected peers, and places keys without itself while another ready node
  is in the ring. So `SalixCluster.Drain` always finds a different owner to
  hand each agent to, and nothing placed through the ring starts on the
  draining node again before the pod stops. A node alone in its ring keeps
  itself: there is no other owner. The ring reads the flag again when it
  restarts, a peer that connects meanwhile is told, and `ready/0` keeps a
  draining node out. `rejoin/0` reverses it (tests, explicit local recovery).

  `:on_change` is a zero-arity function called after the node set changes,
  and `:on_ready` one called when `ready/0` is. Both run inside the ring
  process, so they must only schedule work.
  """
  use SystemsRuntime.Server

  @name __MODULE__
  @ready_read_timeout_ms 5_000

  def start_link(opts \\ []), do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: @name)

  @doc "Preferred node for an agent id."
  @spec owner(String.t()) :: node()
  def owner(agent_id), do: SystemsRuntime.Server.call(@name, {:owner, agent_id})

  @doc "Nodes currently in the ring."
  @spec nodes() :: [node()]
  def nodes, do: SystemsRuntime.Server.call(@name, :nodes)

  @doc "Tells the connected peers that this node is ready to own keys."
  @spec ready() :: :ok
  def ready, do: SystemsRuntime.Server.call(@name, :ready)

  @doc """
  This node leaves the ring for placement: the connected peers place keys
  elsewhere, and so does this node while another ready node is in its ring.
  """
  @spec leave() :: :ok
  def leave, do: SystemsRuntime.Server.call(@name, :leave)

  @doc "Undoes `leave/0`: this node places keys on itself again and tells the peers it is ready."
  @spec rejoin() :: :ok
  def rejoin, do: SystemsRuntime.Server.call(@name, :rejoin)

  @impl true
  def init(opts) do
    SystemsRuntime.Proc.monitor_nodes(true, node_type: :visible)

    state = %{
      ring: build_ring([Node.self()]),
      on_change: Keyword.get(opts, :on_change),
      on_ready: Keyword.get(opts, :on_ready),
      # Each connected peer, with the reference of the readiness read made when it connected.
      connected: %{},
      ready_peers: MapSet.new(),
      # Peers that said they are draining; a late readiness read does not re-add them.
      draining_peers: MapSet.new(),
      draining: SalixCluster.NodeLifecycle.draining?()
    }

    {:ok, Enum.reduce(Node.list(:visible), state, &connect/2)}
  end

  @impl true
  def handle_call({:owner, agent_id}, _from, %{ring: ring} = state) do
    {:reply, HashRing.key_to_node(ring, agent_id), state}
  end

  def handle_call(:nodes, _from, %{ring: ring} = state) do
    {:reply, HashRing.nodes(ring), state}
  end

  def handle_call(:ready, _from, %{draining: true} = state) do
    # preStop came during startup: the launcher's ready must not undo leave.
    SystemsRuntime.put_env(:salix_cluster, :placement_ready, false)
    if is_function(state.on_ready, 0), do: state.on_ready.()
    {:reply, :ok, state}
  end

  def handle_call(:ready, _from, state) do
    tell_peers(state, {:ring_ready, Node.self()})
    if is_function(state.on_ready, 0), do: state.on_ready.()
    {:reply, :ok, state}
  end

  def handle_call(:leave, _from, state) do
    # A peer that connects from now on reads this flag and leaves us out.
    SystemsRuntime.put_env(:salix_cluster, :placement_ready, false)
    tell_peers(state, {:ring_draining, Node.self()})
    {:reply, :ok, put_members(%{state | draining: true})}
  end

  def handle_call(:rejoin, _from, state) do
    SystemsRuntime.put_env(:salix_cluster, :placement_ready, true)
    tell_peers(state, {:ring_ready, Node.self()})
    {:reply, :ok, put_members(%{state | draining: false})}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state),
    do: {:noreply, put_members(connect(node, state))}

  def handle_info({:nodedown, node, _info}, state) do
    # A node that comes back is a new start: it is read again.
    {:noreply,
     put_members(%{
       state
       | connected: Map.delete(state.connected, node),
         ready_peers: MapSet.delete(state.ready_peers, node),
         draining_peers: MapSet.delete(state.draining_peers, node)
     })}
  end

  # A peer that became ready after it connected, or that rejoined after draining.
  def handle_info({:ring_ready, node}, state) when is_atom(node) do
    {:noreply,
     put_members(%{
       state
       | ready_peers: MapSet.put(state.ready_peers, node),
         draining_peers: MapSet.delete(state.draining_peers, node)
     })}
  end

  # A peer that is draining: keys placed on it would start on a pod about to stop.
  def handle_info({:ring_draining, node}, state) when is_atom(node) do
    {:noreply,
     put_members(%{
       state
       | ready_peers: MapSet.delete(state.ready_peers, node),
         draining_peers: MapSet.put(state.draining_peers, node)
     })}
  end

  # The read made when the peer connected; one from an earlier connection is
  # stale, and one that lands after the peer said it is draining is too.
  def handle_info({:ring_ready_read, node, ref, ready?}, state) do
    if ready? and Map.get(state.connected, node) == ref and
         not MapSet.member?(state.draining_peers, node) do
      {:noreply, put_members(%{state | ready_peers: MapSet.put(state.ready_peers, node)})}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp connect(node, state) do
    ref = SystemsRuntime.Proc.make_ref()

    if node in Node.list(:visible) do
      read_ready(node, ref)
      # Its readiness read of us may have raced leave/0; the word reaches it.
      if state.draining,
        do: SystemsRuntime.Proc.send({@name, node}, {:ring_draining, Node.self()})
    end

    %{state | connected: Map.put(state.connected, node, ref)}
  end

  defp tell_peers(state, message) do
    for node <- Map.keys(state.connected), node in Node.list(:visible) do
      SystemsRuntime.Proc.send({@name, node}, message)
    end

    :ok
  end

  # The flag is read where it is kept, so a peer of any release answers. The ring
  # does not wait: the answer comes back as a message.
  defp read_ready(node, ref) do
    ring = SystemsRuntime.Proc.self()

    SystemsRuntime.Proc.spawn(fn ->
      ready? =
        try do
          :erpc.call(
            node,
            SystemsRuntime,
            :get_env,
            [:salix_cluster, :placement_ready, true],
            @ready_read_timeout_ms
          ) != false
        catch
          _kind, _reason -> false
        end

      SystemsRuntime.Proc.send(ring, {:ring_ready_read, node, ref, ready?})
    end)
  end

  # The callback runs after the new ring is stored, so any owner lookup it
  # schedules observes the changed node set.
  defp put_members(%{ring: previous} = state) do
    peers = state.connected |> Map.keys() |> Enum.filter(&MapSet.member?(state.ready_peers, &1))

    members =
      if state.draining and peers != [],
        do: peers,
        else: [Node.self() | peers]

    state = %{state | ring: build_ring(members)}

    if Enum.sort(HashRing.nodes(state.ring)) != Enum.sort(HashRing.nodes(previous)) and
         is_function(state.on_change, 0) do
      state.on_change.()
    end

    state
  end

  defp build_ring(nodes) do
    Enum.reduce(nodes, HashRing.new(), fn n, ring -> HashRing.add_node(ring, n) end)
  end
end
