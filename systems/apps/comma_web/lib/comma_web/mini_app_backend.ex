defmodule CommaWeb.MiniAppBackend do
  @moduledoc """
  Forwards an app's backend call to the private dispatch Worker
  (`systems/cloudflare/miniapp-dispatch`) after the server checked the
  viewer's access, the app's status and the owner's billing.

  `POST {dispatch_base_url}/internal/v1/apps/<script>/<path>` carries the
  salix-vm-gateway HMAC headers (`SalixEnv.VM.Providers.Cloudflare.Client.signature/6`;
  the Worker answers 404 to an unsigned or replayed request) and
  `x-comma-app-method`, `x-comma-app-version`, `x-comma-viewer` and
  `x-comma-app-egress`. The answer's status, `content-type` and body (at most
  5 MiB) pass through. A thrown app error (502 `app_error`) and other upstream
  failures are kept as backend error lines (`Comma.MiniApps.RateLimit.record_error/3`).

  `config :comma_web, :mini_app_dispatch_http_options` merges into each
  request (tests point it at a stub).
  """

  require Logger

  alias Comma.MiniApps.{Config, RateLimit}
  alias SalixEnv.VM.Providers.Cloudflare.Client

  @methods ~w(GET POST PUT PATCH DELETE)
  @response_max 5 * 1024 * 1024
  @timeout_ms 30_000

  def methods, do: @methods

  @doc """
  `{:ok, %{status, content_type, body}}`, `{:error, :not_found}` (no backend),
  or `{:error, :temporarily_unavailable}`.
  """
  def forward(rt, viewer_id, method, path_segments, query, content_type, body) do
    version = rt.version

    with script when is_binary(script) <- version.script_name,
         {:ok, dispatch} <- Config.dispatch() do
      path =
        "/internal/v1/apps/" <>
          seg(script) <> "/" <> Enum.map_join(path_segments, "/", &seg/1) <> query_string(query)

      timestamp = SystemsClock.system_time(:second) |> Integer.to_string()
      nonce = SystemsRuntime.Proc.random_bytes(16) |> Base.encode16(case: :lower)
      signature = Client.signature(dispatch.secret, "POST", path, timestamp, nonce, body)
      egress = get_in(version.manifest, ["backend", "egress"]) || []

      headers =
        [
          {"x-salix-request-id", SystemsRuntime.Proc.uuid()},
          {"x-salix-timestamp", timestamp},
          {"x-salix-nonce", nonce},
          {"x-salix-signature", signature},
          {"x-comma-app-method", method},
          {"x-comma-app-version", Integer.to_string(version.number)},
          {"x-comma-viewer", viewer_id},
          {"x-comma-app-egress", Enum.join(egress, ",")}
        ] ++ if(is_binary(content_type), do: [{"content-type", content_type}], else: [])

      [
        method: :post,
        url: dispatch.base_url <> path,
        headers: headers,
        body: body,
        decode_body: false,
        retry: false,
        redirect: false,
        receive_timeout: @timeout_ms,
        pool_timeout: @timeout_ms,
        connect_options: [timeout: @timeout_ms]
      ]
      |> Keyword.merge(SystemsRuntime.get_env(:comma_web, :mini_app_dispatch_http_options, []))
      |> Req.request()
      |> answer(rt)
    else
      nil -> {:error, :not_found}
      {:error, _} -> {:error, :temporarily_unavailable}
    end
  end

  defp answer({:ok, %Req.Response{status: status, body: body} = response}, rt) do
    body = IO.iodata_to_binary(body || "")
    content_type = response |> Req.Response.get_header("content-type") |> List.first()

    cond do
      byte_size(body) > @response_max ->
        record(rt, "response larger than 5 MiB")
        {:error, :response_too_large}

      status == 502 ->
        record(rt, app_error(body))
        {:ok, %{status: status, content_type: content_type, body: body}}

      status >= 500 ->
        record(rt, "backend answered #{status}")
        {:ok, %{status: status, content_type: content_type, body: body}}

      true ->
        {:ok, %{status: status, content_type: content_type, body: body}}
    end
  end

  defp answer({:error, reason}, rt) do
    Logger.warning("mini app dispatch failed: #{Exception.message(reason)}")
    record(rt, "the backend did not answer")
    {:error, :temporarily_unavailable}
  end

  defp app_error(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => code, "message" => message}} -> "#{code}: #{message}"
      {:ok, %{"error" => code}} -> to_string(code)
      _ -> "backend error"
    end
  end

  defp record(rt, line), do: RateLimit.record_error(rt.app.id, rt.version.number, line)

  defp query_string(nil), do: ""
  defp query_string(""), do: ""
  defp query_string(query), do: "?" <> query

  defp seg(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
