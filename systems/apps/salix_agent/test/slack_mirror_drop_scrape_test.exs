defmodule Salix.SlackMirrorDropScrapeTest do
  @moduledoc """
  The export pipeline for the Slack mirror's drop counter: telemetry event →
  `Salix.Telemetry` metric definition → Prometheus reporter → scrape text.

  This is the layer that matters for this particular counter. The webhook path
  drops an event only when the outbox insert fails, and it discards the result
  by design — so if the definition and the event disagree on name, measurement
  key or tag, the rows vanish and NOTHING reports it. A raw-event test would
  stay green through exactly that.
  """
  use ExUnit.Case, async: false

  @reporter Module.concat(__MODULE__, Reporter)
  @scoped_event [:salix, :slack_mirror, :dropped, :scrape_test]

  # An unnamed drop path must not silently create a new label. It lands on
  # `other`, which is visible in the same query rather than absent from it.
  for {name, reason, count, label} <- [
        {"a drop reaches an operator's scrape, labelled by reason", :outbox_unavailable, 3,
         "outbox_unavailable"},
        {"an unclassified reason is normalized instead of widening the label set", :something_new,
         1, "other"}
      ] do
    test name do
      start_supervised!(
        {TelemetryMetricsPrometheus.Core,
         name: @reporter, metrics: scoped_metrics(), start_async: false}
      )

      :telemetry.execute(@scoped_event, %{count: unquote(count)}, %{reason: unquote(reason)})

      scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)
      label = unquote(label)
      count = unquote(count)

      assert scrape =~
               ~r/salix_slack_mirror_dropped_rows_total\{reason="#{label}"\} #{count}(\.0)?(\s|$)/
    end
  end

  defp scoped_metrics do
    [:salix]
    |> SystemsObservability.Metrics.enabled_metrics()
    |> Enum.flat_map(fn
      %{event_name: [:salix, :slack_mirror, :dropped]} = metric ->
        [%{metric | event_name: @scoped_event}]

      _metric ->
        []
    end)
  end
end
