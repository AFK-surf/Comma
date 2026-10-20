defmodule SalixMeetNative.Rpc do
  @moduledoc false

  alias SalixMeetNative.RpcRequest

  @base_url "https://meet.google.com/$rpc/google.rtc.meetings.v1."
  @meetings_base_url "https://meetings.googleapis.com/$rpc/google.rtc.meetings.v1."
  @api_key "AIzaSyCG_6Rm6c7ucLr2NwAq33-vluCp2VfSkf0"
  @origin "https://meet.google.com"
  @rtcclient "CAEQqgMYASABKAg4AQ=="
  @safari_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Safari/605.1.15"
  @gzip_threshold 1024
  # replay path only: captured headers to drop, and the single-use tags spent by the device request.
  @skip_headers ~w(host content-length content-encoding accept-encoding connection)
  @spent_headers ~w(x-goog-meeting-botguardid x-goog-ext-174067345-bin)

  defmodule Client do
    @moduledoc false
    defstruct headers: %{}, user_agent: "", cookie: "", space: nil
  end

  @type response ::
          {:ok, non_neg_integer(), binary(), %{String.t() => [String.t()]}} | {:error, term()}
  @type ctx :: %{optional(atom()) => String.t() | nil}
  @type auth :: {:bearer, String.t()} | {:api_key, String.t() | nil}

  def base_url, do: @base_url
  def api_key, do: @api_key
  def rtcclient, do: @rtcclient
  def safari_ua, do: @safari_ua

  @doc "x-goog-meeting-debugid value: boq_hlane_ + 11 base64url chars (8 random bytes)."
  def debug_id,
    do: "boq_hlane_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(8), padding: false)

  # ---- native builders (synthesized OAuth path) ----

  # meet.google.com $rpc with the browser header set. Large bodies (>1KB, the offer) are gzipped;
  # CreateMediaSession authenticates with the meeting token + api key, every other call with the
  # account Bearer. The ext tag rides only on CreateMeetingDevice.
  @spec call_meet(String.t(), String.t(), binary(), auth(), ctx(), keyword()) :: response()
  def call_meet(method, service, body, auth, ctx \\ %{}, opts \\ []) do
    {payload, gzip?} = maybe_gzip(body)

    headers =
      %{
        "content-type" => "application/x-protobuf",
        "x-goog-encode-response-if-executable" => "base64",
        "x-goog-authuser" => "0",
        "x-goog-meeting-rtcclient" => Map.get(ctx, :rtcclient) || @rtcclient,
        "x-goog-meeting-debugid" => Map.get(ctx, :debugid) || debug_id(),
        "user-agent" => @safari_ua,
        "origin" => @origin,
        "referer" => referer(ctx)
      }
      |> put_if(gzip?, "content-encoding", "gzip")
      |> put_if(method == "CreateMeetingDevice", "x-goog-ext-174067345-bin", "CgIIAw==")
      |> put_if_present("x-goog-meeting-token", Map.get(ctx, :token))
      |> put_if_present("x-goog-meeting-identifier", Map.get(ctx, :identifier))
      |> put_if_present("x-compass-routing-destination", Map.get(ctx, :compass))
      |> put_auth(auth)

    post(
      @base_url <> service <> "/" <> method,
      headers,
      payload,
      Keyword.get(opts, :timeout_ms, 20_000),
      opts
    )
  end

  # meetings.googleapis.com $rpc: minimal Bearer set (ResolveMeetingSpace / GetMeetingSpace).
  @spec call_http(String.t(), String.t(), binary(), String.t(), ctx(), keyword()) :: response()
  def call_http(method, service, body, bearer, ctx \\ %{}, opts \\ []) do
    headers =
      %{
        "content-type" => "application/x-protobuf",
        "authorization" => "Bearer " <> bearer,
        "x-goog-meeting-rtcclient" => Map.get(ctx, :rtcclient) || @rtcclient
      }
      |> put_if(Map.get(ctx, :send_api_key, false), "x-goog-api-key", @api_key)
      |> put_if_present("x-goog-meeting-token", Map.get(ctx, :token))
      |> put_if_present("x-goog-meeting-identifier", Map.get(ctx, :identifier))
      |> put_if_present("x-compass-routing-destination", Map.get(ctx, :compass))

    post(
      @meetings_base_url <> service <> "/" <> method,
      headers,
      body,
      Keyword.get(opts, :timeout_ms, 20_000),
      opts
    )
  end

  # ---- replay builders (browser token-factory handoff / guest path) ----

  @spec replay(RpcRequest.t(), binary(), keyword()) :: response()
  def replay(%RpcRequest{} = request, body, opts \\ []) do
    headers =
      request.headers
      |> captured_headers()
      |> put_browser_headers(request.user_agent)

    headers =
      if request.cookie != "" do
        headers
        |> Map.put("cookie", request.cookie)
        |> Map.put_new_lazy("authorization", fn -> sapisidhash(request.cookie) end)
      else
        headers
      end

    post(request.url, headers, body, Keyword.get(opts, :timeout_ms, 30_000), opts)
  end

  @spec client_from_device_request(RpcRequest.t(), String.t() | nil, String.t() | nil, String.t()) ::
          %Client{}
  def client_from_device_request(%RpcRequest{} = device, compass, token, space) do
    headers =
      device.headers
      |> captured_headers()
      |> Map.drop(@spent_headers)
      |> put_if_present("x-compass-routing-destination", compass)
      |> put_if_present("x-goog-meeting-token", token)

    %Client{headers: headers, user_agent: device.user_agent, cookie: device.cookie, space: space}
  end

  @spec call(%Client{}, String.t(), String.t(), binary(), keyword()) :: response()
  def call(%Client{} = client, service, method, body, opts \\ []) do
    headers =
      client.headers
      |> Map.put("x-goog-api-key", @api_key)
      |> Map.put_new("x-goog-authuser", "0")
      |> put_browser_headers(client.user_agent)

    headers =
      if client.cookie != "" do
        headers
        |> Map.put("cookie", client.cookie)
        |> Map.put("authorization", sapisidhash(client.cookie))
      else
        headers
      end

    post(
      @base_url <> service <> "/" <> method,
      headers,
      body,
      Keyword.get(opts, :timeout_ms, 20_000),
      opts
    )
  end

  # ---- shared ----

  @spec post(String.t(), %{String.t() => String.t()}, binary(), pos_integer(), keyword()) ::
          response()
  def post(url, headers, body, timeout_ms, opts \\ []) do
    request =
      Req.new(
        [
          method: :post,
          url: url,
          body: body,
          redirect: false,
          retry: false,
          decode_body: false,
          compressed: false,
          receive_timeout: timeout_ms
        ] ++
          Keyword.get(
            opts,
            :req_options,
            SystemsRuntime.get_env(:salix_meet_native, :rpc_req_options, [])
          )
      )

    request =
      Enum.reduce(headers, request, fn {k, v}, req -> Req.Request.put_header(req, k, v) end)

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: resp_body, headers: resp_headers}} ->
        {:ok, status, IO.iodata_to_binary(resp_body), resp_headers}

      {:error, %{reason: reason}} when is_atom(reason) ->
        {:error, reason}

      {:error, %module{}} ->
        {:error, module}
    end
  end

  @spec header(%{String.t() => [String.t()]}, String.t()) :: String.t() | nil
  def header(headers, name) do
    case Map.get(headers, name) do
      [value | _] when value != "" -> value
      _ -> nil
    end
  end

  @spec parse_cookies(String.t()) :: %{String.t() => String.t()}
  def parse_cookies(header) do
    header
    |> String.split(";")
    |> Enum.reduce(%{}, fn part, acc ->
      case String.split(String.trim(part), "=", parts: 2) do
        [name, value] when name != "" -> Map.put(acc, name, value)
        _ -> acc
      end
    end)
  end

  @spec sapisidhash(String.t() | map(), String.t(), integer()) :: String.t()
  def sapisidhash(cookies, origin \\ @origin, ts \\ SystemsClock.system_time(:second))

  def sapisidhash(cookie, origin, ts) when is_binary(cookie),
    do: sapisidhash(parse_cookies(cookie), origin, ts)

  def sapisidhash(cookies, origin, ts) when is_map(cookies) do
    [
      {"SAPISIDHASH", "SAPISID"},
      {"SAPISID1PHASH", "__Secure-1PAPISID"},
      {"SAPISID3PHASH", "__Secure-3PAPISID"}
    ]
    |> Enum.flat_map(fn {scheme, cookie} ->
      case Map.get(cookies, cookie) do
        value when is_binary(value) and value != "" ->
          digest = :crypto.hash(:sha, "#{ts} #{value} #{origin}") |> Base.encode16(case: :lower)
          ["#{scheme} #{ts}_#{digest}"]

        _ ->
          []
      end
    end)
    |> Enum.join(" ")
  end

  defp captured_headers(headers) do
    for {k, v} <- headers,
        k = String.downcase(k),
        not String.starts_with?(k, ":"),
        k not in @skip_headers,
        into: %{},
        do: {k, v}
  end

  defp put_browser_headers(headers, user_agent) do
    headers
    |> put_if_present("user-agent", user_agent)
    |> Map.put("content-type", "application/x-protobuf")
    |> Map.put("origin", @origin)
    |> Map.put("referer", @origin <> "/")
    |> Map.put("accept-encoding", "identity")
  end

  defp maybe_gzip(body) when byte_size(body) > @gzip_threshold, do: {:zlib.gzip(body), true}
  defp maybe_gzip(body), do: {body, false}

  defp referer(ctx) do
    case Map.get(ctx, :code) do
      code when is_binary(code) and code != "" -> @origin <> "/" <> code
      _ -> @origin <> "/"
    end
  end

  defp put_auth(headers, {:bearer, token}),
    do: Map.put(headers, "authorization", "Bearer " <> token)

  defp put_auth(headers, {:api_key, key}), do: Map.put(headers, "x-goog-api-key", key || @api_key)

  defp put_if(headers, false, _key, _value), do: headers
  defp put_if(headers, _true, key, value), do: Map.put(headers, key, value)

  defp put_if_present(headers, _key, value) when value in [nil, ""], do: headers
  defp put_if_present(headers, key, value), do: Map.put(headers, key, value)
end
