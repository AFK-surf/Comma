defmodule CommaWeb.OauthIdpEndpointsTest do
  # async: false — the KEK and endpoint flag live in application config.
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]
  import Plug.Conn
  import Plug.Test

  alias Boruta.Ecto.Admin
  alias Boruta.Oauth.AuthorizeResponse
  alias Boruta.Oauth.ResourceOwner

  @opts CommaWeb.Router.init([])
  @redirect_uri "https://vibe.example.com/callback"

  defmodule AuthorizeCallbacks do
    @moduledoc false
    def authorize_success(_conn, response), do: {:authorize_success, response}
    def authorize_error(_conn, error), do: {:authorize_error, error}
  end

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)

    previous_kek = SystemsRuntime.get_env(:comma_core, :oauth_idp)

    SystemsRuntime.put_env(:comma_core, :oauth_idp,
      kek: :crypto.hash(:sha256, "idp-endpoint-kek")
    )

    previous_flag = SystemsRuntime.get_env(:comma_web, :oauth_idp_enabled)
    SystemsRuntime.put_env(:comma_web, :oauth_idp_enabled, true)

    # Generous default budgets so unrelated cases never trip the limiter;
    # the rate-limiting describe overrides them per test.
    previous_rate_limit = SystemsRuntime.get_env(:comma_core, :oauth_idp_rate_limit)

    SystemsRuntime.put_env(:comma_core, :oauth_idp_rate_limit,
      token: [burst: 10_000, rate: 1000.0],
      authorize: [burst: 10_000, rate: 1000.0]
    )

    on_exit(fn ->
      CommaWeb.TestRepoSandbox.stop_owner(owner)
      restore_env(:comma_core, :oauth_idp, previous_kek)
      restore_env(:comma_web, :oauth_idp_enabled, previous_flag)
      restore_env(:comma_core, :oauth_idp_rate_limit, previous_rate_limit)
    end)

    _kid = Comma.OauthIdp.SigningKeys.provision_initial!()

    {:ok, user} = Comma.Accounts.get_or_create_user_by_email("idp-endpoints@example.com")

    # No oauth_scopes rows are seeded on purpose: the v1 scope set is served
    # from code by Comma.OauthIdp.Scopes, and a fresh deployment has an empty
    # table. Seeding here is what hid the staging invalid_scope failure.

    {:ok, client} =
      Admin.create_client(%{
        name: "vibe-app",
        redirect_uris: [@redirect_uri],
        supported_grant_types: ["authorization_code"],
        access_token_ttl: 600,
        authorization_code_ttl: 60,
        id_token_ttl: 600,
        id_token_signature_alg: "RS256",
        pkce: true
      })

    %{user: user, client: client}
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp call(conn), do: CommaWeb.Router.call(conn, @opts)

  defp json!(conn), do: Jason.decode!(conn.resp_body)

  defp resource_owner(user), do: %ResourceOwner{sub: user["id"], username: user["email"]}

  defp pkce_pair do
    verifier = Base.url_encode64(SystemsRuntime.Proc.random_bytes(48), padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp issue_code(user, client, challenge, opts \\ []) do
    authorize_conn =
      conn(:get, "/oauth2/authorize", %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => Keyword.get(opts, :redirect_uri, @redirect_uri),
        "scope" => Keyword.get(opts, :scope, "openid email profile"),
        "state" => "state-1",
        "nonce" => Keyword.get(opts, :nonce, "nonce-1"),
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })
      |> fetch_query_params()

    assert {:authorize_success, %AuthorizeResponse{type: :code, code: code}} =
             Boruta.Oauth.authorize(authorize_conn, resource_owner(user), AuthorizeCallbacks)

    code
  end

  defp post_token(params) do
    conn(:post, "/oauth2/token", URI.encode_query(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> call()
  end

  defp exchange_code(user, client) do
    {verifier, challenge} = pkce_pair()
    code = issue_code(user, client, challenge)

    response =
      post_token(%{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "code" => code,
        "redirect_uri" => @redirect_uri,
        "code_verifier" => verifier
      })

    assert response.status == 200
    json!(response)
  end

  describe "feature flag off" do
    setup do
      SystemsRuntime.put_env(:comma_web, :oauth_idp_enabled, false)
      :ok
    end

    test "every endpoint answers 404" do
      for {method, path} <- [
            {:get, "/.well-known/openid-configuration"},
            {:get, "/.well-known/jwks.json"},
            {:post, "/oauth2/token"},
            {:get, "/oauth2/userinfo"}
          ] do
        response = call(conn(method, path))
        assert response.status == 404, "#{path} should 404 while disabled"
        assert json!(response) == %{"error" => "not_found"}
      end
    end
  end

  describe "discovery" do
    test "publishes the issuer-anchored metadata" do
      response = call(conn(:get, "/.well-known/openid-configuration"))
      assert response.status == 200

      body = json!(response)
      assert body["issuer"] == "https://comma.test"
      assert body["token_endpoint"] == "https://comma.test/oauth2/token"
      assert body["jwks_uri"] == "https://comma.test/.well-known/jwks.json"
      assert body["response_types_supported"] == ["code"]
      assert body["grant_types_supported"] == ["authorization_code"]
      assert body["code_challenge_methods_supported"] == ["S256"]
      assert body["subject_types_supported"] == ["public"]
      assert body["scopes_supported"] == ["openid", "email", "profile"]
    end
  end

  describe "jwks" do
    test "publishes the provider keys, never private material", %{client: client} do
      response = call(conn(:get, "/.well-known/jwks.json"))
      assert response.status == 200

      %{"keys" => keys} = json!(response)
      assert length(keys) == 1

      for key <- keys do
        assert key["kty"] == "RSA"
        assert is_binary(key["kid"])
        refute Map.has_key?(key, "d"), "JWKS must never contain a private exponent"
        refute Map.has_key?(key, "p")
        refute Map.has_key?(key, "q")
      end

      # Decision D3: the per-client key Boruta generated must not appear.
      {_meta, client_jwk} = client.public_key |> JOSE.JWK.from_pem() |> JOSE.JWK.to_map()
      refute Enum.any?(keys, &(&1["n"] == client_jwk["n"]))
    end
  end

  describe "token endpoint" do
    test "authorization_code + PKCE end to end over HTTP", %{user: user, client: client} do
      body = exchange_code(user, client)

      assert body["token_type"] == "bearer"
      assert is_binary(body["access_token"])
      assert is_binary(body["id_token"])
      assert body["expires_in"] > 0
      refute Map.has_key?(body, "refresh_token")

      # The id_token verifies against the published JWKS and carries the
      # comma user id as sub.
      %{"keys" => [jwk_map]} = json!(call(conn(:get, "/.well-known/jwks.json")))
      jwk = JOSE.JWK.from_map(jwk_map)
      assert {true, jwt, _jws} = JOSE.JWT.verify_strict(jwk, ["RS256"], body["id_token"])
      assert jwt.fields["sub"] == user["id"]
      assert jwt.fields["iss"] == "https://comma.test"
      assert jwt.fields["aud"] == client.id
      assert jwt.fields["nonce"] == "nonce-1"
    end

    test "wrong code_verifier is rejected", %{user: user, client: client} do
      {_verifier, challenge} = pkce_pair()
      {other_verifier, _challenge} = pkce_pair()
      code = issue_code(user, client, challenge)

      response =
        post_token(%{
          "grant_type" => "authorization_code",
          "client_id" => client.id,
          "code" => code,
          "redirect_uri" => @redirect_uri,
          "code_verifier" => other_verifier
        })

      assert response.status in [400, 401]
      assert json!(response)["error"] != nil
    end

    test "a code cannot be redeemed twice", %{user: user, client: client} do
      {verifier, challenge} = pkce_pair()
      code = issue_code(user, client, challenge)

      params = %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "code" => code,
        "redirect_uri" => @redirect_uri,
        "code_verifier" => verifier
      }

      assert post_token(params).status == 200

      replay = post_token(params)
      assert replay.status in [400, 401]
    end

    test "redirect_uri must match the code's", %{user: user, client: client} do
      {verifier, challenge} = pkce_pair()
      code = issue_code(user, client, challenge)

      response =
        post_token(%{
          "grant_type" => "authorization_code",
          "client_id" => client.id,
          "code" => code,
          "redirect_uri" => "https://attacker.example.com/callback",
          "code_verifier" => verifier
        })

      assert response.status in [400, 401]
    end
  end

  describe "userinfo" do
    test "returns claims for a valid access token", %{user: user, client: client} do
      %{"access_token" => access_token} = exchange_code(user, client)

      response =
        conn(:get, "/oauth2/userinfo")
        |> put_req_header("authorization", "Bearer #{access_token}")
        |> call()

      assert response.status == 200
      body = json!(response)
      assert body["sub"] == user["id"]
      assert body["email"] == "idp-endpoints@example.com"
      assert get_resp_header(response, "access-control-allow-origin") == ["*"]
    end

    test "a Comma session token is not an OAuth access token", %{user: user} do
      {:ok, %{"token" => session_token}} = Comma.Accounts.create_session(user["id"])

      response =
        conn(:get, "/oauth2/userinfo")
        |> put_req_header("authorization", "Bearer #{session_token}")
        |> call()

      assert response.status == 401
      # RFC 6750 §3.1: the wire value is invalid_token, never Boruta's
      # internal atom spelling.
      assert [challenge] = get_resp_header(response, "www-authenticate")
      assert challenge =~ ~s(Bearer error="invalid_token")
      refute challenge =~ "invalid_access_token"
      assert json!(response)["error"] == "invalid_token"
    end
  end

  describe "CORS preflight" do
  end

  describe "rate limiting" do
    defp unique_peer do
      <<second, third, fourth>> = SystemsRuntime.Proc.random_bytes(3)
      {10, second, third, fourth}
    end

    test "token requests beyond the burst answer 429 with Retry-After" do
      SystemsRuntime.put_env(:comma_core, :oauth_idp_rate_limit, token: [burst: 2, rate: 0.0])
      peer = unique_peer()

      fixed = fn ->
        conn(:post, "/oauth2/token", URI.encode_query(%{"grant_type" => "authorization_code"}))
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Map.put(:remote_ip, peer)
        |> call()
      end

      _consume = fixed.()
      _consume = fixed.()
      limited = fixed.()

      assert limited.status == 429
      assert json!(limited) == %{"error" => "rate_limited"}
      assert [retry_after] = get_resp_header(limited, "retry-after")
      assert String.to_integer(retry_after) >= 1
    end
  end

  describe "telemetry" do
  end
end
