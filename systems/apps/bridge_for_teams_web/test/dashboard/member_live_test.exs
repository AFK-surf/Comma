defmodule BridgeForTeamsWeb.Dashboard.MemberLiveTest do
  @moduledoc """
  LiveView tests for the org members page (slice members-settings): renders the
  member table, invites a new member, changes a role, and guards the last owner.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Accounts, Memberships, Observability, Repo}
  alias BridgeForTeams.Schema.{OrgSsoIdentity, User}

  setup %{conn: conn} do
    %{conn: conn, user: owner, org: org} = register_and_log_in_user(%{conn: conn})
    %{conn: conn, owner: owner, org: org}
  end

  test "renders the member table with the current owner", %{conn: conn, org: org, owner: owner} do
    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/members")

    assert html =~ "Members"
    assert html =~ owner.email
    assert html =~ "Invite member"
    assert html =~ ~s(href="/orgs/#{org.slug}/operations/audit?resource_type=org_member")
  end

  test "invites a new member by email", %{conn: conn, org: org, owner: owner} do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/members")

    view |> element("button", "Invite member") |> render_click()

    html =
      view
      |> form("#invite-form", invite: %{email: "new@example.com", role: "admin"})
      |> render_submit()

    assert html =~ "new@example.com"
    assert html =~ "added as admin"

    {:ok, user} = Accounts.get_user_by_email("new@example.com")
    assert {:ok, "admin"} = Memberships.org_role(org.id, user.id)

    assert [audit] = Observability.list_audit_logs(org.id, action: "org_member.granted")
    assert audit.actor_user_id == owner.id
    assert audit.resource_type == "org_member"
    assert audit.resource_id == user.id
    assert is_binary(audit.request_id)
    assert audit.request_id != ""
    assert audit.redacted_diff["role"] == %{"from" => nil, "to" => "admin"}
  end

  test "renders a Feishu phone-only member without requiring email", %{conn: conn, org: org} do
    {:ok, user} =
      %User{}
      |> User.changeset(%{"name" => "Feishu Phone User"})
      |> Repo.insert()

    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

    {:ok, _identity} =
      %OrgSsoIdentity{}
      |> OrgSsoIdentity.changeset(%{
        org_id: org.id,
        user_id: user.id,
        provider: "feishu",
        provider_subject_type: "user_id",
        provider_subject: "feishu-phone-only-member",
        mobile: "+10000000001",
        display_name: "Feishu Phone User"
      })
      |> Repo.insert()

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/members")

    assert html =~ "Feishu Phone User"
    assert html =~ "+10000000001"
    assert html =~ "Remove Feishu Phone User from"
    refute html =~ "nil"
  end

  test "changes a member's role", %{conn: conn, org: org, owner: owner} do
    member = user_fixture(email: "member@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/members")

    view
    |> element("#member-#{member.id} form")
    |> render_change(%{"user-id" => member.id, "role" => "admin"})

    assert {:ok, "admin"} = Memberships.org_role(org.id, member.id)

    assert [audit] = Observability.list_audit_logs(org.id, action: "org_member.role_changed")
    assert audit.actor_user_id == owner.id
    assert audit.resource_id == member.id
    assert is_binary(audit.request_id)
    assert audit.request_id != ""
    assert audit.redacted_diff["role"] == %{"from" => "member", "to" => "admin"}
  end

  test "refuses to demote the last owner", %{conn: conn, org: org, owner: owner} do
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/members")

    html =
      view
      |> element("#member-#{owner.id} form")
      |> render_change(%{"user-id" => owner.id, "role" => "member"})

    assert html =~ "Can&#39;t demote the last owner" or html =~ "Can't demote the last owner"
    assert {:ok, "owner"} = Memberships.org_role(org.id, owner.id)
  end

  test "ordinary members cannot invite, remove, or change roles through forged events", %{
    org: org,
    owner: owner
  } do
    member = user_fixture(email: "plain-member@example.com")
    target = user_fixture(email: "target-member@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, _} = Memberships.put_org_member(org.id, target.id, "member")

    member_conn = build_conn() |> log_in_user(member)
    {:ok, view, html} = live(member_conn, ~p"/orgs/#{org.slug}/members")

    refute html =~ "Invite member"
    refute html =~ "Remove"

    assert render_click(view, "open-invite") =~ "Only organization admins can invite members"

    assert render_submit(view, "invite", %{
             "invite" => %{"email" => "forged@example.com", "role" => "admin"}
           }) =~ "Only organization admins can invite members"

    assert {:error, :not_found} = Accounts.get_user_by_email("forged@example.com")

    assert render_change(view, "change-role", %{"user-id" => target.id, "role" => "admin"}) =~
             "Only organization admins can change roles"

    assert {:ok, "member"} = Memberships.org_role(org.id, target.id)

    assert render_click(view, "remove", %{"user-id" => owner.id}) =~
             "Only organization admins can remove members"

    assert {:ok, "owner"} = Memberships.org_role(org.id, owner.id)

    assert [invite_audit] =
             Observability.list_audit_logs(org.id,
               action: "org_member.granted",
               result: "denied"
             )

    assert invite_audit.actor_user_id == member.id
    assert invite_audit.resource_type == "org_member"
    assert is_nil(invite_audit.resource_id)
    assert invite_audit.reason_class == "forbidden"
    assert invite_audit.metadata["surface"] == "members"
    assert invite_audit.metadata["attempted_email_configured"] in [true, "true"]
    assert invite_audit.metadata["attempted_role"] == "admin"
    refute inspect(invite_audit.metadata) =~ "forged@example.com"

    assert [role_change_audit] =
             Observability.list_audit_logs(org.id,
               action: "org_member.role_changed",
               result: "denied"
             )

    assert role_change_audit.actor_user_id == member.id
    assert role_change_audit.resource_id == target.id
    assert role_change_audit.reason_class == "forbidden"
    assert role_change_audit.metadata["surface"] == "members"
    assert role_change_audit.metadata["target_user_id_configured"] in [true, "true"]
    assert role_change_audit.metadata["attempted_role"] == "admin"

    assert [removal_audit] =
             Observability.list_audit_logs(org.id,
               action: "org_member.removed",
               result: "denied"
             )

    assert removal_audit.actor_user_id == member.id
    assert removal_audit.resource_id == owner.id
    assert removal_audit.reason_class == "forbidden"
    assert removal_audit.metadata["surface"] == "members"
    assert removal_audit.metadata["target_user_id_configured"] in [true, "true"]

    assert [event] = Observability.list_events(org.id, audit_log_id: invite_audit.id)
    assert event.domain == "audit"
    assert event.status == "denied"
    assert event.reason_class == "forbidden"
  end
end
