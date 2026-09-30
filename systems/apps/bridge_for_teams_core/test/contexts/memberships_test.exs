defmodule BridgeForTeams.MembershipsTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.{Accounts, Memberships, Observability, Orgs, Projects}

  setup do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
    {:ok, user} = Accounts.create_user(%{email: "u@x.com"})
    {:ok, project} = Projects.create_project(org.id, %{name: "Proj", slug: "proj"})
    %{org: org, user: user, project: project}
  end

  test "put_org_member upserts role", %{org: org, user: user} do
    assert {:ok, m} = Memberships.put_org_member(org.id, user.id, "member")
    assert m.role == "member"
    assert {:ok, m2} = Memberships.put_org_member(org.id, user.id, "admin")
    assert m2.id == m.id
    assert m2.role == "admin"
    assert {:ok, "admin"} = Memberships.org_role(org.id, user.id)
  end

  test "org_role not found", %{org: org} do
    assert {:error, :not_found} = Memberships.org_role(org.id, Ecto.UUID.generate())
  end

  test "project_role derives from org membership", %{org: org, user: user, project: project} do
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "owner")
    # org owner ⇒ project admin baseline
    assert {:ok, "admin"} = Memberships.project_role(project.id, user.id)
  end

  test "org member does not imply project access; explicit project grant allows user access",
       %{org: org, user: user, project: project} do
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
    assert {:error, :not_found} = Memberships.project_role(project.id, user.id)

    {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")
    assert {:ok, "user"} = Memberships.project_role(project.id, user.id)
  end

  test "explicit project admin grant outranks user grant", %{user: user, project: project} do
    {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")
    assert {:ok, "user"} = Memberships.project_role(project.id, user.id)

    {:ok, _} = Memberships.put_project_member(project.id, user.id, "admin")
    assert {:ok, "admin"} = Memberships.project_role(project.id, user.id)
  end

  test "no membership ⇒ project_role not_found", %{project: project} do
    assert {:error, :not_found} = Memberships.project_role(project.id, Ecto.UUID.generate())
  end

  test "bounded project members apply the limit in stable role order", %{project: project} do
    suffix = System.unique_integer([:positive])

    for {email, role} <- [
          {"z-#{suffix}@example.com", "user"},
          {"b-#{suffix}@example.com", "admin"},
          {"a-#{suffix}@example.com", "admin"},
          {"c-#{suffix}@example.com", "user"},
          {"d-#{suffix}@example.com", "user"}
        ] do
      {:ok, member} = Accounts.create_user(%{email: email})
      {:ok, _membership} = Memberships.put_project_member(project.id, member.id, role)
    end

    assert {:ok, page} = Memberships.list_project_members_bounded(project.id, 3)
    assert page.completeness == :truncated
    assert page.truncated

    assert Enum.map(page.members, &{&1.role, &1.user.email}) == [
             {"admin", "a-#{suffix}@example.com"},
             {"admin", "b-#{suffix}@example.com"},
             {"user", "c-#{suffix}@example.com"}
           ]
  end

  test "bounded project members prove completeness when the whole roster fits", %{
    project: project
  } do
    suffix = System.unique_integer([:positive])

    for email <- ["b-#{suffix}@example.com", "a-#{suffix}@example.com"] do
      {:ok, member} = Accounts.create_user(%{email: email})
      {:ok, _membership} = Memberships.put_project_member(project.id, member.id, "user")
    end

    assert {:ok, %{members: members, completeness: :complete, truncated: false}} =
             Memberships.list_project_members_bounded(project.id, 3)

    assert Enum.map(members, & &1.user.email) == [
             "a-#{suffix}@example.com",
             "b-#{suffix}@example.com"
           ]
  end

  describe "authorize/3" do
    test "org min role enforced", %{org: org, user: user} do
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      assert :ok = Memberships.authorize(user.id, :read, %{org_id: org.id})

      assert {:error, :forbidden} =
               Memberships.authorize(user.id, :manage, %{org_id: org.id, min_org_role: "admin"})

      {:ok, _} = Memberships.put_org_member(org.id, user.id, "admin")

      assert :ok =
               Memberships.authorize(user.id, :manage, %{org_id: org.id, min_org_role: "admin"})
    end

    test "project min role enforced", %{org: org, user: user, project: project} do
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

      assert {:error, :forbidden} =
               Memberships.authorize(user.id, :read, %{project_id: project.id})

      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")
      assert :ok = Memberships.authorize(user.id, :read, %{project_id: project.id})

      assert {:error, :forbidden} =
               Memberships.authorize(user.id, :write, %{project_id: project.id})

      {:ok, _} = Memberships.put_project_member(project.id, user.id, "admin")
      assert :ok = Memberships.authorize(user.id, :write, %{project_id: project.id})
    end

    test "org admin has project admin access", %{org: org, user: user, project: project} do
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "admin")

      assert :ok = Memberships.authorize(user.id, :write, %{project_id: project.id})
    end

    test "no scope ⇒ forbidden", %{user: user} do
      assert {:error, :forbidden} = Memberships.authorize(user.id, :x, %{})
    end
  end

  test "remove_org_member", %{org: org, user: user} do
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
    assert :ok = Memberships.remove_org_member(org.id, user.id)
    assert {:error, :not_found} = Memberships.org_role(org.id, user.id)
    assert {:error, :not_found} = Memberships.remove_org_member(org.id, user.id)
  end

  test "remove_project_member", %{project: project, user: user} do
    {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")
    assert :ok = Memberships.remove_project_member(project.id, user.id)
    assert {:error, :not_found} = Memberships.project_role(project.id, user.id)
    assert {:error, :not_found} = Memberships.remove_project_member(project.id, user.id)
  end

  test "org membership writes with an actor record audit trail", %{org: org, user: actor} do
    {:ok, target} = Accounts.create_user(%{email: "member-audit@example.com"})

    assert {:ok, _membership} =
             Memberships.put_org_member(org.id, target.id, "member",
               actor_user_id: actor.id,
               actor_label: "admin@example.com",
               request_id: "req_org_member_grant"
             )

    assert {:ok, _membership} =
             Memberships.put_org_member(org.id, target.id, "admin",
               actor_user_id: actor.id,
               actor_label: "admin@example.com",
               request_id: "req_org_member_role"
             )

    assert [grant] = Observability.list_audit_logs(org.id, action: "org_member.granted")
    assert grant.actor_user_id == actor.id
    assert grant.actor_label == "admin@example.com"
    assert grant.resource_type == "org_member"
    assert grant.resource_id == target.id
    assert grant.request_id == "req_org_member_grant"
    assert grant.redacted_diff["role"] == %{"from" => nil, "to" => "member"}

    assert [role_change] =
             Observability.list_audit_logs(org.id, action: "org_member.role_changed")

    assert role_change.resource_id == target.id
    assert role_change.metadata["target_user_id"] == target.id
    assert role_change.redacted_diff["role"] == %{"from" => "member", "to" => "admin"}
  end

  test "project membership writes with an actor record grant role and removal audit", %{
    org: org,
    project: project,
    user: actor
  } do
    {:ok, target} = Accounts.create_user(%{email: "project-member-audit@example.com"})
    audit_opts = [actor_user_id: actor.id, actor_label: "admin@example.com"]

    assert {:ok, _membership} =
             Memberships.put_project_member(project.id, target.id, "user", audit_opts)

    assert {:ok, _membership} =
             Memberships.put_project_member(project.id, target.id, "admin", audit_opts)

    assert :ok = Memberships.remove_project_member(project.id, target.id, audit_opts)

    audits = Observability.list_audit_logs(org.id, resource_type: "project_member", limit: 10)
    actions = Enum.map(audits, & &1.action)

    assert "project_member.granted" in actions
    assert "project_member.role_changed" in actions
    assert "project_member.removed" in actions

    removal = Enum.find(audits, &(&1.action == "project_member.removed"))
    assert removal.resource_id == target.id
    assert removal.metadata["project_id"] == project.id
    assert removal.redacted_diff["role"] == %{"from" => "admin", "to" => nil}
  end

  describe "swarm owner email sync" do
    alias BridgeForTeams.Schema.ReconcileOutbox

    # update_group reconcile rows carrying the swarm's owner_emails, oldest
    # first (project creation also enqueues update_group rows, but those set
    # the router/billing_owner and never carry owner_emails).
    defp owner_email_sync_rows(project_id) do
      Repo.all(ReconcileOutbox)
      |> Enum.filter(fn row ->
        row.aggregate == "project" and row.aggregate_id == project_id and
          row.op == "update_group" and Map.has_key?(row.payload["attrs"] || %{}, "owner_emails")
      end)
      |> Enum.sort_by(& &1.created_at, DateTime)
    end

    defp last_synced_owner_emails(project_id) do
      case List.last(owner_email_sync_rows(project_id)) do
        nil -> nil
        row -> row.payload["attrs"]["owner_emails"]
      end
    end

    test "granting and revoking project admin syncs the owner email list",
         %{org: org, user: user, project: project} do
      assert owner_email_sync_rows(project.id) == []

      # A plain "user" grant does not change the owner set — no sync row.
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")
      assert owner_email_sync_rows(project.id) == []

      {:ok, _} = Memberships.put_project_member(project.id, user.id, "admin")
      assert last_synced_owner_emails(project.id) == ["u@x.com"]

      row = List.last(owner_email_sync_rows(project.id))
      assert row.payload["group_id"] == project.salix_group_id
      assert row.payload["tenant_id"] == org.salix_tenant_id
      assert row.status == "pending"

      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")
      assert last_synced_owner_emails(project.id) == []

      {:ok, _} = Memberships.put_project_member(project.id, user.id, "admin")
      assert :ok = Memberships.remove_project_member(project.id, user.id)
      assert last_synced_owner_emails(project.id) == []
      assert length(owner_email_sync_rows(project.id)) == 4
    end

    test "removing a non-admin grant does not sync", %{user: user, project: project} do
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")
      assert :ok = Memberships.remove_project_member(project.id, user.id)
      assert owner_email_sync_rows(project.id) == []
    end

    test "org owner/admin membership changes sync every non-archived swarm",
         %{org: org, user: user, project: project} do
      {:ok, other} = Projects.create_project(org.id, %{name: "Other", slug: "other"})
      {:ok, archived} = Projects.create_project(org.id, %{name: "Gone", slug: "gone"})
      {:ok, _} = Projects.archive_project(archived)

      # Ordinary org membership grants no swarm ownership — no sync.
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      assert owner_email_sync_rows(project.id) == []

      {:ok, _} = Memberships.put_org_member(org.id, user.id, "admin")
      assert last_synced_owner_emails(project.id) == ["u@x.com"]
      assert last_synced_owner_emails(other.id) == ["u@x.com"]
      assert owner_email_sync_rows(archived.id) == []

      assert :ok = Memberships.remove_org_member(org.id, user.id)
      assert last_synced_owner_emails(project.id) == []
      assert last_synced_owner_emails(other.id) == []
    end

    test "the synced list combines explicit admins and org owners, deduped and sorted",
         %{org: org, user: user, project: project} do
      {:ok, org_owner} = Accounts.create_user(%{email: "Zoe@Example.com"})
      {:ok, _} = Memberships.put_org_member(org.id, org_owner.id, "owner")
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "admin")

      assert Projects.owner_emails(project) == ["Zoe@Example.com", "u@x.com"]
      assert last_synced_owner_emails(project.id) == ["Zoe@Example.com", "u@x.com"]
    end
  end
end
