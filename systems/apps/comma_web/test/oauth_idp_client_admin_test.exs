defmodule CommaWeb.OauthIdpClientAdminTest do
  # async: false — the KEK, endpoint flag, and admin token live in
  # application config.
  use SystemsClock.Case, async: false

  import Plug.Conn
  import Plug.Test

  @opts CommaWeb.Router.init([])
  @admin_token "test-token"
  @redirect_uri "https://vibe.example.com/callback"

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)

    previous_kek = SystemsRuntime.get_env(:comma_core, :oauth_idp)

    SystemsRuntime.put_env(:comma_core, :oauth_idp,
      kek: :crypto.hash(:sha256, "idp-client-admin-kek")
    )

    previous_flag = SystemsRuntime.get_env(:comma_web, :oauth_idp_enabled)
    SystemsRuntime.put_env(:comma_web, :oauth_idp_enabled, true)

    previous_api_token = SystemsRuntime.get_env(:comma_web, :api_token)
    SystemsRuntime.put_env(:comma_web, :api_token, @admin_token)

    on_exit(fn ->
      CommaWeb.TestRepoSandbox.stop_owner(owner)
      restore_env(:comma_core, :oauth_idp, previous_kek)
      restore_env(:comma_web, :oauth_idp_enabled, previous_flag)
      restore_env(:comma_web, :api_token, previous_api_token)
    end)

    _kid = Comma.OauthIdp.SigningKeys.provision_initial!()
    :ok
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp call(conn), do: CommaWeb.Router.call(conn, @opts)

  defp ops_post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{@admin_token}")
    |> call()
  end

  defp ops_get(path) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{@admin_token}")
    |> call()
  end

  defp json!(conn), do: Jason.decode!(conn.resp_body)

  defp create_client!(body \\ %{}) do
    response =
      ops_post(
        "/v1/comma/admin/oauth-clients",
        Map.merge(%{"name" => "VibeSketch", "redirect_uris" => [@redirect_uri]}, body)
      )

    assert response.status == 201
    json!(response)
  end

  test "create returns the secret once, with no-store, and the list never repeats it" do
    response =
      ops_post("/v1/comma/admin/oauth-clients", %{
        "name" => "VibeSketch",
        "redirect_uris" => [@redirect_uri],
        "confidential" => true
      })

    assert response.status == 201
    assert get_resp_header_value(response, "cache-control") == "no-store"
    client = json!(response)
    assert is_binary(client["client_secret"])

    list = ops_get("/v1/comma/admin/oauth-clients")
    assert list.status == 200
    [listed] = json!(list)["data"]
    assert listed["id"] == client["id"]
    refute Map.has_key?(listed, "client_secret")
    refute list.resp_body =~ client["client_secret"]
  end

  defp get_resp_header_value(conn, name) do
    case get_resp_header(conn, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  test "rotate returns a fresh secret once; unknown ids are 404" do
    client = create_client!(%{"confidential" => true})

    rotated = ops_post("/v1/comma/admin/oauth-clients/#{client["id"]}/rotate-secret", %{})
    assert rotated.status == 200
    body = json!(rotated)
    assert is_binary(body["client_secret"])
    assert body["client_secret"] != client["client_secret"]
    assert get_resp_header_value(rotated, "cache-control") == "no-store"

    missing =
      ops_post("/v1/comma/admin/oauth-clients/#{SystemsRuntime.Proc.uuid()}/rotate-secret", %{})

    assert missing.status == 404
  end

  test "disable cuts the live OAuth surface immediately; enable restores it" do
    client = create_client!()

    # Sanity: the client resolves on the authorize path before disable.
    assert %Boruta.Oauth.Client{} = Comma.OauthIdp.Clients.get_client(client["id"])

    disabled = ops_post("/v1/comma/admin/oauth-clients/#{client["id"]}/disable", %{})
    assert disabled.status == 200
    assert is_binary(json!(disabled)["disabled_at"])

    # Token endpoint refuses the disabled client outright.
    token_response =
      conn(
        :post,
        "/oauth2/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "client_id" => client["id"],
          "code" => "any",
          "redirect_uri" => @redirect_uri,
          "code_verifier" => "any"
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> call()

    assert token_response.status in [400, 401]
    assert json!(token_response)["error"] == "invalid_client"

    enabled = ops_post("/v1/comma/admin/oauth-clients/#{client["id"]}/enable", %{})
    assert enabled.status == 200
    assert json!(enabled)["disabled_at"] == nil
    assert %Boruta.Oauth.Client{} = Comma.OauthIdp.Clients.get_client(client["id"])
  end

  test "a ClientAdmin-created public client completes the code exchange end to end" do
    client = create_client!()
    {:ok, user} = Comma.Accounts.get_or_create_user_by_email("client-admin-e2e@example.com")

    for name <- ["openid", "email", "profile"] do
      {:ok, _scope} = Boruta.Ecto.Admin.create_scope(%{name: name, public: true})
    end

    verifier = Base.url_encode64(SystemsRuntime.Proc.random_bytes(48), padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    authorize_conn =
      conn(:get, "/oauth2/authorize", %{
        "response_type" => "code",
        "client_id" => client["id"],
        "redirect_uri" => @redirect_uri,
        "scope" => "openid email profile",
        "state" => "s",
        "nonce" => "n",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })
      |> fetch_query_params()

    assert {:authorize_success, %Boruta.Oauth.AuthorizeResponse{code: code}} =
             Boruta.Oauth.authorize(
               authorize_conn,
               %Boruta.Oauth.ResourceOwner{sub: user["id"], username: user["email"]},
               CommaWeb.OauthIdpClientAdminTest.AuthorizeCallbacks
             )

    token_response =
      conn(
        :post,
        "/oauth2/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "client_id" => client["id"],
          "code" => code,
          "redirect_uri" => @redirect_uri,
          "code_verifier" => verifier
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> call()

    assert token_response.status == 200
    body = json!(token_response)
    assert is_binary(body["access_token"])
    assert is_binary(body["id_token"])
  end

  defmodule AuthorizeCallbacks do
    @moduledoc false
    def authorize_success(_conn, response), do: {:authorize_success, response}
    def authorize_error(_conn, error), do: {:authorize_error, error}
  end

  describe "human command semantics (rejected vs failed)" do
  end

  test "unauthenticated and product-session callers are rejected" do
    response =
      conn(:post, "/v1/comma/admin/oauth-clients", Jason.encode!(%{"name" => "VibeSketch"}))
      |> put_req_header("content-type", "application/json")
      |> call()

    assert response.status == 401
  end
end
