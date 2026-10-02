defmodule BridgeForTeams.DashboardProjectionTest do
  use BridgeForTeams.DataCase, async: false

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
      if pid = Application.get_env(:bridge_for_teams_core, :dashboard_projection_test_pid) do
        send(pid, message)
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
      if pid = Application.get_env(:bridge_for_teams_core, :dashboard_projection_test_pid) do
        send(pid, {:slow_salix_call_started, self()})
      end

      Process.sleep(:infinity)
    end

    def list_group_meetings(_group_id), do: {:ok, []}
    def list_group_oauth_bindings(_group_id), do: []
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, %{"data" => []}}
    def session_trace(_agent_id, _session_id, _opts), do: {:error, :not_found}
  end

  setup do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    previous_pid = Application.get_env(:bridge_for_teams_core, :dashboard_projection_test_pid)
    Application.put_env(:bridge_for_teams_core, :salix_client, SalixClient)
    Application.put_env(:bridge_for_teams_core, :dashboard_projection_test_pid, self())

    on_exit(fn ->
      Application.put_env(:bridge_for_teams_core, :salix_client, previous_client)
      Application.put_env(:bridge_for_teams_core, :dashboard_projection_test_pid, previous_pid)
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

    assert_receive {:list_group_conversations, _group_id, _opts}
    assert_receive {:list_group_meetings, _group_id}
    assert_receive {:billing_history, agent_id, tenant_id, _opts}
    assert agent_id == agent.salix_agent_id
    assert tenant_id == org.salix_tenant_id
  end

  test "mark_stale and stale_or_missing? expose refresh state" do
    %{project: project} = fixture()

    assert DashboardProjection.stale_or_missing?(project)
    assert {:ok, snapshot} = DashboardProjection.mark_stale(project)
    assert snapshot.stale_at
    assert DashboardProjection.stale_or_missing?(project)
  end

  test "refresh_project preserves the last successful snapshot when a source fails" do
    %{project: project} = fixture()
    refreshed_at = DateTime.add(DateTime.utc_now(), -60, :second)

    assert {:ok, snapshot} =
             DashboardProjection.upsert_snapshot(project, %{
               conversation_count: 7,
               token_total: 99,
               connected_providers: ["github"],
               meeting_count: 2,
               refreshed_at: refreshed_at
             })

    Application.put_env(:bridge_for_teams_core, :salix_client, FailingSalixClient)

    assert {:error, reason} = DashboardProjection.refresh_project(project)
    assert reason =~ "conversation refresh failed"

    persisted = DashboardProjection.snapshot_for_project(project.id)
    assert persisted.project_id == snapshot.project_id
    assert persisted.conversation_count == 7
    assert persisted.token_total == 99
    assert persisted.connected_providers == ["github"]
    assert persisted.meeting_count == 2
    assert DateTime.compare(persisted.refreshed_at, refreshed_at) == :eq
    assert persisted.refreshing_at == nil
    assert persisted.refresh_error =~ "conversation refresh failed"
  end

  test "rebuild_projects records the timed out project and clears refreshing state" do
    %{project: project} = fixture()
    Application.put_env(:bridge_for_teams_core, :salix_client, SlowSalixClient)

    # The timeout leaves the refresh ample time to finish its database writes
    # and block in the Salix call; killing it inside a query would break the
    # test's sandbox connection. It stays below the 5s Salix call timeout.
    assert [{project_id, {:error, {:task_exit, :timeout}}}] =
             DashboardProjection.rebuild_projects([project], timeout: 1_000)

    assert project_id == project.id
    assert_received {:slow_salix_call_started, blocked_call}
    ref = Process.monitor(blocked_call)
    assert_receive {:DOWN, ^ref, :process, ^blocked_call, _reason}

    snapshot = DashboardProjection.snapshot_for_project(project.id)
    assert snapshot.project_id == project.id
    assert snapshot.refreshing_at == nil
    assert snapshot.refresh_error == "rebuild refresh timed out after 1000ms"
  end

  defp fixture do
    n = System.unique_integer([:positive])
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
