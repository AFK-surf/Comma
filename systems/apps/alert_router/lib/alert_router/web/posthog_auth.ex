defmodule AlertRouter.Web.PostHogAuth do
  @moduledoc "Authenticates the server-to-server HTTP destination; never a public ingestion key."

  def authorize(conn) do
    secret = Application.get_env(:alert_router, :posthog_webhook, []) |> Keyword.get(:secret)

    if is_binary(secret) and byte_size(secret) >= 32 do
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> supplied] ->
          if Plug.Crypto.secure_compare(supplied, secret),
            do: :ok,
            else: {:error, :invalid_signature}

        _ ->
          {:error, :invalid_signature}
      end
    else
      {:error, :not_configured}
    end
  end
end
