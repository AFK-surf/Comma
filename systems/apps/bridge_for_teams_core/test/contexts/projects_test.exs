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
      # group and then assigns the default router after the agent is provisioned.
      assert ops == ["create_group", "update_group"]

      assert Enum.all?(project_rows, &(&1.status == "pending"))

      assert [agent_row] =
               Repo.all(ReconcileOutbox)
               |> Enum.filter(&(&1.aggregate == "agent" and &1.aggregate_id == router.id))

      assert agent_row.op == "create_owned_agent"
      assert agent_row.payload["attrs"]["role"] == "router"
      assert agent_row.payload["attrs"]["group_id"] == p.salix_group_id
      # VM is requested by default so OAuth-backed tasks work out of the box.
      assert p.vm_enabled == true
      assert agent_row.payload["attrs"]["vm"] == %{"enabled" => true}

      update_row = Enum.find(project_rows, &(&1.op == "update_group"))
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

    test "the default router follows the org Router default instead of copying it", %{
      org: org
    } do
      {:ok, org} = Orgs.update_org(org, %{"default_router_template_id" => "tmpl-default"})

      assert {:ok, %Project{} = p} = Projects.create_project(org.id, %{name: "P", slug: "p"})

      assert %Agent{} = router = pending_router(p.id)
      refute router.salix["template_id"]

      assert [agent_row] =
               Repo.all(ReconcileOutbox)
               |> Enum.filter(&(&1.aggregate == "agent" and &1.aggregate_id == router.id))

      assert agent_row.op == "create_owned_agent"
      refute agent_row.payload["attrs"]["template_id"]
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

    test "records project creation audit when a creator is supplied", %{org: org} do
      {:ok, user} = Accounts.create_user(%{email: "creator-audit@example.com"})

      assert {:ok, %Project{} = project} =
               Projects.create_project(org.id, %{name: "Audited", slug: "audited"},
                 creator_user_id: user.id,
                 actor_label: "creator-audit@example.com",
                 request_id: "req_project_create"
               )

      assert [audit] = Observability.list_audit_logs(org.id, action: "project.created")
      assert audit.actor_user_id == user.id
      assert audit.actor_label == "creator-audit@example.com"
      assert audit.resource_type == "project"
      assert audit.resource_id == project.id
      assert audit.resource_label == "Audited"
      assert audit.request_id == "req_project_create"
      assert audit.metadata["salix_group_id"] == project.salix_group_id
    end

    test "records failed project creation attempts without raw submitted values", %{org: org} do
      {:ok, user} = Accounts.create_user(%{email: "creator-failed-audit@example.com"})

      assert {:error, changeset} =
               Projects.create_project(org.id, %{name: "", slug: "invalid-create"},
                 creator_user_id: user.id,
                 actor_label: "creator-failed-audit@example.com",
                 request_id: "req_project_create_failed"
               )

      assert %{name: _} = errors_on(changeset)

      assert [audit] = Observability.list_audit_logs(org.id, action: "project.created")
      assert audit.actor_user_id == user.id
      assert audit.actor_label == "creator-failed-audit@example.com"
      assert audit.resource_type == "project"
      assert audit.resource_id == nil
      assert audit.result == "failed"
      assert audit.reason_class == "validation_failed"
      assert audit.request_id == "req_project_create_failed"
      assert audit.metadata["write_attempt"] in [true, "true"]
      assert audit.metadata["validation_fields"] == ["name"]
      assert audit.metadata["attempted_fields"] == ["name", "slug"]
      refute Map.has_key?(audit.metadata, "submitted_name")
      refute Map.has_key?(audit.metadata, "submitted_slug")

      assert [event] = Observability.list_events(org.id, audit_log_id: audit.id)
      assert event.event_type == "audit.project.created"
      assert event.status == "failed"
      assert event.correlation_id == "req_project_create_failed"
    end

    test "rolls back outbox if the row is invalid", %{org: org} do
      {:ok, _} = Projects.create_project(org.id, %{name: "Dup", slug: "dup"})
      before = Repo.aggregate(ReconcileOutbox, :count)
      assert {:error, cs} = Projects.create_project(org.id, %{name: "Dup2", slug: "dup"})
      assert %{slug: ["has already been taken"]} = errors_on(cs)
      assert Repo.aggregate(ReconcileOutbox, :count) == before
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

    test "the quota is counted per org", %{org: org} do
      {:ok, other_org} = Orgs.create_org(%{name: "Beta", slug: "beta"})
      {:ok, member} = Accounts.create_user(%{email: "quota-two-orgs@example.com"})
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
      {:ok, _} = Memberships.put_org_member(other_org.id, member.id, "member")

      assert {:ok, _} =
               Projects.create_project(org.id, %{name: "A", slug: "a"},
                 creator_user_id: member.id
               )

      assert {:ok, _} =
               Projects.create_project(other_org.id, %{name: "B", slug: "b"},
                 creator_user_id: member.id
               )
    end

    test "archiving the member's project frees the quota", %{org: org} do
      {:ok, member} = Accounts.create_user(%{email: "quota-archive@example.com"})
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

      {:ok, first} =
        Projects.create_project(org.id, %{name: "First", slug: "first"},
          creator_user_id: member.id
        )

      {:ok, _} = Projects.archive_project(first)

      assert Projects.can_create_project?(org.id, member.id)

      assert {:ok, _} =
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

    test "a quota rejection records a failed create audit", %{org: org} do
      {:ok, member} = Accounts.create_user(%{email: "quota-audit@example.com"})
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

      {:ok, _} =
        Projects.create_project(org.id, %{name: "First", slug: "first"},
          creator_user_id: member.id
        )

      assert {:error, :project_quota_reached} =
               Projects.create_project(org.id, %{name: "Second", slug: "second"},
                 creator_user_id: member.id,
                 actor_label: "quota-audit@example.com"
               )

      audits = Observability.list_audit_logs(org.id, action: "project.created")

      assert Enum.any?(
               audits,
               &(&1.result == "failed" and &1.reason_class == "project_quota_reached")
             )
    end
  end

  test "get_project / get_project_by_salix_group", %{org: org} do
    {:ok, p} = Projects.create_project(org.id, %{name: "P", slug: "p"})
    assert {:ok, ^p} = Projects.get_project(p.id)
    assert {:ok, found} = Projects.get_project_by_salix_group(p.salix_group_id)
    assert found.id == p.id
    assert {:error, :not_found} = Projects.get_project_by_salix_group("proj_nope")
  end

  test "list_projects excludes archived", %{org: org} do
    {:ok, p1} = Projects.create_project(org.id, %{name: "A", slug: "a"})
    {:ok, p2} = Projects.create_project(org.id, %{name: "B", slug: "b"})
    {:ok, _} = Projects.archive_project(p2)

    ids = Projects.list_projects(org.id) |> Enum.map(& &1.id)
    assert p1.id in ids
    refute p2.id in ids
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
          email: "default-#{System.unique_integer([:positive])}@example.com"
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

    test "falls back to the earliest swarm the user is a member of at all", %{
      org: org,
      user: user
    } do
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      {:ok, _p1} = Projects.create_project(org.id, %{name: "A", slug: "a"})
      {:ok, p2} = Projects.create_project(org.id, %{name: "B", slug: "b"})
      {:ok, _} = Memberships.put_project_member(p2.id, user.id, "user")

      assert Projects.default_project_for_user(org.id, user.id).id == p2.id
    end

    test "org owners/admins without explicit grants get the org's first project by creation time",
         %{org: org, user: user} do
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "owner")
      # Created first but alphabetically last — creation order must win.
      {:ok, pz} = Projects.create_project(org.id, %{name: "Zulu", slug: "zulu"})
      {:ok, _pa} = Projects.create_project(org.id, %{name: "Alpha", slug: "alpha"})

      assert Projects.default_project_for_user(org.id, user.id).id == pz.id
    end

    test "plain org members with no project grants get nothing — not someone else's swarm", %{
      org: org,
      user: user
    } do
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      {:ok, _p} = Projects.create_project(org.id, %{name: "Private", slug: "private"})

      assert Projects.default_project_for_user(org.id, user.id) == nil
    end

    test "archived projects never resolve", %{org: org, user: user} do
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

      {:ok, owned} =
        Projects.create_project(org.id, %{name: "Owned", slug: "owned"}, creator_user_id: user.id)

      {:ok, p2} = Projects.create_project(org.id, %{name: "B", slug: "b"})
      {:ok, _} = Memberships.put_project_member(p2.id, user.id, "user")
      {:ok, _} = Projects.archive_project(owned)

      assert Projects.default_project_for_user(org.id, user.id).id == p2.id

      {:ok, _} = Projects.archive_project(p2)
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
          email: "ensure-#{System.unique_integer([:positive])}@example.com"
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
      assert project.slug == "my-swarm-" <> BridgeForTeams.Artifacts.user_suffix(user.id)

      # Creation went through create_project/3: the creator owns it (admin
      # ACL — ownership in this model), so the dashboard default resolves it.
      assert Projects.default_project_for_user(org.id, user.id).id == project.id
    end

    test "returns the existing owned swarm untouched — idempotent", %{org: org, user: user} do
      assert {:ok, project} = Projects.ensure_owned_project(org.id, user.id, "My Swarm")
      assert {:ok, again} = Projects.ensure_owned_project(org.id, user.id, "Different Name")

      assert again.id == project.id
      assert again.name == "My Swarm"
      assert length(Projects.list_projects(org.id)) == 1
    end

    test "plain membership in someone else's swarm still gets a swarm of their own", %{
      org: org,
      user: user
    } do
      {:ok, foreign} = Projects.create_project(org.id, %{name: "Theirs", slug: "theirs"})
      {:ok, _} = Memberships.put_project_member(foreign.id, user.id, "user")

      assert {:ok, own} = Projects.ensure_owned_project(org.id, user.id, "My Swarm")
      assert own.id != foreign.id
      assert Projects.default_project_for_user(org.id, user.id).id == own.id
    end

    test "a name that slugifies to nothing falls back to the swarm- slug", %{
      org: org,
      user: user
    } do
      assert {:ok, project} = Projects.ensure_owned_project(org.id, user.id, "测试")
      assert project.slug == "swarm-" <> BridgeForTeams.Artifacts.user_suffix(user.id)
    end

    test "an org owner's implied project admin is access, not ownership — still creates", %{
      org: org,
      user: user
    } do
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "owner")
      {:ok, existing} = Projects.create_project(org.id, %{name: "First", slug: "first"})

      # Org admins reach every swarm through the inherited role, but counting
      # that as ownership would mean they never get a swarm of their own.
      assert {:ok, own} = Projects.ensure_owned_project(org.id, user.id, "My Swarm")
      assert own.id != existing.id
      assert own.created_by_user_id == user.id

      # An explicit admin ACL is ownership — idempotent from here on.
      assert {:ok, resolved} = Projects.ensure_owned_project(org.id, user.id, "Another")
      assert resolved.id == own.id
      assert length(Projects.list_projects(org.id)) == 2
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

  test "archive_project sets archived_at + status and releases the slug", %{org: org} do
    {:ok, p} = Projects.create_project(org.id, %{name: "P", slug: "p"})
    assert {:ok, archived} = Projects.archive_project(p)
    assert archived.archived_at
    assert archived.status == "archived"
    assert archived.slug == nil
  end

  test "archiving releases the slug so the same name can be recreated", %{org: org} do
    {:ok, p} = Projects.create_project(org.id, %{name: "Test"})
    assert p.slug == "test"
    {:ok, _} = Projects.archive_project(p)

    assert {:ok, again} = Projects.create_project(org.id, %{name: "Test"})
    assert again.slug == "test"
    assert again.id != p.id
  end

  test "archive_project with an actor records project audit", %{org: org} do
    {:ok, actor} = Accounts.create_user(%{email: "archive-admin@example.com"})
    {:ok, p} = Projects.create_project(org.id, %{name: "P", slug: "p"})

    assert {:ok, archived} =
             Projects.archive_project(p,
               actor_user_id: actor.id,
               actor_label: "archive-admin@example.com",
               request_id: "req_project_archive"
             )

    assert [audit] = Observability.list_audit_logs(org.id, action: "project.archived")
    assert audit.actor_user_id == actor.id
    assert audit.resource_id == p.id
    assert audit.resource_label == archived.name
    assert audit.request_id == "req_project_archive"
    assert audit.redacted_diff["status"] == %{"from" => p.status, "to" => "archived"}
    assert audit.redacted_diff["archived_at"]["to"] == DateTime.to_iso8601(archived.archived_at)
    assert audit.redacted_diff["slug"] == %{"from" => "p", "to" => nil}
  end

  describe "update_project/3" do
    test "records generic project update audit when an actor is supplied", %{org: org} do
      {:ok, actor} = Accounts.create_user(%{email: "update-admin@example.com"})
      {:ok, project} = Projects.create_project(org.id, %{name: "Config", slug: "config"})

      assert {:ok, updated} =
               Projects.update_project(
                 project,
                 %{slug: "config-updated", status: "paused"},
                 actor_user_id: actor.id,
                 actor_label: "update-admin@example.com",
                 request_id: "req_project_update"
               )

      assert updated.slug == "config-updated"
      assert updated.status == "paused"

      assert [audit] = Observability.list_audit_logs(org.id, action: "project.updated")
      assert audit.actor_user_id == actor.id
      assert audit.actor_label == "update-admin@example.com"
      assert audit.resource_type == "project"
      assert audit.resource_id == project.id
      assert audit.resource_label == "Config"
      assert audit.request_id == "req_project_update"
      assert audit.metadata["project_id"] == project.id
      assert audit.redacted_diff["slug"] == %{"from" => "config", "to" => "config-updated"}
      assert audit.redacted_diff["status"] == %{"from" => "active", "to" => "paused"}

      assert [event] = Observability.list_events(org.id, audit_log_id: audit.id)
      assert event.domain == "audit"
      assert event.event_type == "audit.project.updated"
      assert event.correlation_id == "req_project_update"
    end

    test "records failed generic project update attempts without raw submitted values", %{
      org: org
    } do
      {:ok, actor} = Accounts.create_user(%{email: "update-failed-admin@example.com"})

      {:ok, project} =
        Projects.create_project(org.id, %{name: "Existing Project", slug: "existing"})

      assert {:error, changeset} =
               Projects.update_project(
                 project,
                 %{name: ""},
                 actor_user_id: actor.id,
                 actor_label: "update-failed-admin@example.com",
                 request_id: "req_project_update_failed"
               )

      assert %{name: _} = errors_on(changeset)

      assert [audit] = Observability.list_audit_logs(org.id, action: "project.updated")
      assert audit.actor_user_id == actor.id
      assert audit.resource_type == "project"
      assert audit.resource_id == project.id
      assert audit.result == "failed"
      assert audit.reason_class == "validation_failed"
      assert audit.request_id == "req_project_update_failed"
      assert audit.metadata["write_attempt"] in [true, "true"]
      assert audit.metadata["validation_fields"] == ["name"]
      assert audit.metadata["attempted_fields"] == ["name"]
      refute Map.has_key?(audit.metadata, "submitted_name")
      refute Map.has_key?(audit.metadata, "raw_name")

      assert [event] = Observability.list_events(org.id, audit_log_id: audit.id)
      assert event.event_type == "audit.project.updated"
      assert event.status == "failed"
      assert event.correlation_id == "req_project_update_failed"
    end
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

    test "records project rename audit when an actor is supplied", %{org: org} do
      {:ok, actor} = Accounts.create_user(%{email: "rename-admin@example.com"})
      {:ok, p} = Projects.create_project(org.id, %{name: "Old", slug: "old"})

      assert {:ok, renamed} =
               Projects.rename_project(p, "New name",
                 actor_user_id: actor.id,
                 actor_label: "rename-admin@example.com",
                 request_id: "req_project_rename"
               )

      assert [audit] = Observability.list_audit_logs(org.id, action: "project.renamed")
      assert audit.actor_user_id == actor.id
      assert audit.resource_id == p.id
      assert audit.resource_label == renamed.name
      assert audit.request_id == "req_project_rename"
      assert audit.redacted_diff["name"] == %{"from" => "Old", "to" => "New name"}
    end

    test "rejects a blank name and enqueues nothing", %{org: org} do
      {:ok, p} = Projects.create_project(org.id, %{name: "Keep", slug: "keep"})
      before = Repo.aggregate(ReconcileOutbox, :count)

      assert {:error, cs} = Projects.rename_project(p, "")
      assert %{name: _} = errors_on(cs)

      assert {:ok, reloaded} = Projects.get_project(p.id)
      assert reloaded.name == "Keep"
      assert Repo.aggregate(ReconcileOutbox, :count) == before
    end
  end

  describe "set_vm_enabled/3" do
    test "toggling off flips the flag and enqueues a vm update per agent", %{org: org} do
      {:ok, project} = Projects.create_project(org.id, %{name: "P", slug: "p"})
      router = pending_router(project.id)

      assert {:ok, updated} = Projects.set_vm_enabled(project, false)
      assert updated.vm_enabled == false

      assert [vm_row] =
               Repo.all(ReconcileOutbox)
               |> Enum.filter(
                 &(&1.aggregate == "agent" and &1.aggregate_id == router.id and
                     &1.op == "apply_product_vm_default")
               )

      assert vm_row.payload["attrs"]["vm"] == %{"enabled" => false}
      assert vm_row.payload["agent_id"] == router.salix_agent_id
      assert vm_row.payload["tenant_id"] == org.salix_tenant_id
    end

    test "a swarm can be created VM-less and enabled later", %{org: org} do
      {:ok, project} = Projects.create_project(org.id, %{name: "Q", slug: "q"})
      {:ok, off} = Projects.set_vm_enabled(project, false)

      # Re-enabling flips it back and enqueues the enable update.
      assert {:ok, on} = Projects.set_vm_enabled(off, true)
      assert on.vm_enabled == true

      router = pending_router(project.id)

      enables =
        Repo.all(ReconcileOutbox)
        |> Enum.filter(
          &(&1.aggregate_id == router.id and &1.op == "apply_product_vm_default" and
              &1.payload["attrs"]["vm"] == %{"enabled" => true})
        )

      assert length(enables) == 1
    end
  end
end
