defmodule BridgeForTeams.Auth.Lark.HTTP do
  @moduledoc """
  Lark SSO HTTP adapter.

  The web OAuth flow of the Lark open platform:

    * authorize at `accounts.larksuite.com/open-apis/authen/v1/authorize`, with
      PKCE (S256)
    * exchange the code at `open.larksuite.com/open-apis/authen/v2/oauth/token`
    * read the user at `open.larksuite.com/open-apis/authen/v1/user_info`

  The user info needs no scope for the name and the `open_id`/`union_id`.
  Lark returns `email` only with `contact:user.email:readonly` and `user_id`
  only with `contact:user.employee_id:readonly`, so the adapter requests no
  scope unless the connection's `provider_config` has one.

  `provider_config` can replace each endpoint (`authorize_endpoint`,
  `token_endpoint`, `user_info_endpoint`). The settings API does not accept
  those keys.

  The adapter returns normalized identity fields and a small profile without
  secrets. It returns no access token and no raw response from Lark.
  """
  @behaviour BridgeForTeams.Auth.Lark

  @authorize_endpoint "https://accounts.larksuite.com/open-apis/authen/v1/authorize"
  @token_endpoint "https://open.larksuite.com/open-apis/authen/v2/oauth/token"
  @user_info_endpoint "https://open.larksuite.com/open-apis/authen/v1/user_info"
  @http_timeout 10_000

  @impl true
  def authorize_url(sso, opts) do
    with {:ok, client_id} <- required(get(sso, :client_id), :missing_client_id),
         {:ok, redirect_uri} <- redirect_uri(sso, opts) do
      state = random_url_token()
      code_verifier = random_url_token(64)
      config = provider_config(sso)

      query =
        %{
          "client_id" => client_id,
          "response_type" => "code",
          "redirect_uri" => redirect_uri,
          "scope" => Keyword.get(opts, :scope) || get(config, :scope),
          "state" => state,
          "code_challenge" => pkce_challenge(code_verifier),
          "code_challenge_method" => "S256"
        }
        |> reject_blank()

      url =
        endpoint(config, :authorize_endpoint, @authorize_endpoint) <>
          "?" <> URI.encode_query(query)

      {:ok, %{url: url, state: state, code_verifier: code_verifier}}
    end
  end

  @impl true
  def fetch_identity(sso, params, opts) do
    started = SystemsClock.monotonic_time()
    result = do_fetch_identity(sso, params, opts)

    BridgeForTeams.Telemetry.emit_operation(
      :sso,
      if(match?({:ok, _}, result), do: :ok, else: :error),
      SystemsClock.monotonic_time() - started,
      %{provider: "lark"}
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
         {:ok, redirect_uri} <- redirect_uri(sso, opts),
         {:ok, body} <-
           post_json(
             endpoint(config, :token_endpoint, @token_endpoint),
             %{
               "grant_type" => "authorization_code",
               "client_id" => client_id,
               "client_secret" => client_secret,
               "code" => code,
               "redirect_uri" => redirect_uri,
               "code_verifier" => Keyword.get(opts, :code_verifier)
             }
             |> reject_blank()
           ),
         {:ok, data} <- lark_data(body) do
      access_token(data)
    end
  end

  defp fetch_user_info(sso, access_token) do
    url = endpoint(provider_config(sso), :user_info_endpoint, @user_info_endpoint)

    case Req.get(url,
           headers: [{"authorization", "Bearer " <> access_token}],
           receive_timeout: @http_timeout,
           retry: false
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> lark_data(body)
      {:ok, %{status: status}} -> {:error, {:lark_user_info_http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_json(url, body) do
    case Req.post(url, json: body, receive_timeout: @http_timeout, retry: false) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:lark_token_http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The token endpoint answers with the token beside `code`; the user info
  # endpoint answers with the user under `data`.
  defp lark_data(%{"code" => code}) when code not in [0, "0", nil],
    do: {:error, {:lark_error, code}}

  defp lark_data(%{"data" => data}) when is_map(data), do: {:ok, data}
  defp lark_data(data) when is_map(data), do: {:ok, data}
  defp lark_data(_), do: {:error, :invalid_lark_response}

  defp access_token(data) do
    case get(data, :access_token) do
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
        |> Map.take(~w(tenant_key avatar_url avatar_thumb avatar_middle avatar_big en_name))
        |> reject_blank()
    }
    |> reject_blank()
  end

  defp fetch_code(params) do
    case get(params, :code) do
      code when is_binary(code) and code != "" -> {:ok, code}
      _ -> {:error, :missing_code}
    end
  end

  defp redirect_uri(sso, opts) do
    required(Keyword.get(opts, :redirect_uri) || get(sso, :redirect_uri), :missing_redirect_uri)
  end

  defp provider_config(sso), do: get(sso, :provider_config) || %{}

  defp endpoint(config, key, default) do
    case get(config, key) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  defp required(value, _error) when is_binary(value) and value != "", do: {:ok, value}
  defp required(_value, error), do: {:error, error}

  defp random_url_token(bytes \\ 32),
    do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(bytes), padding: false)

  defp pkce_challenge(verifier),
    do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp reject_blank(map),
    do: Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)
end
