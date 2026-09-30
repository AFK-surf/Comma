defmodule BridgeForTeams.Auth.OIDC.HTTPTest do
  @moduledoc """
  Exercises the real OIDC HTTP impl's pure surfaces: PKCE/state generation in
  `authorize_url/2` and JWKS-based `verify_id_token/2`. Discovery/JWKS are served
  from `BridgeForTeams.Cache` (seeded directly) so no network is hit; the id_token
  is minted locally with a generated RSA key whose public half is the JWKS.
  """
  use ExUnit.Case, async: false

  alias BridgeForTeams.Auth.OIDC.HTTP
  alias BridgeForTeams.Cache

  @issuer "https://idp.example.test"
  @client_id "client-abc"

  setup do
    # The Cache GenServer is started by BridgeForTeams.Application; ensure it's up.
    case Process.whereis(Cache) do
      nil -> start_supervised!(Cache)
      _ -> :ok
    end

    Cache.delete({:oidc_discovery, @issuer})
    Cache.delete({:oidc_jwks, @issuer})
    :ok
  end

  defp seed_discovery do
    Cache.put({:oidc_discovery, @issuer}, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @issuer <> "/authorize",
      "token_endpoint" => @issuer <> "/token",
      "jwks_uri" => @issuer <> "/jwks"
    })
  end

  defp rsa_keypair do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, pub_map} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    {jwk, Map.put(pub_map, "kid", "test-kid")}
  end

  defp sign(jwk, claims) do
    jws = %{"alg" => "RS256", "kid" => "test-kid"}
    {_, compact} = JOSE.JWT.sign(jwk, jws, claims) |> JOSE.JWS.compact()
    compact
  end

  test "authorize_url builds an auth-code + PKCE request with state and verifier" do
    seed_discovery()

    sso = %{issuer: @issuer, client_id: @client_id, redirect_uri: "https://app.test/cb"}
    assert {:ok, %{url: url, state: state, code_verifier: verifier}} = HTTP.authorize_url(sso, [])

    assert String.starts_with?(url, @issuer <> "/authorize?")
    assert String.contains?(url, "response_type=code")
    assert String.contains?(url, "code_challenge_method=S256")
    assert String.contains?(url, "client_id=" <> @client_id)
    assert String.contains?(url, "state=" <> state)
    # Verifier is high-entropy and not embedded in the URL (only the challenge is).
    assert byte_size(verifier) >= 43
    refute String.contains?(url, verifier)
  end

  test "verify_id_token accepts a correctly-signed token and returns claims" do
    seed_discovery()
    {jwk, pub} = rsa_keypair()
    Cache.put({:oidc_jwks, @issuer}, [pub])

    now = System.system_time(:second)

    id_token =
      sign(jwk, %{
        "iss" => @issuer,
        "aud" => @client_id,
        "sub" => "user-1",
        "email" => "a@example.test",
        "exp" => now + 3600
      })

    sso = %{issuer: @issuer, client_id: @client_id}
    assert {:ok, claims} = HTTP.verify_id_token(sso, id_token)
    assert claims["email"] == "a@example.test"
    assert claims["sub"] == "user-1"
  end

  test "verify_id_token rejects a token signed by a different key" do
    seed_discovery()
    {_jwk, pub} = rsa_keypair()
    Cache.put({:oidc_jwks, @issuer}, [pub])

    {attacker, _} = rsa_keypair()
    now = System.system_time(:second)
    forged = sign(attacker, %{"iss" => @issuer, "aud" => @client_id, "exp" => now + 3600})

    sso = %{issuer: @issuer, client_id: @client_id}
    assert {:error, :signature_verification_failed} = HTTP.verify_id_token(sso, forged)
  end

  test "verify_id_token rejects issuer / audience / expiry mismatches" do
    seed_discovery()
    {jwk, pub} = rsa_keypair()
    Cache.put({:oidc_jwks, @issuer}, [pub])
    now = System.system_time(:second)
    sso = %{issuer: @issuer, client_id: @client_id}

    wrong_iss = sign(jwk, %{"iss" => "https://evil.test", "aud" => @client_id, "exp" => now + 60})
    assert {:error, :issuer_mismatch} = HTTP.verify_id_token(sso, wrong_iss)

    wrong_aud = sign(jwk, %{"iss" => @issuer, "aud" => "someone-else", "exp" => now + 60})
    assert {:error, :audience_mismatch} = HTTP.verify_id_token(sso, wrong_aud)

    expired = sign(jwk, %{"iss" => @issuer, "aud" => @client_id, "exp" => now - 3600})
    assert {:error, :token_expired} = HTTP.verify_id_token(sso, expired)
  end

  test "verify_id_token accepts an audience array containing the client_id" do
    seed_discovery()
    {jwk, pub} = rsa_keypair()
    Cache.put({:oidc_jwks, @issuer}, [pub])
    now = System.system_time(:second)

    tok =
      sign(jwk, %{
        "iss" => @issuer,
        "aud" => ["other", @client_id],
        "sub" => "u",
        "exp" => now + 60
      })

    assert {:ok, %{"sub" => "u"}} =
             HTTP.verify_id_token(%{issuer: @issuer, client_id: @client_id}, tok)
  end
end
