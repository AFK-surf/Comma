defmodule SalixStore.OAuth.Adapter do
  @moduledoc """
  Behaviour for managed OAuth provider adapters (contract C1). Port of willow's
  `internal/oauth/types.go` (the `Adapter` interface, `AuthorizationRequest`,
  `AuthState`, `TenantApp`, `OAuthTokenSet` / `OAuthAccountMetadata` shapes,
  `splitScopes`, and the resolver's `isInvalidGrant` classifier from
  `internal/oauth/resolver.go`).

  All maps are string-keyed.

    * `app`    — `%{"client_id" => _, "client_secret" => _}` (willow `TenantApp`)
    * `req`    — `%{"redirect_uri" => _, "state" => _, "scopes" => [..],
      "code_challenge" => s256_b64url_or_nil}` (willow `AuthorizationRequest`)
    * `ctx`    — `%{"redirect_uri" => _, "code_verifier" => _ | nil,
      "scopes" => [..]}` (willow `AuthState` minus client credentials, which
      arrive via `app`)
    * `tokens` — `%{"access_token", "refresh_token" | nil, "expires_at" ms | nil,
      "refresh_expires_at" ms | nil, "scopes", "token_type", + provider extras
      such as "slack_user_token"}` (willow `control.OAuthTokenSet`)
    * `account` — `%{"provider_account_id", "provider_account_name",
      "metadata" => map}` (willow `control.OAuthAccountMetadata`)
    * `conn`   — a stored connection record; adapters read
      `"access_token"` / `"refresh_token"` / `"token_type"` / `"scopes"` plus
      provider extras from it (willow `control.OAuthConnection` token fields)

  Every endpoint URL resolves through
  `Application.get_env(:salix_store, :oauth_endpoint_overrides, %{})` —
  `%{provider => %{"authorize_url" | "token_url" | "revoke_url" | "api_url" => url}}`
  — falling back to the real provider endpoints. This is the test seam.

  Intentional divergences from willow:

    * Expiry timestamps are absolute **milliseconds** (`System.system_time(:millisecond)`
      at exchange/refresh time + `expires_in * 1000`); willow stores Unix seconds.
    * The authorization request carries a precomputed S256 `code_challenge`
      (base64url) instead of the raw verifier; willow's adapters compute the
      challenge from `req.CodeVerifier` themselves (`CodeChallengeS256`).
    * `refresh/2` classifies provider `invalid_grant` / `invalid grant` /
      `expired_token` failures itself and returns
      `{:error, :reauthorization_required}`; in willow this classification lives
      in the resolver (`isInvalidGrant` in `internal/oauth/resolver.go`), not in
      the adapters.
    * Missing string fields are `nil` rather than Go's `""` (e.g.
      `"refresh_token" => nil` for classic GitHub OAuth apps).
    * Providers without a revocation endpoint (GitHub, Notion) return
      `{:error, :revocation_not_supported}` from `revoke/2`; willow returns the
      sentinel `ErrNoOpToken` that the binding layer treats as best-effort.
    * `default_env_var/0` is a new callback; willow keeps the equivalent map in
      `internal/tools/listoauth.go` (`GH_TOKEN`, `GOOGLE_ACCESS_TOKEN`,
      `LINEAR_ACCESS_TOKEN`, `NOTION_TOKEN`, `SLACK_USER_TOKEN`).
    * Account metadata is nested under `"metadata"` (mirrors willow's
      `OAuthAccountMetadata.Metadata` field) rather than flattened.

  This module also hosts the shared HTTP / parsing helpers the adapters use
  (willow's `postTokenForm` / `splitScopes` / `defaultHTTPClient` family).
  """

  @type app :: %{optional(String.t()) => any()}
  @type tokens :: %{optional(String.t()) => any()}
  @type account :: %{optional(String.t()) => any()}
  @type conn :: %{optional(String.t()) => any()}

  @callback authorization_url(app :: map, req :: map) :: {:ok, String.t()} | {:error, term}
  @callback exchange_code(app :: map, ctx :: map, code :: String.t()) ::
              {:ok, %{required(String.t()) => map}} | {:error, term}
  @callback refresh(app :: map, conn :: map) ::
              {:ok, tokens} | {:error, :reauthorization_required} | {:error, term}
  @callback revoke(app :: map, conn :: map) :: :ok | {:error, term}
  @callback resolve_credential_value(conn :: map, value :: String.t()) ::
              {:ok, String.t()} | {:error, term}
  @callback validate_credential_value(value :: String.t(), scopes :: [String.t()]) ::
              :ok | {:error, term}
  @callback default_env_var() :: String.t()

  # Credential value names a model can request (willow `CredentialAccessToken`).
  @credential_access_token "access_token"

  @doc "The only supported credential value name (willow `oauth.CredentialAccessToken`)."
  def credential_access_token, do: @credential_access_token

  # ---- endpoint override seam ----

  @doc """
  Resolve an endpoint URL for `provider`/`key` ("authorize_url" | "token_url" |
  "revoke_url" | "api_url"), consulting `:oauth_endpoint_overrides` first.
  """
  def endpoint(provider, key, default) do
    # nil-tolerant: a test restoring the seam with put_env(key, nil) stores a
    # literal nil, which get_env returns INSTEAD of the default.
    overrides = Application.get_env(:salix_store, :oauth_endpoint_overrides) || %{}

    overrides
    |> Map.get(provider, %{})
    |> Map.get(key, default)
  end

  # ---- query encoding ----

  @doc """
  Encode query params sorted by key, application/x-www-form-urlencoded style.
  Matches Go's `url.Values.Encode()` (sorted keys, `+` for spaces) so the
  authorization URLs are byte-identical to willow's.
  """
  def encode_query(pairs) do
    pairs
    |> Enum.sort_by(fn {k, _} -> k end)
    |> URI.encode_query()
  end

  # ---- HTTP helpers (willow postTokenForm / loadAccountMetadata plumbing) ----

  @doc """
  POST a form body, expecting a JSON response. Returns `{:ok, status, map}` or
  `{:error, message}`. `label` mirrors willow's error prefixes, e.g.
  `"github token"` → `"github token request: ..."` /
  `"decode github token response: ..."`.
  """
  def post_form(url, form, label, opts \\ []) do
    req_opts =
      [form: form, headers: [{"accept", "application/json"}]] ++ Keyword.take(opts, [:auth])

    url |> Req.post(req_opts) |> handle_response(label)
  end

  @doc "POST a JSON body, expecting a JSON response. Same return shape as `post_form/4`."
  def post_json(url, body, label, opts \\ []) do
    req_opts =
      [json: body, headers: [{"accept", "application/json"}] ++ Keyword.get(opts, :headers, [])] ++
        Keyword.take(opts, [:auth])

    url |> Req.post(req_opts) |> handle_response(label)
  end

  @doc """
  POST a form body where only the response status matters (revocation
  endpoints — willow ignores the body there). Returns `{:ok, status}` or
  `{:error, message}`.
  """
  def post_form_status(url, form, label, opts \\ []) do
    req_opts = [form: form, decode_body: false] ++ Keyword.take(opts, [:auth])

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: status}} -> {:ok, status}
      {:error, err} -> {:error, "#{label} request: #{Exception.message(err)}"}
    end
  end

  @doc """
  GET a JSON resource with a bearer token. Same return shape as `post_form/4`.
  `:accept` overrides the Accept header (GitHub's `application/vnd.github+json`).
  """
  def get_json(url, bearer_token, label, opts \\ []) do
    headers = [
      {"accept", Keyword.get(opts, :accept, "application/json")},
      {"authorization", "Bearer " <> bearer_token}
    ]

    url |> Req.get(headers: headers) |> handle_response(label)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, label) do
    case decode_body(body) do
      {:ok, map} -> {:ok, status, map}
      :error -> {:error, "decode #{label} response: invalid JSON"}
    end
  end

  defp handle_response({:error, err}, label) do
    {:error, "#{label} request: #{Exception.message(err)}"}
  end

  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp decode_body(_), do: :error

  # ---- token / scope helpers ----

  @doc """
  Split a scope string on `sep`, trimming parts and dropping blanks (willow
  `splitScopes`). Returns `[]` for nil/blank input (willow returns nil).
  """
  def split_scopes(nil, _sep), do: []

  def split_scopes(s, sep) when is_binary(s) do
    s
    |> String.split(sep)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def split_scopes(_, _sep), do: []

  @doc "Absolute ms expiry from a relative `expires_in` (seconds); nil unless > 0."
  def expires_at_ms(expires_in, now_ms \\ nil)

  def expires_at_ms(expires_in, now_ms) when is_number(expires_in) and expires_in > 0 do
    (now_ms || System.system_time(:millisecond)) + trunc(expires_in) * 1000
  end

  def expires_at_ms(_, _), do: nil

  @doc "Trimmed string, with nil/non-binary collapsing to \"\"."
  def trim(s) when is_binary(s), do: String.trim(s)
  def trim(_), do: ""

  @doc "True when the value trims to the empty string."
  def blank?(s), do: trim(s) == ""

  @doc """
  Classify a refresh failure: willow resolver's `isInvalidGrant` — substring
  match on `invalid_grant` / `invalid grant` / `expired_token` (case-insensitive)
  — maps to `{:error, :reauthorization_required}`; everything else passes
  through as `{:error, message}`.
  """
  def refresh_error(msg) when is_binary(msg) do
    lower = String.downcase(msg)

    if String.contains?(lower, "invalid_grant") or String.contains?(lower, "invalid grant") or
         String.contains?(lower, "expired_token") do
      {:error, :reauthorization_required}
    else
      {:error, msg}
    end
  end

  def refresh_error(other), do: {:error, other}

  @doc """
  Pass-through token set for connections without a refresh token (willow's
  GitHub/Notion/Slack "nothing to refresh" branches): existing access token,
  no refresh token, no expiry.
  """
  def passthrough_tokens(conn) do
    %{
      "access_token" => conn["access_token"],
      "refresh_token" => nil,
      "expires_at" => nil,
      "refresh_expires_at" => nil,
      "token_type" => conn["token_type"],
      "scopes" => conn["scopes"] || []
    }
  end

  @doc """
  Shared `resolve_credential_value` for providers whose only credential is the
  stored access token (willow's per-adapter ResolveCredentialValue bodies).
  """
  def resolve_access_token(conn, value, provider_label) do
    cond do
      not is_map(conn) ->
        {:error, "#{provider_label}: connection is nil"}

      value != @credential_access_token ->
        {:error, "#{provider_label}: unsupported credential value #{inspect(value)}"}

      true ->
        {:ok, conn["access_token"]}
    end
  end

  @doc "Shared `validate_credential_value`: only `\"access_token\"` is supported."
  def validate_access_token(value, _scopes, provider_label) do
    if value == @credential_access_token do
      :ok
    else
      {:error, "#{provider_label}: unsupported credential value #{inspect(value)}"}
    end
  end
end
