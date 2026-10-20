defmodule SalixIM.QQTiming do
  @moduledoc """
  Content-free phase timings for QQ callbacks and sends. A scope collects its
  phases and writes one `qq_delivery_timing` log when it ends. No timing state
  is persisted.
  """

  require Logger

  alias SystemsObservability.Context

  @scope {__MODULE__, :scope}

  # A send of many files repeats its HTTP phases; the log stays bounded.
  @max_phases 64

  def run(direction, fun) when direction in [:ingress, :send] do
    scope = %{
      direction: direction,
      started: SystemsClock.monotonic_time(:millisecond),
      started_at_ms: SystemsClock.system_time(:millisecond),
      phases: [],
      phase_count: 0,
      source: [],
      discard?: false
    }

    previous = Process.put(@scope, scope)

    try do
      Context.run(Context.capture(), fn ->
        try do
          result = fun.()
          finish(outcome(result))
          result
        catch
          kind, reason ->
            finish("exception")
            :erlang.raise(kind, reason, __STACKTRACE__)
        end
      end)
    after
      if previous == nil, do: Process.delete(@scope), else: Process.put(@scope, previous)
    end
  end

  # Shared admission functions call this too. Other providers incur no logging
  # or clock reads because only a QQ entrypoint opens the scope.
  def measure(phase, fun) do
    case Process.get(@scope) do
      nil ->
        fun.()

      _scope ->
        started = SystemsClock.monotonic_time(:millisecond)

        try do
          result = fun.()
          record(phase, started, outcome(result))
          result
        catch
          kind, reason ->
            record(phase, started, "exception")
            :erlang.raise(kind, reason, __STACKTRACE__)
        end
    end
  end

  @doc """
  Drops the open scope's log. Unattributed callbacks (an unknown bot or a bad
  signature) call this, so public traffic cannot write timing logs.
  """
  def discard do
    update(&%{&1 | discard?: true})
    :ok
  end

  # Call only after signature verification. This is a cross-clock age at the
  # ProviderHTTP entrypoint, after HTTP body parsing, not network duration.
  def source_timestamp(timestamp) when is_binary(timestamp) and byte_size(timestamp) <= 64 do
    with %{direction: :ingress} <- Process.get(@scope),
         {:ok, sent, _offset} <- DateTime.from_iso8601(timestamp) do
      sent_at_ms = DateTime.to_unix(sent, :millisecond)

      update(fn scope ->
        %{
          scope
          | source: [
              source_sent_at_ms: sent_at_ms,
              handler_started_at_ms: scope.started_at_ms,
              source_to_handler_ms: scope.started_at_ms - sent_at_ms
            ]
        }
      end)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def source_timestamp(_), do: :ok

  defp record(phase, started, outcome) do
    ended = SystemsClock.monotonic_time(:millisecond)

    update(fn scope ->
      entry = %{
        phase: phase,
        offset_ms: started - scope.started,
        duration_ms: max(ended - started, 0),
        outcome: outcome
      }

      if scope.phase_count < @max_phases,
        do: %{scope | phases: [entry | scope.phases], phase_count: scope.phase_count + 1},
        else: %{scope | phase_count: scope.phase_count + 1}
    end)
  end

  defp update(fun) do
    case Process.get(@scope) do
      nil -> :ok
      scope -> Process.put(@scope, fun.(scope))
    end
  rescue
    _ -> :ok
  end

  defp finish(outcome) do
    case Process.get(@scope) do
      %{discard?: false} = scope ->
        Logger.info(
          "qq_delivery_timing",
          [
            component: "salix_im",
            provider: "qq",
            direction: scope.direction,
            started_at_ms: scope.started_at_ms,
            duration_ms: max(SystemsClock.monotonic_time(:millisecond) - scope.started, 0),
            outcome: outcome,
            phases: Enum.reverse(scope.phases),
            phases_dropped: max(scope.phase_count - @max_phases, 0)
          ] ++ scope.source
        )

      _discarded ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp outcome({:error, :timeout}), do: "timeout"
  defp outcome({:error, :invalid_signature}), do: "rejected"
  defp outcome({:error, :ignored}), do: "ignored"
  defp outcome({:error, _}), do: "error"
  defp outcome(_), do: "ok"
end
