defmodule SystemsClock do
  @moduledoc """
  The clock that timers, sleeps, timeouts and deadlines read, so a test can
  control the time the code sees.

  Outside a test that changes it, every function is the BEAM primitive it
  names, after one `:persistent_term` read.

  A test can run the clock in one of two ways, and calls `reset/0` on exit:

    * `manual/0` stops the clock. Time read through this module moves only
      when the test calls `advance/1`, which fires the timers that are then
      due. Record timestamps (`timestamp/1`) are each later than the one
      before by at least 10 µs, so rows written at one clock time keep the
      order they were written in; through `SystemsRuntime.DbClock`, a test
      database's `now()` is the clock's time at its last move, or the last
      record timestamp before it when that is later. No time on a manual
      clock counts real time. A budget the code measures with this clock
      therefore never runs out
      because the machine is slow, and it runs out exactly when the test
      advances past it. `timeout/1` returns `:infinity` for a nonzero span:
      a `receive ... after` or `Task.yield/2` bound by the clock waits for its
      message, because only `send_after/4` and `sleep/1` can see an advance.

    * `speed_up/1` runs the clock `rate` times faster than real time. Every
      span given to this module in milliseconds (`send_after/3`, `sleep/1`,
      `timeout/1`) takes `rate` times less real time. Work outside the module
      (databases, sockets, other OS processes, plain `Process.sleep/1`) keeps
      real time, so a real millisecond counts as `rate` milliseconds of clock
      time: the result can depend on machine speed. Prefer `manual/0`.

  Deadlines stay consistent in both: a deadline computed from
  `monotonic_time/1` expires as a timer of the same span fires.

  The clock is global to the VM. Use it only in `async: false` tests.
  """

  @signal_patience_ms 2_000

  @key {__MODULE__, :clock}

  # In the test environment the clock keeps each process that arms a timer,
  # sleeps or bounds a wait through it (`SystemsClock.NodeTimers`), on the
  # machine's clock as on a manual one.
  @node_timers Application.compile_env(:systems_clock, :node_timers, false)

  @settle_defaults [
    within: 3_600_000,
    io: [
      DBConnection,
      Finch,
      Mint.HTTP1,
      Mint.HTTP2,
      Req.Request,
      :httpc,
      Redix,
      # A native DNS lookup waits for an OS helper, not for this clock.
      {:inet_gethost_native, :wait_reply},
      {:code_server, :call},
      {:erl_prim_loader, :request}
    ],
    ignore: [],
    scope: nil
  ]

  @typedoc "Milliseconds, or `:infinity`."
  @type span :: non_neg_integer() | :infinity

  @doc false
  # While a simulated world runs (`SystemsSim.run/2`), every read of time and
  # every timer must be on its manual clock: reading the machine's clock
  # there fails the run instead of making it depend on real time.
  def require_manual(required?) do
    if required?,
      do: :persistent_term.put({__MODULE__, :require_manual}, true),
      else: :persistent_term.erase({__MODULE__, :require_manual})

    :ok
  end

  defp machine! do
    if :persistent_term.get({__MODULE__, :require_manual}, false),
      do: raise(ArgumentError, "a simulated world read the machine's clock: no manual clock runs")
  end

  @doc "Monotonic time, as `System.monotonic_time/1`."
  @spec monotonic_time(System.time_unit()) :: integer()
  def monotonic_time(unit \\ :native) do
    clock_monotonic_time(unit)
  end

  defp clock_monotonic_time(unit) do
    case :persistent_term.get(@key, nil) do
      nil ->
        machine!()

        # ast-grep-ignore: ex-harness-real-clock -- no manual clock: the clock is the machine's (production)
        System.monotonic_time(unit)

      %{timers: _} = clock ->
        System.convert_time_unit(manual_monotonic(clock), :native, unit)

      clock ->
        System.convert_time_unit(virtual_monotonic(clock), :native, unit)
    end
  end

  @doc "System (wall) time, as `System.system_time/1`."
  @spec system_time(System.time_unit()) :: integer()
  def system_time(unit \\ :native) do
    clock_system_time(unit)
  end

  defp clock_system_time(unit) do
    case :persistent_term.get(@key, nil) do
      nil ->
        machine!()

        # ast-grep-ignore: ex-harness-real-clock -- no manual clock: the clock is the machine's (production)
        System.system_time(unit)

      %{timers: _} = clock ->
        System.convert_time_unit(clock.system + :atomics.get(clock.offset, 1), :native, unit)

      clock ->
        skew = virtual_monotonic(clock) - System.monotonic_time() - clock.monotonic_skew
        System.convert_time_unit(System.system_time() + skew, :native, unit)
    end
  end

  @doc "The current UTC time on the clock, as `DateTime.utc_now/0`."
  @spec utc_now() :: DateTime.t()
  def utc_now, do: DateTime.from_unix!(system_time(:microsecond), :microsecond)

  @doc """
  The time a database's `now()` returns: on a manual clock, the clock's time
  at its last move, or the last `timestamp/1` record time before it when that
  is later (`SystemsRuntime.DbClock` writes it to test databases); otherwise
  `utc_now/0`. An in-memory store answers SQL that reads `now()` with it.
  """
  @spec database_time() :: DateTime.t()
  def database_time do
    clock_database_time()
  end

  defp clock_database_time do
    case :persistent_term.get(@key, nil) do
      %{timers: _, database: database} ->
        DateTime.from_unix!(:atomics.get(database, 1), :microsecond)

      _ ->
        utc_now()
    end
  end

  @doc """
  The current time on the clock as an Ecto timestamp of `type`. Use it as a
  schema's timestamp generator:
  `@timestamps_opts [autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}]`.
  """
  @spec timestamp(:utc_datetime | :utc_datetime_usec | :naive_datetime | :naive_datetime_usec) ::
          DateTime.t() | NaiveDateTime.t()
  def timestamp(:utc_datetime_usec), do: record_time()
  def timestamp(:utc_datetime), do: DateTime.truncate(record_time(), :second)
  def timestamp(:naive_datetime_usec), do: DateTime.to_naive(record_time())

  def timestamp(:naive_datetime),
    do: record_time() |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)

  # Each record time is later than the one before it, by at least 10 µs:
  # records written while the clock barely moves still sort in the order they
  # were written instead of tying, with room for code that orders a batch by
  # adding microseconds to one record time.
  defp next_record_us(clock, at) do
    last = :atomics.get(clock.records, 1)
    next = max(at, last + 10)

    case :atomics.compare_exchange(clock.records, 1, last, next) do
      :ok -> next
      _ -> next_record_us(clock, at)
    end
  end

  defp record_time do
    clock_record_time()
  end

  defp clock_record_time do
    case :persistent_term.get(@key, nil) do
      %{timers: _} = clock ->
        clock
        |> next_record_us(instant_us(clock))
        |> DateTime.from_unix!(:microsecond)

      _ ->
        utc_now()
    end
  end

  @doc "Sends `message` to `dest` after `ms` clock milliseconds, as `Process.send_after/4`."
  @spec send_after(pid() | atom(), term(), non_neg_integer(), keyword()) :: reference()
  def send_after(dest, message, ms, opts \\ []) when is_integer(ms) and ms >= 0 do
    if @node_timers, do: SystemsClock.NodeTimers.armed()
    clock_send_after(dest, message, ms, opts)
  end

  defp clock_send_after(dest, message, ms, opts) do
    case :persistent_term.get(@key, nil) do
      %{timers: timers} = clock ->
        if Keyword.get(opts, :abs, false),
          do: raise(ArgumentError, "a manual clock has no absolute timers")

        arm(clock, timers, make_ref(), dest, message, ms)

      _ ->
        machine!()

        # ast-grep-ignore: ex-harness-real-clock -- no manual clock: a timer on the machine's clock (production)
        Process.send_after(dest, message, timeout(ms), opts)
    end
  end

  @doc """
  Sends `{:timeout, ref, message}` to `dest` after `ms` clock milliseconds and
  returns `ref`, as `:erlang.start_timer/3`. Cancel it with `cancel_timer/1`.
  """
  @spec start_timer(non_neg_integer(), pid() | atom(), term()) :: reference()
  def start_timer(ms, dest, message) when is_integer(ms) and ms >= 0 do
    if @node_timers, do: SystemsClock.NodeTimers.armed()
    clock_start_timer(ms, dest, message)
  end

  defp clock_start_timer(ms, dest, message) do
    case :persistent_term.get(@key, nil) do
      %{timers: timers} = clock ->
        ref = make_ref()
        arm(clock, timers, ref, dest, {:timeout, ref, message}, ms)

      _ ->
        machine!()

        # ast-grep-ignore: ex-harness-real-clock -- no manual clock: a timer on the machine's clock (production)
        :erlang.start_timer(timeout(ms), dest, message)
    end
  end

  defp arm(clock, timers, ref, dest, message, ms) do
    due = manual_monotonic(clock) + System.convert_time_unit(ms, :millisecond, :native)
    :ets.insert(timers, {ref, {due, System.unique_integer([:monotonic])}, dest, message})
    :atomics.add(clock.arms, 1, 1)
    note(clock, {:armed, dest, message, ms, armed_at()})
    send(clock.holder, :armed)
    if fires_here?(), do: fire_due(clock)
    ref
  end

  @doc false
  # Makes `pid` the only process that fires due timers (`nil` lifts it). A
  # `SystemsSim` scheduler holds this while it runs a world: a timer of a
  # process in the world is then delivered by the scheduler's own clock move,
  # never by another process arming a timer at a real time.
  def fire_only_from(nil) do
    :persistent_term.erase({__MODULE__, :firer})
    :ok
  end

  def fire_only_from(pid) when is_pid(pid) do
    :persistent_term.put({__MODULE__, :firer}, pid)
  end

  defp fires_here? do
    case :persistent_term.get({__MODULE__, :firer}, nil) do
      nil -> true
      pid -> pid == self()
    end
  end

  # Where a timer was armed: the first frame outside this module, so a
  # journal names the code that waits (a retry loop, a sleep) by its source.
  defp armed_at do
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

    case Enum.drop_while(stack, fn {module, _, _, _} -> module in [__MODULE__, Process] end) do
      [{module, function, arity, location} | _] ->
        {module, function, arity, location[:line]}

      [] ->
        nil
    end
  end

  @doc "Clock milliseconds left on a timer from `send_after/4`, as `Process.read_timer/1`."
  @spec read_timer(reference()) :: non_neg_integer() | false
  def read_timer(ref) do
    clock_read_timer(ref)
  end

  defp clock_read_timer(ref) do
    case :persistent_term.get(@key, nil) do
      %{timers: timers} = clock ->
        case :ets.lookup(timers, ref) do
          [{^ref, {due, _}, _, _}] -> left_ms(due, clock)
          [] -> false
        end

      _ ->
        case Process.read_timer(ref) do
          false -> false
          left -> left * rate()
        end
    end
  end

  @doc """
  Cancels a timer from `send_after/4`, as `Process.cancel_timer/1`, and returns
  the clock milliseconds it had left.
  """
  @spec cancel_timer(reference()) :: non_neg_integer() | false
  def cancel_timer(nil), do: false

  def cancel_timer(ref) do
    clock_cancel_timer(ref)
  end

  defp clock_cancel_timer(ref) do
    case :persistent_term.get(@key, nil) do
      %{timers: timers} = clock ->
        case :ets.take(timers, ref) do
          [{^ref, {due, _}, _, _}] -> left_ms(due, clock)
          [] -> false
        end

      _ ->
        case Process.cancel_timer(ref) do
          false -> false
          left -> left * rate()
        end
    end
  end

  @doc "Sleeps `ms` clock milliseconds, as `Process.sleep/1`."
  @spec sleep(span()) :: :ok
  def sleep(:infinity) do
    # ast-grep-ignore: ex-harness-real-clock -- a sleep without end waits for no clock
    Process.sleep(:infinity)
  end

  def sleep(ms) do
    if @node_timers, do: SystemsClock.NodeTimers.armed()
    clock_sleep(ms)
  end

  defp clock_sleep(ms) do
    case :persistent_term.get(@key, nil) do
      %{timers: _} = clock ->
        tag = make_ref()
        send_after(self(), {__MODULE__, :slept, tag}, ms)

        if clock.owner == self() do
          settle(
            until: fn ->
              receive do
                {__MODULE__, :slept, ^tag} -> :ok
              after
                0 -> nil
              end
            end,
            within: ms
          )
        else
          receive do
            {__MODULE__, :slept, ^tag} -> :ok
          end
        end

      _ ->
        machine!()

        # ast-grep-ignore: ex-harness-real-clock -- no manual clock: a sleep on the machine's clock (production)
        Process.sleep(timeout(ms))
    end
  end

  @doc """
  The real milliseconds that `ms` clock milliseconds take now. Pass a timeout
  through it where it is given to the BEAM: `receive ... after`, `Task.yield/2`,
  `GenServer.call/3`, an HTTP client's receive timeout. Under a manual clock a
  nonzero span never elapses on its own, so it is `:infinity`.
  """
  @spec timeout(span()) :: span()
  def timeout(:infinity), do: :infinity
  def timeout(0), do: 0

  def timeout(ms) when is_integer(ms) and ms > 0 do
    clock_timeout(ms)
  end

  defp clock_timeout(ms) do
    case :persistent_term.get(@key, nil) do
      nil -> ms
      %{timers: _} -> :infinity
      %{rate: 1} -> ms
      %{rate: rate} -> div(ms + rate - 1, rate)
    end
  end

  @doc """
  Notes that the calling process waits under `key` for an answer from
  outside the VM: a program it sent a request to over a port, whose answer
  comes as a message. Until `replied/1` with the same key, or until the
  process exits, a manual clock counts the process as busy and does not move
  while it settles, so the answer comes at the same clock time however long
  the program takes. (A wait inside a call to a client listed in
  `settle/1`'s `:io`, such as a database query, is seen without it.) Outside
  a manual clock it does nothing.
  """
  @spec awaiting(term()) :: :ok
  def awaiting(key) do
    clock_awaiting(key)
  end

  defp clock_awaiting(key) do
    with %{timers: timers} <- :persistent_term.get(@key, nil),
         keys = awaiting_keys(timers),
         false <- MapSet.member?(keys, key) do
      Process.put({__MODULE__, :awaiting}, {timers, MapSet.put(keys, key)})
      row = {__MODULE__.Awaiting, self()}
      :ets.update_counter(timers, row, 1, {row, 0})
    end

    :ok
  end

  @doc "Ends a wait noted with `awaiting/1`; a key not waited on is ignored."
  @spec replied(term()) :: :ok
  def replied(key) do
    clock_replied(key)
  end

  defp clock_replied(key) do
    with %{timers: timers} <- :persistent_term.get(@key, nil),
         keys = awaiting_keys(timers),
         true <- MapSet.member?(keys, key) do
      Process.put({__MODULE__, :awaiting}, {timers, MapSet.delete(keys, key)})
      :ets.update_counter(timers, {__MODULE__.Awaiting, self()}, -1)
    end

    :ok
  end

  # The keys the calling process waits on under this clock (a key noted
  # under a clock since reset does not count).
  defp awaiting_keys(timers) do
    case Process.get({__MODULE__, :awaiting}) do
      {^timers, keys} -> keys
      _ -> MapSet.new()
    end
  end

  defp awaiting?(pid) do
    case :persistent_term.get(@key, nil) do
      %{timers: timers} ->
        match?([{_row, count}] when count > 0, :ets.lookup(timers, {__MODULE__.Awaiting, pid}))

      _ ->
        false
    end
  end

  @doc """
  `Task.yield/2` on the clock: under a manual clock the wait ends when the
  clock passes `ms`, not after real time.
  """
  @spec yield(Task.t(), timeout()) :: {:ok, term()} | {:exit, term()} | nil
  def yield(%Task{} = task, ms) do
    if @node_timers and is_integer(ms) and ms > 0, do: SystemsClock.NodeTimers.armed()
    clock_yield(task, ms)
  end

  defp clock_yield(%Task{ref: ref} = task, ms) do
    case :persistent_term.get(@key, nil) do
      %{timers: _} = clock when is_integer(ms) and ms > 0 ->
        tag = make_ref()
        timer = send_after(self(), {__MODULE__, :expired, tag}, ms)

        await = fn after_ms ->
          receive do
            {^ref, reply} ->
              cancel_timer(timer)
              Process.demonitor(ref, [:flush])
              {:done, {:ok, reply}}

            {:DOWN, ^ref, _, _, reason} ->
              cancel_timer(timer)
              {:done, {:exit, reason}}

            {__MODULE__, :expired, ^tag} ->
              {:done, nil}
          after
            after_ms -> nil
          end
        end

        {:done, result} =
          if clock.owner == self(),
            do: settle(until: fn -> await.(0) end, within: ms),
            else: await.(:infinity)

        result

      _ ->
        Task.yield(task, timeout(ms))
    end
  end

  @doc """
  `receive` whose `after` span runs on the clock. Under a manual clock the
  `after` clause runs when the clock passes the span; otherwise it is the
  BEAM's own timeout. Write it as `receive`, with one `after span -> body`.
  """
  defmacro vreceive(do: clauses, after: [{:->, _, [[span], after_body]}]) do
    tag = Macro.var(:systems_clock_tag, __MODULE__)
    timer = Macro.var(:systems_clock_timer, __MODULE__)

    disarmed =
      Enum.map(clauses, fn {:->, meta, [head, body]} ->
        {:->, meta,
         [
           head,
           quote(
             do:
               (
                 SystemsClock.cancel_timer(unquote(timer))
                 unquote(body)
               )
           )
         ]}
      end)

    expired =
      hd(
        quote do
          {SystemsClock, :expired, ^unquote(tag)} -> unquote(after_body)
        end
      )

    # The test that drives a manual clock cannot wait for a timer only it can
    # move: it settles instead, taking the first message the receive matches.
    driven =
      Enum.map([expired | disarmed], fn {:->, meta, [head, body]} ->
        {:->, meta, [head, {:done, body}]}
      end)

    quote do
      # The BEAM's own receive. Keep it
      # inline in the caller's function, in this shape: run through a fun
      # (#3253), a script run's wait under a manual clock never ended
      # (round_runtime_test, async script.run). Why is not established.
      span = unquote(span)
      unquote(tag) = make_ref()
      unquote(timer) = SystemsClock.arm_expiry(unquote(tag), span)

      # A zero span only takes what has arrived: the driving test settles the
      # system without moving the clock, then looks once. No expiry is armed
      # for it, so settling until one fired would never end.
      if SystemsClock.drives?() and span == 0, do: SystemsClock.run_for(0)

      if SystemsClock.drives?() and span != 0 do
        {:done, result} =
          SystemsClock.settle(
            until: fn ->
              receive do
                unquote(driven)
              after
                0 -> nil
              end
            end,
            within: SystemsClock.settle_span(span)
          )

        result
      else
        receive do
          unquote([expired | disarmed])
        after
          SystemsClock.timeout(span) -> unquote(after_body)
        end
      end
    end
  end

  @doc false
  def drives? do
    clock_drives?()
  end

  defp clock_drives? do
    case :persistent_term.get(@key, nil) do
      %{owner: owner} when is_pid(owner) -> owner == self()
      _ -> false
    end
  end

  @doc false
  def settle_span(span) when is_integer(span), do: span
  def settle_span(_), do: 3_600_000

  @doc false
  def arm_expiry(tag, span) do
    if @node_timers and is_integer(span) and span > 0, do: SystemsClock.NodeTimers.armed()
    clock_arm_expiry(tag, span)
  end

  defp clock_arm_expiry(tag, span) do
    case :persistent_term.get(@key, nil) do
      %{timers: _} when is_integer(span) and span > 0 ->
        send_after(self(), {__MODULE__, :expired, tag}, span)

      _ ->
        nil
    end
  end

  @doc """
  Records that a signal from outside the node is on its way, such as a
  Postgres notification after a commit: under a manual clock the system is
  not idle until `signal_arrived/1` with the same key. Without a manual clock
  it does nothing. A signal that never arrives stops counting after
  #{@signal_patience_ms} real milliseconds, so a lost one cannot hold a test.
  """
  @spec expect_signal(term()) :: :ok
  def expect_signal(key) do
    clock_expect_signal(key)
  end

  defp clock_expect_signal(key) do
    case :persistent_term.get(@key, nil) do
      %{timers: timers} = clock ->
        now = System.monotonic_time(:millisecond)
        :ets.update_counter(timers, {:signal, key}, {2, 1}, {{:signal, key}, 0, now})
        :ets.update_element(timers, {:signal, key}, {3, now})
        note(clock, {:signal_expected, key})
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Records that a signal `expect_signal/1` announced has arrived."
  @spec signal_arrived(term()) :: :ok
  def signal_arrived(key) do
    clock_signal_arrived(key)
  end

  defp clock_signal_arrived(key) do
    case :persistent_term.get(@key, nil) do
      %{timers: timers} = clock ->
        :ets.update_counter(timers, {:signal, key}, {2, -1, 0, 0}, {{:signal, key}, 0, 0})
        note(clock, {:signal_arrived, key})
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp signals_pending? do
    case :persistent_term.get(@key, nil) do
      %{timers: timers} ->
        oldest = System.monotonic_time(:millisecond) - @signal_patience_ms

        :ets.select_count(timers, [
          {{{:signal, :_}, :"$1", :"$2"}, [{:>, :"$1", 0}, {:>, :"$2", oldest}], [true]}
        ]) > 0

      _ ->
        false
    end
  rescue
    ArgumentError -> false
  end

  @doc """
  `GenServer.call/3` whose timeout runs on the clock: under a manual clock the
  call exits with `:timeout` when the clock passes `ms`, as a busy or
  suspended server would make it on the real clock.
  """
  @spec call(GenServer.server(), term(), timeout()) :: term()
  def call(server, request, ms) do
    clock_call(server, request, ms)
  end

  defp clock_call(server, request, ms) do
    case :persistent_term.get(@key, nil) do
      # A server calling itself exits at once, as `GenServer.call/3` does:
      # the request would wait in its own mailbox until the timeout.
      %{timers: _} when is_integer(ms) ->
        if GenServer.whereis(server) == self(),
          do: exit({:calling_self, {GenServer, :call, [server, request, ms]}})

        request_id = :gen_server.send_request(server, request)

        vreceive do
          {[:alias | ^request_id], reply} ->
            Process.demonitor(request_id, [:flush])
            reply

          {:DOWN, ^request_id, _, _, reason} ->
            exit({reason, {GenServer, :call, [server, request, ms]}})
        after
          ms ->
            Process.demonitor(request_id, [:flush])
            exit({:timeout, {GenServer, :call, [server, request, ms]}})
        end

      _ ->
        GenServer.call(server, request, ms)
    end
  end

  @doc """
  `Task.async_stream/3` whose per-task `:timeout` runs on the clock: under a
  manual clock a task times out when the clock passes it, as `run_bounded/2`
  bounds it; `:on_timeout` keeps its meaning.
  """
  @spec async_stream(Enumerable.t(), (term() -> term()), keyword()) :: Enumerable.t()
  def async_stream(enumerable, fun, opts \\ []) do
    clock_async_stream(enumerable, fun, opts)
  end

  defp clock_async_stream(enumerable, fun, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    case :persistent_term.get(@key, nil) do
      %{timers: _} when is_integer(timeout) ->
        on_timeout = Keyword.get(opts, :on_timeout, :exit)

        bounded = fn item ->
          case run_bounded(fn -> fun.(item) end, timeout) do
            {:ok, result} ->
              {:ok, result}

            {:exit, {kind, reason}} when kind in [:error, :exit, :throw] ->
              :erlang.raise(kind, reason, [])

            {:exit, reason} ->
              exit(reason)

            :timeout ->
              :timeout
          end
        end

        enumerable
        |> Task.async_stream(bounded, Keyword.put(opts, :timeout, :infinity))
        |> Stream.map(fn
          {:ok, {:ok, result}} -> {:ok, result}
          {:ok, :timeout} when on_timeout == :kill_task -> {:exit, :timeout}
          {:ok, :timeout} -> exit({:timeout, {Task.Supervised, :stream, [timeout]}})
          other -> other
        end)

      _ ->
        Task.async_stream(enumerable, fun, opts)
    end
  end

  @doc """
  Runs `fun` in a new process and waits `ms` clock milliseconds for its
  result: `{:ok, result}`, `{:exit, reason}` when it fails, or `:timeout`, after
  which the process is killed. The process is monitored, not linked, so the
  caller sees no exit signal whatever happens. Use it to bound a call to an
  outside service on this clock, so a test's clock can expire it.
  """
  @spec run_bounded((-> term()), non_neg_integer()) :: {:ok, term()} | {:exit, term()} | :timeout
  def run_bounded(fun, ms) when is_function(fun, 0) and is_integer(ms) and ms >= 0 do
    clock_run_bounded(fun, ms)
  end

  defp clock_run_bounded(fun, ms) do
    caller = self()
    callers = [caller | Process.get(:"$callers", [])]

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)

        result =
          try do
            {:ok, fun.()}
          catch
            kind, reason -> {:exit, {kind, reason}}
          end

        send(caller, {__MODULE__, self(), result})
      end)

    result =
      vreceive do
        {__MODULE__, ^pid, result} -> result
        {:DOWN, ^ref, :process, ^pid, reason} -> {:exit, reason}
      after
        ms -> :timeout
      end

    Process.demonitor(ref, [:flush])

    if result == :timeout do
      Process.exit(pid, :kill)

      receive do
        {__MODULE__, ^pid, _} -> :ok
      after
        0 -> :ok
      end
    end

    result
  end

  @doc "How many times faster than real time the clock runs (1 outside a sped-up test)."
  @spec rate() :: pos_integer()
  def rate do
    clock_rate()
  end

  defp clock_rate do
    case :persistent_term.get(@key, nil) do
      %{rate: rate} -> rate
      _ -> 1
    end
  end

  # Code loads on first use. A process loading a module runs code the clock
  # does not see, and a process the test suspends mid-load holds every other
  # caller of that module; once per node, before any clock runs, every module
  # of the loaded applications is loaded, so no run loads code mid-test.
  defp load_all_modules do
    unless :persistent_term.get({__MODULE__, :modules_loaded}, false) do
      Application.loaded_applications()
      |> Enum.flat_map(fn {app, _, _} -> Application.spec(app, :modules) || [] end)
      |> Code.ensure_all_loaded()

      :persistent_term.put({__MODULE__, :modules_loaded}, true)
    end
  end

  @doc """
  Stops the clock at the current time. From now on it moves only by
  `advance/1` or `settle/1`. For tests; pair it with `reset/0` in `on_exit`.

  Options are the defaults of `settle/1`, and:

    * `:drive` - when true, the calling process drives the clock: when it
      sleeps, yields or receives on the clock itself, it settles until its
      wait ends, and while it is blocked in a call on a process in scope that
      waits for the clock, the clock moves to the next timer once everything
      in scope is idle. Without it, only `advance/1` and `settle/1` move the
      clock.

    * `:epoch` - the UTC time the clock stops at, with monotonic time 0, in
      place of the machine's time now: every run then reads the same times.
  """
  @spec manual(keyword()) :: :ok
  def manual(opts \\ []) do
    if match?(%{timers: _}, :persistent_term.get(@key, nil)),
      do: raise(ArgumentError, "a manual clock is already running; take it over instead")

    {drive?, opts} = Keyword.pop(opts, :drive, false)
    {epoch, settle_opts} = Keyword.pop(opts, :epoch)
    load_all_modules()

    {monotonic, system} =
      case epoch do
        nil -> {monotonic_time(), system_time()}
        %DateTime{} -> {0, DateTime.to_unix(epoch, :native)}
      end

    owner = self()

    holder =
      spawn(fn ->
        timers = :ets.new(__MODULE__, [:set, :public])
        journal = :ets.new(__MODULE__, [:ordered_set, :public])
        # The reads of each process's info (see `process_info/2`), one row
        # per process ever read, and the addresses of sockets: apart from
        # the timers, which are scanned.
        reads = :ets.new(__MODULE__, [:set, :public])
        send(owner, {__MODULE__, :timers, timers, journal, reads})
        hold(timers, [])
      end)

    {timers, journal, reads} =
      receive do
        {__MODULE__, :timers, timers, journal, reads} -> {timers, journal, reads}
      end

    driver =
      if drive?,
        do:
          spawn(fn ->
            receive do
              {__MODULE__, :drive, holder} -> drive(holder)
            end
          end)

    clock = %{
      monotonic: monotonic,
      system: system,
      offset: :atomics.new(1, signed: true),
      records: :atomics.new(1, signed: true),
      # The time a test database's `now()` returns (see `database_time/0`).
      database: :atomics.new(1, signed: true),
      arms: :atomics.new(1, signed: false),
      # How many times the driver has slept between its checks, and 1 while
      # the owner sleeps in a settle for the processes in scope to change
      # (see `look/2`).
      driver_polls: :atomics.new(1, signed: false),
      owner_waits: :atomics.new(1, signed: false),
      timers: timers,
      journal: journal,
      reads: reads,
      holder: holder,
      driver: driver,
      owner: if(drive?, do: owner),
      settle: settle_opts
    }

    :persistent_term.put(@key, clock)
    observe(clock)
    if driver, do: send(driver, {__MODULE__, :drive, holder})
    :ok
  end

  @doc """
  Makes the calling process the one that drives a manual clock, as the caller
  of `manual/1` does. A clock kept across the tests of a module is handed to
  each test this way; the timers armed in earlier tests stay on the clock.
  """
  @spec take_over(keyword()) :: :ok
  def take_over(opts \\ []) do
    %{driver: driver} = clock = :persistent_term.get(@key)
    true = is_pid(driver)
    unless opts[:keep_journal], do: :ets.delete_all_objects(clock.journal)
    # A test killed while it slept in a settle left its mark.
    :atomics.put(clock.owner_waits, 1, 0)
    :persistent_term.put(@key, %{clock | owner: self()})
  end

  @doc """
  Whether a driven manual clock is held, by any process. A test's `on_exit`
  callback runs in another process: it takes the clock over (keeping the
  test's journal) to settle work the test left.
  """
  @spec driven?() :: boolean()
  def driven? do
    match?(%{driver: driver} when is_pid(driver), :persistent_term.get(@key, nil))
  end

  # The owner drives the clock. While it is blocked in a call whose reply
  # needs clock time (a server that sleeps or waits for a timer), nothing else
  # would move the clock: when every process in scope is idle and the owner is
  # still blocked on one of them, the clock jumps to the next timer, as
  # `settle/1` does. Checking for that state may take any amount of real time;
  # the state itself, and so each jump, is the same on every run. The driver
  # checks only when the check can find something new (see `look/2`), and
  # not while the owner sleeps in a settle, which drives the clock itself.
  defp drive(holder) do
    case :persistent_term.get(@key, nil) do
      %{holder: ^holder} = clock ->
        polls = :atomics.get(clock.driver_polls, 1)

        if Process.alive?(clock.owner) and :atomics.get(clock.owner_waits, 1) == 0 do
          case look(polls, 0) do
            nil ->
              :ok

            why ->
              started = System.monotonic_time(:millisecond)
              drive_once(clock)
              looked(why, polls, 0, started)
          end
        end

        # Counted before the sleep's switch, as `look/2` counts it.
        :atomics.add(clock.driver_polls, 1, 1)
        Process.sleep(1)
        drive(holder)

      _gone ->
        :ok
    end
  end

  # Taking the state of the processes in scope reads every process of the
  # node, thousands in a full suite: more work than most steps a test waits
  # for, and work that takes the CPU from those steps. After a state that did
  # not let the clock move, the next is taken when it can differ: when another
  # process has run since (the node's context switches grew by more than the
  # waits of the caller and of the driver, one switch each) and none runs now.
  # A change this misses (a process that stopped while the last state was
  # taken, an expected signal whose patience ran out), or work that keeps
  # running (a process outside the scope that never stops), is caught by also
  # taking one after a span of real time, which doubles up to @look_span_max
  # ms. A state is not taken again sooner than the last one took, nor for
  # this span sooner than three times that, so the states never take most of
  # the CPU from the work they wait for. Real time decides only how soon a
  # state is taken, never what it holds.
  @look_span_max 32

  # Why the caller of the gate takes a state now: `:ran` (another process ran
  # since its last one), `:due` (its span passed) or nil (not yet). `own` and
  # `driver` count the caller's waits and the driver's polls.
  defp look(own, driver) do
    case Process.get({__MODULE__, :look}) do
      # No state taken yet.
      nil ->
        :ran

      {switches, own_then, driver_then, _span, ran_after, due} ->
        now = System.monotonic_time(:millisecond)

        cond do
          now >= due -> :due
          now < ran_after -> nil
          # Work runs now: a state would find it busy.
          :erlang.statistics(:total_active_tasks_all) > 1 -> nil
          context_switches() - switches > own - own_then + (driver - driver_then) -> :ran
          true -> nil
        end
    end
  end

  # Records a state taken for `why` (see `look/2`), from `started` (real
  # milliseconds): after another process ran the next span is the shortest,
  # after a span passed it is twice as long.
  defp looked(why, own, driver, started) do
    span =
      case {why, Process.get({__MODULE__, :look})} do
        {:due, {_, _, _, span, _, _}} -> min(span * 2, @look_span_max)
        _ -> 1
      end

    now = System.monotonic_time(:millisecond)
    took = now - started

    Process.put(
      {__MODULE__, :look},
      {context_switches(), own, driver, span, now + took, now + max(span, 3 * took)}
    )
  end

  defp context_switches do
    {switches, 0} = :erlang.statistics(:context_switches)
    switches
  end

  defp drive_once(clock) do
    opts = Keyword.merge(settle_defaults(), clock.settle)
    filter = {MapSet.new([clock.driver, clock.holder, clock.owner]), opts[:scope]}
    arms = :atomics.get(clock.arms, 1)

    if owner_blocked?(clock.owner, opts[:scope]) and
         quiet_now?(opts[:io], filter) and
         owner_blocked?(clock.owner, opts[:scope]) and
         :persistent_term.get(@key, nil) == clock do
      case next_due(clock) do
        nil ->
          :ok

        due ->
          if still_quiet?(clock, arms, filter), do: jump(clock, due)
      end
    end
  end

  defp jump(clock, due) do
    # What the owner waits in when the driver moves the clock for it.
    unanswered(
      fn ->
        with {:current_stacktrace, stack} <- process_info(clock.owner, :current_stacktrace),
             do: note(clock, {:owner_blocked, Enum.take(stack, 6)})
      end,
      :ok
    )

    move_to(clock, due, :driver)
  end

  # Blocked in a call or a task await on a process in scope, and not settling
  # (a settling owner drives the clock itself).
  defp owner_blocked?(owner, scope),
    do: unanswered(fn -> blocked_in_call?(owner, scope) end, false)

  defp blocked_in_call?(owner, scope) do
    case process_info(owner, [:status, :current_stacktrace, :monitors]) do
      [status: :waiting, current_stacktrace: stack, monitors: monitors] ->
        # Only the frames above this module's own: a call made from inside a
        # settle condition blocks the owner as any other call does.
        stack = Enum.take_while(stack, &(not match?({__MODULE__, _, _, _}, &1)))

        # A read from a server of this node (a stub HTTP server) blocks the
        # owner as a call does.
        (stack != [] and local_peer(owner) != nil) or
          (stack != [] and
             Enum.any?(
               stack,
               &match?(
                 {m, f, _, _}
                 when {m, f} in [
                        {:gen, :do_call},
                        {Task, :await},
                        {Task, :await_receive},
                        {Task, :await_many},
                        {Task.Supervised, :stream_reduce}
                      ],
                 &1
               )
             ) and
             not calls_outside?(stack, monitors, scope))

      _ ->
        false
    end
  end

  defp quiet_now?(io, filter) do
    first = quiet_state(io, filter)
    :erlang.yield()
    quiet_again?(quiet_state(io, filter), first)
  end

  # The processes in scope and where each waits, then the counters of the
  # sockets between them. A socket's port takes bytes in and hands them to
  # its owner as a message in one step, which `getstat` follows: counters
  # equal in the states before and after a snapshot mean no bytes reached a
  # process unseen while it was taken.
  #
  # The same processes waiting in the same places in two snapshots do not
  # show that none of them ran in between: a snapshot reads one process after
  # another, so a process read as idle can take a message from one read later,
  # run, and wait in the same place again before the next snapshot reads it.
  # Its reductions tell: each snapshot ends with the reductions of every
  # process it found idle, and the two must differ only by the reads of them
  # that this module made in between, from any process (see `process_info/2`).
  defp quiet_state(io, filter) do
    unanswered(
      fn ->
        case take_snapshot(io, filter) do
          :busy -> :busy
          snapshot -> {snapshot, scoped_socket_ends(snapshot), run_marks(snapshot)}
        end
      end,
      :busy
    )
  end

  defp quiet_again?({snapshot, ends, marks}, {snapshot, ends, previous_marks}) do
    quiet =
      not ran_since?(previous_marks, marks) and not bytes_in_flight?(ends) and
        not signals_pending?()

    if quiet, do: Process.put({__MODULE__, :quiet}, snapshot)
    quiet
  end

  defp quiet_again?(_state, _previous), do: false

  defp run_marks(snapshot) do
    Map.new(snapshot, fn pid ->
      before = reads(pid)

      reductions =
        case Process.info(pid, :reductions) do
          {:reductions, reductions} -> reductions
          nil -> :gone
        end

      # A read in flight, or one that ran while the reductions were read,
      # leaves no exact count: the mark then shows a run.
      mark =
        case {before, reads(pid)} do
          {{done, done}, {done, done}} -> {reductions, done}
          _ -> :reading
        end

      {pid, mark}
    end)
  end

  defp ran_since?(previous, marks),
    do: Enum.any?(marks, fn {pid, mark} -> ran?(previous, pid, mark) end)

  defp ran?(previous, pid, {reductions, reads}) when is_integer(reductions) do
    case previous do
      %{^pid => {before, reads_before}} when is_integer(before) ->
        reductions - before != reads - reads_before

      _ ->
        true
    end
  end

  defp ran?(_previous, _pid, _mark), do: true

  # What kept the last two states from being quiet, for the failure report:
  # the processes that ran between them, the socket ends with bytes in
  # flight, and whether an announced signal was still expected.
  defp unquiet({snapshot, ends, marks}, {snapshot, ends, previous_marks}) do
    [
      ran:
        for(
          {pid, mark} <- marks,
          ran?(previous_marks, pid, mark),
          do: {pid, initial_module(pid), Map.get(previous_marks, pid), mark}
        ),
      in_flight:
        for(
          {pair, %{owner: owner}} = socket_end <- ends,
          in_flight?(ends, socket_end),
          do: {pair, owner}
        ),
      signals_pending: signals_pending?()
    ]
  end

  defp unquiet({snapshot, ends, _marks}, {previous, previous_ends, _previous_marks}) do
    [
      changed_processes:
        for(
          pid <- MapSet.symmetric_difference(snapshot, previous),
          do: {pid, initial_module(pid)}
        ),
      changed_sockets:
        for(
          pair <- Enum.uniq(Map.keys(ends) ++ Map.keys(previous_ends)),
          Map.get(ends, pair) != Map.get(previous_ends, pair),
          do: {pair, socket_state(previous_ends[pair]), socket_state(ends[pair])}
        )
    ]
  end

  defp unquiet(state, _previous), do: [last_state: if(state == :busy, do: :busy, else: :changed)]

  defp socket_state(nil), do: nil

  defp socket_state(%{owner: owner} = state),
    do: Map.put(state, :module, if(is_pid(owner), do: initial_module(owner)))

  # Reading most items of another process's info runs in that process and
  # adds one reduction to it, as a run of its own would; the items listed here
  # are read without it. Every such read, by the settling process or by the
  # driver, is counted in the clock's table (started, then done), so that
  # `ran_since?/2` tells all of them from the process running.
  @direct_info [
    :status,
    :reductions,
    :message_queue_len,
    :initial_call,
    :parent,
    :priority,
    :trap_exit,
    :group_leader,
    :registered_name
  ]

  defp process_info(pid, items) do
    if Enum.all?(List.wrap(items), &(&1 in @direct_info)) do
      Process.info(pid, items)
    else
      read_info(pid, items, reads_table())
    end
  end

  # A process answers a read of its info when it next handles its signals. A
  # read not answered within @read_patience_ms real milliseconds counts the
  # process as busy: the caller moves on (`unanswered/2`), and the read goes on
  # in the caller's reader process, which counts it done when it is answered:
  # in the clock the read began on, so a read answered after its test ended
  # leaves the next test's counts exact.
  @read_patience_ms 2_000

  defp read_info(pid, items, reads) do
    reader = reader()
    reply = :erlang.alias([:reply])
    send(reader, {:read, reply, pid, items, reads})

    receive do
      {^reply, info} -> info
    after
      @read_patience_ms ->
        :erlang.unalias(reply)
        Process.delete({__MODULE__, :reader})
        throw({__MODULE__, :unanswered, pid})
    end
  end

  # The caller's reader, a new one when the last has ended: the end of a test
  # stops the readers it started, while their callers may live on.
  defp reader do
    reader =
      case Process.get({__MODULE__, :reader}) do
        reader when is_pid(reader) ->
          if Process.alive?(reader), do: reader, else: new_reader()

        _ ->
          new_reader()
      end

    # Not code under test: a state never reads a reader (see `readers/0`).
    with %{timers: timers} <- :persistent_term.get(@key, nil),
         do: :ets.insert(timers, {{__MODULE__.Reader, reader}})

    reader
  end

  defp new_reader do
    reader = :proc_lib.spawn(__MODULE__, :read_loop, [self()])
    Process.put({__MODULE__, :reader}, reader)
    reader
  end

  defp readers do
    case :persistent_term.get(@key, nil) do
      %{timers: timers} -> :ets.select(timers, [{{{__MODULE__.Reader, :"$1"}}, [], [:"$1"]}])
      _ -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc false
  def read_loop(caller) do
    ref = Process.monitor(caller)
    read_loop(caller, ref)
  end

  defp read_loop(caller, ref) do
    receive do
      # The reader counts the read both when it starts and when it ends: a
      # reader that ends (stopped with the test that started it, while its
      # caller lives on) leaves no read counted as under way.
      {:read, reply, pid, items, reads} ->
        count_read(reads, pid, 2)
        info = Process.info(pid, items)
        count_read(reads, pid, 3)
        send(reply, {reply, info})
        read_loop(caller, ref)

      {:DOWN, ^ref, :process, ^caller, _reason} ->
        :ok
    end
  end

  # What `fun` returns, or `unanswered` when a process did not answer a read of
  # its info in time (see `read_info/2`).
  defp unanswered(fun, unanswered) do
    fun.()
  catch
    {__MODULE__, :unanswered, _pid} -> unanswered
  end

  defp reads_table do
    case :persistent_term.get(@key, nil) do
      %{reads: reads} -> reads
      _ -> nil
    end
  end

  defp count_read(nil, _pid, _position), do: :ok

  defp count_read(reads, pid, position) do
    key = {__MODULE__.Reads, pid}
    :ets.update_counter(reads, key, {position, 1}, {key, 0, 0})
  rescue
    ArgumentError -> :ok
  end

  # {started, done} reads of `pid`'s info that add to its reductions.
  defp reads(pid) do
    with %{reads: reads} <- :persistent_term.get(@key, nil),
         [{_, started, done}] <- :ets.lookup(reads, {__MODULE__.Reads, pid}) do
      {started, done}
    else
      _ -> {0, 0}
    end
  rescue
    ArgumentError -> {0, 0}
  end

  # Bytes one end of a socket between two processes of this node has sent
  # and the other has not yet taken are work under way that no process state
  # shows, when that other end delivers them as messages (an active socket).
  # A passive end's bytes wait for its reader, whose state tells; but a
  # writer whose bytes are still queued in its port is sending.
  defp bytes_in_flight?(ends), do: Enum.any?(ends, &in_flight?(ends, &1))

  defp in_flight?(ends, {{local, remote}, %{sent: sent, pending: pending}}) do
    %{received: peer_received, active: peer_active} = Map.fetch!(ends, {remote, local})
    pending > 0 or (peer_active != false and sent != peer_received)
  end

  # The TCP sockets of this node whose other end is also of this node.
  defp local_socket_ends do
    addressed =
      for port <- Port.list(),
          {:name, ~c"tcp_inet"} <- [Port.info(port, :name)],
          {local, remote} <- [socket_address(port)],
          do: {port, local, remote}

    # Most sockets go to programs outside the VM (a database): only those
    # whose peer is a socket of this node are read further.
    pairs = MapSet.new(addressed, fn {_port, local, remote} -> {local, remote} end)

    ends =
      for {port, local, remote} <- addressed,
          MapSet.member?(pairs, {remote, local}),
          {:ok, [send_oct: sent, recv_oct: received, send_pend: pending]} <-
            [inet_call(:getstat, port, [[:send_oct, :recv_oct, :send_pend]])],
          {:ok, [active: active]} <- [inet_call(:getopts, port, [[:active]])],
          into: %{},
          do:
            {{local, remote},
             %{
               sent: sent,
               received: received,
               pending: pending,
               active: active,
               owner: elem(Port.info(port, :connected) || {:connected, nil}, 1)
             }}

    Map.filter(ends, fn {{local, remote}, _counts} -> Map.has_key?(ends, {remote, local}) end)
  end

  # A connected socket's own and peer address, or nil. They do not change
  # while the socket is open, and a port is not reused: the clock keeps them.
  defp socket_address(port) do
    key = {__MODULE__.Address, port}

    case reads_table() do
      nil ->
        read_socket_address(port)

      table ->
        case :ets.lookup(table, key) do
          [{_key, address}] ->
            address

          [] ->
            with {_local, _remote} = address <- read_socket_address(port) do
              :ets.insert(table, {key, address})
              address
            end
        end
    end
  rescue
    ArgumentError -> read_socket_address(port)
  end

  defp read_socket_address(port) do
    with {:ok, local} <- inet_call(:sockname, port),
         {:ok, remote} <- inet_call(:peername, port),
         do: {local, remote},
         else: (_ -> nil)
  end

  # The owners of socket ends that act for a process in `owners`: they
  # monitor it or are linked to it.
  defp socket_agents(ends, owners) do
    candidates = MapSet.new(for {_pair, %{owner: owner}} <- ends, is_pid(owner), do: owner)

    for pid <- MapSet.difference(candidates, owners),
        acts_for?(pid, owners),
        do: pid
  end

  defp acts_for?(pid, owners) do
    case process_info(pid, [:monitors, :links]) do
      [monitors: monitors, links: links] ->
        Enum.any?(monitors, fn
          {:process, target} when is_pid(target) -> MapSet.member?(owners, target)
          _ -> false
        end) or Enum.any?(links, &(is_pid(&1) and MapSet.member?(owners, &1)))

      _ ->
        false
    end
  end

  # A scoped settle must not wait for traffic belonging to unrelated work.
  # Keep both ends for processes in scope and the test's own sockets: the
  # owner may wait for a socket in its condition or through the clock driver.
  # A process that moves bytes for one of them (it monitors or links it and
  # owns a socket, as a TLS connection process does for its user) counts as
  # theirs: its bytes in flight are their work under way.
  defp scoped_socket_ends(snapshot) do
    owners = Enum.into(List.wrap(clock_owner()), MapSet.put(snapshot, self()))
    ends = local_socket_ends()
    owners = Enum.into(socket_agents(ends, owners), owners)

    {related, outside} =
      Enum.split_with(ends, fn {{local, remote}, %{owner: owner}} ->
        MapSet.member?(owners, owner) or MapSet.member?(owners, ends[{remote, local}].owner)
      end)

    # A pool can own a passive socket while a process in scope reads it.
    # Only these readers need a stack lookup; idle servers do not borrow
    # sockets, and pairs already retained need no further inspection.
    borrowed =
      if outside == [] do
        MapSet.new()
      else
        for pid <- owners,
            {:current_function, {:prim_inet, _, _}} <- [process_info(pid, :current_function)],
            port <- client_sockets(pid),
            {:ok, local} <- [inet_call(:sockname, port)],
            {:ok, remote} <- [inet_call(:peername, port)],
            into: MapSet.new(),
            do: {local, remote}
      end

    outside
    |> Enum.filter(fn {{local, remote}, _end} ->
      MapSet.member?(borrowed, {local, remote}) or MapSet.member?(borrowed, {remote, local})
    end)
    |> Enum.into(Map.new(related))
  end

  @doc "The default options of `settle/1`."
  @spec settle_defaults() :: keyword()
  def settle_defaults, do: @settle_defaults

  @doc """
  Waits until a manual clock has at least `count` timers pending, so a test
  advances only after the code has armed the timer the advance is meant to
  fire. It waits as long as that takes; the test's own timeout bounds it.
  """
  @spec await_timers(pos_integer()) :: :ok
  def await_timers(count \\ 1) when is_integer(count) and count > 0 do
    %{timers: _} = clock = :persistent_term.get(@key)
    tag = make_ref()
    send(clock.holder, {:await, self(), tag, count})

    receive do
      {__MODULE__, ^tag} -> :ok
    end
  end

  @doc """
  Moves a manual clock forward by `ms` milliseconds and sends the messages of
  the timers that are then due, earliest first.
  """
  @spec advance(non_neg_integer()) :: :ok
  def advance(ms) when is_integer(ms) and ms >= 0 do
    if simulated?() do
      # Only the world's scheduler moves its clock: the caller waits `ms` of it.
      sleep(ms)
    else
      %{timers: _} = clock = :persistent_term.get(@key)
      # As a jump does (`move_to/3`): where the processes in scope wait as
      # the test moves the clock, so a failed run shows what was idle.
      unanswered(
        fn ->
          note_waiters(clock, false)
          note_database_blocked(clock)
        end,
        :ok
      )

      note(clock, {:advance, ms})
      :atomics.add(clock.offset, 1, System.convert_time_unit(ms, :millisecond, :native))
      observe(clock)
      fire_due(clock)
    end
  end

  @doc """
  Runs `ms` clock milliseconds as `settle/1` does: each timer due in the span
  fires in order with the system settled in between, then the clock rests at
  the end of the span. Options are those of `settle/1`.
  """
  @spec run_for(non_neg_integer(), keyword()) :: :ok
  def run_for(ms, opts \\ []) when is_integer(ms) and ms >= 0 do
    settle(Keyword.merge(opts, until: :limit, within: ms))
  end

  @doc """
  Runs the system under a manual clock until nothing more happens without clock
  time passing, then returns. When every other process is idle, the clock jumps
  to the next pending timer and the system runs again, so a backoff or a
  periodic job completes at once in real time, at exact clock times.

  A process is idle when it waits in a `receive` that nothing in its mailbox
  matches and is
  not inside a client call listed in `:io` (a database query or an HTTP
  request still in flight). Nothing here waits on real time: the check repeats
  until the same idle state holds twice with no process running in between.

  Options:

    * `:until` - a function; settling stops as soon as it returns a truthy
      value at an idle point, and returns that value, moving the clock to
      the next timer while it does not. Without it, settling stops at the
      first idle point and does not move the clock.
    * `:within` - the clock span, in milliseconds, settling may jump through
      (default 3_600_000). Periodic timers never run out, so a condition that
      never holds fails here, on clock time, after the same steps every run.
    * `:io` - modules whose frames on a process's stack mean it waits on a
      reply from outside the VM or from module loading (default
      `#{inspect(Keyword.fetch!(@settle_defaults, :io))}`).
    * `:ignore` - pids that never count as busy, besides the caller.
    * `:scope` - module name prefixes (strings such as `"Elixir.SalixAgent"`);
      only processes whose initial call is in such a module count. Library
      processes outside the code under test (connection pools, pollers) keep
      their own schedules and never become idle together with it. By default
      every process counts.
  """

  @spec settle(keyword()) :: term()
  def settle(opts \\ []) do
    if simulated?(), do: simulated_settle(opts), else: node_settle(opts)
  end

  # A process of a `SystemsSim` world settles by handing the turn to the
  # world's scheduler: the scheduler knows when the world is idle and moves
  # its clock, with nothing read from the processes' state at a real time.
  defp simulated?, do: :persistent_term.get(SystemsSim.Scheduler, self()) != self()

  defp simulated_settle(opts) do
    within = Keyword.get(opts, :within, Keyword.fetch!(@settle_defaults, :within))

    case opts[:until] do
      nil ->
        simulated_until(fn -> true end)
        :ok

      :limit ->
        sleep(within)
        simulated_until(fn -> true end)
        :ok

      until when is_function(until, 0) ->
        limit = monotonic_time(:millisecond) + within

        simulated_until(fn ->
          until.() ||
            (monotonic_time(:millisecond) > limit and
               raise(
                 ArgumentError,
                 "the condition did not hold within #{within} ms of clock time"
               ))
        end)
    end
  end

  # `systems_sim` depends on this application, so it is named only here.
  defp simulated_until(fun), do: apply(SystemsSim, :until, [fun])

  defp node_settle(opts) do
    %{timers: _} = clock = :persistent_term.get(@key)
    opts = settle_defaults() |> Keyword.merge(clock.settle) |> Keyword.merge(opts)
    until = opts[:until]

    limit =
      manual_monotonic(clock) + System.convert_time_unit(opts[:within], :millisecond, :native)

    io = opts[:io]
    ignore = MapSet.new([self(), clock.holder, clock.driver | opts[:ignore]])
    scope = opts[:scope]

    # An eager condition is also checked while the system is still busy, so a
    # message the test waits for ends the wait as soon as it arrives.
    outer = Process.delete({__MODULE__, :eager})
    if opts[:eager] && is_function(until), do: Process.put({__MODULE__, :eager}, until)

    try do
      settle_loop(clock, until, limit, io, {ignore, scope})
    catch
      {__MODULE__, :held, held} -> held
    after
      if outer,
        do: Process.put({__MODULE__, :eager}, outer),
        else: Process.delete({__MODULE__, :eager})
    end
  end

  defp settle_loop(clock, until, limit, io, ignore) do
    await_quiet(clock, io, ignore, nil, nil)
    held = is_function(until) && until.()
    # One reading for the whole decision: a process outside the scope can
    # cancel the next timer between two readings.
    due = next_due(clock)

    cond do
      held ->
        held

      until == nil ->
        :idle

      # run_for/2: every timer up to the limit fires in order, then the clock
      # rests at the limit.
      until == :limit and (due == nil or due > limit) ->
        move_to(clock, limit, :run_for)
        await_quiet(clock, io, ignore, nil, nil)
        :ok

      # Nothing in scope can run and no clock timer is pending: the next step
      # waits on the world outside the code under test (a database
      # notification, a reply over a socket). Wait for that activity, not for
      # an amount of time; the test's own timeout stops a wait that never ends.
      due == nil ->
        await_activity(clock, io, ignore, nil)
        settle_loop(clock, until, limit, io, ignore)

      due > limit ->
        raise ArgumentError, "condition never held within the settle span"

      true ->
        move_to(clock, due, :settle)
        settle_loop(clock, until, limit, io, ignore)
    end
  end

  defp check_eager do
    case Process.get({__MODULE__, :eager}) do
      nil ->
        :ok

      until ->
        if held = until.(), do: throw({__MODULE__, :held, held}), else: :ok
    end
  end

  # A settle still waiting after this many real milliseconds records why:
  # each process in scope, busy or idle, and where it waits, for the failure
  # report. `wait` is when the wait began, or `:noted` once it has recorded.
  @long_wait_ms 5_000

  defp long_wait?(:noted), do: false
  defp long_wait?(since), do: System.monotonic_time(:millisecond) - since >= @long_wait_ms

  # Bytes in flight between processes of this node that stay in flight this
  # many real milliseconds will not arrive (the other end does not read): the
  # settle fails then, naming the sockets, instead of at the test's timeout.
  @stuck_in_flight_ms 30_000

  defp bytes_never_arrive!(state, previous, now) do
    waited = now - Process.get({__MODULE__, :unquiet_since}, now)
    limit = Application.get_env(:systems_clock, :stuck_in_flight_ms, @stuck_in_flight_ms)

    with true <- waited >= limit,
         [_ | _] = pairs <- Keyword.get(unquiet(state, previous), :in_flight, []) do
      sockets =
        Enum.map_join(pairs, "\n", fn {{local, remote}, owner} ->
          "  #{:inet.ntoa(elem(local, 0))}:#{elem(local, 1)} -> " <>
            "#{:inet.ntoa(elem(remote, 0))}:#{elem(remote, 1)}, " <>
            "owned by #{inspect(owner)} (#{inspect(owner && initial_module(owner))})"
        end)

      raise RuntimeError,
            "SystemsClock kept the clock still for #{div(waited, 1000)} s of real time " <>
              "because bytes stayed in flight on sockets between processes of this node " <>
              "and never arrived (the reading end does not read):\n" <> sockets
    else
      _ -> :ok
    end
  end

  # Any process that runs ends the wait: the settle then looks again at the
  # whole state, timers armed included.
  defp await_activity(clock, io, filter, wait, why \\ :ran) do
    check_eager()
    started = System.monotonic_time(:millisecond)
    wait = wait || started
    state = quiet_snapshot(io, filter)
    looked(why, own_waits(), :atomics.get(clock.driver_polls, 1), started)

    case state do
      :busy ->
        :ok

      _idle ->
        case await_look(clock, true, 1) do
          {:ran, _checks} ->
            :ok

          {:due, _checks} ->
            wait =
              if long_wait?(wait) do
                note_waiting(clock, :no_activity, io, filter)
                :noted
              else
                wait
              end

            await_activity(clock, io, filter, wait, :due)
        end
    end
  end

  # Quiet means no process waits to run and every other process is idle, in
  # two snapshots in a row with a yield between them, so a message sent
  # between two reads is seen in the second. An eager condition can run
  # processes itself (`:sys.get_state/1`), so it is checked before the first
  # of the two snapshots, never between them. After a snapshot that found a
  # process busy, the next waits until it can differ (see `look/2`).
  defp await_quiet(clock, io, filter, previous, wait, why \\ :ran) do
    eager? = Process.get({__MODULE__, :eager}) != nil
    if previous == nil or not eager?, do: check_eager()
    started = System.monotonic_time(:millisecond)
    if wait == nil, do: Process.put({__MODULE__, :unquiet_since}, started)
    wait = wait || started
    state = quiet_state(io, filter)
    looked(why, own_waits(), :atomics.get(clock.driver_polls, 1), started)

    if quiet_again?(state, previous) do
      :ok
    else
      bytes_never_arrive!(state, previous, started)

      {why, _checks} =
        if state != :busy and :erlang.statistics(:total_active_tasks_all) == 1,
          do: {pause(clock, :yield), 1},
          else: await_look(clock, state == :busy, 1)

      wait =
        if long_wait?(wait) do
          unanswered(
            fn -> note_waiting(clock, :never_quiet, io, filter, unquiet(state, previous)) end,
            :ok
          )

          :noted
        else
          wait
        end

      next = if eager? and previous != nil, do: nil, else: state
      await_quiet(clock, io, filter, next, wait, why)
    end
  end

  # Checks before a wait in `await_look/3` sleeps instead of yielding: short
  # work ends within the yields.
  @look_yields 1_000

  # Waits until `look/2` says a state taken now can differ from the last,
  # checking an eager condition meanwhile when `eager?` (the next state is
  # the first of a pair). Returns why to look and how many checks it made.
  defp await_look(clock, eager?, checks) do
    if eager?, do: check_eager()

    case look(own_waits(), :atomics.get(clock.driver_polls, 1)) do
      nil ->
        pause(clock, if(checks < @look_yields, do: :yield, else: :sleep))
        await_look(clock, eager?, checks + 1)

      why ->
        {why, checks}
    end
  end

  # A yield, or a real millisecond's sleep, each one context switch of the
  # caller's own (see `look/2`). While the owner sleeps the driver does not
  # check: the owner settles and moves the clock itself. Returns `:ran`, the
  # reason to take the next state after a yield.
  defp pause(clock, how) do
    Process.put({__MODULE__, :waits}, own_waits() + 1)

    case how do
      :yield ->
        :erlang.yield()

      :sleep ->
        owner? = clock.owner == self()
        if owner?, do: :atomics.put(clock.owner_waits, 1, 1)
        Process.sleep(1)
        if owner?, do: :atomics.put(clock.owner_waits, 1, 0)
    end

    :ran
  end

  defp own_waits, do: Process.get({__MODULE__, :waits}, 0)

  defp note_waiting(clock, why, io, filter, reasons \\ []),
    do: unanswered(fn -> record_waiting(clock, why, io, filter, reasons) end, :ok)

  defp record_waiting(clock, why, io, {ignore, scope} = filter, reasons) do
    describe = fn pid ->
      case process_info(pid, [:status, :message_queue_len, :current_stacktrace]) do
        nil ->
          nil

        info ->
          stack = info[:current_stacktrace]

          # What a waiting call waits on: its server and that server's state.
          info =
            if Enum.any?(stack, &match?({:gen, :do_call, _, _}, &1)) do
              target = call_target(pid)

              Keyword.put(info, :calls, {
                target,
                target && initial_module(target),
                target && process_info(target, :current_function),
                target && in_scope?(target, scope),
                for(
                  target <- monitored(elem(process_info(pid, :monitors) || {:monitors, []}, 1)),
                  do:
                    {target, initial_module(target), process_info(target, :current_function),
                     in_scope?(target, scope)}
                )
              })
            else
              info
            end

          {pid, initial_module(pid),
           Keyword.update!(info, :current_stacktrace, &Enum.take(&1, 4))}
      end
    end

    in_scope = scoped_processes(ignore, scope)

    busy =
      for pid <- in_scope,
          quiet(pid, io, scope) in [false, :database],
          info = describe.(pid),
          do: info

    # Without a busy process, quiet fails because processes come and go
    # between two snapshots: record those.
    first = quiet_snapshot(io, filter)
    :erlang.yield()
    second = quiet_snapshot(io, filter)

    changed =
      if is_struct(first, MapSet) and is_struct(second, MapSet),
        do:
          for(pid <- MapSet.symmetric_difference(first, second), info = describe.(pid), do: info),
        else: []

    note(
      clock,
      {why, [idle: length(in_scope) - length(busy), busy: busy, changed: changed] ++ reasons}
    )
  end

  # Processes waiting on database queries are busy unless every query the
  # database runs waits for a lock that the system under test holds while it
  # is idle (`config :systems_clock, outside_blocked: [{module, function,
  # args}]`, each check true): then only the clock can move the system on,
  # as a deadline on it ends the wait.
  defp quiet_snapshot(io, filter), do: unanswered(fn -> take_snapshot(io, filter) end, :busy)

  defp take_snapshot(io, {ignore, scope}) do
    ignore = Enum.into(readers(), ignore)

    ignore
    |> reduce_scoped(scope, {MapSet.new(), []}, fn pid, {acc, database} = state ->
      case quiet(pid, io, scope) do
        :gone -> {:cont, state}
        true -> {:cont, {MapSet.put(acc, pid), database}}
        :database -> {:cont, {acc, [pid | database]}}
        false -> {:halt, :busy}
      end
    end)
    |> case do
      :busy ->
        :busy

      {acc, []} ->
        Process.delete({__MODULE__, :database_blocked})
        acc

      {acc, database} ->
        if outside_blocked?() do
          Process.put({__MODULE__, :database_blocked}, database_blocked(database))
          Enum.into(database, acc)
        else
          :busy
        end
    end
  end

  # What the clock took as waiting for a lock when it moved past database
  # queries: where each such process was, and the database's own account of
  # the node's queries (`config :systems_clock, outside_blocked_report:
  # {module, function, args}`). A failed run shows why the queries counted
  # as blocked.
  defp database_blocked(database) do
    processes =
      for pid <- database,
          info = process_info(pid, [:current_stacktrace]),
          info != nil,
          do: {pid, initial_module(pid), Enum.take(info[:current_stacktrace], 4)}

    report =
      case Application.get_env(:systems_clock, :outside_blocked_report) do
        {module, function, args} -> apply(module, function, args)
        nil -> nil
      end

    %{processes: processes, queries: report}
  end

  defp note_database_blocked(clock) do
    case Process.delete({__MODULE__, :database_blocked}) do
      nil -> :ok
      blocked -> note(clock, {:database_blocked, blocked})
    end
  end

  defp quiet_label(false), do: "BUSY"
  defp quiet_label(:database), do: "DATABASE"
  defp quiet_label(_idle), do: "idle"

  defp database_query?(stack), do: Enum.any?(stack, &match?({Postgrex.Protocol, _, _, _}, &1))

  defp outside_blocked? do
    case Application.get_env(:systems_clock, :outside_blocked, []) do
      [] ->
        false

      checks ->
        Enum.all?(checks, fn {module, function, args} -> apply(module, function, args) end)
    end
  end

  defp quiet(pid, io, scope) do
    before = reads(pid)

    case process_info(pid, [:status, :reductions]) do
      nil ->
        :gone

      # A waiting process has nothing in its mailbox that its receive matches:
      # the runtime makes it runnable as soon as a matching message arrives.
      # It has not run since its reductions last changed, so what it waits for
      # is still what it was: the answer is kept until they change. One that
      # waits for a program outside the VM to answer (see `awaiting/1`) is
      # busy until the answer comes.
      [status: status, reductions: reductions] when status in [:waiting, :suspended] ->
        key = {__MODULE__, :waits_for, pid}

        # Reading the stack itself adds a reduction. As in run_marks/1,
        # subtract only fully completed reads; an in-flight read cannot
        # supply a stable mark. Keep the mark from before reading the stack,
        # so work run during that read invalidates the cached answer too.
        mark =
          case {before, reads(pid)} do
            {{done, done}, {done, done}} ->
              {reads_table(), reductions - done, io, scope, clock_owner()}

            _ ->
              nil
          end

        cond do
          awaiting?(pid) ->
            false

          mark != nil and Process.get(key) == mark ->
            true

          true ->
            answer = waiting_quiet(pid, io, scope)

            # Only an idle wait is local to this process. A socket peer,
            # outside call or global lock can change without it running.
            if answer == true and mark != nil,
              do: Process.put(key, mark),
              else: Process.delete(key)

            peer_quiet(answer, io, scope)
        end

      _busy ->
        false
    end
  end

  defp waiting_quiet(pid, io, scope) do
    case process_info(pid, [:current_stacktrace, :monitors]) do
      nil ->
        :gone

      # A process blocked on a socket waits on the other end: a process of
      # this node (see `peer_quiet/3`) or outside work. Waiting for a
      # connection to accept is idle.
      [current_stacktrace: [{:prim_inet, function, _, _} | _], monitors: _]
      when function in [:accept, :accept0] ->
        true

      # A database query waits on the database (see `quiet_snapshot/2`).
      [current_stacktrace: [{:prim_inet, _, _, _} | _] = stack, monitors: _] ->
        case local_peer(pid) do
          nil -> if database_query?(stack), do: :database, else: false
          server -> {:peer, server}
        end

      # No frames: the process is exiting or has not started its code.
      [current_stacktrace: [], monitors: _] ->
        true

      # A BIF that waits for another process's signal reply (`is_process_alive/1`
      # on a process of another scheduler, as `logger` calls for its handler)
      # shows as waiting, but no message can wake it: it runs on as soon as the
      # reply arrives.
      [current_stacktrace: [{:erts_internal, _, _, _} | _], monitors: _] ->
        false

      # A test's own stub waiting in its receive waits for the test, whatever
      # client of outside work called it.
      [current_stacktrace: [top | stack], monitors: monitors] ->
        if test_stub_frame?(top),
          do: true,
          else: classify_wait(pid, [top | stack], monitors, io, scope)
    end
  end

  defp test_stub_frame?({module, _, _, _}) when is_atom(module),
    do: Regex.match?(~r/Test(\.|$)/, Atom.to_string(module))

  defp test_stub_frame?(_frame), do: false

  # The innermost frame that says what the process waits for decides: this
  # module (the clock), a call (idle unless it goes to outside work), or a
  # client of outside work (busy). An outer frame, such as a database
  # transaction around a call, does not.
  defp classify_wait(pid, stack, monitors, io, scope) do
    case Enum.drop_while(stack, &(not wait_frame?(&1, io))) do
      # A clock wait inside a client of outside work (awaiting a guest with a
      # deadline) is that outside work.
      [{__MODULE__, _, _, _} | callers] ->
        case Enum.drop_while(callers, &match?({__MODULE__, _, _, _}, &1)) do
          [caller | _] -> not io_frame?(caller, io)
          [] -> true
        end

      [{:gen, :do_call, _, _} | callers] ->
        case outside_call?(pid, callers, monitors, io, scope) do
          {:target, target} -> {:call, target}
          outside? -> not outside?
        end

      [] ->
        true

      # A `:global` lock request backing off waits on the processes that hold
      # locks: idle while each of them is (they wait on this clock, say), and
      # busy when no lock is held, as the next try then takes it.
      [{:global, :random_sleep, _, _} | _] ->
        case global_lock_holders() do
          [] -> false
          holders -> {:holders, holders}
        end

      _io ->
        case local_peer(pid) do
          nil -> false
          server -> {:peer, server}
        end
    end
  end

  defp global_lock_holders do
    for {_resource, _requester, holders} <- :ets.tab2list(:global_locks),
        {holder, _ref} <- holders,
        uniq: true,
        do: holder
  rescue
    ArgumentError -> []
  end

  # A client of outside work whose socket's other end is a process of this
  # node (a stub HTTP server, say) waits on what that process waits on: it is
  # idle when the server is, as when the server sleeps on this clock.
  defp peer_quiet({:peer, server}, io, scope) do
    case process_info(server, [:status, :current_stacktrace]) do
      [status: status, current_stacktrace: [{:erts_internal, _, _, _} | _]]
      when status in [:waiting, :suspended] ->
        false

      [status: status, current_stacktrace: stack] when status in [:waiting, :suspended] ->
        case Enum.drop_while(stack, &(not wait_frame?(&1, io))) do
          [{__MODULE__, _, _, _} | _] -> true
          [{:gen, :do_call, _, _} | _] -> quiet(server, io, scope) == true
          # A server of the code under test that waits in a receive of its
          # own, as a stream's loop does, is idle as any process in scope is.
          [] -> in_scope?(server, scope)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp peer_quiet({:call, targets}, _io, _scope), do: Enum.any?(targets, &suspended?/1)

  # Holders that wait on each other's locks are busy: the check stops at a
  # holder it is already checking.
  defp peer_quiet({:holders, holders}, io, scope) do
    checking = Process.get({__MODULE__, :checking_holders}, MapSet.new())

    try do
      Process.put({__MODULE__, :checking_holders}, MapSet.union(checking, MapSet.new(holders)))

      Enum.all?(holders, fn holder ->
        not MapSet.member?(checking, holder) and quiet(holder, io, scope) in [true, :gone]
      end)
    after
      Process.put({__MODULE__, :checking_holders}, checking)
    end
  end

  defp peer_quiet(answer, _io, _scope), do: answer

  defp local_peer(pid) do
    with sockets when sockets != [] <- client_sockets(pid),
         {local, remote} <-
           Enum.find_value(sockets, fn socket ->
             with {:ok, local} <- inet_call(:sockname, socket),
                  {:ok, remote} <- inet_call(:peername, socket),
                  do: {local, remote},
                  else: (_ -> nil)
           end) do
      Enum.find_value(Port.list(), fn port ->
        with {:ok, ^remote} <- inet_call(:sockname, port),
             {:ok, ^local} <- inet_call(:peername, port),
             {:connected, server} when server != pid <- Port.info(port, :connected) do
          server
        else
          _ -> nil
        end
      end)
    else
      _ -> nil
    end
  end

  # The sockets a process reads: those it owns, and those named on its stack
  # (a pooled connection is read in passive mode by a process that does not
  # own it).
  defp client_sockets(pid) do
    owned =
      case process_info(pid, :links) do
        {:links, links} -> for port when is_port(port) <- links, do: port
        nil -> []
      end

    named =
      case process_info(pid, :backtrace) do
        {:backtrace, backtrace} ->
          for [port] <- Regex.scan(~r/#Port<\d+\.\d+>/, backtrace),
              do: :erlang.list_to_port(String.to_charlist(port))

        nil ->
          []
      end

    Enum.uniq(owned ++ named)
  rescue
    _ -> []
  end

  defp inet_call(function, port, args \\ []) do
    case Port.info(port, :name) do
      {:name, name} when name in [~c"tcp_inet", ~c"udp_inet"] ->
        apply(:inet, function, [port | args])

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  # A call is outside work when its caller is a client listed in `:io` (a
  # call into the loops host, say) or the called process is outside the scope.
  defp outside_call?(pid, callers, monitors, io, scope) do
    caller =
      Enum.find(callers, fn {module, _, _, _} -> module not in [:gen, GenServer, :gen_server] end)

    cond do
      caller != nil and io_frame?(caller, io) ->
        true

      # Outside work, unless the server is suspended: it does no work until
      # the test resumes it, which `peer_quiet/3` reads each time.
      target = call_target(pid) ->
        if in_scope?(target, scope), do: false, else: {:target, [target]}

      calls_outside?([{:gen, :do_call, 4, []}], monitors, scope) ->
        {:target, monitored(monitors)}

      true ->
        false
    end
  end

  # A call to a registered name monitors the name.
  defp monitored(monitors) do
    for {:process, target} <- monitors,
        pid =
          (case target do
             pid when is_pid(pid) -> pid
             {name, node} when node == node() -> Process.whereis(name)
             _remote -> nil
           end),
        is_pid(pid),
        do: pid
  end

  # Suspended by `:erlang.suspend_process/1`, or by `:sys.suspend/1`, which
  # leaves the server waiting in the `sys` suspend loop.
  defp suspended?(pid) do
    case process_info(pid, [:status, :current_function]) do
      [status: :suspended, current_function: _] -> true
      [status: _, current_function: {:sys, :suspend_loop, _}] -> true
      _ -> false
    end
  end

  # The called process. `gen:do_call/4` keeps only the reply tag and the
  # monitor in its own frame; the call wrappers above it (`gen:call/4`,
  # `gen_server:call/3`, `GenServer.call/3`) keep the server, a pid or a
  # registered name, in a slot of its own. The call monitors its server, so the
  # first such slot the caller monitors names it. A pid inside the request (the
  # owner a callback captures, say) never fills a slot by itself.
  defp call_target(pid) do
    with {:backtrace, backtrace} <- process_info(pid, :backtrace),
         {:monitors, monitors} <- process_info(pid, :monitors),
         [_, frames] <- String.split(backtrace, "(gen:do_call/4", parts: 2) do
      monitored = monitored(monitors)
      [own | callers] = String.split(frames, "\n\n")

      [own | Enum.take_while(callers, &call_wrapper_frame?/1)]
      |> Enum.flat_map(&slot_processes/1)
      |> Enum.find(&(&1 in monitored))
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp call_wrapper_frame?(frame),
    do:
      Regex.match?(
        ~r/\A0x\S+ Return addr 0x\S+ \((gen|gen_server|gen_statem|gen_event|'Elixir\.GenServer'):/,
        frame
      )

  # The processes the slots of one backtrace frame hold whole: a pid, or the
  # name a local process is registered under.
  defp slot_processes(frame) do
    for [value] <- Regex.scan(~r/^y\(\d+\)\s+(\S.*)$/m, frame, capture: :all_but_first),
        pid = slot_process(String.trim(value)),
        do: pid
  end

  defp slot_process("<" <> _ = value) do
    if Regex.match?(~r/\A<\d+\.\d+\.\d+>\z/, value),
      do: :erlang.list_to_pid(String.to_charlist(value))
  end

  defp slot_process(value) do
    name =
      cond do
        Regex.match?(~r/\A'[^']+'\z/, value) -> String.slice(value, 1..-2//1)
        Regex.match?(~r/\A[a-z][A-Za-z0-9_@]*\z/, value) -> value
        true -> nil
      end

    if name, do: Process.whereis(String.to_existing_atom(name))
  rescue
    ArgumentError -> nil
  end

  defp wait_frame?({__MODULE__, _, _, _}, _io), do: true
  defp wait_frame?({:gen, :do_call, _, _}, _io), do: true
  defp wait_frame?(frame, io), do: io_frame?(frame, io)

  # An `:io` entry is a module, or `{module, function}` for a client function
  # of a server whose own loop must not count (the code server).
  defp io_frame?({module, function, _, _}, io),
    do: module in io or {module, function} in io

  # A process waiting for a call's reply from a process outside the scope waits
  # on work this clock does not see, as on a database reply. The call monitors
  # its target.
  defp calls_outside?(_stack, _monitors, nil), do: false

  # The call's own monitor is not told apart from others the process holds:
  # the call counts as outside only when every monitored process is.
  defp calls_outside?(stack, monitors, scope) do
    targets = monitored(monitors)

    Enum.any?(stack, &match?({:gen, :do_call, _, _}, &1)) and targets != [] and
      Enum.all?(targets, &(not in_scope?(&1, scope)))
  end

  defp started?(pid) do
    case process_info(pid, :reductions) do
      {:reductions, reductions} -> reductions > 0
      nil -> true
    end
  end

  defp in_scope?(_pid, nil), do: true
  defp in_scope?(pid, prefixes), do: scope_of(pid, prefixes) != :outside

  # How `pid` counts for the scope `prefixes`: `:module` (its own module is
  # in scope), `:inside` (it works for a process in scope), `:outside`, or
  # `:unsettled`. A process's initial call never changes, so a settled answer
  # is kept for the settling process's lifetime.
  #
  # A process that has not run yet has not put its callers in its
  # dictionary: until it has, it is unsettled, counts as in scope (it is
  # about to run) and is asked again. A process still in `proc_lib`'s start,
  # or a task before it has put its own initial call and callers, is
  # unsettled too.
  defp scope_of(pid, prefixes) do
    key = {__MODULE__, :scope, pid}

    case Process.get(key) do
      nil ->
        {module, callers} = origin(pid)

        answer =
          cond do
            scoped?(module, prefixes) ->
              :module

            spawned_by_scope?(pid, prefixes) or
                Enum.any?(callers, &(&1 == clock_owner() or in_scope?(&1, prefixes))) ->
              :inside

            started?(pid) and module not in [:proc_lib, Task.Supervised] ->
              :outside

            true ->
              :unsettled
          end

        if answer != :unsettled, do: Process.put(key, answer)
        answer

      answer ->
        answer
    end
  end

  # The processes of the node not in `ignore` that count for `scope`, in pid
  # order.
  defp scoped_processes(ignore, scope) do
    ignore
    |> reduce_scoped(scope, [], &{:cont, [&1 | &2]})
    |> :lists.sort()
  end

  # Reduces `fun` over the processes of the node not in `ignore` that count
  # for `scope`, as `Enum.reduce_while/3` does. Most of the node's thousands
  # of processes run outside the code under test, and what decides that a
  # process counts or not does not change: a process outside stays outside
  # (see `in_scope?/2`), and one whose own module is in scope stays in. The
  # clock keeps the processes found so, for every process that settles on it:
  # a look takes the node's process list and reads only the processes not
  # classified before. Those come last, so a look that finds a process busy
  # among the others classifies none.
  defp reduce_scoped(ignore, nil, acc, fun) do
    Enum.reduce_while(Process.list(), acc, fn pid, acc ->
      if MapSet.member?(ignore, pid), do: {:cont, acc}, else: fun.(pid, acc)
    end)
  end

  defp reduce_scoped(ignore, prefixes, acc, fun) do
    known = classified(prefixes)
    {inside, others, alive, kept} = split_known(:lists.sort(Process.list()), known, ignore)

    {acc, found} =
      inside
      |> :lists.reverse()
      |> Enum.reduce_while({:cont, acc}, fn pid, {:cont, acc} -> tagged(fun.(pid, acc)) end)
      |> case do
        {:halt, acc} ->
          {acc, []}

        {:cont, acc} ->
          others
          |> :lists.reverse()
          |> Enum.reduce_while({acc, []}, fn pid, {acc, found} ->
            case not MapSet.member?(ignore, pid) and scope_of(pid, prefixes) do
              false ->
                {:cont, {acc, found}}

              :outside ->
                {:cont, {acc, [{pid, false} | found]}}

              scope ->
                found = if scope == :module, do: [{pid, true} | found], else: found
                {tag, acc} = fun.(pid, acc)
                {tag, {acc, found}}
            end
          end)
      end

    if found != [] or kept != length(known),
      do: classify(prefixes, :lists.merge(:lists.reverse(alive), :lists.reverse(found)))

    acc
  end

  defp tagged({:cont, acc}), do: {:cont, {:cont, acc}}
  defp tagged({:halt, acc}), do: {:halt, {:halt, acc}}

  # Walks the sorted process list and the sorted classified processes
  # together. Returns the processes in scope among those classified, the
  # processes not classified, and the classified ones still alive with their
  # count (each list in reverse order).
  defp split_known(pids, known, ignore), do: split_known(pids, known, ignore, [], [], [], 0)

  defp split_known([pid | pids], [{gone, _module?} | known], ignore, inside, others, alive, kept)
       when pid > gone,
       do: split_known([pid | pids], known, ignore, inside, others, alive, kept)

  defp split_known(
         [pid | pids],
         [{pid, module?} = entry | known],
         ignore,
         inside,
         others,
         alive,
         kept
       ) do
    inside = if module? and not MapSet.member?(ignore, pid), do: [pid | inside], else: inside
    split_known(pids, known, ignore, inside, others, [entry | alive], kept + 1)
  end

  defp split_known([pid | pids], known, ignore, inside, others, alive, kept),
    do: split_known(pids, known, ignore, inside, [pid | others], alive, kept)

  defp split_known([], _known, _ignore, inside, others, alive, kept),
    do: {inside, others, alive, kept}

  defp classified(prefixes) do
    with %{timers: timers} <- :persistent_term.get(@key, nil),
         [{_key, known}] <- :ets.lookup(timers, {__MODULE__.Scope, prefixes}) do
      known
    else
      _ -> []
    end
  rescue
    ArgumentError -> []
  end

  # Two processes may store at once, and one store then loses the other's
  # finds: a process lost is classified again.
  defp classify(prefixes, known) do
    with %{timers: timers} <- :persistent_term.get(@key, nil),
         do: :ets.insert(timers, {{__MODULE__.Scope, prefixes}, known})
  rescue
    ArgumentError -> :ok
  end

  defp scoped?(module, prefixes),
    do: module != nil and String.starts_with?(Atom.to_string(module), prefixes)

  # A process started with a bare `spawn_link/1` has no initial module of its
  # own; it does the work of the process it is linked to.
  defp spawned_by_scope?(pid, prefixes) do
    with {:initial_call, {:erlang, :apply, 2}} <- process_info(pid, :initial_call),
         {:links, links} <- process_info(pid, :links) do
      Enum.any?(links, &(is_pid(&1) and scoped?(initial_module(&1), prefixes))) or
        spawned_by_parent_in_scope?(pid, prefixes)
    else
      _ -> false
    end
  end

  # A bare `spawn`/`spawn_monitor` works for the process that spawned it.
  defp spawned_by_parent_in_scope?(pid, prefixes) do
    case process_info(pid, :parent) do
      {:parent, parent} when is_pid(parent) ->
        parent == clock_owner() or in_scope?(parent, prefixes)

      _ ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp clock_owner do
    case :persistent_term.get(@key, nil) do
      %{owner: owner} -> owner
      _ -> nil
    end
  end

  defp initial_module(pid), do: elem(origin(pid), 0)

  # The module `pid` started in (nil once it has ended) and the processes it
  # works for: a task (`Task.async_stream/3` workers included) works for its
  # callers, the test that drives the clock among them. One read.
  defp origin(pid) do
    case process_info(pid, [
           {:dictionary, :"$initial_call"},
           {:dictionary, :"$callers"},
           :initial_call
         ]) do
      [{_, initial_call}, {_, callers}, {:initial_call, {fallback, _, _}}] ->
        # A task puts its initial call, then its callers: until both are
        # there, it is still starting.
        module =
          case initial_call do
            {module, _, _} when fallback != Task.Supervised or callers != :undefined -> module
            _ -> fallback
          end

        {module, if(is_list(callers), do: Enum.filter(callers, &is_pid/1), else: [])}

      nil ->
        {nil, []}
    end
  end

  defp next_due(clock) do
    case :ets.select(clock.timers, [{{:_, {:"$1", :_}, :_, :_}, [], [:"$1"]}]) do
      [] -> nil
      dues -> Enum.min(dues)
    end
  end

  @doc "Runs the clock `rate` times faster than real time from now on. See the module doc."
  @spec speed_up(pos_integer()) :: :ok
  def speed_up(rate) when is_integer(rate) and rate >= 1 do
    now = System.monotonic_time()

    {virtual, monotonic_skew} =
      case :persistent_term.get(@key, nil) do
        nil -> {now, 0}
        %{timers: _} = clock -> stop_manual(clock, now)
        clock -> {virtual_monotonic(clock), clock.monotonic_skew}
      end

    :persistent_term.put(@key, %{
      rate: rate,
      real_base: now,
      virtual_base: virtual,
      monotonic_skew: monotonic_skew
    })
  end

  @doc """
  Returns the clock to the real clock: every function is the BEAM primitive
  again. A deadline taken from a test's clock does not carry over to real
  time, so code under test and the test must not mix the two.
  """
  @spec reset() :: :ok
  def reset do
    case :persistent_term.get(@key, nil) do
      nil ->
        :ok

      %{timers: _} = clock ->
        save_report(clock)
        :persistent_term.erase(@key)
        observe(nil)
        rearm_real(clock)
        send(clock.holder, :stop)
        :ok

      _clock ->
        :persistent_term.erase(@key)
        :ok
    end
  end

  # Timers still pending on a manual clock belong to processes that outlive
  # the test (pollers, sweeps). They fire on the real clock after the same
  # remaining span, so no process is left waiting on a clock that is gone.
  defp rearm_real(clock) do
    now = manual_monotonic(clock)

    for {_ref, {due, _}, dest, message} <- :ets.tab2list(clock.timers) do
      left = max(System.convert_time_unit(due - now, :native, :millisecond), 0)
      Process.send_after(dest, message, left)
    end
  end

  # Owns a manual clock's timer table and answers `await_timers/1`.
  defp hold(timers, waiters) do
    receive do
      :stop -> :ok
      :armed -> hold(timers, notify(timers, waiters))
      {:await, pid, tag, count} -> hold(timers, notify(timers, [{pid, tag, count} | waiters]))
    end
  end

  defp notify(timers, waiters) do
    pending = :ets.select_count(timers, [{{:_, {:_, :_}, :_, :_}, [], [true]}])
    {ready, waiting} = Enum.split_with(waiters, fn {_, _, count} -> pending >= count end)
    Enum.each(ready, fn {pid, tag, _} -> send(pid, {__MODULE__, tag}) end)
    waiting
  end

  # A manual clock never goes behind real monotonic time when it hands over.
  defp stop_manual(clock, now) do
    send(clock.holder, :stop)
    virtual = max(manual_monotonic(clock), now)
    {virtual, virtual - now}
  end

  defp manual_monotonic(clock), do: clock.monotonic + :atomics.get(clock.offset, 1)

  # The clock's UTC time in microseconds, which record times start from.
  defp instant_us(clock),
    do:
      System.convert_time_unit(
        clock.system + :atomics.get(clock.offset, 1),
        :native,
        :microsecond
      )

  # Observers (`config :systems_clock, observers: [module]`) keep time that
  # lives outside the VM, such as a test database's `now()`, on a manual
  # clock: each gets `clock_moved/1` with the clock's UTC time in
  # microseconds, or the last record time when that is later (time never goes
  # back), when the clock stops or moves, and `nil` when it is reset.
  defp observe(nil) do
    for observer <- Application.get_env(:systems_clock, :observers, []),
        do: observer.clock_moved(nil)
  end

  defp observe(clock) do
    at = max(instant_us(clock), :atomics.get(clock.records, 1))
    :atomics.put(clock.database, 1, at)

    for observer <- Application.get_env(:systems_clock, :observers, []),
        do: observer.clock_moved(at)
  end

  defp left_ms(due, clock),
    do: max(System.convert_time_unit(due - manual_monotonic(clock), :native, :millisecond), 0)

  defp move_to(clock, due, by) do
    # Each jump records where the processes in scope that are neither in a
    # server loop nor on the clock wait (with SYSTEMS_CLOCK_TRACE=1, those on
    # the clock too, with deeper stacks): a failed run shows what the clock
    # took as idle when it moved.
    if due > manual_monotonic(clock) do
      unanswered(
        fn ->
          note_waiters(clock, System.get_env("SYSTEMS_CLOCK_TRACE") == "1")
          note_sockets(clock)
          note_since_quiet(clock)
          note_database_blocked(clock)
        end,
        :ok
      )
    end

    from = manual_ms(clock)
    :atomics.add(clock.offset, 1, max(due - manual_monotonic(clock), 0))
    observe(clock)
    note(clock, {:jump, by, from, manual_ms(clock)})
    # Timers due at the same instant fire one at a time, in the order they
    # were armed, with the system settled in between: which of two
    # simultaneous deadlines comes first does not depend on scheduling.
    fire_due(clock, 1)
  end

  # The quiet state that a driver jump rests on still holds: no timer was
  # armed and no process in scope started since its snapshot. Checking that
  # the state is quiet takes real time, and work started in that time (a reply
  # from outside the clock's scope that a process acts on) arms timers due
  # before the one the clock would jump to. (A settle moves the clock after
  # its condition has run, which may itself arm timers; it does not check.)
  defp still_quiet?(clock, arms, filter),
    do: unanswered(fn -> quiet_since?(clock, arms, filter) end, false)

  defp quiet_since?(clock, arms, {ignore, scope}) do
    ignore = Enum.into(readers(), ignore)

    :atomics.get(clock.arms, 1) == arms and
      case Process.get({__MODULE__, :quiet}) do
        %MapSet{} = quiet ->
          not Enum.any?(scoped_processes(ignore, scope), fn pid ->
            not MapSet.member?(quiet, pid) and process_info(pid, :status) != nil
          end)

        _none ->
          false
      end
  end

  # Processes in scope the quiet snapshot that let the clock move did not
  # hold: started since, or not seen as in scope then. A failed run shows
  # what the clock moved past.
  defp note_since_quiet(clock) do
    with %MapSet{} = quiet <- Process.get({__MODULE__, :quiet}) do
      scope = Keyword.merge(settle_defaults(), clock.settle)[:scope]

      since =
        for pid <-
              scoped_processes(
                MapSet.new([clock.holder, clock.driver, clock.owner, self()]),
                scope
              ),
            not MapSet.member?(quiet, pid),
            info = process_info(pid, [:status, :reductions, :current_stacktrace]),
            info != nil,
            do:
              {pid, initial_module(pid), info[:status], info[:reductions],
               Enum.take(info[:current_stacktrace], 2)}

      if since != [], do: note(clock, {:since_quiet, since})
    end
  end

  # The journal keeps the first and the last entries of a test's clock; a
  # long settle in between is summarized by its count.
  defp note_waiters(clock, trace?) do
    opts = Keyword.merge(settle_defaults(), clock.settle)

    waiters =
      for pid <- scoped_processes(MapSet.new([clock.holder, clock.driver]), opts[:scope]),
          info = process_info(pid, [:current_stacktrace]),
          info != nil,
          stack = info[:current_stacktrace],
          match?([{_, _, _, _} | _], stack),
          {module, _, _, _} = hd(stack),
          module not in [:gen_server, :gen_statem, :gen_event],
          not match?({:prim_inet, accept, _, _} when accept in [:accept, :accept0], hd(stack)),
          trace? or not Enum.any?(stack, &match?({__MODULE__, _, _, _}, &1)),
          do:
            {pid, initial_module(pid), Enum.take(stack, if(trace?, do: 3, else: 2)),
             quiet(pid, opts[:io], opts[:scope])}

    if waiters != [] or trace?, do: note(clock, {:waiters, waiters})

    # A process in scope that runs or has mail as the clock moves woke after
    # the system looked idle: what woke it, and from where.
    awake =
      for pid <-
            scoped_processes(MapSet.new([clock.holder, clock.driver, clock.owner]), opts[:scope]),
          info = process_info(pid, [:status, :message_queue_len, :messages]),
          info != nil,
          info[:status] != :waiting or info[:message_queue_len] > 0,
          do:
            {pid, initial_module(pid), info[:status],
             info[:messages] |> Enum.take(1) |> inspect(limit: 8, printable_limit: 80)}

    if awake != [], do: note(clock, {:awake, awake})
  end

  # The byte counts of sockets between processes of this node at a jump:
  # a jump with bytes under way shows the clock moved past them.
  defp note_sockets(clock) do
    ends = local_socket_ends()

    pairs =
      for {{local, remote}, end_} <- ends do
        peer = Map.fetch!(ends, {remote, local})

        {elem(local, 1), elem(remote, 1), end_.sent, peer.received, end_.pending, peer.active,
         end_.owner && initial_module(end_.owner)}
      end

    if pairs != [], do: note(clock, {:sockets, pairs |> Enum.sort() |> Enum.take(12)})
  end

  @journal_head 200
  @journal_tail 200

  # The journal keeps the last moves of a manual clock: timers armed and
  # fired, advances and jumps, with the clock time of each.
  defp note(%{journal: journal} = clock, entry) do
    n = :ets.update_counter(journal, :count, 1, {:count, 0})

    if n <= @journal_head do
      :ets.insert(journal, {{0, n}, manual_ms(clock), entry})
    else
      :ets.insert(journal, {{1, n}, manual_ms(clock), entry})
      :ets.delete(journal, {1, n - @journal_tail})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp note(_clock, _entry), do: :ok

  defp manual_ms(clock),
    do: System.convert_time_unit(manual_monotonic(clock) - clock.monotonic, :native, :millisecond)

  @doc """
  What the manual clock did, for a failure report: its journal and where every
  process in scope waits now. After `reset/0` it is the report of the clock
  that was reset, kept until the next one is (when `SystemsClock.Formatter`
  runs).
  """
  @spec report() :: String.t() | nil
  def report do
    case {saved_report(), :persistent_term.get(@key, nil)} do
      {%{} = captured, _clock} -> format_report(captured)
      {nil, %{journal: _} = clock} -> clock |> capture_report() |> format_report()
      {nil, _no_clock} -> nil
    end
  end

  @doc """
  Saves the report of the current manual clock for `SystemsClock.Formatter`,
  as `reset/0` does. A test that hands a module's clock to the next test calls
  it when it ends, so its failure reports its own journal.
  """
  @spec save_report() :: :ok
  def save_report do
    case :persistent_term.get(@key, nil) do
      %{journal: _} = clock -> save_report(clock)
      _ -> :ok
    end

    :ok
  end

  defp saved_report do
    case :ets.whereis(SystemsClock.Formatter) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, :report) do
          [{:report, report}] -> report
          [] -> nil
        end
    end
  end

  # Every test saves its report, but only a failed test's is read: the save
  # copies the journal, and `report/0` writes it out with the processes in
  # scope as they are then.
  defp save_report(clock) do
    case :ets.whereis(SystemsClock.Formatter) do
      :undefined -> :ok
      table -> :ets.insert(table, {:report, capture_report(clock)})
    end
  rescue
    ArgumentError -> :ok
  end

  defp journal_count(clock) do
    case :ets.lookup(clock.journal, :count) do
      [{:count, n}] -> n
      [] -> 0
    end
  end

  defp capture_report(clock) do
    # Read once: a timer can be taken between two readings.
    due = next_due(clock)

    %{
      journal: Enum.sort(:ets.tab2list(clock.journal) -- :ets.lookup(clock.journal, :count)),
      count: journal_count(clock),
      at: manual_ms(clock),
      next_due: due && System.convert_time_unit(due - clock.monotonic, :native, :millisecond),
      owner: clock.owner
    }
  end

  defp format_report(captured) do
    entries =
      for {{part, n}, at, entry} <- captured.journal do
        gap =
          if part == 1 and n == captured.count - @journal_tail + 1 and n > @journal_head + 1,
            do: "  ... #{n - @journal_head - 1} entries omitted ...\n",
            else: ""

        gap <> "  t+#{at}ms #{inspect(entry, limit: 300, printable_limit: 200)}"
      end

    # A process that does not answer a read of its info is named as such:
    # it is running native code or stuck in it.
    processes =
      case :persistent_term.get(@key, nil) do
        %{journal: _} = clock ->
          opts = Keyword.merge(settle_defaults(), clock.settle)
          skip = MapSet.new([self(), clock.holder, clock.driver])

          for pid <- Process.list(),
              not MapSet.member?(skip, pid),
              line =
                unanswered(
                  fn ->
                    with true <- in_scope?(pid, opts[:scope]),
                         info when info != nil <-
                           process_info(pid, [:status, :current_function, :message_queue_len]) do
                      "  #{inspect(pid)} #{inspect(initial_module(pid))} #{inspect(info)} " <>
                        quiet_label(quiet(pid, opts[:io], opts[:scope]))
                    else
                      _ -> nil
                    end
                  end,
                  "  #{inspect(pid)} #{inspect(Process.info(pid, [:status, :initial_call]))} UNANSWERED"
                ),
              do: line

        _gone ->
          []
      end

    Enum.join(
      [
        "SystemsClock at t+#{captured.at}ms, next timer #{inspect(captured.next_due)}, " <>
          "owner #{inspect(captured.owner)}",
        "journal (oldest first):"
        | entries
      ] ++ ["processes in scope when reported:" | processes],
      "\n"
    )
  end

  defp fire_due(clock, count \\ :all) do
    now = manual_monotonic(clock)

    clock.timers
    |> :ets.select([
      {{:"$1", {:"$2", :"$3"}, :_, :_}, [{:"=<", :"$2", now}], [{{:"$2", :"$3", :"$1"}}]}
    ])
    |> Enum.sort()
    |> then(&if(count == :all, do: &1, else: Enum.take(&1, count)))
    |> Enum.each(fn {_, _, ref} ->
      case :ets.take(clock.timers, ref) do
        [{^ref, _, dest, message}] ->
          note(clock, {:fired, dest, message})
          deliver(dest, message)

        [] ->
          :ok
      end
    end)
  end

  # As `Process.send_after/4`, a timer for a name that is not registered is dropped.
  defp deliver(dest, message) when is_atom(dest) do
    case Process.whereis(dest) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end

  defp deliver(dest, message), do: send(dest, message)

  defp virtual_monotonic(%{rate: rate, real_base: real_base, virtual_base: virtual_base}) do
    virtual_base + (System.monotonic_time() - real_base) * rate
  end
end
