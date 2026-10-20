defmodule AlertRouter.TelemetryTest do
  use SystemsClock.Case, async: true

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
