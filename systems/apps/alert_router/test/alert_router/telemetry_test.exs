defmodule AlertRouter.TelemetryTest do
  use ExUnit.Case, async: true

  test "metrics expose only the finite operational dimensions" do
    metrics = AlertRouter.Telemetry.metrics()

    assert Enum.map(metrics, & &1.name) == [
             [:alert, :router, :operations, :total],
             [:alert, :router, :operations, :duration, :seconds]
           ]

    assert Enum.all?(metrics, &(&1.tags == [:operation, :provider, :outcome]))
  end

  test "unknown metadata is normalized instead of becoming a new series" do
    [counter | _] = AlertRouter.Telemetry.metrics()

    assert counter.tag_values.(%{
             operation: "incident-123",
             provider: "tenant-controlled",
             outcome: "raw-provider-error"
           }) == %{operation: "other", provider: "other", outcome: "other"}
  end

  test "PostHog ingress uses a reviewed finite provider value" do
    [counter | _] = AlertRouter.Telemetry.metrics()

    assert counter.tag_values.(%{operation: :ingest, provider: "posthog", outcome: :accepted}) ==
             %{operation: "ingest", provider: "posthog", outcome: "accepted"}
  end
end
