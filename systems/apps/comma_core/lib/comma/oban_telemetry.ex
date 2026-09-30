defmodule Comma.ObanTelemetry do
  @moduledoc """
  Low-cardinality telemetry for the Comma-owned Oban instance.

  Operation state and retry policy remain owned by `Comma.Operations`; telemetry
  only reports queue outcomes and shutdown recovery signals.
  """

  @handler_id "comma-oban-telemetry"
  @events [
    [:oban, :job, :stop],
    [:oban, :job, :exception],
    [:oban, :queue, :shutdown]
  ]
  @queues ~w(comma_external comma_recommendations comma_recommendation_control other)
  @states ~w(success failure cancelled discard snoozed exception other)

  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  def handle_event([:oban, :job, event], measurements, %{conf: %{name: Comma.Oban}} = metadata, _)
      when event in [:stop, :exception] do
    job = metadata.job

    :telemetry.execute(
      [:comma, :oban, :job, event],
      Map.take(measurements, [:duration, :queue_time]),
      %{
        queue: finite(job.queue, @queues),
        state: finite(metadata[:state] || event, @states)
      }
    )
  end

  def handle_event(
        [:oban, :queue, :shutdown],
        measurements,
        %{conf: %{name: Comma.Oban}} = metadata,
        _
      ) do
    :telemetry.execute(
      [:comma, :oban, :queue, :shutdown],
      %{elapsed: measurements[:elapsed] || 0, orphaned: length(metadata[:orphaned] || [])},
      %{queue: finite(metadata[:queue], @queues)}
    )
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp finite(value, allowed) when is_atom(value), do: finite(Atom.to_string(value), allowed)

  defp finite(value, allowed) when is_binary(value),
    do: if(value in allowed, do: value, else: "other")

  defp finite(_value, _allowed), do: "other"
end
