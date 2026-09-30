defmodule AlertRouter.Web.GrafanaHMAC do
  @moduledoc "Grafana webhook HMAC-SHA256 verifier with timestamp replay bound."

  @spec verify(Plug.Conn.t(), binary(), DateTime.t()) :: :ok | {:error, term()}
  def verify(conn, raw_body, now \\ DateTime.utc_now())
      when is_binary(raw_body) and is_struct(now, DateTime) do
    config = Application.get_env(:alert_router, :grafana_webhook, [])

    with secret when is_binary(secret) and byte_size(secret) >= 32 <- config[:secret],
         {:ok, signature} <- one_header(conn, config[:signature_header]),
         {:ok, timestamp} <- one_header(conn, config[:timestamp_header]),
         {:ok, unix} <- parse_unix(timestamp),
         true <- abs(DateTime.to_unix(now) - unix) <= config[:tolerance_seconds],
         {:ok, supplied} <- Base.decode16(signature, case: :mixed),
         expected <- :crypto.mac(:hmac, :sha256, secret, timestamp <> ":" <> raw_body),
         true <- byte_size(supplied) == byte_size(expected),
         true <- :crypto.hash_equals(supplied, expected) do
      :ok
    else
      nil -> {:error, :not_configured}
      false -> {:error, :invalid_or_stale_signature}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_signature}
    end
  end

  defp one_header(_conn, nil), do: {:error, :not_configured}

  defp one_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value] when value != "" -> {:ok, value}
      _ -> {:error, :missing_signature_header}
    end
  end

  defp parse_unix(value) do
    case Integer.parse(value) do
      {unix, ""} when unix > 0 -> {:ok, unix}
      _ -> {:error, :invalid_timestamp_header}
    end
  end
end
