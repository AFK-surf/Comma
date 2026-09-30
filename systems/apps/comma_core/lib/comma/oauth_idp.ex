defmodule Comma.OauthIdp do
  @moduledoc """
  Shared primitives for the Comma OAuth/OIDC identity provider
  (docs/identity-security.md).

  Owns the two provider-level facts the adapters share:

    * the global id_token signing-key set (decision D3, revised
      2026-08-25): key pairs live in the shared
      `comma_oauth_signing_keys` table — exactly one `signing` row, at
      most one `pending` row (pre-published, not yet signing), and
      `verify_only` rows inside their verification window — with the
      private half encrypted at rest under the deployment KEK. See
      `Comma.OauthIdp.SigningKeys` for the timed two-step rotation
      protocol and why its waits are enforced by data;
    * the at-rest hashing scheme for opaque credentials (decision D4).
  """

  alias Comma.OauthIdp.SigningKeys

  @hash_prefix "sha256:"

  @doc """
  Returns the active signer as `{pem, kid}`. Raises when no signing key
  is provisioned or the KEK is missing — a misconfigured deployment
  fails closed rather than degrading into "client not found" errors
  downstream. The key is provider infrastructure, not client data: it
  is injected into every `Boruta.Oauth.Client` by `Comma.OauthIdp.Clients`
  at read time.
  """
  @spec signing_key!() :: {pem :: String.t(), kid :: String.t()}
  defdelegate signing_key!, to: SigningKeys

  @doc """
  Returns the JWKS entries for the provider: every key's public half,
  the signing key first. All pods read the same table, so every pod
  publishes an identical set at every instant.
  """
  @spec public_jwks!() :: [%JOSE.JWK{}]
  defdelegate public_jwks!, to: SigningKeys

  @doc """
  Hashes an opaque credential (access token or authorization code) for
  storage. The prefix makes hashed values self-describing in the
  database and impossible to confuse with a plaintext credential.
  """
  @spec hash_token(String.t()) :: String.t()
  def hash_token(value) when is_binary(value) do
    @hash_prefix <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)
  end

  @doc "True when a stored value is already in the hashed-at-rest form."
  @spec hashed?(String.t()) :: boolean()
  def hashed?(@hash_prefix <> _rest), do: true
  def hashed?(_value), do: false
end
