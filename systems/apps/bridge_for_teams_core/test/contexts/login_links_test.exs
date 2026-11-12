defmodule BridgeForTeams.LoginLinksTest do
  use BridgeForTeams.DataCase, async: true

  import ExUnit.CaptureLog

  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.LoginLinks
  alias BridgeForTeams.LoginLinks.Delivery.Fake, as: FakeDelivery
  alias BridgeForTeams.{Accounts, Memberships, Observability, Orgs}
  alias BridgeForTeams.Schema.LoginEmailLink

  @base_url "https://teams.example.com"

  defp uniq(prefix), do: "#{prefix}-#{SystemsRuntime.Proc.unique_integer([:positive])}"

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

  @log_metadata [
    :event,
    :outcome,
    :request_id,
    :org_id,
    :user_id,
    :link_id,
    :provider_message_id,
    :provider_status,
    :provider_error_code
  ]

  # The private outcome line of one request, plus everything it logged.
  defp request_log(org_slug, email, opts \\ []) do
    request_id = uniq("req")

    log =
      capture_log([format: "$level $message $metadata\n", metadata: @log_metadata], fn ->
        request!(org_slug, email, Keyword.put(opts, :request_id, request_id))
      end)

    assert log =~ "event=login_link_request"
    assert log =~ "request_id=#{request_id}"
    log
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

    test "logs each outcome privately: ids only, never the email, slug, or token" do
      org = org_fixture()
      user = member_fixture(org)
      {:ok, outsider} = Accounts.create_user(%{email: uniq("outsider") <> "@example.com"})
      {:ok, inactive} = Accounts.create_user(%{email: uniq("inactive") <> "@example.com"})
      {:ok, inactive} = Accounts.update_user(inactive, %{status: "disabled"})
      {:ok, _} = Memberships.put_org_member(org.id, inactive.id, "member")
      sso_org = org_fixture()
      sso_user = member_fixture(sso_org)
      add_sso!(sso_org)
      unknown_slug = uniq("nope")
      ghost = uniq("ghost") <> "@example.com"

      cases = [
        {unknown_slug, user.email, "outcome=org_not_found", nil},
        {org.slug, ghost, "outcome=user_not_found", nil},
        {org.slug, outsider.email, "outcome=not_member", outsider.id},
        {org.slug, inactive.email, "outcome=user_inactive", inactive.id},
        {sso_org.slug, sso_user.email, "outcome=sso_configured", nil},
        {org.slug, "not-an-email", "outcome=invalid_email", nil}
      ]

      for {slug, email, outcome, user_id} <- cases do
        log = request_log(slug, email)
        assert log =~ outcome
        assert log =~ ~r/^info Login link request/m
        if user_id, do: assert(log =~ "user_id=#{user_id}")
        refute log =~ email
        refute log =~ slug
      end

      assert request_log(org.slug, outsider.email) =~ "org_id=#{org.id}"
      assert FakeDelivery.deliveries() == []

      log = request_log(org.slug, user.email)
      token = delivered_token!()
      [link] = Repo.all(LoginEmailLink)
      assert log =~ "outcome=accepted"
      assert log =~ "org_id=#{org.id}"
      assert log =~ "user_id=#{user.id}"
      assert log =~ "link_id=#{link.id}"
      assert log =~ "provider_message_id=fake-message-1"
      refute log =~ user.email
      refute log =~ org.slug
      refute log =~ token
      refute log =~ @base_url

      assert [audit] = Observability.list_audit_logs(org.id, action: "login_link.requested")
      assert audit.metadata["message_id"] == "fake-message-1"
    end

    test "classifies delivery failures without the provider's error text" do
      org = org_fixture()
      user = member_fixture(org)

      FakeDelivery.script_result({:error, {:postmark, 422, 406}})
      log = request_log(org.slug, user.email)
      assert log =~ ~r/^warning Login link request/m
      assert log =~ "outcome=recipient_suppressed"
      assert log =~ "user_id=#{user.id}"

      FakeDelivery.script_result({:error, {:postmark, 422, 300}})
      log = request_log(org.slug, user.email)
      assert log =~ "outcome=provider_rejected"
      assert log =~ "provider_status=422"
      assert log =~ "provider_error_code=300"

      FakeDelivery.script_result({:error, {:transport, {:closed, "raw-term " <> user.email}}})
      log = request_log(org.slug, user.email)
      assert log =~ "outcome=provider_unreachable"
      refute log =~ "raw-term"
      refute log =~ user.email

      # A failed send records no acceptance.
      assert Observability.list_audit_logs(org.id, action: "login_link.requested") == []
    end

    test "logs which rate limit dropped a request" do
      org = org_fixture()
      user = member_fixture(org)

      email_opts = [rate_limits: [email_burst: 1, email_rate: 0.0, ip_burst: 100, ip_rate: 0.0]]
      assert request_log(org.slug, user.email, email_opts) =~ "outcome=accepted"
      assert request_log(org.slug, user.email, email_opts) =~ "outcome=rate_limited_email"

      other = member_fixture(org)

      ip_opts = [
        remote_ip: uniq("10.0.1"),
        rate_limits: [ip_burst: 1, ip_rate: 0.0, email_burst: 100, email_rate: 0.0]
      ]

      assert request_log(org.slug, other.email, ip_opts) =~ "outcome=accepted"
      log = request_log(org.slug, user.email, ip_opts)
      assert log =~ "outcome=rate_limited_ip"
      refute log =~ ip_opts[:remote_ip]
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
        |> LoginEmailLink.changeset(%{"expires_at" => DateTime.add(SystemsClock.utc_now(), -1)})
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

  describe "delivery_evidence/3" do
    test "reports matching state, suppression, and each link's provider events without the email" do
      org = org_fixture()
      user = member_fixture(org)
      request!(org.slug, user.email, request_id: "req-evidence-1")
      token = delivered_token!()
      [link] = Repo.all(LoginEmailLink)

      FakeDelivery.script_evidence(
        :message_events,
        {:ok,
         %{
           status: "Sent",
           events: [
             %{
               type: "Bounced",
               received_at: "2026-11-03T05:41:00Z",
               bounce: %{type: "HardBounce", type_code: 1, inactive: true}
             }
           ]
         }}
      )

      FakeDelivery.script_evidence(
        :suppression,
        {:ok, %{reason: "HardBounce", origin: "Recipient", created_at: "2026-11-03T05:41:01Z"}}
      )

      assert {:ok, evidence} = LoginLinks.delivery_evidence(org.id, user.id)

      assert %{
               org_id: org_id,
               user_id: user_id,
               delivery_configured: true,
               sso_configured: false,
               user_status: "active",
               member: true,
               suppression: %{reason: "HardBounce", origin: "Recipient"},
               links: [
                 %{
                   link_id: link_id,
                   request_id: "req-evidence-1",
                   acceptance_recorded: true,
                   provider_message_id: "fake-message-1",
                   used_at: nil,
                   provider_events: %{events: [%{type: "Bounced", bounce: %{type: "HardBounce"}}]}
                 }
               ]
             } = evidence

      assert {org_id, user_id, link_id} == {org.id, user.id, link.id}
      refute inspect(evidence) =~ user.email
      refute inspect(evidence) =~ token

      FakeDelivery.script_evidence(:suppression, {:error, {:transport, {:closed, user.email}}})

      assert {:ok, %{suppression: %{error: :provider_unreachable}} = evidence} =
               LoginLinks.delivery_evidence(org.id, user.id)

      refute inspect(evidence) =~ user.email

      assert {:error, :not_found} =
               LoginLinks.delivery_evidence(org.id, SystemsRuntime.Proc.uuid())
    end

    test "a link without an acceptance record reports unknown, not a provider answer" do
      org = org_fixture()
      user = member_fixture(org)

      # A link row whose acceptance audit never got written (a failed send, or
      # an audit write that failed after Postmark accepted it).
      {:ok, link} =
        %LoginEmailLink{}
        |> LoginEmailLink.changeset(%{
          "user_id" => user.id,
          "org_id" => org.id,
          "token_hash" => Sessions.hash_token("bft_login_unrecorded"),
          "expires_at" => DateTime.add(SystemsClock.utc_now(), 900)
        })
        |> Repo.insert()

      FakeDelivery.script_evidence(:message_events, {:error, :must_not_be_called})

      assert {:ok, %{links: [evidence]}} = LoginLinks.delivery_evidence(org.id, user.id)

      assert evidence == %{
               link_id: link.id,
               created_at: link.created_at,
               expires_at: link.expires_at,
               used_at: nil,
               request_id: nil,
               acceptance_recorded: false,
               provider_message_id: nil,
               provider_events: nil
             }
    end
  end
end
