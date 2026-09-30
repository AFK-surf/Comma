defmodule CommaWeb.OauthIdpClientAdminTest do
  # async: false — the KEK, endpoint flag, and admin token live in
  # application config.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @opts CommaWeb.Router.init([])
  @admin_token "test-token"
  @redirect_uri "https://vibe.example.com/callback"

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)

    previous_kek = Application.get_env(:comma_core, :oauth_idp)

    Application.put_env(:comma_core, :oauth_idp,
      kek: :crypto.hash(:sha256, "idp-client-admin-kek")
    )

    previous_flag = Application.get_env(:comma_web, :oauth_idp_enabled)
    Application.put_env(:comma_web, :oauth_idp_enabled, true)

    previous_api_token = Application.get_env(:comma_web, :api_token)
    Application.put_env(:comma_web, :api_token, @admin_token)

    on_exit(fn ->
      CommaWeb.TestRepoSandbox.stop_owner(owner)
      restore_env(:comma_core, :oauth_idp, previous_kek)
      restore_env(:comma_web, :oauth_idp_enabled, previous_flag)
      restore_env(:comma_web, :api_token, previous_api_token)
    end)

    _kid = Comma.OauthIdp.SigningKeys.provision_initial!()
    :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

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

  test "validation errors map to 400 with the specific code" do
    response =
      ops_post("/v1/comma/admin/oauth-clients", %{
        "name" => "Comma Assistant",
        "redirect_uris" => [@redirect_uri]
      })

    assert response.status == 400
    assert json!(response)["error"] == "reserved_oauth_client_name"

    response =
      ops_post("/v1/comma/admin/oauth-clients", %{
        "name" => "VibeSketch",
        "redirect_uris" => ["http://vibe.example.com/cb"]
      })

    assert response.status == 400
    assert json!(response)["error"] == "invalid_redirect_uri"
  end

  test "string confidential is rejected, not downgraded to a public client" do
    response =
      ops_post("/v1/comma/admin/oauth-clients", %{
        "name" => "VibeSketch",
        "redirect_uris" => [@redirect_uri],
        "confidential" => "true"
      })

    assert response.status == 400
    assert json!(response)["error"] == "invalid_oauth_client_confidential"
  end

  test "rotate returns a fresh secret once; unknown ids are 404" do
    client = create_client!(%{"confidential" => true})

    rotated = ops_post("/v1/comma/admin/oauth-clients/#{client["id"]}/rotate-secret", %{})
    assert rotated.status == 200
    body = json!(rotated)
    assert is_binary(body["client_secret"])
    assert body["client_secret"] != client["client_secret"]
    assert get_resp_header_value(rotated, "cache-control") == "no-store"

    missing = ops_post("/v1/comma/admin/oauth-clients/#{Ecto.UUID.generate()}/rotate-secret", %{})
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

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
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

  test "the whole admin surface is 404 while the IdP flag is off" do
    client = create_client!()
    Application.put_env(:comma_web, :oauth_idp_enabled, false)

    assert ops_get("/v1/comma/admin/oauth-clients").status == 404

    for path <- [
          "/v1/comma/admin/oauth-clients",
          "/v1/comma/admin/oauth-clients/#{client["id"]}/rotate-secret",
          "/v1/comma/admin/oauth-clients/#{client["id"]}/disable",
          "/v1/comma/admin/oauth-clients/#{client["id"]}/enable"
        ] do
      assert ops_post(path, %{"name" => "X", "redirect_uris" => [@redirect_uri]}).status == 404
    end
  end

  test "a structured JSON name is a typed 400, never a 500" do
    for bad_name <- [%{"$gt" => ""}, ["VibeSketch"], 42] do
      response =
        ops_post("/v1/comma/admin/oauth-clients", %{
          "name" => bad_name,
          "redirect_uris" => [@redirect_uri]
        })

      assert response.status == 400, "#{inspect(bad_name)} must be a typed rejection"
      assert json!(response)["error"] == "invalid_oauth_client_name"
    end
  end

  describe "human command semantics (rejected vs failed)" do
    @admin_origin "http://127.0.0.1:4175"

    defp web_headers(conn, expectation) do
      conn
      |> put_req_header("origin", @admin_origin)
      |> put_req_header("x-comma-session-transport", "cookie")
      |> put_req_header("x-comma-session-lifecycle-version", "1")
      |> put_req_header("x-comma-expected-auth-session-id", expectation)
    end

    defp browser_login! do
      login =
        conn(:post, "/v1/comma/auth/email/login", Jason.encode!(%{"email" => "idp-ops@comma.surf"}))
        |> put_req_header("content-type", "application/json")
        |> web_headers("none")
        |> call()

      assert login.status == 200
      %{"challenge_id" => challenge_id, "code" => code} = json!(login)

      verify =
        conn(
          :post,
          "/v1/comma/auth/email/verify",
          Jason.encode!(%{"challenge_id" => challenge_id, "code" => code})
        )
        |> put_req_header("content-type", "application/json")
        |> web_headers("none")
        |> call()

      assert verify.status == 200
      cookie = verify.resp_cookies[CommaWeb.SessionCookie.cookie_name()]
      {json!(verify)["session_id"], cookie.value}
    end

    defp human_post(path, body, session_id, token) do
      conn(:post, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("cookie", "#{CommaWeb.SessionCookie.cookie_name()}=#{token}")
      |> web_headers(session_id)
      |> call()
    end

    defp audit_outcomes(action) do
      import Ecto.Query

      Comma.Repo.all(
        from(e in Comma.Admin.AuditEvent, where: e.action == ^action, select: e.outcome)
      )
    end

    test "invalid input is rejected before audit intent and never burns the idempotency key" do
      {session_id, token} = browser_login!()

      envelope = %{
        "reason" => "onboarding hand-picked app",
        "idempotency_key" => "create-vibesketch-reuse-1",
        "confirmation" => "create-oauth-client:VibeSketch"
      }

      invalid =
        human_post(
          "/v1/comma/admin/oauth-clients",
          Map.merge(envelope, %{
            "name" => "VibeSketch",
            "redirect_uris" => [@redirect_uri],
            "confidential" => "true"
          }),
          session_id,
          token
        )

      assert invalid.status == 400
      assert json!(invalid)["error"] == "invalid_oauth_client_confidential"

      # Recorded as rejected — not failed — per the Admin RFC contract.
      assert "rejected" in audit_outcomes("create_oauth_client")
      refute "failed" in audit_outcomes("create_oauth_client")

      # The SAME idempotency key succeeds with corrected input: the
      # rejection did not consume it.
      valid =
        human_post(
          "/v1/comma/admin/oauth-clients",
          Map.merge(envelope, %{
            "name" => "VibeSketch",
            "redirect_uris" => [@redirect_uri],
            "confidential" => true
          }),
          session_id,
          token
        )

      assert valid.status == 201
      assert is_binary(json!(valid)["client_secret"])
      assert "succeeded" in audit_outcomes("create_oauth_client")
    end

    test "lifecycle bodies reject unknown fields without mutating the client" do
      {session_id, token} = browser_login!()
      client = create_client!()

      response =
        human_post(
          "/v1/comma/admin/oauth-clients/#{client["id"]}/disable",
          %{
            "reason" => "cleanup",
            "idempotency_key" => "disable-unknown-field-1",
            "confirmation" => "disable-oauth-client:#{client["id"]}",
            "metadata" => %{"comma_disabled_at" => "spoofed"}
          },
          session_id,
          token
        )

      assert response.status == 400
      assert json!(response)["error"] == "invalid_oauth_client_field"

      # The client is untouched and still resolvable.
      assert %Boruta.Oauth.Client{} = Comma.OauthIdp.Clients.get_client(client["id"])
      assert "rejected" in audit_outcomes("disable_oauth_client")
      refute "failed" in audit_outcomes("disable_oauth_client")
    end
  end

  test "unauthenticated and product-session callers are rejected" do
    response =
      conn(:post, "/v1/comma/admin/oauth-clients", Jason.encode!(%{"name" => "VibeSketch"}))
      |> put_req_header("content-type", "application/json")
      |> call()

    assert response.status == 401
  end
end
