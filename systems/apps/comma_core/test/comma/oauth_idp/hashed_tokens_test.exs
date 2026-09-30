defmodule Comma.OauthIdp.HashedTokensTest do
  @moduledoc """
  Decision D4: a database read must not recover a usable credential.

  Drives the real flow through the hashed contexts and then inspects
  `oauth_tokens` directly: every stored value must be a digest, the
  digest must correspond to the issued plaintext, and lookups/revocation
  must keep working through the hashed forms.
  """

  use ExUnit.Case, async: false

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
    Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, {:shared, self()})
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
    code_verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

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

  test "the access token remains usable through the hashed lookup",
       %{user: user, client: client} do
    {_code, access_token} = run_flow!(user, client)

    assert {:ok, token} = Boruta.Oauth.Authorization.AccessToken.authorize(value: access_token)
    assert token.sub == user["id"]

    # The struct the authorization layer sees carries the digest, so
    # downstream in-process consumers never observe the plaintext again.
    assert OauthIdp.hashed?(token.value)
  end

  test "a revoked access token stops authorizing", %{user: user, client: client} do
    {_code, access_token} = run_flow!(user, client)

    {:ok, token} = Boruta.Oauth.Authorization.AccessToken.authorize(value: access_token)
    assert {:ok, _} = Comma.OauthIdp.HashedAccessTokens.revoke(token)

    assert {:error, _} = Boruta.Oauth.Authorization.AccessToken.authorize(value: access_token)
  end

  test "the plaintext never reaches the database layer at all",
       %{user: user, client: client} do
    # Attach to the repo's query telemetry and capture every statement's
    # parameters for the whole flow. If no parameter ever equals the
    # issued plaintext, the plaintext cannot be in any INSERT/UPDATE —
    # and therefore cannot be in the WAL, replication, or backups. This
    # is a strictly stronger property than auditing the final rows.
    test_pid = self()
    handler_id = {__MODULE__, :query_probe, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:comma, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:query_params, metadata[:params] || []})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {code, access_token} = run_flow!(user, client)

    params = collect_params([])

    for value <- params do
      refute value == code, "plaintext code reached the database layer"
      refute value == access_token, "plaintext access token reached the database layer"
    end

    # Sanity: the probe did observe the hashed forms being written.
    assert OauthIdp.hash_token(code) in params
    assert OauthIdp.hash_token(access_token) in params
  end

  defp collect_params(acc) do
    receive do
      {:query_params, params} -> collect_params(acc ++ params)
    after
      0 -> acc
    end
  end

  test "an authorization code is consumed atomically on first lookup",
       %{user: user, client: client} do
    # The claim is a single UPDATE ... WHERE revoked_at IS NULL, so the
    # database serializes concurrent redemptions to exactly one winner.
    # Under the SQL sandbox everything runs on one connection, so we
    # assert the observable contract: the first lookup consumes the
    # code, every later lookup sees nothing.
    code_verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

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

  test "a failed exchange burns the code", %{user: user, client: client} do
    {:ok, _} = Comma.Accounts.get_or_create_user_by_email("idp-hash@example.com")

    code_verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

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

    wrong = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

    exchange = fn verifier ->
      Boruta.Oauth.token(
        conn(:post, "/oauth2/token", %{
          "grant_type" => "authorization_code",
          "client_id" => client.id,
          "code" => code,
          "redirect_uri" => @redirect_uri,
          "code_verifier" => verifier
        }),
        Callbacks
      )
    end

    assert {:token_error, _} = exchange.(wrong)
    # The probe consumed the code: the correct verifier no longer works.
    assert {:token_error, _} = exchange.(code_verifier)
  end

  test "create refuses to mint a refresh token even when asked to",
       %{user: user, client: client} do
    resolved = Comma.OauthIdp.Clients.get_client(client.id)
    {:ok, owner} = Comma.OauthIdp.ResourceOwners.get_by(sub: user["id"])

    assert {:ok, token} =
             Comma.OauthIdp.HashedAccessTokens.create(
               %{client: resolved, sub: user["id"], scope: "openid", resource_owner: owner},
               refresh_token: true
             )

    assert token.refresh_token == nil

    assert [{"access_token", _value, nil}] = stored_values()
  end

  test "hash_token is deterministic, prefixed, and one-way-shaped" do
    assert OauthIdp.hash_token("abc") == OauthIdp.hash_token("abc")
    assert String.starts_with?(OauthIdp.hash_token("abc"), "sha256:")
    refute OauthIdp.hashed?("abc")
    assert OauthIdp.hashed?(OauthIdp.hash_token("abc"))
  end
end
