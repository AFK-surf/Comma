defmodule SystemsSim.Case do
  @moduledoc """
  `use SystemsSim.Case` in place of `use ExUnit.Case`: each test runs in its
  own `SystemsSim` world, its `setup` blocks first and then its body, under
  the module's seed. The same commit and seed give the same run, so a test
  that passes or fails under a seed does so every time.

      use SystemsSim.Case, seed: 3, apps: [:my_app]

  Options:

    * `:seed` - the seed of each test's world (default 1). `SYSTEMS_SIM_SEED=S`
      in the environment runs the module under seed S instead, and
      `SYSTEMS_SIM_SEEDS=N` runs each test under seeds 1 to N, each in a new
      world, and names the seeds that fail.
    * `:reset` - functions run on the node before each world starts, which
      give it the same start whatever ran before: a database's baseline.
    * `:apps` - applications that run in each test's world, not on the node:
      they are stopped on the node while the module runs, and each world
      starts their supervision trees, in the order given. A test then finds
      the application as it starts, with nothing an earlier test left in it,
      and nothing of it runs between two tests.
    * `:env` - application configuration while the module runs, as
      `[app: [key: value]]`: what the worlds' applications start with, such
      as a service that is off because it would talk to a process of the
      machine outside the world.
    * `:quiet` - `{supervisor, child_id}` children of the node's supervisors
      stopped while the module runs, and not started in the worlds: pollers
      of other parts of the product that would call a service of the world
      by its name at a real time, which fails the run.
    * `:host` - `{supervisor, child_id}` children of the node's supervisors
      that run in each test's world instead: they are stopped on the node
      while the module runs, and each world starts them from their child
      specs before the `:apps`. A service of another application, such as a
      fake the application under test calls.
    * the other options of `SystemsSim.run/2`.

  `setup` blocks run in the world, in the order they are written, and what
  they return is merged into the context, as ExUnit's are. `setup_all` runs
  on the node, before any world. In the world, `start_supervised!/1` starts a
  child under a supervisor of the test's own, which ends with the world, and
  `on_exit/1` runs its function in the world when the body has returned.

  What the test's process may reach (the configuration bound for it, its
  database connections) the world's first process reaches too.

  A test whose world fails prints the seed.
  """

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, async: false
      import ExUnit.Case, except: [test: 2, test: 3]

      import ExUnit.Callbacks,
        except: [setup: 1, setup: 2, on_exit: 1, start_supervised!: 1, start_supervised!: 2]

      import SystemsSim.Case,
        only: [
          test: 2,
          test: 3,
          setup: 1,
          setup: 2,
          on_exit: 1,
          start_supervised!: 1,
          start_supervised!: 2
        ]

      Module.register_attribute(__MODULE__, :sim_setups, accumulate: true)
      @sim_opts unquote(opts)
      @moduletag :sim
      # The world's own limit (`:timeout`) stops a run that hangs.
      @moduletag timeout: :infinity
      ExUnit.Callbacks.setup_all(do: SystemsSim.Case.setup_module(@sim_opts))
      ExUnit.Callbacks.setup({SystemsClock.Case, :isolate})
    end
  end

  @doc false
  # The module's `:quiet` and `:host` children and its `:apps` leave the
  # node, its `:env` holds, and the node runs one scheduler, until its tests
  # are done. The `:host` children's specs reach each world in the context.
  def setup_module(opts) do
    apps = List.wrap(opts[:apps])
    quiet = List.wrap(opts[:quiet])
    host = List.wrap(opts[:host])

    specs =
      for {supervisor, id} <- host do
        {:ok, spec} = :supervisor.get_childspec(supervisor, id)
        spec
      end

    # They stop as a supervisor stops them: the last one first.
    for {supervisor, id} <- Enum.reverse(quiet ++ host),
        do: :ok = Supervisor.terminate_child(supervisor, id)

    for app <- Enum.reverse(apps), do: Application.stop(app)
    schedulers = :erlang.system_flag(:schedulers_online, 1)

    saved =
      for {app, pairs} <- Keyword.get(opts, :env, []), {key, value} <- pairs do
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end

    ExUnit.Callbacks.on_exit(fn ->
      for {app, key, old} <- saved do
        case old do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end

      :erlang.system_flag(:schedulers_online, schedulers)

      for {supervisor, id} <- host ++ quiet do
        case Supervisor.restart_child(supervisor, id) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, :running} -> :ok
        end
      end

      for app <- apps, do: {:ok, _} = Application.ensure_all_started(app)
    end)

    {:ok, sim_hosted: specs}
  end

  # An application's supervision tree, started in the world as its own
  # `start/2` starts it: it ends with the world.
  defp start_app(app) do
    {:ok, {module, args}} = :application.get_key(app, :mod)
    {:ok, _supervisor} = module.start(:normal, args)
  end

  @doc "A test whose setup and body run in a world (see the module)."
  defmacro test(name, context \\ quote(do: _), contents) do
    body = Keyword.fetch!(contents, :do)

    quote do
      ExUnit.Case.test unquote(name), context do
        setups =
          for {describe, setup} <- Enum.reverse(@sim_setups),
              describe in [nil, @ex_unit_describe],
              do: setup

        SystemsSim.Case.run!(__MODULE__, @sim_opts, context, setups, fn unquote(context) ->
          unquote(body)
        end)
      end
    end
  end

  @doc "ExUnit's `setup` in its forms; each runs in the test's world."
  defmacro setup(context, do: body) do
    name = :"__sim_setup_#{:erlang.unique_integer([:positive])}__"

    quote do
      @sim_setups {@ex_unit_describe, unquote(name)}
      def unquote(name)(unquote(context)), do: unquote(body)
    end
  end

  defmacro setup([do: _] = contents) do
    quote do: SystemsSim.Case.setup(_, unquote(contents))
  end

  defmacro setup(names) do
    context = Macro.var(:context, __MODULE__)

    for name <- List.wrap(names) do
      call =
        case name do
          {module, fun} -> quote(do: unquote(module).unquote(fun)(unquote(context)))
          fun when is_atom(fun) -> quote(do: unquote(fun)(unquote(context)))
        end

      quote do
        SystemsSim.Case.setup(unquote(context), do: unquote(call))
      end
    end
  end

  @doc "Starts `spec` under the test's supervisor, as ExUnit's `start_supervised!/2`."
  def start_supervised!(spec, overrides \\ []) do
    child = Supervisor.child_spec(spec, overrides)
    key = {__MODULE__, :supervisor}

    supervisor =
      Process.get(key) ||
        case Supervisor.start_link([], strategy: :one_for_one) do
          {:ok, pid} ->
            Process.put(key, pid)
            pid
        end

    case Supervisor.start_child(supervisor, child) do
      {:ok, pid} -> pid
      {:ok, pid, _info} -> pid
      other -> raise ArgumentError, "cannot start #{inspect(spec)}: #{inspect(other)}"
    end
  end

  @doc "Runs `fun` in the world when the test's body has returned, the last one first."
  def on_exit(fun) when is_function(fun, 0) do
    Process.put({__MODULE__, :on_exit}, [fun | Process.get({__MODULE__, :on_exit}, [])])
    :ok
  end

  @doc false
  def run!(module, opts, context, setups, body) do
    case seeds(opts) do
      [seed] ->
        with {:failed, seed, failure} <- run_seed(seed, module, opts, context, setups, body),
             do: fail!(seed, failure)

      seeds ->
        failed =
          for seed <- seeds,
              result = run_seed(seed, module, opts, context, setups, body),
              result != :ok,
              do: result

        case failed do
          [] ->
            :ok

          [{:failed, seed, failure} | _] ->
            IO.puts(
              "SystemsSim seeds that fail: #{inspect(for {:failed, s, _} <- failed, do: s)}"
            )

            fail!(seed, failure)
        end
    end
  end

  defp run_seed(seed, module, opts, context, setups, body) do
    test = self()
    for reset <- List.wrap(opts[:reset]), do: reset.()
    run = world(seed, test, module, opts, context, setups, body)

    case run.result do
      {:ok, :ok} -> :ok
      _failed -> {:failed, seed, run}
    end
  end

  defp world(seed, test, module, opts, context, setups, body) do
    SystemsSim.run(
      fn ->
        Process.put(:"$callers", [test | Process.get(:"$callers", [])])
        hosted = context[:sim_hosted] || []
        if hosted != [], do: {:ok, _} = Supervisor.start_link(hosted, strategy: :one_for_one)
        for app <- List.wrap(opts[:apps]), do: start_app(app)

        try do
          context =
            Enum.reduce(setups, context, fn setup, context ->
              Map.merge(context, setup_result(apply(module, setup, [context])))
            end)

          body.(context)
          :ok
        after
          for fun <- Process.get({__MODULE__, :on_exit}, []), do: fun.()
        end
      end,
      [seed: seed] ++ Keyword.drop(opts, [:seed, :host, :apps, :env, :reset, :quiet])
    )
  end

  defp fail!(seed, %SystemsSim.Run{result: {:error, {kind, reason, stack}}} = run)
       when kind in [:error, :exit, :throw] do
    IO.puts("SystemsSim seed #{seed}, #{run.steps} steps")
    :erlang.raise(kind, reason, stack)
  end

  defp fail!(seed, %SystemsSim.Run{result: {:error, reason}} = run) do
    ExUnit.Assertions.flunk(
      "SystemsSim seed #{seed}: the world stopped after #{run.steps} steps: " <>
        inspect(reason, pretty: true, limit: 120)
    )
  end

  # `SYSTEMS_SIM_SEED=S` runs each test under seed S, `SYSTEMS_SIM_SEEDS=N`
  # under seeds 1 to N, each in a new world; otherwise the module's seed.
  defp seeds(opts) do
    cond do
      seed = System.get_env("SYSTEMS_SIM_SEED") -> [String.to_integer(seed)]
      count = System.get_env("SYSTEMS_SIM_SEEDS") -> Enum.to_list(1..String.to_integer(count))
      true -> [Keyword.get(opts, :seed, 1)]
    end
  end

  defp setup_result(:ok), do: %{}
  defp setup_result({:ok, values}), do: Map.new(values)
  defp setup_result(values), do: Map.new(values)
end
