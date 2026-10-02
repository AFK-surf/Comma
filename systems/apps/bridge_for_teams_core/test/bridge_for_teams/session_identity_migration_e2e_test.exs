defmodule BridgeForTeams.SessionIdentityMigrationE2ETest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, Agents, Orgs, Repo}
  alias BridgeForTeams.Schema.UserOnboarding
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

    # The product code for this table is retired; the row is seeded with SQL
    # because the identity migration still rewrites any stored data.
    workspace_item_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO workspace_items (
        id, user_id, org_id, project_id, title, category, kind, status, source,
        source_refs, created_at, updated_at
      )
      VALUES ($1, $2, $3, $4, 'Delegated task', 'tasks', 'agent_task',
              'in_progress', 'projection', $5, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(workspace_item_id),
        Ecto.UUID.dump!(user.id),
        Ecto.UUID.dump!(org.id),
        Ecto.UUID.dump!(project.id),
        %{"origin_session_id" => task_session_id}
      ]
    )

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

    migrated_onboarding = Repo.get!(UserOnboarding, onboarding.id)

    assert origin_session_id(workspace_item_id) == task_target_session_id

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

    assert origin_session_id(workspace_item_id) == task_target_session_id

    assert {:ok, migrated_refs} = BridgeForTeams.Migrations.SessionIdentity.inventory_refs()
    assert {agent.salix_agent_id, task_target_session_id} in migrated_refs
  end

  defp origin_session_id(workspace_item_id) do
    [[origin_session_id]] =
      Repo.query!(
        "SELECT source_refs->>'origin_session_id' FROM workspace_items WHERE id = $1",
        [Ecto.UUID.dump!(workspace_item_id)]
      ).rows

    origin_session_id
  end
end
