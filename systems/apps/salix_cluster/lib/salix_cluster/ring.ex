defmodule SalixCluster.Ring do
  @moduledoc """
  Consistent-hash placement ring. A `libring` `HashRing` over the
  connected, visible nodes; `owner/1` names the node that should own the agent
  server. Agent-below-owner resources should only start on that owner node.

  Maintained via `:net_kernel.monitor_nodes/2`: nodes are added/removed as the
  mesh changes. Always includes `Node.self()`.

  `:on_change` is a zero-arity function called after the node set changes.
  It runs inside the ring process, so it must only schedule work.
  """
  use SystemsRuntime.Server

  @name __MODULE__

  def start_link(opts \\ []), do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: @name)

  @doc "Preferred node for an agent id."
  @spec owner(String.t()) :: node()
  def owner(agent_id), do: SystemsRuntime.Server.call(@name, {:owner, agent_id})

  @doc "Nodes currently in the ring."
  @spec nodes() :: [node()]
  def nodes, do: SystemsRuntime.Server.call(@name, :nodes)

  @impl true
  def init(opts) do
    SystemsRuntime.Proc.monitor_nodes(true, node_type: :visible)
    ring = build_ring([Node.self() | Node.list(:visible)])
    {:ok, %{ring: ring, on_change: Keyword.get(opts, :on_change)}}
  end

  @impl true
  def handle_call({:owner, agent_id}, _from, %{ring: ring} = state) do
    {:reply, HashRing.key_to_node(ring, agent_id), state}
  end

  def handle_call(:nodes, _from, %{ring: ring} = state) do
    {:reply, HashRing.nodes(ring), state}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, %{ring: ring} = state) do
    {:noreply, put_ring(state, HashRing.add_node(ring, node))}
  end

  def handle_info({:nodedown, node, _info}, %{ring: ring} = state) do
    {:noreply, put_ring(state, HashRing.remove_node(ring, node))}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The callback runs after the new ring is stored, so any owner lookup it
  # schedules observes the changed node set.
  defp put_ring(%{ring: previous} = state, ring) do
    state = %{state | ring: ring}

    if Enum.sort(HashRing.nodes(ring)) != Enum.sort(HashRing.nodes(previous)) and
         is_function(state.on_change, 0) do
      state.on_change.()
    end

    state
  end

  defp build_ring(nodes) do
    Enum.reduce(nodes, HashRing.new(), fn n, ring -> HashRing.add_node(ring, n) end)
  end
end
