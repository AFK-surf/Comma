defmodule SalixIM.SendTiming do
  @moduledoc "Observational timing for internal message sends. Never persists timing or context."
  alias SystemsObservability.{Context, Trace}

  @active {__MODULE__, :active}

  def run(stage, fun) do
    previous = Process.put(@active, true)

    try do
      measure(stage, fun)
    after
      if previous == nil, do: Process.delete(@active), else: Process.put(@active, previous)
    end
  end

  def measure(stage, fun) do
    if Process.get(@active) do
      Trace.with_span(
        :salix_im_send,
        %{component: "salix_im", operation: stage, surface: Context.current_surface()},
        fn ->
          started = System.monotonic_time()

          try do
            result = fun.()
            emit(stage, outcome(result), System.monotonic_time() - started)
            result
          catch
            kind, reason ->
              emit(stage, "error", System.monotonic_time() - started)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end
        end
      )
    else
      fun.()
    end
  end

  def envelope(agent_id, attrs) do
    {:observed_agent_message, Context.inject(), {node(), System.monotonic_time()}, agent_id,
     attrs}
  end

  def receive_message(context, {sender_node, started}, fun) do
    received = System.monotonic_time()

    Context.run(Context.extract(context), fn ->
      # Monotonic timestamps are comparable only within one VM.
      if sender_node == node(), do: emit("im_send_queue", "ok", received - started)
      run("im_send_actor", fun)
    end)
  end

  defp outcome({:error, :timeout}), do: "timeout"
  defp outcome({:error, _}), do: "error"
  defp outcome({:error_after_commit, _, _}), do: "error"
  defp outcome({:reply, result, _state}), do: outcome(result)
  defp outcome(_), do: "ok"

  defp emit(stage, outcome, duration) do
    :telemetry.execute([:salix, :operation, :stop], %{duration: duration}, %{
      component: "salix_im",
      operation: stage,
      surface: Context.current_surface(),
      outcome: outcome
    })
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
