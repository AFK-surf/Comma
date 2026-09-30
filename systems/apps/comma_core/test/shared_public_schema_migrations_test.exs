defmodule Comma.SharedPublicSchemaMigrationsTest do
  use ExUnit.Case, async: false

  @bft_baseline_version 20_260_716_000_001
  @comma_baseline_version 20_260_722_000_002
  @cutover_marker_version 20_260_723_000_003
  @renumbered_bft_storage_version 20_260_723_000_011
  @renumbered_bft_periodic_version 20_260_723_000_012
  @renumbered_bft_device_version 20_260_723_000_013
  @ledger_collision_repair_version 20_260_723_000_014
  @legacy_user_id_repair_version 20_260_723_000_015
  @ledger_collision_v1_repair_version 20_260_723_000_016
  @workspace_generation_repair_version 20_260_724_000_017
  @workspace_vfs_ownership_repair_version 20_260_724_000_018
  @legacy_prefixed_user_id "usr-codex-electron-staging-smoke"
  @legacy_uuid_user_id "7f659052-4028-460b-b9e8-79dca0d7be3d"

  defmodule SharedTopologyRepo do
    use Ecto.Repo,
      otp_app: :comma_core,
      adapter: Ecto.Adapters.Postgres
  end

  test "the production manifest executor applies every fresh shared-ledger artifact" do
    database = "comma_shared_topology_#{System.unique_integer([:positive])}"

    repo_config =
      Comma.Repo.config()
      |> Keyword.put(:database, database)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    assert :ok = Ecto.Adapters.Postgres.storage_up(repo_config)

    on_exit(fn ->
      case Ecto.Adapters.Postgres.storage_down(repo_config) do
        :ok -> :ok
        {:error, :already_down} -> :ok
      end
    end)

    {:ok, repo_pid} = SharedTopologyRepo.start_link(repo_config)
    Process.unlink(repo_pid)

    try do
      assert Ecto.Migrator.run(
               SharedTopologyRepo,
               migration_path("../../bridge_for_teams_core"),
               :up,
               to: @bft_baseline_version,
               strict_version_order: true,
               log: false
             ) != []

      assert Ecto.Migrator.run(
               SharedTopologyRepo,
               migration_path(".."),
               :up,
               to: @comma_baseline_version,
               strict_version_order: true,
               log: false
             ) != []

      seed_grandfathered_users!(SharedTopologyRepo)

      with_release_sources(SharedTopologyRepo, fn ->
        assert :ok =
                 Comma.Release.execute_authorized_schema_steps([
                   "bridge-20260724000018",
                   "bridge-20260723000011",
                   "bridge-20260723000012",
                   "bridge-20260723000013",
                   "comma-20260723000001",
                   "comma-20260723000002",
                   "comma-20260723000004",
                   "comma-20260723000005",
                   "comma-20260723000006",
                   "comma-20260723000014",
                   "comma-20260723000007",
                   "comma-20260723000008",
                   "comma-20260723000009",
                   "comma-20260723000010",
                   "comma-20260723000015",
                   "comma-20260723000016",
                   "comma-20260724000001",
                   "comma-20260724000017"
                 ])
      end)

      refute Comma.Schema.ready?(SharedTopologyRepo)

      # The release-only cutover migration has external import/audit
      # preconditions covered by Comma.ReleaseAdapterE2ETest. This topology test
      # records the successfully audited marker so the remaining repo
      # migrations can be exercised in the same strict order as production.
      Ecto.Adapters.SQL.query!(
        SharedTopologyRepo,
        """
        INSERT INTO schema_migrations (version, inserted_at)
        VALUES ($1, NOW())
        """,
        [@cutover_marker_version]
      )

      assert %{rows: [["public"]]} =
               Ecto.Adapters.SQL.query!(SharedTopologyRepo, "SELECT current_schema()")

      assert Comma.Schema.ready?(SharedTopologyRepo)

      assert %{rows: version_rows} =
               Ecto.Adapters.SQL.query!(
                 SharedTopologyRepo,
                 """
                 SELECT version
                 FROM schema_migrations
                 WHERE version BETWEEN 20260723000001 AND 20260723000013
                 ORDER BY version
                 """
               )

      assert Enum.map(version_rows, &hd/1) ==
               Enum.to_list(20_260_723_000_001..20_260_723_000_013)

      assert %{rows: rows} =
               Ecto.Adapters.SQL.query!(
                 SharedTopologyRepo,
                 """
                 SELECT table_name
                 FROM information_schema.tables
                 WHERE table_schema = 'public'
                   AND table_name IN (
                     'auth_sessions',
                     'artifact_sweep_scans',
                     'comma_auth_sessions',
                     'comma_external_operations',
                     'comma_session_lifecycle_writer_epoch_tokens',
                     'comma_session_lifecycle_writer_epochs',
                     'comma_user_identities',
                     'dashboard_projection_refreshes',
                     'oban_jobs',
                     'oban_peers',
                     'observability_prune_scans',
                     'project_device_projection_scans',
                     'project_device_projections',
                     'storage_metering_scans',
                     'tenant_config_scans'
                   )
                 ORDER BY table_name
                 """
               )

      assert Enum.map(rows, &hd/1) == [
               "artifact_sweep_scans",
               "auth_sessions",
               "comma_auth_sessions",
               "comma_external_operations",
               "comma_session_lifecycle_writer_epoch_tokens",
               "comma_session_lifecycle_writer_epochs",
               "comma_user_identities",
               "dashboard_projection_refreshes",
               "oban_jobs",
               "oban_peers",
               "observability_prune_scans",
               "project_device_projection_scans",
               "project_device_projections",
               "storage_metering_scans",
               "tenant_config_scans"
             ]

      assert %{rows: [[bft_type], [comma_type]]} =
               Ecto.Adapters.SQL.query!(
                 SharedTopologyRepo,
                 """
                 SELECT data_type
                 FROM information_schema.columns
                 WHERE table_schema = 'public'
                   AND column_name = 'user_id'
                   AND table_name IN ('auth_sessions', 'comma_auth_sessions')
                 ORDER BY table_name
                 """
               )

      assert bft_type == "uuid"
      assert comma_type == "character varying"

      assert %{rows: [[@legacy_uuid_user_id, "Legacy UUID User", @legacy_uuid_user_id]]} =
               Ecto.Adapters.SQL.query!(
                 SharedTopologyRepo,
                 """
                 UPDATE comma_users
                 SET display_name = 'Legacy UUID User'
                 WHERE id = $1
                 RETURNING id, display_name,
                   (SELECT owner_user_id FROM comma_workspaces WHERE id = 'wsp_legacy_uuid')
                 """,
                 [@legacy_uuid_user_id]
               )

      assert %{rows: [[@legacy_prefixed_user_id, @legacy_prefixed_user_id]]} =
               Ecto.Adapters.SQL.query!(
                 SharedTopologyRepo,
                 """
                 SELECT id,
                   (SELECT owner_user_id FROM comma_workspaces WHERE id = 'wsp_legacy_prefix')
                 FROM comma_users
                 WHERE id = $1
                 """,
                 [@legacy_prefixed_user_id]
               )

      assert_raise Postgrex.Error, ~r/comma_users_public_id_valid/, fn ->
        Ecto.Adapters.SQL.query!(
          SharedTopologyRepo,
          """
          INSERT INTO comma_users (
            id, normalized_email, status, profile, lock_version, inserted_at, updated_at
          )
          VALUES ('legacy arbitrary id', 'invalid-id@example.com', 'active', '{}', 1, NOW(), NOW())
          """
        )
      end

      assert %{rows: index_rows} =
               Ecto.Adapters.SQL.query!(
                 SharedTopologyRepo,
                 """
                 SELECT indexname
                 FROM pg_indexes
                 WHERE schemaname = 'public'
                   AND tablename IN ('comma_user_identities', 'workspace_items')
                 ORDER BY indexname
                 """
               )

      index_names = MapSet.new(index_rows, &hd/1)

      assert "comma_user_identities_user_provider_unique" in index_names
      assert "workspace_items_project_user_vfs_path_uniq" in index_names
      refute "comma_user_identities_user_id_index" in index_names
    after
      Supervisor.stop(repo_pid, :normal)
    end
  end

  test "all three renumbered BFT ledger collisions converge across three releases before cutover" do
    with_isolated_repo("comma_shared_collision", fn repo ->
      assert Ecto.Migrator.run(
               repo,
               migration_path("../../bridge_for_teams_core"),
               :up,
               to: @bft_baseline_version,
               strict_version_order: true,
               log: false
             ) != []

      assert Ecto.Migrator.run(
               repo,
               migration_path(".."),
               :up,
               to: @comma_baseline_version,
               strict_version_order: true,
               log: false
             ) != []

      bft_storage =
        require_migration!(
          "../../bridge_for_teams_core/priv/repo/migrations/20260723000011_add_periodic_convergence_state.exs",
          BridgeForTeams.Repo.Migrations.AddPeriodicConvergenceState
        )

      bft_periodic =
        require_migration!(
          "../../bridge_for_teams_core/priv/repo/migrations/20260723000012_add_bft_periodic_convergence_state.exs",
          BridgeForTeams.Repo.Migrations.AddBftPeriodicConvergenceState
        )

      bft_device =
        require_migration!(
          "../../bridge_for_teams_core/priv/repo/migrations/20260723000013_add_project_device_projection.exs",
          BridgeForTeams.Repo.Migrations.AddProjectDeviceProjection
        )

      assert :ok =
               Ecto.Migrator.up(repo, 20_260_723_000_001, bft_storage,
                 strict_version_order: false,
                 log: false
               )

      assert :ok =
               Ecto.Migrator.up(repo, 20_260_723_000_002, bft_periodic,
                 strict_version_order: false,
                 log: false
               )

      assert :ok =
               Ecto.Migrator.up(repo, 20_260_723_000_003, bft_device,
                 strict_version_order: false,
                 log: false
               )

      with_release_sources(repo, fn ->
        first_plan = release_plan!(repo)
        first_online_ids = stage_ids(first_plan, "expand")

        assert Enum.take(first_online_ids, 4) == [
                 "bridge-20260723000012",
                 "bridge-20260723000013",
                 "bridge-20260724000018",
                 "bridge-20260723000011"
               ]

        assert "comma-20260723000014" in first_online_ids

        assert_raise RuntimeError, ~r/cleared colliding BFT migration versions/, fn ->
          Comma.Release.execute_plan_stage(
            "online",
            first_plan.manifestDigest,
            first_online_ids,
            plan: fn -> release_plan!(repo) end
          )
        end
      end)

      assert applied_versions(repo, [
               20_260_723_000_001,
               20_260_723_000_002,
               20_260_723_000_003,
               @renumbered_bft_storage_version,
               @renumbered_bft_periodic_version,
               @renumbered_bft_device_version,
               @ledger_collision_repair_version,
               @ledger_collision_v1_repair_version
             ]) == [
               20_260_723_000_001,
               @renumbered_bft_storage_version,
               @renumbered_bft_periodic_version,
               @renumbered_bft_device_version
             ]

      comma_status =
        Ecto.Migrator.migrations(repo, [
          migration_path(".."),
          Path.expand("../priv/release_migrations", __DIR__)
        ])

      assert Enum.any?(comma_status, fn
               {:down, 20_260_723_000_002, _name} -> true
               _migration -> false
             end)

      assert Enum.any?(comma_status, fn
               {:down, 20_260_723_000_003, _name} -> true
               _migration -> false
             end)

      with_release_sources(repo, fn ->
        second_plan = release_plan!(repo)

        assert "comma-20260723000002" in second_plan.pendingIDs
        assert "comma-20260723000014" in second_plan.pendingIDs
        assert "comma-20260723000016" in second_plan.pendingIDs

        assert_raise RuntimeError,
                     ~r/cleared colliding BFT migration version 20260723000001/,
                     fn ->
                       Comma.Release.execute_plan_stage(
                         "online",
                         second_plan.manifestDigest,
                         stage_ids(second_plan, "expand"),
                         plan: fn -> release_plan!(repo) end
                       )
                     end
      end)

      assert applied_versions(repo, [
               20_260_723_000_001,
               20_260_723_000_002,
               20_260_723_000_003,
               @renumbered_bft_storage_version,
               @renumbered_bft_periodic_version,
               @renumbered_bft_device_version,
               @ledger_collision_repair_version,
               @ledger_collision_v1_repair_version
             ]) == [
               20_260_723_000_002,
               @renumbered_bft_storage_version,
               @renumbered_bft_periodic_version,
               @renumbered_bft_device_version,
               @ledger_collision_repair_version
             ]

      with_release_sources(repo, fn ->
        blocked_cutover_plan = release_plan!(repo)

        assert_raise RuntimeError,
                     ~r/cutover requires all online release steps to converge/,
                     fn ->
                       Comma.Release.execute_plan_stage(
                         "cutover",
                         blocked_cutover_plan.manifestDigest,
                         ["comma-20260723000003"],
                         plan: fn -> release_plan!(repo) end,
                         cutover_executor: fn _ids -> flunk("cutover executor must not run") end
                       )
                     end

        third_plan = release_plan!(repo)
        third_online_ids = stage_ids(third_plan, "expand")

        assert Enum.find_index(third_online_ids, &(&1 == "comma-20260723000001")) <
                 Enum.find_index(third_online_ids, &(&1 == "comma-20260723000016"))

        assert Enum.find_index(third_online_ids, &(&1 == "comma-20260723000016")) <
                 Enum.find_index(third_online_ids, &(&1 == "comma-20260724000017"))

        assert :ok =
                 Comma.Release.execute_plan_stage(
                   "online",
                   third_plan.manifestDigest,
                   third_online_ids,
                   plan: fn -> release_plan!(repo) end
                 )

        cutover_plan = release_plan!(repo)
        assert stage_ids(cutover_plan, "expand") == []

        assert stage_ids(cutover_plan, "exclusive") == [
                 "comma-20260723000003",
                 "comma-20260912000001"
               ]

        seed_final_import_ledger!(repo)

        assert :ok =
                 Comma.Release.execute_plan_stage(
                   "cutover",
                   cutover_plan.manifestDigest,
                   stage_ids(cutover_plan, "exclusive"),
                   plan: fn -> release_plan!(repo) end
                 )

        assert stage_ids(release_plan!(repo), "exclusive") == []
      end)

      assert applied_versions(repo, [
               20_260_723_000_001,
               @renumbered_bft_storage_version,
               @ledger_collision_v1_repair_version,
               @workspace_generation_repair_version
             ]) == [
               20_260_723_000_001,
               @renumbered_bft_storage_version,
               @ledger_collision_v1_repair_version,
               @workspace_generation_repair_version
             ]

      assert %{rows: [[true, true, true, true]]} =
               Ecto.Adapters.SQL.query!(
                 repo,
                 """
                 SELECT
                   to_regclass('public.dashboard_projection_refreshes') IS NOT NULL,
                   to_regclass('public.project_device_projections') IS NOT NULL,
                   EXISTS (
                     SELECT 1 FROM information_schema.columns
                     WHERE table_schema = 'public'
                       AND table_name = 'comma_workspaces'
                       AND column_name = 'vm'
                   ),
                   to_regclass('public.comma_session_budget_consumptions') IS NOT NULL
                 """
               )
    end)
  end

  test "ledger collision repair 16 fails closed for partial Comma schema" do
    with_isolated_repo("comma_shared_collision_partial", fn repo ->
      prepare_v1_collision!(repo, record_renumbered: true)
      Ecto.Adapters.SQL.query!(repo, "ALTER TABLE comma_workspaces ADD COLUMN vm text")

      repair =
        require_migration!(
          "../priv/repo/migrations/20260723000016_repair_renumbered_bft_ledger_collision_v1.exs",
          Comma.Repo.Migrations.RepairRenumberedBftLedgerCollisionV1
        )

      assert_raise RuntimeError, ~r/partial schema/, fn ->
        Ecto.Migrator.up(repo, @ledger_collision_v1_repair_version, repair,
          strict_version_order: false,
          log: false
        )
      end

      assert applied_versions(repo, [20_260_723_000_001]) == [20_260_723_000_001]
    end)
  end

  test "ledger collision repair 16 uses the serving workspace VM as the Comma 1 boundary" do
    with_isolated_repo("comma_shared_collision_vm_ready", fn repo ->
      prepare_v1_collision!(repo, record_renumbered: true)
      Ecto.Adapters.SQL.query!(repo, "ALTER TABLE comma_workspaces ADD COLUMN vm jsonb")

      repair =
        require_migration!(
          "../priv/repo/migrations/20260723000016_repair_renumbered_bft_ledger_collision_v1.exs",
          Comma.Repo.Migrations.RepairRenumberedBftLedgerCollisionV1
        )

      assert :ok =
               Ecto.Migrator.up(repo, @ledger_collision_v1_repair_version, repair,
                 strict_version_order: false,
                 log: false
               )

      assert applied_versions(repo, [
               20_260_723_000_001,
               @renumbered_bft_storage_version,
               @ledger_collision_v1_repair_version
             ]) == [
               20_260_723_000_001,
               @renumbered_bft_storage_version,
               @ledger_collision_v1_repair_version
             ]

      assert %{rows: [[nil]]} =
               Ecto.Adapters.SQL.query!(
                 repo,
                 "SELECT to_regclass('public.comma_session_budget_consumptions')"
               )
    end)
  end

  test "ledger collision repair 16 preserves ledger one without exact renumbered proof" do
    with_isolated_repo("comma_shared_collision_unproven", fn repo ->
      prepare_v1_collision!(repo, record_renumbered: false)

      repair =
        require_migration!(
          "../priv/repo/migrations/20260723000016_repair_renumbered_bft_ledger_collision_v1.exs",
          Comma.Repo.Migrations.RepairRenumberedBftLedgerCollisionV1
        )

      assert_raise RuntimeError, ~r/exact colliding and renumbered BFT ledger versions/, fn ->
        Ecto.Migrator.up(repo, @ledger_collision_v1_repair_version, repair,
          strict_version_order: false,
          log: false
        )
      end

      assert applied_versions(repo, [20_260_723_000_001]) == [20_260_723_000_001]
    end)
  end

  test "ledger collision repair 16 preserves ledger one when Bridge 11 postconditions drift" do
    with_isolated_repo("comma_shared_collision_drift", fn repo ->
      prepare_v1_collision!(repo, record_renumbered: true)
      Ecto.Adapters.SQL.query!(repo, "DROP INDEX workspace_items_project_user_vfs_path_uniq")

      repair =
        require_migration!(
          "../priv/repo/migrations/20260723000016_repair_renumbered_bft_ledger_collision_v1.exs",
          Comma.Repo.Migrations.RepairRenumberedBftLedgerCollisionV1
        )

      assert_raise RuntimeError, ~r/complete renumbered schema/, fn ->
        Ecto.Migrator.up(repo, @ledger_collision_v1_repair_version, repair,
          strict_version_order: false,
          log: false
        )
      end

      assert applied_versions(repo, [20_260_723_000_001]) == [20_260_723_000_001]
    end)
  end

  test "workspace VFS ownership repair precedes Bridge 11 and preserves artifact references" do
    with_isolated_repo("comma_workspace_vfs_ownership", fn repo ->
      assert Ecto.Migrator.run(
               repo,
               migration_path("../../bridge_for_teams_core"),
               :up,
               to: @bft_baseline_version,
               strict_version_order: true,
               log: false
             ) != []

      path = "/.salix/reports/daily-briefing/2026-07-24.md"
      seed_workspace_item_vfs_duplicate!(repo, path)

      with_release_sources(repo, fn ->
        plan = release_plan!(repo)
        online_ids = stage_ids(plan, "expand")

        assert Enum.find_index(online_ids, &(&1 == "bridge-20260724000018")) <
                 Enum.find_index(online_ids, &(&1 == "bridge-20260723000011"))

        assert :ok =
                 Comma.Release.execute_authorized_schema_steps([
                   "bridge-20260724000018",
                   "bridge-20260723000011"
                 ])
      end)

      assert %{rows: [["routine_run", nil], ["report", ^path]]} =
               Ecto.Adapters.SQL.query!(
                 repo,
                 """
                 SELECT kind, vfs_path
                 FROM workspace_items
                 ORDER BY CASE kind WHEN 'routine_run' THEN 1 ELSE 2 END
                 """
               )

      assert %{rows: [[true, true, predicate]]} =
               Ecto.Adapters.SQL.query!(
                 repo,
                 """
                 SELECT indisvalid, indisunique, pg_get_expr(indpred, indrelid)
                 FROM pg_index
                 WHERE indexrelid =
                   to_regclass('public.workspace_items_project_user_vfs_path_uniq')
                 """
               )

      assert predicate =~ "vfs_path IS NOT NULL"
      assert predicate =~ "payload ->> 'vfs_path'"

      assert_raise Postgrex.Error, ~r/workspace_items_project_user_vfs_path_uniq/, fn ->
        insert_workspace_item!(
          repo,
          "00000000-0000-0000-0000-000000000203",
          "second_report",
          "report",
          path,
          true
        )
      end

      assert :ok =
               insert_workspace_item!(
                 repo,
                 "00000000-0000-0000-0000-000000000204",
                 "legacy_reference",
                 "routine_run",
                 path,
                 false
               )
    end)
  end

  test "workspace VFS ownership repair rolls back ambiguous payload owners" do
    with_isolated_repo("comma_workspace_vfs_ambiguous", fn repo ->
      assert Ecto.Migrator.run(
               repo,
               migration_path("../../bridge_for_teams_core"),
               :up,
               to: @bft_baseline_version,
               strict_version_order: true,
               log: false
             ) != []

      path = "/.salix/reports/ambiguous/2026-07-24.md"
      seed_workspace_item_owner!(repo)

      assert :ok =
               insert_workspace_item!(
                 repo,
                 "00000000-0000-0000-0000-000000000211",
                 "report_one",
                 "report",
                 path,
                 true
               )

      assert :ok =
               insert_workspace_item!(
                 repo,
                 "00000000-0000-0000-0000-000000000212",
                 "report_two",
                 "report",
                 path,
                 true
               )

      repair =
        require_migration!(
          "../../bridge_for_teams_core/priv/repo/migrations/20260724000018_repair_workspace_item_vfs_ownership.exs",
          BridgeForTeams.Repo.Migrations.RepairWorkspaceItemVfsOwnership
        )

      assert_raise Postgrex.Error, ~r/ambiguous duplicate path/, fn ->
        Ecto.Migrator.up(repo, @workspace_vfs_ownership_repair_version, repair,
          strict_version_order: false,
          log: false
        )
      end

      assert applied_versions(repo, [@workspace_vfs_ownership_repair_version]) == []

      assert %{rows: [[2]]} =
               Ecto.Adapters.SQL.query!(
                 repo,
                 """
                 SELECT count(*)
                 FROM workspace_items
                 WHERE vfs_path = $1
                 """,
                 [path]
               )
    end)
  end

  test "workspace generation repair canonicalizes the retired router-sensitive value" do
    with_isolated_repo("comma_workspace_generation", fn repo ->
      prepare_comma_baseline!(repo)
      seed_workspace_generation_user!(repo)

      legacy = workspace_generation(["tenant-1", "group-1", "router-1"])
      canonical = workspace_generation(["tenant-1", "group-1"])

      insert_workspace_generation!(
        repo,
        "workspace-legacy",
        "tenant-1",
        "group-1",
        "router-1",
        legacy
      )

      insert_workspace_generation!(
        repo,
        "workspace-canonical",
        "tenant-2",
        "group-2",
        "router-2",
        workspace_generation(["tenant-2", "group-2"])
      )

      repair =
        require_migration!(
          "../priv/repo/migrations/20260724000017_canonicalize_workspace_group_generations.exs",
          Comma.Repo.Migrations.CanonicalizeWorkspaceGroupGenerations
        )

      assert :ok =
               Ecto.Migrator.up(repo, @workspace_generation_repair_version, repair,
                 strict_version_order: false,
                 log: false
               )

      assert %{rows: [["workspace-canonical", canonical_2], ["workspace-legacy", ^canonical]]} =
               Ecto.Adapters.SQL.query!(
                 repo,
                 """
                 SELECT id, group_generation
                 FROM comma_workspaces
                 ORDER BY id
                 """
               )

      assert canonical_2 == workspace_generation(["tenant-2", "group-2"])
    end)
  end

  test "workspace generation repair preserves an unexplained value" do
    with_isolated_repo("comma_workspace_generation_drift", fn repo ->
      prepare_comma_baseline!(repo)
      seed_workspace_generation_user!(repo)

      legacy = workspace_generation(["tenant-legacy", "group-legacy", "router-legacy"])

      insert_workspace_generation!(
        repo,
        "workspace-a-legacy",
        "tenant-legacy",
        "group-legacy",
        "router-legacy",
        legacy
      )

      insert_workspace_generation!(
        repo,
        "workspace-z-drift",
        "tenant-drift",
        "group-drift",
        "router-drift",
        "unexplained-generation"
      )

      repair =
        require_migration!(
          "../priv/repo/migrations/20260724000017_canonicalize_workspace_group_generations.exs",
          Comma.Repo.Migrations.CanonicalizeWorkspaceGroupGenerations
        )

      assert_raise RuntimeError, ~r/matches neither the canonical.*nor the retired/s, fn ->
        Ecto.Migrator.up(repo, @workspace_generation_repair_version, repair,
          strict_version_order: false,
          log: false
        )
      end

      assert %{
               rows: [
                 ["workspace-a-legacy", ^legacy],
                 ["workspace-z-drift", "unexplained-generation"]
               ]
             } =
               Ecto.Adapters.SQL.query!(
                 repo,
                 """
                 SELECT id, group_generation
                 FROM comma_workspaces
                 ORDER BY id
                 """
               )

      assert applied_versions(repo, [@workspace_generation_repair_version]) == []
    end)
  end

  test "a database that applied the old user ID constraint converges through repair migration 15" do
    with_isolated_repo("comma_legacy_user_id_constraint", fn repo ->
      assert Ecto.Migrator.run(
               repo,
               migration_path("../../bridge_for_teams_core"),
               :up,
               to: @bft_baseline_version,
               strict_version_order: true,
               log: false
             ) != []

      assert Ecto.Migrator.run(
               repo,
               migration_path(".."),
               :up,
               to: @comma_baseline_version,
               strict_version_order: true,
               log: false
             ) != []

      with_release_sources(repo, fn ->
        assert :ok =
                 Comma.Release.execute_authorized_schema_steps([
                   "bridge-20260724000018",
                   "bridge-20260723000011",
                   "bridge-20260723000012",
                   "bridge-20260723000013",
                   "comma-20260723000001",
                   "comma-20260723000002",
                   "comma-20260723000004",
                   "comma-20260723000005",
                   "comma-20260723000006",
                   "comma-20260723000014",
                   "comma-20260723000007",
                   "comma-20260723000008",
                   "comma-20260723000009",
                   "comma-20260723000010",
                   "comma-20260723000015",
                   "comma-20260723000016",
                   "comma-20260724000017"
                 ])

        Ecto.Adapters.SQL.query!(
          repo,
          "ALTER TABLE comma_users DROP CONSTRAINT comma_users_public_id_valid"
        )

        Ecto.Adapters.SQL.query!(
          repo,
          """
          ALTER TABLE comma_users
            ADD CONSTRAINT comma_users_public_id_valid
            CHECK (id ~ '^usr_[A-Za-z0-9_-]+$')
          """
        )

        Ecto.Adapters.SQL.query!(
          repo,
          "DELETE FROM schema_migrations WHERE version = $1",
          [@legacy_user_id_repair_version]
        )

        plan = release_plan!(repo)
        refute "comma-20260723000009" in plan.pendingIDs

        online_ids = stage_ids(plan, "expand")
        assert "comma-20260723000015" in online_ids

        assert :ok =
                 Comma.Release.execute_plan_stage(
                   "online",
                   plan.manifestDigest,
                   online_ids,
                   plan: fn -> release_plan!(repo) end
                 )
      end)

      seed_grandfathered_users!(repo)

      assert %{rows: [[@legacy_prefixed_user_id], [@legacy_uuid_user_id]]} =
               Ecto.Adapters.SQL.query!(
                 repo,
                 """
                 SELECT owner_user_id
                 FROM comma_workspaces
                 WHERE id IN ('wsp_legacy_prefix', 'wsp_legacy_uuid')
                 ORDER BY id
                 """
               )
    end)
  end

  defp with_isolated_repo(prefix, fun) do
    database = "#{prefix}_#{System.unique_integer([:positive])}"

    repo_config =
      Comma.Repo.config()
      |> Keyword.put(:database, database)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    assert :ok = Ecto.Adapters.Postgres.storage_up(repo_config)

    try do
      {:ok, repo_pid} = SharedTopologyRepo.start_link(repo_config)
      Process.unlink(repo_pid)

      try do
        fun.(SharedTopologyRepo)
      after
        Supervisor.stop(repo_pid, :normal)
      end
    after
      assert :ok = Ecto.Adapters.Postgres.storage_down(repo_config)
    end
  end

  defp prepare_comma_baseline!(repo) do
    assert Ecto.Migrator.run(
             repo,
             migration_path(".."),
             :up,
             to: @comma_baseline_version,
             strict_version_order: true,
             log: false
           ) != []
  end

  defp seed_workspace_generation_user!(repo) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      INSERT INTO comma_users (
        id, normalized_email, status, profile, lock_version, inserted_at, updated_at
      )
      VALUES ('workspace-owner', 'workspace-owner@example.com', 'active', '{}', 1, NOW(), NOW())
      """
    )
  end

  defp seed_workspace_item_vfs_duplicate!(repo, path) do
    seed_workspace_item_owner!(repo)

    assert :ok =
             insert_workspace_item!(
               repo,
               "00000000-0000-0000-0000-000000000201",
               "routine_run",
               "routine_run",
               path,
               false
             )

    assert :ok =
             insert_workspace_item!(
               repo,
               "00000000-0000-0000-0000-000000000202",
               "report",
               "report",
               path,
               true
             )
  end

  defp seed_workspace_item_owner!(repo) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      INSERT INTO users (id, email, status, created_at, updated_at)
      VALUES ('00000000-0000-0000-0000-000000000001', 'vfs-owner@example.com',
              'active', NOW(), NOW())
      """
    )

    Ecto.Adapters.SQL.query!(
      repo,
      """
      INSERT INTO organizations (
        id, name, slug, status, salix_tenant_id, billing_account_id,
        created_at, updated_at
      )
      VALUES ('00000000-0000-0000-0000-000000000002', 'VFS Org', 'vfs-org',
              'active', 'vfs-tenant', 'vfs-billing', NOW(), NOW())
      """
    )

    Ecto.Adapters.SQL.query!(
      repo,
      """
      INSERT INTO projects (
        id, org_id, name, slug, status, created_by_user_id, salix_group_id,
        created_at, updated_at
      )
      VALUES (
        '00000000-0000-0000-0000-000000000003',
        '00000000-0000-0000-0000-000000000002',
        'VFS Project',
        'vfs-project',
        'active',
        '00000000-0000-0000-0000-000000000001',
        'vfs-group',
        NOW(),
        NOW()
      )
      """
    )
  end

  defp insert_workspace_item!(repo, id, conversation_id, kind, path, payload_owner?) do
    payload = if payload_owner?, do: %{"vfs_path" => path}, else: %{}

    case Ecto.Adapters.SQL.query(
           repo,
           """
           INSERT INTO workspace_items (
             id, user_id, org_id, project_id, title, category, kind, platform,
             status, source, payload, metadata, source_refs, labels,
             latest_artifact, salix_conversation_id, vfs_path, created_at, updated_at
           )
           VALUES (
             $1,
             '00000000-0000-0000-0000-000000000001',
             '00000000-0000-0000-0000-000000000002',
             '00000000-0000-0000-0000-000000000003',
             $2::varchar,
             CASE WHEN $3 = 'report' THEN 'reports' ELSE 'routines' END,
             $3,
             'comma',
             'done',
             'projection',
             $4,
             '{}',
             '{}',
             '{}',
             jsonb_build_object('type', 'vfs', 'path', $5::varchar),
             $2::varchar,
             $5::varchar,
             NOW(),
             NOW()
           )
           """,
           [Ecto.UUID.dump!(id), conversation_id, kind, payload, path]
         ) do
      {:ok, _result} -> :ok
      {:error, error} -> raise error
    end
  end

  defp insert_workspace_generation!(repo, id, tenant_id, group_id, router_id, generation) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      INSERT INTO comma_workspaces (
        id,
        owner_user_id,
        salix_tenant_id,
        salix_group_id,
        group_generation,
        salix_router_agent_id,
        salix_worker_agent_id,
        billing_owner_id,
        status,
        lock_version,
        inserted_at,
        updated_at
      )
      VALUES ($1, 'workspace-owner', $2, $3, $4, $5, 'worker-1', 'billing-1',
              'active', 1, NOW(), NOW())
      """,
      [id, tenant_id, group_id, generation, router_id]
    )
  end

  defp workspace_generation(parts) do
    :crypto.hash(:sha256, Enum.join(parts, ":"))
    |> Base.url_encode64(padding: false)
  end

  defp require_migration!(relative_path, module) do
    Code.require_file(Path.expand(relative_path, __DIR__))
    module
  end

  defp prepare_v1_collision!(repo, opts) do
    assert Ecto.Migrator.run(
             repo,
             migration_path("../../bridge_for_teams_core"),
             :up,
             to: @bft_baseline_version,
             strict_version_order: true,
             log: false
           ) != []

    assert Ecto.Migrator.run(
             repo,
             migration_path(".."),
             :up,
             to: @comma_baseline_version,
             strict_version_order: true,
             log: false
           ) != []

    bft_storage =
      require_migration!(
        "../../bridge_for_teams_core/priv/repo/migrations/20260723000011_add_periodic_convergence_state.exs",
        BridgeForTeams.Repo.Migrations.AddPeriodicConvergenceState
      )

    assert :ok =
             Ecto.Migrator.up(repo, 20_260_723_000_001, bft_storage,
               strict_version_order: false,
               log: false
             )

    if Keyword.fetch!(opts, :record_renumbered) do
      Ecto.Adapters.SQL.query!(
        repo,
        "INSERT INTO schema_migrations (version, inserted_at) VALUES ($1, NOW())",
        [@renumbered_bft_storage_version]
      )
    end
  end

  defp with_release_sources(repo, fun) do
    previous = Application.get_env(:comma, :release_ecto_sources)

    Application.put_env(:comma, :release_ecto_sources, %{
      comma_core: [repo: repo, migration_dir: migration_path("..")],
      bridge_for_teams_core: [
        repo: repo,
        migration_dir: migration_path("../../bridge_for_teams_core")
      ]
    })

    try do
      fun.()
    after
      if previous do
        Application.put_env(:comma, :release_ecto_sources, previous)
      else
        Application.delete_env(:comma, :release_ecto_sources)
      end
    end
  end

  defp seed_final_import_ledger!(repo) do
    identity = "comma-product-state-final-import-v1"
    zero_digest = String.duplicate("0", 64)
    completed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    evidence = %{
      "schema_version" => 1,
      "release_identity" => identity,
      "mode" => "import",
      "status" => "pass",
      "source_count" => 0,
      "source_object_count" => 0,
      "target_count" => 0,
      "checkpoint_count" => 0,
      "membership_index_count" => 0,
      "excluded_counts" => %{},
      "relation_counts" => %{},
      "source_digest" => zero_digest,
      "target_digest" => zero_digest,
      "checkpoint_digest" => zero_digest,
      "checkpoint_target_digest" => zero_digest,
      "secret_posture" => "redacted"
    }

    envelope = %{
      "release_identity" => identity,
      "status" => "complete",
      "evidence" => evidence,
      "completed_at" => DateTime.to_iso8601(completed_at)
    }

    repo.insert!(%Comma.Data.ImportRun{
      release_identity: identity,
      status: "complete",
      evidence: evidence,
      evidence_digest: digest(envelope),
      completed_at: completed_at
    })
  end

  defp digest(value) do
    value
    |> canonical()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(%DateTime{} = value),
    do: {:utc_microsecond, DateTime.to_unix(value, :microsecond)}

  defp canonical(value) when is_map(value) do
    value |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end) |> Enum.sort()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp applied_versions(repo, versions) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT version
        FROM schema_migrations
        WHERE version = ANY($1)
        ORDER BY version
        """,
        [versions]
      )

    Enum.map(rows, &hd/1)
  end

  defp seed_grandfathered_users!(repo) do
    seed_grandfathered_user!(
      repo,
      @legacy_prefixed_user_id,
      "legacy-prefix@example.com",
      "legacy_prefix"
    )

    seed_grandfathered_user!(
      repo,
      @legacy_uuid_user_id,
      "legacy-uuid@example.com",
      "legacy_uuid"
    )
  end

  defp seed_grandfathered_user!(repo, user_id, email, suffix) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      INSERT INTO comma_users (
        id, normalized_email, status, profile, lock_version, inserted_at, updated_at
      )
      VALUES ($1, $2, 'active', '{}', 1, NOW(), NOW())
      """,
      [user_id, email]
    )

    Ecto.Adapters.SQL.query!(
      repo,
      """
      INSERT INTO comma_workspaces (
        id, owner_user_id, salix_tenant_id, salix_group_id, group_generation,
        salix_router_agent_id, salix_worker_agent_id, billing_owner_id, status,
        lock_version, inserted_at, updated_at
      )
      VALUES (
        $2, $1, $3, $4, $8,
        $5, $6, $7, 'active',
        1, NOW(), NOW()
      )
      """,
      [
        user_id,
        "wsp_#{suffix}",
        "ten_#{suffix}",
        "grp_#{suffix}",
        "agt_router_#{suffix}",
        "agt_worker_#{suffix}",
        "bill_#{suffix}",
        workspace_generation(["ten_#{suffix}", "grp_#{suffix}"])
      ]
    )
  end

  defp release_plan!(repo) do
    manifest = Comma.ReleaseManifestV2.manifest()

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT version FROM schema_migrations"
      )

    applied = MapSet.new(rows, &hd/1)

    ecto_facts = fn owner ->
      manifest["steps"]
      |> Enum.filter(
        &(&1["owner"] == owner and &1["store"] == "postgres" and
            &1["source"] != "historical-ledger-only")
      )
      |> Enum.map(fn step ->
        # This suite reconstructs shared-schema releases. Contract migrations
        # are deferred outside ordinary release plans and are not part of this
        # online repair sequence.
        status =
          if step["phase"] == "contract" or MapSet.member?(applied, step["version"]),
            do: :up,
            else: :down

        {status, step["version"], step["id"]}
      end)
    end

    analytics_manifest =
      SalixAnalytics.Migrations.migrations()
      |> Map.new(&{&1.version, &1.checksum})

    {:ok, plan} =
      Comma.ReleasePlan.plan(
        facts: fn ->
          %{
            # Alert Router owns an independent logical database and migration
            # ledger. This fixture intentionally models only the shared public
            # schema, so the optional subsystem is out of scope here.
            alert_router: :disabled,
            comma: ecto_facts.("comma_core"),
            billing:
              manifest["steps"]
              |> Enum.filter(
                &(&1["owner"] == "billing_core" and &1["store"] == "postgres" and
                    &1["source"] != "historical-ledger-only")
              )
              |> Enum.map(&{:up, &1["version"], &1["id"]}),
            bridge: ecto_facts.("bridge_for_teams"),
            # Salix keeps an isolated salix_schema_migrations ledger; it never
            # appears in the shared public schema_migrations table this test
            # drives. Report its own manifest slice as applied so the shared
            # trio's collision scenario stays the only variable under test.
            salix:
              manifest["steps"]
              |> Enum.filter(&(&1["owner"] == "salix_store" and &1["store"] == "postgres"))
              |> Enum.map(&{:up, &1["version"], &1["id"]}),
            clickhouse: {:ok, %{manifest: analytics_manifest, pending: []}},
            catalog_digest: "shared-topology-e2e",
            catalog_current: true,
            require_provider: false
          }
        end
      )

    plan
  end

  defp stage_ids(plan, phase) do
    plan.pendingSteps
    |> Enum.filter(&(&1["phase"] == phase))
    |> Enum.map(& &1["id"])
  end

  defp migration_path(app_relative_path) do
    Path.expand(
      "#{app_relative_path}/priv/repo/migrations",
      __DIR__
    )
  end
end
