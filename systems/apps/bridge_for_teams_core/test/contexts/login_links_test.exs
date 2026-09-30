defmodule BridgeForTeams.LoginLinksTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.LoginLinks
  alias BridgeForTeams.LoginLinks.Delivery.Fake, as: FakeDelivery
  alias BridgeForTeams.{Accounts, Memberships, Observability, Orgs}
  alias BridgeForTeams.Schema.LoginEmailLink

  @base_url "https://teams.example.com"

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp org_fixture do
    slug = uniq("magic-org")
    {:ok, org} = Orgs.create_org(%{name: "Magic #{slug}", slug: slug})
    org
  end

  defp member_fixture(org, role \\ "member") do
    {:ok, user} = Accounts.create_user(%{email: uniq("member") <> "@example.com"})
    {:ok, _} = Memberships.put_org_member(org.id, user.id, role)
    user
  end

  defp add_sso!(org) do
    {:ok, _sso} =
      Orgs.upsert_sso_connection(org.id, %{
        "issuer" => "https://idp.test",
        "client_id" => "client-magic",
        "client_secret" => "secret"
      })

    :ok
  end

  defp request!(org_slug, email, opts \\ []) do
    assert :ok =
             LoginLinks.request_login_link(
               org_slug,
               email,
               Keyword.merge([base_url: @base_url], opts)
             )
  end

  defp delivered_token! do
    assert [%{url: url}] = FakeDelivery.deliveries()
    %{query: query} = URI.parse(url)
    %{"token" => token} = URI.decode_query(query)
    token
  end

  describe "request_login_link/3" do
    test "emails a one-time link to an active member of an SSO-less org" do
      org = org_fixture()
      user = member_fixture(org)

      request!(org.slug, user.email)

      assert [%{email: email, org_name: org_name, url: url}] = FakeDelivery.deliveries()
      assert email == user.email
      assert org_name == org.name
      assert url =~ @base_url <> "/auth/email/verify?token=bft_login_"

      assert [link] = Repo.all(LoginEmailLink)
      assert link.user_id == user.id
      assert link.org_id == org.id
      assert is_nil(link.used_at)
      # Only the hash is stored, never the raw token.
      token = delivered_token!()
      assert link.token_hash == Sessions.hash_token(token)
      refute inspect(link) =~ token

      assert [audit] = Observability.list_audit_logs(org.id, action: "login_link.requested")
      assert audit.resource_type == "login_email_link"
      refute inspect(audit) =~ token
    end

    test "silently does nothing unless org, SSO absence, user, and membership all match" do
      org = org_fixture()
      user = member_fixture(org)
      {:ok, outsider} = Accounts.create_user(%{email: uniq("outsider") <> "@example.com"})
      {:ok, inactive} = Accounts.create_user(%{email: uniq("inactive") <> "@example.com"})
      {:ok, inactive} = Accounts.update_user(inactive, %{status: "disabled"})
      {:ok, _} = Memberships.put_org_member(org.id, inactive.id, "member")

      sso_org = org_fixture()
      sso_user = member_fixture(sso_org)
      add_sso!(sso_org)

      # Unknown org slug.
      request!(uniq("nope"), user.email)
      # Known org, unknown email.
      request!(org.slug, uniq("ghost") <> "@example.com")
      # Known org, existing user without membership.
      request!(org.slug, outsider.email)
      # Known org, inactive member.
      request!(org.slug, inactive.email)
      # Org with SSO configured never falls back to magic links.
      request!(sso_org.slug, sso_user.email)
      # Not even shaped like an email.
      request!(org.slug, "not-an-email")

      assert FakeDelivery.deliveries() == []
      assert Repo.all(LoginEmailLink) == []
    end

    test "rate limits per org+email and per requester IP" do
      org = org_fixture()
      user = member_fixture(org)

      opts = [rate_limits: [email_burst: 2, email_rate: 0.0, ip_burst: 100, ip_rate: 0.0]]
      for _ <- 1..3, do: request!(org.slug, user.email, opts)
      assert length(FakeDelivery.deliveries()) == 2

      other = member_fixture(org)
      ip = uniq("10.0.0")

      ip_opts = [
        remote_ip: ip,
        rate_limits: [ip_burst: 1, ip_rate: 0.0, email_burst: 100, email_rate: 0.0]
      ]

      request!(org.slug, other.email, ip_opts)
      request!(org.slug, user.email, ip_opts)
      # Only the first request on this IP got through.
      assert length(FakeDelivery.deliveries()) == 3
    end
  end

  describe "redeem_login_token_for_session/2" do
    test "creates a session once and burns the link" do
      org = org_fixture()
      user = member_fixture(org)
      request!(org.slug, user.email)
      token = delivered_token!()

      assert {:ok, %{user: redeemed_user, org: redeemed_org, token: session_token}} =
               LoginLinks.redeem_login_token_for_session(token)

      assert redeemed_user.id == user.id
      assert redeemed_org.id == org.id
      assert {:ok, %{user_id: fetched_user_id}} = Sessions.fetch(session_token)
      assert fetched_user_id == user.id

      assert [%LoginEmailLink{used_at: %DateTime{}}] = Repo.all(LoginEmailLink)

      assert {:error, :login_token_already_used} =
               LoginLinks.redeem_login_token_for_session(token)

      assert [_audit] = Observability.list_audit_logs(org.id, action: "login_link.redeemed")
    end

    test "rejects unknown, expired, and blank tokens" do
      org = org_fixture()
      user = member_fixture(org)
      request!(org.slug, user.email)
      token = delivered_token!()

      assert {:error, :invalid_login_token} =
               LoginLinks.redeem_login_token_for_session("bft_login_bogus")

      assert {:error, :invalid_login_token} = LoginLinks.redeem_login_token_for_session(nil)

      [link] = Repo.all(LoginEmailLink)

      {:ok, _} =
        link
        |> LoginEmailLink.changeset(%{"expires_at" => DateTime.add(DateTime.utc_now(), -1)})
        |> Repo.update()

      assert {:error, :login_token_expired} = LoginLinks.redeem_login_token_for_session(token)
    end

    test "rejects redemption once the org configures SSO or membership is gone" do
      org = org_fixture()
      user = member_fixture(org)
      request!(org.slug, user.email)
      token = delivered_token!()
      add_sso!(org)

      assert {:error, :invalid_login_token} = LoginLinks.redeem_login_token_for_session(token)

      org2 = org_fixture()
      user2 = member_fixture(org2)
      request!(org2.slug, user2.email)
      [_, %{url: url2}] = FakeDelivery.deliveries()
      %{"token" => token2} = URI.decode_query(URI.parse(url2).query)

      assert :ok = Memberships.remove_org_member(org2.id, user2.id)
      assert {:error, :invalid_login_token} = LoginLinks.redeem_login_token_for_session(token2)
    end
  end
end
