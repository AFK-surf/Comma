defmodule SalixSignal.Telemetry do
  @moduledoc """
  Finite, content-free telemetry of the Signal runtime. Observational only:
  a handler failure never changes a business result.
  """

  import Telemetry.Metrics

  @guard_event [:salix_signal, :receive, :guard]
  @guard_reasons [:cooling_started, :sender_cooling, :budget_exceeded, :retry_answer_limited]

  @doc "Metric definitions for `SystemsObservability.Metrics`."
  def metrics do
    [
      # How often do the receive work limits act? `cooling_started` counts
      # senders that used up their failure budget, `sender_cooling` the
      # envelopes dropped while a sender cools down, `budget_exceeded` the
      # envelopes whose opening ran out of time, `retry_answer_limited` the
      # retry requests left unanswered because their sender sent more than
      # the per-sender bound. A rise means forged or broken traffic, or a
      # limit set too low for real traffic.
      counter("salix.signal.receive.guard.total",
        event_name: @guard_event,
        tags: [:reason]
      )
    ]
  end

  @doc "Records one action of the receive work limits."
  @spec receive_guard(
          :cooling_started
          | :sender_cooling
          | :budget_exceeded
          | :retry_answer_limited
        ) :: :ok
  def receive_guard(reason) when reason in @guard_reasons do
    :telemetry.execute(@guard_event, %{count: 1}, %{reason: reason})
  rescue
    _ -> :ok
  end
end
