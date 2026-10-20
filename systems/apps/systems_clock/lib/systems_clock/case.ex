defmodule SystemsClock.Case do
  @moduledoc """
  `use SystemsClock.Case` in place of `use ExUnit.Case`, with the same
  options. A synchronous test does not leave work running into the next
  one: when it ends, after its own `on_exit` callbacks, the processes it
  started that are still alive are stopped and named in the test output.

  The processes first finish what they are doing (a connection's owner
  checks it back in after the test's exit): they are stopped once none of
  them runs. A process that a dynamic supervisor holds (an Agent server, a
  session, a task under a `Task.Supervisor`) is stopped through that
  supervisor, so it is not restarted; any other one is killed with the tree
  it heads. Registered processes, a supervisor's children under ids of their
  own, an application the test started or restarted, a dependency's
  processes and ExUnit's own are left alone: they are the node's long-lived
  services, restarted or started on first use.

  A synchronous test also fails, before it starts, when one of those services
  holds a timer on the clock that the node was not told about
  (`SystemsClock.NodeTimers`).
  """

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, unquote(opts)
      setup {SystemsClock.Case, :isolate}
    end
  end

  @node_timers Application.compile_env(:systems_clock, :node_timers, false)

  @doc """
  The `setup` callback of a case template: in a synchronous test, checks the
  node's timers and stops what the test leaves running when it ends.
  Concurrent tests share the node, so an asynchronous one is left as it is.
  """
  def isolate(%{async: true}), do: :ok

  def isolate(_context) do
    # No other test runs now: a service that holds a timer is the node's own.
    if @node_timers, do: SystemsClock.NodeTimers.check!()
    before = processes()
    ExUnit.Callbacks.on_exit({__MODULE__, :isolate}, fn -> stop_left(before) end)
  end

  @doc false
  # The node's processes, in pid order, for `stop_left/1`.
  def processes, do: :lists.sort(Process.list())

  # Real milliseconds the node gets to play out the end of a test (and the
  # stop of what it left) before what is left is taken as it is.
  @finish_ms 1_000

  # Checks of whether a process still runs that yield instead of sleeping.
  @finish_yields 100

  @doc false
  # The processes started since `before` (`processes/0`) and still alive,
  # stopped from the roots of their trees down; returns what was stopped, by
  # kind.
  def stop_left(before) do
    quiesce()
    own = own_applications()
    new = for pid <- started_since(processes(), before, []), pid != self(), do: pid
    infos = for pid <- new, info = left_info(pid), do: {pid, info}

    # An application the test started or restarted: its master is its own
    # group leader and the group leader of every process of its tree.
    masters = for {pid, %{module: :application_master}} <- infos, into: MapSet.new(), do: pid

    # A process that watches the test's exit callbacks (a connection one of
    # them checked out) ends with them.
    left =
      infos
      |> Enum.reject(fn {pid, info} ->
        MapSet.member?(masters, pid) or MapSet.member?(masters, info.group_leader) or
          {:process, self()} in info.monitors or not own?(pid, own)
      end)
      |> keep_connection_peers()
      |> Enum.sort_by(fn {_pid, info} -> length(info.ancestors) end)

    {stopped, _gone} =
      Enum.reduce(left, {[], MapSet.new()}, fn {pid, info}, {stopped, gone} ->
        cond do
          Enum.any?(info.ancestors, &MapSet.member?(gone, &1)) -> {stopped, MapSet.put(gone, pid)}
          stop(pid, info) -> {[info.kind | stopped], MapSet.put(gone, pid)}
          true -> {stopped, gone}
        end
      end)

    if stopped != [] do
      kinds =
        stopped
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_kind, count} -> -count end)
        |> Enum.map_join(", ", fn {kind, count} -> "#{count}x #{kind}" end)

      IO.puts("SystemsClock.Case stopped #{length(stopped)} processes the test left: #{kinds}")

      # What the stops set off (a registry dropping their names, a pool
      # whose owner they were) ends before the next test.
      quiesce()
    end

    stopped
  end

  # The processes of `now` not in `before` (both in pid order), in pid order.
  defp started_since([pid | now], [old | before], new) when pid > old,
    do: started_since([pid | now], before, new)

  defp started_since([pid | now], [pid | before], new), do: started_since(now, before, new)
  defp started_since([pid | now], before, new), do: started_since(now, before, [pid | new])
  defp started_since([], _before, new), do: Enum.reverse(new)

  # The two ends of a TCP connection in this VM stay or go together: the
  # server's handler of a pooled client connection that stays (an HTTP client
  # library's pool) is not stopped, or the next request on the connection
  # would find it closed.
  defp keep_connection_peers([]), do: []

  defp keep_connection_peers(left) do
    leaving = MapSet.new(left, &elem(&1, 0))
    ends = connection_ends()

    Enum.reject(left, fn {pid, _info} ->
      Enum.any?(ends, fn {{local, remote}, owner} ->
        owner == pid and
          case Map.fetch(ends, {remote, local}) do
            {:ok, peer} -> not MapSet.member?(leaving, peer)
            :error -> false
          end
      end)
    end)
  end

  # Each end of the TCP connections in this VM, by its own and its peer's
  # address, with the process that owns it.
  defp connection_ends do
    for port <- Port.list(),
        Port.info(port, :name) == {:name, ~c"tcp_inet"},
        {:ok, local} <- [:inet.sockname(port)],
        {:ok, remote} <- [:inet.peername(port)],
        {:connected, owner} <- [Port.info(port, :connected)],
        into: %{},
        do: {{local, remote}, owner}
  end

  # Waits until no process but this one runs or waits to run: what the
  # test's exit set off has played out (a connection's owner has checked it
  # back in, a pool whose owner exited has stopped). After @finish_ms real
  # milliseconds it names what still runs and returns.
  defp quiesce, do: quiesce(0, System.monotonic_time(:millisecond) + @finish_ms)

  defp quiesce(checks, deadline) do
    cond do
      not any_running?() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        IO.puts(
          "SystemsClock.Case: still running #{@finish_ms} ms after the test: " <>
            inspect(for pid <- running(), do: {pid, Process.info(pid, :current_function)})
        )

      checks < @finish_yields ->
        :erlang.yield()
        quiesce(checks + 1, deadline)

      true ->
        Process.sleep(1)
        quiesce(checks + 1, deadline)
    end
  end

  # Whether a process but this one runs or waits to run. The node's count of
  # them answers at once when it is this one alone; it also counts ports.
  defp any_running?,
    do: :erlang.statistics(:total_active_tasks_all) > 1 and Enum.any?(Process.list(), &running?/1)

  defp running, do: Enum.filter(Process.list(), &running?/1)

  defp running?(pid),
    do:
      pid != self() and
        Process.info(pid, :status) not in [nil, status: :waiting, status: :suspended]

  defp left_info(pid) do
    # Only the dictionary entries it needs: a whole dictionary can be large.
    with [
           {:registered_name, []},
           {:group_leader, group_leader},
           {:monitors, monitors},
           {{:dictionary, :"$initial_call"}, own_call},
           {{:dictionary, :"$ancestors"}, ancestors},
           {:initial_call, initial_call}
         ] <-
           Process.info(pid, [
             :registered_name,
             :group_leader,
             :monitors,
             {:dictionary, :"$initial_call"},
             {:dictionary, :"$ancestors"},
             :initial_call
           ]),
         {module, _function, _arity} = kind <-
           if(own_call == :undefined, do: initial_call, else: own_call),
         false <- String.starts_with?(Atom.to_string(module), "Elixir.ExUnit"),
         # A clock's reader ends with its caller. Stopped in a read, it would
         # leave the read counted as under way on a clock kept for the next
         # test (`SystemsClock.Test`), which then never finds the node quiet.
         false <- kind == {SystemsClock, :read_loop, 1} do
      ancestors = if ancestors == :undefined, do: [], else: Enum.map(ancestors, &whereis/1)

      %{
        kind: kind_name(kind),
        module: module,
        group_leader: group_leader,
        monitors: monitors,
        ancestors: ancestors,
        parent: List.first(ancestors)
      }
    else
      _ -> nil
    end
  end

  # Started by the test outside any application, or by one of this
  # repository's. A dependency's process (a database driver's type server, an
  # HTTP client's connection pool) is the library's to end.
  defp own?(pid, own) do
    case :application.get_application(pid) do
      {:ok, app} -> MapSet.member?(own, app)
      :undefined -> true
    end
  end

  defp own_applications do
    # Mix runs each umbrella application under its own project in the same VM.
    app = Mix.Project.config()[:app]
    key = {__MODULE__, :own_applications, app}

    with nil <- :persistent_term.get(key, nil) do
      deps = Mix.Project.deps_path() <> "/"

      own =
        for {dependency, path} <- Mix.Project.deps_paths(),
            not String.starts_with?(path, deps),
            into: MapSet.new([app]),
            do: dependency

      :persistent_term.put(key, own)
      own
    end
  end

  defp whereis(pid) when is_pid(pid), do: pid
  defp whereis(name) when is_atom(name), do: Process.whereis(name)
  defp whereis(_other), do: nil

  defp kind_name({module, function, arity}),
    do: inspect(Function.capture(module, function, arity))

  # A dynamic supervisor's child is killed when the supervisor does not restart
  # it (a temporary child, such as a web server's connection handler or a
  # task), and otherwise stopped through the supervisor, so it is not
  # restarted: a graceful stop waits for the child's shutdown timeout, which a
  # handler blocked mid-request runs out. A child a supervisor holds under an
  # id of its own is a service of the node and stays.
  defp stop(pid, %{parent: parent}) do
    case parent && child_id(parent, pid) do
      :undefined ->
        case restart(parent, pid) do
          :temporary -> kill(pid)
          nil -> false
          _restart -> terminate_child(parent, pid)
        end

      nil ->
        kill(pid)

      _id ->
        false
    end
  end

  # How `supervisor` (a `DynamicSupervisor` or a `simple_one_for_one`
  # supervisor) restarts its child `pid`, or nil when `pid` is no longer its
  # child: a child can end, and its supervisor with it, while the test's other
  # processes are stopped.
  defp restart(supervisor, pid) do
    case :sys.get_state(supervisor, 1_000) do
      %DynamicSupervisor{children: children} ->
        case children do
          %{^pid => {_start, restart, _shutdown, _type, _modules}} -> restart
          _children -> nil
        end

      _state ->
        case :supervisor.get_childspec(supervisor, pid) do
          {:ok, %{restart: restart}} -> restart
          {:error, _reason} -> nil
        end
    end
  catch
    :exit, _ -> nil
  end

  defp terminate_child(supervisor, pid) do
    DynamicSupervisor.terminate_child(supervisor, pid) == :ok
  catch
    :exit, _ -> false
  end

  @doc false
  # The id under which `supervisor` holds `pid` (`:undefined` for a dynamic
  # child), or nil when `supervisor` is not a supervisor holding it.
  def child_id(supervisor, pid) do
    with {:dictionary, dictionary} <- Process.info(supervisor, :dictionary),
         {:supervisor, _module, _arity} <- Keyword.get(dictionary, :"$initial_call") do
      supervisor
      |> Supervisor.which_children()
      |> Enum.find_value(fn {id, child, _type, _modules} -> if child == pid, do: id end)
    else
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> true
    end
  end
end
