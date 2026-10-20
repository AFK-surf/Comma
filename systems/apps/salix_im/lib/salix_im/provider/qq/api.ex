defmodule SalixIM.Provider.QQ.API do
  @moduledoc """
  Narrow Req adapter for the QQ bot OpenAPI (`https://api.bot.qq.com`).

  QQ publishes Go, Python and Node SDKs, and no Elixir one. Only the calls
  Salix IM needs live here: the app access token, the bot profile, messages,
  rich-media upload (in one request or in parts), interaction acknowledgement
  and command panels.

  A QQ bot authenticates with `Authorization: QQBot <access_token>`. The token
  comes from the app's AppID and AppSecret and lasts two hours; it is cached
  per app and minted again when QQ rejects it.
  """

  use SystemsRuntime.Server

  alias SalixIM.QQTiming

  @default_base "https://api.bot.qq.com"
  @token_cache_table :salix_im_qq_access_token_cache
  @default_token_ttl_seconds 7_200
  @token_expiry_skew_seconds 120
  @receive_timeout_ms 15_000
  @part_receive_timeout_ms 60_000
  # 11241..11244: the token is missing, malformed, wrong or expired.
  @token_rejection_codes [11_241, 11_242, 11_243, 11_244]

  @type error :: {:qq_api, non_neg_integer(), integer() | nil, String.t()} | String.t()

  @doc false
  def start_link(_opts), do: SystemsRuntime.Server.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    table =
      SystemsRuntime.ETS.new(@token_cache_table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{token_cache_table: table}}
  end

  @doc false
  def reset_token_cache do
    case SystemsRuntime.ETS.whereis(@token_cache_table) do
      :undefined -> :ok
      table -> SystemsRuntime.ETS.delete_all_objects(table)
    end

    :ok
  end

  @doc "The bot's own profile. It proves that the AppID and AppSecret are valid."
  @spec bot_profile(map()) :: {:ok, map()} | {:error, error()}
  def bot_profile(connect), do: request(connect, :get, "/users/@me")

  @doc """
  Calls one OpenAPI method as the connect's bot. A success returns the decoded
  body, or `%{}` when QQ sends none. A QQ error returns
  `{:error, {:qq_api, http_status, err_code, message}}`.
  """
  @spec request(map(), atom(), String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def request(connect, method, path, opts \\ []) when is_map(connect) and is_binary(path) do
    with {:ok, token} <- QQTiming.measure("access_token", fn -> access_token(connect) end) do
      case call(connect, method, path, token, opts) do
        {:error, {:qq_api, status, code, _message}} = rejected
        when status == 401 or code in @token_rejection_codes ->
          invalidate_cached_token(connect)

          with {:ok, token} <- QQTiming.measure("access_token", fn -> access_token(connect) end) do
            call(connect, method, path, token, opts)
          else
            _error -> rejected
          end

        result ->
          result
      end
    end
  end

  @doc """
  Puts one part of a file to the address QQ signed for it. The address carries
  its own authorization, so the bot's token does not go with it.
  """
  @spec put_part(String.t(), binary()) :: :ok | {:error, error()}
  def put_part(url, chunk) when is_binary(url) and is_binary(chunk) do
    if part_address?(url) do
      case Req.put(url,
             body: chunk,
             retry: false,
             redirect: false,
             decode_body: false,
             receive_timeout: @part_receive_timeout_ms
           ) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status}} -> {:error, {:qq_api, status, nil, "a file part was refused"}}
        {:error, _reason} -> {:error, "a file part could not be uploaded to QQ"}
      end
    else
      {:error, "QQ gave no usable upload address"}
    end
  end

  defp part_address?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) -> true
      # Tests take the parts on a local HTTP stub.
      %URI{scheme: "http", host: host} when is_binary(host) -> host in test_hosts()
      _other -> false
    end
  end

  defp test_hosts, do: List.wrap(SystemsRuntime.get_env(:salix_im, :qq_media_test_hosts, []))

  @spec access_token(map()) :: {:ok, String.t()} | {:error, error()}
  def access_token(connect) when is_map(connect) do
    app_id = str(connect["app_id"])
    app_secret = str(connect["app_secret"])

    cond do
      app_id == "" -> {:error, "QQ app_id is not configured"}
      app_secret == "" -> {:error, "QQ app_secret is not configured"}
      true -> cached_access_token(app_id, app_secret)
    end
  end

  @doc "A user-safe text for an API error."
  @spec error_text(error()) :: String.t()
  def error_text({:qq_api, status, nil, message}), do: "QQ API HTTP #{status}: #{message}"
  def error_text({:qq_api, _status, code, message}), do: "QQ API error #{code}: #{message}"
  def error_text(message) when is_binary(message), do: message
  def error_text(other), do: inspect(other)

  # ---- token ----

  defp cached_access_token(app_id, app_secret) do
    key = token_cache_key(app_id, app_secret)

    case read_cached_token(key) do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        SystemsRuntime.Proc.global_trans(
          {{__MODULE__, :access_token, key}, SystemsRuntime.Proc.self()},
          fn ->
            case read_cached_token(key) do
              {:ok, token} -> {:ok, token}
              :miss -> mint_and_cache(app_id, app_secret, key)
            end
          end
        )
    end
  end

  defp mint_and_cache(app_id, app_secret, key) do
    QQTiming.measure("token_http", fn ->
      Req.post(base_url() <> "/app/getAppAccessToken",
        json: %{"appId" => app_id, "clientSecret" => app_secret},
        retry: false,
        receive_timeout: @receive_timeout_ms
      )
      |> decode()
    end)
    |> case do
      {:ok, %{"access_token" => token} = body} when is_binary(token) and token != "" ->
        cache_token(key, token, body["expires_in"])
        {:ok, token}

      {:ok, _body} ->
        {:error, "QQ access token response has no token"}

      {:error, _reason} = error ->
        error
    end
  end

  defp read_cached_token(key) do
    table = token_cache_table()
    now_ms = SystemsClock.monotonic_time(:millisecond)

    case SystemsRuntime.ETS.lookup(table, key) do
      [{^key, token, expires_at_ms}] when expires_at_ms > now_ms -> {:ok, token}
      [_expired] -> SystemsRuntime.ETS.delete(table, key) && :miss
      [] -> :miss
    end
  end

  defp cache_token(key, token, expires_in) do
    ttl_seconds =
      expires_in
      |> int_or(@default_token_ttl_seconds)
      |> max(@token_expiry_skew_seconds + 1)
      |> Kernel.-(@token_expiry_skew_seconds)

    expires_at_ms = SystemsClock.monotonic_time(:millisecond) + ttl_seconds * 1_000
    true = SystemsRuntime.ETS.insert(token_cache_table(), {key, token, expires_at_ms})
    :ok
  end

  defp invalidate_cached_token(connect) do
    key = token_cache_key(str(connect["app_id"]), str(connect["app_secret"]))
    SystemsRuntime.ETS.delete(token_cache_table(), key)
    :ok
  end

  defp token_cache_key(app_id, app_secret),
    do: {base_url(), app_id, :crypto.hash(:sha256, app_secret)}

  defp token_cache_table do
    case SystemsRuntime.ETS.whereis(@token_cache_table) do
      :undefined -> raise "QQ access token cache is not started"
      table -> table
    end
  end

  # ---- transport ----

  defp call(_connect, method, path, token, opts) do
    QQTiming.measure("api_http", fn ->
      [
        method: method,
        url: base_url() <> path,
        headers: [{"authorization", "QQBot " <> token}],
        retry: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, @receive_timeout_ms)
      ]
      |> put_opt(:json, Keyword.get(opts, :json))
      |> put_opt(:params, Keyword.get(opts, :params))
      |> Req.request()
      |> decode()
    end)
  end

  defp put_opt(request, _key, nil), do: request
  defp put_opt(request, key, value), do: Keyword.put(request, key, value)

  # QQ answers a failure with `err_code` (newer methods) or `code`, and a
  # success with the business body alone.
  defp decode({:ok, %{status: status, body: body}}) when status in 200..299 do
    case body do
      %{"err_code" => code} = body when is_integer(code) and code != 0 ->
        {:error, {:qq_api, status, code, str(body["message"])}}

      %{} = body ->
        {:ok, body}

      _empty ->
        {:ok, %{}}
    end
  end

  defp decode({:ok, %{status: status, body: %{} = body}}) do
    code = body["err_code"] || body["code"]
    {:error, {:qq_api, status, if(is_integer(code), do: code), str(body["message"])}}
  end

  defp decode({:ok, %{status: status}}), do: {:error, {:qq_api, status, nil, "no error body"}}

  # The request may have reached QQ. The stable class names that unknown outcome.
  defp decode({:error, %Req.TransportError{reason: :timeout} = reason}),
    do: {:error, %{"error_class" => "provider_timeout", "message" => inspect(reason)}}

  defp decode({:error, reason}), do: {:error, inspect(reason)}

  defp base_url do
    :salix_im
    |> SystemsRuntime.get_env(:qq_api_base_url, @default_base)
    |> to_string()
    |> String.trim_trailing("/")
    |> case do
      "" -> @default_base
      base -> base
    end
  end

  defp int_or(value, _default) when is_integer(value), do: value

  defp int_or(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp int_or(_value, default), do: default

  defp str(nil), do: ""
  defp str(value) when is_binary(value), do: String.trim(value)
  defp str(value), do: value |> to_string() |> String.trim()
end
