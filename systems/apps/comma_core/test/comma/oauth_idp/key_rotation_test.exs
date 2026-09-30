defmodule Comma.OauthIdp.KeyRotationTest do
  @moduledoc """
  Rotation over the shared signing-key set
  (docs/identity-security.md).

  Pods all read one table, so the set is instantly consistent inside
  Comma. What the fifth review round established is that relying parties
  are NOT instantly consistent: their JWKS caches refresh on their own
  clock (contractually bounded). The two-step protocol makes activation
  wait out that bound — enforced by data, not discipline — and the
  acceptance here retains an RP cache ACROSS the rotation boundary, as
  that review required. Early removal inside the verification window is
  likewise refused, with explicitly named emergency bypasses.
  """

  use ExUnit.Case, async: false

  alias Boruta.Ecto.Admin
  alias Boruta.Oauth.AuthorizeResponse
  alias Boruta.Oauth.TokenResponse
  alias Comma.OauthIdp
  alias Comma.OauthIdp.ResourceOwners
  alias Comma.OauthIdp.SigningKeys
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
    OauthIdpTestKeys.install_kek()

    {:ok, user} = Comma.Accounts.get_or_create_user_by_email("idp-rotation@example.com")

    for name <- ["openid", "email", "profile"] do
      {:ok, _scope} = Admin.create_scope(%{name: name, public: true})
    end

    {:ok, client} =
      Admin.create_client(%{
        name: "rotation-app",
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

  defp issue_id_token!(user, client) do
    code_verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

    code_challenge =
      :sha256 |> :crypto.hash(code_verifier) |> Base.url_encode64(padding: false)

    authorize_conn =
      Plug.Test.conn(:get, "/oauth2/authorize", %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "scope" => "openid email profile",
        "state" => "opaque-state",
        "nonce" => "rotation-nonce",
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256"
      })
      |> Plug.Conn.fetch_query_params()

    resource_owner = ResourceOwners.to_resource_owner(user)

    assert {:authorize_success, %AuthorizeResponse{type: :code, code: code}} =
             Boruta.Oauth.authorize(authorize_conn, resource_owner, Callbacks)

    token_conn =
      Plug.Test.conn(:post, "/oauth2/token", %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "code" => code,
        "redirect_uri" => @redirect_uri,
        "code_verifier" => code_verifier
      })
      |> Plug.Conn.fetch_query_params()

    assert {:token_success, %TokenResponse{id_token: id_token}} =
             Boruta.Oauth.token(token_conn, Callbacks)

    id_token
  end

  defp jwks_by_kid do
    Map.new(OauthIdp.public_jwks!(), fn jwk -> {jwk.fields["kid"], jwk} end)
  end

  defp header_kid(id_token) do
    %JOSE.JWS{fields: fields} = JOSE.JWT.peek_protected(id_token)
    fields["kid"]
  end

  defp verifies?(id_token) do
    case jwks_by_kid()[header_kid(id_token)] do
      nil -> false
      jwk -> match?({true, _, _}, JOSE.JWT.verify_strict(jwk, ["RS256"], id_token))
    end
  end

  # An RP's cached JWKS: snapshotted once, never refetched. This is the
  # review's required shape — assertions that re-read the live JWKS
  # cannot see cache staleness at all.
  defp snapshot_rp_cache do
    jwks_by_kid()
  end

  defp cached_rp_verifies?(cache, id_token) do
    case cache[header_kid(id_token)] do
      nil -> false
      jwk -> match?({true, _, _}, JOSE.JWT.verify_strict(jwk, ["RS256"], id_token))
    end
  end

  defp backdate_pending!(seconds) do
    import Ecto.Query

    Comma.Repo.update_all(
      from(k in SigningKeys.Key, where: k.status == "pending"),
      inc: [],
      set: [created_at: DateTime.add(DateTime.utc_now(), -seconds, :second)]
    )
  end

  defp backdate_retire_after!(kid, seconds) do
    import Ecto.Query

    Comma.Repo.update_all(
      from(k in SigningKeys.Key, where: k.kid == ^kid),
      set: [retire_after: DateTime.add(DateTime.utc_now(), -seconds, :second)]
    )
  end

  test "an RP cache held across the rotation boundary verifies the new signer",
       %{user: user, client: client} do
    old_kid = SigningKeys.provision_initial!()
    old_token = issue_id_token!(user, client)
    assert header_kid(old_token) == old_kid

    new_kid = SigningKeys.prepublish!()

    # The RP refreshes at some point during the enforced pre-publish
    # window — any refresh in that window already sees the pending key.
    rp_cache = snapshot_rp_cache()
    assert Map.has_key?(rp_cache, new_kid)

    backdate_pending!(631)
    assert ^new_kid = SigningKeys.activate!()

    # The rotation boundary has passed; the RP has NOT refreshed. Both
    # the new signer's tokens and the old key's tokens verify against
    # the stale cache.
    new_token = issue_id_token!(user, client)
    assert header_kid(new_token) == new_kid
    assert cached_rp_verifies?(rp_cache, new_token)
    assert cached_rp_verifies?(rp_cache, old_token)
  end

  test "activation refuses to run inside the contractual RP cache window",
       %{user: user, client: client} do
    SigningKeys.provision_initial!()
    _old_token = issue_id_token!(user, client)

    # An RP cache taken BEFORE pre-publish: exactly the cache that made
    # single-step rotation unsafe.
    stale_cache = snapshot_rp_cache()

    new_kid = SigningKeys.prepublish!()

    assert_raise RuntimeError, ~r/published for \d+s; the contractual RP cache bound/, fn ->
      SigningKeys.activate!()
    end

    # Because activation was refused, the stale cache never has to
    # verify a new-kid token: everything issued right now still bears
    # the old kid.
    still_old = issue_id_token!(user, client)
    refute header_kid(still_old) == new_kid
    assert cached_rp_verifies?(stale_cache, still_old)
  end

  test "routine removal refuses inside the verification window and works after it",
       %{user: user, client: client} do
    old_kid = SigningKeys.provision_initial!()
    old_token = issue_id_token!(user, client)

    SigningKeys.prepublish!()
    backdate_pending!(631)
    SigningKeys.activate!()

    # The review's second regression, green: retire_after is enforced.
    assert_raise RuntimeError, ~r/inside its verification\s+window/, fn ->
      SigningKeys.remove!(old_kid)
    end

    assert verifies?(old_token)

    backdate_retire_after!(old_kid, 1)
    :ok = SigningKeys.remove!(old_kid)
    refute verifies?(old_token)
  end

  test "emergency paths are immediate and explicitly named",
       %{user: user, client: client} do
    compromised_kid = SigningKeys.provision_initial!()
    compromised_token = issue_id_token!(user, client)

    # rotate_compromised! replaces the signer and deletes the leaked row
    # in one transaction: the compromised public key leaves the JWKS
    # immediately rather than parking in verify_only.
    new_kid = SigningKeys.rotate_compromised!()
    refute Map.has_key?(jwks_by_kid(), compromised_kid)
    refute verifies?(compromised_token)
    assert header_kid(issue_id_token!(user, client)) == new_kid

    # remove_compromised! bypasses the verification window for a
    # verify_only key — but never removes the active signer.
    SigningKeys.prepublish!()
    backdate_pending!(631)
    demoted_kid = new_kid
    SigningKeys.activate!()
    :ok = SigningKeys.remove_compromised!(demoted_kid)
    refute Map.has_key?(jwks_by_kid(), demoted_kid)

    assert_raise RuntimeError, ~r/is the active signer/, fn ->
      SigningKeys.remove_compromised!(SigningKeys.list() |> hd() |> Map.fetch!(:kid))
    end
  end

  test "one rotation in flight at a time; a pending key can be cancelled" do
    SigningKeys.provision_initial!()
    pending_kid = SigningKeys.prepublish!()

    assert_raise RuntimeError, ~r/already has a pending key/, fn ->
      SigningKeys.prepublish!()
    end

    # Cancelling a pending key is always safe: nothing was signed by it.
    :ok = SigningKeys.remove!(pending_kid)
    refute Map.has_key?(jwks_by_kid(), pending_kid)
  end

  test "at most one signing key is a database guarantee" do
    SigningKeys.provision_initial!()

    for _round <- 1..3 do
      SigningKeys.prepublish!()
      backdate_pending!(631)
      SigningKeys.activate!()

      import Ecto.Query

      assert Comma.Repo.aggregate(
               from(k in SigningKeys.Key, where: k.status == "signing"),
               :count
             ) == 1
    end
  end

  test "custody: ciphertext at rest, wrong KEK fails closed, no private material in JWKS",
       %{user: user, client: client} do
    kid = SigningKeys.provision_initial!()
    _token = issue_id_token!(user, client)

    import Ecto.Query
    row = Comma.Repo.one(from(k in SigningKeys.Key, where: k.kid == ^kid))
    refute String.contains?(row.public_pem, "PRIVATE")
    refute is_nil(row.private_pem_ciphertext)
    refute String.contains?(Base.encode64(row.private_pem_ciphertext), "BEGIN RSA")

    for jwk <- OauthIdp.public_jwks!() do
      {_kty, map} = JOSE.JWK.to_map(jwk)
      refute Map.has_key?(map, "d")
    end

    previous = Application.get_env(:comma_core, :oauth_idp)
    wrong = Keyword.put(previous, :kek, :crypto.strong_rand_bytes(32))
    Application.put_env(:comma_core, :oauth_idp, wrong)
    on_exit(fn -> Application.put_env(:comma_core, :oauth_idp, previous) end)

    assert_raise RuntimeError, ~r/failed authenticated\s+decryption/, fn ->
      OauthIdp.signing_key!()
    end
  end

  test "unprovisioned deployment fails closed" do
    assert_raise RuntimeError, ~r/has no signing key/, fn ->
      OauthIdp.signing_key!()
    end

    assert_raise RuntimeError, ~r/no pending key/, fn ->
      SigningKeys.activate!()
    end

    assert_raise RuntimeError, ~r/already has keys/, fn ->
      SigningKeys.provision_initial!()
      SigningKeys.provision_initial!()
    end
  end
end
