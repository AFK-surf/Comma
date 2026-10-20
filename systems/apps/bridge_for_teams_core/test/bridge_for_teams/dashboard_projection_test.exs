defmodule BridgeForTeams.DashboardProjectionTest do
  use BridgeForTeams.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.BridgeForTeams"]

  alias BridgeForTeams.{Accounts, Agents, DashboardProjection, Memberships, Orgs, Repo}

  defmodule SalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    def list_group_conversations(group_id, opts) do
      notify({:list_group_conversations, group_id, opts})

      {:ok,
       [
         %{
           "conversation_id" => "conv-dashboard",
           "title" => "Dashboard conversation",
           "kind" => "work_item",
           "status" => "accepted",
           "metadata" => %{"source" => "projection", "payload" => %{"vfs_path" => "/artifact.md"}},
           "source_refs" => %{"agent_id" => "agent-dashboard"},
           "updated_at" => 1_700_000_000
         }
       ]}
    end

    def list_group_meetings(group_id) do
      notify({:list_group_meetings, group_id})

      {:ok,
       [
         %{
           "meeting_id" => "meet-1",
           "title" => "Planning",
           "provider" => "slack",
           "created_at" => "2026-07-08T00:00:00Z",
           "summary" => %{
             "title" => "Planning",
             "key_points" => ["Agreed on rollout"],
             "action_items" => [%{"description" => "Send rollout note", "owner" => "Sam"}]
           }
         }
       ]}
    end

    def list_group_oauth_bindings(group_id) do
      notify({:list_group_oauth_bindings, group_id})
      [%{"provider" => "github", "status" => "enabled"}]
    end

    def billing_history(agent_id, tenant_id, opts) do
      notify({:billing_history, agent_id, tenant_id, opts})
      {:ok, %{"data" => [%{"input_tokens" => 10, "output_tokens" => 20, "total_tokens" => 30}]}}
    end

    def session_trace(_agent_id, _session_id, _opts), do: {:error, :not_found}

    defp notify(message) do
      if pid = SystemsRuntime.get_env(:bridge_for_teams_core, :dashboard_projection_test_pid) do
        SystemsRuntime.Proc.send(pid, message)
      end
    end
  end

  defmodule FailingSalixClient do
    def list_group_conversations(_group_id, _opts), do: {:error, :unavailable}
    def list_group_meetings(_group_id), do: {:ok, []}
    def list_group_oauth_bindings(_group_id), do: []
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, %{"data" => []}}
    def session_trace(_agent_id, _session_id, _opts), do: {:error, :not_found}
  end

  defmodule SlowSalixClient do
    # Blocks until the rebuild kills the refresh. The refresh does its database
    # work before this call, so the kill cannot land in the middle of a query.
    def list_group_conversations(_group_id, _opts) do
      if pid = SystemsRuntime.get_env(:bridge_for_teams_core, :dashboard_projection_test_pid) do
        SystemsRuntime.Proc.send(pid, {:slow_salix_call_started, SystemsRuntime.Proc.self()})
      end

      SystemsClock.sleep(:infinity)
    end

    def list_group_meetings(_group_id), do: {:ok, []}
    def list_group_oauth_bindings(_group_id), do: []
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, %{"data" => []}}
    def session_trace(_agent_id, _session_id, _opts), do: {:error, :not_found}
  end

  setup do
    previous_client = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    previous_pid = SystemsRuntime.get_env(:bridge_for_teams_core, :dashboard_projection_test_pid)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, SalixClient)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :dashboard_projection_test_pid,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn ->
      SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous_client)
      SystemsRuntime.put_env(:bridge_for_teams_core, :dashboard_projection_test_pid, previous_pid)
    end)

    :ok
  end

  test "refresh_project performs Salix fan-out and writes the project snapshot" do
    %{org: org, project: project} = fixture()
    [agent | _] = Agents.list_agents(project.id)

    assert {:ok, snapshot} = DashboardProjection.refresh_project(project)
    assert snapshot.conversation_count == 1
    assert snapshot.meeting_count == 1
    assert snapshot.token_total == 30
    assert snapshot.connected_providers == ["github"]

    assert [%{"conversation_id" => "conv-dashboard", "title" => "Dashboard conversation"}] =
             snapshot.recent_conversations

    settle_receive({:list_group_conversations, _group_id, _opts})
    settle_receive({:list_group_meetings, _group_id})
    settle_receive({:billing_history, agent_id, tenant_id, _opts})
    assert agent_id == agent.salix_agent_id
    assert tenant_id == org.salix_tenant_id
  end

  defp fixture do
    n = SystemsRuntime.Proc.unique_integer([:positive])
    {:ok, user} = Accounts.create_user(%{"email" => "projection-#{n}@example.com"})
    {:ok, org} = Orgs.create_org(%{"name" => "Projection #{n}", "slug" => "projection-#{n}"})
    {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "owner")

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "Project #{n}", "slug" => "proj-#{n}"},
        creator_user_id: user.id
      )

    %{org: org, project: Repo.preload(project, :agents)}
  end
end
