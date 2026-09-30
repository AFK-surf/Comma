defmodule BridgeForTeams.PeriodicConvergenceTest do
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
      case Application.get_env(
             :bridge_for_teams_core,
             :dashboard_projection_lease_expiry_test_pid
           ) do
        pid when is_pid(pid) ->
          ref = make_ref()
          send(pid, {:dashboard_external_read, operation, self(), ref})

          receive do
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
        Application.get_env(
          :bridge_for_teams_core,
          :periodic_convergence_pruner_error_payload
        )

      if is_binary(payload) and String.contains?(statement, "FROM operation_runs") do
        Application.delete_env(
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

  test "expired dashboard worker cannot mutate snapshot before or after a newer worker commits" do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

    previous_pid =
      Application.get_env(
        :bridge_for_teams_core,
        :dashboard_projection_lease_expiry_test_pid
      )

    Application.put_env(:bridge_for_teams_core, :salix_client, LeaseExpirySalixClient)

    Application.put_env(
      :bridge_for_teams_core,
      :dashboard_projection_lease_expiry_test_pid,
      self()
    )

    on_exit(fn ->
      Application.put_env(:bridge_for_teams_core, :salix_client, previous_client)

      Application.put_env(
        :bridge_for_teams_core,
        :dashboard_projection_lease_expiry_test_pid,
        previous_pid
      )
    end)

    {_org, project} = project_fixture("dashboard-lease-expiry")

    assert {:ok, _snapshot} =
             DashboardProjection.upsert_snapshot(project, %{
               refreshed_at: DateTime.add(DateTime.utc_now(), -600, :second),
               refreshing_at: nil,
               refresh_error: "prior refresh error",
               refresh_generation: 0
             })

    assert :ok = DashboardReconciler.request_refresh(project.id)

    old_worker =
      Task.async(fn ->
        DashboardReconciler.run_once(backstop_limit: 0, lease_ms: 20, retry_ms: 0)
      end)

    assert_receive {:dashboard_external_read, :list_group_conversations, old_pid, old_ref},
                   2_000

    assert %ProjectDashboardSnapshot{
             refreshing_at: nil,
             refresh_error: "prior refresh error",
             refresh_generation: 0
           } = Repo.get(ProjectDashboardSnapshot, project.id)

    Repo.query!(
      """
      UPDATE dashboard_projection_refreshes
      SET lease_expires_at = now() - interval '1 second'
      WHERE project_id = $1::text::uuid
      """,
      [project.id]
    )

    new_worker =
      Task.async(fn ->
        DashboardReconciler.run_once(backstop_limit: 0, lease_ms: 1_000, retry_ms: 0)
      end)

    assert_receive {:dashboard_external_read, :list_group_conversations, new_pid, new_ref},
                   2_000

    send(new_pid, {:continue_dashboard_external_read, new_ref, {:ok, []}})
    assert {:ok, %{refreshed: 1}} = Task.await(new_worker, 5_000)

    assert %ProjectDashboardSnapshot{
             refreshing_at: nil,
             refresh_error: nil,
             refresh_generation: 1
           } = Repo.get(ProjectDashboardSnapshot, project.id)

    send(old_pid, {:continue_dashboard_external_read, old_ref, {:ok, []}})
    assert {:error, _reason} = Task.await(old_worker, 5_000)

    assert %ProjectDashboardSnapshot{
             refreshing_at: nil,
             refresh_error: nil,
             refresh_generation: 1
           } = Repo.get(ProjectDashboardSnapshot, project.id)

    assert [[1, 1, nil]] =
             Repo.query!(
               """
               SELECT desired_generation, completed_generation, lease_token
               FROM dashboard_projection_refreshes
               WHERE project_id = $1::text::uuid
               """,
               [project.id]
             ).rows
  end

  test "archived projects retain pending generations without retrying deleted groups" do
    {_org, project} = project_fixture("archived-refresh")
    assert :ok = DashboardReconciler.request_refresh(project.id)

    Repo.query!(
      "UPDATE projects SET status = 'archived', archived_at = now() WHERE id = $1::text::uuid",
      [project.id]
    )

    assert {:ok, %{claimed: false}} =
             DashboardReconciler.run_once(
               backstop_limit: 0,
               refresh_fun: fn _, _ -> flunk("archived project refreshed") end
             )

    assert [[1, 0, nil]] =
             Repo.query!(
               "SELECT desired_generation, completed_generation, lease_token FROM dashboard_projection_refreshes WHERE project_id = $1::text::uuid",
               [project.id]
             ).rows
  end

  test "tenant config ignores disabled organizations while active failures remain visible" do
    {:ok, disabled} = Orgs.create_org(%{name: "Disabled", slug: "disabled-config"})
    {:ok, active} = Orgs.create_org(%{name: "Active", slug: "active-config"})

    Repo.query!("UPDATE organizations SET status = 'disabled' WHERE id = $1::text::uuid", [
      disabled.id
    ])

    Repo.query!("DELETE FROM tenant_config_scans WHERE id = 'tenant-config'")

    assert {:ok, %{total: 1, failed: [%{org_id: active_id}]}} = TenantConfigChecker.run_once()
    assert active_id == active.id

    # Exercise the actor's real event writer, including schema validation.
    Repo.query!("DELETE FROM tenant_config_scans WHERE id = 'tenant-config'")

    assert {:noreply, %{status: "failed"}} =
             TenantConfigChecker.handle_info(:check_all, %TenantConfigChecker{})

    assert [%{source: "salix.control", reason_class: "not_found"}] =
             Repo.all(
               from e in BridgeForTeams.Schema.ObservabilityEvent,
                 where:
                   e.org_id == ^active.id and e.event_type == "salix.tenant_config.ensure_failed"
             )

    refute Repo.exists?(
             from e in BridgeForTeams.Schema.ObservabilityEvent, where: e.org_id == ^disabled.id
           )
  end

  test "tenant config scan is leased, bounded, fenced, and wraps fairly" do
    orgs =
      for suffix <- ~w(a b c) do
        {:ok, org} = Orgs.create_org(%{name: "Tenant #{suffix}", slug: "tenant-#{suffix}"})
        org
      end

    Repo.query!("DELETE FROM tenant_config_scans WHERE id = 'tenant-config'")
    parent = self()

    assert {:error, {:exception, %RuntimeError{message: "tenant scan crash"}}} =
             TenantConfigChecker.run_once(
               limit: 1,
               ensure_fun: fn _org -> raise "tenant scan crash" end
             )

    assert [[nil]] =
             Repo.query!("SELECT lease_token FROM tenant_config_scans WHERE id = 'tenant-config'").rows

    Repo.query!("DELETE FROM tenant_config_scans WHERE id = 'tenant-config'")

    ensure_fun = fn org ->
      send(parent, {:ensured, org.id})
      %{org_id: org.id, tenant_id: org.salix_tenant_id, status: "ok", changed: false}
    end

    assert {:ok, %{total: 2, wrapped: false}} =
             TenantConfigChecker.run_once(limit: 2, ensure_fun: ensure_fun)

    first_page = receive_ids(2)
    assert length(first_page) == 2

    assert {:ok, %{total: 1, wrapped: false}} =
             TenantConfigChecker.run_once(limit: 2, ensure_fun: ensure_fun)

    assert [third] = receive_ids(1)
    assert Enum.sort(first_page ++ [third]) == Enum.sort(Enum.map(orgs, & &1.id))

    assert {:ok, %{total: 0, wrapped: true}} =
             TenantConfigChecker.run_once(limit: 2, ensure_fun: ensure_fun)

    Repo.query!("""
    UPDATE tenant_config_scans
    SET lease_token = gen_random_uuid(), lease_expires_at = now() + interval '1 minute'
    WHERE id = 'tenant-config'
    """)

    assert {:ok, %{claimed: false, total: 0}} =
             TenantConfigChecker.run_once(limit: 2, ensure_fun: ensure_fun)

    Repo.query!("""
    UPDATE tenant_config_scans
    SET lease_token = NULL, lease_expires_at = NULL
    WHERE id = 'tenant-config'
    """)

    assert {:error, :stale_tenant_config_scan} =
             TenantConfigChecker.run_once(
               limit: 1,
               ensure_fun: fn org ->
                 Repo.query!("""
                 UPDATE tenant_config_scans
                 SET lease_token = gen_random_uuid(), lease_expires_at = now() - interval '1 second'
                 WHERE id = 'tenant-config'
                 """)

                 %{org_id: org.id, tenant_id: org.salix_tenant_id, status: "ok"}
               end
             )

    [[cursor]] =
      Repo.query!(
        "SELECT cursor_org_id::text FROM tenant_config_scans WHERE id = 'tenant-config'"
      ).rows

    assert is_nil(cursor)
  end

  test "observability pruning uses one shared lease and rotates bounded batches" do
    {:ok, org} = Orgs.create_org(%{name: "Prune", slug: "prune"})

    for n <- 1..5 do
      assert {:ok, _} =
               Observability.record_audit(%{
                 org_id: org.id,
                 action: "test.prune.#{n}",
                 resource_type: "test",
                 resource_id: Integer.to_string(n),
                 result: "ok"
               })
    end

    Repo.update_all(
      from(log in AuditLog, where: log.org_id == ^org.id),
      set: [created_at: DateTime.add(DateTime.utc_now(), -172_800, :second)]
    )

    Repo.query!("DELETE FROM observability_prune_scans WHERE id = 'operations-retention'")

    policy = %{
      stderr_tail_days: false,
      observability_events_days: false,
      operation_runs_days: false,
      check_results_days: false,
      audit_logs_days: 1
    }

    assert {:error, {:exception, %FunctionClauseError{}}} =
             Pruner.run_batch_once(
               limit: 2,
               policy: Map.put(policy, :stderr_tail_days, "invalid")
             )

    assert [[nil]] =
             Repo.query!(
               "SELECT lease_token FROM observability_prune_scans WHERE id = 'operations-retention'"
             ).rows

    Repo.query!("DELETE FROM observability_prune_scans WHERE id = 'operations-retention'")

    first_round =
      for _ <- 1..5 do
        {:ok, counts} = Pruner.run_batch_once(limit: 2, policy: policy)
        counts
      end

    assert Enum.map(first_round, & &1.audit_logs_deleted) == [0, 0, 0, 0, 2]
    assert Repo.aggregate(from(log in AuditLog, where: log.org_id == ^org.id), :count) == 3

    second_round =
      for _ <- 1..5 do
        {:ok, counts} = Pruner.run_batch_once(limit: 2, policy: policy)
        counts
      end

    assert List.last(second_round).audit_logs_deleted == 2
    assert Repo.aggregate(from(log in AuditLog, where: log.org_id == ^org.id), :count) == 1

    Repo.query!("""
    UPDATE observability_prune_scans
    SET lease_token = gen_random_uuid(), lease_expires_at = now() + interval '1 minute'
    WHERE id = 'operations-retention'
    """)

    assert {:ok, %{claimed: false}} = Pruner.run_batch_once(limit: 2, policy: policy)
  end

  test "durable periodic workers persist only bounded error classes" do
    marker = "secret-marker-"
    payload = marker <> String.duplicate("x", 1_000_000)

    {_org, project} = project_fixture("bounded-errors")
    assert :ok = DashboardReconciler.request_refresh(project.id)

    assert {:error, ^payload} =
             DashboardReconciler.run_once(
               backstop_limit: 0,
               retry_ms: 0,
               refresh_fun: fn _project_id, _opts -> {:error, payload} end
             )

    assert_bounded_last_error(
      "SELECT last_error FROM dashboard_projection_refreshes WHERE project_id = $1::text::uuid",
      [project.id],
      marker
    )

    {:ok, _org} = Orgs.create_org(%{name: "Bounded tenant", slug: "bounded-tenant"})
    Repo.query!("DELETE FROM tenant_config_scans WHERE id = 'tenant-config'")

    assert {:error, {:throw, ^payload}} =
             TenantConfigChecker.run_once(
               limit: 1,
               ensure_fun: fn _org -> throw(payload) end
             )

    assert_bounded_last_error(
      "SELECT last_error FROM tenant_config_scans WHERE id = 'tenant-config'",
      [],
      marker
    )

    Repo.query!("DELETE FROM observability_prune_scans WHERE id = 'operations-retention'")

    Application.put_env(
      :bridge_for_teams_core,
      :periodic_convergence_pruner_error_payload,
      payload
    )

    on_exit(fn ->
      Application.delete_env(
        :bridge_for_teams_core,
        :periodic_convergence_pruner_error_payload
      )
    end)

    assert {:error, {:exception, %RuntimeError{message: ^payload}}} =
             Pruner.run_batch_once(
               repo: OneShotPrunerRepo,
               policy: %{
                 stderr_tail_days: 1,
                 observability_events_days: false,
                 operation_runs_days: false,
                 check_results_days: false,
                 audit_logs_days: false
               }
             )

    assert_bounded_last_error(
      "SELECT last_error FROM observability_prune_scans WHERE id = 'operations-retention'",
      [],
      marker
    )
  end

  defp successful_dashboard_refresh(project) do
    fn _project_id, opts ->
      case Repo.transaction(fn ->
             :ok = opts[:commit_guard].()

             {:ok, snapshot} =
               DashboardProjection.upsert_snapshot(project, %{
                 refreshed_at: DateTime.utc_now(),
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

  defp assert_bounded_last_error(statement, params, marker) do
    assert [[last_error]] = Repo.query!(statement, params).rows
    assert is_binary(last_error)
    assert byte_size(last_error) <= 128
    refute String.contains?(last_error, marker)
  end

  defp receive_ids(count) do
    for _ <- 1..count do
      assert_receive {:ensured, id}
      id
    end
  end

  defp project_fixture(suffix) do
    unique = System.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{name: "Org #{suffix}", slug: "#{suffix}-#{unique}"})

    {:ok, project} =
      Projects.create_project(org.id, %{name: "Project #{suffix}", slug: "#{suffix}-#{unique}"})

    {org, project}
  end
end
