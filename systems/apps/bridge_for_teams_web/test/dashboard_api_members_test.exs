defmodule BridgeForTeamsWeb.DashboardAPIMembersTest do
  @moduledoc """
  The Members API behind the React Members page: listing, invites, role
  changes and removal, the owner-only owner role, the last-owner guard, the
  denied-write audit, and CSRF protection for writes.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Accounts, Memberships, Observability, Repo}
  alias BridgeForTeams.Schema.{OrgSsoIdentity, User}

  setup :register_and_log_in_user

  describe "GET /dashboard/api/v1/orgs/:org/members" do
    test "lists members and the caller's permissions", %{conn: conn, org: org, user: owner} do
      member = user_fixture(email: "member@example.com", name: "Mia")
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

      data = conn |> get(members_path(org)) |> json_response(200) |> Map.fetch!("data")

      assert data["viewer"] == %{
               "user_id" => owner.id,
               "role" => "owner",
               "can_manage" => true,
               "can_grant_owner" => true
             }

      assert [
               %{"user_id" => owner_id, "role" => "owner", "email" => owner_email},
               %{"user_id" => member_id, "role" => "member", "name" => "Mia", "sso" => false}
             ] = data["members"]

      assert {owner_id, owner_email, member_id} == {owner.id, owner.email, member.id}
      assert {:ok, _, _} = DateTime.from_iso8601(hd(data["members"])["joined_at"])
    end

    test "names a phone-only Feishu member from the SSO identity", %{conn: conn, org: org} do
      {:ok, user} = %User{} |> User.changeset(%{"name" => ""}) |> Repo.insert()
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

      members =
        conn |> get(members_path(org)) |> json_response(200) |> get_in(["data", "members"])

      assert %{
               "name" => "Feishu Phone User",
               "email" => nil,
               "mobile" => "+10000000001",
               "sso" => true,
               "sso_provider" => "feishu"
             } = Enum.find(members, &(&1["user_id"] == user.id))
    end

    test "a member may list but cannot manage", %{org: org} do
      member = add_member(org, "member")

      data =
        build_conn()
        |> log_in_user(member)
        |> get(members_path(org))
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["viewer"]["can_manage"] == false
      assert data["viewer"]["can_grant_owner"] == false
      assert length(data["members"]) == 2
    end

    test "answers 404 to a non-member", %{org: org} do
      outsider = user_fixture()

      assert %{"error" => %{"code" => "org_not_found"}} =
               build_conn()
               |> log_in_user(outsider)
               |> get(members_path(org))
               |> json_response(404)
    end
  end

  describe "POST /dashboard/api/v1/orgs/:org/members" do
    test "invites a new user and records the audit", %{conn: conn, org: org, user: owner} do
      data =
        conn
        |> post(members_path(org), %{"email" => " New@Example.com ", "role" => "admin"})
        |> json_response(200)
        |> Map.fetch!("data")

      {:ok, invitee} = Accounts.get_user_by_email("new@example.com")
      assert {:ok, "admin"} = Memberships.org_role(org.id, invitee.id)
      assert Enum.any?(data["members"], &(&1["user_id"] == invitee.id and &1["role"] == "admin"))

      assert [audit] = Observability.list_audit_logs(org.id, action: "org_member.granted")
      assert audit.actor_user_id == owner.id
      assert audit.resource_id == invitee.id
      assert audit.redacted_diff["role"] == %{"from" => nil, "to" => "admin"}
    end

    test "rejects an invalid email or role", %{conn: conn, org: org} do
      assert %{"error" => %{"code" => "invalid_email"}} =
               conn |> post(members_path(org), %{"email" => "  "}) |> json_response(422)

      assert %{"error" => %{"code" => "invalid_email"}} =
               conn |> post(members_path(org), %{"email" => "not-an-email"}) |> json_response(422)

      assert %{"error" => %{"code" => "invalid_role"}} =
               conn
               |> post(members_path(org), %{"email" => "x@example.com", "role" => "root"})
               |> json_response(422)

      assert {:error, :not_found} = Accounts.get_user_by_email("x@example.com")
    end

    test "does not change an existing member's role", %{conn: conn, org: org} do
      member = add_member(org, "member")

      assert %{"error" => %{"code" => "already_member"}} =
               conn
               |> post(members_path(org), %{"email" => member.email, "role" => "admin"})
               |> json_response(409)

      assert {:ok, "member"} = Memberships.org_role(org.id, member.id)
    end

    test "only an owner may invite an owner", %{org: org} do
      admin_conn = org |> add_member("admin") |> then(&log_in_user(build_conn(), &1))

      assert %{"error" => %{"code" => "owner_required"}} =
               admin_conn
               |> post(members_path(org), %{"email" => "boss@example.com", "role" => "owner"})
               |> json_response(403)

      assert {:error, :not_found} = Accounts.get_user_by_email("boss@example.com")

      assert %{"data" => _} =
               admin_conn
               |> post(members_path(org), %{"email" => "helper@example.com", "role" => "admin"})
               |> json_response(200)
    end
  end

  describe "PATCH /dashboard/api/v1/orgs/:org/members/:user_id" do
    test "changes a role and records the audit", %{conn: conn, org: org, user: owner} do
      member = add_member(org, "member")

      data =
        conn
        |> patch(member_path(org, member), %{"role" => "admin"})
        |> json_response(200)
        |> Map.fetch!("data")

      assert {:ok, "admin"} = Memberships.org_role(org.id, member.id)
      assert Enum.any?(data["members"], &(&1["user_id"] == member.id and &1["role"] == "admin"))

      assert [audit] = Observability.list_audit_logs(org.id, action: "org_member.role_changed")
      assert audit.actor_user_id == owner.id
      assert audit.redacted_diff["role"] == %{"from" => "member", "to" => "admin"}
    end

    test "refuses to demote the last owner", %{conn: conn, org: org, user: owner} do
      assert %{"error" => %{"code" => "last_owner"}} =
               conn |> patch(member_path(org, owner), %{"role" => "admin"}) |> json_response(409)

      assert {:ok, "owner"} = Memberships.org_role(org.id, owner.id)

      second_owner = add_member(org, "owner")

      assert %{"data" => _} =
               conn |> patch(member_path(org, owner), %{"role" => "admin"}) |> json_response(200)

      assert {:ok, "admin"} = Memberships.org_role(org.id, owner.id)
      assert {:ok, "owner"} = Memberships.org_role(org.id, second_owner.id)
    end

    test "an admin can neither grant nor revoke the owner role", %{org: org, user: owner} do
      admin = add_member(org, "admin")
      member = add_member(org, "member")
      _second_owner = add_member(org, "owner")
      admin_conn = log_in_user(build_conn(), admin)

      assert %{"error" => %{"code" => "owner_required"}} =
               admin_conn
               |> patch(member_path(org, member), %{"role" => "owner"})
               |> json_response(403)

      assert %{"error" => %{"code" => "owner_required"}} =
               admin_conn
               |> patch(member_path(org, admin), %{"role" => "owner"})
               |> json_response(403)

      assert %{"error" => %{"code" => "owner_required"}} =
               admin_conn
               |> patch(member_path(org, owner), %{"role" => "member"})
               |> json_response(403)

      assert {:ok, "member"} = Memberships.org_role(org.id, member.id)
      assert {:ok, "admin"} = Memberships.org_role(org.id, admin.id)
      assert {:ok, "owner"} = Memberships.org_role(org.id, owner.id)

      assert %{"data" => _} =
               admin_conn
               |> patch(member_path(org, member), %{"role" => "admin"})
               |> json_response(200)
    end

    test "rejects an unknown member or role", %{conn: conn, org: org} do
      member = add_member(org, "member")
      outsider = user_fixture()

      for target <- [outsider.id, "not-a-uuid"] do
        assert %{"error" => %{"code" => "member_not_found"}} =
                 conn
                 |> patch(~p"/dashboard/api/v1/orgs/#{org.slug}/members/#{target}", %{
                   "role" => "admin"
                 })
                 |> json_response(404)
      end

      assert %{"error" => %{"code" => "invalid_role"}} =
               conn |> patch(member_path(org, member), %{"role" => "root"}) |> json_response(422)
    end
  end

  describe "DELETE /dashboard/api/v1/orgs/:org/members/:user_id" do
    test "removes a member", %{conn: conn, org: org, user: owner} do
      member = add_member(org, "member")

      data = conn |> delete(member_path(org, member)) |> json_response(200) |> Map.fetch!("data")

      assert {:error, :not_found} = Memberships.org_role(org.id, member.id)
      assert Enum.map(data["members"], & &1["user_id"]) == [owner.id]

      assert %{"error" => %{"code" => "member_not_found"}} =
               conn |> delete(member_path(org, member)) |> json_response(404)
    end

    test "refuses to remove the last owner", %{conn: conn, org: org, user: owner} do
      assert %{"error" => %{"code" => "last_owner"}} =
               conn |> delete(member_path(org, owner)) |> json_response(409)

      assert {:ok, "owner"} = Memberships.org_role(org.id, owner.id)
    end

    test "an admin cannot remove an owner", %{org: org, user: owner} do
      _second_owner = add_member(org, "owner")
      admin = add_member(org, "admin")

      assert %{"error" => %{"code" => "owner_required"}} =
               build_conn()
               |> log_in_user(admin)
               |> delete(member_path(org, owner))
               |> json_response(403)

      assert {:ok, "owner"} = Memberships.org_role(org.id, owner.id)
    end
  end

  test "a member's writes are refused and audited as denied", %{org: org, user: owner} do
    member = add_member(org, "member")
    target = add_member(org, "member")
    member_conn = log_in_user(build_conn(), member)

    assert %{"error" => %{"code" => "forbidden"}} =
             member_conn
             |> post(members_path(org), %{"email" => "forged@example.com", "role" => "admin"})
             |> json_response(403)

    assert %{"error" => %{"code" => "forbidden"}} =
             member_conn
             |> patch(member_path(org, target), %{"role" => "admin"})
             |> json_response(403)

    assert %{"error" => %{"code" => "forbidden"}} =
             member_conn |> delete(member_path(org, owner)) |> json_response(403)

    assert {:error, :not_found} = Accounts.get_user_by_email("forged@example.com")
    assert {:ok, "member"} = Memberships.org_role(org.id, target.id)
    assert {:ok, "owner"} = Memberships.org_role(org.id, owner.id)

    assert [invite] =
             Observability.list_audit_logs(org.id, action: "org_member.granted", result: "denied")

    assert invite.actor_user_id == member.id
    assert is_nil(invite.resource_id)
    assert invite.reason_class == "forbidden"
    assert invite.metadata["surface"] == "members"
    assert invite.metadata["attempted_role"] == "admin"
    refute inspect(invite.metadata) =~ "forged@example.com"

    assert [role_change] =
             Observability.list_audit_logs(org.id,
               action: "org_member.role_changed",
               result: "denied"
             )

    assert role_change.resource_id == target.id
    assert role_change.metadata["attempted_role"] == "admin"

    assert [removal] =
             Observability.list_audit_logs(org.id, action: "org_member.removed", result: "denied")

    assert removal.resource_id == owner.id
    assert removal.reason_class == "forbidden"
  end

  describe "CSRF" do
    test "writes need the page's CSRF token in the x-csrf-token header", %{conn: conn, org: org} do
      member = add_member(org, "member")
      {conn, token} = csrf_session(conn, org)

      assert_error_sent(403, fn ->
        conn |> enforce_csrf() |> post(members_path(org), %{"email" => "a@example.com"})
      end)

      assert_error_sent(403, fn ->
        conn
        |> enforce_csrf()
        |> put_req_header("x-csrf-token", "forged")
        |> patch(member_path(org, member), %{"role" => "admin"})
      end)

      assert_error_sent(403, fn ->
        conn |> enforce_csrf() |> delete(member_path(org, member))
      end)

      assert {:error, :not_found} = Accounts.get_user_by_email("a@example.com")
      assert {:ok, "member"} = Memberships.org_role(org.id, member.id)

      with_token = fn -> conn |> enforce_csrf() |> put_req_header("x-csrf-token", token) end

      assert %{"ok" => true} =
               with_token.()
               |> post(members_path(org), %{"email" => "a@example.com"})
               |> json_response(200)

      assert %{"ok" => true} =
               with_token.()
               |> patch(member_path(org, member), %{"role" => "admin"})
               |> json_response(200)

      assert %{"ok" => true} =
               with_token.() |> delete(member_path(org, member)) |> json_response(200)
    end
  end

  defp add_member(org, role) do
    user = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, user.id, role)
    user
  end

  defp members_path(org), do: ~p"/dashboard/api/v1/orgs/#{org.slug}/members"

  defp member_path(org, user), do: ~p"/dashboard/api/v1/orgs/#{org.slug}/members/#{user.id}"

  # Load the SPA page the way a browser does: it stores the CSRF secret in the
  # session cookie and hands the token to the page.
  defp csrf_session(conn, org) do
    conn = get(conn, ~p"/orgs/#{org.slug}/members")

    [_, token] =
      Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

    {recycle(conn), token}
  end

  # `Phoenix.ConnTest` skips CSRF checks by default; the real browser does not.
  defp enforce_csrf(conn), do: put_private(conn, :plug_skip_csrf_protection, false)
end
