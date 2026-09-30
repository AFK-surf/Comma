defmodule BridgeForTeams.WorkspaceItemsTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.{Accounts, Memberships, Orgs, Repo, WorkspaceItems}
  alias BridgeForTeams.Schema.Project

  test "create/list/get/update/archive workspace items from the local table" do
    %{user: user, org: org, project: project} = fixture()

    assert {:ok, [report, inbox]} =
             WorkspaceItems.create_tasks(user.id, org.id, project.id, [
               %{
                 "title" => "Weekly report",
                 "category" => "reports",
                 "status" => "accepted",
                 "source" => "projection",
                 "payload" => %{"vfs_path" => "/report.md"},
                 "salix_conversation_id" => "conv-report"
               },
               %{
                 "title" => "Inbox item",
                 "category" => "inbox",
                 "status" => "suggested",
                 "source" => "user"
               }
             ])

    assert [^report] =
             WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "reports")

    assert [^inbox] =
             WorkspaceItems.list_tasks(user.id, project_id: project.id, status: "suggested")

    assert {:ok, fetched} =
             WorkspaceItems.get_task(user.id, "conv-report", project_id: project.id)

    assert fetched.id == report.id
    assert fetched.latest_artifact == %{"type" => "vfs", "path" => "/report.md"}

    assert {:ok, updated} = WorkspaceItems.update_task(report, %{"status" => "done"})
    assert updated.status == "done"

    assert {:ok, archived} = WorkspaceItems.archive_task(inbox)
    assert archived.status == "archived"

    assert WorkspaceItems.list_tasks(user.id, project_id: project.id, include_archived: false) ==
             [updated]
  end

  test "create_tasks returns an error changeset (never raises) on a duplicate salix_conversation_id" do
    %{user: user, org: org, project: project} = fixture()

    attrs = %{
      "title" => "Daily wrap-up",
      "category" => "routines",
      "status" => "ready_for_review",
      "source" => "agent",
      "salix_conversation_id" => "cnv-dup"
    }

    assert {:ok, [_first]} = WorkspaceItems.create_tasks(user.id, org.id, project.id, [attrs])

    # A second row for the same user+project reusing the conversation id collides
    # on the unique index — surfaced as a rolled-back changeset error, not a raise.
    assert {:error, %Ecto.Changeset{} = changeset} =
             WorkspaceItems.create_tasks(user.id, org.id, project.id, [attrs])

    assert %{salix_conversation_id: ["has already been taken"]} = errors_on(changeset)

    # The transaction rolled back: no partial second row landed.
    assert [_only_one] =
             WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "routines")
  end

  test "latest_artifact references do not claim payload-owned VFS identity" do
    %{user: user, org: org, project: project} = fixture()
    path = "/.salix/reports/daily-briefing/2026-07-24.md"

    assert {:ok, [routine, report]} =
             WorkspaceItems.create_tasks(user.id, org.id, project.id, [
               %{
                 "title" => "Daily briefing routine",
                 "category" => "routines",
                 "kind" => "routine_run",
                 "status" => "done",
                 "source" => "projection",
                 "salix_conversation_id" => "conv-routine",
                 "latest_artifact" => %{"type" => "vfs", "path" => path}
               },
               %{
                 "title" => "Daily briefing report",
                 "category" => "reports",
                 "kind" => "report",
                 "status" => "done",
                 "source" => "projection",
                 "salix_conversation_id" => "conv-report-owner",
                 "payload" => %{"vfs_path" => path},
                 "latest_artifact" => %{"type" => "vfs", "path" => path}
               }
             ])

    assert routine.vfs_path == nil
    assert routine.latest_artifact == %{"type" => "vfs", "path" => path}
    assert report.vfs_path == path
    assert report.payload["vfs_path"] == path
  end

  test "projected VFS upsert ignores an old-runtime non-owner reference" do
    %{user: user, org: org, project: project} = fixture()
    path = "/.salix/reports/daily-briefing/2026-07-24.md"

    assert {:ok, [reference]} =
             WorkspaceItems.create_tasks(user.id, org.id, project.id, [
               %{
                 "title" => "Old runtime routine reference",
                 "category" => "routines",
                 "kind" => "routine_run",
                 "status" => "done",
                 "source" => "projection",
                 "vfs_path" => path,
                 "payload" => %{},
                 "latest_artifact" => %{"type" => "vfs", "path" => path}
               }
             ])

    assert {:error, :not_found} =
             WorkspaceItems.get_task(user.id, path, project_id: project.id)

    assert {:ok, [owner]} =
             WorkspaceItems.upsert_projected_items(project, user.id, [
               %{
                 "title" => "Daily briefing report",
                 "category" => "reports",
                 "kind" => "report",
                 "status" => "done",
                 "source" => "projection",
                 "payload" => %{"vfs_path" => path},
                 "latest_artifact" => %{"type" => "vfs", "path" => path}
               }
             ])

    refute owner.id == reference.id
    assert owner.vfs_path == path
    assert owner.payload["vfs_path"] == path

    assert {:ok, fetched_owner} =
             WorkspaceItems.get_task(user.id, path, project_id: project.id)

    assert fetched_owner.id == owner.id

    assert {:ok, fetched_reference} =
             WorkspaceItems.get_task(user.id, reference.id, project_id: project.id)

    assert fetched_reference.payload == %{}
    assert fetched_reference.vfs_path == path
  end

  test "seeded? is satisfied by local source refs only" do
    %{user: user, org: org, project: project} = fixture()

    refute WorkspaceItems.seeded?(user.id, project.id)

    assert {:ok, :seeded} =
             WorkspaceItems.ensure_seeded(user.id, org.id, project.id, [
               %{"title" => "Seed", "category" => "general"}
             ])

    assert WorkspaceItems.seeded?(user.id, project.id)
    assert {:ok, :already_seeded} = WorkspaceItems.ensure_seeded(user.id, org.id, project.id, [])
  end

  defp fixture do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.create_user(%{"email" => "workspace-items-#{n}@example.com"})
    {:ok, org} = Orgs.create_org(%{"name" => "Org #{n}", "slug" => "wi-#{n}"})
    {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "owner")

    project =
      Repo.insert!(%Project{
        org_id: org.id,
        name: "Project #{n}",
        slug: "project-#{n}",
        salix_group_id: SalixStore.Ids.new_group_id(org.salix_tenant_id),
        created_by_user_id: user.id
      })

    %{user: user, org: org, project: project}
  end
end
