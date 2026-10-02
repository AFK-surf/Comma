defmodule CommaWeb.OauthIdpConsentTest do
  # async: false — the KEK and endpoint flag live in application config.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Boruta.Ecto.Admin

  @opts CommaWeb.Router.init([])
  @redirect_uri "https://vibe.example.com/callback"
  @issuer "https://comma.test"

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)

    previous_kek = Application.get_env(:comma_core, :oauth_idp)
    Application.put_env(:comma_core, :oauth_idp, kek: :crypto.hash(:sha256, "idp-consent-kek"))

    previous_flag = Application.get_env(:comma_web, :oauth_idp_enabled)
    Application.put_env(:comma_web, :oauth_idp_enabled, true)

    # Generous budgets: this suite exercises the consent flow, not the
    # limiter, and Plug.Test conns all share the default peer IP.
    previous_rate_limit = Application.get_env(:comma_core, :oauth_idp_rate_limit)

    Application.put_env(:comma_core, :oauth_idp_rate_limit,
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

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp attach_request_telemetry do
    handler_id = "idp-consent-#{inspect(make_ref())}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:comma_product, :oauth_idp, :request],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:idp_request, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp call(conn), do: CommaWeb.Router.call(conn, @opts)

  defp with_session(conn, token) do
    put_req_header(conn, "cookie", "#{CommaWeb.SessionCookie.cookie_name()}=#{token}")
  end

  defp pkce_pair do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
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
    # Regression for the widen_oauth_token_request_params migration:
    # RFC 6749 puts no bound on `state` (Auth.js sends an ~800-byte JWE)
    # and OIDC none on `nonce`; Boruta's stock varchar(255) columns made
    # a stock NextAuth login crash the approve step with a database
    # error.
    test "an Auth.js-sized state and nonce survive the full approve flow",
         %{session_token: token, client: client} do
      long_state = String.duplicate("s", 800)
      long_nonce = String.duplicate("n", 400)
      {_verifier, challenge} = pkce_pair()

      consent =
        get_consent(token, client, challenge, %{
          "state" => long_state,
          "nonce" => long_nonce
        })

      assert consent.status == 200
      handle = extract_hidden(consent.resp_body, "handle")
      csrf = extract_hidden(consent.resp_body, "_csrf_token")

      response =
        post_decision(token, %{
          "handle" => handle,
          "_csrf_token" => csrf,
          "decision" => "approve"
        })

      assert response.status == 302
      [location] = Plug.Conn.get_resp_header(response, "location")
      redirect = URI.parse(location)
      query = URI.decode_query(redirect.query)
      assert query["state"] == long_state
      assert is_binary(query["code"])
    end
  end

  describe "feature flag off" do
    setup do
      Application.put_env(:comma_web, :oauth_idp_enabled, false)
      :ok
    end

    test "authorize answers 404 on both methods", %{session_token: token, client: client} do
      {_verifier, challenge} = pkce_pair()
      assert get_consent(token, client, challenge).status == 404
      assert post_decision(token, %{"decision" => "approve"}).status == 404
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

    test "forbids intermediaries from rewriting the page body", %{
      session_token: token,
      client: client
    } do
      # Not hardening — a fix. Cloudflare's Email Address Obfuscation
      # rewrote the user's address on this page into a `[email protected]`
      # placeholder and injected a decoder script to restore it, which the
      # page's own `default-src 'none'` CSP blocked; the address was then
      # permanently unreadable on the one screen whose job is showing which
      # account is being handed to a third party. `no-transform` (RFC 9111
      # §5.2.2.6) is the documented opt-out, and being standard it also
      # binds proxies and CDNs we do not operate.
      #
      # Scoped to this HTML surface: the JSON endpoints keep plain
      # `no-store` (pinned by oauth_idp_endpoints_test), because rewriting
      # does not target them and RFC 6749 §5.1 fixes the token response's
      # Cache-Control.
      {_verifier, challenge} = pkce_pair()
      response = get_consent(token, client, challenge)

      assert get_resp_header(response, "cache-control") == ["no-store, no-transform"],
             "the consent page must tell intermediaries not to rewrite its body"
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

    test "the CSP names an IPv6 loopback client's origin with brackets",
         %{session_token: token} do
      # The v1 contract admits http://[::1] for local development (RFC §7.2;
      # ClientAdmin.loopback_host?/1). URI.parse strips the brackets — the
      # host comes back as `::1` — while a CSP host-source requires them, so
      # a charset guard written for names and IPv4 silently dropped these
      # clients back to the bare policy and their redirect stayed blocked.
      {:ok, v6_client} =
        Admin.create_client(%{
          name: "V6Loopback",
          redirect_uris: ["http://[::1]:8765/callback"],
          supported_grant_types: ["authorization_code"],
          access_token_ttl: 600,
          authorization_code_ttl: 60,
          id_token_ttl: 600,
          id_token_signature_alg: "RS256",
          pkce: true
        })

      {_verifier, challenge} = pkce_pair()

      consent =
        get_consent(token, v6_client, challenge, %{
          "redirect_uri" => "http://[::1]:8765/callback"
        })

      assert consent.status == 200
      assert [csp] = get_resp_header(consent, "content-security-policy")

      assert csp =~ "form-action 'self' http://[::1]:8765",
             "IPv6 loopback origin must be bracketed in form-action; got: " <> csp
    end

    test "the page's referrer policy never makes the browser send Origin: null",
         %{session_token: token, client: client} do
      # Regression guard for a whole-flow outage that no synthetic test can
      # reach. Under a `no-referrer` policy the Fetch spec has the browser
      # serialize the Origin header of a navigation request as the literal
      # "null" — and the consent form POST is a navigation. The page would
      # then fail its own `require_same_origin/1` check in every real
      # browser, so approve and deny both settle as invalid_request and no
      # authorization can ever complete. Every test here (and the CI canary)
      # supplies `origin` by hand, so these assertions are all that stand
      # between that policy and a fully broken IdP.
      #
      # A document has TWO policy sources and both must be checked. Asserting
      # only the response header is what let the first fix ship broken: the
      # markup still carried `<meta name="referrer" content="no-referrer">`,
      # which the HTML meta-referrer algorithm applies *after* the header,
      # so the browser-observed policy was still no-referrer.
      {_verifier, challenge} = pkce_pair()
      consent = get_consent(token, client, challenge)

      assert get_resp_header(consent, "referrer-policy") == ["same-origin"],
             "response header must not be no-referrer: it makes browsers send Origin: null"

      meta_policies =
        Regex.scan(~r/<meta\s+name="referrer"\s+content="([^"]*)"/i, consent.resp_body)
        |> Enum.map(fn [_full, content] -> content end)

      assert meta_policies == ["same-origin"],
             "the rendered <meta name=\"referrer\"> overrides the response header, so it " <>
               "must state the same policy; got: #{inspect(meta_policies)}"

      # The other half of the coupling: "null" is — and must stay — rejected.
      handle = extract_hidden(consent.resp_body, "handle")
      csrf = extract_hidden(consent.resp_body, "_csrf_token")
      params = %{"handle" => handle, "_csrf_token" => csrf, "decision" => "approve"}

      assert post_decision(token, params, origin: "null").status == 400
      assert post_decision(token, params).status == 302
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

      assert_receive {:idp_request, %{count: 1},
                      %{endpoint: :authorize, outcome: :login_redirect}}

      assert [location] = get_resp_header(response, "location")

      # The redirect goes to the configured frontend origin and carries
      # only the opaque handle — none of the authorization parameters
      # ride along in the URL (RFC §5).
      login_uri = URI.parse(location)
      origin = Application.fetch_env!(:comma_web, :web_cookie_origin)
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
          email: "g-#{System.unique_integer([:positive])}@guest.comma.invalid",
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

    test "scope must equal the fixed v1 set, order-insensitively", %{
      session_token: token,
      client: client
    } do
      {_verifier, challenge} = pkce_pair()

      # Order does not matter.
      reordered = get_consent(token, client, challenge, %{"scope" => "profile openid email"})
      assert reordered.status == 200

      attach_request_telemetry()

      for bad_scope <- ["openid", "openid email", "openid email profile extra", ""] do
        response = get_consent(token, client, challenge, %{"scope" => bad_scope})

        assert response.status == 302, "scope #{inspect(bad_scope)} must bounce"
        assert [location] = get_resp_header(response, "location")
        assert String.starts_with?(location, @redirect_uri)
        assert location =~ "error=invalid_scope"
        assert location =~ "state=opaque-state"

        assert_receive {:idp_request, %{count: 1}, %{endpoint: :authorize, outcome: :rejected}}
      end
    end

    test "a validation error with a trusted redirect_uri bounces back to the app",
         %{session_token: token, client: client} do
      # Missing PKCE challenge: the client and redirect_uri are valid, so
      # the spec sends the error to the app rather than stranding the user.
      response =
        get_consent(token, client, "ignored", %{"code_challenge" => ""})

      assert response.status == 302
      assert [location] = get_resp_header(response, "location")
      assert String.starts_with?(location, @redirect_uri)
      assert location =~ "error="
      assert location =~ "state=opaque-state"
    end
  end

  describe "POST /oauth2/authorize" do
    test "approve issues a code on the registered redirect_uri that the token endpoint accepts",
         %{session_token: token, client: client, user: user} do
      attach_request_telemetry()
      {response, verifier} = approve_flow(token, client)

      assert response.status == 302
      assert_receive {:idp_request, %{count: 1}, %{endpoint: :authorize, outcome: :ok}}
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
      assert_receive {:idp_request, %{count: 1}, %{endpoint: :authorize, outcome: :ok}}
      assert_receive {:idp_request, %{count: 1}, %{endpoint: :authorize, outcome: :rejected}}
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

    test "logged-out prompt=none returns login_required to the vouched redirect, no stash",
         %{client: client} do
      {_verifier, challenge} = pkce_pair()

      response =
        conn(
          :get,
          "/oauth2/authorize",
          authorize_params(client, challenge, %{"prompt" => "none"})
        )
        |> call()

      assert response.status == 302
      [location] = get_resp_header(response, "location")
      uri = URI.parse(location)
      assert "https://#{uri.host}#{uri.path}" == @redirect_uri

      query = URI.decode_query(uri.query)
      assert query["error"] == "login_required"
      assert query["state"] == "opaque-state"

      # Silent auth must not touch the login round trip or storage.
      refute location =~ "/login"
      assert Comma.Repo.aggregate(Comma.OauthIdp.AuthorizeRequests.Request, :count) == 0
    end

    test "logged-in prompt=none returns consent_required (v1 always requires consent)",
         %{client: client, session_token: token} do
      {_verifier, challenge} = pkce_pair()

      response =
        conn(
          :get,
          "/oauth2/authorize",
          authorize_params(client, challenge, %{"prompt" => "none"})
        )
        |> with_session(token)
        |> call()

      assert response.status == 302
      [location] = get_resp_header(response, "location")
      uri = URI.parse(location)
      assert "https://#{uri.host}#{uri.path}" == @redirect_uri

      query = URI.decode_query(uri.query)
      assert query["error"] == "consent_required"
      assert query["state"] == "opaque-state"
      assert Comma.Repo.aggregate(Comma.OauthIdp.AuthorizeRequests.Request, :count) == 0
    end

    test "prompt combining none with other values is invalid_request in both states",
         %{client: client, session_token: token} do
      {_verifier, challenge} = pkce_pair()
      params = authorize_params(client, challenge, %{"prompt" => "none login"})

      for build <- [
            fn -> conn(:get, "/oauth2/authorize", params) end,
            fn -> conn(:get, "/oauth2/authorize", params) |> with_session(token) end
          ] do
        response = build.() |> call()

        assert response.status == 302
        [location] = get_resp_header(response, "location")
        assert URI.decode_query(URI.parse(location).query)["error"] == "invalid_request"
        refute location =~ "/login"
      end

      assert Comma.Repo.aggregate(Comma.OauthIdp.AuthorizeRequests.Request, :count) == 0
    end

    test "prompt=none with an invalid client is a terminal page, never a redirect",
         %{client: client} do
      {_verifier, challenge} = pkce_pair()

      response =
        conn(
          :get,
          "/oauth2/authorize",
          authorize_params(client, challenge, %{
            "prompt" => "none",
            "redirect_uri" => "https://evil.example.com/cb"
          })
        )
        |> call()

      assert response.status != 302
      assert Comma.Repo.aggregate(Comma.OauthIdp.AuthorizeRequests.Request, :count) == 0
    end

    test "logged-out invalid requests settle to the vouched redirect and stash nothing",
         %{client: client} do
      {_verifier, challenge} = pkce_pair()

      # Missing PKCE: the client mandates a code_challenge, so this is
      # an invalid request even though the client and redirect_uri are
      # fine — it must never reach the stash or the login round trip.
      no_pkce =
        conn(
          :get,
          "/oauth2/authorize",
          authorize_params(client, challenge) |> Map.drop(["code_challenge"])
        )
        |> call()

      assert no_pkce.status == 302
      [location] = get_resp_header(no_pkce, "location")
      assert location =~ @redirect_uri
      refute location =~ "/login"
      assert URI.decode_query(URI.parse(location).query)["error"] != nil

      # Unknown scope value: rejected by scope validation, same shape.
      bad_scope =
        conn(
          :get,
          "/oauth2/authorize",
          authorize_params(client, challenge, %{"scope" => "openid email profile admin"})
        )
        |> call()

      assert bad_scope.status == 302
      [scope_location] = get_resp_header(bad_scope, "location")
      assert scope_location =~ @redirect_uri
      refute scope_location =~ "/login"

      assert Comma.Repo.aggregate(Comma.OauthIdp.AuthorizeRequests.Request, :count) == 0
    end

    test "an invalid client stashes nothing and stays on a terminal page", %{client: client} do
      {_verifier, challenge} = pkce_pair()

      response =
        conn(
          :get,
          "/oauth2/authorize",
          authorize_params(client, challenge, %{"redirect_uri" => "https://evil.example.com/cb"})
        )
        |> call()

      assert response.status != 302
      assert Comma.Repo.aggregate(Comma.OauthIdp.AuthorizeRequests.Request, :count) == 0
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

    test "a resume handle is single-use", %{client: client, session_token: token} do
      {_verifier, challenge} = pkce_pair()
      handle = stash(client, challenge)

      assert resume(handle, token).status == 200

      replay = resume(handle, token)
      assert replay.status == 400
      assert replay.resp_body =~ "authorization_request_expired"
    end

    test "resume while still logged out is terminal, not another redirect",
         %{client: client} do
      {_verifier, challenge} = pkce_pair()
      handle = stash(client, challenge)

      response = conn(:get, "/oauth2/authorize", %{"resume" => handle}) |> call()

      assert response.status == 401
      assert response.resp_body =~ "login_required"
      refute get_resp_header(response, "location") != []

      # The handle is not burned by the failed attempt.
      assert {:ok, _request} = Comma.OauthIdp.AuthorizeRequests.consume_anonymous(handle)
    end

    test "unknown and malformed resume handles are indistinguishable expired errors",
         %{session_token: token} do
      for handle <- [Ecto.UUID.generate(), "not-a-uuid"] do
        response = resume(handle, token)
        assert response.status == 400
        assert response.resp_body =~ "authorization_request_expired"
      end
    end

    test "an expired stash cannot be resumed", %{client: client, session_token: token} do
      {_verifier, challenge} = pkce_pair()
      handle = stash(client, challenge)

      import Ecto.Query

      Comma.Repo.update_all(
        from(r in Comma.OauthIdp.AuthorizeRequests.Request, where: r.id == ^handle),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      response = resume(handle, token)
      assert response.status == 400
      assert response.resp_body =~ "authorization_request_expired"
    end

    test "a consent-stage handle cannot be replayed through resume",
         %{client: client, session_token: token} do
      {_verifier, challenge} = pkce_pair()
      consent = get_consent(token, client, challenge)
      assert consent.status == 200
      consent_handle = extract_hidden(consent.resp_body, "handle")

      response = resume(consent_handle, token)
      assert response.status == 400
      assert response.resp_body =~ "authorization_request_expired"
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
