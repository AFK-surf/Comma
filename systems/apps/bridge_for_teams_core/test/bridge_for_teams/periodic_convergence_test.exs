defmodule BridgeForTeams.PeriodicConvergenceTest do
  require SystemsRuntime.Proc

  use BridgeForTeams.DataCase, async: false

  import Ecto.Query

  alias BridgeForTeams.{
    DashboardProjection,
    Observability,
    Orgs,
    Projects,
    Repo
  }

  alias BridgeForTeams.DashboardProjection.Reconciler, as: DashboardReconciler
  alias BridgeForTeams.Observability.Pruner
  alias BridgeForTeams.Salix.TenantConfigChecker
  alias BridgeForTeams.Schema.{AuditLog, ProjectDashboardSnapshot}

  defmodule LeaseExpirySalixClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    def list_group_conversations(_group_id, _opts) do
      call(:list_group_conversations, {:ok, []})
    end

    def list_group_meetings(_group_id), do: {:ok, []}
    def list_group_oauth_bindings(_group_id), do: []
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, []}
    def session_trace(_agent_id, _session_id, _opts), do: {:error, :not_found}

    defp call(operation, default) do
      case SystemsRuntime.get_env(
             :bridge_for_teams_core,
             :dashboard_projection_lease_expiry_test_pid
           ) do
        pid when SystemsRuntime.Proc.is_process(pid) ->
          ref = SystemsRuntime.Proc.make_ref()

          SystemsRuntime.Proc.send(
            pid,
            {:dashboard_external_read, operation, SystemsRuntime.Proc.self(), ref}
          )

          SystemsRuntime.Proc.receive do
            {:continue_dashboard_external_read, ^ref, result} -> result
          after
            5_000 -> {:error, :timeout}
          end

        _ ->
          default
      end
    end
  end

  defmodule OneShotPrunerRepo do
    def transaction(fun), do: BridgeForTeams.Repo.transaction(fun)

    def query!(statement, params) do
      payload =
        SystemsRuntime.get_env(
          :bridge_for_teams_core,
          :periodic_convergence_pruner_error_payload
        )

      if is_binary(payload) and String.contains?(statement, "FROM operation_runs") do
        SystemsRuntime.delete_env(
          :bridge_for_teams_core,
          :periodic_convergence_pruner_error_payload
        )

        raise payload
      end

      BridgeForTeams.Repo.query!(statement, params)
    end

    def query(statement, params), do: BridgeForTeams.Repo.query(statement, params)
  end

  test "dashboard desired generation survives a crash and stale claims cannot commit" do
    {_org, project} = project_fixture("dashboard")
    assert :ok = DashboardReconciler.request_refresh(project.id)

    assert {:error, {:exception, %RuntimeError{message: "crash"}}} =
             DashboardReconciler.run_once(
               backstop_limit: 0,
               retry_ms: 0,
               refresh_fun: fn _project_id, _opts -> raise "crash" end
             )

    assert [[1, 0, nil]] =
             Repo.query!(
               """
               SELECT desired_generation, completed_generation, lease_token
               FROM dashboard_projection_refreshes
               WHERE project_id = $1::text::uuid
               """,
               [project.id]
             ).rows

    assert {:ok, %{refreshed: 1}} =
             DashboardReconciler.run_once(
               backstop_limit: 0,
               refresh_fun: successful_dashboard_refresh(project)
             )

    assert %ProjectDashboardSnapshot{refresh_generation: 1} =
             Repo.get(ProjectDashboardSnapshot, project.id)

    assert :ok = DashboardReconciler.request_refresh(project.id)

    assert {:error, :stale_dashboard_refresh_claim} =
             DashboardReconciler.run_once(
               backstop_limit: 0,
               retry_ms: 0,
               refresh_fun: fn _project_id, opts ->
                 Repo.query!(
                   """
                   UPDATE dashboard_projection_refreshes
                   SET lease_token = gen_random_uuid(), lease_expires_at = now() - interval '1 second'
                   WHERE project_id = $1::text::uuid
                   """,
                   [project.id]
                 )

                 opts[:commit_guard].()
               end
             )

    assert %ProjectDashboardSnapshot{refresh_generation: 1} =
             Repo.get(ProjectDashboardSnapshot, project.id)

    assert {:ok, %{refreshed: 1}} =
             DashboardReconciler.run_once(
               backstop_limit: 0,
               refresh_fun: successful_dashboard_refresh(project)
             )

    assert %ProjectDashboardSnapshot{refresh_generation: 2} =
             Repo.get(ProjectDashboardSnapshot, project.id)
  end

  defp successful_dashboard_refresh(project) do
    fn _project_id, opts ->
      case Repo.transaction(fn ->
             :ok = opts[:commit_guard].()

             {:ok, snapshot} =
               DashboardProjection.upsert_snapshot(project, %{
                 refreshed_at: SystemsClock.utc_now(),
                 refresh_generation: opts[:refresh_generation]
               })

             :ok = opts[:commit_ack].()
             snapshot
           end) do
        {:ok, snapshot} -> {:ok, snapshot}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp project_fixture(suffix) do
    unique = SystemsRuntime.Proc.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{name: "Org #{suffix}", slug: "#{suffix}-#{unique}"})

    {:ok, project} =
      Projects.create_project(org.id, %{name: "Project #{suffix}", slug: "#{suffix}-#{unique}"})

    {org, project}
  end
end
