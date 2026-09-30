defmodule BridgeForTeams.SkillsAuthorizationTest.FakeSalix do
  @moduledoc false

  def get_agent("agt_skills_" <> suffix = agent_id, _tenant_id) do
    {:ok,
     %{
       "agent_id" => agent_id,
       "group_id" => "grp_skills_#{suffix}",
       "role" => "router",
       "name" => "Current Router"
     }}
  end

  def delete_agent_skill(agent_id, tenant_id, skill_id, actor) do
    send(
      Application.fetch_env!(:bridge_for_teams_core, :skills_authorization_test_pid),
      {:delete_agent_skill, agent_id, tenant_id, skill_id, actor}
    )

    {:ok,
     %{
       "skill_id" => skill_id,
       "deleted" => true,
       "created_by_agent_id" => "agt_previous_router"
     }}
  end
end

defmodule BridgeForTeams.SkillsAuthorizationTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, Memberships, Observability, Skills}
  alias BridgeForTeams.Schema.{Agent, Organization, Project}

  setup do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

    Application.put_env(
      :bridge_for_teams_core,
      :salix_client,
      BridgeForTeams.SkillsAuthorizationTest.FakeSalix
    )

    Application.put_env(:bridge_for_teams_core, :skills_authorization_test_pid, self())

    on_exit(fn ->
      restore_env(:salix_client, previous_client)
      Application.delete_env(:bridge_for_teams_core, :skills_authorization_test_pid)
    end)

    suffix = System.unique_integer([:positive])

    org =
      %Organization{}
      |> Organization.changeset(%{
        name: "Skills authorization #{suffix}",
        slug: "skills-authorization-#{suffix}",
        billing_account_id: "billing-skills-#{suffix}",
        salix_tenant_id: "ten_skills_#{suffix}"
      })
      |> Repo.insert!()

    project =
      %Project{}
      |> Project.changeset(%{
        org_id: org.id,
        name: "Skills swarm",
        slug: "skills-swarm-#{suffix}",
        salix_group_id: "grp_skills_#{suffix}"
      })
      |> Repo.insert!()

    agent =
      %Agent{}
      |> Agent.changeset(%{
        project_id: project.id,
        salix_agent_id: "agt_skills_#{suffix}",
        role: "router",
        name: "Current Router"
      })
      |> Repo.insert!()

    %{agent: agent, org: org, project: project, suffix: suffix}
  end

  test "organization and Agent Swarm admins delete group skills with a human audit trail", %{
    agent: agent,
    org: org,
    project: project,
    suffix: suffix
  } do
    actors = [
      {:org_owner, "owner"},
      {:org_admin, "admin"},
      {:project_admin, "member"}
    ]

    Enum.each(actors, fn {kind, org_role} ->
      {:ok, user} =
        Accounts.create_user(%{email: "#{kind}-skills-#{suffix}@example.com"})

      {:ok, _membership} = Memberships.put_org_member(org.id, user.id, org_role)

      if kind == :project_admin do
        {:ok, _membership} = Memberships.put_project_member(project.id, user.id, "admin")
      end

      skill_id = "#{kind}-old-router"
      request_id = "req_#{kind}_#{suffix}"

      assert {:ok, %{"deleted" => true, "skill_id" => ^skill_id}} =
               Skills.delete_user_skill(
                 org,
                 agent,
                 Skills.runtime_location(skill_id),
                 actor_user_id: user.id,
                 actor_label: user.email,
                 request_id: request_id
               )

      assert_receive {:delete_agent_skill, agent_id, tenant_id, ^skill_id, actor}
      assert agent_id == agent.salix_agent_id
      assert tenant_id == org.salix_tenant_id

      assert actor == %{
               "type" => "user",
               "user_id" => user.id,
               "label" => user.email,
               "request_id" => request_id
             }

      assert [audit] = Observability.list_audit_logs(org.id, request_id: request_id)
      assert audit.action == "skill.group.deleted"
      assert audit.actor_user_id == user.id
      assert audit.resource_type == "skill"
      assert audit.resource_id == skill_id
      assert audit.result == "ok"
      assert audit.metadata["project_id"] == project.id
      assert audit.metadata["salix_group_id"] == project.salix_group_id
      assert audit.metadata["created_by_agent_id"] == "agt_previous_router"
    end)
  end

  test "ordinary Agent Swarm users cannot invoke the control-plane delete", %{
    agent: agent,
    org: org,
    project: project,
    suffix: suffix
  } do
    {:ok, user} = Accounts.create_user(%{email: "member-skills-#{suffix}@example.com"})
    {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "member")
    {:ok, _membership} = Memberships.put_project_member(project.id, user.id, "user")

    assert {:error, :forbidden} =
             Skills.delete_user_skill(
               org,
               agent,
               Skills.runtime_location("member-blocked"),
               actor_user_id: user.id,
               actor_label: user.email,
               request_id: "req_member_blocked_#{suffix}"
             )

    refute_receive {:delete_agent_skill, _, _, _, _}
  end

  defp restore_env(key, nil), do: Application.delete_env(:bridge_for_teams_core, key)
  defp restore_env(key, value), do: Application.put_env(:bridge_for_teams_core, key, value)
end
