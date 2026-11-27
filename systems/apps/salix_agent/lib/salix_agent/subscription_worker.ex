defmodule SalixAgent.SubscriptionWorker do
  require SystemsRuntime.Proc

  require SystemsClock

  @moduledoc """
  Supervised subscription subprocess with bounded, acknowledged streams.

  The `:port_module` option defaults to `Port`. Test adapters implement its
  `open/2`, `command/3` and `close/1` calls and deliver the same port messages.
  """
  use SystemsRuntime.Server
  alias SalixAgent.SubscriptionLog, as: Log
  @limit 64
  @frame_limit 16 * 1024 * 1024
  # A pipe write refused under `:nosuspend` is retried this often, and only a
  # pipe that stays full this long stops the subprocess.
  @control_retry_ms 5
  @control_blocked_limit_ms 10_000

  def start_link(opts \\ []) do
    SystemsRuntime.Server.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def request(op, body, credential \\ %{}, opts \\ []) do
    server = Keyword.get(opts, :server, server())
    consume = Keyword.get(opts, :consume, fn bytes, acc -> {:cont, acc <> bytes} end)
    acc = Keyword.get(opts, :acc, "")

    timeout =
      case Keyword.get(opts, :timeout) do
        ms when is_integer(ms) and ms > 0 -> {ms, "worker_timeout", {ms, "worker_timeout"}}
        _ -> request_timeout(op, body)
      end

    id = Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive, :monotonic]))
    payload = Jason.encode!(%{type: "call", id: id, op: op, body: body, credential: credential})

    stats = SystemsRuntime.Atomics.new(3, signed: false)
    started = SystemsClock.monotonic_time(:millisecond)

    observed_consume = fn bytes, current ->
      Log.frame(stats, bytes, started)
      consume.(bytes, current)
    end

    fields = [
      worker_request_id: id,
      operation: op,
      stream: is_map(body) and Map.get(body, "stream") == true
    ]

    Log.span(
      "subscription_worker_call",
      fields,
      fn ->
        if byte_size(payload) > @frame_limit do
          {:error, 413, "request_too_large", acc}
        else
          monitor = SystemsRuntime.Proc.monitor(server)
          reply_to = SystemsRuntime.Proc.alias()

          try do
            case SystemsClock.call(server, {:start, id, payload, reply_to}, 5_000) do
              :ok -> receive_data(server, monitor, id, observed_consume, acc, timeout)
              {:error, code} -> {:error, 503, code, acc}
            end
          catch
            :exit, _ -> {:error, 503, "worker_unavailable", acc}
          after
            SystemsRuntime.Proc.unalias(reply_to)
            SystemsRuntime.Server.cast(server, {:cancel, id, SystemsRuntime.Proc.self()})
            SystemsRuntime.Proc.demonitor(monitor, [:flush])
            flush(id)
          end
        end
      end,
      fn -> Log.stats(stats) end
    )
  end

  defp request_timeout(op, body) do
    if op in ["/v1/responses", "/v1/responses/compact", "/v1/messages", "/v1/chat/completions"] and
         is_map(body) and
         body["stream"] == true do
      {SalixAgent.LLM.stream_first_event_timeout_ms(), "worker_first_event_timeout",
       {SalixAgent.LLM.stream_idle_timeout_ms(), "worker_idle_timeout"}}
    else
      # Blocking executors emit only after the complete response arrives.
      budget = SalixAgent.LLM.request_timeout_ms()
      {budget, "worker_timeout", {budget, "worker_timeout"}}
    end
  end

  defp receive_data(server, monitor, id, consume, acc, {timeout_ms, timeout_code, next_timeout}) do
    SystemsClock.vreceive do
      {:subscription, ^id, %{"type" => "data", "data" => data}} ->
        case consume.(Base.decode64!(data), acc) do
          {:cont, next} ->
            SystemsRuntime.Server.cast(server, {:ack, id, SystemsRuntime.Proc.self()})
            {idle_ms, idle_code} = next_timeout
            receive_data(server, monitor, id, consume, next, {idle_ms, idle_code, next_timeout})

          {:halt, next} ->
            {:ok, next}
        end

      {:subscription, ^id, %{"type" => "done"}} ->
        {:ok, acc}

      {:subscription, ^id, %{"type" => "error", "status" => status, "code" => code}} ->
        {:error, status, code, acc}

      {:DOWN, ^monitor, :process, _, _} ->
        {:error, 503, "worker_down", acc}
    after
      timeout_ms -> {:error, 504, timeout_code, acc}
    end
  end

  defp flush(id) do
    SystemsRuntime.Proc.receive do
      {:subscription, ^id, _} -> flush(id)
    after
      0 -> :ok
    end
  end

  def server, do: SystemsRuntime.get_env(:salix_agent, :subscription_worker, __MODULE__)

  # Reuse the provider clients' request construction and incremental parsers.
  # Req is only a response container here; no socket or HTTP request is created.
  def post(
        path,
        opts,
        credential,
        on_chunk \\ fn -> :ok end,
        on_rejected \\ fn -> :ok end,
        on_local_failure \\ fn -> :ok end
      ) do
    body = opts[:json] || Jason.decode!(opts[:body])
    into = opts[:into]
    response = Req.Response.new(status: 200, body: "")

    consume = fn bytes, {resp, seen} ->
      if bytes != "", do: on_chunk.()

      if into do
        {action, {_, resp}} = into.({:data, bytes}, {Req.new(), resp})
        {action, {resp, seen or bytes != ""}}
      else
        {:cont, {%{resp | body: resp.body <> bytes}, seen or bytes != ""}}
      end
    end

    case request(path, body, credential, consume: consume, acc: {response, false}) do
      {:ok, {resp, _}} ->
        {:ok, resp}

      {:error, status, code, {resp, seen}} ->
        if not seen and rejected_before_execution?(status, code), do: on_rejected.()
        if local_failure?(code), do: on_local_failure.()

        if seen and into do
          {:error, %RuntimeError{message: code}, resp}
        else
          error_body = Jason.encode!(%{error: %{message: code, code: code}})
          resp = %{resp | status: status, body: error_body}

          if into do
            {_, {_, resp}} = into.({:data, error_body}, {Req.new(), resp})
            {:ok, resp}
          else
            {:ok, resp}
          end
        end
    end
  end

  def rejected_before_execution?(status, "worker_busy") when status in [429, 503], do: true
  def rejected_before_execution?(413, "request_too_large"), do: true
  def rejected_before_execution?(_, _), do: false

  @doc """
  Whether `code` is a failure of this worker on this node, not of the
  upstream account the call used.
  """
  def local_failure?(code), do: code in ~w(worker_down worker_unavailable worker_busy)

  @impl true
  def init(opts) do
    SystemsRuntime.Proc.trap_exit(true)

    {:ok,
     %{
       port: nil,
       calls: %{},
       command: opts[:command],
       port_module: opts[:port_module] || Port,
       # Control frames (`:ack`, `:cancel`) a full pipe refused, by call id:
       # at most one per call, so bounded by the active calls (`@limit`).
       pending_controls: %{},
       control_blocked_since: nil,
       flush_timer: nil
     }}
  end

  @impl true
  def handle_call({:start, id, payload, reply_to}, {pid, _}, state) do
    if map_size(state.calls) >= @limit do
      {:reply, {:error, "worker_busy"}, state}
    else
      with {:ok, state} <- flush_controls(state),
           {:ok, state} <- ensure_port(state) do
        if state.port_module.command(state.port, payload, [:nosuspend]) do
          monitor = SystemsRuntime.Proc.monitor(pid)

          timer =
            SystemsClock.send_after(
              SystemsRuntime.Proc.self(),
              {:deadline, id},
              SalixAgent.LLM.request_timeout_ms()
            )

          {:reply, :ok,
           put_in(state.calls[id], %{
             pid: pid,
             reply_to: reply_to,
             monitor: monitor,
             timer: timer
           })}
        else
          {:reply, {:error, "worker_busy"}, state}
        end
      else
        # Control frames still wait for the pipe: a new request would only
        # fill it further.
        {:blocked, state} -> {:reply, {:error, "worker_busy"}, state}
        :error -> {:reply, {:error, "worker_unavailable"}, state}
      end
    end
  rescue
    _ -> {:reply, {:error, "worker_unavailable"}, fail_calls(state)}
  end

  defp ensure_port(%{port: port} = state) when not is_nil(port), do: {:ok, state}

  defp ensure_port(state) do
    {exe, args} =
      state.command || {Path.join(:code.priv_dir(:salix_agent), "subscription_worker"), []}

    port =
      state.port_module.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        {:packet, 4},
        args: args
      ])

    Log.emit("subscription_worker_started")
    {:ok, %{state | port: port}}
  rescue
    _ -> :error
  end

  @impl true
  def handle_cast({kind, id, pid}, state) when kind in [:ack, :cancel] do
    case state.calls[id] do
      %{pid: ^pid} ->
        state = send_control(state, kind, id)
        {:noreply, if(kind == :cancel, do: finish(state, id), else: state)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    state = flush_controls!(state)

    case Jason.decode(bytes) do
      {:ok, %{"id" => id, "type" => type} = event} when type in ["data", "done", "error"] ->
        if call = state.calls[id],
          do: SystemsRuntime.Proc.send(call.reply_to, {:subscription, id, event})

        {:noreply, if(type == "data", do: state, else: finish(state, id))}

      _ ->
        {:noreply, fail_calls(state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Enum.find(state.calls, fn {_, c} -> c.monitor == ref end) do
      {id, _} ->
        Log.emit("subscription_worker_caller_cancelled",
          worker_request_id: id,
          outcome: "cancelled",
          error_code: "caller_cancelled"
        )

        {:noreply, state |> send_control(:cancel, id) |> finish(id)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:deadline, id}, state) do
    if call = state.calls[id] do
      Log.emit("subscription_worker_deadline",
        worker_request_id: id,
        outcome: "error",
        error_code: "worker_timeout"
      )

      SystemsRuntime.Proc.send(
        call.reply_to,
        {:subscription, id, %{"type" => "error", "status" => 504, "code" => "worker_timeout"}}
      )
    end

    {:noreply, state |> send_control(:cancel, id) |> finish(id)}
  end

  def handle_info(:flush_controls, state),
    do: {:noreply, flush_controls!(%{state | flush_timer: nil})}

  def handle_info({port, {:exit_status, _}}, %{port: port} = state),
    do: {:noreply, fail_calls(state)}

  def handle_info({:EXIT, port, _}, %{port: port} = state), do: {:noreply, fail_calls(state)}
  def handle_info(_, state), do: {:noreply, state}

  defp send_control(%{port: nil} = state, _, _), do: state

  # A pipe a concurrent large request fills refuses a `:nosuspend` write for a
  # few milliseconds. The frame waits in `pending_controls` instead of
  # stopping the subprocess and every call on it.
  defp send_control(state, kind, id) do
    state |> queue_control(kind, id) |> flush_controls!()
  end

  defp queue_control(state, kind, id) do
    pending =
      case {kind, state.pending_controls[id]} do
        # A cancel supersedes an unsent ack of the same call.
        {:ack, :cancel} -> state.pending_controls
        _ -> Map.put(state.pending_controls, id, kind)
      end

    since = state.control_blocked_since || SystemsClock.monotonic_time(:millisecond)
    %{state | pending_controls: pending, control_blocked_since: since}
  end

  defp flush_controls!(state) do
    case flush_controls(state) do
      {:ok, state} -> state
      {:blocked, state} -> state
    end
  end

  # Writes the waiting control frames. `{:blocked, state}` while the pipe still
  # refuses one; a pipe full past `@control_blocked_limit_ms`, or a write that
  # raises, stops the subprocess and fails its calls.
  defp flush_controls(%{pending_controls: pending} = state) when map_size(pending) == 0,
    do: {:ok, state}

  defp flush_controls(%{port: nil} = state), do: {:ok, clear_controls(state)}

  defp flush_controls(state) do
    left =
      Enum.reduce_while(state.pending_controls, state.pending_controls, fn {id, kind}, left ->
        cond do
          # The call ended: nothing reads its acknowledgement.
          kind == :ack and not Map.has_key?(state.calls, id) ->
            {:cont, Map.delete(left, id)}

          state.port_module.command(state.port, Jason.encode!(%{type: kind, id: id}), [
            :nosuspend
          ]) ->
            {:cont, Map.delete(left, id)}

          true ->
            {:halt, left}
        end
      end)

    state = %{state | pending_controls: left}

    cond do
      map_size(left) == 0 ->
        {:ok, clear_controls(state)}

      SystemsClock.monotonic_time(:millisecond) - state.control_blocked_since >=
          @control_blocked_limit_ms ->
        Log.emit("subscription_worker_control_blocked", active_calls: map_size(state.calls))
        {:ok, fail_calls(state)}

      true ->
        {:blocked, arm_flush(state)}
    end
  rescue
    _ -> {:ok, fail_calls(state)}
  end

  defp arm_flush(%{flush_timer: nil} = state) do
    timer =
      SystemsClock.send_after(SystemsRuntime.Proc.self(), :flush_controls, @control_retry_ms)

    %{state | flush_timer: timer}
  end

  defp arm_flush(state), do: state

  defp clear_controls(state) do
    SystemsClock.cancel_timer(state.flush_timer)
    %{state | pending_controls: %{}, control_blocked_since: nil, flush_timer: nil}
  end

  defp finish(state, id) do
    case Map.pop(state.calls, id) do
      {nil, _} ->
        state

      {call, calls} ->
        SystemsClock.cancel_timer(call.timer)
        SystemsRuntime.Proc.demonitor(call.monitor, [:flush])
        %{state | calls: calls}
    end
  end

  defp fail_calls(state) do
    Log.emit("subscription_worker_stopped", active_calls: map_size(state.calls))
    if state.port, do: close_port(state)

    Enum.reduce(state.calls, %{clear_controls(state) | port: nil}, fn {id, call}, acc ->
      SystemsRuntime.Proc.send(
        call.reply_to,
        {:subscription, id, %{"type" => "error", "status" => 503, "code" => "worker_down"}}
      )

      finish(acc, id)
    end)
  end

  defp close_port(state) do
    state.port_module.close(state.port)
  rescue
    _ -> :ok
  end

  @impl true
  def terminate(_, state), do: fail_calls(state)
end
