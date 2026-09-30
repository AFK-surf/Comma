defmodule Comma.OauthIdp.Scopes do
  @moduledoc """
  The v1 scope set, owned by code rather than by table rows.

  `docs/identity-security.md` §2.1 fixes v1 to exactly `openid email
  profile` for every client; there is no per-client scope
  configuration and no product surface that grants anything else.

  Boruta's stock context reads grantable scopes from `oauth_scopes`,
  which made that fixed contract depend on someone having inserted
  three rows in every environment. The discovery document advertises
  the set from code, so an unseeded environment published three scopes
  and then rejected two of them with `invalid_scope` — exactly what the
  staging canary hit. Serving the same list the discovery document
  advertises makes that mismatch unrepresentable instead of merely
  detectable, and removes a provisioning step that could be forgotten
  in production.

  Widening the set is a product decision (RFC §10 lists API scopes as a
  non-goal), so it belongs in this list and in the discovery document
  together — `CommaWeb.OauthIdpEndpointsTest` asserts the two agree.
  """

  @behaviour Boruta.Oauth.Scopes

  alias Boruta.Oauth.Scope

  # `openid` is granted by Boruta itself on every OIDC request; it is
  # listed here so this module states the whole advertised contract.
  @v1_scopes ~w(openid email profile)

  @doc "The scopes v1 grants, in discovery-document order."
  @spec v1_scopes() :: [String.t()]
  def v1_scopes, do: @v1_scopes

  @impl Boruta.Oauth.Scopes
  def public do
    Enum.map(@v1_scopes, &%Scope{name: &1, public: true})
  end
end
