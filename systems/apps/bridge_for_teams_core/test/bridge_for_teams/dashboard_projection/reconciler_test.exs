defmodule BridgeForTeams.DashboardProjection.ReconcilerTest do
  use BridgeForTeams.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.BridgeForTeams"]

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
           SystemsRuntime.get_env(
             :bridge_for_teams_core,
             :dashboard_projection_reconciler_test_pid
           ) do
        SystemsRuntime.Proc.send(pid, message)
      end
    end
  end

  setup do
    previous_client = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)

    previous_pid =
      SystemsRuntime.get_env(:bridge_for_teams_core, :dashboard_projection_reconciler_test_pid)

    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, SalixClient)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :dashboard_projection_reconciler_test_pid,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn ->
      SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous_client)

      SystemsRuntime.put_env(
        :bridge_for_teams_core,
        :dashboard_projection_reconciler_test_pid,
        previous_pid
      )
    end)

    :ok
  end

  test "enqueue coalesces refresh work and writes a snapshot" do
    %{project: project} = fixture()
    group_id = project.salix_group_id
    start_supervised!({DashboardProjection.Reconciler, enabled: true})

    assert :ok = DashboardProjection.enqueue_refresh(project.id)
    assert :ok = DashboardProjection.enqueue_refresh(project.id)

    settle_receive({:list_group_conversations, ^group_id})
    settle_receive({:list_group_meetings, ^group_id})

    assert %ProjectDashboardSnapshot{refreshed_at: %DateTime{}} =
             settle_until(fn ->
               case Repo.get(ProjectDashboardSnapshot, project.id) do
                 %ProjectDashboardSnapshot{refreshed_at: %DateTime{}} = snapshot -> snapshot
                 _ -> nil
               end
             end)
  end

  test "a refresh requested while a drain runs starts as soon as that drain ends" do
    %{project: first} = fixture()
    %{project: second} = fixture()
    {first_id, second_id} = {first.id, second.id}
    test = SystemsRuntime.Proc.self()

    refresh = fn project_id, _opts ->
      SystemsRuntime.Proc.send(test, {:refreshing, project_id, SystemsRuntime.Proc.self()})
      receive(do: ({:finish, result} -> result))
    end

    assert :ok = DashboardProjection.Reconciler.request_refresh(first_id)

    # The interval never passes in this test: only the doorbell can start the
    # second drain.
    start_supervised!(
      {DashboardProjection.Reconciler,
       enabled: true, interval_ms: 3_600_000, run_opts: [backstop_limit: 0, refresh_fun: refresh]}
    )

    settle_receive({:refreshing, ^first_id, first_worker})
    assert :ok = DashboardProjection.enqueue_refresh(second_id)
    _ = :sys.get_state(DashboardProjection.Reconciler)

    # The running drain ends without claiming more work.
    SystemsRuntime.Proc.send(first_worker, {:finish, {:error, :unavailable}})

    settle_receive({:refreshing, ^second_id, second_worker})
    SystemsRuntime.Proc.send(second_worker, {:finish, {:error, :unavailable}})
    settle()
  end

  defp fixture do
    n = SystemsRuntime.Proc.unique_integer([:positive])
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
