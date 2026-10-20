defmodule SystemsSim do
  @moduledoc """
  Deterministic simulation for tests: runs a function and every process it
  starts one at a time, in an order chosen by a seed, so a concurrency failure
  found under one seed fails the same way every time that seed runs.

  ## The world

  `run/2` starts the function in a new process, the root of a *world*. Every
  process spawned from a process in the world joins it, before it runs its
  first instruction. Processes outside the world (application supervisors,
  database pools, the code server, the logger) keep running as usual.

  ## Scheduling

  Exactly one process of the world runs at a time. It runs until it waits in a
  `receive` that nothing in its mailbox matches, or exits. The scheduler then
  suspends it and picks the next process, among those whose mailbox grew
  since they last stopped, with a PRNG seeded by `:seed`. The order in which
  processes run, and so the order of every message between them, follows from
  the seed alone.

  Between two steps each process of the world takes in the signals it was
  sent, one process after another in the order they started, and a process
  that such a signal ends finishes ending before the next one is asked. So
  the processes an exit takes with it end in that order, at that step, on
  every run. No step waits for a real time to pass.

  A process waiting on a reply from outside the world (a call to a process
  outside it, a database query, an HTTP request, file or socket I/O, or the
  runtime, as `Process.alive?/1` on a process with a signal queued) keeps the
  turn until the reply arrives, so the world's calls to the outside are serial.
  A process that waits in a call, for a task or for a process it starts, and
  watches only processes of the world, gives the turn up even when its stack
  holds a database transaction open.

  The run sets the VM to one online scheduler, so no other process of the world
  can run on another core between two steps, and restores the count after.
  Tests that use it are `async: false`. The VM has two schedulers or more
  (`+S 2:1` and up): on a VM with one, ETS tables with `write_concurrency`
  keep their keys in another order, and a world that walks one takes other
  steps than on any other machine.

  ## Logs

  During a run, the node's default log handler is `SystemsSim.Log`, which
  keeps each event in the logging process instead of handing it to a process
  outside the world (`SystemsSim.Log.events/0`).

  ## Time

  `run/2` stops `SystemsClock` (`SystemsClock.manual/1`) at `:epoch`, the same
  time on every run, and a read of the machine's clock in the run fails it
  (`SystemsClock.require_manual/1`).
  When no process of the world has anything to do, the clock moves to the next
  timer, so a timeout, backoff or periodic job happens at once in real time, at
  the same clock time and step on every run.

  ## Randomness and the machine's clock

  A process in the world that draws through `SystemsRuntime.Proc` (random
  integers, floats, bytes and UUIDs, unique integers) gets the values from
  the run's seeded PRNG and a counter of the world, in the order the steps
  draw them; one that reads the machine's clock there reads the world's.
  Other sources (`:rand`, `:crypto`, `make_ref/0`) differ between runs; they
  are deterministic only if the code does not branch on them.

  ## The record

  A run's `record` lists its steps: the process that ran, every message it
  sent to a process of the world with its content, the processes it started,
  and the processes that ended with their reasons. Pids, references, ports
  and functions appear by the names the world gives them, so two runs of one
  seed have equal records. `check/2` compares them.

  ## What it does not control

  Messages that a process outside the world sends on its own (not as a reply),
  and timers armed with `Process.send_after/3` rather than `SystemsClock`,
  arrive at a real time. The world does not wait for them: a world whose
  processes all wait, with no timer of the world pending, is a deadlock. One
  that takes such a message in at different steps is reported by `check/2`,
  which runs a seed twice and compares the records. A call from a process
  outside the world to one of the world fails the run (`{:called_from_outside,
  calls}`), and so does a process of the world that runs without the turn
  (`{:ran_without_turn, processes}`).

  Receive timeouts inside OTP (a call's default 5 seconds, a supervisor's
  shutdown wait) are real times: a world must not depend on them expiring.

  While a process holds the turn, a process it sent an exit signal may end
  before the turn does or at its end, as the VM decides. The others see it
  ended either way; the sender itself does only if it looks without waiting.

  Pids and references differ between runs. Code that follows their order or
  their hash (a map of more than 32 pids walked in order) can take different
  steps; `check/2` reports it.
  """

  alias SystemsSim.Scheduler

  # The wall-clock time at which a world starts, unless `run/2` names one.
  @epoch ~U[2026-01-01 00:00:00Z]

  defmodule Run do
    @moduledoc "The outcome of one simulated run."
    @enforce_keys [:seed, :result, :steps, :trace, :record]
    defstruct [:seed, :result, :steps, :trace, :record]

    @type t :: %__MODULE__{
            seed: integer(),
            result: {:ok, term()} | {:error, term()},
            steps: non_neg_integer(),
            trace: [non_neg_integer() | {:clock, non_neg_integer()} | :idle_waiter],
            record: [term()]
          }
  end

  @doc """
  Runs `fun` in a new world under `seed` and returns the `Run`.

  The result is `{:ok, value}`, or `{:error, reason}` when `fun` raised, threw
  or exited, when the world deadlocked (every process waits and no timer is
  pending), or when it ran more than `:max_steps` steps.

  Options:

    * `:seed` - the PRNG seed (default 1).
    * `:epoch` - the UTC time at which the world's clock starts
      (default #{inspect(@epoch)}).
    * `:max_steps` - the step budget (default 100_000).
    * `:timeout` - real milliseconds the whole run may take (default 60_000).
  """
  @spec run((-> term()), keyword()) :: Run.t()
  def run(fun, opts \\ []) when is_function(fun, 0) do
    seed = Keyword.get(opts, :seed, 1)

    if :erlang.system_info(:schedulers) < 2,
      do:
        raise(
          ArgumentError,
          "a world runs on a VM with two schedulers or more (as ELIXIR_ERL_OPTIONS=\"+S 2:1\"): " <>
            "with one, ETS tables keep their keys in another order"
        )

    # Named once and left: between runs it hands every process the machine's
    # values. (Replacing or erasing a persistent term costs a pass over every
    # process of the node.)
    if :persistent_term.get({SystemsRuntime.Proc, :world}, nil) != __MODULE__,
      do: :persistent_term.put({SystemsRuntime.Proc, :world}, __MODULE__)

    one_scheduler(fn ->
      log = SystemsSim.Log.capture()

      try do
        :ok = SystemsClock.manual(epoch: Keyword.get(opts, :epoch, @epoch))
        :ok = SystemsClock.require_manual(true)
        run = Scheduler.run(fun, seed, opts)
        SystemsSim.Record.add(run)
        run
      after
        SystemsClock.require_manual(false)
        SystemsClock.reset()
        restore_hosted()
        SystemsSim.Log.release(log)
      end
    end)
  end

  @doc """
  Runs `fun` with one online scheduler, as `run/2` runs a world, and returns
  its result. Runs inside it keep that scheduler: taking schedulers offline and
  back waits for every scheduler thread, which a loaded machine runs late, so a
  test of many runs takes them offline once around all of them.
  """
  @spec one_scheduler((-> result)) :: result when result: term()
  def one_scheduler(fun) when is_function(fun, 0) do
    case :erlang.system_info(:schedulers_online) do
      1 ->
        fun.()

      _many ->
        schedulers = :erlang.system_flag(:schedulers_online, 1)

        try do
          fun.()
        after
          :erlang.system_flag(:schedulers_online, schedulers)
        end
    end
  end

  @doc """
  Runs `fun` under each seed and returns `:ok`, or raises at the first seed
  whose run fails `property`.

  `property` takes the `Run` and returns true when it holds; by default the
  run must return `{:ok, _}`. The first `:recheck` seeds (default 3) run twice
  and must take the same steps and return the same result; a difference means
  the run depends on something the seed does not control.

  The seeds are `:seeds` (default `1..100`). The environment variable
  `SYSTEMS_SIM_SEEDS=N` runs seeds `1..N` instead, and `SYSTEMS_SIM_SEED=S`
  runs only seed `S`, which reproduces a failure. Other options are those of
  `run/2`.
  """
  @spec check((-> term()), keyword()) :: :ok
  def check(fun, opts \\ []) do
    property = Keyword.get(opts, :property, &match?(%Run{result: {:ok, _}}, &1))
    recheck = Keyword.get(opts, :recheck, 3)

    one_scheduler(fn -> check_seeds(fun, opts, property, recheck) end)
  end

  defp check_seeds(fun, opts, property, recheck) do
    seeds(opts)
    |> Enum.with_index()
    |> Enum.each(fn {seed, i} ->
      run = run(fun, Keyword.put(opts, :seed, seed))

      if i < recheck do
        again = run(fun, Keyword.put(opts, :seed, seed))

        if {again.result, again.record} != {run.result, run.record} do
          raise SystemsSim.Nondeterministic, seed: seed, first: run, second: again
        end
      end

      unless property.(run), do: raise(SystemsSim.Failure, run: run)
    end)
  end

  defp seeds(opts) do
    cond do
      seed = System.get_env("SYSTEMS_SIM_SEED") -> [String.to_integer(seed)]
      count = System.get_env("SYSTEMS_SIM_SEEDS") -> 1..String.to_integer(count)
      true -> Keyword.get(opts, :seeds, 1..100)
    end
  end

  @doc """
  A random integer in `1..n` from the run's seeded PRNG. Called from a process
  in the world; anywhere else it is `:rand.uniform/1`.
  """
  @spec uniform(pos_integer()) :: pos_integer()
  def uniform(n) when is_integer(n) and n >= 1,
    do: draw({:uniform, n}, fn -> :rand.uniform(n) end)

  @doc false
  # `SystemsRuntime.Proc` asks this while a world runs: a process of the world
  # gets the world's value for `request`, any other process `machine`'s.
  def draw(request, machine) do
    with scheduler when is_pid(scheduler) <- :persistent_term.get(Scheduler, nil),
         {:tracer, ^scheduler} <- :erlang.trace_info(self(), :tracer) do
      case request do
        {:monotonic_time, unit} -> SystemsClock.monotonic_time(unit)
        {:system_time, unit} -> SystemsClock.system_time(unit)
        :uuid -> uuid(ask(scheduler, {:bytes, 16}))
        request -> ask(scheduler, request)
      end
    else
      _ -> machine.()
    end
  end

  defp ask(scheduler, request) do
    tag = make_ref()
    send(scheduler, {Scheduler, :draw, self(), tag, request})

    receive do
      {^tag, value} -> value
    end
  end

  # A version 4 UUID in its text form, from 16 bytes.
  defp uuid(<<a::48, _::4, b::12, _::2, c::62>>) do
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    Enum.join([p1, p2, p3, p4, p5], "-")
  end

  @doc """
  Kills `pid`, a process of the world, and returns once it is gone, so its
  links and monitors get the exit at the same step on every run. Called from
  a process in the world; outside a run it is `Process.exit(pid, :kill)`.
  (`Process.exit/2` takes effect at a real time.)
  """
  @spec kill(pid()) :: :ok
  def kill(pid) when is_pid(pid) do
    case Process.get(Scheduler) || :persistent_term.get(Scheduler, nil) do
      scheduler when is_pid(scheduler) ->
        tag = make_ref()
        send(scheduler, {Scheduler, :kill, self(), tag, pid})

        receive do
          {^tag, :ok} -> :ok
        end

      _ ->
        Process.exit(pid, :kill)
        :ok
    end
  end

  @doc """
  Moves children of the node's supervisors into the world, for the rest of
  the run: each `{supervisor, child_id}` is stopped under `supervisor` and
  started again, from its own child spec, under a supervisor of the calling
  process, a process of the world. Code that reaches the child by its
  registered name then reaches the world's instance, which the seed
  schedules. The children start in the order given, and are back under their
  own supervisors when the run ends. Returns the world's supervisor.

  The node's application processes start at boot, outside any world; this is
  how a simulation runs the application code under test inside it. Tests
  that use it run one world at a time (`async: false`).
  """
  @spec host([{Supervisor.supervisor(), term()}]) :: pid()
  def host(children) when is_list(children) do
    specs =
      for {supervisor, id} <- children do
        {:ok, spec} = :supervisor.get_childspec(supervisor, id)
        spec
      end

    # They stop as a supervisor stops them: the last one first.
    for {supervisor, id} <- Enum.reverse(children) do
      :ok = Supervisor.terminate_child(supervisor, id)
      :persistent_term.put({__MODULE__, :hosted}, [{supervisor, id} | hosted()])
    end

    {:ok, world} = Supervisor.start_link(specs, strategy: :one_for_one)
    world
  end

  defp hosted, do: :persistent_term.get({__MODULE__, :hosted}, [])

  # The world's processes are gone: the hosted children start again under
  # their own supervisors, in the reverse of the order they left.
  defp restore_hosted do
    for {supervisor, id} <- hosted() do
      case Supervisor.restart_child(supervisor, id) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, :running} -> :ok
      end
    end

    :persistent_term.erase({__MODULE__, :hosted})
    :ok
  end

  @doc """
  Runs the world until `fun` returns a truthy value, and returns it. Called
  from a process of the world, as a test's settle: `fun` is checked when no
  other process of the world has anything to do, and, while it does not hold,
  the clock moves to the next timer of the world and the world runs again.
  Raises when it does not hold and no timer is left.
  """
  @spec until((-> result)) :: result when result: term()
  def until(fun) when is_function(fun, 0), do: until(fun, false)

  defp until(fun, move?) do
    case when_idle(move?) do
      :idle when move? ->
        if held = fun.(), do: held, else: raise(ArgumentError, "condition never held")

      _idle_or_moved ->
        if held = fun.(), do: held, else: until(fun, true)
    end
  end

  # Waits until the rest of the world is idle, first moving the clock to the
  # next timer when `move?`; returns :moved when it did.
  defp when_idle(move?) do
    case Process.get(Scheduler) || :persistent_term.get(Scheduler, nil) do
      scheduler when is_pid(scheduler) ->
        tag = make_ref()
        send(scheduler, {Scheduler, :when_idle, self(), tag, move?})

        receive do
          {^tag, idle} -> idle
        end

      _ ->
        raise ArgumentError, "SystemsSim.until/1 runs in a world"
    end
  end

  @doc "Whether the calling process runs in a world."
  @spec simulated?() :: boolean()
  def simulated?, do: is_pid(:persistent_term.get(Scheduler, nil))
