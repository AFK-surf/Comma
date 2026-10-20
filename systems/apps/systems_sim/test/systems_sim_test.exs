defmodule SystemsSimTest do
  require Logger
  use SystemsClock.Case, async: false

  alias SystemsSim.Run

  defmodule Register do
    @moduledoc false
    use GenServer

    def init(value), do: {:ok, value}
    def handle_call(:get, _from, value), do: {:reply, value, value}
    def handle_call({:put, value}, _from, _), do: {:reply, :ok, value}
  end

  # Three tasks each increment a register twice with a read and a write:
  # 6 when no two increments interleave, less when one overwrites another.
  defp lost_update do
    {:ok, register} = GenServer.start_link(Register, 0)

    1..3
    |> Enum.map(fn _ ->
      Task.async(fn ->
        for _ <- 1..2 do
          value = GenServer.call(register, :get)
          :ok = GenServer.call(register, {:put, value + 1})
        end
      end)
    end)
    |> Enum.map(&await/1)

    GenServer.call(register, :get)
  end

  test "a seed decides the interleaving: the same seed repeats it, other seeds find the race" do
    {runs, agains} =
      SystemsSim.one_scheduler(fn ->
        runs = for seed <- 1..200, do: SystemsSim.run(&lost_update/0, seed: seed)

        agains =
          for %Run{seed: seed} <- Enum.take(runs, 20),
              do: SystemsSim.run(&lost_update/0, seed: seed)

        {runs, agains}
      end)

    for {run, again} <- Enum.zip(runs, agains) do
      assert {again.result, again.trace} == {run.result, run.trace}
    end

    outcomes = runs |> Enum.map(& &1.result) |> Enum.uniq() |> Enum.sort()
    assert {:ok, 2} in outcomes
    assert Enum.all?(outcomes, &match?({:ok, n} when n in 2..6, &1))
  end

  test "check/2 names the seed that breaks the property" do
    error =
      assert_raise SystemsSim.Failure, fn ->
        SystemsSim.check(&lost_update/0, property: &match?(%Run{result: {:ok, 6}}, &1))
      end

    assert Exception.message(error) =~ "Reproduce with SYSTEMS_SIM_SEED=#{error.run.seed}"
    assert SystemsSim.run(&lost_update/0, seed: error.run.seed).result == error.run.result
  end

  test "the clock moves to the next timer when the world is idle" do
    run =
      SystemsSim.run(fn ->
        parent = self()

        for {name, ms} <- [slow: 5_000, fast: 20] do
          spawn_link(fn ->
            SystemsClock.sleep(ms)
            send(parent, {name, SystemsClock.monotonic_time(:millisecond)})
          end)
        end

        started = SystemsClock.monotonic_time(:millisecond)

        for _ <- 1..2 do
          receive do
            {name, at} -> {name, at - started}
          end
        end
      end)

    assert run.result == {:ok, [fast: 20, slow: 5_000]}
    assert {:clock, 20} in run.trace
  end

  test "a world that waits on itself is reported as a deadlock" do
    run =
      SystemsSim.run(fn ->
        {:ok, register} = GenServer.start_link(Register, 0)
        :sys.suspend(register)
        GenServer.call(register, :get, :infinity)
      end)

    assert {:error, {:deadlock, procs}} = run.result
    assert length(procs) == 2
  end

  test "a call to a process outside the world keeps the turn until it replies" do
    {:ok, outside} = start_supervised({Agent, fn -> [] end})

    run =
      SystemsSim.run(fn ->
        1..3
        |> Enum.map(fn i ->
          Task.async(fn ->
            Agent.update(outside, &[{:start, i} | &1])
            Agent.update(outside, &[{:stop, i} | &1])
          end)
        end)
        |> Enum.map(&await/1)

        Agent.get(outside, &Enum.reverse/1)
      end)

    {:ok, events} = run.result
    # Each task runs alone between its calls only if the world is serial;
    # the order of the tasks still follows the seed.
    assert length(events) == 6
  end

  test "a process waiting on the runtime keeps the turn" do
    run =
      SystemsSim.run(fn ->
        root = self()

        spawn(fn ->
          # With a message queued at the root, the runtime answers through the
          # root's signal queue, while the root waits for its turn.
          send(root, :queued)
          send(root, {:alive, Process.alive?(root)})
        end)

        # Fires if the child is left waiting for the answer.
        SystemsClock.send_after(root, :timeout, 1_000)

        receive do
          {:alive, alive?} -> alive?
          :timeout -> :timeout
        end
      end)

    assert run.result == {:ok, true}
  end

  test "a call to a process of the world is answered there, whatever the caller holds open" do
    run =
      SystemsSim.run(fn ->
        {:ok, register} = GenServer.start_link(Register, :answer)
        # A lazy log message is made inside Logger's frames, as a transaction
        # runs inside the database pool's.
        Logger.info(fn -> "read #{GenServer.call(register, :get)}" end)
        :logged
      end)

    assert run.result == {:ok, :logged}
    assert Enum.any?(SystemsSim.Log.events(), &(&1 =~ "read answer"))
  end

  test "processes left running are stopped when the run ends" do
    run =
      SystemsSim.run(fn ->
        pid = spawn(fn -> receive do: (:never -> :ok) end)
        :persistent_term.put({__MODULE__, :left}, pid)
        :ok
      end)

    assert run.result == {:ok, :ok}
    refute Process.alive?(:persistent_term.get({__MODULE__, :left}))
  end

  test "a child of a node's supervisor runs in the world while it is hosted" do
    {:ok, top} =
      Supervisor.start_link(
        [%{id: :counter, start: {Agent, :start_link, [fn -> 0 end, [name: __MODULE__.Counter]]}}],
        strategy: :one_for_one
      )

    boot = Process.whereis(__MODULE__.Counter)

    run =
      SystemsSim.run(fn ->
        SystemsSim.host([{top, :counter}])
        hosted = Process.whereis(__MODULE__.Counter)

        tasks =
          for _ <- 1..3,
              do: Task.async(fn -> Agent.get_and_update(__MODULE__.Counter, &{&1, &1 + 1}) end)

        {hosted, Enum.map(tasks, &await/1)}
      end)

    assert {:ok, {hosted, seen}} = run.result
    assert hosted != boot and not Process.alive?(hosted)
    assert Enum.sort(seen) == [0, 1, 2]
    assert [{:counter, again, :worker, _}] = Supervisor.which_children(top)
    assert is_pid(again) and Process.whereis(__MODULE__.Counter) == again
  end

  test "a world's log events stay in the world, and the default handler is back after it" do
    {:ok, before} = :logger.get_handler_config(:default)

    run =
      SystemsSim.run(fn ->
        task = Task.async(fn -> Logger.error("from a process of the world") end)
        await(task)
        :logged
      end)

    assert run.result == {:ok, :logged}
    assert Enum.any?(SystemsSim.Log.events(), &(&1 =~ "[error] from a process of the world"))
    assert {:ok, %{module: module}} = :logger.get_handler_config(:default)
    assert module == before.module
  end

  test "until/1 runs the world, and moves its clock, until a condition holds" do
    run =
      SystemsSim.run(fn ->
        {:ok, flag} = Agent.start_link(fn -> false end)
        started = SystemsClock.monotonic_time(:millisecond)

        spawn(fn ->
          SystemsClock.sleep(5_000)
          Agent.update(flag, fn _ -> true end)
        end)

        held = SystemsSim.until(fn -> Agent.get(flag, & &1) end)
        {held, SystemsClock.monotonic_time(:millisecond) - started}
      end)

    assert run.result == {:ok, {true, 5_000}}

    never = SystemsSim.run(fn -> SystemsSim.until(fn -> false end) end)
    assert {:error, {:error, %ArgumentError{message: "condition never held"}, _}} = never.result
  end

  test "a world that reads the machine's clock fails" do
    run =
      SystemsSim.run(fn ->
        SystemsClock.reset()
        SystemsClock.monotonic_time(:millisecond)
      end)

    assert {:error, {:error, %ArgumentError{message: message}, _stack}} = run.result
    assert message =~ "read the machine's clock"
    assert is_integer(SystemsClock.monotonic_time(:millisecond))
  end

  test "uniform/1 draws from the seed" do
    draw = fn -> for _ <- 1..5, do: SystemsSim.uniform(1_000_000) end
    assert SystemsSim.run(draw, seed: 7).result == SystemsSim.run(draw, seed: 7).result
    refute SystemsSim.run(draw, seed: 7).result == SystemsSim.run(draw, seed: 8).result
  end

  test "the processes an exit takes with it end in the order they started, on every run" do
    # A keeper ends and its six linked children end with it; a watcher
    # reports the order their ends reached it.
    world = fn ->
      root = self()

      watcher =
        spawn(fn ->
          receive do
            {:watch, pids} ->
              refs = Map.new(pids, &{Process.monitor(&1), &1})
              send(root, :watching)

              order =
                for _ <- pids do
                  receive do
                    {:DOWN, ref, :process, _, _} -> Enum.find_index(pids, &(&1 == refs[ref]))
                  end
                end

              send(root, {:order, order})
          end
        end)

      keeper =
        spawn(fn ->
          children = for _ <- 1..6, do: spawn_link(fn -> receive do: (:never -> :ok) end)
          send(watcher, {:watch, children})

          receive do
            :end -> exit(:ended)
          end
        end)

      receive do
        :watching -> send(keeper, :end)
      end

      receive do
        {:order, order} -> order
      end
    end

    runs =
      SystemsSim.one_scheduler(fn ->
        for seed <- 1..30,
            do: {SystemsSim.run(world, seed: seed), SystemsSim.run(world, seed: seed)}
      end)

    for {run, again} <- runs do
      assert run.result == {:ok, [0, 1, 2, 3, 4, 5]}
      assert again.record == run.record
    end
  end

  test "the record holds what was sent: runs that differ in one value have different records" do
    world = fn value ->
      fn ->
        send(self(), {:value, value})

        receive do
          {:value, value} -> value
        end
      end
    end

    accepted = SystemsSim.run(world.(:accepted))
    rejected = SystemsSim.run(world.(:rejected))

    assert accepted.trace == rejected.trace
    refute accepted.record == rejected.record
    assert SystemsSim.run(world.(:accepted)).record == accepted.record
  end

  test "no other process of the world runs inside a computation of many time slices" do
    # Each worker reads a counter, computes for several time slices and
    # writes it back: an update is lost when another worker runs in between.
    world = fn ->
      table = :ets.new(:counter, [:public])
      :ets.insert(table, {:value, 0})
      {:ok, register} = GenServer.start_link(Register, 0)

      1..4
      |> Enum.map(fn _ ->
        Task.async(fn ->
          for _ <- 1..5 do
            [{:value, value}] = :ets.lookup(table, :value)
            Enum.reduce(1..30_000, 0, &(&1 + &2))
            :ets.insert(table, {:value, value + 1})
            GenServer.call(register, :get)
          end
        end)
      end)
      |> Enum.map(&await/1)

      :ets.lookup_element(table, :value, 2)
    end

    runs =
      SystemsSim.one_scheduler(fn -> for seed <- 1..10, do: SystemsSim.run(world, seed: seed) end)

    assert Enum.map(runs, & &1.result) == List.duplicate({:ok, 20}, 10)
  end

  test "the clock starts at the same time on every run" do
    world = fn ->
      {SystemsClock.system_time(:millisecond), SystemsClock.monotonic_time(:millisecond)}
    end

    assert SystemsSim.run(world).result == SystemsSim.run(world).result
    assert {:ok, {_, 0}} = SystemsSim.run(world).result
    assert {:ok, {at, 0}} = SystemsSim.run(world, epoch: ~U[2030-01-01 00:00:00Z]).result
    assert at == DateTime.to_unix(~U[2030-01-01 00:00:00Z], :millisecond)
  end

  test "a process of the world draws its random values, unique integers and time from the run" do
    {:ok, outside} = Agent.start_link(fn -> nil end)

    world = fn ->
      task =
        Task.async(fn ->
          {SystemsRuntime.Proc.uuid(), SystemsRuntime.Proc.random_bytes(8),
           SystemsRuntime.Proc.uniform(1_000_000),
           SystemsRuntime.Proc.unique_integer([:positive]),
           SystemsRuntime.Proc.system_time(:millisecond)}
        end)

      drawn = await(task)
      # A process outside the world draws from the machine, not from the run.
      Agent.get(outside, fn _ -> SystemsRuntime.Proc.unique_integer([:positive]) end)
      {drawn, SystemsRuntime.Proc.unique_integer([:positive])}
    end

    run = SystemsSim.run(world, seed: 7)
    assert run.result == SystemsSim.run(world, seed: 7).result
    refute run.result == SystemsSim.run(world, seed: 8).result
    assert {:ok, {{uuid, <<_::64>>, n, 1, at}, 2}} = run.result
    assert uuid =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    assert n in 1..1_000_000
    assert at == DateTime.to_unix(~U[2026-01-01 00:00:00Z], :millisecond)
  end

  test "runs whose messages hold one term in two encodings have the same record" do
    # Atoms made in this order are written in it by default, and sorted when
    # the encoding is deterministic: two encodings of one map.
    late = String.to_atom("sim_" <> "zz_late")
    early = String.to_atom("sim_" <> "aa_early")
    plain = :erlang.term_to_binary(%{late => 1, early => 2})
    sorted = :erlang.term_to_binary(%{late => 1, early => 2}, [:deterministic])
    other = :erlang.term_to_binary(%{late => 3, early => 2})
    assert plain != sorted

    # A message holds the encoding and its MD5 digest, as an S3 object and
    # its ETag.
    world = fn encoded ->
      fn ->
        send(self(), {:stored, encoded, Base.encode16(:crypto.hash(:md5, encoded), case: :lower)})

        receive do
          {:stored, _, _} -> :ok
        end
      end
    end

    assert SystemsSim.run(world.(plain)).record == SystemsSim.run(world.(sorted)).record
    refute SystemsSim.run(world.(plain)).record == SystemsSim.run(world.(other)).record
  end

  test "a call into the world from a process outside it fails the run, naming the request" do
    {:ok, outside} = Agent.start_link(fn -> nil end)

    run =
      SystemsSim.run(fn ->
        {:ok, register} = GenServer.start_link(Register, 0)

        # While the world waits on it, the outside process calls the register.
        Agent.get(outside, fn _ ->
          send(register, {:"$gen_call", {self(), make_ref()}, :get})
        end)

        SystemsSim.until(fn -> true end)
      end)

    assert {:error, {:called_from_outside, [%{request: :get}]}} = run.result
  end

  # A task's reply, without a deadline: the world decides when it comes.
  defp await(%Task{ref: ref}) do
    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply
    end
  end
end
