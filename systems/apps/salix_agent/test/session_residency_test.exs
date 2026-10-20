defmodule SalixAgent.SessionResidencyTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  alias SalixAgent.SessionResidency, as: Residency

  defmodule Actor do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call(:hold, from, owner) do
      SystemsRuntime.Proc.send(owner, {:held, from})
      {:noreply, owner}
    end

    def handle_call(:ping, _from, owner), do: {:reply, :pong, owner}

    def handle_info(:residency_evict, owner) do
      SystemsRuntime.Proc.send(owner, {:eviction_requested, SystemsRuntime.Proc.self()})
      {:noreply, owner}
    end
  end

  setup do
    controller = SystemsRuntime.Proc.whereis(Residency)
    if controller, do: :sys.suspend(controller, :infinity)

    on_exit(fn ->
      if controller && SystemsRuntime.Proc.alive?(controller),
        do: :sys.resume(controller, :infinity)
    end)

    # Pure runner creates the application-owned table; umbrella execution
    # uses the application's existing owner and touches only these test PIDs.
    if :ets.whereis(Residency) == :undefined, do: Residency.create_table()
    {:ok, pid} = start_supervised({Actor, SystemsRuntime.Proc.self()})
    :ets.insert(Residency, {pid, %{}, true})
    on_exit(fn -> if :ets.whereis(Residency) != :undefined, do: Residency.unregister(pid) end)
    table = :ets.new(:residency_policy, [:public, :ordered_set])
    :ets.insert(table, {pid, %{}, true})
    %{pid: pid, table: table}
  end

  test "an admitted call pins the actor through its reply", %{pid: pid} do
    task = SystemsRuntime.Task.async(fn -> Residency.call(pid, :hold, 1000) end)
    settle_receive({:held, from})
    assert Residency.second_chance(pid) == :referenced
    assert Residency.second_chance(pid) == :pinned
    refute Residency.close(pid)
    GenServer.reply(from, :ok)
    assert settled_await(task) == :ok
    assert Residency.second_chance(pid) == :candidate
    assert Residency.close(pid)
    assert Residency.call(pid, :ping, 1000) == {:error, :session_actor_retiring}
    assert Residency.cast(pid, :wake) == {:error, :session_actor_retiring}
    assert Residency.reopen(pid)
    assert Residency.call(pid, :ping, 1000) == :pong
  end

  test "pressure, hysteresis, no-progress and read failure drive bounded admission", %{
    pid: pid,
    table: table
  } do
    state = %{
      table: table,
      cursor: :pressure,
      monitors: %{pid => SystemsRuntime.Proc.make_ref()},
      sample: fn -> {:ok, %{used: 50, limit: 100}} end,
      interval: 60_000,
      high: 0.8,
      low: 0.65,
      batch: 2,
      pressure: false,
      previous: nil,
      attempted: false,
      stalled: false
    }

    {:noreply, state} = Residency.handle_info(:tick, state)
    assert Residency.admission(table) == :ok
    settle_refute_receive({:eviction_requested, _}, 10)
    state = %{state | sample: fn -> {:ok, %{used: 85, limit: 100}} end}
    {:noreply, state} = Residency.handle_info(:tick, state)
    assert Residency.admission(table) == {:error, :session_memory_pressure}
    settle_refute_receive({:eviction_requested, _}, 10)
    {:noreply, state} = Residency.handle_info(:tick, state)
    settle_receive({:eviction_requested, ^pid})
    {:noreply, state} = Residency.handle_cast(:evicted, state)
    {:noreply, state} = Residency.handle_info(:tick, state)
    assert state.stalled
    settle_refute_receive({:eviction_requested, _}, 10)

    {:noreply, state} =
      Residency.handle_info(:tick, %{state | sample: fn -> {:ok, %{used: 70, limit: 100}} end})

    assert state.pressure

    {:noreply, state} =
      Residency.handle_info(:tick, %{state | sample: fn -> {:ok, %{used: 60, limit: 100}} end})

    refute state.pressure
    assert Residency.admission(table) == :ok
    Residency.handle_info(:tick, %{state | sample: fn -> raise "unavailable" end})
    assert Residency.admission(table) == {:error, :session_memory_pressure}
  end
end
