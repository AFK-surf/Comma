defmodule Salix.SlackMirrorReaderOperationScrapeTest do
  use ExUnit.Case, async: false

  @reporter Module.concat(__MODULE__, Reporter)
  @scoped_event [:salix, :operation, :slack_mirror_reader_scrape_test]
  @operations ~w(
    slack_mirror_tail
    slack_mirror_changes
    slack_mirror_latest_states
    slack_mirror_thread
    slack_mirror_thread_reactions
    slack_mirror_search
  )

  test "Slack mirror reader query families retain finite operation labels" do
    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: @reporter, metrics: scoped_metrics(), start_async: false}
    )

    Enum.each(@operations, fn operation ->
      :telemetry.execute(
        @scoped_event,
        %{duration: System.convert_time_unit(1, :millisecond, :native)},
        %{
          component: "salix_analytics",
          operation: operation,
          surface: "system",
          outcome: "error"
        }
      )
    end)

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    Enum.each(@operations, fn operation ->
      assert scrape =~
               ~s(salix_operations_total{component="salix_analytics",operation="#{operation}",outcome="error",surface="system"} 1)
    end)

    refute scrape =~
             ~s(salix_operations_total{component="salix_analytics",operation="other")
  end

  defp scoped_metrics do
    [:salix]
    |> SystemsObservability.Metrics.enabled_metrics()
    |> Enum.flat_map(fn
      %{event_name: [:salix, :operation, :stop]} = metric ->
        [%{metric | event_name: @scoped_event}]

      _metric ->
        []
    end)
  end
end
