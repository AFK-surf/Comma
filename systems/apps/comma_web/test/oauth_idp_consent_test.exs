defmodule CommaWeb.OauthIdpConsentTest do
  # async: false — the KEK and endpoint flag live in application config.
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]
  import Plug.Conn
  import Plug.Test

  alias Boruta.Ecto.Admin

  @opts CommaWeb.Router.init([])
  @redirect_uri "https://vibe.example.com/callback"
  @issuer "https://comma.test"

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)

    previous_kek = SystemsRuntime.get_env(:comma_core, :oauth_idp)
    SystemsRuntime.put_env(:comma_core, :oauth_idp, kek: :crypto.hash(:sha256, "idp-consent-kek"))

    previous_flag = SystemsRuntime.get_env(:comma_web, :oauth_idp_enabled)
    SystemsRuntime.put_env(:comma_web, :oauth_idp_enabled, true)

    # Generous budgets: this suite exercises the consent flow, not the
    # limiter, and Plug.Test conns all share the default peer IP.
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

    {:ok, user} = Comma.Accounts.get_or_create_user_by_email("idp-consent@example.com")
    {:ok, session} = Comma.Accounts.create_session(user["id"])

    for name <- ["openid", "email", "profile"] do
      {:ok, _scope} = Admin.create_scope(%{name: name, public: true})
    end

    {:ok, client} =
      Admin.create_client(%{
        name: "VibeSketch",
        redirect_uris: [@redirect_uri],
        supported_grant_types: ["authorization_code"],
        access_token_ttl: 600,
        authorization_code_ttl: 60,
        id_token_ttl: 600,
        id_token_signature_alg: "RS256",
        pkce: true
      })

    %{user: user, session_token: session["token"], client: client}
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp attach_request_telemetry do
    handler_id = "idp-consent-#{inspect(SystemsRuntime.Proc.make_ref())}"
    test_pid = SystemsRuntime.Proc.self()

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler_id,
        [:comma_product, :oauth_idp, :request],
        fn _event, measurements, metadata, _config ->
          SystemsRuntime.Proc.send(test_pid, {:idp_request, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler_id) end)
  end

  defp call(conn), do: CommaWeb.Router.call(conn, @opts)

  defp with_session(conn, token) do
    put_req_header(conn, "cookie", "#{CommaWeb.SessionCookie.cookie_name()}=#{token}")
  end

  defp pkce_pair do
    verifier = Base.url_encode64(SystemsRuntime.Proc.random_bytes(48), padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp authorize_params(client, challenge, overrides \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "scope" => "openid email profile",
        "state" => "opaque-state",
        "nonce" => "consent-nonce",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      },
      overrides
    )
  end

  defp get_consent(session_token, client, challenge, overrides \\ %{}) do
    conn(:get, "/oauth2/authorize", authorize_params(client, challenge, overrides))
    |> with_session(session_token)
    |> call()
  end

  defp extract_hidden(html, name) do
    [_, value] = Regex.run(~r/name="#{name}" value="([^"]+)"/, html)
    value
  end

  defp post_decision(session_token, params, headers \\ []) do
    headers =
      Keyword.merge([origin: @issuer, sec_fetch_site: "same-origin"], headers)

    conn = conn(:post, "/oauth2/authorize", URI.encode_query(params))

    conn =
      Enum.reduce(headers, conn, fn
        {_key, nil}, acc -> acc
        {:origin, value}, acc -> put_req_header(acc, "origin", value)
        {:sec_fetch_site, value}, acc -> put_req_header(acc, "sec-fetch-site", value)
      end)

    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> with_session(session_token)
    |> call()
  end

  defp approve_flow(session_token, client) do
    {verifier, challenge} = pkce_pair()
    consent = get_consent(session_token, client, challenge)
    assert consent.status == 200

    handle = extract_hidden(consent.resp_body, "handle")
    csrf = extract_hidden(consent.resp_body, "_csrf_token")

    response =
      post_decision(session_token, %{
        "handle" => handle,
        "_csrf_token" => csrf,
        "decision" => "approve"
      })

    {response, verifier}
  end

  describe "RP-controlled parameter sizes" do
  end

  describe "feature flag off" do
    setup do
      SystemsRuntime.put_env(:comma_web, :oauth_idp_enabled, false)
      :ok
    end
  end

  describe "GET /oauth2/authorize" do
    test "renders the consent page for a signed-in user", %{
      session_token: token,
      client: client,
      user: user
    } do
      {_verifier, challenge} = pkce_pair()
      response = get_consent(token, client, challenge)

      assert response.status == 200
      assert response.resp_body =~ "Sign in to VibeSketch"
      assert response.resp_body =~ user["email"]
      assert response.resp_body =~ ~s(name="handle")
      assert response.resp_body =~ ~s(name="_csrf_token")
      assert response.resp_body =~ "vibe.example.com"

      assert get_resp_header(response, "content-type") |> hd() =~ "text/html"
      assert [csp] = get_resp_header(response, "content-security-policy")
      assert csp =~ "default-src 'none'"
      assert csp =~ "frame-ancestors 'none'"
      assert get_resp_header(response, "x-frame-options") == ["DENY"]
      assert get_resp_header(response, "cache-control") == ["no-store, no-transform"]
      assert get_resp_header(response, "referrer-policy") == ["same-origin"]
    end

    test "the CSP lets the form submission follow the redirect to the client",
         %{session_token: token, client: client} do
      # Chrome enforces form-action on every hop of the redirect chain a
      # form submission follows, and approving consent answers a 302 to the
      # client's redirect_uri carrying the authorization code. With a bare
      # `form-action 'self'` the server accepts the POST, consumes the
      # one-shot handle, issues the code — and the browser then refuses the
      # redirect: the user stays on the consent page, the client never gets
      # the code, and a second click answers authorization_request_expired.
      # The allowed origin must come from the validated stored request.
      {_verifier, challenge} = pkce_pair()
      consent = get_consent(token, client, challenge)

      assert [csp] = get_resp_header(consent, "content-security-policy")

      assert csp =~ "form-action 'self' https://vibe.example.com",
             "consent CSP must allow the redirect to the registered redirect_uri; got: " <> csp

      # Terminal error pages have no form and keep the strict policy.
      error =
        get_consent(token, client, challenge, %{
          "redirect_uri" => "https://attacker.example.com/cb"
        })

      assert error.status == 400
      assert [error_csp] = get_resp_header(error, "content-security-policy")
      assert error_csp =~ "form-action 'self';"
      refute error_csp =~ "attacker.example.com"
    end

    test "escapes a hostile client name", %{session_token: token} do
      {:ok, hostile} =
        Admin.create_client(%{
          name: "<script>alert(1)</script>",
          redirect_uris: [@redirect_uri],
          supported_grant_types: ["authorization_code"],
          access_token_ttl: 600,
          authorization_code_ttl: 60,
          id_token_ttl: 600,
          id_token_signature_alg: "RS256",
          pkce: true
        })

      {_verifier, challenge} = pkce_pair()
      response = get_consent(token, hostile, challenge)

      assert response.status == 200
      refute response.resp_body =~ "<script>alert(1)</script>"
      assert response.resp_body =~ "&lt;script&gt;"
    end

    test "without a session stashes the request and redirects to the login page",
         %{client: client} do
      attach_request_telemetry()
      {_verifier, challenge} = pkce_pair()

      response =
        conn(:get, "/oauth2/authorize", authorize_params(client, challenge))
        |> call()

      assert response.status == 302

      settle_receive(
        {:idp_request, %{count: 1}, %{endpoint: :authorize, outcome: :login_redirect}}
      )

      assert [location] = get_resp_header(response, "location")

      # The redirect goes to the configured frontend origin and carries
      # only the opaque handle — none of the authorization parameters
      # ride along in the URL (RFC §5).
      login_uri = URI.parse(location)
      origin = SystemsRuntime.fetch_env!(:comma_web, :web_cookie_origin)
      assert "#{login_uri.scheme}://#{login_uri.host}:#{login_uri.port}" == origin
      assert login_uri.path == "/login"

      assert %{"oauth_handle" => handle} = URI.decode_query(login_uri.query)
      assert map_size(URI.decode_query(login_uri.query)) == 1
      assert {:ok, _uuid} = Ecto.UUID.cast(handle)

      # The stashed row is anonymous and unconsumed.
      request = Comma.Repo.get!(Comma.OauthIdp.AuthorizeRequests.Request, handle)
      assert request.user_id == nil
      assert request.consumed_at == nil
      assert request.client_id == client.id
      refute response.resp_body =~ "VibeSketch"
    end

    test "a tampered redirect_uri renders the terminal page without the client name and without redirecting",
         %{session_token: token, client: client} do
      {_verifier, challenge} = pkce_pair()

      response =
        get_consent(token, client, challenge, %{
          "redirect_uri" => "https://attacker.example.com/callback"
        })

      assert response.status == 400
      assert get_resp_header(response, "location") == []
      assert response.resp_body =~ "isn’t valid"
      refute response.resp_body =~ "VibeSketch"
    end

    test "restricted and ops-issued sessions cannot authorize apps", %{
      user: user,
      client: client,
      session_token: token
    } do
      {_verifier, challenge} = pkce_pair()

      {:ok, restricted} =
        Comma.Accounts.create_session(user["id"],
          session_source: "ops_api",
          restricted: true,
          ttl_seconds: 600,
          interaction_budget_remaining: 10
        )

      {:ok, ops_unrestricted} =
        Comma.Accounts.create_session(user["id"], session_source: "ops_api", ttl_seconds: 600)

      # A guest's placeholder email is not an identity to assert.
      guest =
        %Comma.Accounts.User{}
        |> Comma.Accounts.User.changeset(%{
          id: Comma.Accounts.User.new_id(),
          email: "g-#{SystemsRuntime.Proc.unique_integer([:positive])}@guest.comma.invalid",
          status: "active"
        })
        |> Ecto.Changeset.put_change(:kind, "guest")
        |> Comma.Repo.insert!()

      {:ok, guest_session} =
        Comma.Accounts.create_session(guest.id, auth_method: "guest", ttl_seconds: 600)

      for bad_token <- [restricted["token"], ops_unrestricted["token"], guest_session["token"]] do
        response = get_consent(bad_token, client, challenge)
        assert response.status == 403
        assert response.resp_body =~ "restricted_session"
        assert get_resp_header(response, "location") == []
      end

      # No handle was persisted for either rejected attempt, and a
      # restricted session cannot settle a handle minted by the real one.
      consent = get_consent(token, client, challenge)
      handle = extract_hidden(consent.resp_body, "handle")
      csrf = extract_hidden(consent.resp_body, "_csrf_token")

      hijack =
        post_decision(restricted["token"], %{
          "handle" => handle,
          "_csrf_token" => csrf,
          "decision" => "approve"
        })

      assert hijack.status == 403
      assert get_resp_header(hijack, "location") == []
    end
  end

  describe "POST /oauth2/authorize" do
    test "approve issues a code on the registered redirect_uri that the token endpoint accepts",
         %{session_token: token, client: client, user: user} do
      attach_request_telemetry()
      {response, verifier} = approve_flow(token, client)

      assert response.status == 302
      settle_receive({:idp_request, %{count: 1}, %{endpoint: :authorize, outcome: :ok}})
      assert [location] = get_resp_header(response, "location")
      assert String.starts_with?(location, @redirect_uri)

      %{"code" => code, "state" => "opaque-state"} =
        URI.decode_query(URI.parse(location).query)

      token_response =
        conn(
          :post,
          "/oauth2/token",
          URI.encode_query(%{
            "grant_type" => "authorization_code",
            "client_id" => client.id,
            "code" => code,
            "redirect_uri" => @redirect_uri,
            "code_verifier" => verifier
          })
        )
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> call()

      assert token_response.status == 200
      body = Jason.decode!(token_response.resp_body)
      assert is_binary(body["id_token"])

      %{"keys" => [jwk_map]} =
        Jason.decode!(call(conn(:get, "/.well-known/jwks.json")).resp_body)

      jwk = JOSE.JWK.from_map(jwk_map)
      assert {true, jwt, _jws} = JOSE.JWT.verify_strict(jwk, ["RS256"], body["id_token"])
      assert jwt.fields["sub"] == user["id"]
      assert jwt.fields["nonce"] == "consent-nonce"
    end

    test "deny bounces back with access_denied and no code", %{
      session_token: token,
      client: client
    } do
      attach_request_telemetry()
      {_verifier, challenge} = pkce_pair()
      consent = get_consent(token, client, challenge)
      handle = extract_hidden(consent.resp_body, "handle")
      csrf = extract_hidden(consent.resp_body, "_csrf_token")

      response =
        post_decision(token, %{
          "handle" => handle,
          "_csrf_token" => csrf,
          "decision" => "deny"
        })

      assert response.status == 302
      assert [location] = get_resp_header(response, "location")
      assert String.starts_with?(location, @redirect_uri)
      assert location =~ "error=access_denied"
      refute location =~ "code="

      # Rendering the consent page is the one ok outcome here; the deny
      # 302 itself must count as rejected, never ok (review finding on
      # this PR).
      settle_receive({:idp_request, %{count: 1}, %{endpoint: :authorize, outcome: :ok}})
      settle_receive({:idp_request, %{count: 1}, %{endpoint: :authorize, outcome: :rejected}})
      refute_received {:idp_request, _measurements, %{endpoint: :authorize, outcome: _any}}
    end

    test "a handle cannot be consumed twice", %{session_token: token, client: client} do
      {_verifier, challenge} = pkce_pair()
      consent = get_consent(token, client, challenge)
      handle = extract_hidden(consent.resp_body, "handle")
      csrf = extract_hidden(consent.resp_body, "_csrf_token")

      params = %{"handle" => handle, "_csrf_token" => csrf, "decision" => "approve"}

      assert post_decision(token, params).status == 302

      replay = post_decision(token, params)
      assert replay.status == 400
      assert replay.resp_body =~ "expired"
      assert get_resp_header(replay, "location") == []
    end

    test "another user's session cannot consume the handle", %{
      session_token: token,
      client: client
    } do
      {_verifier, challenge} = pkce_pair()
      consent = get_consent(token, client, challenge)
      handle = extract_hidden(consent.resp_body, "handle")
      csrf = extract_hidden(consent.resp_body, "_csrf_token")

      {:ok, other} = Comma.Accounts.get_or_create_user_by_email("other-user@example.com")
      {:ok, other_session} = Comma.Accounts.create_session(other["id"])

      response =
        post_decision(other_session["token"], %{
          "handle" => handle,
          "_csrf_token" => csrf,
          "decision" => "approve"
        })

      assert response.status == 400
      assert get_resp_header(response, "location") == []
    end

    test "a wrong CSRF token burns the handle and never redirects", %{
      session_token: token,
      client: client
    } do
      {_verifier, challenge} = pkce_pair()
      consent = get_consent(token, client, challenge)
      handle = extract_hidden(consent.resp_body, "handle")

      response =
        post_decision(token, %{
          "handle" => handle,
          "_csrf_token" => "forged-token",
          "decision" => "approve"
        })

      assert response.status == 400
      assert get_resp_header(response, "location") == []

      # The handle is burned: even the honest CSRF token cannot revive it.
      csrf = extract_hidden(consent.resp_body, "_csrf_token")

      retry =
        post_decision(token, %{
          "handle" => handle,
          "_csrf_token" => csrf,
          "decision" => "approve"
        })

      assert retry.status == 400
    end

    test "cross-site posts are rejected before any state changes", %{
      session_token: token,
      client: client
    } do
      {_verifier, challenge} = pkce_pair()
      consent = get_consent(token, client, challenge)
      handle = extract_hidden(consent.resp_body, "handle")
      csrf = extract_hidden(consent.resp_body, "_csrf_token")

      params = %{"handle" => handle, "_csrf_token" => csrf, "decision" => "approve"}

      wrong_origin = post_decision(token, params, origin: "https://attacker.example.com")
      assert wrong_origin.status == 400
      assert get_resp_header(wrong_origin, "location") == []

      missing_origin = post_decision(token, params, origin: nil)
      assert missing_origin.status == 400

      cross_site = post_decision(token, params, sec_fetch_site: "cross-site")
      assert cross_site.status == 400

      # The handle survived the rejected attempts and still works.
      assert post_decision(token, params).status == 302
    end
  end

  describe "logged-out resume flow" do
    defp stash(client, challenge, overrides \\ %{}) do
      response =
        conn(:get, "/oauth2/authorize", authorize_params(client, challenge, overrides))
        |> call()

      assert response.status == 302
      [location] = get_resp_header(response, "location")

      %{"oauth_handle" => handle} =
        location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      handle
    end

    defp resume(handle, session_token) do
      conn(:get, "/oauth2/authorize", %{"resume" => handle})
      |> with_session(session_token)
      |> call()
    end

    test "resume renders consent and the full flow completes",
         %{client: client, session_token: token, user: user} do
      {verifier, challenge} = pkce_pair()
      handle = stash(client, challenge)

      response = resume(handle, token)
      assert response.status == 200
      assert response.resp_body =~ "VibeSketch"

      # The stashed row is burned; consent runs on a fresh user-bound handle.
      assert :error = Comma.OauthIdp.AuthorizeRequests.consume_anonymous(handle)
      consent_handle = extract_hidden(response.resp_body, "handle")
      csrf = extract_hidden(response.resp_body, "_csrf_token")
      assert consent_handle != handle

      approve =
        post_decision(token, %{
          "decision" => "approve",
          "handle" => consent_handle,
          "_csrf_token" => csrf
        })

      assert approve.status == 302
      [location] = get_resp_header(approve, "location")
      redirect_uri = URI.parse(location)
      assert "https://#{redirect_uri.host}#{redirect_uri.path}" == @redirect_uri
      %{"code" => code, "state" => "opaque-state"} = URI.decode_query(redirect_uri.query)

      token_response =
        conn(
          :post,
          "/oauth2/token",
          URI.encode_query(%{
            "grant_type" => "authorization_code",
            "client_id" => client.id,
            "code" => code,
            "redirect_uri" => @redirect_uri,
            "code_verifier" => verifier
          })
        )
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> call()

      assert token_response.status == 200
      body = Jason.decode!(token_response.resp_body)

      assert {true, jwt, _jws} =
               JOSE.JWT.verify_strict(
                 JOSE.JWK.from_map(
                   hd(Jason.decode!(call(conn(:get, "/.well-known/jwks.json")).resp_body)["keys"])
                 ),
                 ["RS256"],
                 body["id_token"]
               )

      assert jwt.fields["sub"] == user["id"]
      assert jwt.fields["nonce"] == "consent-nonce"
    end

    test "restricted sessions cannot resume", %{client: client, user: user} do
      {_verifier, challenge} = pkce_pair()
      handle = stash(client, challenge)

      {:ok, restricted} =
        Comma.Accounts.create_session(user["id"],
          session_source: "ops_api",
          restricted: true,
          ttl_seconds: 600
        )

      response = resume(handle, restricted["token"])
      assert response.status == 403
      assert response.resp_body =~ "restricted_session"
    end
  end
end
