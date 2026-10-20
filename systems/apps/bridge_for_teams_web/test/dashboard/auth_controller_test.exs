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

  alias BridgeForTeams.Auth.{Feishu, Lark, OIDC}
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.Schema.{OrgMembership, OrgSsoIdentity}
  alias BridgeForTeamsWeb.Dashboard.Auth, as: DashAuth

  setup do
    previous = SystemsRuntime.get_env(:bridge_for_teams_web, :public_base_url)
    previous_impersonator = SystemsRuntime.get_env(:bridge_for_teams_web, :impersonator_org_slug)

    on_exit(fn ->
      if previous do
        SystemsRuntime.put_env(:bridge_for_teams_web, :public_base_url, previous)
      else
        SystemsRuntime.delete_env(:bridge_for_teams_web, :public_base_url)
      end

      if previous_impersonator do
        SystemsRuntime.put_env(
          :bridge_for_teams_web,
          :impersonator_org_slug,
          previous_impersonator
        )
      else
        SystemsRuntime.delete_env(:bridge_for_teams_web, :impersonator_org_slug)
      end
    end)
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
    SystemsRuntime.put_env(:bridge_for_teams_web, :impersonator_org_slug, org.slug)

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
    SystemsRuntime.put_env(:bridge_for_teams_web, :impersonator_org_slug, org.slug)

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

  test "impersonation route is hidden when no impersonator org is configured", %{conn: conn} do
    SystemsRuntime.delete_env(:bridge_for_teams_web, :impersonator_org_slug)
    user = user_fixture(email: "admin@example.com")

    conn =
      conn
      |> log_in_user(user)
      |> get("/impersonate")

    assert conn.status == 404
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

  test "Lark sign-in starts from the organization's login page and ends in a session", %{
    conn: conn
  } do
    org = org_fixture()

    {:ok, _sso} =
      Orgs.upsert_sso_connection(org.id, %{
        "provider" => "lark",
        "client_id" => "cli_lark_controller",
        "client_secret" => "secret",
        "default_role" => "admin"
      })

    login = conn |> get("/login", %{"o" => org.slug}) |> html_response(200)
    assert login =~ "Sign in with Lark"
    refute login =~ "Continue with SSO"

    Lark.Fake.script_identity(%{
      "union_id" => "on-lark-controller",
      "open_id" => "ou-lark-controller",
      "display_name" => "Lark Controller",
      "profile" => %{"source" => "dashboard-fake"}
    })

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> post("/auth/start", %{"org_slug" => org.slug})

    location = redirected_to(conn)
    assert location =~ "https://lark.test/oauth/authorize?"
    assert %{"state" => state} = URI.decode_query(URI.parse(location).query)

    conn =
      conn
      |> recycle()
      |> get("/auth/callback", %{"code" => "lark-code", "state" => state})

    assert_remember_login_org_page(conn, org)
    token = get_session(conn, DashAuth.session_token_key())

    assert {:ok, user} = Auth.authenticate_session(token)
    assert user.email == nil
    assert user.name == "Lark Controller"

    identity =
      Repo.get_by!(OrgSsoIdentity,
        org_id: org.id,
        provider: "lark",
        provider_subject_type: "union_id",
        provider_subject: "on-lark-controller"
      )

    assert identity.user_id == user.id
    assert Repo.get_by!(OrgMembership, org_id: org.id, user_id: user.id).role == "admin"
  end

  test "the login page of an organization on another provider keeps the SSO button", %{
    conn: conn
  } do
    org = org_with_feishu_sso!("feishu-login-label")

    login = conn |> get("/login", %{"o" => org.slug}) |> html_response(200)
    assert login =~ "Continue with SSO"
    refute login =~ "Sign in with Lark"
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
