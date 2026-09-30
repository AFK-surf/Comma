defmodule BridgeForTeams.DashboardProjection.ReconcilerTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{
    Accounts,
    DashboardProjection,
    Memberships,
    Orgs,
    Projects,
    Repo
  }

  alias BridgeForTeams.Schema.ProjectDashboardSnapshot

  defmodule SalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    def list_group_conversations(group_id, _opts) do
      notify({:list_group_conversations, group_id})
      {:ok, []}
    end

    def list_group_meetings(group_id) do
      notify({:list_group_meetings, group_id})
      {:ok, []}
    end

    def list_group_oauth_bindings(group_id) do
      notify({:list_group_oauth_bindings, group_id})
      []
    end

    def billing_history(agent_id, tenant_id, _opts) do
      notify({:billing_history, agent_id, tenant_id})
      {:ok, []}
    end

    defp notify(message) do
      if pid =
           Application.get_env(:bridge_for_teams_core, :dashboard_projection_reconciler_test_pid) do
        send(pid, message)
      end
    end
  end

  setup do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

    previous_pid =
      Application.get_env(:bridge_for_teams_core, :dashboard_projection_reconciler_test_pid)

    Application.put_env(:bridge_for_teams_core, :salix_client, SalixClient)
    Application.put_env(:bridge_for_teams_core, :dashboard_projection_reconciler_test_pid, self())

    on_exit(fn ->
      Application.put_env(:bridge_for_teams_core, :salix_client, previous_client)

      Application.put_env(
        :bridge_for_teams_core,
        :dashboard_projection_reconciler_test_pid,
        previous_pid
      )
    end)

    :ok
  end

  test "enqueue coalesces refresh work and writes a snapshot" do
    %{project: project} = fixture()

    assert :ok = DashboardProjection.enqueue_refresh(project.id)
    assert :ok = DashboardProjection.enqueue_refresh(project.id)

    assert_receive {:list_group_conversations, _group_id}, 2_000
    assert_receive {:list_group_meetings, _group_id}, 2_000

    assert_eventually(fn ->
      case Repo.get(ProjectDashboardSnapshot, project.id) do
        %ProjectDashboardSnapshot{refreshed_at: %DateTime{}} -> true
        _ -> false
      end
    end)
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp fixture do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.create_user(%{"email" => "reconciler-#{n}@example.com"})
    {:ok, org} = Orgs.create_org(%{"name" => "Reconciler #{n}", "slug" => "reconciler-#{n}"})
    {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "owner")

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Project #{n}", "slug" => "proj-#{n}"},
        creator_user_id: user.id
      )

    %{user: user, org: org, project: project}
  end
end
