defmodule AlertRouter.Web.SlackSignature do
  @moduledoc """
  Verifies Slack's signature over the raw request body before parsing it.

  The existing Salix verifier requires its provider runtime. Official Slack
  SDKs do not include Elixir. This adapter uses OTP crypto and Slack's documented
  v0 signature format, with a five-minute replay window and constant-time comparison.
  """

  def verify(conn, body) do
    config = Application.get_env(:alert_router, :slack_progress, [])

    with secret when is_binary(secret) and byte_size(secret) > 0 <- config[:signing_secret],
         [timestamp] <- Plug.Conn.get_req_header(conn, "x-slack-request-timestamp"),
         {seconds, ""} <- Integer.parse(timestamp),
         true <- abs(System.system_time(:second) - seconds) <= 300,
         ["v0=" <> signature] <- Plug.Conn.get_req_header(conn, "x-slack-signature"),
         {:ok, supplied} <- Base.decode16(signature, case: :lower),
         expected <- :crypto.mac(:hmac, :sha256, secret, "v0:" <> timestamp <> ":" <> body),
         true <- byte_size(supplied) == byte_size(expected),
         true <- :crypto.hash_equals(supplied, expected) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end
end
