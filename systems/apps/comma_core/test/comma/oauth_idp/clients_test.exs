defmodule Comma.OauthIdp.ClientsTest do
  @moduledoc """
  Decision D3: one global signing key, injected at read time; the JWKS
  publishes provider keys only and never enumerates clients.
  """

  use ExUnit.Case, async: false

  alias Boruta.Ecto.Admin
  alias Comma.OauthIdp
  alias Comma.OauthIdpTestKeys

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Comma.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, {:shared, self()})
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

  test "get_client returns nil for an unknown client" do
    OauthIdpTestKeys.install()
    assert Comma.OauthIdp.Clients.get_client(Ecto.UUID.generate()) == nil
  end

  test "the JWKS lists exactly the provider keys, regardless of client count" do
    kid = OauthIdpTestKeys.install()
    for n <- 1..3, do: create_client!("jwks-client-#{n}")

    jwks = Comma.OauthIdp.Clients.list_clients_jwk()

    assert [%JOSE.JWK{} = jwk] = jwks
    assert jwk.fields["kid"] == kid

    # Public key material only.
    {_meta, map} = JOSE.JWK.to_map(jwk)
    refute Map.has_key?(map, "d")
    assert map["kty"] == "RSA"
  end

  test "a missing signing key fails closed with a clear raise" do
    previous = Application.get_env(:comma_core, :oauth_idp)
    Application.delete_env(:comma_core, :oauth_idp)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:comma_core, :oauth_idp)
        config -> Application.put_env(:comma_core, :oauth_idp, config)
      end
    end)

    client = create_client!("no-key")

    assert_raise RuntimeError, ~r/has no signing key/, fn ->
      Comma.OauthIdp.Clients.get_client(client.id)
    end

    assert_raise RuntimeError, ~r/has no signing key/, fn ->
      Comma.OauthIdp.Clients.list_clients_jwk()
    end

    assert_raise RuntimeError, ~r/has no signing key/, fn ->
      OauthIdp.signing_key!()
    end
  end
end
