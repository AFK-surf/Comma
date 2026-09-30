defmodule BridgeForTeams.Auth.Feishu.HTTP do
  @moduledoc """
  Real Feishu SSO HTTP adapter.

  This uses the current Feishu web OAuth flow shape:

    * authorize with `accounts.feishu.cn/open-apis/authen/v1/authorize`
    * exchange code with `open.feishu.cn/open-apis/authen/v2/oauth/token`
    * fetch user info with `open.feishu.cn/open-apis/authen/v1/user_info`

  The adapter returns only normalized identity fields and a small non-secret
  profile snapshot. Access tokens and raw provider responses are never returned
  to the auth facade.
  """
  @behaviour BridgeForTeams.Auth.Feishu

  @authorize_endpoint "https://accounts.feishu.cn/open-apis/authen/v1/authorize"
  @token_endpoint "https://open.feishu.cn/open-apis/authen/v2/oauth/token"
  @user_info_endpoint "https://open.feishu.cn/open-apis/authen/v1/user_info"
  @default_scope "contact:user.base:readonly"
  @http_timeout 10_000

  @impl true
  def authorize_url(sso, opts) do
    with {:ok, client_id} <- required(get(sso, :client_id), :missing_client_id),
         {:ok, redirect_uri} <-
           required(
             Keyword.get(opts, :redirect_uri) || get(sso, :redirect_uri),
             :missing_redirect_uri
           ) do
      state = random_url_token()
      config = provider_config(sso)

      query =
        %{
          "client_id" => client_id,
          "response_type" => "code",
          "redirect_uri" => redirect_uri,
          "scope" => Keyword.get(opts, :scope) || get(config, :scope) || @default_scope,
          "state" => state
        }
        |> reject_nil()

      url =
        endpoint(config, :authorize_endpoint, @authorize_endpoint) <>
          "?" <> URI.encode_query(query)

      {:ok, %{url: url, state: state, code_verifier: nil}}
    end
  end

  @impl true
  def fetch_identity(sso, params, opts) do
    started = System.monotonic_time()
    result = do_fetch_identity(sso, params, opts)

    BridgeForTeams.Telemetry.emit_operation(
      :sso,
      if(match?({:ok, _}, result), do: :ok, else: :error),
      System.monotonic_time() - started
    )

    result
  end

  defp do_fetch_identity(sso, params, opts) do
    with {:ok, code} <- fetch_code(params),
         {:ok, access_token} <- exchange_code(sso, code, opts),
         {:ok, user_info} <- fetch_user_info(sso, access_token) do
      {:ok, normalize_user_info(user_info)}
    end
  end

  defp exchange_code(sso, code, opts) do
    config = provider_config(sso)

    with {:ok, client_id} <- required(get(sso, :client_id), :missing_client_id),
         {:ok, client_secret} <- required(get(sso, :client_secret), :missing_client_secret),
         {:ok, redirect_uri} <-
           required(
             Keyword.get(opts, :redirect_uri) || get(sso, :redirect_uri),
             :missing_redirect_uri
           ),
         {:ok, body} <-
           post_json(endpoint(config, :token_endpoint, @token_endpoint), %{
             "grant_type" => "authorization_code",
             "client_id" => client_id,
             "client_secret" => client_secret,
             "code" => code,
             "redirect_uri" => redirect_uri
           }),
         {:ok, data} <- feishu_data(body),
         {:ok, token} <- access_token(data) do
      {:ok, token}
    end
  end

  defp fetch_user_info(sso, access_token) do
    config = provider_config(sso)
    url = endpoint(config, :user_info_endpoint, @user_info_endpoint)

    case Req.get(url,
           headers: [{"authorization", "Bearer " <> access_token}],
           receive_timeout: @http_timeout,
           retry: false
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        feishu_data(body)

      {:ok, %{status: status}} ->
        {:error, {:feishu_user_info_http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post_json(url, body) do
    case Req.post(url, json: body, receive_timeout: @http_timeout, retry: false) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:feishu_token_http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp feishu_data(%{"code" => code, "data" => data}) when code in [0, "0"] and is_map(data),
    do: {:ok, data}

  defp feishu_data(%{"code" => code}) when code not in [0, "0", nil],
    do: {:error, {:feishu_error, code}}

  defp feishu_data(data) when is_map(data), do: {:ok, data}
  defp feishu_data(_), do: {:error, :invalid_feishu_response}

  defp access_token(data) do
    case get(data, :access_token) || get(data, :user_access_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :missing_user_access_token}
    end
  end

  defp normalize_user_info(data) do
    %{
      "user_id" => get(data, :user_id),
      "union_id" => get(data, :union_id),
      "open_id" => get(data, :open_id),
      "email" => get(data, :email),
      "mobile" => get(data, :mobile),
      "display_name" => get(data, :name) || get(data, :en_name),
      "profile" =>
        data
        |> take([
          "tenant_key",
          "avatar_url",
          "avatar_thumb",
          "avatar_middle",
          "avatar_big",
          "en_name"
        ])
        |> reject_nil()
    }
    |> reject_nil()
  end

  defp fetch_code(params) do
    case get(params, :code) do
      code when is_binary(code) and code != "" -> {:ok, code}
      _ -> {:error, :missing_code}
    end
  end

  defp provider_config(sso), do: get(sso, :provider_config) || %{}

  defp endpoint(config, key, default), do: get(config, key) || default

  defp required(value, _error) when is_binary(value) and value != "", do: {:ok, value}
  defp required(_value, error), do: {:error, error}

  defp random_url_token(bytes \\ 32),
    do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp reject_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)

  defp take(map, keys),
    do: Map.take(map, keys) |> Map.merge(Map.take(map, Enum.map(keys, &String.to_atom/1)))
end
