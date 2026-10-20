defmodule Comma.OauthIdp.ClientsTest do
  @moduledoc """
  Decision D3: one global signing key, injected at read time; the JWKS
  publishes provider keys only and never enumerates clients.
  """

  use SystemsClock.Case, async: false

  alias Boruta.Ecto.Admin
  alias Comma.OauthIdp
  alias Comma.OauthIdpTestKeys

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Comma.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, {:shared, SystemsRuntime.Proc.self()})
    :ok
  end

  defp create_client!(name) do
    {:ok, client} =
      Admin.create_client(%{
        name: name,
        redirect_uris: ["https://#{name}.example.com/callback"],
        supported_grant_types: ["authorization_code"],
        access_token_ttl: 600,
        authorization_code_ttl: 60,
        id_token_ttl: 600,
        id_token_signature_alg: "RS256",
        pkce: true
      })

    client
  end

  test "get_client swaps in the global key, kid, and RS256" do
    kid = OauthIdpTestKeys.install()
    {pem, ^kid} = Comma.OauthIdp.signing_key!()
    client = create_client!("swap-check")

    resolved = Comma.OauthIdp.Clients.get_client(client.id)

    assert resolved.private_key == pem
    assert resolved.id_token_kid == kid
    assert resolved.id_token_signature_alg == "RS256"

    # The per-client key Boruta generated at registration is not what
    # signing uses.
    refute resolved.private_key == client.private_key
  end
end
