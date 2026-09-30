defmodule SalixAgent.SubscriptionWorker do
  @moduledoc "Supervised subscription subprocess with bounded, acknowledged streams."
  use GenServer
  alias SalixAgent.SubscriptionLog, as: Log
  @limit 64
  @frame_limit 16 * 1024 * 1024

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
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

    id = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    payload = Jason.encode!(%{type: "call", id: id, op: op, body: body, credential: credential})

    stats = :atomics.new(3, signed: false)
    started = System.monotonic_time(:millisecond)

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
          monitor = Process.monitor(server)
          reply_to = :erlang.alias()

          try do
            case GenServer.call(server, {:start, id, payload, reply_to}, 5_000) do
              :ok -> receive_data(server, monitor, id, observed_consume, acc, timeout)
              {:error, code} -> {:error, 503, code, acc}
            end
          catch
            :exit, _ -> {:error, 503, "worker_unavailable", acc}
          after
            :erlang.unalias(reply_to)
            GenServer.cast(server, {:cancel, id, self()})
            Process.demonitor(monitor, [:flush])
            flush(id)
          end
        end
      end,
      fn -> Log.stats(stats) end
    )
  end

  defp request_timeout(op, body) do
    if op in ["/v1/responses", "/v1/responses/compact", "/v1/messages"] and is_map(body) and
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
    receive do
      {:subscription, ^id, %{"type" => "data", "data" => data}} ->
        case consume.(Base.decode64!(data), acc) do
          {:cont, next} ->
            GenServer.cast(server, {:ack, id, self()})
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
    receive do
      {:subscription, ^id, _} -> flush(id)
    after
      0 -> :ok
    end
  end

  def server, do: Application.get_env(:salix_agent, :subscription_worker, __MODULE__)

  # Reuse the provider clients' request construction and incremental parsers.
  # Req is only a response container here; no socket or HTTP request is created.
  def post(path, opts, credential, on_chunk \\ fn -> :ok end, on_rejected \\ fn -> :ok end) do
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

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{port: nil, calls: %{}, command: opts[:command]}}
  end

  @impl true
  def handle_call({:start, id, payload, reply_to}, {pid, _}, state) do
    if map_size(state.calls) >= @limit do
      {:reply, {:error, "worker_busy"}, state}
    else
      case ensure_port(state) do
        {:ok, state} ->
          if Port.command(state.port, payload, [:nosuspend]) do
            monitor = Process.monitor(pid)

            timer =
              Process.send_after(self(), {:deadline, id}, SalixAgent.LLM.request_timeout_ms())

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

        :error ->
          {:reply, {:error, "worker_unavailable"}, state}
      end
    end
  end

  defp ensure_port(%{port: port} = state) when is_port(port), do: {:ok, state}

  defp ensure_port(state) do
    {exe, args} =
      state.command || {Path.join(:code.priv_dir(:salix_agent), "subscription_worker"), []}

    port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, {:packet, 4}, args: args])
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
    case Jason.decode(bytes) do
      {:ok, %{"id" => id, "type" => type} = event} when type in ["data", "done", "error"] ->
        if call = state.calls[id], do: send(call.reply_to, {:subscription, id, event})
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

      send(
        call.reply_to,
        {:subscription, id, %{"type" => "error", "status" => 504, "code" => "worker_timeout"}}
      )
    end

    {:noreply, state |> send_control(:cancel, id) |> finish(id)}
  end

  def handle_info({port, {:exit_status, _}}, %{port: port} = state),
    do: {:noreply, fail_calls(state)}

  def handle_info({:EXIT, port, _}, %{port: port} = state), do: {:noreply, fail_calls(state)}
  def handle_info(_, state), do: {:noreply, state}

  defp send_control(%{port: nil} = state, _, _), do: state

  defp send_control(state, kind, id) do
    if Port.command(state.port, Jason.encode!(%{type: kind, id: id}), [:nosuspend]),
      do: state,
      else: fail_calls(state)
  rescue
    _ -> fail_calls(state)
  end

  defp finish(state, id) do
    case Map.pop(state.calls, id) do
      {nil, _} ->
        state

      {call, calls} ->
        Process.cancel_timer(call.timer)
        Process.demonitor(call.monitor, [:flush])
        %{state | calls: calls}
    end
  end

  defp fail_calls(state) do
    Log.emit("subscription_worker_stopped", active_calls: map_size(state.calls))
    if state.port, do: close_port(state.port)

    Enum.reduce(state.calls, %{state | port: nil}, fn {id, call}, acc ->
      send(
        call.reply_to,
        {:subscription, id, %{"type" => "error", "status" => 503, "code" => "worker_down"}}
      )

      finish(acc, id)
    end)
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  @impl true
  def terminate(_, state), do: fail_calls(state)
end
