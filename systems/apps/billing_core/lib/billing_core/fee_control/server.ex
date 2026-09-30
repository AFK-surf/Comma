defmodule BillingCore.FeeControl.Server do
  @moduledoc false

  use GenServer

  alias BillingCore.{FeeControl, State}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def check(attrs, opts \\ []) do
    timeout = opts[:timeout] || 5_000
    GenServer.call(opts[:server] || __MODULE__, {:check, attrs, timeout}, timeout)
  end

  @impl true
  def init(_opts) do
    {:ok, supervisor} = Task.Supervisor.start_link()
    {:ok, %{supervisor: supervisor, cache: %{}, pending: %{}, sequence: 0}}
  end

  @impl true
  def handle_call({:check, attrs, timeout}, from, state) do
    key = FeeControl.cache_key(attrs)
    {_sequence, cached} = Map.get(state.cache, key, {0, nil})
    context = SystemsObservability.Context.capture()

    task =
      Task.Supervisor.async_nolink(state.supervisor, fn ->
        SystemsObservability.Context.run(context, fn -> run_check(attrs, key, cached) end)
      end)

    timer =
      if timeout == :infinity,
        do: nil,
        else: Process.send_after(self(), {:check_timeout, task.ref}, timeout)

    sequence = state.sequence + 1
    pending = %{from: from, key: key, sequence: sequence, timer: timer, pid: task.pid}
    {:noreply, %{state | sequence: sequence, pending: Map.put(state.pending, task.ref, pending)}}
  end

  @impl true
  def handle_info({ref, {:ok, result, entry}}, state) when is_reference(ref) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        {:noreply, state}

      {pending, rest} ->
        Process.demonitor(ref, [:flush])
        cancel_timer(pending.timer)
        # Concurrent queries can finish out of order. Only a newer started
        # successful refresh can replace this key's shadow-cache entry.
        {previous, _} = Map.get(state.cache, pending.key, {0, nil})

        cache =
          if entry != :unchanged and pending.sequence > previous,
            do: Map.put(state.cache, pending.key, {pending.sequence, entry}),
            else: state.cache

        GenServer.reply(pending.from, {:ok, result})
        {:noreply, %{state | pending: rest, cache: cache}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    finish_error(state, ref, :fee_control_check_failed)
  end

  def handle_info({:check_timeout, ref}, state) do
    case state.pending[ref] do
      nil ->
        {:noreply, state}

      pending ->
        Process.exit(pending.pid, :kill)
        Process.demonitor(ref, [:flush])
        finish_error(state, ref, :fee_control_check_timeout)
    end
  end

  @impl true
  def terminate(_reason, state), do: Supervisor.stop(state.supervisor)

  defp finish_error(state, ref, reason) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        {:noreply, state}

      {pending, rest} ->
        cancel_timer(pending.timer)
        GenServer.reply(pending.from, {:error, reason})
        {:noreply, %{state | pending: rest}}
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp run_check(attrs, key, cached) do
    started = System.monotonic_time()
    cache = if is_nil(cached), do: %{}, else: %{key => cached}

    try do
      {:ok, result, next_state} = FeeControl.check(State.new(fee_control_cache: cache), attrs)
      maybe_write_check(result, attrs)

      BillingTelemetry.emit_operation(
        :fee_control,
        surface(attrs),
        "ok",
        System.monotonic_time() - started
      )

      entry = next_state.fee_control_cache[key]

      {:ok, result,
       if(result.cache_hit and not result.query_performed, do: :unchanged, else: entry)}
    rescue
      exception ->
        BillingTelemetry.emit_operation(
          :fee_control,
          surface(attrs),
          "error",
          System.monotonic_time() - started
        )

        reraise exception, __STACKTRACE__
    end
  end

  defp maybe_write_check(result, attrs) do
    do_maybe_write_check(result, attrs)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp do_maybe_write_check(result, attrs) do
    with sink when not is_nil(sink) <-
           attrs[:typed_sink] || Application.get_env(:billing_core, :fee_control_typed_sink),
         context when is_map(context) <- attrs[:row_context] do
      row =
        context
        |> Map.merge(%{
          source: attrs[:source] || "fee_control",
          source_key:
            attrs[:source_key] ||
              "fee:#{context["billing_account_id"] || context[:billing_account_id]}:#{System.unique_integer([:positive])}",
          resource_kind: :fee_control,
          provider: attrs[:provider],
          sku: attrs[:sku],
          mode: result.mode,
          action: result.action,
          target_resource_kind: result.resource_kind,
          allowed: result.allowed?,
          reason: result.reason,
          entitlement_mode: Atom.to_string(result.entitlement_mode),
          decision_id: result.decision_id,
          cache_hit: result.cache_hit,
          cache_age_ms: result.cache_age_ms,
          cache_ttl_ms: result.cache_ttl_ms,
          query_performed: result.query_performed,
          query_duration_ms: result.query_duration_ms,
          result_source: if(result.query_performed, do: "pg", else: "cache"),
          would_block: result.would_block,
          would_exceed: result.would_block,
          balance_snapshot: result.balance_snapshot
        })
        |> SalixAnalytics.FeeControlCheck.build()

      safe_enqueue(sink, [row])
    else
      _ -> :ok
    end
  end

  defp safe_enqueue(sink, rows) do
    _ = sink.enqueue(rows, server: SalixAnalytics.AgentObservabilitySinkWorker)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp surface(attrs) do
    context = attrs[:row_context] || attrs["row_context"] || %{}
    attrs[:surface] || attrs["surface"] || context[:surface] || context["surface"] || "other"
  end
end
