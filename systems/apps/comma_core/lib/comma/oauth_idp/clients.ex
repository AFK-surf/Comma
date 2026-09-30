defmodule Comma.OauthIdp.Clients do
  @moduledoc """
  `Boruta.Oauth.Clients` backed by the database directly — no client
  cache — signing with one global provider key (decision D3 of
  docs/identity-security.md).

  ## Why resolution reads the database every time

  Boruta's stock context resolves through a TTL-less replicated cache.
  Two review rounds on PR #1059 showed that every ordering protocol for
  invalidating that cache around the audited lifecycle transaction
  leaves a window (concurrent repopulation before commit; process death
  between commit and a post-commit sweep, unrepairable by idempotent
  retry) in which a disabled client stays usable or a rotated secret
  stays valid — forever, because nothing expires the entry.

  The unified guarantee is to remove the second source of truth
  entirely: `get_client/1` reads the committed row. Disable, enable,
  and rotation are effective the instant their transaction commits, on
  every pod, with no invalidation protocol, no crash window, and no
  recovery machinery to model. The cost is one primary-key SELECT (plus
  the scope preload Boruta's mapper performs) per resolution on the
  authorize/token paths — negligible at v1's hand-picked client count,
  and revisitable with a bounded-TTL cache if scale ever demands it.

  Signing material is provider policy, not client data: the global key
  from `Comma.OauthIdp.signing_key!/0` is injected into every resolved
  struct, so no database private-key column is ever used for signing
  and the JWKS never enumerates registered clients. A missing signing
  key raises — a misconfigured deployment fails closed rather than
  degrading into `invalid_client` responses that hide the real fault.
  """

  @behaviour Boruta.Oauth.Clients

  alias Boruta.Ecto.Client, as: ClientRecord
  alias Boruta.Oauth
  alias Comma.OauthIdp

  @impl Boruta.Oauth.Clients
  def get_client(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %ClientRecord{} = record <- Comma.Repo.get(ClientRecord, uuid),
         false <- Comma.OauthIdp.ClientAdmin.disabled?(record) do
      record
      |> Boruta.Ecto.OauthMapper.to_oauth_schema()
      |> put_signing_material()
    else
      # Unknown, malformed, and disabled ids are indistinguishable:
      # Boruta reports invalid_client for all of them.
      _unknown_or_disabled -> nil
    end
  end

  @impl Boruta.Oauth.Clients
  def authorized_scopes(%Oauth.Client{} = client) do
    Boruta.Ecto.Clients.authorized_scopes(client)
  end

  @impl Boruta.Oauth.Clients
  def list_clients_jwk do
    OauthIdp.public_jwks!()
  end

  defp put_signing_material(client) do
    {pem, kid} = OauthIdp.signing_key!()

    %{
      client
      | private_key: pem,
        id_token_kid: kid,
        # An HS* alg would switch Boruta to signing with the client
        # secret, which D3 forbids.
        id_token_signature_alg: "RS256"
    }
  end
end
