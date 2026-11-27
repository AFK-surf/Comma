defmodule BridgeForTeamsWeb.M2squareWebhookController do
  @moduledoc """
  Public webhook receiver for M2square Teams payment notifications.

  Application code authenticates requests via an exact single `sign` header
  (SHA-512 over the bounded <= 64 KiB raw body captured by
  `BridgeForTeamsWeb.M2squareWebhookPlug`) plus upstream `verifyStatus`
  confirmation, without trusting `conn.remote_ip`.

  Before enabling any M2square country (`enabled: true`), operators must
  configure Cloudflare/ingress IP allowlisting for `/v1/billing/m2square/webhook`
  and block direct origin bypass (`docs/architecture/DOMAIN_CONCEPTS.md`).
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  alias BridgeForTeams.PaidSignup

  @max_webhook_bytes 65_536

  def webhook(conn, _params) do
    with {:ok, raw_body} <- fetch_bounded_raw_body(conn),
         {:ok, sign} <- fetch_single_sign_header(conn) do
      case PaidSignup.handle_m2square_webhook(raw_body, sign) do
        {:ok, _result} -> send_plain(conn, 200, "success")
        {:error, :unauthorized} -> send_plain(conn, 401, "unauthorized")
        {:error, :bad_request} -> send_plain(conn, 400, "bad_request")
        {:error, _retryable} -> send_plain(conn, 500, "retry")
      end
    else
      {:error, :too_large} -> send_plain(conn, 413, "payload_too_large")
      {:error, :unauthorized} -> send_plain(conn, 401, "unauthorized")
      {:error, :bad_request} -> send_plain(conn, 400, "bad_request")
    end
  end

  defp fetch_bounded_raw_body(conn) do
    case conn.private[:m2square_raw_body] do
      raw when is_binary(raw) and byte_size(raw) <= @max_webhook_bytes -> {:ok, raw}
      raw when is_binary(raw) -> {:error, :too_large}
      _ -> {:error, :bad_request}
    end
  end

  defp fetch_single_sign_header(conn) do
    case get_req_header(conn, "sign") do
      [sign] when is_binary(sign) ->
        if String.trim(sign) == "", do: {:error, :unauthorized}, else: {:ok, sign}

      _missing_or_duplicate ->
        {:error, :unauthorized}
    end
  end

  defp send_plain(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end
