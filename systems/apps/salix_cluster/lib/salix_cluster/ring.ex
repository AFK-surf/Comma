defmodule SalixCluster.Ring do
  @moduledoc """
  Consistent-hash placement ring. A `libring` `HashRing` over the
  connected, visible nodes; `owner/1` names the node that should own the agent
  server. Agent-below-owner resources should only start on that owner node.

  Maintained via `:net_kernel.monitor_nodes/2`: nodes are added/removed as the
  mesh changes. Always includes `Node.self()`.
  """
  use GenServer

  @name __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @doc "Preferred node for an agent id."
  @spec owner(String.t()) :: node()
  def owner(agent_id), do: GenServer.call(@name, {:owner, agent_id})

  @doc "Nodes currently in the ring."
  @spec nodes() :: [node()]
  def nodes, do: GenServer.call(@name, :nodes)

  @impl true
  def init(_opts) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    ring = build_ring([Node.self() | Node.list(:visible)])
    {:ok, %{ring: ring}}
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
    {:noreply, %{state | ring: HashRing.add_node(ring, node)}}
  end

  def handle_info({:nodedown, node, _info}, %{ring: ring} = state) do
    {:noreply, %{state | ring: HashRing.remove_node(ring, node)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp build_ring(nodes) do
    Enum.reduce(nodes, HashRing.new(), fn n, ring -> HashRing.add_node(ring, n) end)
  end
end
