defmodule SalixWeb.ConnectorDisconnectQueue do
  @moduledoc false
  use GenServer

  require Logger
  alias SalixEnv.Registry

  @admission_key {__MODULE__, :admission}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # Socket teardown must remain wait-free. The atomic lease is retained from
  # ingress through active work and retries, so queued + active identities stay
  # within one per-queue-generation capacity even while the GenServer is paused.
  def submit(connector_run_id, generation, owner_node) do
    operation = %{
      connector_run_id: connector_run_id,
      generation: generation,
      owner_node: owner_node
    }

    _ = try_submit(operation, nil)
    :ok
  end

  defp try_submit(operation, rejected_pid) do
    case :persistent_term.get(@admission_key, nil) do
      {pid, counter} when is_pid(pid) and pid != rejected_pid ->
        if Process.alive?(pid) and acquire_admission(counter) do
          case :persistent_term.get(@admission_key, nil) do
            {^pid, ^counter} ->
              send(pid, {:disconnect, operation})
              :submitted

            _restarted ->
              :atomics.sub(counter, 1, 1)
              :retry
          end
        else
          :retry
        end

      _unavailable ->
        :retry
    end
  end

  @impl true
  def init(_opts) do
    ingress = :atomics.new(1, signed: false)
    :persistent_term.put(@admission_key, {self(), ingress})

    {:ok,
     %{
       queue: :queue.new(),
       pending: %{},
       active: %{},
       retries: %{},
       concurrency: Application.get_env(:salix_web, :connector_disconnect_task_limit, 16),
       capacity: queue_limit()
     }}
  end

  @impl true
  def handle_info({:disconnect, operation}, state) do
    retains_admission =
      not tracked_base?(state, base(operation)) and tracked_size(state) < state.capacity

    state = enqueue(state, operation)
    unless retains_admission, do: release_admission()
    {:noreply, drain(state)}
  end

  def handle_info({:disconnect_result, token, result, wrapper}, state) do
    state =
      case Enum.find(state.active, fn {_ref, active} -> active.token == token end) do
        {ref, active} ->
          Process.demonitor(ref, [:flush])
          finish(state, ref, active, result)

        nil ->
          state
      end

    send(wrapper, {:disconnect_result_ack, token})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.fetch(state.active, ref) do
      {:ok, active} -> {:noreply, finish(state, ref, active, {:error, {:task_exit, reason}})}
      :error -> {:noreply, state}
    end
  end

  def handle_info({:disconnect_timeout, ref}, state) do
    case Map.fetch(state.active, ref) do
      {:ok, active} ->
        Process.exit(active.pid, :kill)
        Process.demonitor(ref, [:flush])
        {:noreply, finish(state, ref, active, {:error, :timeout})}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_disconnect, base, operation}, state) do
    state = %{state | retries: Map.delete(state.retries, base)}
    operation = newer(operation, state.pending[base])
    state = %{state | pending: Map.delete(state.pending, base)}
    {:noreply, state |> enqueue(operation) |> drain()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    case :persistent_term.get(@admission_key, nil) do
      {pid, _counter} when pid == self() -> :persistent_term.erase(@admission_key)
      _other -> :ok
    end

    Enum.each(state.retries, fn {_base, timer} -> Process.cancel_timer(timer) end)

    Enum.each(state.active, fn {ref, active} ->
      Process.cancel_timer(active.timer)
      Process.demonitor(ref, [:flush])
      Process.exit(active.pid, :kill)
    end)

    :ok
  end

  defp enqueue(state, nil), do: state

  defp enqueue(state, operation) do
    base = base(operation)

    cond do
      tracked_base?(state, base) ->
        %{state | pending: Map.update(state.pending, base, operation, &newer(&1, operation))}

      tracked_size(state) >= state.capacity ->
        state

      true ->
        %{
          state
          | queue: :queue.in(base, state.queue),
            pending: Map.put(state.pending, base, operation)
        }
    end
  end

  defp drain(state) when map_size(state.active) >= state.concurrency, do: state

  defp drain(state) do
    case :queue.out(state.queue) do
      {{:value, base}, queue} ->
        operation = state.pending[base]

        state = %{
          state
          | queue: queue,
            pending: Map.delete(state.pending, base)
        }

        if is_nil(operation) do
          drain(state)
        else
          parent = self()
          token = make_ref()

          {pid, ref} = spawn_monitor(fn -> execute_with_parent(parent, token, operation) end)

          timer = Process.send_after(self(), {:disconnect_timeout, ref}, task_timeout_ms())
          active = %{pid: pid, timer: timer, operation: operation, token: token}

          state = %{state | active: Map.put(state.active, ref, active)}

          drain(state)
        end

      {:empty, _queue} ->
        state
    end
  end

  defp finish(state, ref, active, result) do
    Process.cancel_timer(active.timer)
    base = base(active.operation)

    state = %{state | active: Map.delete(state.active, ref)}

    state =
      if successful?(result) do
        enqueue_pending(state, base)
      else
        Logger.warning(
          "connector disconnect failed; retrying run=#{active.operation.connector_run_id} " <>
            "reason=#{inspect(result)}"
        )

        schedule_retry(state, base, active.operation)
      end

    drain(state)
  end

  defp enqueue_pending(state, base) do
    case Map.pop(state.pending, base) do
      {nil, _pending} ->
        release_admission()
        state

      {operation, pending} ->
        enqueue(%{state | pending: pending}, operation)
    end
  end

  defp schedule_retry(state, base, operation) do
    operation = newer(operation, state.pending[base])
    state = %{state | pending: Map.delete(state.pending, base)}
    timer = Process.send_after(self(), {:retry_disconnect, base, operation}, retry_ms())
    %{state | retries: Map.put(state.retries, base, timer)}
  end

  defp safe_execute(operation) do
    case Application.get_env(:salix_web, :connector_disconnect_executor) do
      fun when is_function(fun, 1) -> fun.(operation)
      _ -> Registry.mark_disconnected(operation.connector_run_id, registry_opts(operation))
    end
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp registry_opts(operation) do
    [connection_generation: operation.generation, owner_node: operation.owner_node]
  end

  defp successful?(:ok), do: true
  defp successful?({:ok, _}), do: true
  defp successful?({:error, :not_found}), do: true
  defp successful?(_), do: false

  defp newer(nil, operation), do: operation
  defp newer(operation, nil), do: operation

  defp newer(left, right) do
    if right.generation >= left.generation, do: right, else: left
  end

  defp base(operation), do: {operation.connector_run_id, operation.owner_node}

  defp execute_with_parent(parent, token, operation) do
    parent_monitor = Process.monitor(parent)
    outer = self()

    executor =
      spawn_link(fn ->
        send(outer, {:executor_result, safe_execute(operation)})
      end)

    receive do
      {:executor_result, result} ->
        send(parent, {:disconnect_result, token, result, self()})

        receive do
          {:disconnect_result_ack, ^token} ->
            Process.demonitor(parent_monitor, [:flush])

          {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
            resubmit_after_restart(parent, operation, 100)
        end

      {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
        Process.unlink(executor)
        Process.exit(executor, :kill)
        resubmit_after_restart(parent, operation, 100)
    end
  end

  defp resubmit_after_restart(old_parent, operation, 0) do
    Logger.warning(
      "connector disconnect recovery exhausted after queue restart " <>
        "run=#{operation.connector_run_id} old_queue=#{inspect(old_parent)}"
    )

    :ok
  end

  # FORMAL-SPEC: tla/salix/ConnectorDisconnectRecovery.tla
  # Registration precedes init/1. A :kill also bypasses terminate/2, so the
  # registered replacement can coexist briefly with the dead generation's
  # admission authority. Recovery therefore waits for a different published
  # authority and never treats Process.whereis/1 as submission authority.
  defp resubmit_after_restart(old_parent, operation, attempts) do
    case try_submit(operation, old_parent) do
      :submitted ->
        :ok

      :retry ->
        Process.sleep(10)
        resubmit_after_restart(old_parent, operation, attempts - 1)
    end
  end

  defp tracked_base?(state, target_base) do
    Enum.any?(state.active, fn {_ref, active} -> base(active.operation) == target_base end) or
      Map.has_key?(state.retries, target_base) or Map.has_key?(state.pending, target_base)
  end

  defp tracked_size(state) do
    state.active
    |> Map.values()
    |> Enum.map(&base(&1.operation))
    |> MapSet.new()
    |> MapSet.union(Map.keys(state.retries) |> MapSet.new())
    |> MapSet.union(Map.keys(state.pending) |> MapSet.new())
    |> MapSet.size()
  end

  defp acquire_admission(counter) do
    current = :atomics.get(counter, 1)

    cond do
      current >= queue_limit() ->
        false

      :atomics.compare_exchange(counter, 1, current, current + 1) == :ok ->
        true

      true ->
        acquire_admission(counter)
    end
  end

  defp release_admission do
    case :persistent_term.get(@admission_key, nil) do
      {pid, counter} when pid == self() -> :atomics.sub(counter, 1, 1)
      _other -> :ok
    end
  end

  defp queue_limit,
    do: Application.get_env(:salix_web, :connector_disconnect_queue_limit, 1_024)

  defp task_timeout_ms,
    do: Application.get_env(:salix_web, :connector_disconnect_task_timeout_ms, 30_000)

  defp retry_ms, do: Application.get_env(:salix_web, :connector_disconnect_retry_ms, 1_000)
end
