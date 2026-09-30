defmodule CommaSSH.Connections do
  @moduledoc "Ephemeral, process-scoped handoff from completed SSH authentication to its channel."
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def authenticated(blob, peer), do: GenServer.call(__MODULE__, {:register, blob, peer})
  def claim(connection), do: GenServer.call(__MODULE__, {:claim, connection})
  def init(state), do: {:ok, state}

  def handle_call({:register, blob, peer}, {pid, _}, state) do
    Process.monitor(pid)
    {:reply, :ok, Map.put(state, pid, %{key: blob, peer: peer, claimed: false})}
  end

  def handle_call({:claim, connection}, _from, state) do
    case state[connection] do
      %{claimed: false} = context ->
        {:reply, {:ok, context}, Map.put(state, connection, %{context | claimed: true})}

      _ ->
        {:reply, {:error, :unauthenticated}, state}
    end
  end

  def handle_info({:DOWN, _, :process, pid, _}, state), do: {:noreply, Map.delete(state, pid)}
end
