defmodule SalixAgent.SessionResidencyTest do
  use ExUnit.Case, async: false
  alias SalixAgent.SessionResidency, as: Residency

  defmodule Actor do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call(:hold, from, owner) do
      send(owner, {:held, from})
      {:noreply, owner}
    end

    def handle_call(:ping, _from, owner), do: {:reply, :pong, owner}

    def handle_info(:residency_evict, owner) do
      send(owner, {:eviction_requested, self()})
      {:noreply, owner}
    end
  end

  setup do
    controller = Process.whereis(Residency)
    if controller, do: :sys.suspend(controller)

    on_exit(fn ->
      if controller && Process.alive?(controller), do: :sys.resume(controller)
    end)

    # Pure runner creates the application-owned table; umbrella execution
    # uses the application's existing owner and touches only these test PIDs.
    if :ets.whereis(Residency) == :undefined, do: Residency.create_table()
    {:ok, pid} = start_supervised({Actor, self()})
    :ets.insert(Residency, {pid, %{}, true})
    on_exit(fn -> if :ets.whereis(Residency) != :undefined, do: Residency.unregister(pid) end)
    table = :ets.new(:residency_policy, [:public, :ordered_set])
    :ets.insert(table, {pid, %{}, true})
    %{pid: pid, table: table}
  end

  test "CLOCK gives a reference one chance, and a real call renews it", %{pid: pid} do
    assert Residency.second_chance(pid) == :referenced
    assert Residency.second_chance(pid) == :candidate
    assert Residency.call(pid, :ping, 1000) == :pong
    assert Residency.second_chance(pid) == :referenced
    assert Residency.second_chance(pid) == :candidate
  end

  test "an admitted call pins the actor through its reply", %{pid: pid} do
    task = Task.async(fn -> Residency.call(pid, :hold, 1000) end)
    assert_receive {:held, from}
    assert Residency.second_chance(pid) == :referenced
    assert Residency.second_chance(pid) == :pinned
    refute Residency.close(pid)
    GenServer.reply(from, :ok)
    assert Task.await(task) == :ok
    assert Residency.second_chance(pid) == :candidate
    assert Residency.close(pid)
    assert Residency.call(pid, :ping, 1000) == {:error, :session_actor_retiring}
    assert Residency.cast(pid, :wake) == {:error, :session_actor_retiring}
    assert Residency.reopen(pid)
    assert Residency.call(pid, :ping, 1000) == :pong
  end

  test "a killed caller does not leave a permanent pin", %{pid: pid} do
    caller = spawn(fn -> Residency.call(pid, :hold, :infinity) end)
    assert_receive {:held, _}
    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
    Residency.second_chance(pid)
    Residency.second_chance(pid)
    assert Residency.second_chance(pid) == :candidate
    assert Residency.close(pid)
  end

  test "timeout releases admission without pretending queued work was cancelled", %{pid: pid} do
    assert catch_exit(Residency.call(pid, :hold, 1))
    assert_receive {:held, _}
    Residency.second_chance(pid)
    assert Residency.second_chance(pid) == :candidate
    # The production owner also checks its busy state and mailbox before stop.
  end

  test "concurrent callers cannot overwrite each other's pins", %{pid: pid} do
    tasks = for _ <- 1..20, do: Task.async(fn -> Residency.call(pid, :hold, 2000) end)

    froms =
      for _ <- tasks do
        assert_receive {:held, from}
        from
      end

    Residency.second_chance(pid)
    assert Residency.second_chance(pid) == :pinned
    [last | first] = froms
    Enum.each(first, &GenServer.reply(&1, :ok))
    refute Residency.close(pid)
    GenServer.reply(last, :ok)
    Enum.each(tasks, &Task.await/1)
    assert Residency.second_chance(pid) == :candidate
    assert Residency.close(pid)
  end

  test "pressure, hysteresis, no-progress and read failure drive bounded admission", %{
    pid: pid,
    table: table
  } do
    state = %{
      table: table,
      cursor: :pressure,
      monitors: %{pid => make_ref()},
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
    refute_receive {:eviction_requested, _}, 10
    state = %{state | sample: fn -> {:ok, %{used: 85, limit: 100}} end}
    {:noreply, state} = Residency.handle_info(:tick, state)
    assert Residency.admission(table) == {:error, :session_memory_pressure}
    refute_receive {:eviction_requested, _}, 10
    {:noreply, state} = Residency.handle_info(:tick, state)
    assert_receive {:eviction_requested, ^pid}
    {:noreply, state} = Residency.handle_cast(:evicted, state)
    {:noreply, state} = Residency.handle_info(:tick, state)
    assert state.stalled
    refute_receive {:eviction_requested, _}, 10

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

  test "CLOCK continues when its previous actor disappears", %{pid: pid, table: table} do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    :ets.insert(table, {dead, %{}, false})

    state = %{
      table: table,
      cursor: dead,
      monitors: %{dead => ref, pid => make_ref()},
      sample: fn -> {:ok, %{used: 85, limit: 100}} end,
      interval: 60_000,
      high: 0.8,
      low: 0.65,
      batch: 2,
      pressure: false,
      previous: nil,
      attempted: false,
      stalled: false
    }

    {:noreply, state} = Residency.handle_info({:DOWN, ref, :process, dead, :normal}, state)
    assert :ets.lookup(table, dead) == []
    assert {:noreply, _} = Residency.handle_info(:tick, state)
  end

  test "file cache does not trigger soft eviction, but near-limit charge still does", %{
    table: table
  } do
    state = %{
      table: table,
      cursor: :pressure,
      monitors: %{},
      sample: fn -> {:ok, %{used: 85, reclaimable: 30, limit: 100}} end,
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
    refute state.pressure

    {:noreply, state} =
      Residency.handle_info(:tick, %{
        state
        | sample: fn -> {:ok, %{used: 96, reclaimable: 30, limit: 100}} end
      })

    assert state.pressure
  end
end
