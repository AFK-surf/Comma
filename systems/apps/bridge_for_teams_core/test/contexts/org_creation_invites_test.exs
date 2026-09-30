defmodule BridgeForTeams.OrgCreationInvitesTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.{Accounts, Memberships, Observability, OrgCreationInvites, Orgs, Repo}
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.Schema.OrgCreationInvite

  describe "create_invite_code/1" do
    test "returns the raw code once and stores only its hash" do
      suffix = unique_suffix()

      assert {:ok, %{code: code, invite: invite}} =
               OrgCreationInvites.create_invite_code(
                 org_name: "Founder Co",
                 org_slug: "founder-co-#{suffix}",
                 note: "founder"
               )

      assert String.starts_with?(code, "bft_")
      assert invite.note == "founder"
      assert invite.org_name == "Founder Co"
      assert invite.org_slug == "founder-co-#{suffix}"
      assert invite.code_hash == Sessions.hash_token(code)
      refute invite.code_hash == code
      assert %DateTime{} = invite.expires_at
    end

    test "requires org name and slug" do
      assert {:error, changeset} = OrgCreationInvites.create_invite_code(note: "missing org")

      assert %{org_name: ["can't be blank"], org_slug: ["can't be blank"]} =
               errors_on(changeset)
    end
  end

  describe "redeem_invite_code/2" do
    test "creates organization, user, owner membership, and marks the code used" do
      suffix = unique_suffix()
      email = "owner-#{suffix}@example.com"
      org_slug = "acme-#{suffix}"

      {:ok, %{code: code, invite: invite}} =
        create_invite(org_name: "Acme", org_slug: org_slug)

      assert {:ok, %{org: org, user: user, membership: membership, invite: used}} =
               OrgCreationInvites.redeem_invite_code(code, %{
                 email: email,
                 name: "Owner"
               })

      assert user.email == email
      assert user.name == "Owner"
      assert org.name == "Acme"
      assert org.slug == org_slug
      assert membership.role == "owner"
      assert used.id == invite.id
      assert used.used_by_user_id == user.id
      assert used.used_org_id == org.id
      assert %DateTime{} = used.used_at
      assert {:ok, "owner"} = Memberships.org_role(org.id, user.id)
    end

    test "records invite redemption and initial owner grant audit rows when requested" do
      suffix = unique_suffix()
      email = "audited-owner-#{suffix}@example.com"
      org_slug = "audited-#{suffix}"

      {:ok, %{code: code, invite: invite}} =
        create_invite(org_name: "Audited Co", org_slug: org_slug)

      assert {:ok, %{org: org, user: user, membership: membership}} =
               OrgCreationInvites.redeem_invite_code(
                 code,
                 %{
                   email: email,
                   name: "Audited Owner"
                 },
                 audit: true,
                 request_id: "req-invite-signup"
               )

      assert [invite_audit] =
               Observability.list_audit_logs(org.id,
                 action: "org_creation_invite.redeemed"
               )

      assert invite_audit.actor_user_id == user.id
      assert invite_audit.actor_label == email
      assert invite_audit.resource_type == "organization"
      assert invite_audit.resource_id == org.id
      assert invite_audit.resource_label == "Audited Co"
      assert invite_audit.result == "ok"
      assert invite_audit.request_id == "req-invite-signup"
      assert invite_audit.metadata["invite_id"] == invite.id
      assert invite_audit.metadata["org_slug"] == org_slug
      assert invite_audit.metadata["owner_user_id"] == user.id
      assert invite_audit.metadata["membership_id"] == membership.id
      refute inspect(invite_audit.metadata) =~ code
      refute inspect(invite_audit.metadata) =~ invite.code_hash

      assert [member_audit] =
               Observability.list_audit_logs(org.id,
                 action: "org_member.granted",
                 resource_type: "org_member"
               )

      assert member_audit.actor_user_id == user.id
      assert member_audit.resource_id == user.id
      assert member_audit.request_id == "req-invite-signup"
      assert member_audit.metadata["new_role"] == "owner"

      assert [event] = Observability.list_events(org.id, audit_log_id: invite_audit.id)
      assert event.domain == "audit"
      assert event.event_type == "audit.org_creation_invite.redeemed"
      assert event.correlation_id == "req-invite-signup"
    end

    test "cannot reuse a code" do
      suffix = unique_suffix()
      {:ok, %{code: code}} = create_invite(org_name: "One", org_slug: "one-#{suffix}")

      assert {:ok, _} =
               OrgCreationInvites.redeem_invite_code(code, %{
                 email: "one-#{suffix}@example.com"
               })

      assert {:error, :invite_already_used} =
               OrgCreationInvites.redeem_invite_code(code, %{
                 email: "two-#{suffix}@example.com"
               })
    end

    test "rejects expired codes" do
      suffix = unique_suffix()

      {:ok, %{code: code}} =
        create_invite(org_name: "Expired", org_slug: "expired-#{suffix}", ttl_seconds: -1)

      assert {:error, :invite_expired} =
               OrgCreationInvites.redeem_invite_code(code, %{
                 email: "expired-#{suffix}@example.com"
               })
    end

    test "creates the organization from the invite even when submitted org attrs are forged" do
      suffix = unique_suffix()
      org_slug = "fixed-#{suffix}"
      {:ok, %{code: code}} = create_invite(org_name: "Fixed Co", org_slug: org_slug)

      assert {:ok, %{org: org}} =
               OrgCreationInvites.redeem_invite_code(code, %{
                 email: "fixed-#{suffix}@example.com",
                 org_name: "Forged Co",
                 org_slug: "forged-#{suffix}"
               })

      assert org.name == "Fixed Co"
      assert org.slug == org_slug
      assert {:error, :not_found} = Orgs.get_org_by_slug("forged-#{suffix}")
    end

    test "does not consume the code when user creation fails" do
      suffix = unique_suffix()
      email = "owner-#{suffix}@example.com"
      org_slug = "acme-#{suffix}"

      {:ok, _user} = Accounts.create_user(%{email: email})
      {:ok, %{code: code, invite: invite}} = create_invite(org_name: "Acme", org_slug: org_slug)

      assert {:error, %Ecto.Changeset{}} =
               OrgCreationInvites.redeem_invite_code(code, %{
                 email: String.upcase(email)
               })

      reloaded = Repo.get!(OrgCreationInvite, invite.id)
      assert is_nil(reloaded.used_at)
      assert {:error, :not_found} = Orgs.get_org_by_slug(org_slug)
    end

    test "requires an email to create the owner account" do
      suffix = unique_suffix()
      org_slug = "missing-email-#{suffix}"

      {:ok, %{code: code, invite: invite}} =
        create_invite(org_name: "Missing Email", org_slug: org_slug)

      assert {:error, %Ecto.Changeset{} = changeset} =
               OrgCreationInvites.redeem_invite_code(code, %{
                 name: "Owner"
               })

      assert %{email: ["can't be blank"]} = errors_on(changeset)
      reloaded = Repo.get!(OrgCreationInvite, invite.id)
      assert is_nil(reloaded.used_at)
      assert {:error, :not_found} = Orgs.get_org_by_slug(org_slug)
    end
  end

  defp unique_suffix do
    System.unique_integer([:positive, :monotonic])
  end

  defp create_invite(attrs) do
    OrgCreationInvites.create_invite_code(attrs)
  end
end
