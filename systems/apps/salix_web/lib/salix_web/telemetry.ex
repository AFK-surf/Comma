defmodule SalixWeb.Telemetry do
  @moduledoc """
  Thin LiveDashboard adapter over the shared metric definitions.

  Polling and reporter ownership belong exclusively to `systems_observability`.
  """
  @doc "Metric definitions surfaced on the LiveDashboard Metrics page."
  def metrics do
    SystemsObservability.Telemetry.metrics()
  end
end
