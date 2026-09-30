defmodule SystemsObservability.MetricsTest do
  use ExUnit.Case, async: false

  test "hostile HTTP paths scrape only as the bounded unmatched family" do
    name = Module.concat(__MODULE__, HTTPReporter)

    histograms =
      Enum.filter(
        SystemsObservability.Telemetry.metrics(),
        &match?(%Telemetry.Metrics.Distribution{}, &1)
      )

    start_supervised!(
      {SystemsObservability.HistogramReporter, name: name, metrics: histograms},
      id: :http_test_reporter
    )

    hostile = "/users/550e8400-e29b-41d4-a716-446655440000?token=secret"

    :telemetry.execute(
      [:comma_system, :http, :stop],
      %{duration: System.convert_time_unit(1, :millisecond, :native)},
      %{endpoint: :comma_product_api, route: hostile, method: :get, status: 200}
    )

    scrape = SystemsObservability.HistogramReporter.scrape(name)
    assert scrape =~ ~s(route="unmatched")
    refute scrape =~ "550e8400"
    refute scrape =~ "token=secret"
  end

  test "runtime delegates distributions to the bounded histogram reporter" do
    core_metrics =
      TelemetryMetricsPrometheus.Core.Registry.metrics(SystemsObservability.Prometheus)

    refute Enum.any?(core_metrics, &match?(%Telemetry.Metrics.Distribution{}, &1))

    :telemetry.execute(
      [:comma_system, :http, :stop],
      %{duration: System.convert_time_unit(2, :millisecond, :native)},
      %{endpoint: :comma_product_api, route: "/health", method: :get, status: 204}
    )

    scrape = SystemsObservability.scrape()
    assert scrape =~ "comma_system_http_requests_total"
    assert scrape =~ "comma_system_http_duration_seconds_bucket"
  end

  test "runtime probe labels pass the finite domain allowlist" do
    metrics = SystemsObservability.Metrics.enabled_metrics([:salix])

    assert Enum.any?(metrics, fn metric ->
             metric.name == [:salix, :runtime, :probes, :total] and
               metric.tags == [:provider, :trigger, :outcome]
           end)
  end
end
