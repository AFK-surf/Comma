defmodule SystemsSim.Scheduler do
  @moduledoc false
  # The scheduler of one `SystemsSim.run/2` world.
  #
  # It runs at high priority on a VM with one online scheduler, so while it is
  # runnable no process of the world runs, and a process the world spawns has
  # not run yet when the scheduler sees the spawn. Tracing (`:procs`, `:send`,
  # `:receive`, `:exiting`, inherited with `:set_on_spawn`, and `:running` for
  # the process that holds the turn) reports every spawn, message, scheduling
  # and end of the world to it.
  #
  # The VM holds a trace message back when another thread has the
  # scheduler's message queue locked (`enif_send` in erl_nif.c), and the
  # tracee's later trace messages wait with it: a process the holder spawned
  # can then run before the scheduler sees it. A dirty scheduler collecting
  # the scheduler's own garbage is such a thread, so the scheduler keeps its
  # heap small (its record lives in a table, its messages off its heap); and
  # a process of the world other than the holder that is scheduled in fails
  # the run (`running/2`).
  #
  # A suspended process still takes in its signals, when the VM runs it for
  # that: a message only joins its mailbox, an exit signal ends it. Left to
  # the VM, how far that has got when the scheduler next decides something
  # would depend on how long the scheduler waited, and it waits for real
  # times: for a reply from outside the world, for the trace messages still
  # on their way. So each time the process that holds the turn is scheduled
  # out, and before the scheduler waits for anything but a trace message, it
  # asks each process of the world for the length of its mailbox (`settle/2`).
  # A process answers only after it has taken in every signal sent to it
  # before, and the scheduler waits for one that ends to finish ending
  # (`out_exited`), which sends its own links and monitors their signals.
  # When a whole pass ends nothing, no signal of the world is on its way: each
  # mailbox holds what the steps so far sent it, and a process is ready when
  # its mailbox grew since it last stopped.

  # In `:erts_internal` a process waits for the runtime to answer, as to
  # `Process.alive?/1` on a process with a signal queued; a suspended process
  # of the world answers too.
  @io_modules [
    :code,
    :code_server,
    :erl_prim_loader,
    :erts_internal,
    :file,
    :file_io_server,
    :gen_tcp,
    :gen_udp,
    :httpc,
    :io,
    :prim_file,
    :prim_inet,
    :ssl,
    :tls_sender
  ]
  @io_prefixes ~w(Elixir.DBConnection Elixir.Postgrex Elixir.Finch Elixir.Mint Elixir.Req Elixir.Redix Elixir.Logger)

  @call_frames [
    {:gen, :do_call},
    {:gen, :do_call_with_timeout},
    {:proc_lib, :sync_start},
    {:proc_lib, :sync_start_link},
    {:proc_lib, :sync_start_monitor},
    {Task, :await},
    {Task, :await_many},
    {Task, :yield},
    {Task, :yield_many}
  ]

  # `:running` (scheduled in and out) is on only for the process that holds
  # the turn; `running/2`.
  @trace_flags [:procs, :exiting, :send, :receive, :set_on_spawn]

  def run(fun, seed, opts) do
    caller = self()
    tag = make_ref()

    {pid, mref} =
      spawn_monitor(fn ->
        Process.flag(:priority, :high)
        # Its heap stays small, so its garbage collection never moves to a
        # dirty scheduler and runs beside a process of the world: the trace
        # messages and the record wait outside it.
        Process.flag(:message_queue_data, :off_heap)
        send(caller, {tag, start(fun, seed, opts, tag)})
      end)

    receive do
      {^tag, run} ->
        Process.demonitor(mref, [:flush])
        run

      {:DOWN, ^mref, :process, ^pid, reason} ->
        raise "SystemsSim scheduler crashed: #{inspect(reason)}"
    end
  end

  defp start(fun, seed, opts, tag) do
    :persistent_term.put(__MODULE__, self())
    SystemsClock.fire_only_from(self())
    sched = self()

    root =
      spawn(fn ->
        receive do
          {^tag, :go} -> :ok
        end

        result =
          try do
            {:ok, fun.()}
          catch
            kind, reason -> {:error, {kind, reason, __STACKTRACE__}}
          end

        send(sched, {tag, :result, result})
      end)

    :erlang.trace(root, true, @trace_flags)
    :erlang.suspend_process(root)
    send(root, {tag, :go})

    st = %{
      tag: tag,
      seed: seed,
      # pid => %{id, seen}: `seen` is the length of its mailbox when it last
      # stopped, `:new` before its first turn.
      procs: %{root => %{id: 0, seen: :new}},
      # Processes that began to end and still owe their links and monitors a
      # signal, and the ids of those that are gone.
      ending: MapSet.new(),
      gone: %{},
      next_id: 1,
      refs: %{},
      rng: :rand.seed_s(:exsss, seed),
      # The last unique integer a process of the world was given.
      unique: 0,
      trace: [],
      # The record's steps, by number.
      record: :ets.new(__MODULE__, [:ordered_set, :private]),
      # What happened since the last step was written down, newest first.
      events: [],
      changes: 0,
      steps: 0,
      result: nil,
      outside: false,
      # A process of the world in `SystemsSim.until/1`, waiting for the world
      # to be idle: %{pid, tag, move?, moved?}.
      idle_waiter: nil,
      # The process that holds the turn, and the one that held it last.
      holder: nil,
      last_holder: nil,
      # Processes of the world that ran without the turn, and calls into the
      # world from outside it.
      escapes: [],
      intrusions: [],
      clock?: Keyword.get(opts, :clock, true),
      max_steps: Keyword.get(opts, :max_steps, 100_000),
      deadline: System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 60_000)
    }

    try do
      st = loop(st)
      finish(st, escaped(st) || intruded(st) || st.result)
    catch
      {__MODULE__, :stop, st, reason} ->
        finish(st, escaped(st) || intruded(st) || {:error, reason})
    after
      :persistent_term.erase(__MODULE__)
      SystemsClock.fire_only_from(nil)
    end
  end

  defp loop(%{result: result} = st) when result != nil, do: st

  defp loop(st) do
    if st.steps >= st.max_steps,
      do: throw({__MODULE__, :stop, st, {:max_steps, st.steps, busiest(st)}})

    {st, lengths} = settle(st)

    case ready(st, lengths) do
      _ when st.result != nil ->
        st

      [] ->
        st |> write(nil) |> idle() |> loop()

      ready ->
        {i, rng} = :rand.uniform_s(length(ready), st.rng)
        {pid, p} = Enum.at(ready, i - 1)
        st = write(st, nil)
        st = %{st | rng: rng, trace: [p.id | st.trace], steps: st.steps + 1, outside: false}
        st |> turn(pid) |> delivered() |> write(p.id) |> loop()
    end
  end

  # The processes whose mailbox grew since they last stopped, oldest first.
  defp ready(st, lengths) do
    st.procs
    |> Enum.filter(fn {pid, p} -> Map.get(lengths, pid, p.seen) != p.seen end)
    |> Enum.sort_by(fn {_, p} -> p.id end)
  end

  # Each process of the world but `except` takes in the signals it was sent;
  # one that ends has finished ending before the pass goes on. Gives each
  # one's mailbox length. Asking a process that has only messages waiting
  # reads its mailbox without running it; one with another signal waiting (an
  # exit, a link) runs to take it in before it answers, and has no answer
  # when the signal ended it.
  defp settle(st, except \\ nil) do
    before = st.changes

    {st, lengths} =
      st.procs
      |> Enum.sort_by(fn {_, p} -> p.id end)
      |> Enum.reduce({st, %{}}, fn {pid, _}, {st, lengths} ->
        if pid != except and Map.has_key?(st.procs, pid) do
          case Process.info(pid, :message_queue_len) do
            {:message_queue_len, n} -> {st, Map.put(lengths, pid, n)}
            nil -> {ended(st, pid), lengths}
          end
        else
          {st, lengths}
        end
      end)

    st = ended(st)
    # Nothing of the world ran in a pass that ended nothing.
    if st.changes == before, do: {st, lengths}, else: settle(st, except)
  end

  # Waits until every process that began to end has ended.
  defp ended(st) do
    if MapSet.size(st.ending) == 0, do: st, else: st |> event(next(st)) |> ended()
  end

  # Waits until `pid`, which is ending, has ended.
  defp ended(st, pid) do
    if alive?(st, pid), do: st |> event(next(st)) |> ended(pid), else: st
  end

  # Gives `pid` the turn: it runs until it waits on something only the world
  # can send, or ends.
  defp turn(st, pid) do
    running(pid, true)
    st = if resume(pid), do: hold(%{st | holder: pid}, pid), else: ended(st, pid)
    running(pid, false)
    %{st | holder: nil, last_holder: pid}
  end

  # Only the process that holds the turn reports when it is scheduled in and
  # out. Another process of the world that is scheduled in ran without the
  # turn: one that started while the trace messages of its parent were still
  # on their way, and ran before this scheduler could suspend it.
  defp running(pid, on?) do
    :erlang.trace(pid, on?, [:running])
  rescue
    ArgumentError -> 0
  end

  # False when the process is already gone (its exit trace is on the way).
  defp resume(pid) do
    :erlang.resume_process(pid)
  rescue
    ArgumentError -> false
  end

  defp hold(st, holder) do
    if alive?(st, holder) do
      case next(st) do
        {:trace, ^holder, :receive, msg} ->
          hold(%{intrusion(st, holder, msg) | outside: false}, holder)

        {:trace, ^holder, :out, _} ->
          # The others take in what it sent them so far.
          {st, _} = settle(st, holder)

          case alive?(st, holder) && Process.info(holder, [:status, :message_queue_len]) do
            # Still waiting for a reply from outside. Reading the stack
            # again would schedule the process in and out once more.
            [status: :waiting, message_queue_len: _] when st.outside ->
              hold(st, holder)

            [status: :waiting, message_queue_len: seen] ->
              if waiting_outside?(st, holder),
                do: hold(%{st | outside: true}, holder),
                else: stop(st, holder, seen)

            _running_or_gone ->
              hold(st, holder)
          end

        {:trace, ^holder, tag, _} = ending when tag in [:exit, :out_exiting, :out_exited] ->
          {st, _} = st |> event(ending) |> settle(holder)
          hold(st, holder)

        other ->
          st |> event(other) |> hold(holder)
      end
    else
      {st, _} = settle(st)
      st
    end
  end

  # The holder waits for the world, having looked at the `seen` messages of
  # its mailbox. A message that comes from outside the world from now on
  # does not run it: the mailbox is then longer than `seen`, and the process
  # ready.
  defp stop(st, holder, seen) do
    :erlang.suspend_process(holder)
    put_in(st.procs[holder].seen, seen)
  rescue
    ArgumentError -> st
  end

  defp alive?(st, pid), do: Map.has_key?(st.procs, pid) or MapSet.member?(st.ending, pid)

  # Nothing in the world has anything new to take in: move the clock to the
  # next timer of the world. With none, the world waits on itself.
  defp idle(%{idle_waiter: %{pid: pid, tag: tag} = waiter} = st) do
    case waiter.move? && st.clock? && next_due_in(st) do
      ms when is_integer(ms) ->
        # The waiter is answered once what the timers wake has run.
        advance(%{st | idle_waiter: %{waiter | move?: false, moved?: true}}, ms)

      _ ->
        send(pid, {tag, if(waiter.moved?, do: :moved, else: :idle)})

        record(%{st | idle_waiter: nil, trace: [:idle_waiter | st.trace]}, :idle_waiter)
    end
  end

  defp idle(st) do
    case st.clock? && next_due_in(st) do
      ms when is_integer(ms) -> advance(st, ms)
      _ -> throw({__MODULE__, :stop, st, {:deadlock, describe(st)}})
    end
  end

  # Moves the clock `ms` to the next timer of the world; the timers that fire
  # send their messages, which the next pass over the world finds.
  defp advance(st, ms) do
    SystemsClock.advance(ms)
    record(%{st | trace: [{:clock, ms} | st.trace]}, {:clock, ms})
  end

  # Milliseconds to the next timer of a process of the world. Timers of
  # processes outside it (application processes on the shared clock) are not
  # waited for: they would move the clock at times the seed does not decide.
  defp next_due_in(st) do
    case :persistent_term.get({SystemsClock, :clock}, nil) do
      %{timers: timers, monotonic: monotonic, offset: offset} ->
        dues =
          for {_ref, {due, _seq}, dest, _msg} <- SystemsRuntime.ETS.tab2list(timers),
              Map.has_key?(st.procs, if(is_atom(dest), do: Process.whereis(dest), else: dest)),
              do: due

        case dues do
          [] ->
            nil

          dues ->
            now = monotonic + :atomics.get(offset, 1)
            native = max(Enum.min(dues) - now, 0)
            ms = System.convert_time_unit(1, :millisecond, :native)
            System.convert_time_unit(native + ms - 1, :native, :millisecond)
        end

      _ ->
        nil
    end
  end

  # The next message for the scheduler. The run's real-time limit only stops
  # a world that hangs outside the scheduler's reach.
  defp next(st) do
    receive do
      message -> message
    after
      max(st.deadline - System.monotonic_time(:millisecond), 0) ->
        throw({__MODULE__, :stop, st, {:timeout, holding(st), describe(st)}})
    end
  end

  # Takes in every trace message generated so far: they reach the scheduler
  # asynchronously, and `trace_delivered` comes after all of them. How long
  # that takes is a real time, so it is asked only when the world has
  # settled: nothing in it moves meanwhile.
  defp delivered(st) do
    ref = :erlang.trace_delivered(:all)
    delivered(st, ref)
  end

  defp delivered(st, ref) do
    case next(st) do
      {:trace_delivered, :all, ^ref} -> st
      other -> st |> event(other) |> delivered(ref)
    end
  end

  defp event(st, {:trace, parent, :spawn, child, _mfa}) do
    # It started with the trace flags of its parent, the holder's; without
    # them it is not reported when it is scheduled in to take in the signal
    # that suspends it.
    if Map.has_key?(st.procs, parent), do: running(child, false)

    if Map.has_key?(st.procs, parent) and suspend(child) do
      procs = Map.put(st.procs, child, %{id: st.next_id, seen: :new})
      st = %{st | procs: procs, next_id: st.next_id + 1}
      note(st, {:spawn, st.procs[parent].id, st.procs[child].id})
    else
      st
    end
  end

  defp event(st, {:trace, from, :send, msg, to}) do
    to = if is_atom(to), do: Process.whereis(to), else: to

    cond do
      # A request to this scheduler: its own event records what it asked.
      to == self() -> st
      is_pid(to) and alive?(st, to) -> note(st, {:send, id(st, from), id(st, to), msg})
      # A reply to a call goes to an alias of the caller.
      is_reference(to) -> note(st, {:send, id(st, from), {:alias, to}, msg})
      # What the node's own services are told carries values of the machine.
      true -> note(st, {:send, id(st, from), :outside})
    end
  end

  defp event(st, {:trace, pid, :exit, reason}) do
    case Map.pop(st.procs, pid) do
      {nil, _procs} ->
        st

      {p, procs} ->
        st = %{
          st
          | procs: procs,
            ending: MapSet.put(st.ending, pid),
            gone: Map.put(st.gone, pid, p.id)
        }

        note(st, {:exit, p.id, reason})
    end
  end

  # Only now has it sent every signal its end owes.
  defp event(st, {:trace, pid, :out_exited, _}) do
    if MapSet.member?(st.ending, pid),
      do: %{st | ending: MapSet.delete(st.ending, pid), changes: st.changes + 1},
      else: st
  end

  defp event(st, {__MODULE__, :draw, from, tag, request}) do
    {value, st} = draw(st, request)
    send(from, {tag, value})
    note(st, {:draw, id(st, from), request, value})
  end

  defp event(st, {__MODULE__, :when_idle, from, tag, move?}),
    do: %{st | idle_waiter: %{pid: from, tag: tag, move?: move?, moved?: false}}

  # Kills a process of the world for `SystemsSim.kill/1` and waits until it
  # is gone, so its exit takes effect at this step on every run.
  defp event(st, {__MODULE__, :kill, from, tag, pid}) do
    st =
      if Map.has_key?(st.procs, pid) do
        Process.exit(pid, :kill)
        {st, _} = settle(st, from)
        st
      else
        st
      end

    send(from, {tag, :ok})
    st
  end

  defp event(st, {:trace, pid, :in, _}) when pid != st.holder and pid != st.last_holder,
    do: %{st | escapes: [pid | st.escapes]}

  defp event(st, {:trace, pid, :receive, msg}), do: intrusion(st, pid, msg)

  defp event(st, {tag, :result, result}) when tag == st.tag, do: %{st | result: result}
  defp event(st, _other), do: st

  # A value for `SystemsSim.draw/2`, from the run's seed.
  defp draw(st, {:uniform, n}) do
    {value, rng} = :rand.uniform_s(n, st.rng)
    {value, %{st | rng: rng}}
  end

  defp draw(st, :uniform) do
    {value, rng} = :rand.uniform_s(st.rng)
    {value, %{st | rng: rng}}
  end

  defp draw(st, {:bytes, n}) do
    {value, rng} = :rand.bytes_s(n, st.rng)
    {value, %{st | rng: rng}}
  end

  # One counter serves every modifier: its integers are positive and grow.
  defp draw(st, {:unique_integer, _modifiers}), do: {st.unique + 1, %{st | unique: st.unique + 1}}

  defp suspend(pid) do
    :erlang.suspend_process(pid)
  rescue
    ArgumentError -> false
  end

  defp id(st, pid), do: (st.procs[pid] && st.procs[pid].id) || st.gone[pid] || :outside

  defp note(st, event), do: %{st | events: [event | st.events], changes: st.changes + 1}

  # One step of the record: what its process did, in its order, the values
  # it drew, then what that made others do, by process. Trace messages of
  # different processes reach the scheduler in an order the VM does not
  # promise, nor do a process's trace messages and its own requests to it.
  defp write(%{events: []} = st, nil), do: st

  defp write(st, id) do
    {own, others} = st.events |> Enum.reverse() |> Enum.split_with(&(elem(&1, 1) == id))
    {draws, own} = Enum.split_with(own, &match?({:draw, _, _, _}, &1))
    {step, refs} = stable({id, own ++ draws ++ Enum.sort_by(others, &elem(&1, 1))}, st)
    record(%{st | events: [], refs: refs}, step)
  end

  defp record(st, entry) do
    :ets.insert(st.record, {:ets.info(st.record, :size), entry})
    st
  end

  # A term with each value that differs between runs by name only (a pid, a
  # reference, a port, a function) replaced by the name the world gives it.
  defp stable(term, st) do
    {term, refs} = stable(term, st, st.refs)
    {term, refs}
  end

  defp stable(pid, st, refs) when is_pid(pid), do: {{:pid, id(st, pid)}, refs}

  defp stable(ref, _st, refs) when is_reference(ref) do
    case refs do
      %{^ref => n} -> {{:ref, n}, refs}
      _ -> {{:ref, map_size(refs)}, Map.put(refs, ref, map_size(refs))}
    end
  end

  defp stable(fun, _st, refs) when is_function(fun), do: {:fun, refs}
  defp stable(port, _st, refs) when is_port(port), do: {:port, refs}

  defp stable(tuple, st, refs) when is_tuple(tuple) do
    {list, refs} = stable(Tuple.to_list(tuple), st, refs)
    {List.to_tuple(list), refs}
  end

  defp stable([head | tail], st, refs) do
    {head, refs} = stable(head, st, refs)
    {tail, refs} = stable(tail, st, refs)
    {[head | tail], refs}
  end

  defp stable(map, st, refs) when is_map(map) do
    # Its pairs in the order of their own terms, which the names above do
    # not change within one run but differ between two. A map's own order
    # follows the node's atom table, which differs between two VMs: the
    # pairs are named in the order of their keys.
    {pairs, refs} =
      map
      |> Map.to_list()
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_reduce(refs, fn {key, value}, refs ->
        {key, refs} = stable(key, st, refs)
        {value, refs} = stable(value, st, refs)
        {{key, value}, refs}
      end)

    {{:map, Enum.sort(pairs)}, refs}
  end

  # A term's encoding follows the node's atom table too (a map's atom keys
  # are written in its order): an encoded term is named by the term, and a
  # hex digest of such bytes (an S3 ETag), an opaque name, by its first
  # appearance.
  defp stable(<<131, _::binary>> = bin, st, refs), do: encoded(bin, bin, st, refs)

  defp stable(<<0x28, 0xB5, 0x2F, 0xFD, _::binary>> = bin, st, refs) do
    etf = bin |> :zstd.decompress() |> IO.iodata_to_binary()
    encoded(etf, bin, st, refs)
  rescue
    _not_zstd -> {bin, refs}
  end

  defp stable(bin, _st, refs) when is_binary(bin) and byte_size(bin) in [32, 34] do
    if Regex.match?(~r/\A"?[0-9a-f]{32}"?\z/, bin) do
      case refs do
        %{{:digest, ^bin} => n} -> {{:digest, n}, refs}
        _ -> {{:digest, map_size(refs)}, Map.put(refs, {:digest, bin}, map_size(refs))}
      end
    else
      {bin, refs}
    end
  end

  defp stable(other, _st, refs), do: {other, refs}

  defp encoded(etf, bin, st, refs) do
    {term, refs} = stable(:erlang.binary_to_term(etf, [:safe]), st, refs)
    {{:encoded, term}, refs}
  rescue
    ArgumentError -> {bin, refs}
  end

  # A process that waits in a call, for a task or for a process it starts
  # (the top of its stack) watches what it waits for: when it watches only
  # processes of the world, the world answers it, whatever its stack holds
  # open below, as a database transaction.
  defp waiting_outside?(st, pid) do
    with {:current_stacktrace, [top | _] = stack} <- Process.info(pid, :current_stacktrace),
         {:monitors, monitors} <- Process.info(pid, :monitors) do
      outside = Enum.reject(monitors, &in_world?(st, &1))

      if call_frame?(top) and outside == [] do
        false
      else
        Enum.any?(stack, &io_frame?/1) or
          Enum.any?(stack, &match?({SystemsSim, f, _, _} when f in [:ask, :kill], &1)) or
          (Enum.any?(stack, &call_frame?/1) and outside != [])
      end
    else
      _ -> false
    end
  end

  defp io_frame?({module, _, _, _}) do
    module in @io_modules or
      (is_atom(module) and String.starts_with?(Atom.to_string(module), @io_prefixes))
  end

  defp call_frame?({module, function, _, _}), do: {module, function} in @call_frames

  defp in_world?(st, {:process, pid}) when is_pid(pid), do: alive?(st, pid)

  defp in_world?(st, {:process, {name, node}}) when node == node(),
    do: alive?(st, Process.whereis(name))

  defp in_world?(_st, _monitor), do: false

  defp describe(st) do
    st.procs
    |> Enum.sort_by(fn {_, p} -> p.id end)
    |> Enum.map(fn {pid, p} ->
      %{id: p.id, initial_call: initial_call(pid), waits_in: current_function(pid)}
    end)
  end

  # The processes that took most of the steps, and how far the clock moved:
  # what a world that never comes to rest keeps doing.
  defp busiest(st) do
    pids = Map.new(st.procs, fn {pid, p} -> {p.id, pid} end)
    steps = for id <- st.trace, is_integer(id), do: id
    clock = for {:clock, ms} <- st.trace, reduce: 0, do: (sum -> sum + ms)

    most =
      steps
      |> Enum.frequencies()
      |> Enum.sort_by(fn {id, count} -> {-count, id} end)
      |> Enum.take(8)
      |> Enum.map(fn {id, count} ->
        %{id: id, steps: count, initial_call: pids[id] && initial_call(pids[id])}
      end)

    %{clock_ms: clock, most_steps: most, first_waits_in: pids[0] && stack(pids[0])}
  end

  # The process that held the turn when the run's real-time limit ended it,
  # and where it waited: for an answer from outside the world that did not
  # come.
  defp holding(%{holder: nil}), do: nil

  defp holding(%{holder: pid} = st),
    do: %{id: id(st, pid), initial_call: initial_call(pid), waits_in: stack(pid)}

  defp stack(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stack} -> Enum.take(stack, 8)
      nil -> nil
    end
  end

  defp initial_call(pid) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {_, mfa} <- List.keyfind(dictionary, :"$initial_call", 0) do
      mfa
    else
      _ ->
        case Process.info(pid, :initial_call) do
          {:initial_call, mfa} -> mfa
          nil -> nil
        end
    end
  end

  defp current_function(pid) do
    case Process.info(pid, :current_function) do
      {:current_function, mfa} -> mfa
      nil -> nil
    end
  end

  # A process outside the world that calls one of the world, as a poller of
  # another application calling a service the world hosts, does so at a real
  # time: the steps that follow depend on the machine, and the run fails,
  # naming it. (A reply to a call the world made is no call.)
  defp intrusion(st, pid, {:"$gen_call", {from, _tag}, request}) when is_pid(from) do
    if Map.has_key?(st.procs, pid) and from != self() and not alive?(st, from) and
         not Map.has_key?(st.gone, from) do
      intrusion = %{
        to: id(st, pid),
        from: initial_call(from),
        name: Process.info(from, :registered_name),
        request: request
      }

      %{st | intrusions: [intrusion | st.intrusions]}
    else
      st
    end
  end

  defp intrusion(st, _pid, _msg), do: st

  defp intruded(%{intrusions: []}), do: nil
  defp intruded(st), do: {:error, {:called_from_outside, Enum.reverse(st.intrusions)}}

  # A process of the world that ran without the turn makes the run's steps
  # depend on the VM's timing, not the seed: the run fails, naming it.
  defp escaped(%{escapes: []}), do: nil

  defp escaped(st) do
    {:error,
     {:ran_without_turn, Enum.map(st.escapes, &%{id: id(st, &1), initial_call: initial_call(&1)})}}
  end

  # The world's processes are gone when the run returns, so the next run can
  # register the same names.
  defp finish(st, result) do
    refs =
      for pid <- Map.keys(st.procs) ++ MapSet.to_list(st.ending) do
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        ref
      end

    for ref <- refs do
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      end
    end

    %SystemsSim.Run{
      seed: st.seed,
      result: result || {:error, :no_result},
      steps: st.steps,
      trace: Enum.reverse(st.trace),
      record: st.record |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
    }
  end
end
