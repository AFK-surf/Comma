defmodule SystemsClockCaseTest do
  use SystemsClock.Case, async: false

  defmodule Service do
    use Application

    # An unregistered tree with a dynamic child, as an application's own.
    def start(_type, _args) do
      {:ok, top} =
        Supervisor.start_link(
          [
            %{
              id: :dynamic,
              start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
              type: :supervisor
            }
          ],
          strategy: :one_for_one
        )

      [{:dynamic, dynamic, :supervisor, _modules}] = Supervisor.which_children(top)
      {:ok, _agent} = DynamicSupervisor.start_child(dynamic, {Agent, fn -> :service end})
      {:ok, top}
    end
  end

  defmodule Poller do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, nil, opts)

    @impl true
    def init(nil) do
      SystemsClock.send_after(self(), :poll, 1_000)
      {:ok, nil}
    end

    @impl true
    def handle_info(:poll, state) do
      SystemsClock.send_after(self(), :poll, 1_000)
      {:noreply, state}
    end
  end

  defmodule PollingService do
    use Application

    # Three pollers, as an application's own: one registered, one its
    # supervisor holds under an id, one a dynamic supervisor's child.
    def start(_type, _args) do
      {:ok, top} =
        Supervisor.start_link(
          [
            %{
              id: :registered,
              start: {Poller, :start_link, [[name: :systems_clock_case_poller]]}
            },
            %{id: :held, start: {Poller, :start_link, [[]]}},
            %{
              id: :dynamic,
              start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
              type: :supervisor
            }
          ],
          strategy: :one_for_one,
          name: :systems_clock_case_polling_supervisor
        )

      {:dynamic, dynamic, :supervisor, _modules} =
        List.keyfind(Supervisor.which_children(top), :dynamic, 0)

      {:ok, _poller} = DynamicSupervisor.start_child(dynamic, {Poller, []})
      {:ok, top}
    end
  end

  test "a service of the node that holds a timer and is not listed fails the next test, once" do
    :ok =
      :application.load(
        {:application, :systems_clock_case_polling,
         [
           description: ~c"SystemsClock.Case test service that polls",
           vsn: ~c"0.1.0",
           modules: [PollingService, Poller],
           registered: [:systems_clock_case_poller, :systems_clock_case_polling_supervisor],
           applications: [:kernel, :stdlib],
           mod: {PollingService, []}
         ]}
      )

    on_exit(fn ->
      Application.stop(:systems_clock_case_polling)
      Application.unload(:systems_clock_case_polling)
    end)

    # This test's own setup has checked the node as it was.
    assert SystemsClock.NodeTimers.check!() == :ok

    :ok = Application.start(:systems_clock_case_polling)

    error = assert_raise ArgumentError, fn -> SystemsClock.NodeTimers.check!() end

    assert error.message =~
             ":systems_clock_case_poller, armed in SystemsClockCaseTest.Poller.init/1"

    assert error.message =~
             "SystemsClockCaseTest.Poller, armed in SystemsClockCaseTest.Poller.init/1"

    assert length(String.split(error.message, "armed in")) == 3
    assert error.message =~ "systems/config/test.exs"

    assert SystemsClock.NodeTimers.check!() == :ok
  end

  test "a poller the test starts under its own supervisor is not a service of the node" do
    start_supervised!({Poller, [name: :systems_clock_case_poller]})
    assert SystemsClock.NodeTimers.check!() == :ok
  end

  # A server under a dynamic supervisor, another under a static one, and a
  # bare process, all started after `before`.
  test "the processes a test leaves are stopped, through their dynamic supervisor" do
    {:ok, dynamic} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, static} = Supervisor.start_link([], strategy: :one_for_one)
    Process.unlink(dynamic)
    Process.unlink(static)

    before = SystemsClock.Case.processes()

    {:ok, held} = DynamicSupervisor.start_child(dynamic, {Agent, fn -> :held end})

    {:ok, service} =
      Supervisor.start_child(static, %{
        id: :service,
        start: {Agent, :start_link, [fn -> :service end]}
      })

    bare = spawn(fn -> receive do: (:never -> :ok) end)

    stopped = SystemsClock.Case.stop_left(before)

    refute Process.alive?(held)
    refute Process.alive?(bare)
    assert Process.alive?(service)
    assert DynamicSupervisor.which_children(dynamic) == []
    assert length(stopped) == 2

    Supervisor.stop(static)
    DynamicSupervisor.stop(dynamic)
  end

  # Like a connection's ownership server, which checks the connection back in
  # when the test that owns it exits; the check-in runs on for 100,000
  # yields.
  test "a process still at work when the test ends finishes before the rest is stopped" do
    test = self()
    before = SystemsClock.Case.processes()
    owner = spawn(fn -> receive do: (:stop -> :ok) end)

    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:DOWN, ^ref, :process, ^owner, _reason} ->
          Enum.each(1..100_000, fn _ -> :erlang.yield() end)
          send(test, :checked_in)
      end
    end)

    send(owner, :stop)

    assert SystemsClock.Case.stop_left(before) == []
    assert_received :checked_in
  end

  test "an application the test starts is left running" do
    before = SystemsClock.Case.processes()

    :ok =
      :application.load(
        {:application, :systems_clock_case_service,
         [
           description: ~c"SystemsClock.Case test service",
           vsn: ~c"0.1.0",
           modules: [Service],
           registered: [],
           applications: [:kernel, :stdlib],
           mod: {Service, []}
         ]}
      )

    on_exit(fn ->
      Application.stop(:systems_clock_case_service)
      Application.unload(:systems_clock_case_service)
    end)

    :ok = Application.start(:systems_clock_case_service)
    {:ok, top} = :application.get_supervisor(:systems_clock_case_service)
    [{:dynamic, dynamic, :supervisor, _modules}] = Supervisor.which_children(top)
    [{:undefined, agent, :worker, _modules}] = DynamicSupervisor.which_children(dynamic)

    assert SystemsClock.Case.stop_left(before) == []
    assert Process.alive?(top) and Process.alive?(dynamic) and Process.alive?(agent)
  end

  defmodule EarlierProject do
    def project, do: [app: :systems_clock_case_earlier, version: "0.1.0", deps: []]
  end

  defmodule LaterProject do
    def project, do: [app: :systems_clock_case_later, version: "0.1.0", deps: []]
  end

  test "cleanup follows the current application when Mix moves to the next project" do
    app = :systems_clock_case_later

    :ok =
      :application.load(
        {:application, app,
         [
           description: ~c"SystemsClock.Case later project",
           vsn: ~c"0.1.0",
           modules: [Service],
           registered: [],
           applications: [:kernel, :stdlib],
           mod: {Service, []}
         ]}
      )

    on_exit(fn ->
      Application.stop(app)
      Application.unload(app)
    end)

    :ok = Application.start(app)
    {:ok, top} = :application.get_supervisor(app)
    [{:dynamic, dynamic, :supervisor, _}] = Supervisor.which_children(top)
    before = SystemsClock.Case.processes()
    {:ok, child} = DynamicSupervisor.start_child(dynamic, {Agent, fn -> :test_work end})
    assert :application.get_application(child) == {:ok, app}

    # The first project leaves another application's work alone.
    Mix.Project.push(EarlierProject)

    try do
      assert SystemsClock.Case.stop_left(before) == []
      assert Process.alive?(child)
    after
      Mix.Project.pop()
    end

    # The same VM then runs that application's tests.
    Mix.Project.push(LaterProject)

    try do
      assert length(SystemsClock.Case.stop_left(before)) == 1
      refute Process.alive?(child)
      assert Process.alive?(top) and Process.alive?(dynamic)
    after
      Mix.Project.pop()
    end
  end

  test "a server's end of a connection whose client end stays is left open" do
    test = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listener)
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    before = SystemsClock.Case.processes()

    # Like a web server's handler of a client library's pooled connection:
    # the test starts it, and the client's end stays with this process.
    handler =
      spawn(fn ->
        {:ok, _socket} = :gen_tcp.accept(listener)
        send(test, :accepted)
        receive do: (:never -> :ok)
      end)

    receive do: (:accepted -> :ok)

    assert SystemsClock.Case.stop_left(before) == []
    assert Process.alive?(handler)

    Process.exit(handler, :kill)
    :gen_tcp.close(client)
    :gen_tcp.close(listener)
  end

  # Like a web server's connection handler blocked mid-request: it does not
  # end on its supervisor's shutdown signal.
  defmodule Stubborn do
    def start_link do
      {:ok,
       :proc_lib.spawn_link(fn ->
         Process.flag(:trap_exit, true)
         ignore()
       end)}
    end

    defp ignore do
      receive do
        _any -> ignore()
      end
    end
  end

  test "a temporary child of a dynamic supervisor is killed, not shut down" do
    {:ok, dynamic} = DynamicSupervisor.start_link(strategy: :one_for_one)
    Process.unlink(dynamic)
    before = SystemsClock.Case.processes()

    {:ok, stubborn} =
      DynamicSupervisor.start_child(dynamic, %{
        id: :stubborn,
        start: {Stubborn, :start_link, []},
        restart: :temporary,
        shutdown: :infinity
      })

    assert length(SystemsClock.Case.stop_left(before)) == 1
    refute Process.alive?(stubborn)
    assert DynamicSupervisor.which_children(dynamic) == []

    DynamicSupervisor.stop(dynamic)
  end

  # A module keeps one clock across its tests (`SystemsClock.Test`): a reader
  # stopped in a read would leave the read under way on it.
  test "a clock's reader that a long-lived caller started is left to its caller" do
    test = self()

    caller =
      spawn(fn ->
        Stream.repeatedly(fn ->
          receive do
            :report ->
              SystemsClock.report()
              send(test, {:reader, Process.get({SystemsClock, :reader})})
          end
        end)
        |> Stream.run()
      end)

    SystemsClock.manual()
    on_exit(fn -> Process.exit(caller, :kill) end)
    before = SystemsClock.Case.processes()

    send(caller, :report)
    reader = receive(do: ({:reader, reader} -> reader))

    SystemsClock.Case.stop_left(before)
    assert Process.alive?(reader)
    SystemsClock.reset()
  end

  test "a dynamic supervisor's child that ends while it is being stopped leaves the supervisor running" do
    {:ok, dynamic} = DynamicSupervisor.start_link(strategy: :one_for_one)
    Process.unlink(dynamic)
    before = SystemsClock.Case.processes()

    {:ok, child} =
      DynamicSupervisor.start_child(dynamic, %{
        id: :child,
        start: {Stubborn, :start_link, []},
        restart: :temporary
      })

    # The child ends just after the supervisor has listed it.
    :sys.install(
      dynamic,
      {fn
         :armed, {:in, {:"$gen_call", _from, :which_children}}, _state ->
           ref = Process.monitor(child)
           Process.exit(child, :kill)
           receive do: ({:DOWN, ^ref, :process, ^child, _reason} -> :done)

         armed, _event, _state ->
           armed
       end, :armed}
    )

    SystemsClock.Case.stop_left(before)
    assert Process.alive?(dynamic)

    DynamicSupervisor.stop(dynamic)
  end
end
