defmodule AlertRouter.Web.GitHubHMAC do
  @moduledoc """
  Verifies GitHub webhook HMAC-SHA256 signatures over the exact raw body.

  GitHub does not publish an official Elixir webhook SDK. This deliberately
  keeps the handwritten protocol surface to the documented signature and
  required event headers, using OTP crypto and constant-time comparison.
  """

  @spec verify(Plug.Conn.t(), binary()) :: {:ok, binary()} | {:error, term()}
  def verify(conn, raw_body) when is_binary(raw_body) do
    config = Application.get_env(:alert_router, :github_webhook, [])

    with secret when is_binary(secret) and byte_size(secret) >= 32 <- config[:secret],
         {:ok, event} <- one_header(conn, config[:event_header]),
         :ok <- allowed_event(event),
         {:ok, delivery_id} <- one_header(conn, config[:delivery_header]),
         :ok <- bounded_delivery_id(delivery_id),
         {:ok, "sha256=" <> encoded} <- one_header(conn, config[:signature_header]),
         {:ok, supplied} <- Base.decode16(encoded, case: :mixed),
         expected <- :crypto.mac(:hmac, :sha256, secret, raw_body),
         true <- byte_size(supplied) == byte_size(expected),
         true <- :crypto.hash_equals(supplied, expected) do
      {:ok, event}
    else
      nil -> {:error, :not_configured}
      false -> {:error, :invalid_signature}
      :error -> {:error, :invalid_signature}
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

  defp allowed_event(event) when event in ["workflow_run", "ping"], do: :ok
  defp allowed_event(_event), do: {:error, :invalid_github_event}

  defp bounded_delivery_id(delivery_id) when byte_size(delivery_id) <= 100, do: :ok
  defp bounded_delivery_id(_delivery_id), do: {:error, :invalid_github_delivery_id}
end
