defmodule BridgeForTeams.SessionIdentityMigrationE2ETest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, Agents, Orgs, Repo}
  alias BridgeForTeams.Schema.{UserOnboarding, WorkspaceItem}
  alias SalixStore.SessionIdMigration

  setup do
    SalixStore.S3.Fake.reset()

    suffix = System.unique_integer([:positive])

    {:ok, org} =
      Orgs.create_org(%{"name" => "Migration #{suffix}", "slug" => "migration-#{suffix}"})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Session migration",
        "slug" => "session-migration-#{suffix}"
      })

    [agent | _] = Agents.list_agents(project.id)

    {:ok, user} =
      Accounts.create_user(%{"email" => "session-migration-#{suffix}@example.test"})

    %{agent: agent, org: org, project: project, user: user}
  end

  test "rewrites projected task and paused-routine session references", %{
    agent: agent,
    org: org,
    project: project,
    user: user
  } do
    task_session_id = "router-bft-task-session"
    routine_session_id = "im-bft-routine-session"

    workspace_item =
      %WorkspaceItem{}
      |> WorkspaceItem.changeset(%{
        user_id: user.id,
        org_id: org.id,
        project_id: project.id,
        title: "Delegated task",
        category: "tasks",
        kind: "agent_task",
        platform: "comma",
        status: "in_progress",
        source: "projection",
        source_refs: %{
          "origin_session_id" => task_session_id
        }
      })
      |> Repo.insert!()

    onboarding =
      %UserOnboarding{}
      |> UserOnboarding.changeset(%{
        user_id: user.id,
        capabilities: %{
          "_paused" => %{
            project.id => %{
              "sch-legacy" => %{
                "agent_id" => agent.salix_agent_id,
                "definition" => %{"session_id" => routine_session_id}
              }
            }
          }
        }
      })
      |> Repo.insert!()

    assert {:ok, refs} = BridgeForTeams.Migrations.SessionIdentity.inventory_refs()
    assert {agent.salix_agent_id, task_session_id} in refs
    assert {agent.salix_agent_id, routine_session_id} in refs

    assert {:ok, _stats} =
             SalixStore.Migrations.SessionIdentity.run(additional_refs: refs)

    assert {:ok, maps} = SessionIdMigration.read_all()
    session_ids = maps[agent.salix_agent_id]

    task_target_session_id = session_ids[task_session_id]
    routine_target_session_id = session_ids[routine_session_id]

    assert {:ok, _summary} = BridgeForTeams.Migrations.SessionIdentity.run(maps)

    migrated_workspace_item = Repo.get!(WorkspaceItem, workspace_item.id)
    migrated_onboarding = Repo.get!(UserOnboarding, onboarding.id)

    assert migrated_workspace_item.source_refs["origin_session_id"] == task_target_session_id

    assert get_in(migrated_onboarding.capabilities, [
             "_paused",
             project.id,
             "sch-legacy",
             "definition",
             "session_id"
           ]) == routine_target_session_id

    assert {:ok, true} =
             SessionIdMigration.phase_complete?(:bft, %{
               agent.salix_agent_id => session_ids
             })

    assert {:ok, _summary} = BridgeForTeams.Migrations.SessionIdentity.run(maps)

    assert Repo.get!(WorkspaceItem, workspace_item.id).source_refs["origin_session_id"] ==
             task_target_session_id

    assert {:ok, migrated_refs} = BridgeForTeams.Migrations.SessionIdentity.inventory_refs()
    assert {agent.salix_agent_id, task_target_session_id} in migrated_refs
  end
end
