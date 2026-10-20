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
    assert {:error, :not_found} = Memberships.project_role(project.id, SystemsRuntime.Proc.uuid())
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
  end
end
