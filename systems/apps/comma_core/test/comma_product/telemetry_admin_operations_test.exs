defmodule CommaProduct.TelemetryAdminOperationsTest do
  # async: false — attaches a global telemetry handler.
  use ExUnit.Case, async: false

  @operation_stop [:comma_product, :operation, :stop]

  # The Prometheus reporter derives label values through the metric's
  # tag_values function; asserting through that exact closure pins the
  # scraped series, not an internal helper (PR #1059 review round 2:
  # the named admin actions must not collapse to operation="other").
  defp operation_tag_values do
    metric =
      Enum.find(CommaProduct.Telemetry.metrics(), fn metric ->
        metric.event_name == @operation_stop
      end)

    assert metric, "operation metric must exist"
    metric.tag_values
  end

  test "the four OAuth client admin actions emit named operation tags at the scrape boundary" do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "oauth-client-admin-operations-#{inspect(ref)}",
      @operation_stop,
      fn @operation_stop, _measurements, metadata, _config ->
        send(test_pid, {ref, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("oauth-client-admin-operations-#{inspect(ref)}") end)

    tag_values = operation_tag_values()

    for {action, expected_tag} <- [
          {"create_oauth_client", "admin_create_oauth_client"},
          {"rotate_oauth_client_secret", "admin_rotate_oauth_client_secret"},
          {"disable_oauth_client", "admin_disable_oauth_client"},
          {"enable_oauth_client", "admin_enable_oauth_client"}
        ] do
      CommaProduct.Telemetry.emit_admin_command(action, :ok, 1)

      assert_receive {^ref, metadata}
      tags = tag_values.(metadata)

      assert tags.operation == expected_tag,
             "#{action} must scrape as #{expected_tag}, got #{inspect(tags.operation)}"

      refute tags.operation == "other"
    end
  end
end
