defmodule Comma.SharedPublicSchemaMigrationsTest do
  use SystemsClock.Case, async: false

  @bft_baseline_version 20_260_716_000_001
  @comma_baseline_version 20_260_722_000_002
  @cutover_marker_version 20_260_723_000_003
  @workspace_generation_repair_version 20_260_724_000_017
  @legacy_prefixed_user_id "usr-codex-electron-staging-smoke"
  @legacy_uuid_user_id "7f659052-4028-460b-b9e8-79dca0d7be3d"

  defmodule SharedTopologyRepo do
    use Ecto.Repo,
      otp_app: :comma_core,
      adapter: Ecto.Adapters.Postgres
  end

  test "the production manifest executor applies every fresh shared-ledger artifact" do
    database = "comma_shared_topology_#{SystemsRuntime.Proc.unique_integer([:positive])}"

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
    SystemsRuntime.Proc.unlink(repo_pid)

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

  defp with_isolated_repo(prefix, fun) do
    database = "#{prefix}_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    repo_config =
      Comma.Repo.config()
      |> Keyword.put(:database, database)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    assert :ok = Ecto.Adapters.Postgres.storage_up(repo_config)

    try do
      {:ok, repo_pid} = SharedTopologyRepo.start_link(repo_config)
      SystemsRuntime.Proc.unlink(repo_pid)

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

  defp with_release_sources(repo, fun) do
    previous = SystemsRuntime.get_env(:comma, :release_ecto_sources)

    SystemsRuntime.put_env(:comma, :release_ecto_sources, %{
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
        SystemsRuntime.put_env(:comma, :release_ecto_sources, previous)
      else
        SystemsRuntime.delete_env(:comma, :release_ecto_sources)
      end
    end
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

  defp migration_path(app_relative_path) do
    Path.expand(
      "#{app_relative_path}/priv/repo/migrations",
      __DIR__
    )
  end
end
