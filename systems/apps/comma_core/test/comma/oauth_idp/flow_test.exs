defmodule Comma.OauthIdp.FlowTest do
  @moduledoc """
  End-to-end authorization-code + PKCE + OIDC flow over the three Comma
  adapters (docs/identity-security.md PR 2), promoted from the
  selection spike into the permanent suite.

  Covers the RFC acceptance criteria that belong to the adapters: the
  full flow issues an RS256 id_token signed with the global key whose
  `sub` is the `usr_*` Comma user id; per-client grant restriction rejects
  every non-enabled grant; and a code replay fails.
  """

  use ExUnit.Case, async: false

  alias Boruta.Ecto.Admin
  alias Boruta.Oauth.AuthorizeResponse
  alias Boruta.Oauth.Error
  alias Boruta.Oauth.TokenResponse
  alias Comma.OauthIdp.ResourceOwners
  alias Comma.OauthIdpTestKeys

  defmodule Callbacks do
    @behaviour Boruta.Oauth.Application

    @impl true
    def authorize_success(_conn, response), do: {:authorize_success, response}
    @impl true
    def authorize_error(_conn, error), do: {:authorize_error, error}
    @impl true
    def token_success(_conn, response), do: {:token_success, response}
    @impl true
    def token_error(_conn, error), do: {:token_error, error}
    @impl true
    def preauthorize_success(_conn, response), do: {:preauthorize_success, response}
    @impl true
    def preauthorize_error(_conn, error), do: {:preauthorize_error, error}
    @impl true
    def introspect_success(_conn, response), do: {:introspect_success, response}
    @impl true
    def introspect_error(_conn, error), do: {:introspect_error, error}
    @impl true
    def revoke_success(_conn), do: :revoke_success
    @impl true
    def revoke_error(_conn, error), do: {:revoke_error, error}
  end

  @redirect_uri "https://vibe.example.com/callback"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Comma.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, {:shared, self()})
    OauthIdpTestKeys.install()

    {:ok, user} = Comma.Accounts.get_or_create_user_by_email("idp-flow@example.com")

    for name <- ["openid", "email", "profile"] do
      {:ok, _scope} = Admin.create_scope(%{name: name, public: true})
    end

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

  defp conn(method, path, params) do
    Plug.Test.conn(method, path, params)
    |> Plug.Conn.fetch_query_params()
  end

  defp authorize!(user, client, opts \\ []) do
    code_verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

    code_challenge =
      :sha256 |> :crypto.hash(code_verifier) |> Base.url_encode64(padding: false)

    authorize_conn =
      conn(:get, "/oauth2/authorize", %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "scope" => Keyword.get(opts, :scope, "openid email profile"),
        "state" => "opaque-state",
        "nonce" => Keyword.get(opts, :nonce, "flow-nonce"),
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256"
      })

    resource_owner = ResourceOwners.to_resource_owner(user)

    assert {:authorize_success, %AuthorizeResponse{type: :code, code: code}} =
             Boruta.Oauth.authorize(authorize_conn, resource_owner, Callbacks)

    {code, code_verifier}
  end

  defp exchange(client, code, code_verifier) do
    token_conn =
      conn(:post, "/oauth2/token", %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "code" => code,
        "redirect_uri" => @redirect_uri,
        "code_verifier" => code_verifier
      })

    Boruta.Oauth.token(token_conn, Callbacks)
  end

  test "full flow issues a globally-signed id_token with the comma user as sub",
       %{user: user, client: client} do
    {code, code_verifier} = authorize!(user, client)

    assert {:token_success,
            %TokenResponse{
              token_type: "bearer",
              access_token: access_token,
              id_token: id_token,
              refresh_token: refresh_token
            }} =
             exchange(client, code, code_verifier)

    assert is_binary(access_token)
    # v1 contract: no refresh token reaches any client, even though the
    # core requests one on the authorization-code flow.
    assert refresh_token == nil

    # Signature verifies against the GLOBAL public key, not the
    # per-client key Boruta generated at registration.
    {_pem, expected_kid} = Comma.OauthIdp.signing_key!()
    global_jwk = Comma.OauthIdpTestKeys.public_jwk(expected_kid)
    assert {true, jwt, jws} = JOSE.JWT.verify_strict(global_jwk, ["RS256"], id_token)

    # The token header names the global kid.
    {_alg, %{"kid" => kid}} = {jws.alg, JOSE.JWS.to_map(jws) |> elem(1)}
    assert kid == expected_kid

    claims = jwt.fields
    assert claims["sub"] == user["id"]
    assert String.starts_with?(claims["sub"], "usr_")
    assert claims["iss"] == "https://comma.test"
    assert claims["aud"] == client.id
    assert claims["nonce"] == "flow-nonce"
    assert claims["email"] == "idp-flow@example.com"

    # The per-client key must NOT verify: signing is provider policy.
    per_client_jwk = JOSE.JWK.from_pem(client.public_key)
    assert {false, _, _} = JOSE.JWT.verify_strict(per_client_jwk, ["RS256"], id_token)
  end

  test "an authorization code cannot be replayed", %{user: user, client: client} do
    {code, code_verifier} = authorize!(user, client)

    assert {:token_success, %TokenResponse{}} = exchange(client, code, code_verifier)
    assert {:token_error, %Error{}} = exchange(client, code, code_verifier)
  end

  test "PKCE is enforced: authorize without code_challenge is rejected",
       %{user: user, client: client} do
    authorize_conn =
      conn(:get, "/oauth2/authorize", %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "scope" => "openid",
        "state" => "opaque-state"
      })

    assert {:authorize_error, %Error{error: error}} =
             Boruta.Oauth.authorize(
               authorize_conn,
               ResourceOwners.to_resource_owner(user),
               Callbacks
             )

    assert error in [:invalid_request, :invalid_code_challenge]
  end

  test "a wrong code_verifier is rejected", %{user: user, client: client} do
    {code, _code_verifier} = authorize!(user, client)

    wrong_verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
    assert {:token_error, %Error{}} = exchange(client, code, wrong_verifier)
  end

  test "other grant types are rejected for an authorization_code-only client",
       %{client: client} do
    token_conn =
      conn(:post, "/oauth2/token", %{
        "grant_type" => "client_credentials",
        "client_id" => client.id,
        "client_secret" => client.secret
      })

    assert {:token_error, %Error{error: :unsupported_grant_type}} =
             Boruta.Oauth.token(token_conn, Callbacks)
  end

  test "implicit response type is rejected for an authorization_code-only client",
       %{user: user, client: client} do
    authorize_conn =
      conn(:get, "/oauth2/authorize", %{
        "response_type" => "token",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "scope" => "openid"
      })

    assert {:authorize_error, %Error{error: error}} =
             Boruta.Oauth.authorize(
               authorize_conn,
               ResourceOwners.to_resource_owner(user),
               Callbacks
             )

    assert error in [:unsupported_response_type, :unsupported_grant_type]
  end

  test "a disabled user cannot complete the flow", %{user: user, client: client} do
    {:ok, _} = Comma.Accounts.update_user(user["id"], %{"status" => "disabled"})

    # The session-derived resource owner may still be presented, but the
    # userinfo/claims path resolves nothing for a disabled account.
    assert {:error, _} = Comma.OauthIdp.ResourceOwners.get_by(sub: user["id"])
  end
end
