defmodule SystemsObservability do
  @moduledoc """
  VM-local telemetry kernel shared by all Comma systems subsystems.

  Domain event semantics remain owned by their domain telemetry modules.
  """

  @reporter_name SystemsObservability.Prometheus
  @histogram_reporter_name SystemsObservability.Histograms

  @doc "Return a Prometheus exposition from the VM's single reporter."
  def scrape do
    core = safe_scrape(fn -> TelemetryMetricsPrometheus.Core.scrape(@reporter_name) end)

    histograms =
      safe_scrape(fn ->
        SystemsObservability.HistogramReporter.scrape(@histogram_reporter_name)
      end)

    core <> histograms
  end

  defp safe_scrape(fun) do
    fun.()
  rescue
    _exception -> ""
  catch
    _kind, _reason -> ""
  end
end
