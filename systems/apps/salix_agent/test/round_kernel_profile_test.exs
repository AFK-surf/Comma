Code.require_file("../../../native/verified_kernel/test/support/activation_fixture.exs", __DIR__)

defmodule SalixAgent.RoundKernelProfileTest do
  @moduledoc """
  Profiles the Elixir-to-Lean calls of Session Actor rounds.

  Each measured input runs through the production owner: admission, a tool
  round (`fs.write_file` and `fs.list_files` through `call`), and a final round. A
  trace session records every call to the two kernel NIF entry points in
  every process. The report groups the calls by kernel operation.

  Fake S3, IFC off, and an immediate model. Compaction is out of scope.
  Host speed affects timings. Compare results from the same host only.

  Run it with `--include activation_latency`. Use these settings:

  - `ROUND_KERNEL_PROFILE_MESSAGES`: history sizes, comma-separated.
  - `ROUND_KERNEL_PROFILE_INPUTS`: measured inputs for each size.
  - `ROUND_KERNEL_PROFILE_OUT`: a file path for the per-call rows as CSV.
  - `RKP_HOTLOOP`: labels to replay in a loop, separated by `|`. The slowest
    call of each label runs. `label@50` runs the call at that percentile.
    Attach a stack sampler to the BEAM process during the loop.
  - `RKP_HOTLOOP_SECONDS`: the loop time for each label.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.InternalSessionStore
  alias SalixVerifiedKernel.Test.ActivationFixture, as: Fixture

  @native SalixVerifiedKernel.Native

  defmodule ToolRoundLLM do
    @moduledoc "Alternates a two-call tool round and a final round."
    def complete(_messages, _tools), do: raise("profile expects streaming")

    def complete_stream(_messages, _tools, _on_delta, _opts \\ []) do
      n = :counters.get(counter(), 1)
      :counters.add(counter(), 1, 1)

      if rem(n, 2) == 0 do
        {:assistant, "checking",
         [
           %{
             id: "write-#{n}",
             name: "call",
             args: %{
               "tool" => "fs.write_file",
               "params" => %{"path" => "/notes/#{n}.txt", "content" => "note #{n}"}
             }
           },
           %{id: "list-#{n}", name: "call", args: %{"tool" => "fs.list_files", "params" => %{}}}
         ]}
      else
        {:assistant, "answered",
         [%{id: "end-#{n}", name: "end_turn", args: %{"outcome" => "done"}}]}
      end
    end

    def reset, do: :persistent_term.put({__MODULE__, :counter}, :counters.new(1, []))
    defp counter, do: :persistent_term.get({__MODULE__, :counter})
  end

  defmodule Observer do
    def agent_run(fact), do: send(pid(), {:run, fact})
    def round_phase(fact), do: send(pid(), {:phase, fact})
    def tool_call(_), do: :ok
    def llm_attempt(_), do: :ok
    defp pid, do: Application.fetch_env!(:salix_agent, :round_kernel_profile_pid)
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    ToolRoundLLM.reset()

    changes = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_agent, :llm, ToolRoundLLM},
      {:salix_agent, :agent_observability_mod, Observer},
      {:salix_agent, :round_kernel_profile_pid, self()},
      {:salix_agent, :ifc_facts_mod, nil}
    ]

    previous =
      Enum.map(changes, fn {app, key, value} ->
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end)

    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      Enum.each(previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end)

    :ok
  end

  @tag :activation_latency
  @tag timeout: 900_000
  test "profile kernel calls of tool and final rounds across history sizes" do
    sizes =
      "ROUND_KERNEL_PROFILE_MESSAGES"
      |> System.get_env("1,1000,4000")
      |> String.split(",")
      |> Enum.map(&String.to_integer/1)

    inputs = String.to_integer(System.get_env("ROUND_KERNEL_PROFILE_INPUTS", "5"))

    rows =
      for size <- sizes do
        {agent_id, session_id} = seed(size)
        # The first input starts the actor and loads its revision.
        run_input(agent_id, session_id, "warmup")

        # Untraced inputs give the wall time without the trace overhead.
        untraced =
          for i <- 1..inputs do
            {us, _} = :timer.tc(fn -> run_input(agent_id, session_id, "untraced-#{i}") end)
            us
          end

        for i <- 1..inputs do
          {calls, wall_us} = capture(fn -> run_input(agent_id, session_id, "input-#{i}") end)
          Enum.map(calls, &Map.merge(&1, %{size: size, input: i, wall_us: wall_us}))
        end
        |> List.flatten()
        |> tap(&report(size, inputs, untraced, &1))
      end
      |> List.flatten()

    if path = System.get_env("ROUND_KERNEL_PROFILE_OUT"), do: write_csv(path, rows)
    if hot = System.get_env("RKP_HOTLOOP"), do: hotloop(hot, rows)
    assert rows != []
  end

  # ---- scenario ----

  defp seed(size) do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)

    SalixAgent.TestSupport.create_control_agent!(agent_id, %{
      tenant_id: SalixStore.Ids.tenant_id_from_group!(group_id),
      group_id: group_id,
      role: "worker",
      # Keep every size on the no-compaction path.
      context_tokens: 100_000_000
    })

    session_id = "ses1_" <> String.pad_leading(Integer.to_string(size), 19, "0")
    session = Fixture.build(agent_id, session_id, messages: size, refs: min(size, 600))
    assert :ok = InternalSessionStore.prepare_seed(agent_id, session)
    {agent_id, session_id}
  end

  defp run_input(agent_id, session_id, source) do
    assert {:ok, _} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: "Answer #{source}.",
                 role: "user",
                 session_id: session_id,
                 created_at: System.system_time(:second)
               },
               source_message_id: "#{session_id}-#{source}"
             )

    assert_receive {:run, %{status: "completed"}}, 120_000
    :ok = SalixAgent.TestSupport.await_session_quiet(agent_id, session_id, 60_000)
    flush()
  end

  defp flush do
    receive do
      {tag, _} when tag in [:run, :phase] -> flush()
    after
      0 -> :ok
    end
  end

  # ---- capture ----

  defp capture(fun) do
    tracer = spawn_link(fn -> collect([]) end)
    session = :trace.session_create(:round_kernel_profile, tracer, [])

    match = [
      {:_, [], [{:message, {:current_stacktrace, 16}}, {:return_trace}, {:exception_trace}]}
    ]

    1 = :trace.function(session, {@native, :session, 2}, match, [:local])
    1 = :trace.function(session, {@native, :invoke_etf, 1}, match, [:local])
    :trace.process(session, :all, true, [:call, :monotonic_timestamp])

    started = System.monotonic_time(:microsecond)
    fun.()
    wall_us = System.monotonic_time(:microsecond) - started

    true = :trace.session_destroy(session)
    send(tracer, {:done, self()})
    events = receive(do: ({:events, events} -> events))
    {pair(events), wall_us}
  end

  defp collect(acc) do
    receive do
      {:done, from} ->
        send(from, {:events, drain(acc)})

      event ->
        collect([event | acc])
    end
  end

  defp drain(acc) do
    receive do
      event when elem(event, 0) == :trace_ts -> drain([event | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  # One row for each call: its caller, entry point, arguments, result, and
  # duration between the call and its return.
  defp pair(events) do
    {rows, _open} =
      Enum.reduce(events, {[], %{}}, fn
        {:trace_ts, pid, :call, {@native, fun, args}, stack, ts}, {rows, open} ->
          {rows, Map.put(open, pid, {fun, args, stack, ts})}

        {:trace_ts, pid, kind, {@native, _, _}, result, ts}, {rows, open}
        when kind in [:return_from, :exception_from] ->
          {fun, args, stack, started} = Map.fetch!(open, pid)

          row = %{
            pid: pid,
            caller: caller(stack),
            started: started,
            ended: ts,
            fun: fun,
            args: args,
            result: result,
            ok: kind == :return_from,
            ns: :erlang.convert_time_unit(ts - started, :native, :nanosecond)
          }

          {[row | rows], Map.delete(open, pid)}

        _, acc ->
          acc
      end)

    rows |> Enum.reverse() |> label()
  end

  # ---- classification ----

  defp label(rows) do
    {labelled, _stacks} =
      Enum.map_reduce(rows, %{}, fn row, stacks ->
        {request, response} = io(row)
        req = :erlang.binary_to_term(request)
        {name, stacks} = name(row.pid, req, observe(response), stacks)

        labelled = %{
          pid: row.pid,
          caller: row.caller,
          started: row.started,
          ended: row.ended,
          label: name,
          ns: row.ns,
          replay_ns: replay_ns(row),
          fun: row.fun,
          args: row.args,
          ok: row.ok,
          req_bytes: byte_size(request),
          resp_bytes: if(is_binary(response), do: byte_size(response), else: 0),
          encode_ns: time_ns(fn -> :erlang.term_to_binary(req, minor_version: 2) end),
          decode_ns:
            if(is_binary(response),
              do: time_ns(fn -> :erlang.binary_to_term(response, [:safe, :used]) end),
              else: 0
            )
        }

        {labelled, stacks}
      end)

    labelled
  end

  # Handles are immutable, so the same call can run again after the input
  # settles. The fastest of three runs is the call's own cost without the
  # lineage lock or dirty-scheduler waits of the actual run.
  defp replay_ns(%{fun: fun, args: args}) do
    for _ <- 1..3 do
      {ns, _} = :timer.tc(fn -> apply(@native, fun, args) end, :nanosecond)
      ns
    end
    |> Enum.min()
  end

  defp io(%{fun: :invoke_etf, args: [request], result: response}), do: {request, response}

  defp io(%{fun: :session, args: [_resident, request], result: {_next, response}}),
    do: {request, response}

  defp io(%{fun: :session, args: [_resident, request]}), do: {request, nil}

  # A query that asks the host for a read waits on a per-process stack until
  # its resume; a read callback can run other kernel calls in between.
  defp name(pid, {1, domain, 1, op, payload}, observed, stacks) do
    stack = Map.get(stacks, pid, [])

    {name, stack} =
      case {domain, op} do
        {:session, op} when op in [:query, :lifecycle] ->
          {"session.#{op}:#{elem(payload, 0)}", stack}

        {:session, :step} ->
          {"session.step:#{event_type(elem(payload, 0))}", stack}

        {:session, :resume} ->
          case stack do
            [{base, kind} | rest] -> {{base, "#{base} <resume #{kind}>"}, rest}
            [] -> {"session.resume", []}
          end

        {domain, op} ->
          {"#{domain}.#{op}", stack}
      end

    {base, name} =
      case name do
        {base, name} -> {base, name}
        name -> {name, name}
      end

    stack = if observed, do: [{base, observed} | stack], else: stack
    {name, Map.put(stacks, pid, stack)}
  end

  # The first frames outside the kernel facades name the host path.
  @facades [
    SalixAgent.InternalSession,
    SalixAgent.SessionDriver,
    Enum,
    :lists,
    :timer,
    SystemsObservability.Trace,
    :otel_tracer,
    :otel_tracer_default
  ]

  defp caller(stack) when is_list(stack) do
    stack
    |> Enum.reject(fn {module, _, _, _} ->
      module in @facades or
        String.starts_with?(Atom.to_string(module), "Elixir.SalixVerifiedKernel")
    end)
    |> Enum.take(2)
    |> Enum.map_join(" < ", fn {module, fun, arity, _} ->
      "#{inspect(module) |> String.replace_prefix("SalixAgent.", "")}.#{fun}/#{arity(arity)}"
    end)
  end

  defp caller(_), do: "?"

  defp arity(arity) when is_list(arity), do: length(arity)
  defp arity(arity), do: arity

  defp event_type(%{"type" => type}), do: type
  defp event_type(%{type: type}), do: type
  defp event_type(_), do: "?"

  defp observe(response) when is_binary(response) do
    case :erlang.binary_to_term(response) do
      {1, :ok, {:observe, request, _token}} -> read_kind(request)
      {1, :ok, {:observe, request}} -> read_kind(request)
      _ -> nil
    end
  end

  defp observe(_), do: nil

  defp read_kind(request) when is_atom(request), do: Atom.to_string(request)

  defp read_kind({:request_batch, requests}),
    do: "batch[" <> (requests |> Enum.map(&read_kind/1) |> Enum.uniq() |> Enum.join(",")) <> "]"

  defp read_kind({:held, key}), do: "held:#{key}"
  defp read_kind(request) when is_tuple(request), do: read_kind(elem(request, 0))
  defp read_kind(request), do: inspect(request, limit: 3)

  defp time_ns(fun) do
    samples =
      for _ <- 1..3 do
        {us, _} = :timer.tc(fun, :nanosecond)
        us
      end

    samples |> Enum.sort() |> Enum.at(1)
  end

  # ---- report ----

  defp report(size, inputs, untraced, rows) do
    wall = rows |> Enum.uniq_by(& &1.input) |> Enum.map(& &1.wall_us) |> Enum.sum()
    kernel = rows |> Enum.map(& &1.ns) |> Enum.sum()
    isolated = rows |> Enum.map(& &1.replay_ns) |> Enum.sum()
    host = rows |> Enum.map(&(&1.encode_ns + &1.decode_ns)) |> Enum.sum()

    overlapped =
      rows |> Enum.group_by(& &1.input) |> Enum.map(&overlapped_ns(elem(&1, 1))) |> Enum.sum()

    IO.puts("""

    == #{size} history messages: #{inputs} inputs, 2 model rounds each ==
    wall per input: untraced #{fmt_ms(Enum.sum(untraced) * 1000 / inputs)}, traced #{fmt_ms(wall * 1000 / inputs)}
    NIF calls per input #{Float.round(length(rows) / inputs, 1)}; \
    NIF time per input #{fmt_ms(kernel / inputs)} \
    (#{fmt_ms(overlapped / inputs)} while another process was also in the kernel); \
    isolated replay per input #{fmt_ms(isolated / inputs)}; \
    ETF encode+decode per input #{fmt_ms(host / inputs)}
    """)

    table("operation", inputs, Enum.group_by(rows, & &1.label), 1_000)
    IO.puts("")
    table("host caller", inputs, Enum.group_by(rows, & &1.caller), 25)
  end

  defp table(title, inputs, groups, limit) do
    IO.puts(
      :io_lib.format("~-70ts ~6ts ~9ts ~9ts ~9ts ~9ts ~9ts ~9ts ~9ts ~9ts", [
        title,
        "n/in",
        "ms/in",
        "iso ms",
        "p50 us",
        "p95 us",
        "max us",
        "req KB",
        "resp KB",
        "enc+dec"
      ])
    )

    groups
    |> Enum.map(fn {label, calls} ->
      ns = calls |> Enum.map(& &1.ns) |> Enum.sort()
      {label, calls, ns, Enum.sum(ns)}
    end)
    |> Enum.sort_by(fn {_, _, _, total} -> -total end)
    |> Enum.take(limit)
    |> Enum.each(fn {label, calls, ns, total} ->
      n = length(calls)

      IO.puts(
        :io_lib.format("~-70ts ~6.1f ~9.3f ~9.3f ~9.1f ~9.1f ~9.1f ~9.1f ~9.1f ~9.3f", [
          String.slice(label, 0, 70),
          n / inputs,
          total / inputs / 1.0e6,
          Enum.sum(Enum.map(calls, & &1.replay_ns)) / inputs / 1.0e6,
          pct(ns, 0.5) / 1000,
          pct(ns, 0.95) / 1000,
          List.last(ns) / 1000,
          avg(calls, :req_bytes) / 1024,
          avg(calls, :resp_bytes) / 1024,
          (Enum.sum(Enum.map(calls, & &1.encode_ns)) + Enum.sum(Enum.map(calls, & &1.decode_ns))) /
            inputs / 1.0e6
        ])
      )
    end)
  end

  # NIF time of calls that overlapped a kernel call in another process: the
  # lineage lock or the dirty schedulers can make one call wait for another.
  defp overlapped_ns(calls) do
    calls
    |> Enum.filter(fn call ->
      Enum.any?(calls, fn other ->
        other.pid != call.pid and other.started < call.ended and call.started < other.ended
      end)
    end)
    |> Enum.map(& &1.ns)
    |> Enum.sum()
  end

  defp pct(sorted, p), do: Enum.at(sorted, min(length(sorted) - 1, trunc(p * length(sorted))))
  defp avg(calls, key), do: Enum.sum(Enum.map(calls, &Map.fetch!(&1, key))) / length(calls)
  defp fmt_ms(ns), do: :io_lib.format("~.2f ms", [ns / 1.0e6]) |> to_string()

  # Replays the slowest captured call of each named operation for a fixed
  # time, so an external sampler can attribute its time to Lean functions.
  defp hotloop(spec, rows) do
    seconds = String.to_integer(System.get_env("RKP_HOTLOOP_SECONDS", "15"))

    for entry <- String.split(spec, "|") do
      # `label@50` replays the call at that percentile instead of the slowest.
      {label, calls} =
        case String.split(entry, "@") do
          [label, pct] ->
            sorted = rows |> Enum.filter(&(&1.label == label)) |> Enum.sort_by(& &1.replay_ns)
            {label, [Enum.at(sorted, div(length(sorted) * String.to_integer(pct), 100))]}

          [label] ->
            {label, rows |> Enum.filter(&(&1.label == label))}
        end

      call = Enum.max_by(calls, & &1.replay_ns)

      IO.puts(
        "HOTLOOP start #{label} #{System.os_time(:millisecond)} (#{div(call.replay_ns, 1000)} us)"
      )

      deadline = System.monotonic_time(:millisecond) + seconds * 1000

      loop = fn loop, n ->
        if System.monotonic_time(:millisecond) < deadline do
          apply(@native, call.fun, call.args)
          loop.(loop, n + 1)
        else
          n
        end
      end

      runs = loop.(loop, 0)
      IO.puts("HOTLOOP stop #{label} #{System.os_time(:millisecond)} runs=#{runs}")
    end
  end

  defp write_csv(path, rows) do
    header =
      "size,input,wall_us,started_ns,ended_ns,pid,caller,label,ns,replay_ns,ok,req_bytes,resp_bytes,encode_ns,decode_ns\n"

    body =
      Enum.map(rows, fn r ->
        [
          r.size,
          r.input,
          r.wall_us,
          :erlang.convert_time_unit(r.started, :native, :nanosecond),
          :erlang.convert_time_unit(r.ended, :native, :nanosecond),
          inspect(r.pid),
          ~s("#{r.caller}"),
          ~s("#{String.replace(r.label, "\"", "'")}"),
          r.ns,
          r.replay_ns,
          r.ok,
          r.req_bytes,
          r.resp_bytes,
          r.encode_ns,
          r.decode_ns
        ]
        |> Enum.join(",")
        |> Kernel.<>("\n")
      end)

    File.write!(path, [header | body])
  end
end
