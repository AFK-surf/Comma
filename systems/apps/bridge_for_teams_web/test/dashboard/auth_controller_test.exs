defmodule BridgeForTeamsWeb.Dashboard.AuthControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{
    AccountRecovery,
    Accounts,
    Auth,
    Memberships,
    Observability,
    OrgCreationInvites,
    Orgs,
    Repo
  }

  alias BridgeForTeams.Auth.{Feishu, OIDC}
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.Schema.{OrgMembership, OrgSsoIdentity}
  alias BridgeForTeamsWeb.Dashboard.Auth, as: DashAuth

  @org_icon "data:image/png;base64,iVBORw0KGgo="

  setup do
    previous = Application.get_env(:bridge_for_teams_web, :public_base_url)
    previous_impersonator = Application.get_env(:bridge_for_teams_web, :impersonator_org_slug)

    on_exit(fn ->
      if previous do
        Application.put_env(:bridge_for_teams_web, :public_base_url, previous)
      else
        Application.delete_env(:bridge_for_teams_web, :public_base_url)
      end

      if previous_impersonator do
        Application.put_env(:bridge_for_teams_web, :impersonator_org_slug, previous_impersonator)
      else
        Application.delete_env(:bridge_for_teams_web, :impersonator_org_slug)
      end
    end)
  end

  test "OIDC start uses the configured public base URL for the callback", %{conn: conn} do
    org = org_fixture()

    {:ok, _sso} =
      Orgs.upsert_sso_connection(org.id, %{
        "issuer" => "https://idp.test",
        "client_id" => "client-public-base",
        "client_secret" => "secret",
        "default_role" => "member"
      })

    Application.put_env(
      :bridge_for_teams_web,
      :public_base_url,
      "https://teams-staging.bridge.surf/"
    )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/auth/start", %{"org_slug" => org.slug})

    location = redirected_to(conn)
    assert location =~ "https://idp.test/authorize?"

    assert %{"redirect_uri" => "https://teams-staging.bridge.surf/auth/callback"} =
             URI.decode_query(URI.parse(location).query)
  end

  test "OIDC callback rejects mismatched state", %{conn: conn} do
    org = org_fixture()

    {:ok, _sso} =
      Orgs.upsert_sso_connection(org.id, %{
        "issuer" => "https://idp.test",
        "client_id" => "client-state",
        "client_secret" => "secret",
        "default_role" => "member"
      })

    OIDC.Fake.script_claims(%{
      "sub" => "state-user",
      "email" => "state-user@example.com",
      "email_verified" => true,
      "name" => "State User"
    })

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{
        oidc_org_id: org.id,
        oidc_state: "expected-state",
        oidc_code_verifier: "verifier"
      })
      |> get("/auth/callback", %{"code" => "authcode", "state" => "wrong-state"})

    assert redirected_to(conn) == "/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Sign-in failed. Please try again."
    assert is_nil(Plug.Conn.get_session(conn, DashAuth.session_token_key()))
    assert {:error, :not_found} = Accounts.get_user_by_email("state-user@example.com")

    assert [event] = Observability.list_events(org.id, domain: "sso")
    assert event.event_type == "sso.login.failed"
    assert event.reason_class == "invalid_state"
    assert event.evidence["stage"] == "state"
    assert event.evidence["provider"] == "generic_oidc"
    refute inspect(event) =~ "wrong-state"
  end

  test "OIDC callback accepts matching state and creates a dashboard session", %{conn: conn} do
    org = org_fixture()

    {:ok, _sso} =
      Orgs.upsert_sso_connection(org.id, %{
        "issuer" => "https://idp.test",
        "client_id" => "client-state-ok",
        "client_secret" => "secret",
        "default_role" => "member"
      })

    OIDC.Fake.script_claims(%{
      "sub" => "state-ok-user",
      "email" => "state-ok-user@example.com",
      "email_verified" => true,
      "name" => "State OK User"
    })

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{
        oidc_org_id: org.id,
        oidc_state: "expected-state",
        oidc_code_verifier: "verifier"
      })
      |> get("/auth/callback", %{"code" => "authcode", "state" => "expected-state"})

    assert_remember_login_org_page(conn, org)
    assert {:ok, user} = Accounts.get_user_by_email("state-ok-user@example.com")
    assert {:ok, "member"} = Memberships.org_role(org.id, user.id)

    token = Plug.Conn.get_session(conn, DashAuth.session_token_key())
    assert {:ok, %{user_id: user_id}} = Sessions.fetch(token)
    assert user_id == user.id
  end

  # With magic-link delivery configured (the test env injects the Fake), an
  # unknown slug falls back to the email form — the same place as a real
  # SSO-less org, so the response still doesn't reveal whether the org exists.
  # `magic_link_login_test.exs` covers the unconfigured-delivery variant that
  # keeps the historical ambiguous error.
  test "OIDC start falls back to the email login form for an unknown org slug", %{conn: conn} do
    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/auth/start", %{"org_slug" => "does-not-exist"})

    assert redirected_to(conn) == "/auth/email?o=does-not-exist"
  end

  test "OIDC start falls back to the email login form when SSO is not configured", %{conn: conn} do
    org = org_fixture()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/auth/start", %{"org_slug" => org.slug})

    assert redirected_to(conn) == "/auth/email?" <> URI.encode_query(%{"o" => org.slug})

    assert [event] = Observability.list_events(org.id, domain: "sso")
    assert event.event_type == "sso.login.failed"
    assert event.reason_class == "no_sso_connection"
    assert event.resource_type == "organization"
    assert event.resource_id == org.id
    assert event.evidence["stage"] == "authorize"

    conn =
      conn
      |> recycle()
      |> get("/auth/email", %{"o" => org.slug})

    assert html_response(conn, 200) =~ "Sign in with email"
  end

  test "invite signup creates org, owner account, and dashboard session", %{conn: conn} do
    {:ok, %{code: code}} =
      OrgCreationInvites.create_invite_code(
        org_name: "Founder Co",
        org_slug: "founder-co"
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/signup", %{
        "signup" => %{
          "invite_code" => code,
          "email" => "founder@example.com",
          "name" => "Founder",
          "org_name" => "Forged Co",
          "org_slug" => "forged-co"
        }
      })

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Organization created."

    assert {:ok, user} = Accounts.get_user_by_email("founder@example.com")
    assert {:ok, org} = Orgs.get_org_by_slug("founder-co")
    assert org.name == "Founder Co"
    assert {:error, :not_found} = Orgs.get_org_by_slug("forged-co")
    assert {:ok, "owner"} = Memberships.org_role(org.id, user.id)

    token = Plug.Conn.get_session(conn, DashAuth.session_token_key())
    assert {:ok, %{user_id: user_id}} = Sessions.fetch(token)
    assert user_id == user.id

    assert [invite_audit] =
             Observability.list_audit_logs(org.id,
               action: "org_creation_invite.redeemed"
             )

    assert invite_audit.actor_user_id == user.id
    assert invite_audit.resource_type == "organization"
    assert invite_audit.resource_id == org.id
    assert invite_audit.resource_label == "Founder Co"
    assert invite_audit.result == "ok"
    assert invite_audit.metadata["source"] == "signup"
    refute inspect(invite_audit.metadata) =~ code

    assert [member_audit] =
             Observability.list_audit_logs(org.id,
               action: "org_member.granted",
               resource_type: "org_member"
             )

    assert member_audit.actor_user_id == user.id
    assert member_audit.resource_id == user.id
    assert member_audit.request_id == invite_audit.request_id
  end

  test "invite signup form preloads the invite organization with a fixed slug", %{conn: conn} do
    {:ok, %{code: code}} =
      OrgCreationInvites.create_invite_code(
        org_name: "Prefilled Co",
        org_slug: "prefilled-co"
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> get("/signup", %{"code" => code})

    html = html_response(conn, 200)
    assert html =~ ~s(name="signup[invite_code]")
    assert html =~ ~s(value="#{code}")
    assert html =~ ~s(name="signup[org_name]")
    assert html =~ ~s(value="Prefilled Co")
    assert html =~ ~s(name="signup[org_slug]")
    assert html =~ ~s(value="prefilled-co")
    assert html =~ "readonly"
  end

  test "invite signup keeps the form public and rejects bad codes", %{conn: conn} do
    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/signup", %{
        "signup" => %{
          "invite_code" => "missing-code",
          "email" => "founder@example.com",
          "org_name" => "Founder Co",
          "org_slug" => "founder-co"
        }
      })

    assert html_response(conn, 200) =~ "Invite code or signup details could not be used."
    assert {:error, :not_found} = Accounts.get_user_by_email("founder@example.com")
    assert {:error, :not_found} = Orgs.get_org_by_slug("founder-co")
  end

  test "recovery link signs into an existing account once", %{conn: conn} do
    user = user_fixture(email: "recover-web@example.com")
    {:ok, %{token: recovery_token}} = AccountRecovery.create_recovery_link(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> get("/auth/recovery", %{"token" => recovery_token})

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Signed in with recovery link."

    session_token = Plug.Conn.get_session(conn, DashAuth.session_token_key())
    assert {:ok, %{user_id: user_id}} = Sessions.fetch(session_token)
    assert user_id == user.id

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> get("/auth/recovery", %{"token" => recovery_token})

    assert redirected_to(conn) == "/login"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Recovery link is invalid, expired, or already used."

    refute Plug.Conn.get_session(conn, DashAuth.session_token_key())
  end

  test "impersonator org admin can switch dashboard session to any user", %{conn: conn} do
    org = org_fixture(slug: "impersonators")
    admin = user_fixture(email: "admin@example.com")
    target = user_fixture(email: "target@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, admin.id, "admin")
    Application.put_env(:bridge_for_teams_web, :impersonator_org_slug, org.slug)

    conn =
      conn
      |> log_in_user(admin)
      |> post("/impersonate", %{"impersonate" => %{"target" => target.email}})

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Now impersonating target@example.com"

    token = Plug.Conn.get_session(conn, DashAuth.session_token_key())
    assert {:ok, %{user_id: target_id}} = Sessions.fetch(token)
    assert target_id == target.id

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "user.impersonation.started")

    assert audit.actor_user_id == admin.id
    assert audit.resource_type == "user"
    assert audit.resource_id == target.id
    assert audit.resource_label == "Impersonated user"
    assert audit.result == "ok"
    assert audit.metadata["target_lookup"] == "email"
    assert audit.metadata["target_configured"] in [true, "true"]
    assert audit.metadata["target_found"] in [true, "true"]
    refute inspect(audit) =~ "target@example.com"

    assert [event] = Observability.list_events(org.id, audit_log_id: audit.id)
    assert event.domain == "audit"
    assert event.event_type == "audit.user.impersonation.started"
    assert event.correlation_id == audit.request_id
  end

  test "ordinary member of impersonator org cannot impersonate", %{conn: conn} do
    org = org_fixture(slug: "impersonators")
    member = user_fixture(email: "member@example.com")
    target = user_fixture(email: "target@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    Application.put_env(:bridge_for_teams_web, :impersonator_org_slug, org.slug)

    conn =
      conn
      |> log_in_user(member)
      |> post("/impersonate", %{"impersonate" => %{"target" => target.email}})

    assert redirected_to(conn) == "/"

    token = Plug.Conn.get_session(conn, DashAuth.session_token_key())
    assert {:ok, %{user_id: member_id}} = Sessions.fetch(token)
    assert member_id == member.id

    assert [audit] =
             Observability.list_audit_logs(org.id,
               action: "user.impersonation.started",
               result: "denied"
             )

    assert audit.actor_user_id == member.id
    assert audit.resource_type == "user"
    assert audit.resource_label == "Impersonation target"
    assert audit.reason_class == "forbidden"
    assert audit.metadata["surface"] == "impersonation"
    assert audit.metadata["target_lookup"] == "email"
    assert audit.metadata["target_configured"] in [true, "true"]
    refute inspect(audit) =~ "target@example.com"
  end

  test "impersonator admin missing target records failed audit without target input", %{
    conn: conn
  } do
    org = org_fixture(slug: "impersonators")
    admin = user_fixture(email: "admin@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, admin.id, "admin")
    Application.put_env(:bridge_for_teams_web, :impersonator_org_slug, org.slug)

    conn =
      conn
      |> log_in_user(admin)
      |> post("/impersonate", %{"impersonate" => %{"target" => "ghost@example.com"}})

    assert html_response(conn, 200) =~ "User not found."

    token = Plug.Conn.get_session(conn, DashAuth.session_token_key())
    assert {:ok, %{user_id: admin_id}} = Sessions.fetch(token)
    assert admin_id == admin.id

    assert [audit] =
             Observability.list_audit_logs(org.id,
               action: "user.impersonation.started",
               result: "failed"
             )

    assert audit.actor_user_id == admin.id
    assert audit.resource_type == "user"
    assert audit.resource_label == "Impersonation target"
    assert audit.reason_class == "not_found"
    assert audit.metadata["surface"] == "impersonation"
    assert audit.metadata["target_lookup"] == "email"
    assert audit.metadata["target_configured"] in [true, "true"]
    refute inspect(audit) =~ "ghost@example.com"
  end

  test "impersonation route is hidden when no impersonator org is configured", %{conn: conn} do
    Application.delete_env(:bridge_for_teams_web, :impersonator_org_slug)
    user = user_fixture(email: "admin@example.com")

    conn =
      conn
      |> log_in_user(user)
      |> get("/impersonate")

    assert conn.status == 404
  end

  test "OIDC callback rejects a mismatched state before creating a session", %{conn: conn} do
    org = org_with_sso!()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/auth/start", %{"org_slug" => org.slug})

    assert redirected_to(conn) =~ "https://idp.test/authorize?"

    conn =
      conn
      |> recycle()
      |> get("/auth/callback", %{"code" => "authcode", "state" => "wrong-state"})

    assert redirected_to(conn) == "/login"
    refute get_session(conn, DashAuth.session_token_key())
    assert {:error, :not_found} = Accounts.get_user_by_email("user@example.com")
  end

  test "OIDC callback accepts the stored state and completes login", %{conn: conn} do
    org = org_with_sso!()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/auth/start", %{"org_slug" => org.slug})

    location = redirected_to(conn)
    assert %{"state" => state} = URI.decode_query(URI.parse(location).query)

    conn =
      conn
      |> recycle()
      |> get("/auth/callback", %{"code" => "authcode", "state" => state})

    assert_remember_login_org_page(conn, org)
    assert get_session(conn, DashAuth.session_token_key())
    assert {:ok, user} = Accounts.get_user_by_email("user@example.com")
    assert user.name == "Fake User"
  end

  test "OIDC callback remembers every SSO-enabled org for the authenticated user", %{conn: conn} do
    org = org_with_sso!()
    {:ok, org} = Orgs.update_org(org, %{icon: @org_icon})

    extra_org = org_fixture(name: "Previously Used Org", slug: "previously-used-org")
    no_sso_org = org_fixture(name: "No SSO Org", slug: "no-sso-org")

    {:ok, _sso} =
      Orgs.upsert_sso_connection(extra_org.id, %{
        "issuer" => "https://idp-extra.test",
        "client_id" => "client-extra",
        "client_secret" => "secret",
        "default_role" => "member"
      })

    user = user_fixture(email: "user@example.com", name: "Existing User")
    {:ok, _} = Memberships.put_org_member(extra_org.id, user.id, "member")
    {:ok, _} = Memberships.put_org_member(no_sso_org.id, user.id, "member")

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/auth/start", %{"org_slug" => org.slug})

    location = redirected_to(conn)
    assert %{"state" => state} = URI.decode_query(URI.parse(location).query)

    conn =
      conn
      |> recycle()
      |> get("/auth/callback", %{"code" => "authcode", "state" => state})

    assert_remember_login_orgs_page(conn, [org, extra_org])
    refute html_response(conn, 200) =~ no_sso_org.slug
    refute html_response(conn, 200) =~ no_sso_org.name
    assert {:ok, "member"} = Memberships.org_role(org.id, user.id)
  end

  test "OIDC callback returns to a local device-login path after login", %{conn: conn} do
    org = org_with_sso!()
    return_to = "/cli/device-login/ABCDEFGH"

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/auth/start", %{"org_slug" => org.slug, "return_to" => return_to})

    location = redirected_to(conn)
    assert %{"state" => state} = URI.decode_query(URI.parse(location).query)

    conn =
      conn
      |> recycle()
      |> get("/auth/callback", %{"code" => "authcode", "state" => state})

    assert redirected_to(conn) == return_to
    assert get_session(conn, DashAuth.session_token_key())
  end

  test "OIDC callback ignores external return_to values", %{conn: conn} do
    org = org_with_sso!()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/auth/start", %{
        "org_slug" => org.slug,
        "return_to" => "https://evil.example.com/cli/device-login/ABCDEFGH"
      })

    location = redirected_to(conn)
    assert %{"state" => state} = URI.decode_query(URI.parse(location).query)

    conn =
      conn
      |> recycle()
      |> get("/auth/callback", %{"code" => "authcode", "state" => state})

    assert_remember_login_org_page(conn, org)
    assert get_session(conn, DashAuth.session_token_key())
  end

  test "login page disables stored org shortcuts whenever an org slug is supplied", %{conn: conn} do
    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> get("/login", %{"o" => "stale-or-unknown"})

    html = html_response(conn, 200)

    assert html =~ ~s(id="remembered-org-login")
    assert html =~ ~s(data-disabled="true")
    assert html =~ ~s(name="org_slug")
    refute html =~ ~s(data-login-orgs=)
  end

  test "login page exposes localStorage-backed org shortcuts after logout", %{conn: conn} do
    org = org_with_sso!()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/auth/start", %{"org_slug" => org.slug})

    assert %{"state" => state} = URI.decode_query(URI.parse(redirected_to(conn)).query)

    conn =
      conn
      |> recycle()
      |> get("/auth/callback", %{"code" => "authcode", "state" => state})

    assert_remember_login_org_page(conn, org)
    assert get_session(conn, DashAuth.session_token_key())

    logout_conn =
      conn
      |> recycle()
      |> delete("/logout")

    assert redirected_to(logout_conn) == "/login"
    assert logout_conn.private[:plug_session_info] == :drop

    conn =
      logout_conn
      |> recycle()
      |> get("/login")

    html = html_response(conn, 200)
    refute get_session(conn, DashAuth.session_token_key())
    assert html =~ ~s(id="remembered-org-login")
    assert html =~ ~s(id="remembered-org-list")
    assert html =~ ~s(data-storage-key="bridge_for_teams:login_orgs")
    assert html =~ ~s(data-legacy-storage-key="bridge_for_teams:last_login_org")
    assert html =~ "localStorage.getItem"
    assert html =~ "orgLoginForm"
    assert html =~ "document.createElement(\"img\")"
    refute html =~ ~s(data-login-orgs=)
  end

  test "login page passes local return_to through remembered org shortcut forms", %{conn: conn} do
    return_to = "/cli/device-login/ABCDEFGH"

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> get("/login", %{"return_to" => return_to})

    html = html_response(conn, 200)

    assert html =~ ~s(id="remembered-org-login")
    assert html =~ ~s(data-disabled="false")
    assert html =~ ~s(data-return-to="#{return_to}")
    assert html =~ ~s(const returnTo = section.dataset.returnTo || "";)
    assert html =~ ~s(returnToInput.name = "return_to";)
    assert html =~ ~s(returnToInput.value = labels.returnTo;)
  end

  test "Feishu start uses client id and configured public callback URL", %{conn: conn} do
    org = org_with_feishu_sso!("feishu-public-base")

    Application.put_env(
      :bridge_for_teams_web,
      :public_base_url,
      "https://teams-staging.bridge.surf/"
    )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/auth/start", %{"org_slug" => org.slug})

    location = redirected_to(conn)
    assert location =~ "https://feishu.test/oauth/authorize?"

    assert %{
             "client_id" => "feishu-public-base",
             "redirect_uri" => "https://teams-staging.bridge.surf/auth/callback",
             "state" => state
           } = URI.decode_query(URI.parse(location).query)

    assert String.starts_with?(state, "fake-feishu-state-")
  end

  test "Feishu callback completes dashboard login for a phone-only user", %{conn: conn} do
    org = org_with_feishu_sso!("feishu-phone-controller")

    Feishu.Fake.script_identity(%{
      "user_id" => "feishu-controller-phone-only",
      "mobile" => "+10000000005",
      "display_name" => "Feishu Phone Controller",
      "profile" => %{"source" => "dashboard-fake"}
    })

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/auth/start", %{"org_slug" => org.slug})

    assert %{"state" => state} = URI.decode_query(URI.parse(redirected_to(conn)).query)

    conn =
      conn
      |> recycle()
      |> get("/auth/callback", %{"code" => "feishu-code", "state" => state})

    assert_remember_login_org_page(conn, org)
    token = get_session(conn, DashAuth.session_token_key())
    assert is_binary(token)

    assert {:ok, user} = Auth.authenticate_session(token)
    assert user.email == nil
    assert user.name == "Feishu Phone Controller"

    identity =
      Repo.get_by!(OrgSsoIdentity,
        org_id: org.id,
        provider: "feishu",
        provider_subject_type: "user_id",
        provider_subject: "feishu-controller-phone-only"
      )

    assert identity.user_id == user.id
    assert identity.email == nil
    assert identity.mobile == "+10000000005"

    membership = Repo.get_by!(OrgMembership, org_id: org.id, user_id: user.id)
    assert membership.role == "member"
  end

  defp org_with_sso! do
    org = org_fixture()

    {:ok, _sso} =
      Orgs.upsert_sso_connection(org.id, %{
        "issuer" => "https://idp.test",
        "client_id" => "client-state",
        "client_secret" => "secret",
        "default_role" => "member"
      })

    org
  end

  defp assert_remember_login_org_page(conn, org) do
    assert_remember_login_orgs_page(conn, [org])
  end

  defp assert_remember_login_orgs_page(conn, orgs) do
    html = html_response(conn, 200)

    assert html =~ ~s(id="remember-login-orgs")
    assert html =~ ~s(data-storage-key="bridge_for_teams:login_orgs")
    assert html =~ ~s(data-login-orgs=)

    for org <- orgs do
      assert html =~ org.slug
      assert html =~ org.name

      if org.icon do
        assert html =~ org.icon
      end
    end

    assert html =~ "localStorage.setItem"
    assert html =~ "window.location.replace"

    html
  end

  defp org_with_feishu_sso!(client_id) do
    org = org_fixture()

    {:ok, _sso} =
      Orgs.upsert_sso_connection(org.id, %{
        "provider" => "feishu",
        "client_id" => client_id,
        "client_secret" => "secret",
        "default_role" => "member",
        "provider_config" => %{"scope" => "contact:user.base:readonly"}
      })

    org
  end
end
