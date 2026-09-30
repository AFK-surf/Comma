defmodule BridgeForTeams.ConversationWorkspaceE2ETest do
  use BridgeForTeams.DataCase, async: false

  alias SalixStore.Keys

  alias BridgeForTeams.{
    Accounts,
    Agents,
    Conversations,
    Memberships,
    Orgs,
    TaskDelegation,
    WorkspaceItems
  }

  setup do
    SalixStore.S3.Fake.reset()

    suffix = System.unique_integer([:positive])

    {:ok, org} =
      Orgs.create_org(%{"name" => "Workspace #{suffix}", "slug" => "workspace-#{suffix}"})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Workspace",
        "slug" => "workspace-#{suffix}"
      })

    [agent | _] = Agents.list_agents(project.id)
    drain_reconcile!()

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "workspace-#{suffix}@example.test",
        "name" => "Workspace User"
      })

    {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "member")
    {:ok, _membership} = Memberships.put_project_member(project.id, user.id, "user")

    %{agent: agent, org: org, project: project, user_id: user.id}
  end

  defp drain_reconcile! do
    case BridgeForTeams.Salix.Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _count} -> drain_reconcile!()
    end
  end

  test "creates, lists, and updates workspace items through Salix conversations", %{
    org: org,
    project: project,
    user_id: user_id
  } do
    artifact_path = WorkspaceItems.artifact_path("conv-report", "v1", "daily.md")

    assert {:ok, [item]} =
             WorkspaceItems.create_tasks(user_id, org.id, project.id, [
               %{
                 "title" => "Daily Briefing",
                 "category" => "reports",
                 "platform" => "comma",
                 "status" => "accepted",
                 "source" => "onboarding",
                 "payload" => %{"summary" => "Queued", "vfs_path" => artifact_path}
               }
             ])

    assert item.category == "reports"
    assert item.kind == "report"
    assert is_nil(item.salix_conversation_id)
    assert {:ok, _uuid} = Ecto.UUID.cast(item.id)
    assert item.latest_artifact == %{"type" => "vfs", "path" => artifact_path}

    assert [listed] =
             WorkspaceItems.list_tasks(user_id, project_id: project.id, category: "reports")

    assert listed.id == item.id
    assert listed.payload["vfs_path"] == artifact_path

    next_path = WorkspaceItems.artifact_path(item.id, "v2", "daily.md")

    assert {:ok, updated} =
             WorkspaceItems.update_task(item, %{
               "status" => "ready_for_review",
               "payload" => %{"summary" => "Ready", "vfs_path" => next_path}
             })

    assert updated.status == "ready_for_review"
    assert updated.latest_artifact == %{"type" => "vfs", "path" => next_path}

    assert [ready] =
             WorkspaceItems.list_tasks(user_id,
               project_id: project.id,
               status: "ready_for_review"
             )

    assert ready.payload["summary"] == "Ready"

    assert {:ok, archived} = WorkspaceItems.archive_task(updated)
    assert archived.status == "archived"
    assert WorkspaceItems.list_tasks(user_id, project_id: project.id) == []

    assert [_archived] =
             WorkspaceItems.list_tasks(user_id, project_id: project.id, include_archived: true)
  end

  test "seeds are idempotent without using BFT task rows", %{
    org: org,
    project: project,
    user_id: user_id
  } do
    seeds = [
      %{
        "title" => "Team activity",
        "category" => "team_activity",
        "platform" => "comma",
        "status" => "ready_for_review",
        "payload" => %{"summary" => "Live conversations"}
      }
    ]

    assert {:ok, :seeded} = WorkspaceItems.ensure_seeded(user_id, org.id, project.id, seeds)

    assert {:ok, :already_seeded} =
             WorkspaceItems.ensure_seeded(user_id, org.id, project.id, seeds)

    assert [item] =
             WorkspaceItems.list_tasks(user_id, project_id: project.id, include_archived: true)

    assert item.kind == "team_activity"
    assert item.source_refs == %{"source" => "workspace_seed"}
  end

  test "agent task conversations project into general workspace tasks without owner metadata", %{
    agent: agent,
    project: project,
    user_id: user_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             Conversations.create_project_conversation(project, agent, %{
               "kind" => "agent_task",
               "title" => "Plan a Shanghai food crawl",
               "status" => "active"
             })

    assert "agent_task" in WorkspaceItems.kinds()

    assert [task] =
             WorkspaceItems.list_tasks(user_id, project_id: project.id, category: "general")

    assert {:ok, _uuid} = Ecto.UUID.cast(task.id)
    assert task.salix_conversation_id == conversation_id
    assert task.kind == "agent_task"
    assert task.title == "Plan a Shanghai food crawl"
    assert task.status == "in_progress"
    assert is_nil(task.user_id)
  end

  test "dashboard Run creates one canonical Worker Task and preserves its presentation", %{
    agent: router,
    org: org,
    project: project,
    user_id: user_id
  } do
    assert {:ok, worker} =
             BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
               project.id,
               %{
                 "name" => "Presentation Worker",
                 "role" => "worker"
               }
             )

    drain_reconcile!()

    assert {:ok, [seed]} =
             WorkspaceItems.create_tasks(user_id, org.id, project.id, [
               %{
                 "title" => "Draft the launch note",
                 "description" => "Keep the final paragraph concise",
                 "category" => "email_drafts",
                 "platform" => "gmail",
                 "status" => "accepted",
                 "source" => "onboarding",
                 "payload" => %{"to" => "team@example.com", "subject" => "Launch"},
                 "labels" => ["launch"]
               }
             ])

    assert {:ok, task} =
             TaskDelegation.dispatch(seed, actor_user_id: user_id, agent: worker)

    assert task.id == seed.id
    assert task.kind == "agent_task"
    assert task.category == "email_drafts"
    assert task.status == "in_progress"
    assert task.salix_agent_id == worker.salix_agent_id
    assert task.labels == ["launch"]

    assert {:ok, conversation} =
             Conversations.get_project_conversation(project, task.salix_conversation_id)

    assert conversation["kind"] == "agent_task"
    assert conversation["status"] == "active"
    assert conversation["owner_user_id"] == user_id
    assert conversation["metadata"]["workspace_category"] == "email_drafts"
    assert conversation["metadata"]["platform"] == "gmail"
    assert conversation["metadata"]["description"] == "Keep the final paragraph concise"
    assert conversation["metadata"]["payload"]["subject"] == "Launch"

    assert {:ok, participants} =
             Conversations.list_project_conversation_participants(
               project,
               task.salix_conversation_id
             )

    assert Enum.any?(
             participants,
             &(&1["agent_id"] == router.salix_agent_id and &1["role_label"] == "delegator")
           )

    assert Enum.any?(
             participants,
             &(&1["agent_id"] == worker.salix_agent_id and &1["role_label"] == "worker")
           )

    assert {:ok, _items} =
             Conversations.project_project_conversation(project, conversation)

    assert [projected] =
             WorkspaceItems.list_tasks(user_id,
               project_id: project.id,
               category: "email_drafts"
             )

    assert projected.id == seed.id
    assert projected.kind == "agent_task"
    assert projected.title == seed.title
    assert projected.payload["to"] == "team@example.com"
  end

  test "linked workspace writes remain canonical across forced projection", %{
    org: org,
    project: project,
    user_id: user_id
  } do
    assert {:ok, worker} =
             BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
               project.id,
               %{"name" => "Review Worker", "role" => "worker"}
             )

    drain_reconcile!()

    assert {:ok, [seed]} =
             WorkspaceItems.create_tasks(user_id, org.id, project.id, [
               %{
                 "title" => "Prepare review draft",
                 "category" => "email_drafts",
                 "platform" => "gmail",
                 "status" => "accepted",
                 "payload" => %{"subject" => "Original"}
               }
             ])

    assert {:ok, task} =
             TaskDelegation.dispatch(seed, actor_user_id: user_id, agent: worker)

    assert {:ok, reviewable} =
             Conversations.update_workspace_item(project, task, %{
               "status" => "ready_for_review",
               "payload" => %{"subject" => "Edited", "body" => "Canonical body"}
             })

    assert reviewable.status == "ready_for_review"
    assert reviewable.payload["body"] == "Canonical body"

    assert {:ok, done} = Conversations.accept_workspace_item_review(project, reviewable)
    assert done.status == "done"

    assert {:ok, archived} = Conversations.archive_workspace_item(project, done)
    assert archived.status == "archived"

    assert {:ok, conversation} =
             Conversations.get_project_conversation(project, task.salix_conversation_id)

    assert conversation["status"] == "archived"
    assert conversation["metadata"]["payload"]["subject"] == "Edited"
    assert conversation["metadata"]["payload"]["body"] == "Canonical body"
    assert conversation["archived_from_status"] == "completed"
    assert is_integer(conversation["archived_at"])
    assert DateTime.to_unix(archived.archived_at, :millisecond) == conversation["archived_at"]

    assert {:ok, _items} =
             Conversations.project_project_conversation(project, conversation)

    assert WorkspaceItems.list_tasks(user_id, project_id: project.id) == []

    assert [still_archived] =
             WorkspaceItems.list_tasks(user_id,
               project_id: project.id,
               include_archived: true
             )

    assert still_archived.id == seed.id
    assert still_archived.status == "archived"
    assert still_archived.category == "email_drafts"
    assert still_archived.payload["body"] == "Canonical body"
  end

  test "only committed Conversation updates change a projected workspace item", %{
    agent: agent,
    project: project,
    user_id: user_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             Conversations.create_project_conversation(project, agent, %{
               "kind" => "email_draft",
               "title" => "Founder introduction",
               "status" => "in_progress",
               "metadata" => %{
                 "payload" => %{
                   "to" => "founder@example.com",
                   "subject" => "Introduction"
                 }
               }
             })

    assert {:ok,
            %{
              "kind" => "agent_task",
              "metadata" => %{"workspace_category" => "email_drafts"}
            }} = Conversations.get_project_conversation(project, conversation_id)

    assert {:ok, %{"inserted" => true}} =
             SalixIM.ConversationServer.append_group_conversation_agent_message(
               project.salix_group_id,
               conversation_id,
               agent.salix_agent_id,
               %{
                 "client_request_id" => "legacy-conversation-update-message",
                 "content" => [
                   %{
                     "type" => "text",
                     "text" =>
                       "Draft ready.\n```conversation_update\n{\"status\":\"ready_for_review\"}\n```"
                   }
                 ],
                 "metadata" => %{
                   "conversation_update" => %{
                     "status" => "ready_for_review",
                     "metadata" => %{"payload" => %{"body" => "hidden command"}}
                   }
                 }
               }
             )

    assert [before_update] =
             WorkspaceItems.list_tasks(user_id,
               project_id: project.id,
               category: "email_drafts"
             )

    assert before_update.status == "in_progress"
    refute Map.has_key?(before_update.payload, "body")

    assert {:ok,
            %{
              "status" => "ready_for_review",
              "metadata" => %{"workspace_category" => "email_drafts"}
            }} =
             Conversations.update_project_conversation(project, conversation_id, %{
               "status" => "ready_for_review",
               "metadata" => %{
                 "payload" => %{
                   "to" => "founder@example.com",
                   "subject" => "Introduction",
                   "body" => "Visible committed draft"
                 }
               }
             })

    assert [after_update] =
             WorkspaceItems.list_tasks(user_id,
               project_id: project.id,
               category: "email_drafts"
             )

    assert after_update.status == "ready_for_review"
    assert after_update.payload["body"] == "Visible committed draft"
  end

  test "workspace visibility is not gated by conversation owner labels inside the project", %{
    agent: agent,
    project: project,
    user_id: user_id
  } do
    {:ok, other_user} =
      Accounts.create_user(%{
        "email" => "other-owner-#{System.unique_integer([:positive])}@example.test",
        "name" => "Other Owner"
      })

    assert {:ok, %{"conversation_id" => conversation_id}} =
             Conversations.create_project_conversation(project, agent, %{
               "kind" => "agent_task",
               "title" => "Other-owned worker task",
               "status" => "active",
               "owner_user_id" => other_user.id
             })

    assert [task] =
             WorkspaceItems.list_tasks(user_id, project_id: project.id, category: "general")

    assert {:ok, _uuid} = Ecto.UUID.cast(task.id)
    assert task.salix_conversation_id == conversation_id
    assert task.user_id == other_user.id
  end

  test "agent task conversations outside the user's projects are not projected", %{
    org: org,
    project: project,
    user_id: user_id
  } do
    suffix = System.unique_integer([:positive])

    {:ok, foreign_project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Foreign Workspace",
        "slug" => "foreign-workspace-#{suffix}"
      })

    [foreign_agent | _] = Agents.list_agents(foreign_project.id)
    drain_reconcile!()

    assert {:ok, %{"conversation_id" => foreign_conversation_id}} =
             Conversations.create_project_conversation(foreign_project, foreign_agent, %{
               "kind" => "agent_task",
               "title" => "Private worker task",
               "status" => "active"
             })

    assert [] =
             WorkspaceItems.list_tasks(user_id, project_id: project.id, category: "general")

    assert [] =
             WorkspaceItems.list_tasks(user_id,
               project_id: foreign_project.id,
               category: "general"
             )

    assert {:error, :not_found} = WorkspaceItems.get_task(user_id, foreign_conversation_id)
  end

  test "kindless conversations are not projected into workspace items", %{
    agent: agent,
    project: project,
    user_id: user_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             Conversations.create_project_conversation(project, agent, %{
               "title" => "Legacy chat without kind",
               "owner_user_id" => user_id,
               "created_by_user_id" => user_id
             })

    assert {:ok, _conversation} =
             SalixStore.CasRecord.update(
               Keys.ctl_group_conversation(project.salix_group_id, conversation_id),
               &Map.delete(&1, "kind")
             )

    assert [] =
             WorkspaceItems.list_tasks(user_id, project_id: project.id, category: "general")
  end
end
