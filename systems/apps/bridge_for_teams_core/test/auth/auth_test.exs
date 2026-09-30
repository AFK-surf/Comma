defmodule BridgeForTeams.AuthTest do
  @moduledoc """
  End-to-end auth-code flow + session lifecycle + JIT provisioning driven by the
  injected `BridgeForTeams.Auth.OIDC.Fake` (no IdP, no salix node). DB-backed via
  the DataCase sandbox.
  """
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.{Auth, Observability}
  alias BridgeForTeams.Auth.{Feishu, OIDC, Sessions}

  alias BridgeForTeams.Schema.{
    ApiKey,
    Organization,
    OrgMembership,
    OrgSsoConnection,
    OrgSsoIdentity,
    User
  }

  setup do
    # Belt-and-braces: the suite configures the Fake, assert it's active.
    assert OIDC.impl() == OIDC.Fake
    assert Feishu.impl() == Feishu.Fake
    :ok
  end

  defp org!(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    tenant_id = "org_#{n}"

    %Organization{}
    |> Organization.changeset(
      Map.merge(
        %{
          name: "Org #{n}",
          slug: "org-#{n}",
          salix_tenant_id: tenant_id,
          billing_account_id: "bridge-ba-#{tenant_id}"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp sso!(org, attrs \\ %{}) do
    base = %{
      org_id: org.id,
      issuer: "https://idp.test",
      client_id: "client-#{System.unique_integer([:positive])}",
      client_secret: "the-secret",
      allowed_domains: [],
      default_role: "member"
    }

    %OrgSsoConnection{}
    |> OrgSsoConnection.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  describe "authorize_url/2" do
    test "builds a redirect for a configured org" do
      org = org!()
      sso!(org)

      assert {:ok, %{url: url, state: state, code_verifier: verifier}} =
               Auth.authorize_url(org.id)

      assert String.contains?(url, "/authorize?")
      assert is_binary(state) and is_binary(verifier)
    end

    test "errors when the org has no SSO connection" do
      org = org!()
      assert {:error, :no_sso_connection} = Auth.authorize_url(org.id)
    end

    test "builds a Feishu redirect for a Feishu SSO org" do
      org = org!()
      sso!(org, %{provider: "feishu", issuer: nil, client_id: "feishu-client"})

      assert {:ok, %{url: url, state: state, code_verifier: nil}} = Auth.authorize_url(org.id)
      assert String.contains?(url, "https://feishu.test/oauth/authorize?")
      assert String.starts_with?(state, "fake-feishu-state-")
    end
  end

  describe "callback/3 (auth-code flow + JIT provisioning)" do
    test "provisions a new user + org membership and returns a session" do
      org = org!()
      sso!(org)

      OIDC.Fake.script_claims(%{
        "sub" => "abc",
        "email" => "New.User@Example.test",
        "email_verified" => true,
        "name" => "New User"
      })

      assert {:ok, %{user: user, token: token, session: session}} =
               Auth.callback(org.id, %{"code" => "authcode"}, code_verifier: "v", device: "web")

      # email lower-cased + persisted
      assert user.email == "new.user@example.test"
      assert user.name == "New User"
      assert Repo.get(User, user.id)

      # org membership created with default role
      m = Repo.get_by(OrgMembership, org_id: org.id, user_id: user.id)
      assert m.role == "member"

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "org_member.granted",
                 resource_type: "org_member"
               )

      assert audit.actor_user_id == user.id
      assert audit.resource_id == user.id
      assert audit.result == "ok"
      assert audit.metadata["source"] == "sso_jit"
      assert audit.metadata["provider"] == "generic_oidc"
      assert audit.metadata["new_role"] == "member"
      refute Map.has_key?(audit.metadata, "email")
      refute Map.has_key?(audit.metadata, "subject")
      refute Map.has_key?(audit.metadata, "provider_subject")
      refute Enum.any?(audit.metadata, fn {_key, value} -> value == "New.User@Example.test" end)
      refute Enum.any?(audit.metadata, fn {_key, value} -> value == "abc" end)

      assert [event] = Observability.list_events(org.id, audit_log_id: audit.id)
      assert event.domain == "audit"
      assert event.event_type == "audit.org_member.granted"
      assert event.correlation_id == audit.request_id

      # session usable
      assert session.user_id == user.id
      assert {:ok, ^user} = Auth.authenticate_session(token) |> normalize_user(user)
    end

    test "reuses an existing user and does not duplicate membership" do
      org = org!()
      sso!(org)

      existing =
        %User{}
        |> User.changeset(%{email: "dup@example.test", name: "Existing"})
        |> Repo.insert!()

      %OrgMembership{}
      |> OrgMembership.changeset(%{org_id: org.id, user_id: existing.id, role: "admin"})
      |> Repo.insert!()

      OIDC.Fake.script_claims(%{
        "sub" => "x",
        "email" => "dup@example.test",
        "email_verified" => true
      })

      assert {:ok, %{user: user}} = Auth.callback(org.id, %{"code" => "c"}, code_verifier: "v")
      assert user.id == existing.id
      # role preserved, single membership
      assert [%{role: "admin"}] = Repo.all(from m in OrgMembership, where: m.org_id == ^org.id)

      assert [] =
               Observability.list_audit_logs(org.id,
                 action: "org_member.granted",
                 resource_type: "org_member"
               )
    end

    test "enforces allowed_domains" do
      org = org!()
      sso!(org, %{allowed_domains: ["allowed.test"]})

      OIDC.Fake.script_claims(%{
        "sub" => "x",
        "email" => "user@blocked.test",
        "email_verified" => true
      })

      assert {:error, :domain_not_allowed} =
               Auth.callback(org.id, %{"code" => "c"}, code_verifier: "v")

      OIDC.Fake.script_claims(%{
        "sub" => "y",
        "email" => "user@allowed.test",
        "email_verified" => true
      })

      assert {:ok, _} = Auth.callback(org.id, %{"code" => "c"}, code_verifier: "v")
    end

    test "records redacted OIDC callback failures for Operations" do
      org = org!()
      sso_conn = sso!(org, %{allowed_domains: ["allowed.test"]})

      OIDC.Fake.script_claims(%{
        "sub" => "x",
        "email" => "blocked-user@example.test",
        "email_verified" => true
      })

      assert {:error, :domain_not_allowed} =
               Auth.callback(org.id, %{"code" => "c"},
                 code_verifier: "v",
                 request_id: "req_login_blocked"
               )

      assert [event] = Observability.list_events(org.id, domain: "sso")
      assert event.source == "bft.dashboard"
      assert event.event_type == "sso.login.failed"
      assert event.resource_type == "org_sso_connection"
      assert event.resource_id == sso_conn.id
      assert event.status == "failed"
      assert event.reason_class == "domain_not_allowed"
      assert event.correlation_id == "req_login_blocked"
      assert event.evidence["provider"] == "generic_oidc"
      assert event.evidence["stage"] == "callback"
      assert event.evidence["request_id"] == "req_login_blocked"
      refute inspect(event) =~ "blocked-user@example.test"
    end

    test "rejects unverified emails" do
      org = org!()
      sso!(org)

      OIDC.Fake.script_claims(%{
        "sub" => "x",
        "email" => "u@example.test",
        "email_verified" => false
      })

      assert {:error, :email_not_verified} =
               Auth.callback(org.id, %{"code" => "c"}, code_verifier: "v")
    end

    test "requires code and code_verifier" do
      org = org!()
      sso!(org)
      assert {:error, :missing_code} = Auth.callback(org.id, %{}, code_verifier: "v")
      assert {:error, :missing_code_verifier} = Auth.callback(org.id, %{"code" => "c"}, [])
    end

    test "errors when the token response carries no id_token" do
      org = org!()
      sso!(org)
      OIDC.Fake.script_token(%{"access_token" => "only-access"})
      assert {:error, :no_id_token} = Auth.callback(org.id, %{"code" => "c"}, code_verifier: "v")
    end
  end

  describe "callback/3 (Feishu subject-first identity flow)" do
    test "provisions a user with no email using the stable Feishu subject" do
      org = org!()
      sso!(org, %{provider: "feishu", issuer: nil, client_id: "feishu-app"})

      Feishu.Fake.script_identity(%{
        "user_id" => "feishu-user-phone-only",
        "mobile" => "+10000000001",
        "display_name" => "Feishu Phone User",
        "profile" => %{"tenant_key" => "fake-tenant"}
      })

      assert {:ok, %{user: user, token: token, session: session}} =
               Auth.callback(org.id, %{"code" => "feishu-code"}, device: "web")

      assert user.email == nil
      assert user.name == "Feishu Phone User"
      assert session.user_id == user.id
      assert {:ok, ^user} = Auth.authenticate_session(token) |> normalize_user(user)

      identity =
        Repo.get_by!(OrgSsoIdentity,
          org_id: org.id,
          provider: "feishu",
          provider_subject_type: "user_id",
          provider_subject: "feishu-user-phone-only"
        )

      assert identity.user_id == user.id
      assert identity.email == nil
      assert identity.mobile == "+10000000001"
      assert identity.display_name == "Feishu Phone User"

      membership = Repo.get_by!(OrgMembership, org_id: org.id, user_id: user.id)
      assert membership.role == "member"

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "org_member.granted",
                 resource_type: "org_member"
               )

      assert audit.actor_user_id == user.id
      assert audit.actor_label == "Feishu Phone User"
      assert audit.resource_id == user.id
      assert audit.metadata["source"] == "sso_jit"
      assert audit.metadata["provider"] == "feishu"
      assert audit.metadata["new_role"] == "member"
      refute inspect(audit.metadata) =~ "feishu-user-phone-only"
      refute inspect(audit.metadata) =~ "+10000000001"
    end

    test "reuses the org-scoped Feishu identity instead of matching by mobile" do
      org = org!()
      sso!(org, %{provider: "feishu", issuer: nil, client_id: "feishu-app"})

      Feishu.Fake.script_identity(%{
        "user_id" => "feishu-user-reuse",
        "mobile" => "+10000000002",
        "display_name" => "First Name"
      })

      assert {:ok, %{user: first}} = Auth.callback(org.id, %{"code" => "first"})

      Feishu.Fake.script_identity(%{
        "user_id" => "feishu-user-reuse",
        "mobile" => "+10000000003",
        "display_name" => "Second Name"
      })

      assert {:ok, %{user: second}} = Auth.callback(org.id, %{"code" => "second"})
      assert second.id == first.id

      identities =
        Repo.all(
          from i in OrgSsoIdentity,
            where: i.org_id == ^org.id and i.provider_subject == "feishu-user-reuse"
        )

      assert length(identities) == 1
      assert hd(identities).mobile == "+10000000003"
    end

    test "does not merge different Feishu subjects that share a mobile number" do
      org = org!()
      sso!(org, %{provider: "feishu", issuer: nil, client_id: "feishu-app"})

      Feishu.Fake.script_identity(%{
        "user_id" => "feishu-subject-a",
        "mobile" => "+10000000004",
        "display_name" => "Subject A"
      })

      assert {:ok, %{user: first}} = Auth.callback(org.id, %{"code" => "first"})

      Feishu.Fake.script_identity(%{
        "user_id" => "feishu-subject-b",
        "mobile" => "+10000000004",
        "display_name" => "Subject B"
      })

      assert {:ok, %{user: second}} = Auth.callback(org.id, %{"code" => "second"})
      assert second.id != first.id

      identities =
        Repo.all(
          from i in OrgSsoIdentity,
            where: i.org_id == ^org.id and i.mobile == "+10000000004",
            order_by: [asc: i.provider_subject]
        )

      assert Enum.map(identities, & &1.provider_subject) == [
               "feishu-subject-a",
               "feishu-subject-b"
             ]
    end

    test "stores Feishu contact email on the SSO identity without matching global users" do
      org = org!()
      sso!(org, %{provider: "feishu", issuer: nil, client_id: "feishu-app"})

      existing =
        %User{}
        |> User.changeset(%{email: "shared@example.test", name: "Existing OIDC User"})
        |> Repo.insert!()

      Feishu.Fake.script_identity(%{
        "user_id" => "feishu-user-email-contact",
        "email" => "Shared@Example.test",
        "mobile" => "+10000000005",
        "display_name" => "Feishu Contact User"
      })

      assert {:ok, %{user: feishu_user}} = Auth.callback(org.id, %{"code" => "feishu-code"})
      assert feishu_user.id != existing.id
      assert feishu_user.email == nil
      assert feishu_user.name == "Feishu Contact User"

      identity =
        Repo.get_by!(OrgSsoIdentity,
          org_id: org.id,
          provider: "feishu",
          provider_subject_type: "user_id",
          provider_subject: "feishu-user-email-contact"
        )

      assert identity.user_id == feishu_user.id
      assert identity.email == "shared@example.test"
      assert identity.mobile == "+10000000005"
    end

    test "rejects Feishu identities from a different configured tenant" do
      org = org!()

      sso!(org, %{
        provider: "feishu",
        issuer: nil,
        client_id: "feishu-app",
        provider_config: %{"tenant_key" => "expected-tenant"}
      })

      Feishu.Fake.script_identity(%{
        "user_id" => "feishu-wrong-tenant",
        "mobile" => "+10000000006",
        "display_name" => "Wrong Tenant",
        "profile" => %{"tenant_key" => "other-tenant"}
      })

      assert {:error, :feishu_tenant_mismatch} =
               Auth.callback(org.id, %{"code" => "feishu-code"})

      assert [event] = Observability.list_events(org.id, domain: "sso")
      assert event.event_type == "sso.login.failed"
      assert event.reason_class == "feishu_tenant_mismatch"
      assert event.evidence["provider"] == "feishu"
      assert event.evidence["stage"] == "callback"
      refute inspect(event) =~ "other-tenant"
      refute inspect(event) =~ "+10000000006"

      refute Repo.get_by(OrgSsoIdentity,
               org_id: org.id,
               provider: "feishu",
               provider_subject: "feishu-wrong-tenant"
             )

      assert [] = Repo.all(from m in OrgMembership, where: m.org_id == ^org.id)
    end

    test "rejects new Feishu users when provisioning policy requires an existing identity" do
      org = org!()

      sso!(org, %{
        provider: "feishu",
        issuer: nil,
        client_id: "feishu-app",
        provider_config: %{"provisioning_policy" => "existing_identity"}
      })

      Feishu.Fake.script_identity(%{
        "user_id" => "feishu-not-linked",
        "mobile" => "+10000000007",
        "display_name" => "Not Linked"
      })

      assert {:error, :feishu_provisioning_policy_rejected} =
               Auth.callback(org.id, %{"code" => "feishu-code"})

      refute Repo.get_by(OrgSsoIdentity,
               org_id: org.id,
               provider: "feishu",
               provider_subject: "feishu-not-linked"
             )

      assert [] = Repo.all(from m in OrgMembership, where: m.org_id == ^org.id)
    end

    test "allows a pre-linked Feishu identity when provisioning policy requires it" do
      org = org!()

      sso!(org, %{
        provider: "feishu",
        issuer: nil,
        client_id: "feishu-app",
        provider_config: %{"provisioning_policy" => "existing_identity"}
      })

      user =
        %User{}
        |> User.changeset(%{name: "Prelinked User", status: "active"})
        |> Repo.insert!()

      %OrgSsoIdentity{}
      |> OrgSsoIdentity.changeset(%{
        org_id: org.id,
        user_id: user.id,
        provider: "feishu",
        provider_subject_type: "user_id",
        provider_subject: "feishu-prelinked",
        mobile: "+10000000008",
        display_name: "Prelinked User"
      })
      |> Repo.insert!()

      Feishu.Fake.script_identity(%{
        "user_id" => "feishu-prelinked",
        "mobile" => "+10000000009",
        "display_name" => "Prelinked Updated"
      })

      assert {:ok, %{user: logged_in}} = Auth.callback(org.id, %{"code" => "feishu-code"})
      assert logged_in.id == user.id

      identity =
        Repo.get_by!(OrgSsoIdentity,
          org_id: org.id,
          provider: "feishu",
          provider_subject: "feishu-prelinked"
        )

      assert identity.user_id == user.id
      assert identity.mobile == "+10000000009"

      membership = Repo.get_by!(OrgMembership, org_id: org.id, user_id: user.id)
      assert membership.role == "member"
    end

    test "rejects Feishu identities with no stable subject" do
      org = org!()
      sso!(org, %{provider: "feishu", issuer: nil, client_id: "feishu-app"})

      Feishu.Fake.script_identity(%{
        "mobile" => "+10000000004",
        "display_name" => "No Stable Subject"
      })

      assert {:error, :missing_provider_subject} =
               Auth.callback(org.id, %{"code" => "feishu-code"})
    end
  end

  describe "authenticate_session/1" do
    test "resolves an active user from a valid token" do
      user = %User{} |> User.changeset(%{email: "a@b.test"}) |> Repo.insert!()
      {:ok, %{token: token}} = Sessions.create(user)
      assert {:ok, got} = Auth.authenticate_session(token)
      assert got.id == user.id
    end

    test "rejects an unknown token and a suspended user" do
      assert {:error, :unauthenticated} = Auth.authenticate_session("bad")

      user =
        %User{} |> User.changeset(%{email: "susp@b.test", status: "suspended"}) |> Repo.insert!()

      {:ok, %{token: token}} = Sessions.create(user)
      assert {:error, :unauthenticated} = Auth.authenticate_session(token)
    end
  end

  describe "authenticate_api_key/1 + logout/1" do
    test "creates an API key and returns the raw token only once" do
      org = org!()

      assert {:ok, %{token: token, api_key: api_key}} =
               Auth.create_api_key(org.id, %{
                 "name" => "mac-mini",
                 "scopes" => ["runners:write"]
               })

      assert String.starts_with?(token, "bft_")
      assert api_key.name == "mac-mini"
      assert api_key.key_hash == Sessions.hash_token(token)
      assert api_key.scopes == ["runners:write"]
      refute inspect(api_key) =~ token

      assert [%ApiKey{id: id, key_hash: key_hash}] = Auth.list_api_keys(org.id)
      assert id == api_key.id
      assert key_hash == Sessions.hash_token(token)
      refute inspect(Auth.list_api_keys(org.id)) =~ token

      assert {:ok, %{org_id: oid, scopes: ["runners:write"]}} =
               Auth.authenticate_api_key(token)

      assert oid == org.id
    end

    test "revokes an API key by org" do
      org = org!()
      other_org = org!()
      {:ok, %{token: token, api_key: api_key}} = Auth.create_api_key(org.id, %{"name" => "mac"})

      assert {:error, :not_found} = Auth.revoke_api_key(other_org.id, api_key.id)
      assert {:ok, revoked} = Auth.revoke_api_key(org.id, api_key.id)
      assert revoked.revoked_at
      assert {:error, :unauthenticated} = Auth.authenticate_api_key(token)
    end

    test "creates and revokes API key audit without exposing the raw token" do
      org = org!()

      assert {:ok, %{token: token, api_key: api_key}} =
               Auth.create_api_key(
                 org.id,
                 %{
                   "name" => "mac",
                   "scopes" => ["runners:write"]
                 },
                 actor_label: "owner@example.com"
               )

      assert [created] = Observability.list_audit_logs(org.id, action: "api_key.created")
      assert created.resource_id == api_key.id
      assert created.metadata["scopes"] == ["runners:write"]
      refute inspect(created) =~ token
      refute inspect(created) =~ api_key.key_hash

      assert {:ok, _revoked} =
               Auth.revoke_api_key(org.id, api_key.id, actor_label: "owner@example.com")

      assert [revoked] = Observability.list_audit_logs(org.id, action: "api_key.revoked")
      assert revoked.resource_id == api_key.id
      assert revoked.redacted_diff["revoked_at"]["to"]
      refute inspect(revoked) =~ token
      refute inspect(revoked) =~ api_key.key_hash
    end

    test "rotates an active API key and revokes the old token" do
      org = org!()
      other_org = org!()

      assert {:ok, %{token: old_token, api_key: old_key}} =
               Auth.create_api_key(org.id, %{
                 "name" => "mac",
                 "scopes" => ["runners:write"]
               })

      assert {:error, :not_found} = Auth.rotate_api_key(other_org.id, old_key.id)

      assert {:ok, %{token: new_token, api_key: new_key, revoked_api_key: revoked}} =
               Auth.rotate_api_key(
                 org.id,
                 old_key.id,
                 %{"name" => "mac replacement"},
                 actor_label: "owner@example.com",
                 request_id: "req_api_key_rotate"
               )

      assert new_token != old_token
      assert new_key.id != old_key.id
      assert new_key.name == "mac replacement"
      assert new_key.scopes == ["runners:write"]
      assert revoked.id == old_key.id
      assert revoked.revoked_at

      assert {:error, :unauthenticated} = Auth.authenticate_api_key(old_token)

      assert {:ok, %{org_id: org_id, scopes: ["runners:write"]}} =
               Auth.authenticate_api_key(new_token)

      assert org_id == org.id
      refute inspect(Auth.list_api_keys(org.id)) =~ new_token

      assert [rotated] = Observability.list_audit_logs(org.id, action: "api_key.rotated")
      assert rotated.resource_id == new_key.id
      assert rotated.request_id == "req_api_key_rotate"
      assert rotated.metadata["old_key_id"] == old_key.id
      assert rotated.metadata["replacement_key_id"] == new_key.id
      assert rotated.metadata["scopes"] == ["runners:write"]
      assert rotated.metadata["old_key_revoked"] == "true"
      assert rotated.redacted_diff["credential"] == %{"from" => old_key.id, "to" => new_key.id}
      assert rotated.redacted_diff["revoked_at"]["to"]
      refute inspect(rotated) =~ old_token
      refute inspect(rotated) =~ new_token
      refute inspect(rotated) =~ old_key.key_hash
      refute inspect(rotated) =~ new_key.key_hash

      assert {:error, :revoked} = Auth.rotate_api_key(org.id, old_key.id)
    end

    test "records failed API key write attempts without exposing token material" do
      org = org!()

      assert {:error, %Ecto.Changeset{}} =
               Auth.create_api_key(
                 org.id,
                 %{"name" => "invalid key", "scopes" => "not-a-list"},
                 actor_label: "owner@example.com",
                 request_id: "req_api_key_create_failed"
               )

      assert [create_attempt] =
               Observability.list_audit_logs(org.id, action: "api_key.created")

      assert create_attempt.result == "failed"
      assert create_attempt.reason_class == "validation_failed"
      assert create_attempt.request_id == "req_api_key_create_failed"
      assert create_attempt.metadata["write_attempt"] == "true"
      assert create_attempt.metadata["surface"] == "api_key"
      assert create_attempt.metadata["name_configured"] == "true"
      assert create_attempt.metadata["error_fields"] == ["scopes"]

      missing_id = Ecto.UUID.generate()

      assert {:error, :not_found} =
               Auth.revoke_api_key(org.id, missing_id,
                 actor_label: "owner@example.com",
                 request_id: "req_api_key_revoke_missing"
               )

      assert [revoke_attempt] =
               Observability.list_audit_logs(org.id, action: "api_key.revoked")

      assert revoke_attempt.result == "failed"
      assert revoke_attempt.reason_class == "not_found"
      assert revoke_attempt.resource_id == missing_id
      assert revoke_attempt.request_id == "req_api_key_revoke_missing"

      assert {:ok, %{token: token, api_key: api_key}} =
               Auth.create_api_key(org.id, %{
                 "name" => "rotated later",
                 "scopes" => ["runners:write"]
               })

      assert {:ok, _revoked} = Auth.revoke_api_key(org.id, api_key.id)

      assert {:error, :revoked} =
               Auth.rotate_api_key(
                 org.id,
                 api_key.id,
                 %{},
                 actor_label: "owner@example.com",
                 request_id: "req_api_key_rotate_revoked"
               )

      assert [rotate_attempt] =
               Observability.list_audit_logs(org.id, action: "api_key.rotated")

      assert rotate_attempt.result == "failed"
      assert rotate_attempt.reason_class == "revoked"
      assert rotate_attempt.resource_id == api_key.id
      assert rotate_attempt.request_id == "req_api_key_rotate_revoked"

      assert [rotate_event] = Observability.list_events(org.id, audit_log_id: rotate_attempt.id)
      assert rotate_event.event_type == "audit.api_key.rotated"
      assert rotate_event.status == "failed"
      assert rotate_event.reason_class == "revoked"

      refute inspect([create_attempt, revoke_attempt, rotate_attempt, rotate_event]) =~ token

      refute inspect([create_attempt, revoke_attempt, rotate_attempt, rotate_event]) =~
               api_key.key_hash
    end

    test "resolves an active key to its org and scopes" do
      org = org!()
      raw = "key-#{System.unique_integer([:positive])}"

      %ApiKey{}
      |> ApiKey.changeset(%{
        org_id: org.id,
        name: "ci",
        key_hash: Sessions.hash_token(raw),
        scopes: ["projects:read"]
      })
      |> Repo.insert!()

      assert {:ok, %{org_id: oid, scopes: ["projects:read"]}} = Auth.authenticate_api_key(raw)
      assert oid == org.id
    end

    test "rejects unknown and revoked keys" do
      assert {:error, :unauthenticated} = Auth.authenticate_api_key("nope")

      org = org!()
      raw = "rev-#{System.unique_integer([:positive])}"

      %ApiKey{}
      |> ApiKey.changeset(%{
        org_id: org.id,
        key_hash: Sessions.hash_token(raw),
        revoked_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      assert {:error, :unauthenticated} = Auth.authenticate_api_key(raw)
    end

    test "logout revokes the session" do
      user = %User{} |> User.changeset(%{email: "lo@b.test"}) |> Repo.insert!()
      {:ok, %{token: token}} = Sessions.create(user)
      assert :ok = Auth.logout(token)
      assert {:error, :unauthenticated} = Auth.authenticate_session(token)
    end
  end

  # authenticate_session returns {:ok, %User{}}; align with the bound `user`
  # struct (which may differ in loaded assocs) by comparing ids.
  defp normalize_user({:ok, got}, expected) do
    if got.id == expected.id, do: {:ok, expected}, else: {:ok, got}
  end
end
