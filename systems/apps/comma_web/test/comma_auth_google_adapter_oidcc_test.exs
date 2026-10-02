defmodule Comma.Auth.GoogleAdapter.OidccIntegrationTest do
  use ExUnit.Case, async: false

  alias Comma.Auth.GoogleAdapter.Oidcc, as: GoogleAdapter
  alias Comma.Auth.GoogleAdapter.Oidcc.JwksRefreshGate
  alias Oidcc.ProviderConfiguration.Worker

  @client_id "comma-web.apps.googleusercontent.com"
  @client_secret "comma-desktop-client-secret"
  @nonce "login-attempt-nonce"
  @provider Comma.Auth.GoogleAdapter.Oidcc.Provider

  defmodule MockProvider do
    @behaviour Plug

    @desktop_client_id "comma-web.apps.googleusercontent.com"
    @desktop_client_secret "comma-desktop-client-secret"

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, state: state) do
      case {conn.method, conn.request_path} do
        {"GET", "/.well-known/openid-configuration"} ->
          issuer = Agent.get(state, & &1.issuer)

          json(conn, %{
            "issuer" => issuer,
            "authorization_endpoint" => issuer <> "/authorize",
            "token_endpoint" => issuer <> "/token",
            "jwks_uri" => issuer <> "/jwks",
            "scopes_supported" => ["openid", "email", "profile"],
            "response_types_supported" => ["code", "id_token"],
            "grant_types_supported" => ["authorization_code"],
            "code_challenge_methods_supported" => ["S256"],
            "token_endpoint_auth_methods_supported" => ["client_secret_post"],
            "subject_types_supported" => ["public"],
            "id_token_signing_alg_values_supported" => ["RS256"]
          })

        {"GET", "/jwks"} ->
          keys =
            Agent.get_and_update(state, fn state ->
              {state.keys, %{state | jwks_requests: state.jwks_requests + 1}}
            end)

          json(conn, %{"keys" => keys})

        {"POST", "/token"} ->
          {:ok, body, conn} = read_body(conn)
          params = URI.decode_query(body)
          snapshot = Agent.get(state, & &1)
          send(snapshot.test_pid, {:google_token_request, params})

          if params["client_id"] == @desktop_client_id and
               params["client_secret"] == @desktop_client_secret and
               params["code"] == "desktop-authorization-code" and
               params["code_verifier"] == "desktop-pkce-verifier-0123456789012345678901" and
               params["redirect_uri"] == "http://127.0.0.1:43123/oauth2/callback" do
            json(conn, %{
              "access_token" => "unused-access-token",
              "expires_in" => 300,
              "id_token" => snapshot.id_token,
              "token_type" => "Bearer"
            })
          else
            conn
            |> put_status(401)
            |> json(%{"error" => "invalid_client"})
          end

        _other ->
          send_resp(conn, 404, "not found")
      end
    end

    defp json(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "max-age=3600")
      |> send_resp(conn.status || 200, Jason.encode!(body))
    end
  end

  setup do
    if :ets.whereis(Bandit.Clock) == :undefined do
      start_supervised!(Bandit.Clock)
    end

    {signing_key, public_key} = rsa_keypair("initial-kid")
    test_pid = self()

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             clock_ms: 0,
             id_token: nil,
             issuer: nil,
             keys: [public_key],
             jwks_requests: 0,
             test_pid: test_pid
           }
         end}
      )

    bandit =
      start_supervised!(
        {Bandit,
         plug: {MockProvider, state: state},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    issuer = "http://127.0.0.1:#{port}"
    id_token = token(signing_key, "initial-kid", claims(issuer))
    Agent.update(state, &%{&1 | id_token: id_token, issuer: issuer})

    start_supervised!(
      {Worker,
       %{
         issuer: issuer,
         name: @provider,
         provider_configuration_opts: %{fallback_expiry: :timer.hours(1)}
       }}
    )

    start_supervised!(
      {JwksRefreshGate, cooldown_ms: 1_000, clock: fn -> Agent.get(state, & &1.clock_ms) end}
    )

    assert %JOSE.JWK{} = Worker.get_jwks(@provider)

    {:ok, issuer: issuer, signing_key: signing_key, state: state}
  end

  test "accepts a valid Google ID token", context do
    token = token(context.signing_key, "initial-kid", claims(context.issuer))

    assert {:ok, verified_claims} = verify(token)
    assert verified_claims["sub"] == "google-user-1"
    assert verified_claims["email"] == "user@example.test"
  end

  test "accepts an Android Credential Manager token only from an authorized party", context do
    android_client_id = "comma-android.apps.googleusercontent.com"

    android_token =
      token(
        context.signing_key,
        "initial-kid",
        claims(context.issuer, %{"azp" => android_client_id})
      )

    assert {:error, :invalid_google_credential} = verify(android_token)

    assert {:ok, verified_claims} =
             GoogleAdapter.verify_id_token(android_token,
               authorized_parties: [android_client_id],
               client_id: @client_id,
               nonce: @nonce
             )

    assert verified_claims["azp"] == android_client_id

    assert {:error, :invalid_google_credential} =
             GoogleAdapter.verify_id_token(android_token,
               authorized_parties: ["another-android.apps.googleusercontent.com"],
               client_id: @client_id,
               nonce: @nonce
             )
  end

  test "exchanges the desktop code with client_secret_post and validates PKCE and nonce" do
    assert {:ok, claims} =
             GoogleAdapter.exchange_authorization_code("desktop-authorization-code",
               client_id: @client_id,
               client_secret: @client_secret,
               nonce: @nonce,
               pkce_verifier: "desktop-pkce-verifier-0123456789012345678901",
               redirect_uri: "http://127.0.0.1:43123/oauth2/callback"
             )

    assert claims["sub"] == "google-user-1"

    assert_receive {:google_token_request, params}
    assert params["client_id"] == @client_id
    assert params["client_secret"] == @client_secret
    assert params["code_verifier"] == "desktop-pkce-verifier-0123456789012345678901"
  end

  test "classifies a rejected desktop client credential as provider unavailable" do
    assert {:error, :google_provider_unavailable} =
             GoogleAdapter.exchange_authorization_code("desktop-authorization-code",
               client_id: @client_id,
               client_secret: "wrong-secret",
               nonce: @nonce,
               pkce_verifier: "desktop-pkce-verifier-0123456789012345678901",
               redirect_uri: "http://127.0.0.1:43123/oauth2/callback"
             )
  end

  test "rejects an ID token with a bad signature", context do
    {attacker_key, _public_key} = rsa_keypair("attacker-kid")
    forged = token(attacker_key, "initial-kid", claims(context.issuer))

    assert {:error, :invalid_google_credential} = verify(forged)
  end

  # `{:now_offset, seconds}` resolves against the clock when the token is minted.
  for {label, overrides} <- [
        {"that has expired", %{"exp" => {:now_offset, -3_600}}},
        {"for another audience", %{"aud" => "another-client", "azp" => "another-client"}},
        {"from another issuer", %{"iss" => "https://attacker.example"}},
        {"with the wrong nonce", %{"nonce" => "another-login-attempt"}}
      ] do
    @overrides overrides
    test "rejects an ID token #{label}", context do
      overrides =
        Map.new(@overrides, fn
          {key, {:now_offset, seconds}} -> {key, System.system_time(:second) + seconds}
          pair -> pair
        end)

      rejected = token(context.signing_key, "initial-kid", claims(context.issuer, overrides))

      assert {:error, :invalid_google_credential} = verify(rejected)
    end
  end

  test "refreshes JWKS once and accepts a token with a newly published kid", context do
    {rotated_key, rotated_public_key} = rsa_keypair("rotated-kid")
    requests_before = Agent.get(context.state, & &1.jwks_requests)

    Agent.update(context.state, fn state ->
      %{state | keys: state.keys ++ [rotated_public_key]}
    end)

    rotated_token = token(rotated_key, "rotated-kid", claims(context.issuer))

    assert {:ok, %{"sub" => "google-user-1"}} = verify(rotated_token)
    assert Agent.get(context.state, & &1.jwks_requests) == requests_before + 1
  end

  test "singleflights refresh and applies one global cooldown to attacker-controlled kids",
       context do
    requests_before = Agent.get(context.state, & &1.jwks_requests)
    {rotated_key, rotated_public_key} = rsa_keypair("singleflight-rotated-kid")

    Agent.update(context.state, fn state ->
      %{state | keys: state.keys ++ [rotated_public_key]}
    end)

    rotated_token = token(rotated_key, "singleflight-rotated-kid", claims(context.issuer))

    rotated_results =
      1..8
      |> Enum.map(fn _index -> Task.async(fn -> verify(rotated_token) end) end)
      |> Task.await_many(10_000)

    assert Enum.all?(rotated_results, &match?({:ok, %{"sub" => "google-user-1"}}, &1))
    assert Agent.get(context.state, & &1.jwks_requests) == requests_before + 1

    {attacker_key, _attacker_public_key} = rsa_keypair("ignored-attacker-kid")

    first_unknown = token(attacker_key, "random-kid-before-cooldown", claims(context.issuer))
    assert {:error, :invalid_google_credential} = verify(first_unknown)
    assert Agent.get(context.state, & &1.jwks_requests) == requests_before + 1

    Agent.update(context.state, &%{&1 | clock_ms: &1.clock_ms + 1_000})

    random_results =
      1..8
      |> Enum.map(fn index ->
        random_token = token(attacker_key, "random-kid-#{index}", claims(context.issuer))
        Task.async(fn -> verify(random_token) end)
      end)
      |> Task.await_many(10_000)

    assert Enum.all?(random_results, &match?({:error, :invalid_google_credential}, &1))
    assert Agent.get(context.state, & &1.jwks_requests) == requests_before + 2

    last_unknown = token(attacker_key, "random-kid-after-burst", claims(context.issuer))
    assert {:error, :invalid_google_credential} = verify(last_unknown)
    assert Agent.get(context.state, & &1.jwks_requests) == requests_before + 2
  end

  defp verify(token) do
    GoogleAdapter.verify_id_token(token, client_id: @client_id, nonce: @nonce)
  end

  defp claims(issuer, overrides \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => issuer,
        "sub" => "google-user-1",
        "aud" => @client_id,
        "azp" => @client_id,
        "exp" => now + 300,
        "iat" => now,
        "nonce" => @nonce,
        "email" => "user@example.test"
      },
      overrides
    )
  end

  defp rsa_keypair(kid) do
    private_key = JOSE.JWK.generate_key({:rsa, 2_048})
    {_, public_key} = private_key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    public_key =
      Map.merge(public_key, %{"alg" => "RS256", "kid" => kid, "use" => "sig"})

    {private_key, public_key}
  end

  defp token(private_key, kid, claims) do
    protected = %{"alg" => "RS256", "kid" => kid, "typ" => "JWT"}
    {_, compact} = private_key |> JOSE.JWT.sign(protected, claims) |> JOSE.JWS.compact()
    compact
  end
end
