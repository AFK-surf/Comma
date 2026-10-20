defmodule Salix.StoreInflightScrapeTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The full export pipeline for the in-flight store gauges: Poller.publish →
  telemetry event → `Salix.Telemetry` metric definitions → Prometheus
  reporter → scrape text. The raw-event tests in salix_store prove the poller
  emits; this proves an operator's scrape actually SEES it — the layer a
  definition typo (event name, measurement key, tag mismatch) would break
  while every raw-event test stays green.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixStore.Inflight

  @reporter Module.concat(__MODULE__, Reporter)
  @scoped_event [:salix, :store, :inflight, :scrape_test]

  setup do
    _ = Inflight.create_table()
    :ok
  end

  test "in-flight gauges flow through the reporter to scrape, and fall back to zero" do
    parent = SystemsRuntime.Proc.self()

    task =
      SystemsRuntime.Task.async(fn ->
        Inflight.track("store_put", fn ->
          SystemsRuntime.Proc.send(parent, :tracked)

          SystemsRuntime.Proc.receive do
            :release -> :ok
          end
        end)
      end)

    foreign_task =
      SystemsRuntime.Task.async(fn ->
        Inflight.track("store_get", fn ->
          SystemsRuntime.Proc.send(parent, :foreign_tracked)

          SystemsRuntime.Proc.receive do
            :release -> :ok
          end
        end)
      end)

    settle_receive(:tracked)
    settle_receive(:foreign_tracked)

    metrics =
      [:salix]
      |> SystemsObservability.Metrics.enabled_metrics()
      |> scoped_inflight_metrics()

    start_supervised!(
      {TelemetryMetricsPrometheus.Core, name: @reporter, metrics: metrics, start_async: false}
    )

    Inflight.Poller.publish_for(task.pid, @scoped_event)
    # A real/global publish after the scoped one includes the deliberately held
    # foreign GET. It must not overwrite this test-owned reporter observation.
    Inflight.Poller.publish()
    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~ ~r/salix_store_inflight_ops\{operation="store_put"\} 1(\.0)?(\s|$)/
    assert scrape =~ ~r/salix_store_inflight_ops\{operation="store_get"\} 0(\.0)?(\s|$)/
    assert scrape =~ ~r/salix_store_inflight_ops\{operation="store_list"\} 0(\.0)?(\s|$)/

    assert [age] =
             Regex.run(
               ~r/salix_store_inflight_oldest_age_seconds\{operation="store_put"\} ([0-9.eE+-]+)/,
               scrape,
               capture: :all_but_first
             )

    {age_seconds, _rest} = Float.parse(age)
    assert age_seconds >= 0.0

    SystemsRuntime.Proc.send(task.pid, :release)
    settled_await(task)

    # The next poll zero-fills the gauge back down — the property an
    # event-driven emitter cannot provide.
    Inflight.Poller.publish_for(task.pid, @scoped_event)
    Inflight.Poller.publish()
    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~ ~r/salix_store_inflight_ops\{operation="store_put"\} 0(\.0)?(\s|$)/

    SystemsRuntime.Proc.send(foreign_task.pid, :release)
    settled_await(foreign_task)
  end

  defp scoped_inflight_metrics(metrics) do
    Enum.flat_map(metrics, fn
      %{event_name: [:salix, :store, :inflight]} = metric ->
        [%{metric | event_name: @scoped_event}]

      _metric ->
        []
    end)
  end
end
