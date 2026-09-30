defmodule SalixIM.TestSupport.FleetTest do
  use ExUnit.Case, async: false

  alias SalixIM.TestSupport.Fleet

  @fleet SalixIM.TestSupport.FleetTestSupervisor
  @registry SalixIM.TestSupport.FleetTestRegistry

  defmodule GatedChild do
    def start_link(opts) do
      gate = Keyword.fetch!(opts, :gate)

      if :atomics.get(gate, 1) == 1 do
        test_pid = Keyword.fetch!(opts, :test_pid)
        registry = Keyword.fetch!(opts, :registry)

        Task.start_link(fn ->
          Registry.register(registry, :gated_child, nil)
          send(test_pid, {:gated_child_started, self()})
          Process.sleep(:infinity)
        end)
      else
        Process.sleep(1)
        {:error, :restart_gate_closed}
      end
    end
  end

  defmodule DependentChild do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)
      {:ok, opts}
    end

    @impl true
    def terminate(_reason, opts) do
      value = Agent.get(Keyword.fetch!(opts, :dependency), & &1)
      send(Keyword.fetch!(opts, :test_pid), {:dependency_available_at_shutdown, value})
    end
  end

  test "cleanup stops consumers before their supervised dependencies" do
    start_supervised!({Registry, keys: :unique, name: @registry})
    start_supervised!({DynamicSupervisor, name: @fleet, strategy: :one_for_one})
    dependency = __MODULE__.Dependency

    children = [
      %{id: dependency, start: {Agent, :start_link, [fn -> :ready end, [name: dependency]]}},
      {Fleet.Cleanup, supervisor: @fleet, registry: @registry}
    ]

    fixture =
      start_supervised!(%{
        id: :fixture,
        start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
        restart: :temporary
      })

    {:ok, consumer} =
      DynamicSupervisor.start_child(
        @fleet,
        {DependentChild, dependency: dependency, test_pid: self()}
      )

    Supervisor.stop(fixture)
    assert_receive {:dependency_available_at_shutdown, :ready}
    refute Process.alive?(consumer)
    assert DynamicSupervisor.count_children(@fleet).specs == 0
  end

  @tag capture_log: true
  test "waits for a restarting child before reporting fleet quiescence" do
    start_supervised!({Registry, keys: :unique, name: @registry})

    start_supervised!(
      {DynamicSupervisor,
       name: @fleet, strategy: :one_for_one, max_restarts: 1_000_000, max_seconds: 1}
    )

    gate = :atomics.new(1, [])
    :atomics.put(gate, 1, 1)

    child_spec = %{
      id: :gated_child,
      start: {GatedChild, :start_link, [[gate: gate, test_pid: self(), registry: @registry]]},
      restart: :permanent,
      type: :worker
    }

    assert {:ok, child} = DynamicSupervisor.start_child(@fleet, child_spec)
    assert_receive {:gated_child_started, ^child}, 1_000

    :atomics.put(gate, 1, 0)
    Process.exit(child, :kill)

    assert_eventually(fn ->
      children = DynamicSupervisor.which_children(@fleet)
      counts = Map.take(DynamicSupervisor.count_children(@fleet), [:active, :specs])

      children == [{:undefined, :restarting, :worker, [GatedChild]}] and
        counts == %{active: 0, specs: 1} and Registry.count(@registry) == 0
    end)

    assert %{active: 0, specs: 1} =
             Map.take(DynamicSupervisor.count_children(@fleet), [:active, :specs])

    stop_task = Task.async(fn -> Fleet.stop_all!(@fleet, @registry) end)

    try do
      assert nil == Task.yield(stop_task, 100)
    after
      :atomics.put(gate, 1, 1)
    end

    assert :ok = Task.await(stop_task, 2_000)

    assert %{active: 0, specs: 0} =
             Map.take(DynamicSupervisor.count_children(@fleet), [:active, :specs])

    assert Registry.count(@registry) == 0
  end

  @tag capture_log: true
  test "waits while a Registry partition is unavailable during restart" do
    registry = start_supervised!({Registry, keys: :unique, name: @registry, partitions: 2})
    start_supervised!({DynamicSupervisor, name: @fleet, strategy: :one_for_one})
    [{_, partition, _, _} | _] = Supervisor.which_children(registry)
    ref = Process.monitor(partition)

    :ok = :sys.suspend(registry)

    try do
      Process.exit(partition, :kill)
      assert_receive {:DOWN, ^ref, :process, ^partition, :killed}

      stop_task =
        Task.async(fn ->
          try do
            Fleet.stop_all!(@fleet, @registry)
          rescue
            error -> {:error, error}
          end
        end)

      assert Task.yield(stop_task, 50) == nil
      :ok = :sys.resume(registry)
      assert Task.await(stop_task, 2_000) == :ok
    after
      :sys.resume(registry)
    end
  end

  defp assert_eventually(fun, attempts_left \\ 1_000)

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp assert_eventually(fun, attempts_left) do
    if fun.() do
      :ok
    else
      Process.sleep(1)
      assert_eventually(fun, attempts_left - 1)
    end
  end
end
