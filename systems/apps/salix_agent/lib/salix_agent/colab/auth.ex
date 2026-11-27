defmodule SalixAgent.Colab.Auth do
  @moduledoc """
  Google Colab OAuth 2.0 (PKCE S256) client for Comma.

  Requests only the 4 minimal scopes required for `/tun/m/*` GPU compute:
  `openid`, `userinfo.email`, `userinfo.profile`, and `colaboratory`
  (never `cloud-platform` or `drive.file`).

  Endpoints, client credentials, and Req options are read from
  `SystemsRuntime.get_env(:salix_agent, :colab_oauth, [])` so tests inject
  local mocks without real network calls.
  """

  @colab_scope "https://www.googleapis.com/auth/colaboratory"

  @scopes [
    "openid",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
    @colab_scope
  ]

  @default_client_id "764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com"
  @default_client_secret "d-FL95Q19q7MQmFpd7hHD0Ty"
  @default_redirect_uri "https://sdk.cloud.google.com/applicationdefaultauthcode.html"
  @default_auth_uri "https://accounts.google.com/o/oauth2/auth"
  @default_token_uri "https://oauth2.googleapis.com/token"
  @default_userinfo_uri "https://www.googleapis.com/oauth2/v2/userinfo"

  @valid_issuers ["https://accounts.google.com", "accounts.google.com"]

  @doc "Minimal OAuth scopes requested for Google Colab."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc "Configured OAuth redirect URI for Google Colab."
  @spec redirect_uri() :: String.t()
  def redirect_uri, do: config()[:redirect_uri] || @default_redirect_uri

  @doc """
  Parse and validate user-pasted Google OAuth authorization input.

  Supports:
  - Full redirect URL (`https://...?code=...&state=...` or `#code=...&state=...`)
  - Query string (`code=...&state=...`)
  - `code#state`
  - Bare authorization code (as shown by Google's `applicationdefaultauthcode.html` copy button)

  When `expected_state:` is provided, any URL, query string, or `code#state` input
  must carry a matching `state`; `error=...` parameters are always rejected.
  """
  @spec parse_authorization_input(String.t(), keyword()) ::
          {:ok, %{code: String.t(), state: String.t() | nil}}
          | {:error, :invalid_code | :state_mismatch | :oauth_error}
  def parse_authorization_input(input, opts \\ [])

  def parse_authorization_input(input, opts) when is_binary(input) and is_list(opts) do
    trimmed = String.trim(input)
    expected_state = Keyword.get(opts, :expected_state)

    cond do
      trimmed == "" or byte_size(trimmed) > 4096 ->
        {:error, :invalid_code}

      String.starts_with?(trimmed, "http://") or String.starts_with?(trimmed, "https://") ->
        parse_redirect_url(trimmed, expected_state)

      String.contains?(trimmed, "code=") or String.contains?(trimmed, "error=") ->
        parse_query_params(URI.decode_query(String.trim_leading(trimmed, "?")), expected_state)

      String.contains?(trimmed, "#") ->
        parse_code_hash_state(trimmed, expected_state)

      true ->
        if Regex.match?(~r/\s/, trimmed) or String.contains?(trimmed, <<0>>) do
          {:error, :invalid_code}
        else
          {:ok, %{code: trimmed, state: nil}}
        end
    end
  end

  def parse_authorization_input(_, _), do: {:error, :invalid_code}

  defp parse_redirect_url(url, expected_state) do
    uri = URI.parse(url)

    query_params =
      if is_binary(uri.query) and uri.query != "", do: URI.decode_query(uri.query), else: %{}

    fragment_params =
      if is_binary(uri.fragment) and uri.fragment != "" and
           (String.contains?(uri.fragment, "code=") or String.contains?(uri.fragment, "error=")) do
        URI.decode_query(uri.fragment)
      else
        %{}
      end

    params = Map.merge(fragment_params, query_params)
    parse_query_params(params, expected_state)
  end

  defp parse_query_params(params, expected_state) when is_map(params) do
    error = clean_string(params["error"])
    code = clean_string(params["code"])
    state = clean_string(params["state"])

    cond do
      is_binary(error) ->
        {:error, :oauth_error}

      is_nil(code) or Regex.match?(~r/\s/, code) ->
        {:error, :invalid_code}

      is_binary(expected_state) and expected_state != "" ->
        if is_binary(state) and secure_equal?(state, expected_state) do
          {:ok, %{code: code, state: state}}
        else
          {:error, :state_mismatch}
        end

      true ->
        {:ok, %{code: code, state: state}}
    end
  end

  defp parse_code_hash_state(raw, expected_state) do
    case String.split(raw, "#", parts: 2) do
      [raw_code, raw_state] ->
        code = clean_string(raw_code)
        state = clean_string(raw_state)

        cond do
          is_nil(code) or Regex.match?(~r/\s/, code) ->
            {:error, :invalid_code}

          is_binary(expected_state) and expected_state != "" ->
            if is_binary(state) and secure_equal?(state, expected_state) do
              {:ok, %{code: code, state: state}}
            else
              {:error, :state_mismatch}
            end

          true ->
            {:ok, %{code: code, state: state}}
        end

      _ ->
        {:error, :invalid_code}
    end
  end

  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  @doc """
  Begin a PKCE S256 OAuth authorization flow (`token_usage=remote`,
  `access_type=offline`, `prompt=consent`, optional `login_hint`).
  """
  @spec begin(keyword() | map()) ::
          {:ok, %{url: String.t(), state: String.t(), code_verifier: String.t()}}
  def begin(opts \\ []) do
    opts = if is_map(opts), do: Enum.into(opts, []), else: opts

    state =
      case Keyword.get(opts, :state) do
        s when is_binary(s) and byte_size(s) > 0 -> s
        _ -> Base.url_encode64(SystemsRuntime.Proc.random_bytes(24), padding: false)
      end

    code_verifier = Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)

    code_challenge =
      :crypto.hash(:sha256, code_verifier)
      |> Base.url_encode64(padding: false)

    login_hint = Keyword.get(opts, :login_hint)

    params =
      [
        {"client_id", client_id()},
        {"redirect_uri", redirect_uri()},
        {"response_type", "code"},
        {"scope", Enum.join(@scopes, " ")},
        {"state", state},
        {"code_challenge", code_challenge},
        {"code_challenge_method", "S256"},
        {"access_type", "offline"},
        {"prompt", "consent"},
        {"token_usage", "remote"}
      ]
      |> then(fn list ->
        if is_binary(login_hint) and String.trim(login_hint) != "" do
          list ++ [{"login_hint", String.trim(login_hint)}]
        else
          list
        end
      end)

    url = auth_uri() <> "?" <> URI.encode_query(params)
    {:ok, %{url: url, state: state, code_verifier: code_verifier}}
  end

  @doc """
  Exchange an authorization code + PKCE `code_verifier` for tokens and verified
  Google identity (`google_sub` + optional `email`).
  """
  @spec exchange_code(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def exchange_code(code, code_verifier, opts \\ [])

  def exchange_code(code, code_verifier, opts)
      when is_binary(code) and code != "" and is_binary(code_verifier) and code_verifier != "" and
             is_list(opts) do
    form = [
      code: code,
      client_id: client_id(),
      client_secret: client_secret(),
      redirect_uri: Keyword.get(opts, :redirect_uri) || redirect_uri(),
      grant_type: "authorization_code",
      code_verifier: code_verifier
    ]

    with {:ok, body} <- post_token(form, :exchange, opts),
         {:ok, access_token} <- non_empty(body["access_token"], :exchange_failed),
         {:ok, expires_at} <- compute_expires_at(body["expires_in"]),
         :ok <- verify_colab_scope(body["scope"]),
         {:ok, identity} <- extract_identity(body["id_token"], access_token) do
      credentials =
        %{
          "access_token" => access_token,
          "token_type" => non_empty_or(body["token_type"], "Bearer"),
          "scope" => body["scope"],
          "expires_at" => expires_at,
          "google_sub" => identity.google_sub
        }
        |> maybe_put("refresh_token", body["refresh_token"])
        |> maybe_put("email", identity.email)

      {:ok, credentials}
    end
  end

  def exchange_code(_, _, _), do: {:error, :invalid_input}

  @doc """
  Refresh an access token using `refresh_token` (either a raw token string or a
  credentials map containing `"refresh_token"`).

  Classifies errors precisely:
  - `400 invalid_grant` -> `{:error, :invalid_grant}`
  - `401 invalid_client` -> `{:error, :platform_unavailable}`
  - `429` / `5xx` / timeout / network -> `{:error, :token_refresh_failed}`

  Preserves the previous `refresh_token` when Google does not return a new one.
  """
  @spec refresh_token(String.t() | map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def refresh_token(token_or_map, opts \\ [])
  def refresh_token(%{"refresh_token" => token}, opts), do: refresh_token(token, opts)
  def refresh_token(%{}, _opts), do: {:error, :invalid_grant}

  def refresh_token(refresh_token, opts)
      when is_binary(refresh_token) and refresh_token != "" and is_list(opts) do
    form = [
      client_id: client_id(),
      client_secret: client_secret(),
      refresh_token: refresh_token,
      grant_type: "refresh_token"
    ]

    with {:ok, body} <- post_token(form, :refresh, opts),
         {:ok, access_token} <- non_empty(body["access_token"], :token_refresh_failed),
         {:ok, expires_at} <- compute_expires_at(body["expires_in"]) do
      new_refresh = non_empty_or(body["refresh_token"], refresh_token)

      result =
        %{
          "access_token" => access_token,
          "refresh_token" => new_refresh,
          "token_type" => non_empty_or(body["token_type"], "Bearer"),
          "expires_at" => expires_at
        }
        |> maybe_put("scope", body["scope"])

      {:ok, result}
    end
  end

  def refresh_token(_, _), do: {:error, :invalid_grant}

  # ---- Identity extraction ----

  defp extract_identity(id_token, access_token) do
    from_jwt = parse_id_token(id_token)

    cond do
      is_binary(from_jwt.google_sub) and is_binary(from_jwt.email) ->
        {:ok, from_jwt}

      true ->
        from_userinfo = fetch_userinfo(access_token)
        google_sub = from_jwt.google_sub || from_userinfo.google_sub
        email = from_jwt.email || from_userinfo.email

        if is_binary(google_sub) and google_sub != "" do
          {:ok, %{google_sub: google_sub, email: email}}
        else
          {:error, :invalid_identity}
        end
    end
  end

  defp parse_id_token(token) when is_binary(token) do
    now = SystemsClock.system_time(:second)

    with [_, payload_b64, _] <- String.split(token, ".", parts: 3),
         {:ok, json} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, %{} = claims} <- Jason.decode(json),
         true <- claims["iss"] in @valid_issuers,
         true <- valid_audience?(claims["aud"]),
         true <- is_integer(claims["exp"]) and claims["exp"] > now do
      google_sub = clean_string(claims["sub"])

      email =
        if claims["email_verified"] != false do
          clean_string(claims["email"])
        else
          nil
        end

      %{google_sub: google_sub, email: email}
    else
      _ -> %{google_sub: nil, email: nil}
    end
  end

  defp parse_id_token(_), do: %{google_sub: nil, email: nil}

  defp valid_audience?(aud) when is_binary(aud), do: aud == client_id()
  defp valid_audience?(aud) when is_list(aud), do: client_id() in aud
  defp valid_audience?(_), do: false

  defp fetch_userinfo(access_token) do
    headers = [
      {"authorization", "Bearer " <> access_token},
      {"accept", "application/json"}
    ]

    case Req.get(userinfo_uri(), req_options(headers: headers)) do
      {:ok, %{status: 200, body: %{} = body}} ->
        google_sub = clean_string(body["id"] || body["sub"])

        email =
          if body["verified_email"] != false and body["email_verified"] != false do
            clean_string(body["email"])
          else
            nil
          end

        %{google_sub: google_sub, email: email}

      _ ->
        %{google_sub: nil, email: nil}
    end
  rescue
    _ -> %{google_sub: nil, email: nil}
  end

  # ---- HTTP & validation helpers ----

  defp post_token(form, mode, opts) do
    headers = [{"accept", "application/json"}]
    extra = Keyword.take(opts, [:receive_timeout])

    case Req.post(token_uri(), req_options([form: form, headers: headers] ++ extra)) do
      {:ok, %{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %{status: 200, body: raw}} when is_binary(raw) ->
        case Jason.decode(raw) do
          {:ok, %{} = body} -> {:ok, body}
          _ -> {:error, default_error(mode)}
        end

      {:ok, %{status: status, body: body}} ->
        classify_token_error(status, decode_map(body), mode)

      {:error, _reason} ->
        {:error, default_error(mode)}
    end
  rescue
    _ -> {:error, default_error(mode)}
  end

  defp classify_token_error(400, %{"error" => "invalid_grant"}, _mode),
    do: {:error, :invalid_grant}

  defp classify_token_error(401, %{"error" => "invalid_client"}, _mode),
    do: {:error, :platform_unavailable}

  defp classify_token_error(400, %{"error" => "invalid_client"}, _mode),
    do: {:error, :platform_unavailable}

  defp classify_token_error(status, _body, :refresh) when status == 429 or status >= 500,
    do: {:error, :token_refresh_failed}

  defp classify_token_error(_status, _body, mode),
    do: {:error, default_error(mode)}

  defp default_error(:refresh), do: :token_refresh_failed
  defp default_error(:exchange), do: :exchange_failed

  defp verify_colab_scope(scope) when is_binary(scope) do
    granted = String.split(scope, ~r/\s+/, trim: true)

    if @colab_scope in granted do
      :ok
    else
      {:error, :missing_colaboratory_scope}
    end
  end

  defp verify_colab_scope(_), do: {:error, :missing_colaboratory_scope}

  defp compute_expires_at(seconds) when is_integer(seconds) and seconds > 0 do
    {:ok,
     SystemsClock.utc_now()
     |> DateTime.add(seconds, :second)
     |> DateTime.truncate(:second)
     |> DateTime.to_iso8601()}
  end

  defp compute_expires_at(_), do: {:error, :invalid_token_response}

  defp decode_map(%{} = body), do: body

  defp decode_map(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = body} -> body
      _ -> %{}
    end
  end

  defp decode_map(_), do: %{}

  defp non_empty(value, _error) when is_binary(value) and value != "", do: {:ok, value}
  defp non_empty(_, error), do: {:error, error}

  defp non_empty_or(value, _default) when is_binary(value) and value != "", do: value
  defp non_empty_or(_, default), do: default

  defp clean_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp clean_string(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp req_options(opts) do
    [
      retry: false,
      redirect: false,
      receive_timeout: 20_000,
      connect_options: [timeout: 5_000]
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(config()[:req_options] || [])
  end

  defp config, do: SystemsRuntime.get_env(:salix_agent, :colab_oauth, [])
  defp client_id, do: config()[:client_id] || @default_client_id
  defp client_secret, do: config()[:client_secret] || @default_client_secret
  defp auth_uri, do: config()[:auth_uri] || @default_auth_uri
  defp token_uri, do: config()[:token_uri] || @default_token_uri
  defp userinfo_uri, do: config()[:userinfo_uri] || @default_userinfo_uri
end
