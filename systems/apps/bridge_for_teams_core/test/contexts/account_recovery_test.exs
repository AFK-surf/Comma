defmodule BridgeForTeams.AccountRecoveryTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.{AccountRecovery, Accounts, Memberships, Observability, Orgs, Repo}
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.Schema.AccountRecoveryLink

  describe "create_recovery_link/2" do
    test "returns a one-time URL and stores only the token hash" do
      user = user_fixture()

      assert {:ok, %{token: token, path: path, url: url, recovery_link: link}} =
               AccountRecovery.create_recovery_link(user.email,
                 base_url: "https://teams.example.com/",
                 note: "sso rollback"
               )

      assert String.starts_with?(token, "bft_recovery_")
      assert path == "/auth/recovery?" <> URI.encode_query(%{"token" => token})
      assert url == "https://teams.example.com" <> path
      assert link.user_id == user.id
      assert link.note == "sso rollback"
      assert link.token_hash == Sessions.hash_token(token)
      refute link.token_hash == token
      assert %DateTime{} = link.expires_at
    end

    test "records org-scoped audit without token hash, token, or operator note" do
      user = user_fixture(email: "recovery-owner@example.com")
      {:ok, org} = Orgs.create_org(%{name: "Acme Recovery", slug: "acme-recovery"})
      {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "owner")

      assert {:ok, %{token: token, recovery_link: link}} =
               AccountRecovery.create_recovery_link(user,
                 token: "bft_recovery_SECRET_TOKEN",
                 note: "private SSO rollback note",
                 actor_label: "operator@example.test",
                 request_id: "req-recovery-create"
               )

      assert token == "bft_recovery_SECRET_TOKEN"

      [audit] =
        Observability.list_audit_logs(org.id,
          action: "account_recovery.link_created",
          result: "ok"
        )

      assert audit.actor_type == "system"
      assert audit.actor_label == "operator@example.test"
      assert audit.resource_type == "account_recovery_link"
      assert audit.resource_id == link.id
      assert audit.request_id == "req-recovery-create"
      assert audit.metadata["target_user_id"] == user.id
      assert audit.metadata["recovery_link_id"] == link.id
      refute inspect(audit) =~ "bft_recovery_SECRET_TOKEN"
      refute inspect(audit) =~ link.token_hash
      refute inspect(audit) =~ "private SSO rollback note"
      refute inspect(audit) =~ "recovery-owner@example.com"

      [event] = Observability.list_events(org.id, audit_log_id: audit.id)
      assert event.domain == "audit"
      assert event.correlation_id == "req-recovery-create"
      refute inspect(event) =~ "bft_recovery_SECRET_TOKEN"
      refute inspect(event) =~ link.token_hash
    end

    test "rejects inactive accounts" do
      user = user_fixture(status: "disabled")

      assert {:error, :inactive_user} = AccountRecovery.create_recovery_link(user.id)
    end
  end

  describe "redeem_recovery_token/1" do
    test "marks the link used and cannot redeem it twice" do
      user = user_fixture()
      {:ok, %{token: token, recovery_link: link}} = AccountRecovery.create_recovery_link(user)

      assert {:ok, %{user: recovered, recovery_link: used}} =
               AccountRecovery.redeem_recovery_token(token)

      assert recovered.id == user.id
      assert used.id == link.id
      assert %DateTime{} = used.used_at

      assert {:error, :recovery_token_already_used} =
               AccountRecovery.redeem_recovery_token(token)
    end

    test "rejects expired links without consuming them" do
      user = user_fixture()

      {:ok, %{token: token, recovery_link: link}} =
        AccountRecovery.create_recovery_link(user, ttl_seconds: -1)

      assert {:error, :recovery_token_expired} = AccountRecovery.redeem_recovery_token(token)

      reloaded = Repo.get!(AccountRecoveryLink, link.id)
      assert is_nil(reloaded.used_at)
    end
  end

  describe "redeem_recovery_token_for_session/2" do
    test "redeems once and creates a normal auth session" do
      user = user_fixture()
      {:ok, %{token: token}} = AccountRecovery.create_recovery_link(user)

      assert {:ok, %{user: recovered, token: session_token, session: session}} =
               AccountRecovery.redeem_recovery_token_for_session(token)

      assert recovered.id == user.id
      assert session.user_id == user.id
      assert {:ok, fetched} = Sessions.fetch(session_token)
      assert fetched.user_id == user.id

      assert {:error, :recovery_token_already_used} =
               AccountRecovery.redeem_recovery_token_for_session(token)
    end

    test "records recovery redemption audit without token material" do
      user = user_fixture(email: "recovered-owner@example.com")
      {:ok, org} = Orgs.create_org(%{name: "Acme Redeem", slug: "acme-redeem"})
      {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "owner")

      {:ok, %{token: token, recovery_link: link}} =
        AccountRecovery.create_recovery_link(user,
          token: "bft_recovery_REDEEM_SECRET",
          note: "private recovery reason",
          audit: false
        )

      assert {:ok, %{session: session}} =
               AccountRecovery.redeem_recovery_token_for_session(token)

      [audit] =
        Observability.list_audit_logs(org.id,
          action: "account_recovery.redeemed",
          result: "ok"
        )

      assert audit.actor_type == "user"
      assert audit.actor_user_id == user.id
      assert audit.resource_type == "account_recovery_link"
      assert audit.resource_id == link.id
      assert audit.metadata["target_user_id"] == user.id
      assert audit.metadata["recovery_link_id"] == link.id
      assert is_binary(audit.metadata["used_at"])
      refute is_nil(session)
      refute inspect(audit) =~ "bft_recovery_REDEEM_SECRET"
      refute inspect(audit) =~ link.token_hash
      refute inspect(audit) =~ "private recovery reason"
    end
  end

  defp user_fixture(attrs \\ %{}) do
    email = attrs[:email] || "recover-#{System.unique_integer([:positive])}@example.com"

    {:ok, user} =
      Accounts.create_user(%{
        "email" => email,
        "name" => attrs[:name] || "Recover User",
        "status" => attrs[:status] || "active"
      })

    user
  end
end
