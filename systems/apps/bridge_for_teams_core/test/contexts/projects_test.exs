defmodule BridgeForTeams.ProjectsTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.{Accounts, Agents, Memberships, Observability, Orgs, Projects}
  alias BridgeForTeams.Schema.{Agent, Project, ReconcileOutbox}

  setup do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
    %{org: org}
  end

  defp pending_router(project_id) do
    association = Repo.get_by!(Agent, project_id: project_id, role: "router")
    {:ok, pending} = Agents.get_agent(association.id)
    assert pending.provisioning == "provisioning"
    assert association.salix["name"] == nil
    pending
  end

  describe "create_project/2" do
    test "assigns a salix group id, creates a router agent, and enqueues reconcile", %{
      org: org
    } do
      assert {:ok, %Project{} = p} = Projects.create_project(org.id, %{name: "P", slug: "p"})
      assert SalixStore.Ids.valid_group_id_for_tenant?(p.salix_group_id, org.salix_tenant_id)

      assert %Agent{} = router = pending_router(p.id)
      assert router.role == "router"
      assert router.slot == "router"
      assert router.salix["name"] == "Router"
      assert SalixStore.Ids.valid_agent_id_for_group?(router.salix_agent_id, p.salix_group_id)

      project_rows =
        Repo.all(ReconcileOutbox)
        |> Enum.filter(&(&1.aggregate == "project" and &1.aggregate_id == p.id))

      ops = Enum.map(project_rows, & &1.op) |> Enum.sort()
      # The org's tenant is created by Orgs.create_org; the project creates a
      # group, assigns the default router after the agent is provisioned, and
      # turns on the group's Cloud VM switch.
      assert ops == ["create_group", "update_group", "update_group"]

      assert Enum.all?(project_rows, &(&1.status == "pending"))

      assert [agent_row] =
               Repo.all(ReconcileOutbox)
               |> Enum.filter(&(&1.aggregate == "agent" and &1.aggregate_id == router.id))

      assert agent_row.op == "create_owned_agent"
      assert agent_row.payload["attrs"]["role"] == "router"
      assert agent_row.payload["attrs"]["group_id"] == p.salix_group_id
      # VM is on by default so OAuth-backed tasks work out of the box: it is
      # the group's switch, not the router's.
      assert p.vm_enabled == true
      refute Map.has_key?(agent_row.payload["attrs"], "vm")

      assert [%{"cloud_vm_enabled" => true}] =
               for(
                 %{op: "update_group", payload: %{"attrs" => %{"cloud_vm_enabled" => _} = a}} <-
                   project_rows,
                 do: a
               )

      update_row =
        Enum.find(
          project_rows,
          &(&1.op == "update_group" and Map.has_key?(&1.payload["attrs"], "router_agent_id"))
        )

      assert update_row.payload["attrs"]["router_agent_id"] == router.salix_agent_id

      assert update_row.payload["attrs"]["billing_owner"]["billing_account_id"] ==
               org.billing_account_id

      assert update_row.payload["attrs"]["billing_owner"]["salix_group_id"] == p.salix_group_id

      assert update_row.payload["attrs"]["billing_owner"]["router_agent_id"] ==
               router.salix_agent_id

      create_row = Enum.find(project_rows, &(&1.op == "create_group"))

      assert create_row.payload["attrs"]["billing_owner"]["billing_account_id"] ==
               org.billing_account_id
    end

    test "the default router gets a copy of the org Router default model", %{org: org} do
      choice = %{"kind" => "catalog", "model" => "gpt-5.5"}
      {:ok, org} = Orgs.update_org(org, %{"default_router_model" => choice})

      assert {:ok, %Project{} = p} = Projects.create_project(org.id, %{name: "P", slug: "p"})

      assert %Agent{} = router = pending_router(p.id)
      assert router.salix["model"] == choice

      assert [agent_row] =
               Repo.all(ReconcileOutbox)
               |> Enum.filter(&(&1.aggregate == "agent" and &1.aggregate_id == router.id))

      assert agent_row.op == "create_owned_agent"
      assert agent_row.payload["attrs"]["model"] == choice
    end

    test "grants the creator explicit Agent Swarm admin access", %{org: org} do
      {:ok, user} = Accounts.create_user(%{email: "creator@example.com"})

      assert {:ok, %Project{} = project} =
               Projects.create_project(org.id, %{name: "Private", slug: "private"},
                 creator_user_id: user.id
               )

      assert {:ok, "admin"} = Memberships.project_role(project.id, user.id)
    end

    test "seeds the salix group's owner emails from the swarm owner set", %{org: org} do
      {:ok, org_admin} = Accounts.create_user(%{email: "org-admin@example.com"})
      {:ok, _} = Memberships.put_org_member(org.id, org_admin.id, "admin")
      {:ok, creator} = Accounts.create_user(%{email: "creator@example.com"})

      assert {:ok, %Project{} = project} =
               Projects.create_project(org.id, %{name: "Owned", slug: "owned"},
                 creator_user_id: creator.id
               )

      create_row =
        Repo.all(ReconcileOutbox)
        |> Enum.find(&(&1.op == "create_group" and &1.aggregate_id == project.id))

      assert create_row.payload["attrs"]["owner_emails"] ==
               ["creator@example.com", "org-admin@example.com"]

      assert Projects.owner_emails(project) == ["creator@example.com", "org-admin@example.com"]
    end
  end

  describe "member Agent Swarm quota" do
    test "an ordinary member can create exactly one project per org", %{org: org} do
      {:ok, member} = Accounts.create_user(%{email: "quota-member@example.com"})
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

      assert Projects.can_create_project?(org.id, member.id)

      assert {:ok, %Project{} = first} =
               Projects.create_project(org.id, %{name: "First", slug: "first"},
                 creator_user_id: member.id
               )

      assert first.created_by_user_id == member.id
      refute Projects.can_create_project?(org.id, member.id)

      assert {:error, :project_quota_reached} =
               Projects.create_project(org.id, %{name: "Second", slug: "second"},
                 creator_user_id: member.id
               )
    end

    test "org owners and admins are not quota-limited", %{org: org} do
      {:ok, admin} = Accounts.create_user(%{email: "quota-admin@example.com"})
      {:ok, _} = Memberships.put_org_member(org.id, admin.id, "admin")

      assert {:ok, _} =
               Projects.create_project(org.id, %{name: "A", slug: "a"}, creator_user_id: admin.id)

      assert {:ok, _} =
               Projects.create_project(org.id, %{name: "B", slug: "b"}, creator_user_id: admin.id)

      assert Projects.can_create_project?(org.id, admin.id)
    end
  end

  test "list_projects_for_user returns org admin projects and explicit ACL grants only", %{
    org: org
  } do
    {:ok, owner} = Accounts.create_user(%{email: "owner@example.com"})
    {:ok, member} = Accounts.create_user(%{email: "member@example.com"})
    {:ok, outsider} = Accounts.create_user(%{email: "outsider@example.com"})

    {:ok, _} = Memberships.put_org_member(org.id, owner.id, "admin")
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

    {:ok, p1} =
      Projects.create_project(org.id, %{name: "A", slug: "a"}, creator_user_id: member.id)

    {:ok, p2} = Projects.create_project(org.id, %{name: "B", slug: "b"})

    assert Projects.list_projects_for_user(org.id, owner.id) |> Enum.map(& &1.id) == [
             p1.id,
             p2.id
           ]

    assert Projects.list_projects_for_user(org.id, member.id) |> Enum.map(& &1.id) == [p1.id]
    assert Projects.list_projects_for_user(org.id, outsider.id) == []
  end

  describe "default_project_for_user/2" do
    setup %{org: org} do
      {:ok, user} =
        Accounts.create_user(%{
          email: "default-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com"
        })

      %{org: org, user: user}
    end

    test "prefers the earliest swarm the user owns (creator admin grant)", %{
      org: org,
      user: user
    } do
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

      # A plain membership on the org's first project must not outrank
      # ownership of a later one.
      {:ok, p1} = Projects.create_project(org.id, %{name: "A", slug: "a"})
      {:ok, _} = Memberships.put_project_member(p1.id, user.id, "user")

      {:ok, p2} =
        Projects.create_project(org.id, %{name: "B", slug: "b"}, creator_user_id: user.id)

      # Members may create only one swarm (quota); a second OWNED swarm comes
      # from an explicit admin grant, which resolves identically.
      {:ok, p3} = Projects.create_project(org.id, %{name: "C", slug: "c"})
      {:ok, _} = Memberships.put_project_member(p3.id, user.id, "admin")

      assert Projects.default_project_for_user(org.id, user.id).id == p2.id
    end

    test "plain org members with no project grants get nothing — not someone else's swarm", %{
      org: org,
      user: user
    } do
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      {:ok, _p} = Projects.create_project(org.id, %{name: "Private", slug: "private"})

      assert Projects.default_project_for_user(org.id, user.id) == nil
    end

    test "scoped to the org — memberships elsewhere never leak in", %{org: org, user: user} do
      {:ok, other_org} = Orgs.create_org(%{name: "Other", slug: "other-default"})
      {:ok, _} = Memberships.put_org_member(other_org.id, user.id, "member")

      {:ok, other_project} =
        Projects.create_project(other_org.id, %{name: "Theirs", slug: "theirs"},
          creator_user_id: user.id
        )

      # Owning a swarm in another org resolves nothing in this one.
      assert Projects.default_project_for_user(org.id, user.id) == nil
      assert Projects.default_project_for_user(other_org.id, user.id).id == other_project.id
    end
  end

  describe "ensure_owned_project/3" do
    setup %{org: org} do
      {:ok, user} =
        Accounts.create_user(%{
          email: "ensure-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com"
        })

      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      %{org: org, user: user}
    end

    test "creates an owned swarm with the user-suffixed slug when the user owns none", %{
      org: org,
      user: user
    } do
      assert {:ok, project} = Projects.ensure_owned_project(org.id, user.id, "My Swarm")

      assert project.name == "My Swarm"
      assert project.slug == "my-swarm-" <> String.slice(String.replace(user.id, "-", ""), 0, 8)

      # Creation went through create_project/3: the creator owns it (admin
      # ACL — ownership in this model), so the dashboard default resolves it.
      assert Projects.default_project_for_user(org.id, user.id).id == project.id
    end
  end

  test "archive durably enqueues tenant-scoped IM cleanup", %{org: org} do
    {:ok, project} = Projects.create_project(org.id, %{name: "Cleanup", slug: "cleanup"})
    assert {:ok, _} = Projects.archive_project(project)

    assert cleanup =
             Repo.get_by(ReconcileOutbox,
               aggregate_id: project.id,
               op: "delete_group_im_connects"
             )

    assert cleanup.status == "pending"

    assert cleanup.payload == %{
             "tenant_id" => org.salix_tenant_id,
             "group_id" => project.salix_group_id
           }
  end

  describe "update_project/3" do
  end

  describe "rename_project/2" do
    test "updates the name, keeps the slug, and enqueues a group rename reconcile", %{org: org} do
      {:ok, p} = Projects.create_project(org.id, %{name: "Old", slug: "old"})

      assert {:ok, renamed} = Projects.rename_project(p, "New name")
      assert renamed.name == "New name"
      assert renamed.slug == "old"

      rename_row =
        Repo.all(ReconcileOutbox)
        |> Enum.filter(&(&1.aggregate == "project" and &1.aggregate_id == p.id))
        |> Enum.find(&(&1.op == "update_group" and &1.payload["attrs"]["name"] == "New name"))

      assert rename_row
      assert rename_row.status == "pending"
      assert rename_row.payload["group_id"] == p.salix_group_id
    end
  end

  describe "set_vm_enabled/3" do
    test "toggling off flips the flag and enqueues the group's Cloud VM switch", %{org: org} do
      {:ok, project} = Projects.create_project(org.id, %{name: "P", slug: "p"})
      router = pending_router(project.id)

      assert {:ok, updated} = Projects.set_vm_enabled(project, false)
      assert updated.vm_enabled == false

      assert [vm_row] =
               Repo.all(ReconcileOutbox)
               |> Enum.filter(
                 &(&1.aggregate == "project" and &1.aggregate_id == project.id and
                     &1.op == "update_group" and
                     &1.payload["attrs"] == %{"cloud_vm_enabled" => false})
               )

      assert vm_row.payload["group_id"] == project.salix_group_id
      assert vm_row.payload["tenant_id"] == org.salix_tenant_id

      refute Enum.any?(
               Repo.all(ReconcileOutbox),
               &(&1.aggregate == "agent" and &1.aggregate_id == router.id and
                   &1.op == "apply_product_vm_default")
             )
    end
  end

  describe "converge_group_cloud_vm_page/1" do
    test "queues each live project's Cloud VM switch from vm_enabled", %{org: org} do
      {:ok, on} = Projects.create_project(org.id, %{name: "On", slug: "on"})
      {:ok, off} = Projects.create_project(org.id, %{name: "Off", slug: "off"})
      {:ok, off} = Projects.set_vm_enabled(off, false)
      {:ok, archived} = Projects.create_project(org.id, %{name: "Gone", slug: "gone"})
      {:ok, _archived} = Projects.archive_project(archived)
      Repo.delete_all(ReconcileOutbox)

      assert {:ok, %{processed: 2, next_cursor: nil}} = Projects.converge_group_cloud_vm_page(nil)

      rows = Repo.all(ReconcileOutbox)

      assert Enum.sort(for row <- rows, do: {row.aggregate_id, row.op, row.payload}) ==
               Enum.sort([
                 {on.id, "update_group",
                  %{
                    "group_id" => on.salix_group_id,
                    "tenant_id" => org.salix_tenant_id,
                    "attrs" => %{"cloud_vm_enabled" => true}
                  }},
                 {off.id, "update_group",
                  %{
                    "group_id" => off.salix_group_id,
                    "tenant_id" => org.salix_tenant_id,
                    "attrs" => %{"cloud_vm_enabled" => false}
                  }}
               ])

      assert Enum.all?(rows, &(&1.status == "pending"))

      # Past the last project: nothing more.
      last = Enum.max([on.id, off.id])

      assert {:ok, %{processed: 0, next_cursor: nil}} =
               Projects.converge_group_cloud_vm_page(last)
    end
  end
end
