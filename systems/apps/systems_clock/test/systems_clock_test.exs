defmodule SystemsClockTest do
  use SystemsClock.Case, async: false

  # Processes whose initial call is in this module are the code under test of
  # a settle scoped to it.
  defmodule InScope do
    def start(fun), do: :proc_lib.spawn(__MODULE__, :run, [fun])
    def run(fun), do: fun.()
  end

  # A process that never stops running, outside that scope.
  defmodule Spinner do
    def start, do: :proc_lib.spawn(__MODULE__, :spin, [])
    def spin, do: spin()
  end

  defmodule SocketTraffic do
    def start(fun), do: :proc_lib.spawn(__MODULE__, :run, [fun])

    def run(fun) do
      receive do: (:go -> fun.())
    end

    def send_bytes(socket) do
      :ok = :gen_tcp.send(socket, :binary.copy("x", 65_536))
      send_bytes(socket)
    end

    def receive_bytes(socket) do
      {:ok, _} = :gen_tcp.recv(socket, 0)
      receive_bytes(socket)
    end

    # Lets `reader` go once `settler` has run up to `reductions`, or once the
    # clock has moved from `at`.
    def release_after(settler, reductions, at, reader) do
      {:reductions, now} = Process.info(settler, :reductions)

      if now >= reductions or SystemsClock.monotonic_time(:millisecond) != at do
        send(reader, :go)
      else
        :erlang.yield()
        release_after(settler, reductions, at, reader)
      end
    end
  end

  setup do
    on_exit(&SystemsClock.reset/0)
  end

  test "a sped-up clock fires timers and expires deadlines together" do
    SystemsClock.speed_up(100)
    deadline = SystemsClock.monotonic_time(:millisecond) + 3_000

    SystemsClock.send_after(self(), :fired, 3_000)
    assert_receive :fired

    assert SystemsClock.monotonic_time(:millisecond) >= deadline
  end

  test "sleeps and timeouts take clock time" do
    SystemsClock.speed_up(50)
    clock_before = SystemsClock.monotonic_time(:millisecond)

    SystemsClock.sleep(2_000)

    assert SystemsClock.monotonic_time(:millisecond) - clock_before >= 2_000
    assert SystemsClock.timeout(1_000) == 20
    assert SystemsClock.timeout(:infinity) == :infinity
  end

  test "reset returns to the real clock" do
    SystemsClock.speed_up(1_000)
    SystemsClock.sleep(5_000)

    SystemsClock.reset()

    assert SystemsClock.rate() == 1
    assert SystemsClock.timeout(250) == 250

    assert abs(SystemsClock.monotonic_time(:millisecond) - System.monotonic_time(:millisecond)) <
             50

    assert abs(SystemsClock.system_time(:millisecond) - System.system_time(:millisecond)) < 50
  end

  test "system time moves with the sped-up clock" do
    SystemsClock.speed_up(1_000)
    before = SystemsClock.system_time(:millisecond)

    SystemsClock.sleep(10_000)

    assert SystemsClock.system_time(:millisecond) - before >= 10_000
  end

  test "a manual clock moves only when advanced, and fires the timers that are then due" do
    SystemsClock.manual()
    deadline = SystemsClock.monotonic_time(:millisecond) + 1_000
    wall = SystemsClock.system_time(:millisecond)
    SystemsClock.send_after(self(), :late, 2_000)
    SystemsClock.send_after(self(), :early, 1_000)
    cancelled = SystemsClock.send_after(self(), :cancelled, 1_500)

    Process.sleep(20)
    assert SystemsClock.monotonic_time(:millisecond) < deadline
    assert SystemsClock.system_time(:millisecond) == wall
    assert SystemsClock.timeout(1_000) == :infinity
    assert SystemsClock.timeout(0) == 0
    refute_received _

    SystemsClock.advance(999)
    refute_received _
    assert SystemsClock.read_timer(cancelled) == 501
    assert SystemsClock.cancel_timer(cancelled) == 501

    SystemsClock.advance(1_001)
    assert SystemsClock.monotonic_time(:millisecond) == deadline + 1_000
    assert SystemsClock.system_time(:millisecond) == wall + 2_000
    assert {:messages, [:early, :late]} = Process.info(self(), :messages)
  end

  test "record timestamps on a manual clock keep write order on clock time alone" do
    SystemsClock.manual()
    now = SystemsClock.utc_now()
    assert SystemsClock.timestamp(:utc_datetime_usec) == now
    assert SystemsClock.timestamp(:utc_datetime_usec) == DateTime.add(now, 10, :microsecond)

    SystemsClock.advance(1)
    assert SystemsClock.timestamp(:utc_datetime_usec) == DateTime.add(now, 1, :millisecond)
  end

  test "start_timer on a manual clock sends its tagged timeout when advanced past" do
    SystemsClock.manual()
    ref = SystemsClock.start_timer(1_000, self(), :expired)
    cancelled = SystemsClock.start_timer(1_000, self(), :cancelled)
    assert SystemsClock.cancel_timer(cancelled) == 1_000

    SystemsClock.advance(999)
    refute_received _
    SystemsClock.advance(1)
    assert_received {:timeout, ^ref, :expired}
    refute_received {:timeout, _, :cancelled}
  end

  test "a sleep under a manual clock ends when the clock is advanced past it" do
    SystemsClock.manual()
    test = self()

    sleeper =
      spawn(fn ->
        SystemsClock.sleep(5_000)
        send(test, :woke)
      end)

    ref = Process.monitor(sleeper)
    SystemsClock.await_timers()
    SystemsClock.advance(4_999)
    refute_received :woke
    SystemsClock.advance(1)
    assert_receive :woke
    assert_receive {:DOWN, ^ref, :process, ^sleeper, :normal}
  end

  test "reset after a manual clock returns to the real clock" do
    SystemsClock.manual()
    SystemsClock.advance(60_000)

    SystemsClock.reset()

    assert SystemsClock.timeout(250) == 250

    assert abs(SystemsClock.monotonic_time(:millisecond) - System.monotonic_time(:millisecond)) <
             50
  end

  test "settle runs a backoff to completion at once, at exact clock times" do
    SystemsClock.manual()
    test = self()
    started = SystemsClock.monotonic_time(:millisecond)

    spawn(fn ->
      for delay <- [1_000, 2_000, 4_000] do
        SystemsClock.sleep(delay)
        send(test, {:retried, SystemsClock.monotonic_time(:millisecond) - started})
      end
    end)

    assert :done =
             SystemsClock.settle(
               until: fn ->
                 if Process.info(test, :message_queue_len) == {:message_queue_len, 3}, do: :done
               end
             )

    assert_received {:retried, 1_000}
    assert_received {:retried, 3_000}
    assert_received {:retried, 7_000}
  end

  test "settle without a condition stops once nothing is due" do
    SystemsClock.manual()
    test = self()
    spawn(fn -> send(test, {:echo, receive(do: (message -> message))}) end) |> send(:ping)

    assert :idle = SystemsClock.settle()
    assert_received {:echo, :ping}
  end

  test "a condition that never holds fails on clock time, not real time" do
    SystemsClock.manual(scope: ["Elixir.SystemsClockTest.InScope"])

    # A periodic job keeps a timer pending forever, as pollers do.
    poller =
      InScope.start(fn ->
        tick = fn tick ->
          SystemsClock.send_after(self(), :tick, 1_000)
          receive(do: (:tick -> tick.(tick)))
        end

        tick.(tick)
      end)

    on_exit(fn -> Process.exit(poller, :kill) end)

    assert_raise ArgumentError, ~r/never held/, fn ->
      SystemsClock.settle(until: fn -> false end, within: 60_000)
    end
  end

  # A read of a process's info not answered in time goes on in the reader
  # (suspended here, as by a loaded machine) after the clock is replaced.
  @tag timeout: 20_000
  test "a read answered after its clock ended does not hold the next clock" do
    SystemsClock.manual(scope: ["Elixir.SystemsClockTest.InScope"])

    waiter =
      InScope.start(fn ->
        Stream.repeatedly(fn -> receive(do: (_ -> :ok)) end) |> Stream.run()
      end)

    on_exit(fn -> Process.exit(waiter, :kill) end)

    assert :idle = SystemsClock.settle()
    reader = Process.get({SystemsClock, :reader})
    :erlang.suspend_process(reader)
    assert SystemsClock.report() =~ "UNANSWERED"

    SystemsClock.reset()
    SystemsClock.manual(scope: ["Elixir.SystemsClockTest.InScope"])
    :erlang.resume_process(reader)
    wait_drained(reader)

    send(waiter, :ran)
    assert :idle = SystemsClock.settle()
  end

  # A process of the node outlives a test whose end stopped the reader it
  # started.
  @tag timeout: 20_000
  test "a read sent to a stopped reader does not hold the next clock" do
    SystemsClock.manual(scope: ["Elixir.SystemsClockTest.InScope"])

    waiter =
      InScope.start(fn ->
        Stream.repeatedly(fn -> receive(do: (_ -> :ok)) end) |> Stream.run()
      end)

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

    on_exit(fn -> Enum.each([waiter, caller], &Process.exit(&1, :kill)) end)

    send(caller, :report)
    reader = receive(do: ({:reader, reader} -> reader))
    Process.exit(reader, :kill)

    SystemsClock.reset()
    SystemsClock.manual(scope: ["Elixir.SystemsClockTest.InScope"])
    send(caller, :report)
    receive(do: ({:reader, _reader} -> :ok))

    send(waiter, :ran)
    assert :idle = SystemsClock.settle()
  end

  defp wait_drained(pid) do
    case Process.info(pid, [:message_queue_len, :status]) do
      [message_queue_len: 0, status: :waiting] -> :ok
      _ -> wait_drained(pid)
    end
  end

  test "a receive timeout and a task yield expire on a manual clock" do
    require SystemsClock
    SystemsClock.manual()
    test = self()

    waiter =
      spawn(fn ->
        result =
          SystemsClock.vreceive do
            :never -> :received
          after
            5_000 -> :expired
          end

        send(test, {:waited, result})
      end)

    task = Task.async(fn -> receive(do: (:never -> :done)) end)

    assert {:waited, :expired} =
             SystemsClock.settle(
               until: fn ->
                 receive do
                   {:waited, _} = message -> message
                 after
                   0 -> nil
                 end
               end
             )

    assert Process.alive?(waiter) == false
    yielder = Task.async(fn -> SystemsClock.yield(task, 3_000) end)
    assert {:ok, nil} = SystemsClock.settle(until: fn -> Task.yield(yielder, 0) end)
    Task.shutdown(task, :brutal_kill)
  end

  test "the test that drives the clock moves it while it sleeps or calls a sleeping server" do
    SystemsClock.manual(drive: true)
    started = SystemsClock.monotonic_time(:millisecond)

    assert :ok = SystemsClock.sleep(2_000)
    assert SystemsClock.monotonic_time(:millisecond) - started == 2_000

    {:ok, server} =
      Agent.start_link(fn -> :ok end)

    assert :slept =
             Agent.get(
               server,
               fn _ ->
                 SystemsClock.sleep(5_000)
                 :slept
               end,
               :infinity
             )

    assert SystemsClock.monotonic_time(:millisecond) - started == 7_000
  end

  test "the driver moves the clock for a blocked test while a process outside the scope runs on" do
    SystemsClock.manual(drive: true, scope: ["Elixir.SystemsClockTest.InScope"])
    spinner = Spinner.start()
    on_exit(fn -> Process.exit(spinner, :kill) end)
    started = SystemsClock.monotonic_time(:millisecond)

    server =
      InScope.start(fn ->
        receive do
          {:"$gen_call", from, :sleep} ->
            SystemsClock.sleep(5_000)
            GenServer.reply(from, :slept)
        end
      end)

    assert :slept = GenServer.call(server, :sleep, :infinity)
    assert SystemsClock.monotonic_time(:millisecond) - started == 5_000
  end

  test "a scoped timer completes while unrelated socket traffic continues" do
    {client, server} = socket_pair()
    owner = self()
    sender = SocketTraffic.start(fn -> SocketTraffic.send_bytes(client) end)

    receiver =
      SocketTraffic.start(fn ->
        {:ok, _} = :gen_tcp.recv(server, 0)
        send(owner, :traffic_started)
        SocketTraffic.receive_bytes(server)
      end)

    :ok = :gen_tcp.controlling_process(client, sender)
    :ok = :gen_tcp.controlling_process(server, receiver)

    on_exit(fn ->
      Process.exit(sender, :kill)
      Process.exit(receiver, :kill)
    end)

    send(sender, :go)
    send(receiver, :go)
    receive do: (:traffic_started -> :ok)
    SystemsClock.manual(drive: true, scope: ["Elixir.SystemsClockTest.InScope"])
    started = SystemsClock.monotonic_time(:millisecond)

    InScope.start(fn ->
      SystemsClock.sleep(5_000)
      send(owner, :timer_fired)
    end)

    assert :fired =
             SystemsClock.settle(
               until: fn -> receive do: (:timer_fired -> :fired), after: (0 -> nil) end
             )

    assert SystemsClock.monotonic_time(:millisecond) - started == 5_000
    assert Process.alive?(sender) and Process.alive?(receiver)
  end

  for ownership <- [:caller, :outside_pool] do
    @tag socket_ownership: ownership
    test "a scoped reader receives a response with #{ownership} socket ownership", %{
      socket_ownership: ownership
    } do
      {client, server} = socket_pair()
      owner = self()

      socket_owner =
        if ownership == :outside_pool,
          do: SocketTraffic.start(fn -> receive do: (:stop -> :ok) end),
          else: owner

      responder =
        SocketTraffic.start(fn ->
          {:ok, "request"} = :gen_tcp.recv(server, 7)
          SystemsClock.sleep(1_000)
          :ok = :gen_tcp.send(server, "response")
          receive do: (:stop -> :ok)
        end)

      :ok = :gen_tcp.controlling_process(client, socket_owner)
      :ok = :gen_tcp.controlling_process(server, responder)

      on_exit(fn ->
        if socket_owner != owner, do: Process.exit(socket_owner, :kill)
        Process.exit(responder, :kill)
      end)

      if socket_owner != owner, do: send(socket_owner, :go)
      send(responder, :go)

      SystemsClock.manual(
        drive: ownership == :outside_pool,
        scope: ["Elixir.SystemsClockTest.InScope"]
      )

      started = SystemsClock.monotonic_time(:millisecond)

      InScope.start(fn ->
        :ok = :gen_tcp.send(client, "request")
        result = :gen_tcp.recv(client, 8)
        send(owner, {:response, result})
      end)

      assert {:ok, "response"} =
               SystemsClock.settle(
                 until: fn -> receive do: ({:response, result} -> result), after: (0 -> nil) end
               )

      assert SystemsClock.monotonic_time(:millisecond) - started == 1_000
    end
  end

  # A process outside the scope that moves bytes for one in it, as a TLS
  # connection process does for its user: it monitors the process it acts for
  # and writes to a socket whose reader has not taken the bytes yet.
  defmodule ByteAgent do
    def start(user, socket, bytes), do: :proc_lib.spawn(__MODULE__, :run, [user, socket, bytes])

    def run(user, socket, bytes) do
      Process.monitor(user)
      receive do: (:go -> :ok)
      :ok = :gen_tcp.send(socket, bytes)
      receive do: (:stop -> :ok)
    end
  end

  test "the clock does not move while an agent of a process in scope has bytes in flight" do
    {client, server} = socket_pair()
    owner = self()
    SystemsClock.manual(drive: true, scope: ["Elixir.SystemsClockTest.InScope"])
    started = SystemsClock.monotonic_time(:millisecond)

    user =
      InScope.start(fn ->
        SystemsClock.send_after(self(), :gave_up, 10_000)
        receive do: (:gave_up -> :ok)
      end)

    size = 16_777_216
    agent = ByteAgent.start(user, client, :binary.copy("x", size))
    :ok = :gen_tcp.controlling_process(client, agent)

    # The reader reads the clock while its last byte is still in flight: the
    # clock may move only once every byte has arrived.
    reader =
      SocketTraffic.start(fn ->
        {:ok, _bytes} = :gen_tcp.recv(server, size - 1)
        send(owner, {:read_at, SystemsClock.monotonic_time(:millisecond)})
        {:ok, _byte} = :gen_tcp.recv(server, 1)
        receive do: (:stop -> :ok)
      end)

    :ok = :gen_tcp.controlling_process(server, reader)

    on_exit(fn ->
      Process.exit(user, :kill)
      Process.exit(agent, :kill)
      Process.exit(reader, :kill)
    end)

    send(agent, :go)
    # The reader takes the bytes only once the settling test has worked long
    # enough for the clock to have looked many times (or the clock moved):
    # until then most of them stay queued in the agent's port.
    {:reductions, settling_from} = Process.info(owner, :reductions)

    releaser =
      SocketTraffic.start(fn ->
        SocketTraffic.release_after(owner, settling_from + 20_000_000, started, reader)
      end)

    send(releaser, :go)
    on_exit(fn -> Process.exit(releaser, :kill) end)

    read_at =
      SystemsClock.settle(until: fn -> receive do: ({:read_at, at} -> at), after: (0 -> nil) end)

    assert read_at == started
  end

  test "bytes in flight that never arrive fail the settle and name the socket" do
    previous = Application.get_env(:systems_clock, :stuck_in_flight_ms)
    Application.put_env(:systems_clock, :stuck_in_flight_ms, 200)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:systems_clock, :stuck_in_flight_ms, previous),
        else: Application.delete_env(:systems_clock, :stuck_in_flight_ms)
    end)

    {client, server} = socket_pair()
    owner = self()
    SystemsClock.manual(drive: true, scope: ["Elixir.SystemsClockTest.InScope"])

    user =
      InScope.start(fn ->
        result = receive do: (message when message in [:delivered] -> message)
        send(owner, {:result, result})
      end)

    agent = ByteAgent.start(user, client, :binary.copy("x", 16_777_216))
    :ok = :gen_tcp.controlling_process(client, agent)

    on_exit(fn ->
      Process.exit(agent, :kill)
      :gen_tcp.close(server)
    end)

    send(agent, :go)

    error =
      assert_raise RuntimeError, fn ->
        SystemsClock.settle(
          until: fn -> receive do: ({:result, result} -> result), after: (0 -> nil) end
        )
      end

    assert error.message =~ "never arrived"
    assert error.message =~ "SystemsClockTest.ByteAgent"
    {:ok, {_address, port}} = :inet.sockname(client)
    assert error.message =~ ":#{port} ->"
  end

  test "an agent of a process in scope with an idle socket does not hold the clock" do
    {client, server} = socket_pair()
    owner = self()
    SystemsClock.manual(drive: true, scope: ["Elixir.SystemsClockTest.InScope"])
    started = SystemsClock.monotonic_time(:millisecond)

    user =
      InScope.start(fn ->
        SystemsClock.send_after(self(), :gave_up, 10_000)
        result = receive do: (message when message in [:delivered, :gave_up] -> message)
        send(owner, {:result, result})
      end)

    agent = ByteAgent.start(user, client, "")
    :ok = :gen_tcp.controlling_process(client, agent)

    on_exit(fn ->
      Process.exit(agent, :kill)
      :gen_tcp.close(server)
    end)

    assert :gave_up =
             SystemsClock.settle(
               until: fn -> receive do: ({:result, result} -> result), after: (0 -> nil) end
             )

    assert SystemsClock.monotonic_time(:millisecond) - started == 10_000
  end

  defp socket_pair do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    {:ok, server} = :gen_tcp.accept(listener)
    :gen_tcp.close(listener)
    {client, server}
  end

  test "a server calling itself on the clock exits at once, as GenServer.call does" do
    defmodule SelfCaller do
      use GenServer
      def init(nil), do: {:ok, nil}

      def handle_call(:outer, _from, state) do
        result =
          try do
            SystemsClock.call(__MODULE__, :inner, 25_000)
          catch
            :exit, reason -> {:exit, reason}
          end

        {:reply, result, state}
      end
    end

    start_supervised!(%{
      id: SelfCaller,
      start: {GenServer, :start_link, [SelfCaller, nil, [name: SelfCaller]]}
    })

    SystemsClock.manual(drive: true)
    started = SystemsClock.monotonic_time(:millisecond)

    assert {:exit, {:calling_self, {GenServer, :call, [SelfCaller, :inner, 25_000]}}} =
             GenServer.call(SelfCaller, :outer, :infinity)

    assert SystemsClock.monotonic_time(:millisecond) == started
  end

  test "a bounded call returns its result, its failure, or times out on the clock" do
    SystemsClock.manual(drive: true)
    started = SystemsClock.monotonic_time(:millisecond)

    assert {:ok, 42} = SystemsClock.run_bounded(fn -> 42 end, 1_000)

    assert {:exit, {:error, %RuntimeError{}}} =
             SystemsClock.run_bounded(fn -> raise "down" end, 1_000)

    assert :timeout = SystemsClock.run_bounded(fn -> SystemsClock.sleep(5_000) end, 1_000)
    assert SystemsClock.monotonic_time(:millisecond) - started == 1_000
    refute_received {:EXIT, _, _}
  end

  test "a bounded native DNS lookup finishes before its virtual deadline" do
    {:ok, expected} = :inet_gethost_native.gethostbyname(~c"localhost")
    resolver = Process.whereis(:inet_gethost_native)
    test = self()

    # Hold the actual OTP resolver until its caller waits for the reply.
    # The controller is outside the clock; its work models a busy DNS helper.
    {controller, monitor} =
      spawn_monitor(fn ->
        true = :erlang.suspend_process(resolver)
        send(test, :resolver_held)

        try do
          receive do
            {:lookup, caller} ->
              wait_for_native_dns(caller)
              Enum.each(1..100_000, fn _ -> :erlang.yield() end)
          end
        after
          :erlang.resume_process(resolver)
        end
      end)

    on_exit(fn -> Process.exit(controller, :kill) end)
    receive do: (:resolver_held -> :ok)
    SystemsClock.manual(drive: true, ignore: [controller])
    started = SystemsClock.monotonic_time(:millisecond)

    result =
      SystemsClock.run_bounded(
        fn ->
          send(controller, {:lookup, self()})
          :inet_gethost_native.gethostbyname(~c"localhost")
        end,
        15_000
      )

    receive do
      {:DOWN, ^monitor, :process, ^controller, reason} -> assert reason == :normal
    end

    assert result == {:ok, {:ok, expected}}
    assert SystemsClock.monotonic_time(:millisecond) == started
  end

  defp wait_for_native_dns(pid) do
    case Process.info(pid, :current_function) do
      {:current_function, {:inet_gethost_native, :wait_reply, _}} ->
        :ok

      nil ->
        raise "lookup ended before its resolver replied"

      _ ->
        :erlang.yield()
        wait_for_native_dns(pid)
    end
  end

  test "a zero-span receive by the driving test takes what the settled system sent, at the same time" do
    require SystemsClock
    SystemsClock.manual(drive: true)
    started = SystemsClock.monotonic_time(:millisecond)
    test = self()
    spawn(fn -> SystemsClock.sleep(5_000) end)

    look = fn ->
      SystemsClock.vreceive do
        :sent -> :received
      after
        0 -> :empty
      end
    end

    assert :empty = look.()
    spawn(fn -> send(test, :sent) end)
    assert :received = look.()
    assert SystemsClock.monotonic_time(:millisecond) == started
  end

  test "a call to a server outside the scope is work under way, whatever else the caller monitors" do
    SystemsClock.manual(scope: ["Elixir.SystemsClockTest.InScope"])
    test = self()

    # Outside work the clock does not see, as a supervisor starting a child.
    server =
      spawn(fn ->
        receive do
          {:"$gen_call", from, :start_child} ->
            Process.sleep(20)
            GenServer.reply(from, :started)
        end
      end)

    # A pending timer the clock would jump to if the caller looked idle.
    sleeper = InScope.start(fn -> SystemsClock.sleep(10_000) end)

    caller =
      InScope.start(fn ->
        receive do
          :call ->
            Process.monitor(sleeper)
            reply = GenServer.call(server, :start_child, :infinity)
            send(test, {:replied, reply, SystemsClock.monotonic_time(:millisecond)})
        end
      end)

    # Observing an idle receive must not leave it classified as idle after
    # the same process starts waiting on outside work.
    assert :idle = SystemsClock.settle()
    assert :idle = SystemsClock.settle()
    send(caller, :call)

    started = SystemsClock.monotonic_time(:millisecond)

    assert {:replied, :started, at} =
             SystemsClock.settle(
               until: fn ->
                 receive do
                   {:replied, _, _} = message -> message
                 after
                   0 -> nil
                 end
               end
             )

    assert at == started
  end

  defp assert_real_clock do
    before = {System.monotonic_time(), System.system_time()}
    clock = {SystemsClock.monotonic_time(), SystemsClock.system_time()}
    later = {System.monotonic_time(), System.system_time()}
    assert elem(before, 0) <= elem(clock, 0) and elem(clock, 0) <= elem(later, 0)
    assert elem(before, 1) <= elem(clock, 1) and elem(clock, 1) <= elem(later, 1)
  end

  test "a process waiting for an outside program holds the clock until the program answers" do
    SystemsClock.manual()
    test = self()

    InScope.start(fn ->
      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          args: ["-c", "read line; sleep 0.3; echo answered"]
        ])

      SystemsClock.awaiting(:request)
      SystemsClock.send_after(self(), :deadline, 100)
      Port.command(port, "go\n")

      receive do
        {^port, {:data, _answer}} ->
          SystemsClock.replied(:request)
          send(test, {:answered, SystemsClock.monotonic_time(:millisecond)})

        :deadline ->
          send(test, :deadline)
      end
    end)

    started = SystemsClock.monotonic_time(:millisecond)

    SystemsClock.settle(
      scope: [Atom.to_string(InScope)],
      until: fn -> match?({:messages, [_ | _]}, Process.info(self(), :messages)) end
    )

    # Without the wait noted, the clock would have moved to the deadline
    # while the program was still running.
    assert_received {:answered, ^started}
  end

  test "a process backing off for a :global lock waits on the holder, which waits on the clock" do
    SystemsClock.manual()
    test = self()

    InScope.start(fn ->
      :global.trans({__MODULE__, self()}, fn ->
        send(test, :holding)
        SystemsClock.sleep(1_000)
      end)
    end)

    SystemsClock.settle(
      scope: [Atom.to_string(InScope)],
      until: fn -> match?({:messages, [_ | _]}, Process.info(self(), :messages)) end
    )

    assert_received :holding

    InScope.start(fn ->
      :global.trans({__MODULE__, self()}, fn ->
        send(test, {:taken, SystemsClock.monotonic_time(:millisecond)})
      end)
    end)

    started = SystemsClock.monotonic_time(:millisecond)

    # `:global.random_sleep/1` counts as outside work, as the Salix suites
    # list it: the clock still moves while the holder waits on it.
    SystemsClock.settle(
      scope: [Atom.to_string(InScope)],
      io: [{:global, :random_sleep}],
      until: fn -> match?({:messages, [_ | _]}, Process.info(self(), :messages)) end
    )

    assert_received {:taken, at}
    assert at >= started + 1_000
  end
end
