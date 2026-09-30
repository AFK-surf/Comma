defmodule CommaWeb.TelegramOIDC.HTTPAdapter do
  @moduledoc false
  @behaviour :oidcc_http_adapter

  require Logger

  # OIDCC owns discovery, JSON decoding and all token validation. Its default
  # httpc transport does not decompress Telegram's gzip responses; use the
  # supported transport seam with Req's existing compression implementation.
  @impl true
  def request(method, request, http_options, [body_format: :binary], _config) do
    timeout = Keyword.fetch!(http_options, :timeout)
    connect_options = [timeout: timeout]

    connect_options =
      case Keyword.fetch(http_options, :ssl) do
        {:ok, options} -> Keyword.put(connect_options, :transport_opts, options)
        :error -> connect_options
      end

    options =
      [
        method: method,
        compressed: true,
        decode_body: false,
        retry: &retry_read/2,
        max_retries: 1,
        retry_log_level: false,
        redirect: false,
        receive_timeout: timeout,
        pool_timeout: timeout,
        connect_options: connect_options
      ] ++ request_options(request)

    case Req.request(options) do
      {:ok, %{status: status, headers: headers, body: body}} when is_binary(body) ->
        headers =
          for {name, values} <- headers, value <- values do
            {name |> String.downcase() |> String.to_charlist(), value}
          end

        {:ok, {{~c"HTTP/1.1", status, ~c""}, headers, body}}

      {:error, reason} ->
        failure(transport_reason(reason), method)
    end
  rescue
    # Provider errors can contain response bytes, authorization headers or URLs.
    # Return a bounded error so the SDK retries without crashing its supervisor
    # or logging provider credentials/content.
    exception in [ArgumentError, KeyError] ->
      failure(:invalid_request, method, exception_module: inspect(exception.__struct__))

    exception ->
      failure(:adapter_failure, method, exception_module: inspect(exception.__struct__))
  end

  # Retry only safe reads interrupted by a transport failure. Never replay a
  # one-use authorization code, or sleep on an unbounded provider Retry-After.
  # The SDK still owns recovery after this one retry (at most 2 requests).
  defp retry_read(%Req.Request{method: :get}, %Req.TransportError{reason: reason})
       when reason in [:timeout, :econnrefused, :econnreset, :closed],
       do: {:delay, 100}

  defp retry_read(%Req.Request{method: :get}, %Req.HTTPError{protocol: :http2, reason: reason})
       when reason in [:unprocessed, :pool_not_available],
       do: {:delay, 100}

  defp retry_read(_request, _result), do: false

  defp transport_reason(%Req.DecompressError{}), do: :invalid_compression
  defp transport_reason(%Req.TransportError{reason: :timeout}), do: :timeout
  defp transport_reason(%Req.TransportError{reason: :closed}), do: :closed
  defp transport_reason(%Req.TransportError{reason: :econnreset}), do: :connection_reset
  defp transport_reason(%Req.TransportError{reason: :econnrefused}), do: :connection_refused
  defp transport_reason(%Req.TransportError{reason: :nxdomain}), do: :dns
  defp transport_reason(%Req.TransportError{reason: {:tls_alert, _}}), do: :tls
  defp transport_reason(%Req.HTTPError{}), do: :http_protocol
  defp transport_reason(_reason), do: :unavailable

  defp failure(reason, method, metadata \\ []) do
    Logger.warning(
      "Telegram OIDC transport failed",
      [
        event: "telegram_oidc_transport_failed",
        phase: if(method == :get, do: "read", else: "exchange"),
        reason_class: reason
      ] ++ metadata
    )

    {:error, {:telegram_oidc_transport, reason}}
  end

  defp request_options({url, headers}) do
    [url: to_string(url), headers: normalize_headers(headers)]
  end

  defp request_options({url, headers, content_type, body}) do
    [
      url: to_string(url),
      headers: [{"content-type", to_string(content_type)} | normalize_headers(headers)],
      body: IO.iodata_to_binary(body)
    ]
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), IO.iodata_to_binary(value)} end)
  end
end
