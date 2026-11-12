defmodule SalixAgent.SessionHistory.Scheduler do
  @moduledoc "Pod-local session serialization and fair tenant admission for history workers."
  use SystemsRuntime.Server
  alias SalixAgent.SessionHistory.Worker
  @limit 4
  @tenant_limit 2

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)
  def drain, do: SystemsRuntime.Server.cast(__MODULE__, :drain)

  def init(_) do
    Worker.init_queue()
    {:ok, %{active: %{}, served: %{}, turn: 0}}
  end

  def handle_cast(:drain, state), do: {:noreply, start_ready(state)}

  defp start_ready(state) do
    {key, state} = next(state)

    case key && Worker.take_key(key) do
      nil ->
        state

      {agent, session} = key ->
        # This scheduler admits the address before another task can start.
        # No unclaimed task exists outside the same four total / two tenant slots.
        {:ok, pid} =
          SystemsRuntime.Task.start(fn ->
            Worker.safely("session_history_index", fn -> Worker.index(agent, session) end)
          end)

        start_ready(admit(state, pid, key))
    end
  end

  defp next(state) do
    pending = Worker.pending_hints()
    tenants = Enum.map(pending, fn {{agent, _}, _} -> tenant(agent) end)
    active_tenants = Enum.map(state.active, fn {_, task} -> task.tenant end)
    state = %{state | served: Map.take(state.served, tenants ++ active_tenants)}

    candidate =
      pending
      |> Enum.filter(fn {key, _} ->
        available?(state, key)
      end)
      |> Enum.min_by(
        fn {{agent, _}, queued_at} -> {Map.get(state.served, tenant(agent), -1), queued_at} end,
        fn -> nil end
      )

    case candidate do
      {key, _} -> {key, state}
      nil -> {nil, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case state.active[pid] do
      %{ref: ^ref, key: {agent, session}} ->
        if reason != :normal, do: Worker.hint(agent, session)
        {:noreply, start_ready(release(state, pid))}

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
    task = %{key: key, tenant: tenant(agent), ref: SystemsRuntime.Proc.monitor(pid)}
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
        SystemsRuntime.Proc.demonitor(ref, [:flush])
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
