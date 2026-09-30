defmodule BridgeForTeams.Auth.OIDC do
  @moduledoc """
  OIDC provider behaviour (design §7): discovery, token exchange, and id_token
  verification against an org's IdP. A real HTTP impl
  (`BridgeForTeams.Auth.OIDC.HTTP`, using `:req` + `:jose`) and an in-memory
  `BridgeForTeams.Auth.OIDC.Fake` (tests, no network) are swapped via app env
  `{:bridge_for_teams_core, :oidc_provider}`. Same seam pattern as the Salix client.
  """

  @typedoc "An org's resolved SSO connection config (issuer, client id/secret, ...)."
  @type sso :: map()
  @type claims :: map()

  @doc "Fetch/cache the IdP discovery document + JWKS for an issuer."
  @callback discover(issuer :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc "Build the authorization-code + PKCE redirect URL."
  @callback authorize_url(sso(), opts :: keyword()) ::
              {:ok, %{url: String.t(), state: String.t(), code_verifier: String.t()}}
              | {:error, term()}

  @doc "Exchange an authorization code (+ PKCE verifier) for the token response."
  @callback exchange_code(
              sso(),
              code :: String.t(),
              code_verifier :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, map()} | {:error, term()}

  @doc "Verify an id_token against the issuer's JWKS and return the verified claims."
  @callback verify_id_token(sso(), id_token :: String.t()) :: {:ok, claims()} | {:error, term()}

  @doc "The configured OIDC provider (`{:bridge_for_teams_core, :oidc_provider}`)."
  @spec impl() :: module()
  def impl,
    do: Application.get_env(:bridge_for_teams_core, :oidc_provider, BridgeForTeams.Auth.OIDC.HTTP)
end
