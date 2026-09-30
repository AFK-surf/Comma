defmodule SalixAgent.SessionResidency do
  @moduledoc """
  Node-local CLOCK residency for internal session actors. No idle TTL.

  The application owns the admission table, so controller restart cannot forget
  pins or reopen a retiring actor. A pin covers command admission through its
  reply; casts are pinned through enqueue. The actor alone closes its gate and
  checks quiescence before stopping. Rejected commands have not been sent.
  """
  use GenServer
  @table __MODULE__

  def create_table do
    :ets.new(@table, [:named_table, :public, :ordered_set, write_concurrency: true])
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def register(pid) do
    true = :ets.insert_new(@table, {pid, %{}, true})
    GenServer.cast(__MODULE__, {:register, pid})
    :ok
  end

  def evicted, do: GenServer.cast(__MODULE__, :evicted)

  def unregister(pid), do: :ets.delete(@table, pid)

  def eviction_allowed?, do: :ets.lookup(@table, :pressure) == [{:pressure, :high}]

  def admission(table \\ @table) do
    case :ets.lookup(table, :pressure) do
      [{:pressure, :normal}] -> :ok
      _ -> {:error, :session_memory_pressure}
    end
  end

  def call(pid, message, timeout) do
    with {:ok, token} <- pin(pid) do
      try do
        GenServer.call(pid, message, timeout)
      after
        unpin(pid, token)
      end
    end
  end

  def cast(pid, message) do
    with {:ok, token} <- pin(pid) do
      try do
        GenServer.cast(pid, message)
      after
        unpin(pid, token)
      end
    end
  end

  # The lease belongs to the caller. Dead callers are pruned during CLOCK
  # scanning; a killed caller cannot leave an uncollectable pin behind.
  defp pin(pid) do
    token = make_ref()

    case :ets.lookup(@table, pid) do
      [{^pid, pins, referenced}] when is_map(pins) ->
        if replace({pid, pins, referenced}, {pid, Map.put(pins, token, self()), true}),
          do: {:ok, token},
          else: pin(pid)

      _ ->
        {:error, :session_actor_retiring}
    end
  end

  defp unpin(pid, token) do
    case :ets.lookup(@table, pid) do
      [{^pid, pins, referenced}] when is_map(pins) ->
        unless replace({pid, pins, referenced}, {pid, Map.delete(pins, token), referenced}),
          do: unpin(pid, token)

      _ ->
        :ok
    end
  end

  def close(pid), do: replace({pid, %{}, false}, {pid, :retiring, false})
  def reopen(pid), do: replace({pid, :retiring, false}, {pid, %{}, true})

  def second_chance(pid, table \\ @table) do
    case :ets.lookup(table, pid) do
      [{^pid, pins, referenced}] when is_map(pins) ->
        live = Map.filter(pins, fn {_ref, caller} -> Process.alive?(caller) end)

        cond do
          live != pins ->
            replace({pid, pins, referenced}, {pid, live, referenced}, table)
            :pinned

          referenced ->
            replace({pid, pins, true}, {pid, pins, false}, table)
            :referenced

          map_size(pins) == 0 ->
            :candidate

          true ->
            :pinned
        end

      _ ->
        :pinned
    end
  end

  defp replace({pid, pins, referenced}, new, table \\ @table) do
    :ets.select_replace(table, [
      {{pid, :"$1", :"$2"}, [{:"=:=", :"$1", {:const, pins}}, {:"=:=", :"$2", referenced}],
       [{:const, new}]}
    ]) == 1
  end

  @impl true
  def init(opts) do
    opts = Keyword.merge(Application.get_env(:salix_agent, :session_residency, []), opts)

    state = %{
      table: Keyword.get(opts, :table, @table),
      cursor: :"$end_of_table",
      monitors: %{},
      sample: Keyword.get(opts, :sample, &SalixAgent.SessionMemory.sample/0),
      interval: Keyword.get(opts, :interval, 1_000),
      high: Keyword.get(opts, :high, 0.80),
      low: Keyword.get(opts, :low, 0.65),
      batch: Keyword.get(opts, :batch, 16),
      pressure: false,
      previous: nil,
      attempted: false,
      stalled: false
    }

    state =
      Enum.reduce(:ets.tab2list(state.table), state, fn
        {pid, _, _}, acc when is_pid(pid) -> track(pid, acc)
        _, acc -> acc
      end)

    {:ok, tick(state)}
  end

  @impl true
  def handle_cast(:evicted, state), do: {:noreply, %{state | attempted: true}}

  def handle_cast({:register, pid}, state), do: {:noreply, track(pid, state)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    :ets.delete(state.table, pid)

    {:noreply,
     %{
       state
       | monitors: Map.delete(state.monitors, pid)
     }}
  end

  def handle_info(:tick, state), do: {:noreply, tick(state)}

  defp track(pid, state) do
    if Map.has_key?(state.monitors, pid) do
      state
    else
      ref = Process.monitor(pid)
      %{state | monitors: Map.put(state.monitors, pid, ref)}
    end
  end

  defp sample(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp tick(state) do
    state =
      case sample(state.sample) do
        {:ok, %{used: used, limit: limit} = sample}
        when is_integer(used) and used >= 0 and is_integer(limit) and limit > 0 ->
          working = max(used - Map.get(sample, :reclaimable, 0), 0)

          pressure =
            working >= limit * state.high or used >= limit * 0.95 or
              (state.pressure and (working > limit * state.low or used >= limit * 0.90))

          # An eviction batch must show actual charge reduction before another
          # batch. Allocator retention must not empty the resident set blindly.
          stalled =
            pressure and state.attempted and state.previous != nil and used >= state.previous

          :ets.insert(state.table, {:pressure, if(pressure, do: :high, else: :normal)})
          next = %{state | pressure: pressure, previous: used, stalled: stalled}

          if pressure and not stalled,
            do: sweep(next),
            else: %{next | attempted: state.attempted and pressure}

        _ ->
          :ets.insert(state.table, {:pressure, :unknown})
          state
      end

    observe(state)
    Process.send_after(self(), :tick, state.interval)
    state
  end

  defp observe(state) do
    # No identity labels and no event handlers on the command-admission path.
    :telemetry.execute(
      [:salix, :session_residency, :sample],
      %{
        resident: map_size(state.monitors),
        pressure: if(admission(state.table) == :ok, do: 0, else: 1),
        stalled: if(state.stalled, do: 1, else: 0),
        observed_at: System.system_time(:second)
      },
      %{}
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp sweep(state) do
    # ordered_set permits next/2 after the previous actor was deleted. No
    # population-wide queue traversal or retained dead-PID queue is needed.
    cursor =
      Enum.reduce(
        List.duplicate(nil, min(state.batch, map_size(state.monitors) + 1)),
        state.cursor,
        fn _, cursor ->
          next =
            case cursor do
              :"$end_of_table" -> :ets.first(state.table)
              key -> :ets.next(state.table, key)
            end

          next = if next == :"$end_of_table", do: :ets.first(state.table), else: next

          if is_pid(next) do
            if Process.alive?(next) do
              if second_chance(next, state.table) == :candidate, do: send(next, :residency_evict)
            else
              :ets.delete(state.table, next)
            end
          end

          next
        end
      )

    %{state | cursor: cursor, attempted: false}
  end
end
