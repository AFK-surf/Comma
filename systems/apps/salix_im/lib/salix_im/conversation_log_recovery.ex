defmodule SalixIM.ConversationLogRecovery do
  @moduledoc false
  use SystemsRuntime.Server

  alias SalixStore.ConversationLogRecovery, as: Index

  @interval 1_000
  @concurrency 8
  @timeout 30_000

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  # Direct entry point for deterministic recovery tests and operational probes.
  def sweep(now \\ SystemsClock.system_time(:millisecond)) do
    with {:ok, candidates} <- claim(@concurrency, now) do
      results = Enum.map(candidates, &recover/1)
      {:ok, %{scanned: length(candidates), results: results}}
    end
  end

  @impl true
  def init(_opts) do
    SystemsRuntime.Proc.trap_exit(true)
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :tick, @interval)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, tasks) do
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :tick, @interval)
    available = @concurrency - map_size(tasks)

    tasks =
      if available > 0 do
        case claim(available) do
          {:ok, candidates} ->
            Enum.reduce(candidates, tasks, fn candidate, tasks ->
              task = SystemsRuntime.Task.async(fn -> recover(candidate) end)

              timer =
                SystemsClock.send_after(
                  SystemsRuntime.Proc.self(),
                  {:timeout, task.ref},
                  @timeout
                )

              Map.put(tasks, task.ref, {task, timer})
            end)

          _ ->
            tasks
        end
      else
        tasks
      end

    {:noreply, tasks}
  end

  def handle_info({ref, _result}, tasks) when is_reference(ref) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])
    {:noreply, forget(tasks, ref)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, tasks), do: {:noreply, forget(tasks, ref)}

  def handle_info({:EXIT, _pid, _reason}, tasks), do: {:noreply, tasks}

  def handle_info({:timeout, ref}, tasks) do
    case tasks[ref] do
      {task, _} ->
        SystemsRuntime.Task.shutdown(task, :brutal_kill)

        Salix.Telemetry.emit_operation(
          "salix_im",
          "conversation_log_recovery",
          "salix",
          "timeout",
          System.convert_time_unit(@timeout, :millisecond, :native)
        )

      _ ->
        :ok
    end

    {:noreply, forget(tasks, ref)}
  end

  defp forget(tasks, ref) do
    case Map.pop(tasks, ref) do
      {{_, timer}, tasks} ->
        SystemsClock.cancel_timer(timer)
        tasks

      {nil, tasks} ->
        tasks
    end
  end

  defp claim(limit, now \\ SystemsClock.system_time(:millisecond)) do
    started = SystemsClock.monotonic_time()
    result = Index.claim(limit, now)

    Salix.Telemetry.emit_operation(
      "salix_im",
      "conversation_log_recovery_claim",
      "salix",
      if(match?({:ok, _}, result), do: "ok", else: "error"),
      SystemsClock.monotonic_time() - started
    )

    result
  end

  defp recover(candidate) do
    started = SystemsClock.monotonic_time()
    result = safely_recover(candidate)

    outcome =
      case result do
        :ok -> "cleaned"
        {:ok, :pending} -> "retained"
        _ -> "error"
      end

    Salix.Telemetry.emit_operation(
      "salix_im",
      "conversation_log_recovery",
      "salix",
      outcome,
      SystemsClock.monotonic_time() - started
    )

    result
  end

  defp safely_recover(candidate) do
    SalixIM.ConversationSource.recover(candidate)
  rescue
    _ -> {:error, :recovery_failed}
  catch
    :exit, _ -> {:error, :recovery_failed}
  end
end
