defmodule AlertRouter.GrafanaHMACTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AlertRouter.Web.GrafanaHMAC

  @secret "alert-router-grafana-test-secret"
  @now ~U[2026-04-25 14:13:20Z]
  @body ~s({"status":"firing"})

  test "accepts the raw-body signature inside the timestamp window" do
    timestamp = Integer.to_string(DateTime.to_unix(@now))
    signature = sign(timestamp, @body)

    conn =
      conn(:post, "/v1/events/grafana", @body)
      |> put_req_header("x-grafana-alerting-signature", signature)
      |> put_req_header("x-grafana-alerting-signature-timestamp", timestamp)

    assert :ok = GrafanaHMAC.verify(conn, @body, @now)
  end

  test "rejects body tampering and stale timestamps" do
    current_timestamp = Integer.to_string(DateTime.to_unix(@now))
    stale_timestamp = Integer.to_string(DateTime.to_unix(@now) - 301)

    stale_conn =
      conn(:post, "/v1/events/grafana", @body)
      |> put_req_header("x-grafana-alerting-signature", sign(stale_timestamp, @body))
      |> put_req_header("x-grafana-alerting-signature-timestamp", stale_timestamp)

    tampered_conn =
      conn(:post, "/v1/events/grafana", @body)
      |> put_req_header("x-grafana-alerting-signature", sign(current_timestamp, @body))
      |> put_req_header("x-grafana-alerting-signature-timestamp", current_timestamp)

    assert {:error, :invalid_or_stale_signature} =
             GrafanaHMAC.verify(stale_conn, @body, @now)

    assert {:error, :invalid_or_stale_signature} =
             GrafanaHMAC.verify(tampered_conn, @body <> " ", @now)
  end

  defp sign(timestamp, body) do
    :crypto.mac(:hmac, :sha256, @secret, timestamp <> ":" <> body)
    |> Base.encode16(case: :lower)
  end
end
