defmodule SystemsRuntime.Bindings do
  @moduledoc false
  # Owns the bindings table. Readers look rows up directly; every write comes
  # here, so the owner (or allowed process) is monitored before the write
  # returns and its rows are deleted when it exits.
  #
  # Rows: `{{:bind, owner, app, key}, {:value, value} | :unset}`,
  # `{{:allow, pid}, owner}` and `{:shared, owner}`.
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    SystemsRuntime.put_table(table)
    {:ok, %{table: table, monitored: MapSet.new()}}
  end

  @impl true
  def handle_call({:bind, owner, app, key, binding}, _from, state) do
    :ets.insert(state.table, {{:bind, owner, app, key}, binding})
    {:reply, :ok, monitor(state, owner)}
  end

  def handle_call({:allow, owner, pid}, _from, state) do
    case :ets.lookup(state.table, {:allow, pid}) do
      [{_, other}] when other != owner ->
        {:reply, {:error, {:already_allowed, other}}, state}

      _ ->
        :ets.insert(state.table, {{:allow, pid}, owner})
        {:reply, :ok, state |> monitor(owner) |> monitor(pid)}
    end
  end

  def handle_call({:share, owner}, _from, state) do
    case :ets.lookup(state.table, :shared) do
      [{:shared, other}] when other != owner ->
        {:reply, {:error, {:already_shared, other}}, state}

      _ ->
        :ets.insert(state.table, {:shared, owner})
        {:reply, :ok, monitor(state, owner)}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.match_delete(state.table, {{:bind, pid, :_, :_}, :_})
    :ets.delete(state.table, {:allow, pid})
    :ets.match_delete(state.table, {{:allow, :_}, pid})
    :ets.match_delete(state.table, {:shared, pid})
    {:noreply, %{state | monitored: MapSet.delete(state.monitored, pid)}}
  end

  defp monitor(state, pid) do
    if MapSet.member?(state.monitored, pid) do
      state
    else
      Process.monitor(pid)
      %{state | monitored: MapSet.put(state.monitored, pid)}
    end
  end
end
