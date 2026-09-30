defmodule BridgeForTeams.DashboardProjectionTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{
    Accounts,
    Agents,
    DashboardProjection,
    Memberships,
    Orgs,
    Repo,
    WorkspaceItems
  }

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

    def seed_group_conversation_transcript(_group_id, conversation_id, attrs) do
      message_count = attrs |> Map.get("messages", []) |> length()

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "requested_count" => message_count,
         "appended_count" => message_count,
         "skipped_count" => 0,
         "message_count" => message_count
       }}
    end

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

  defmodule SharedArtifactConversationsClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    def list_group_conversations(_group_id, _opts) do
      path = "/.salix/reports/daily-briefing/2026-07-24.md"

      {:ok,
       [
         %{
           "conversation_id" => "conv-routine-run",
           "title" => "Daily briefing routine",
           "kind" => "routine_run",
           "status" => "done",
           "metadata" => %{"source" => "projection", "payload" => %{}},
           "source_refs" => %{"agent_id" => "agent-routine"},
           "latest_artifact" => %{"type" => "vfs", "path" => path},
           "updated_at" => 1_700_000_001
         },
         %{
           "conversation_id" => "conv-report",
           "title" => "Daily briefing report",
           "kind" => "report",
           "status" => "done",
           "metadata" => %{
             "source" => "projection",
             "payload" => %{"vfs_path" => path, "summary" => "Daily briefing"}
           },
           "source_refs" => %{},
           "latest_artifact" => %{"type" => "vfs", "path" => path},
           "updated_at" => 1_700_000_002
         }
       ]}
    end

    defdelegate list_group_meetings(group_id), to: SalixClient
    defdelegate list_group_oauth_bindings(group_id), to: SalixClient
    defdelegate billing_history(agent_id, tenant_id, opts), to: SalixClient
    defdelegate session_trace(agent_id, session_id, opts), to: SalixClient

    defdelegate seed_group_conversation_transcript(group_id, conversation_id, attrs),
      to: SalixClient
  end

  defmodule WorkflowSalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    def list_group_conversations(_group_id, _opts) do
      {:ok, [Application.fetch_env!(:bridge_for_teams_core, :workflow_projection_fixture)]}
    end

    defdelegate list_group_meetings(group_id), to: SalixClient
    defdelegate list_group_oauth_bindings(group_id), to: SalixClient
    defdelegate billing_history(agent_id, tenant_id, opts), to: SalixClient
    defdelegate session_trace(agent_id, session_id, opts), to: SalixClient

    defdelegate seed_group_conversation_transcript(group_id, conversation_id, attrs),
      to: SalixClient
  end

  defmodule SlowSalixClient do
    def list_group_conversations(_group_id, _opts) do
      Process.sleep(5_000)
      {:ok, []}
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

  test "refresh_project performs Salix fan-out and writes local projections for visible users" do
    %{user: user, member: member, org: org, project: project} = fixture()
    [agent | _] = Agents.list_agents(project.id)

    assert {:ok, snapshot} = DashboardProjection.refresh_project(project)
    assert snapshot.conversation_count == 1
    assert snapshot.meeting_count == 1
    assert snapshot.token_total == 30

    assert_receive {:list_group_conversations, _group_id, _opts}
    assert_receive {:list_group_meetings, _group_id}
    assert_receive {:billing_history, agent_id, tenant_id, _opts}
    assert agent_id == agent.salix_agent_id
    assert tenant_id == org.salix_tenant_id

    item =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id, category: "general")
      |> Enum.find(&(&1.salix_conversation_id == "conv-dashboard"))

    assert item
    assert item.salix_conversation_id == "conv-dashboard"
    assert item.vfs_path == "/artifact.md"

    assert [metrics] =
             WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "metrics")

    assert metrics.payload["hero"]["type"] == "kpis"

    assert [member_metrics] =
             WorkspaceItems.list_tasks(member.id, project_id: project.id, category: "metrics")

    assert member_metrics.payload["hero"]["type"] == "kpis"

    assert [activity] =
             WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "team_activity")

    assert [%{"name" => "Dashboard conversation"}] = activity.payload["hero"]["items"]

    assert [recap] =
             WorkspaceItems.list_tasks(user.id,
               project_id: project.id,
               category: "meeting_recaps"
             )

    assert recap.title == "Planning — recap"
    assert recap.payload["bullets"] == ["Agreed on rollout"]

    action_items =
      WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "general")
      |> Enum.filter(&(&1.payload["origin"] == "meeting:meet-1:0"))

    assert [action_item] = action_items
    assert action_item.title == "Send rollout note"
  end

  test "projection keeps latest-artifact references separate from payload-owned VFS identity" do
    Application.put_env(
      :bridge_for_teams_core,
      :salix_client,
      SharedArtifactConversationsClient
    )

    %{user: user, project: project} = fixture()
    path = "/.salix/reports/daily-briefing/2026-07-24.md"

    assert {:ok, _snapshot} = DashboardProjection.refresh_project(project)
    assert {:ok, _snapshot} = DashboardProjection.refresh_project(project)

    assert [routine] =
             WorkspaceItems.list_tasks(user.id,
               project_id: project.id,
               category: "routines"
             )
             |> Enum.filter(&(&1.salix_conversation_id == "conv-routine-run"))

    assert routine.vfs_path == nil
    assert routine.latest_artifact == %{"type" => "vfs", "path" => path}

    assert [report] =
             WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "reports")
             |> Enum.filter(&(&1.salix_conversation_id == "conv-report"))

    assert report.vfs_path == path
    assert report.payload["vfs_path"] == path
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

  test "refresh skips builder rows for categories owned by a user's mock-import cards" do
    %{user: user, member: member, org: org, project: project} = fixture()

    # First refresh plants the projection singletons for every visible user.
    assert {:ok, _snapshot} = DashboardProjection.refresh_project(project)

    assert [%{external_source: "dashboard_projection"}] =
             WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "metrics")

    # Importing a mock metrics card adopts the category for THIS user: the
    # projection singleton is archived, and later refreshes skip rebuilding it.
    assert {:ok, summary} =
             BridgeForTeams.WorkspaceImports.import_document(user, user, org, project, %{
               "format" => "bft.myspace.import",
               "version" => 1,
               "items" => [
                 %{
                   "external_id" => "mock-metrics",
                   "category" => "metrics",
                   "title" => "Mock metrics",
                   "payload" => %{"hero" => %{"type" => "kpis", "items" => []}}
                 }
               ]
             })

    assert summary.created == 1
    assert summary.archived == 1

    assert {:ok, _snapshot} = DashboardProjection.refresh_project(project)

    assert [metrics] =
             WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "metrics")

    assert metrics.external_source == "mock_import"
    assert metrics.title == "Mock metrics"

    # Other users' boards are untouched: the member still gets the live widget.
    assert [member_metrics] =
             WorkspaceItems.list_tasks(member.id, project_id: project.id, category: "metrics")

    assert member_metrics.external_source == "dashboard_projection"

    # Unowned categories keep refreshing normally for the importing user too.
    assert [activity] =
             WorkspaceItems.list_tasks(user.id, project_id: project.id, category: "team_activity")

    assert activity.external_source == "dashboard_projection"
  end

  test "rebuild_projects records the timed out project and clears refreshing state" do
    %{project: project} = fixture()
    Application.put_env(:bridge_for_teams_core, :salix_client, SlowSalixClient)

    assert [{project_id, {:error, {:task_exit, :timeout}}}] =
             DashboardProjection.rebuild_projects([project], timeout: 10)

    assert project_id == project.id

    snapshot = DashboardProjection.snapshot_for_project(project.id)
    assert snapshot.project_id == project.id
    assert snapshot.refreshing_at == nil
    assert snapshot.refresh_error == "rebuild refresh timed out after 10ms"
  end

  defp fixture do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.create_user(%{"email" => "projection-#{n}@example.com"})
    {:ok, member} = Accounts.create_user(%{"email" => "projection-member-#{n}@example.com"})
    {:ok, org} = Orgs.create_org(%{"name" => "Projection #{n}", "slug" => "projection-#{n}"})
    {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "owner")
    {:ok, _membership} = Memberships.put_org_member(org.id, member.id, "member")

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "Project #{n}", "slug" => "proj-#{n}"},
        creator_user_id: user.id
      )

    {:ok, _membership} = Memberships.put_project_member(project.id, member.id, "user")

    %{user: user, member: member, org: org, project: Repo.preload(project, :agents)}
  end
end
