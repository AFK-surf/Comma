defmodule CommaWeb.OauthIdpEndpoints do
  @moduledoc """
  Machine-side endpoints of the Comma OAuth/OIDC identity provider
  (docs/identity-security.md, PR 4/10): OIDC discovery, JWKS,
  token exchange, and userinfo.

  Protocol handling is delegated to `Boruta.Oauth`/`Boruta.Openid`
  wired to the `Comma.OauthIdp` adapters; this module owns only HTTP
  transport (response shapes, headers, the deployment feature flag).
  The browser-side `/oauth2/authorize` endpoint and its consent page
  are a separate PR (§11.2 PR 5) with its own security review.

  All four endpoints are authentication-exempt in `CommaWeb.Auth`: the
  token endpoint authenticates the OAuth client itself (PKCE or client
  secret) and userinfo authenticates the presented access token —
  both inside Boruta, neither via Comma sessions. While the feature flag
  is off every endpoint answers 404 and no Boruta code runs.
  """

  import Plug.Conn

  require Logger

  alias Boruta.Oauth.Error
  alias Boruta.Oauth.TokenResponse
  alias Boruta.Openid.UserinfoResponse

  @public_paths [
    "/.well-known/openid-configuration",
    "/.well-known/jwks.json",
    "/oauth2/token",
    "/oauth2/userinfo"
  ]

  @cors_max_age "600"

  @doc "True when the deployment has switched the IdP surface on."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:comma_web, :oauth_idp_enabled, false) == true
  end

  @doc """
  Paths served by this module. They bypass Comma session authentication
  and carry the public-CORS policy; nothing else does.
  """
  @spec public_path?(String.t()) :: boolean()
  def public_path?(path), do: path in @public_paths

  @doc """
  Public-endpoint CORS: these endpoints are authenticated by client
  credentials, PKCE, or bearer access tokens — never by cookies — so
  any web origin may call them (RFC §6.1). Preflights are answered
  here; actual responses get the wildcard origin appended.
  """
  @spec put_public_cors(Plug.Conn.t()) :: Plug.Conn.t()
  def put_public_cors(%Plug.Conn{method: "OPTIONS"} = conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET,POST,OPTIONS")
    |> put_resp_header("access-control-allow-headers", "authorization,content-type")
    |> put_resp_header("access-control-max-age", @cors_max_age)
    |> send_resp(204, "")
    |> halt()
  end

  def put_public_cors(conn) do
    put_resp_header(conn, "access-control-allow-origin", "*")
  end

  @doc false
  @spec not_found(Plug.Conn.t()) :: Plug.Conn.t()
  def not_found(conn) do
    send_json(conn, 404, %{error: "not_found"})
  end

  ## Rate limiting (docs/identity-security.md, PR 9)

  @doc """
  Fail-closed per-peer token bucket in front of the authorize and token
  entry points. Returns `{:allow, conn}` or a halted conn: `429` with
  `Retry-After` when the peer exhausted its bucket, `503` with
  `Retry-After` when no decision could be made (Redis down, limiter not
  running, invalid policy) — an undecidable request is rejected, never
  passed. The peer is `conn.remote_ip`; forwarding headers are never
  consulted (user-system RFC peer-limit rule).
  """
  @spec rate_limit(Plug.Conn.t(), :authorize | :token) :: {:allow, Plug.Conn.t()} | Plug.Conn.t()
  def rate_limit(conn, endpoint) do
    case Comma.OauthIdp.RateLimit.check(endpoint, conn.remote_ip) do
      :allow ->
        {:allow, conn}

      {:deny, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_json(429, %{error: "rate_limited"})
        |> halt()

      {:unavailable, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_json(503, %{error: "temporarily_unavailable"})
        |> halt()
    end
  end

  ## Telemetry (docs/identity-security.md, PR 9)

  @telemetry_endpoints %{
    "/.well-known/openid-configuration" => :discovery,
    "/.well-known/jwks.json" => :jwks,
    "/oauth2/authorize" => :authorize,
    "/oauth2/token" => :token,
    "/oauth2/userinfo" => :userinfo
  }

  @doc """
  Annotates the response with its semantic outcome. OAuth settles many
  rejections as 302 redirects back to the client (user deny,
  invalid_scope, ...), so the HTTP status alone cannot classify
  authorize responses — settlement points call this and
  `register_telemetry/1` prefers the annotation over the status
  fallback.
  """
  @spec put_outcome(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def put_outcome(conn, outcome) when is_atom(outcome) do
    put_private(conn, :comma_oauth_idp_outcome, outcome)
  end

  @doc """
  Registers the low-cardinality endpoint × outcome counter for an IdP
  request. The outcome is the settlement point's explicit annotation
  (`put_outcome/2`) when present, else derived from the response
  status — one seam for Boruta, the consent flow, the rate limiter,
  and the disabled-flag 404.
  """
  @spec register_telemetry(Plug.Conn.t()) :: Plug.Conn.t()
  def register_telemetry(conn) do
    case Map.fetch(@telemetry_endpoints, conn.request_path) do
      {:ok, endpoint} ->
        register_before_send(conn, fn conn ->
          :telemetry.execute(
            [:comma_product, :oauth_idp, :request],
            %{count: 1},
            %{endpoint: endpoint, outcome: response_outcome(conn)}
          )

          conn
        end)

      :error ->
        conn
    end
  end

  defp response_outcome(conn) do
    conn.private[:comma_oauth_idp_outcome] || outcome_for_status(conn.status)
  end

  defp outcome_for_status(status) when is_integer(status) do
    cond do
      status == 404 -> :not_found
      status == 429 -> :rate_limited
      status == 503 -> :unavailable
      status in 200..399 -> :ok
      status in 400..499 -> :rejected
      true -> :error
    end
  end

  defp outcome_for_status(_status), do: :error

  ## Discovery

  # The discovery document is derived entirely from the issuer and values
  # fixed in this module: it changes only on deploy, carries nothing
  # per-client or secret, and every OIDC client re-fetches it constantly
  # (Auth.js issues one request per `signIn` plus two more per callback,
  # with no cache of its own). Declaring it publicly cacheable lets a shared
  # cache absorb that traffic instead of every login paying a round trip to
  # the origin.
  #
  # Deliberately NOT applied to /.well-known/jwks.json. Relying parties
  # cache the JWKS on their own clock — the v1 integration contract caps
  # that at 10 minutes — and `rotation_prepublish_seconds` (630 s) budgets
  # for exactly that one cache before a pre-published key starts signing.
  # An intermediary cache would stack on top of the RP's rather than share
  # its window, pushing worst-case staleness past the pre-publish wait and
  # breaking the rotation timing property that tla/oauth_idp_key_rotation/
  # machine-checks. Caching the JWKS means widening that budget first — a
  # change to the contract and the model, not a header tweak here.
  @discovery_cache_control "public, max-age=600"

  @spec discovery(Plug.Conn.t()) :: Plug.Conn.t()
  def discovery(conn) do
    issuer = issuer!()

    conn
    |> put_resp_header("cache-control", @discovery_cache_control)
    |> send_json(200, %{
      issuer: issuer,
      authorization_endpoint: issuer <> "/oauth2/authorize",
      token_endpoint: issuer <> "/oauth2/token",
      userinfo_endpoint: issuer <> "/oauth2/userinfo",
      jwks_uri: issuer <> "/.well-known/jwks.json",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code"],
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["RS256"],
      scopes_supported: ["openid", "email", "profile"],
      token_endpoint_auth_methods_supported: [
        "client_secret_basic",
        "client_secret_post",
        "none"
      ],
      code_challenge_methods_supported: ["S256"],
      claims_supported: ["sub", "email", "email_verified", "name"]
    })
  end

  ## JWKS

  @spec jwks(Plug.Conn.t()) :: Plug.Conn.t()
  def jwks(conn) do
    Boruta.Openid.jwks(conn, __MODULE__)
  end

  @doc false
  def jwk_list(conn, _client_jwks) do
    # Decision D3: the provider publishes its own signing-key set, never
    # the per-client keys Boruta would list (which would leak how many
    # clients are registered).
    keys =
      Enum.map(Comma.OauthIdp.public_jwks!(), fn jwk ->
        {_meta, map} = JOSE.JWK.to_map(jwk)
        map
      end)

    send_json(conn, 200, %{keys: keys})
  end

  ## Token

  @spec token(Plug.Conn.t()) :: Plug.Conn.t()
  def token(conn) do
    Boruta.Oauth.token(conn, __MODULE__)
  end

  @doc false
  def token_success(conn, %TokenResponse{} = response) do
    body =
      %{
        token_type: response.token_type,
        access_token: response.access_token,
        expires_in: response.expires_in,
        id_token: response.id_token,
        scope: scope_or_nil(response)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    emit_issuance(response)

    # RFC 6749 §5.1: responses carrying tokens require both headers.
    # cache-control: no-store is already forced for /oauth2/* by the
    # router's auth_response_policy.
    conn
    |> put_resp_header("pragma", "no-cache")
    |> send_json(200, body)
  end

  # Issuance is counted as one aggregate metric; per-client detail goes
  # to the structured log line instead (the observability GUIDE forbids
  # ID-valued metric labels, and a per-client label would mint a new
  # Prometheus series per registration once self-serve opens). The log
  # carries client_id and nothing about the user or tokens.
  defp emit_issuance(%TokenResponse{token: %{client: %{id: client_id}}})
       when is_binary(client_id) do
    :telemetry.execute([:comma_product, :oauth_idp, :issuance], %{count: 1}, %{})
    Logger.info("oauth_idp token issued", oauth_idp_client_id: client_id)
  end

  defp emit_issuance(_response), do: :ok

  @doc false
  def token_error(conn, %Error{} = error) do
    send_oauth_error(conn, error)
  end

  ## Userinfo

  @spec userinfo(Plug.Conn.t()) :: Plug.Conn.t()
  def userinfo(conn) do
    Boruta.Openid.userinfo(conn, __MODULE__)
  end

  @doc false
  def userinfo_fetched(conn, %UserinfoResponse{format: :json} = response) do
    send_json(conn, 200, UserinfoResponse.payload(response))
  end

  @doc false
  def unauthorized(conn, %Error{} = error) do
    error_code = bearer_error_code(error.error)

    conn
    |> put_resp_header(
      "www-authenticate",
      ~s(Bearer error="#{error_code}", error_description="#{error.error_description}")
    )
    |> send_json(401, %{error: error_code})
  end

  # RFC 6750 §3.1 defines the bearer error registry; Boruta's internal
  # atoms are not wire values and must be mapped at this boundary.
  defp bearer_error_code(:invalid_access_token), do: "invalid_token"
  defp bearer_error_code(:invalid_request), do: "invalid_request"
  defp bearer_error_code(:insufficient_scope), do: "insufficient_scope"
  defp bearer_error_code(_other), do: "invalid_token"

  ## Shared plumbing

  defp issuer! do
    # Single source of truth: the same issuer Boruta stamps into id_tokens.
    case Boruta.Config.issuer() do
      issuer when is_binary(issuer) and issuer != "" and issuer != "boruta" ->
        issuer

      _missing_or_default ->
        raise "config :boruta, Boruta.Oauth, issuer: must be set to the public API origin"
    end
  end

  defp scope_or_nil(%TokenResponse{token: %{scope: scope}}) when is_binary(scope), do: scope
  defp scope_or_nil(_response), do: nil

  defp send_oauth_error(conn, %Error{} = error) do
    status = Plug.Conn.Status.code(error.status)

    send_json(conn, status, %{
      error: to_string(error.error),
      error_description: error.error_description
    })
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
