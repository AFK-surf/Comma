defmodule CommaWeb.Stations.Gateway do
  @moduledoc """
  Station tool transport. By default calls go over the station's presence
  socket (`CommaWeb.StationTools`); with `:gateway` they use the HTTP client
  for the station gateway (`POST /v1/stations/:id/tools`,
  contract §9). One call is one request; it is never retried, because station
  ops such as `exec` are not idempotent.

  Configured by `config :comma_web, :station_gateway, url: _, token: _`
  (`COMMA_STATION_GATEWAY_URL`, `COMMA_STATION_GATEWAY_TOKEN`). Tests may add
  `req_options` such as a `Req.Test` plug.
  """

  # The gateway's own default deadline is 60 s, extended by an op's
  # timeout_ms plus 15 s; wait a little longer so its 504 arrives first.
  @default_receive_ms 70_000
  @op_grace_ms 20_000
  @max_receive_ms 16 * 60_000
  # Transport failures that happen before the request leaves Salix.
  @not_connected [:econnrefused, :nxdomain, :ehostunreach, :enetunreach]

  @doc """
  How station tools travel: `:presence` (default) over the station's own
  presence socket (`CommaWeb.StationTools`), or `:gateway` over this HTTP
  gateway (`COMMA_STATION_TOOLS_TRANSPORT=gateway`).
  """
  def transport, do: SystemsRuntime.get_env(:comma_web, :station_tools_transport, :presence)

  @spec configured?() :: boolean()
  def configured? do
    case transport() do
      :gateway ->
        config = config()
        present?(config[:url]) and present?(config[:token])

      _presence ->
        Comma.Stations.Config.enabled?()
    end
  end

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(station_id, body) do
    case transport() do
      :gateway -> call_gateway(station_id, body)
      _presence -> CommaWeb.StationTools.call(station_id, body)
    end
  end

  defp call_gateway(station_id, %{"args" => args} = body) do
    config = config()

    options =
      [
        method: :post,
        url: "#{config[:url]}/v1/stations/#{station_id}/tools",
        json: body,
        auth: {:bearer, config[:token]},
        headers: [{"x-request-id", body["id"]}],
        receive_timeout: receive_timeout(args),
        retry: false
      ]
      |> Keyword.merge(config[:req_options] || [])

    case Req.request(options) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true, "result" => result}}}
      when is_map(result) ->
        {:ok, result}

      {:ok, %Req.Response{status: 200, body: %{"ok" => false, "error" => %{} = error}}} ->
        {:error, {:tool, error}}

      {:ok, %Req.Response{body: %{"error" => %{"code" => code} = error}}} ->
        {:error, {:gateway, to_string(code), to_string(error["message"] || "")}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:gateway, "gateway_error", "unexpected gateway status #{status}"}}

      {:error, %Req.TransportError{reason: reason} = error} when reason in @not_connected ->
        {:error, {:gateway, "gateway_unreachable", Exception.message(error)}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, {:gateway, "timeout", "no answer from the station gateway"}}

      # The request may have reached the gateway before the connection broke.
      {:error, exception} ->
        {:error, {:gateway, "gateway_disconnected", Exception.message(exception)}}
    end
  end

  defp receive_timeout(%{"timeout_ms" => ms}) when is_integer(ms) and ms > 0,
    do: min(max(@default_receive_ms, ms + @op_grace_ms), @max_receive_ms)

  defp receive_timeout(_args), do: @default_receive_ms

  defp config, do: SystemsRuntime.get_env(:comma_web, :station_gateway, [])
  defp present?(value), do: is_binary(value) and value != ""
end
