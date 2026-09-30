defmodule SalixAgent.SessionHistory.Scheduler do
  @moduledoc "Pod-local session serialization and fair tenant admission for history workers."
  use GenServer
  alias SalixAgent.SessionHistory.Worker
  @limit 4
  @tenant_limit 2

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def claim, do: GenServer.call(__MODULE__, :claim)
  def maintenance(key), do: GenServer.call(__MODULE__, {:maintenance, key})
  def complete, do: GenServer.call(__MODULE__, :complete)

  def init(_) do
    Worker.init_queue()
    {:ok, %{active: %{}, served: %{}, turn: 0}}
  end

  def handle_call(:claim, {pid, _}, state) do
    pending = Worker.pending_hints()
    tenants = Enum.map(pending, fn {{agent, _}, _} -> tenant(agent) end)
    active_tenants = Enum.map(state.active, fn {_, task} -> task.tenant end)
    state = %{state | served: Map.take(state.served, tenants ++ active_tenants)}

    candidate =
      pending
      |> Enum.filter(fn {key, _} ->
        not Map.has_key?(state.active, pid) and available?(state, key)
      end)
      |> Enum.min_by(
        fn {{agent, _}, queued_at} -> {Map.get(state.served, tenant(agent), -1), queued_at} end,
        fn -> nil end
      )

    case candidate do
      {key, _} ->
        case Worker.take_key(key) do
          ^key -> {:reply, key, admit(state, pid, key)}
          nil -> {:reply, nil, state}
        end

      nil ->
        {:reply, nil, state}
    end
  end

  def handle_call({:maintenance, key}, {pid, _}, state) do
    # Maintenance must not take a free slot ahead of admissible recent work.
    recent_waiting = Enum.any?(Worker.pending_hints(), fn {k, _} -> available?(state, k) end)

    if not Map.has_key?(state.active, pid) and available?(state, key) and not recent_waiting do
      {:reply, :ok, admit(state, pid, key)}
    else
      {:reply, :busy, state}
    end
  end

  def handle_call(:complete, {pid, _}, state) do
    {:reply, :ok, release(state, pid)}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    case state.active[pid] do
      %{ref: ^ref, key: {agent, session}} ->
        Worker.hint(agent, session)
        {:noreply, release(state, pid)}

      _ ->
        {:noreply, state}
    end
  end

  defp available?(state, {agent, _} = key) do
    map_size(state.active) < @limit and
      not Enum.any?(state.active, fn {_, task} -> task.key == key end) and
      Enum.count(state.active, fn {_, task} -> task.tenant == tenant(agent) end) < @tenant_limit
  end

  defp admit(state, pid, {agent, _} = key) do
    task = %{key: key, tenant: tenant(agent), ref: Process.monitor(pid)}
    queued_tenants = Enum.map(Worker.pending_hints(), fn {{a, _}, _} -> tenant(a) end)
    active_tenants = Enum.map(state.active, fn {_, t} -> t.tenant end)
    served = Map.take(state.served, queued_tenants ++ active_tenants)

    %{
      state
      | active: Map.put(state.active, pid, task),
        served: Map.put(served, task.tenant, state.turn),
        turn: state.turn + 1
    }
  end

  defp release(state, pid) do
    case Map.pop(state.active, pid) do
      {nil, _} ->
        state

      {%{ref: ref}, active} ->
        Process.demonitor(ref, [:flush])
        %{state | active: active}
    end
  end

  defp tenant(agent) do
    SalixStore.Ids.tenant_id_from_agent!(agent)
  rescue
    # Legacy/test identities share a conservative quota, never an unbounded lane.
    _ -> :legacy
  end
end
