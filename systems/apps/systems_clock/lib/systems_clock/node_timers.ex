defmodule SystemsClock.NodeTimers do
  @moduledoc """
  The services of the test node that hold a timer on `SystemsClock`.

  A process an application keeps running (a poller, a sweeper, a sampler)
  does its timed work beside every test of the node: when its timer fires it
  works in whatever test runs then, on the tables, buckets and processes that
  test uses. So the test node runs no timed work it has not been told about.
  With `config :systems_clock, node_timers: true` (the test configuration)
  the clock keeps each process that arms a timer through it, and `check!/0`,
  which `SystemsClock.Case` runs before every synchronous test, fails for a
  service among them that `priv/node_timers.exs` does not list.

  A service is a process in an application's supervision tree that is
  registered under a name, or that its supervisor holds under an id of its
  own: what `SystemsClock.Case` leaves running between tests. A process a
  test starts for itself is not one: under the test's own supervisor
  (`start_supervised!/1`) it is outside every application, and a dynamic
  supervisor's child ends with the test that started it.

  The answer does not depend on time: a process is kept from the first timer
  it arms, whether or not the timer has fired, and an application's worker
  arms its first one as it starts.
  """

  use GenServer

  @list_path Path.expand("../../priv/node_timers.exs", __DIR__)
  @external_resource @list_path
  @listed @list_path |> Code.eval_file() |> elem(0) |> Map.keys() |> MapSet.new()

  # Rows kept before the processes that have ended are taken out, where no
  # test does it (a node started with `mix run`).
  @sweep_every 4096

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # Owns the table and does nothing else. Rows: `{pid, where, checked?}` for
  # a process that armed a timer, `where` being the first place it did.
  @impl true
  def init(nil) do
    :ets.new(__MODULE__, [:named_table, :public, :set])
    {:ok, nil}
  end

  @doc false
  # The clock calls this in the process that arms a timer.
  def armed do
    with table when table != :undefined <- :ets.whereis(__MODULE__),
         false <- :ets.member(table, self()) do
      :ets.insert(table, {self(), armed_at(), false})
      if rem(:ets.info(table, :size), @sweep_every) == 0, do: sweep(table)
    end

    :ok
  end

  @doc """
  Fails when a service of the node holds a timer and is not listed. Each
  service fails one test: the first synchronous one after its first timer.
  """
  @spec check!() :: :ok
  def check! do
    case unlisted() do
      [] -> :ok
      services -> raise ArgumentError, message(services)
    end
  end

  @doc """
  The unlisted services that have armed a timer since the last call, as
  `{name, where}`.
  """
  @spec unlisted() :: [{atom(), {module(), atom(), arity()} | nil}]
  def unlisted do
    table =
      with :undefined <- :ets.whereis(__MODULE__) do
        raise ArgumentError,
              "SystemsClock.NodeTimers is not running: start the :systems_clock application " <>
                "before the tests (config :systems_clock, node_timers: true)"
      end

    sweep(table)

    for {pid, where, false} <- :ets.tab2list(table),
        :ets.update_element(table, pid, {3, true}),
        name = service(pid),
        not MapSet.member?(@listed, name),
        do: {name, where}
  end

  defp sweep(table) do
    for {pid, _where, _checked?} <- :ets.tab2list(table),
        not Process.alive?(pid),
        do: :ets.delete(table, pid)

    :ok
  end

  # The name of the service `pid` is, or nil.
  defp service(pid) do
    with {:ok, _app} <- :application.get_application(pid),
         [registered_name: name, dictionary: dictionary, initial_call: initial_call] <-
           Process.info(pid, [:registered_name, :dictionary, :initial_call]) do
      {module, _function, _arity} = Keyword.get(dictionary, :"$initial_call", initial_call)

      cond do
        is_atom(name) -> name
        own_child?(dictionary, pid) -> module
        true -> nil
      end
    else
      _ -> nil
    end
  end

  # Whether the supervisor that started `pid` holds it under an id of its own.
  defp own_child?(dictionary, pid) do
    parent =
      case Keyword.get(dictionary, :"$ancestors", []) do
        [name | _] when is_atom(name) -> Process.whereis(name)
        [parent | _] -> parent
        [] -> nil
      end

    is_pid(parent) and SystemsClock.Case.child_id(parent, pid) not in [nil, :undefined]
  end

  # Where the calling process arms its timer: the first frame outside the
  # clock.
  defp armed_at do
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

    case Enum.drop_while(stack, fn {module, _, _, _} ->
           module in [__MODULE__, SystemsClock, Process]
         end) do
      [{module, function, arity, _location} | _] -> {module, function, arity}
      [] -> nil
    end
  end

  defp message(services) do
    held =
      Enum.map_join(services, "\n", fn {name, where} ->
        "  #{inspect(name)}" <>
          case where do
            {module, function, arity} ->
              ", armed in #{Exception.format_mfa(module, function, arity)}"

            nil ->
              ""
          end
      end)

    """
    a service of the test node holds a timer on SystemsClock and is not listed:

    #{held}

    Its timed work runs beside every test of this node, on whatever the test \
    that runs then has written. Keep it from starting on the test node: give \
    its application a switch and turn it off in systems/config/test.exs (as \
    `config :salix_web, triage_effect_workers: false` does), and call its work \
    from the tests that need it, or start it there with `start_supervised!/1`, \
    which stops it with the test. systems/apps/systems_clock/priv/node_timers.exs \
    lists the services that held a timer before this check; it only loses entries.
    """
  end
end
