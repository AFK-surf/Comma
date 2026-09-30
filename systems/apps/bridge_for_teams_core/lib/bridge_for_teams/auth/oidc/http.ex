defmodule BridgeForTeams.Auth.OIDC.HTTP do
  @moduledoc """
  Real `BridgeForTeams.Auth.OIDC` implementation (design §7).

  * Discovery: fetches `<issuer>/.well-known/openid-configuration` and the
    referenced JWKS with `:req`, caching both in `BridgeForTeams.Cache`.
  * Authorize URL: builds an authorization-code + PKCE (S256) request with a
    random `state` and `code_verifier`.
  * Token exchange: POSTs the code + `code_verifier` to the token endpoint.
  * id_token verification: validates the JWS signature against the issuer JWKS
    via `:jose`, then checks `iss`/`aud`/`exp` claims.

  The org SSO connection (`sso`) is a map with string-or-atom keys:
  `issuer`, `client_id`, `client_secret` (already decrypted by `BridgeForTeams.Auth`),
  and `redirect_uri`.
  """
  @behaviour BridgeForTeams.Auth.OIDC

  alias BridgeForTeams.Cache

  @discovery_ttl_ms :timer.minutes(60)
  @jwks_ttl_ms :timer.minutes(60)
  @clock_skew_seconds 60
  @http_timeout 10_000

  @impl true
  def discover(issuer) when is_binary(issuer) do
    cache_key = {:oidc_discovery, issuer}

    case Cache.get(cache_key) do
      {:ok, doc} ->
        {:ok, doc}

      _ ->
        url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

        case get_json(url) do
          {:ok, doc} when is_map(doc) ->
            Cache.put(cache_key, doc, ttl: @discovery_ttl_ms)
            {:ok, doc}

          {:ok, _} ->
            {:error, :invalid_discovery_document}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def authorize_url(sso, opts) do
    with {:ok, doc} <- discover(get(sso, :issuer)) do
      state = random_url_token()
      code_verifier = random_url_token(64)
      code_challenge = pkce_challenge(code_verifier)

      query =
        %{
          "response_type" => "code",
          "client_id" => get(sso, :client_id),
          "redirect_uri" => Keyword.get(opts, :redirect_uri) || get(sso, :redirect_uri),
          "scope" => Keyword.get(opts, :scope, "openid email profile"),
          "state" => state,
          "code_challenge" => code_challenge,
          "code_challenge_method" => "S256",
          "nonce" => random_url_token()
        }
        |> reject_nil()

      url = doc["authorization_endpoint"] <> "?" <> URI.encode_query(query)
      {:ok, %{url: url, state: state, code_verifier: code_verifier}}
    end
  end

  @impl true
  def exchange_code(sso, code, code_verifier, opts) do
    with {:ok, doc} <- discover(get(sso, :issuer)) do
      form =
        %{
          "grant_type" => "authorization_code",
          "code" => code,
          "code_verifier" => code_verifier,
          "client_id" => get(sso, :client_id),
          "client_secret" => get(sso, :client_secret),
          "redirect_uri" => Keyword.get(opts, :redirect_uri) || get(sso, :redirect_uri)
        }
        |> reject_nil()

      post_form(doc["token_endpoint"], form)
    end
  end

  @impl true
  def verify_id_token(sso, id_token) when is_binary(id_token) do
    issuer = get(sso, :issuer)

    with {:ok, jwks} <- fetch_jwks(issuer),
         {:ok, claims} <- verify_signature(jwks, id_token),
         :ok <- validate_claims(claims, issuer, get(sso, :client_id)) do
      {:ok, claims}
    end
  end

  def verify_id_token(_sso, _), do: {:error, :invalid_id_token}

  # --- JWKS ---

  defp fetch_jwks(issuer) do
    cache_key = {:oidc_jwks, issuer}

    case Cache.get(cache_key) do
      {:ok, jwks} ->
        {:ok, jwks}

      _ ->
        with {:ok, doc} <- discover(issuer),
             uri when is_binary(uri) <- doc["jwks_uri"],
             {:ok, %{"keys" => keys}} <- get_json(uri) do
          Cache.put(cache_key, keys, ttl: @jwks_ttl_ms)
          {:ok, keys}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :no_jwks}
        end
    end
  end

  defp verify_signature(keys, id_token) do
    kid = peek_kid(id_token)

    candidates =
      case Enum.find(keys, fn k -> kid && k["kid"] == kid end) do
        nil -> keys
        key -> [key]
      end

    Enum.find_value(candidates, {:error, :signature_verification_failed}, fn jwk_map ->
      jwk = JOSE.JWK.from_map(jwk_map)

      case JOSE.JWT.verify_strict(jwk, allowed_algs(jwk_map), id_token) do
        {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
        _ -> false
      end
    end)
  end

  defp allowed_algs(%{"alg" => alg}) when is_binary(alg), do: [alg]
  defp allowed_algs(%{"kty" => "RSA"}), do: ["RS256", "RS384", "RS512"]
  defp allowed_algs(%{"kty" => "EC"}), do: ["ES256", "ES384", "ES512"]
  defp allowed_algs(_), do: ["RS256"]

  defp peek_kid(id_token) do
    with [header_b64 | _] <- String.split(id_token, "."),
         {:ok, json} <- Base.url_decode64(header_b64, padding: false),
         {:ok, %{"kid" => kid}} <- Jason.decode(json) do
      kid
    else
      _ -> nil
    end
  end

  defp validate_claims(claims, issuer, client_id) do
    now = System.system_time(:second)

    cond do
      claims["iss"] && claims["iss"] != issuer ->
        {:error, :issuer_mismatch}

      client_id && not audience_ok?(claims["aud"], client_id) ->
        {:error, :audience_mismatch}

      is_integer(claims["exp"]) and claims["exp"] + @clock_skew_seconds < now ->
        {:error, :token_expired}

      true ->
        :ok
    end
  end

  defp audience_ok?(aud, client_id) when is_binary(aud), do: aud == client_id
  defp audience_ok?(aud, client_id) when is_list(aud), do: client_id in aud
  defp audience_ok?(_, _), do: false

  # --- PKCE ---

  defp pkce_challenge(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  defp random_url_token(bytes \\ 32),
    do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  # --- HTTP ---

  defp get_json(url) do
    case Req.get(url, receive_timeout: @http_timeout, retry: false) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_form(url, form) do
    case Req.post(url, form: form, receive_timeout: @http_timeout, retry: false) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, %{"raw" => body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_endpoint, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- helpers ---

  defp get(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp reject_nil(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
end
