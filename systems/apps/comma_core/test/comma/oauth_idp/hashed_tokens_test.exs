defmodule Comma.OauthIdp.HashedTokensTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Decision D4: a database read must not recover a usable credential.

  Drives the real flow through the hashed contexts and then inspects
  `oauth_tokens` directly: every stored value must be a digest, the
  digest must correspond to the issued plaintext, and lookups/revocation
  must keep working through the hashed forms.
  """

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.Comma"]
  import Ecto.Query, only: [from: 2]

  alias Boruta.Ecto.Admin
  alias Boruta.Oauth.AuthorizeResponse
  alias Boruta.Oauth.TokenResponse
  alias Comma.OauthIdp
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
    Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, {:shared, SystemsRuntime.Proc.self()})
    OauthIdpTestKeys.install()

    {:ok, user} = Comma.Accounts.get_or_create_user_by_email("idp-hash@example.com")

    for name <- ["openid", "email", "profile"] do
      {:ok, _scope} = Admin.create_scope(%{name: name, public: true})
    end

    {:ok, client} =
      Admin.create_client(%{
        name: "hash-check-app",
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
    Plug.Test.conn(method, path, params) |> Plug.Conn.fetch_query_params()
  end

  defp run_flow!(user, client) do
    code_verifier = Base.url_encode64(SystemsRuntime.Proc.random_bytes(48), padding: false)

    code_challenge =
      :sha256 |> :crypto.hash(code_verifier) |> Base.url_encode64(padding: false)

    authorize_conn =
      conn(:get, "/oauth2/authorize", %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "scope" => "openid",
        "state" => "s",
        "nonce" => "n",
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256"
      })

    assert {:authorize_success, %AuthorizeResponse{code: code}} =
             Boruta.Oauth.authorize(
               authorize_conn,
               ResourceOwners.to_resource_owner(user),
               Callbacks
             )

    token_conn =
      conn(:post, "/oauth2/token", %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "code" => code,
        "redirect_uri" => @redirect_uri,
        "code_verifier" => code_verifier
      })

    assert {:token_success, %TokenResponse{access_token: access_token}} =
             Boruta.Oauth.token(token_conn, Callbacks)

    {code, access_token}
  end

  defp stored_values do
    Comma.Repo.all(from(t in Boruta.Ecto.Token, select: {t.type, t.value, t.refresh_token}))
  end

  test "every persisted credential is a digest tied to the issued plaintext",
       %{user: user, client: client} do
    {code, access_token} = run_flow!(user, client)

    rows = stored_values()
    assert length(rows) == 2

    for {_type, value, refresh} <- rows do
      assert OauthIdp.hashed?(value)
      refute value in [code, access_token]
      # v1 contract: no refresh token is ever generated or stored.
      assert refresh == nil
    end

    assert {"code", OauthIdp.hash_token(code), nil} in rows

    assert Enum.any?(rows, fn {type, value, _} ->
             type == "access_token" and value == OauthIdp.hash_token(access_token)
           end)
  end

  test "a revoked access token stops authorizing", %{user: user, client: client} do
    {_code, access_token} = run_flow!(user, client)

    {:ok, token} = Boruta.Oauth.Authorization.AccessToken.authorize(value: access_token)
    assert {:ok, _} = Comma.OauthIdp.HashedAccessTokens.revoke(token)

    assert {:error, _} = Boruta.Oauth.Authorization.AccessToken.authorize(value: access_token)
  end

  test "an authorization code is consumed atomically on first lookup",
       %{user: user, client: client} do
    # The claim is a single UPDATE ... WHERE revoked_at IS NULL, so the
    # database serializes concurrent redemptions to exactly one winner.
    # Under the SQL sandbox everything runs on one connection, so we
    # assert the observable contract: the first lookup consumes the
    # code, every later lookup sees nothing.
    code_verifier = Base.url_encode64(SystemsRuntime.Proc.random_bytes(48), padding: false)

    code_challenge =
      :sha256 |> :crypto.hash(code_verifier) |> Base.url_encode64(padding: false)

    authorize_conn =
      conn(:get, "/oauth2/authorize", %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "scope" => "openid",
        "state" => "s",
        "nonce" => "n",
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256"
      })

    assert {:authorize_success, %AuthorizeResponse{code: code}} =
             Boruta.Oauth.authorize(
               authorize_conn,
               ResourceOwners.to_resource_owner(user),
               Callbacks
             )

    assert %Boruta.Oauth.Token{revoked_at: nil} =
             Comma.OauthIdp.HashedCodes.get_by(value: code, redirect_uri: @redirect_uri)

    assert Comma.OauthIdp.HashedCodes.get_by(value: code, redirect_uri: @redirect_uri) == nil
  end
end