end

defmodule SystemsSim.Failure do
  @moduledoc "A seed whose run broke the property `SystemsSim.check/2` checks."
  defexception [:run]

  @impl true
  def message(%{run: run}) do
    """
    seed #{run.seed} failed after #{run.steps} steps: #{inspect(run.result, limit: 50, printable_limit: 500)}
    Reproduce with SYSTEMS_SIM_SEED=#{run.seed}.
    """
  end
end

defmodule SystemsSim.Nondeterministic do
  @moduledoc "A seed that took different steps on two runs."
  defexception [:seed, :first, :second]

  @impl true
  def message(%{seed: seed, first: a, second: b}) do
    at =
      Enum.zip(a.record, b.record)
      |> Enum.find_index(fn {x, y} -> x != y end)
      |> Kernel.||(min(length(a.record), length(b.record)))

    """
    seed #{seed} ran differently twice; the records part at entry #{at}.
    First: #{inspect(Enum.slice(a.record, max(at - 2, 0), 4), limit: 60)} -> #{inspect(a.result, limit: 20)}
    Second: #{inspect(Enum.slice(b.record, max(at - 2, 0), 4), limit: 60)} -> #{inspect(b.result, limit: 20)}
    Something outside the seed decided the order or a value: a message from
    outside the world, a real-time timer, or a random or unique value.
    """
  end
end
