defmodule Comma.ReleaseAdapterE2ETest do
  use ExUnit.Case, async: false

  defmodule SharedLedgerRepo do
    use Ecto.Repo,
      otp_app: :comma,
      adapter: Ecto.Adapters.Postgres
  end

  @moduletag :release_controller_e2e

  @ecto_a 20_990_101_000_001
  @ecto_b 20_990_101_000_002
  @product_state_cutover 20_260_723_000_003
  @external_activity_revision_cutover 20_260_807_000_101
  @pending_binding_repair 20_990_101_000_007
  @analytics_a 20_990_102_000_001
  @analytics_b 20_990_102_000_002
  @analytics_partial 20_990_102_000_003
  @analytics_after_partial 20_990_102_000_004
  @participant_group_id "grp1_1000000000000000001_1000000000000000002"
  @participant_conversation_id "cnv1_1000000000000000003"
  @participant_id "ptp1_1000000000000000004"

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:salix_store)
    {:ok, _} = Application.ensure_all_started(:comma_core)
    {:ok, _} = Application.ensure_all_started(:billing_core)

    started_repo =
      unless Process.whereis(BillingCore.Repo) do
        {:ok, pid} = BillingCore.Repo.start_link()
        Process.unlink(pid)
        pid
      end

    Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo, sandbox: false)

    migration_dir = Path.join(System.tmp_dir!(), "comma-release-adapter-e2e")
    File.mkdir_p!(migration_dir)
    write_ecto_migrations(migration_dir)
    write_clickhouse_migrations(migration_dir)

    previous_sources = Application.get_env(:comma, :release_ecto_sources)
    previous_clickhouse = Application.get_env(:comma, :release_clickhouse_opts)
    clickhouse_database = "comma_release_e2e_#{System.unique_integer([:positive])}"

    Application.put_env(:comma, :release_ecto_sources, %{
      billing_core: [repo: BillingCore.Repo, migration_dir: migration_dir]
    })

    Application.put_env(:comma, :release_clickhouse_opts,
      base_url: System.get_env("RELEASE_E2E_CLICKHOUSE_URL", "http://127.0.0.1:8123"),
      table: "#{clickhouse_database}.events",
      migration_dir: migration_dir
    )

    cleanup_ecto()

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo, sandbox: false)
      cleanup_ecto()
      Ecto.Adapters.SQL.Sandbox.checkin(BillingCore.Repo)
      if started_repo, do: Supervisor.stop(started_repo, :normal)
      drop_clickhouse_database(clickhouse_database)
      restore_env(:release_ecto_sources, previous_sources)
      restore_env(:release_clickhouse_opts, previous_clickhouse)
      File.rm_rf!(migration_dir)
    end)

    {:ok, clickhouse_database: clickhouse_database}
  end

  test "aggregate release migration applies the Comma schema" do
    previous_subsystems = Application.get_env(:comma, :enabled_subsystems)
    Application.put_env(:comma, :enabled_subsystems, [:comma_product])
    on_exit(fn -> restore_env(:enabled_subsystems, previous_subsystems) end)

    assert :ok = Comma.Release.migrate()
    refute Comma.Schema.ready?()

    assert {:ok, before_cutover} = production_release_plan()

    assert %{"id" => "comma-20260723000003", "phase" => "exclusive"} =
             Enum.find(before_cutover.pendingSteps, &(&1["id"] == "comma-20260723000003"))

    assert %{rows: [["comma_users"], ["comma_import_checkpoints"]]} =
             Ecto.Adapters.SQL.query!(
               Comma.Repo,
               "SELECT table_name FROM information_schema.tables WHERE table_name IN ('comma_users', 'comma_import_checkpoints') ORDER BY table_name DESC",
               []
             )

    seed_final_import_ledger!()

    assert [
             20_260_723_000_003,
             20_260_912_000_001,
             20_261_001_190_001
           ] =
             Ecto.Migrator.run(
               Comma.Repo,
               Application.app_dir(:comma_core, "priv/release_migrations"),
               :up,
               all: true
             )

    assert Comma.Schema.ready?()

    assert {:ok, after_cutover} = production_release_plan()
    refute "comma-20260723000003" in after_cutover.pendingIDs
    refute "comma-20260912000001" in after_cutover.pendingIDs
    refute "comma-20261001190001" in after_cutover.pendingIDs
  end

  test "aggregate dev/compose migration relocates retained nested participant state" do
    previous_subsystems = Application.get_env(:comma, :enabled_subsystems)
    Application.put_env(:comma, :enabled_subsystems, [:salix])
    on_exit(fn -> restore_env(:enabled_subsystems, previous_subsystems) end)

    fixture = prepare_participant_state_cutover!()

    assert :ok = Comma.Release.migrate()
    assert {:error, :not_found} = SalixStore.S3.get(fixture.old_key)
    assert {:ok, %{body: body}} = SalixStore.S3.get(fixture.new_key)
    assert Jason.decode!(body) == fixture.participant

    assert :ok = Comma.Release.migrate()
    assert {:error, :not_found} = SalixStore.S3.get(fixture.old_key)
    assert {:ok, %{body: rerun_body}} = SalixStore.S3.get(fixture.new_key)
    assert Jason.decode!(rerun_body) == fixture.participant
  end

  test "cold aggregate Salix migration leaves cutovers a supervised Repo" do
    previous_subsystems = Application.get_env(:comma, :enabled_subsystems)
    Application.put_env(:comma, :enabled_subsystems, [:salix])

    on_exit(fn ->
      restore_env(:enabled_subsystems, previous_subsystems)
      {:ok, _} = Application.ensure_all_started(:salix_store)
    end)

    SalixStore.Repo.query!(
      "DELETE FROM salix_schema_migrations WHERE version = $1",
      [20_260_831_000_101]
    )

    :ok = Application.stop(:salix_store)
    refute Process.whereis(SalixStore.Repo)

    assert :ok = Comma.Release.migrate()
    assert Process.whereis(SalixStore.Repo)

    assert Enum.any?(Supervisor.which_children(SalixStore.Supervisor), fn
             {_id, pid, _type, [SalixStore.Repo]} when is_pid(pid) -> true
             _child -> false
           end)
  end

  test "pending assistant binding migration repairs a missing prior constraint" do
    assert :ok = Comma.Release.migrate()

    Code.require_file(
      Application.app_dir(
        :comma_core,
        "priv/repo/migrations/20260723000007_add_pending_assistant_chat_bindings.exs"
      )
    )

    migration = Comma.Repo.Migrations.AddPendingAssistantChatBindings

    Ecto.Adapters.SQL.query!(
      Comma.Repo,
      "DELETE FROM schema_migrations WHERE version = $1",
      [@pending_binding_repair]
    )

    Ecto.Adapters.SQL.query!(
      Comma.Repo,
      """
      ALTER TABLE comma_assistant_chat_bindings
      DROP CONSTRAINT IF EXISTS comma_assistant_chat_bindings_state_check
      """
    )

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(
        Comma.Repo,
        "DELETE FROM schema_migrations WHERE version = $1",
        [@pending_binding_repair]
      )

      Ecto.Adapters.SQL.query!(
        Comma.Repo,
        """
        ALTER TABLE comma_assistant_chat_bindings
        DROP CONSTRAINT IF EXISTS comma_assistant_chat_bindings_state_check
        """
      )

      assert :ok =
               Ecto.Migrator.up(Comma.Repo, @pending_binding_repair, migration,
                 strict_version_order: true
               )

      Ecto.Adapters.SQL.query!(
        Comma.Repo,
        "DELETE FROM schema_migrations WHERE version = $1",
        [@pending_binding_repair]
      )
    end)

    assert :ok =
             Ecto.Migrator.up(Comma.Repo, @pending_binding_repair, migration,
               strict_version_order: true
             )

    assert %{rows: [[true]]} =
             Ecto.Adapters.SQL.query!(
               Comma.Repo,
               """
               SELECT EXISTS (
                 SELECT 1
                 FROM pg_constraint
                 WHERE conrelid = 'comma_assistant_chat_bindings'::regclass
                   AND conname = 'comma_assistant_chat_bindings_state_check'
               )
               """
             )
  end

  test "real cutover entrypoint runs the terminal marker in the schema batch" do
    manifest_digest = "sha256:" <> String.duplicate("a", 64)
    marker_id = "comma-20260723000003"
    parent = self()
    calls = start_supervised!({Agent, fn -> 0 end})

    plan = fn ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})

      %{
        manifestDigest: manifest_digest,
        pendingSteps: if(call == 0, do: [plan_step(marker_id, "exclusive")], else: []),
        providerPendingIDs: []
      }
    end

    assert :ok =
             Comma.Release.execute_plan_stage("cutover", manifest_digest, [marker_id],
               plan: plan,
               cutover_executor: fn ids ->
                 Comma.Release.execute_cutover_steps(ids,
                   schema_runner: fn schema_ids ->
                     send(parent, {:cutover_schema_ids, schema_ids})
                     :ok
                   end
                 )
               end
             )

    assert_received {:cutover_schema_ids, [^marker_id]}
  end

  test "external Session Activity revision boundary runs only through the real cutover entrypoint" do
    id = "salix-20260807000101"
    manifest_digest = Comma.ReleaseManifestV2.manifest_digest()

    assert %{
             "id" => ^id,
             "phase" => "exclusive",
             "safety" => %{"rollbackStrategy" => "none"}
           } =
             step =
             Enum.find(
               Comma.ReleaseManifestV2.manifest()["steps"],
               &(&1["id"] == id)
             )

    assert Comma.Release.authorized_migration_path(
             :salix_store,
             @external_activity_revision_cutover
           ) =~
             "priv/release_migrations/20260807000101_external_session_activity_revision_cutover.exs"

    parent = self()
    calls = start_supervised!({Agent, fn -> 0 end})

    plan = fn ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})

      %{
        manifestDigest: manifest_digest,
        pendingSteps: if(call == 0, do: [step], else: []),
        providerPendingIDs: []
      }
    end

    assert :ok =
             Comma.Release.execute_plan_stage("cutover", manifest_digest, [id],
               plan: plan,
               cutover_executor: fn ids ->
                 send(parent, {:external_activity_cutover_ids, ids})
                 :ok
               end
             )

    assert_received {:external_activity_cutover_ids, [^id]}
  end

  test "release plan accepts the production topology's shared Ecto ledger" do
    {:ok, repo} =
      SharedLedgerRepo.start_link(
        BridgeForTeams.Repo.config()
        |> Keyword.put(:pool_size, 1)
        |> Keyword.put(:name, SharedLedgerRepo)
      )

    Process.unlink(repo)

    on_exit(fn ->
      if Process.alive?(repo), do: Supervisor.stop(repo, :normal)

      Ecto.Adapters.SQL.query!(
        BridgeForTeams.Repo,
        "DROP TABLE IF EXISTS comma_release_shared_schema_migrations"
      )
    end)

    Ecto.Adapters.SQL.query!(
      SharedLedgerRepo,
      "DROP TABLE IF EXISTS comma_release_shared_schema_migrations"
    )

    Ecto.Adapters.SQL.query!(
      SharedLedgerRepo,
      "CREATE TABLE comma_release_shared_schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp(0) without time zone)",
      [],
      timeout: :infinity
    )

    # The shared physical ledger carries only the Comma/Billing/BFT owners.
    # Salix and Alert Router keep isolated ledgers and must never appear in (or
    # read from) the shared table.
    postgres_versions =
      Comma.ReleaseManifestV2.manifest()["steps"]
      |> Enum.filter(
        &(&1["store"] == "postgres" and &1["id"] != "comma-local-seed" and
            &1["owner"] not in ["salix_store", "alert_router"])
      )
      |> Enum.map(& &1["version"])
      |> Enum.uniq()

    Enum.each(postgres_versions, fn version ->
      Ecto.Adapters.SQL.query!(
        SharedLedgerRepo,
        "INSERT INTO comma_release_shared_schema_migrations (version, inserted_at) VALUES ($1, NOW())",
        [version]
      )
    end)

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        SharedLedgerRepo,
        "SELECT version FROM comma_release_shared_schema_migrations ORDER BY version"
      )

    shared_ledger = Enum.map(rows, fn [version] -> {:up, version, "shared-ledger"} end)

    salix_ledger =
      Comma.ReleaseManifestV2.manifest()["steps"]
      |> Enum.filter(&(&1["owner"] == "salix_store" and &1["store"] == "postgres"))
      |> Enum.map(&{:up, &1["version"], &1["id"]})

    alert_router_ledger =
      Comma.ReleaseManifestV2.manifest()["steps"]
      |> Enum.filter(&(&1["owner"] == "alert_router" and &1["store"] == "postgres"))
      |> Enum.map(&{:up, &1["version"], &1["id"]})

    clickhouse_manifest =
      SalixAnalytics.Migrations.migrations()
      |> Map.new(&{&1.version, &1.checksum})

    assert {:ok, plan} =
             Comma.ReleasePlan.plan(
               facts: fn ->
                 %{
                   alert_router: alert_router_ledger,
                   comma: shared_ledger,
                   billing: shared_ledger,
                   bridge: shared_ledger,
                   salix: salix_ledger,
                   clickhouse: {:ok, %{manifest: clickhouse_manifest, pending: []}},
                   catalog_digest: "catalog",
                   catalog_current: true,
                   require_provider: false
                 }
               end
             )

    assert plan.requiredMode == "online"
    assert plan.pendingIDs == []
  end

  test "a newly pending known migration cannot escape the persisted allowed ids", %{
    clickhouse_database: clickhouse_database
  } do
    clickhouse_opts = Application.fetch_env!(:comma, :release_clickhouse_opts)
    assert {:ok, clickhouse_plan} = SalixAnalytics.Migrations.plan(clickhouse_opts)
    assert Enum.sort(clickhouse_plan.pending) == [@analytics_a, @analytics_b]
    refute clickhouse_database_exists?(clickhouse_database)

    manifest = "sha256:release-adapter-e2e"
    calls = start_supervised!({Agent, fn -> 0 end})

    plan = fn ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})

      %{
        manifestDigest: manifest,
        pendingSteps:
          if call == 0 do
            [
              plan_step("billing-#{@ecto_a}", "expand"),
              plan_step("analytics-#{@analytics_a}", "expand")
            ]
          else
            [
              plan_step("billing-#{@ecto_b}", "expand"),
              plan_step("analytics-#{@analytics_b}", "expand")
            ]
          end,
        providerPendingIDs: []
      }
    end

    assert :ok =
             Comma.Release.execute_plan_stage(
               "online",
               manifest,
               ["billing-#{@ecto_a}", "analytics-#{@analytics_a}"],
               plan: plan
             )

    assert ecto_applied?(@ecto_a)
    refute ecto_applied?(@ecto_b)
    assert clickhouse_applied?(clickhouse_database, @analytics_a)
    refute clickhouse_applied?(clickhouse_database, @analytics_b)
  end

  test "exclusive schema uses production Postgres and ClickHouse adapters with exact authorization",
       %{
         clickhouse_database: clickhouse_database
       } do
    manifest = "sha256:exclusive-release-adapter-e2e"
    calls = start_supervised!({Agent, fn -> 0 end})

    plan = fn ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})

      %{
        manifestDigest: manifest,
        pendingSteps:
          if call == 0 do
            [
              plan_step("billing-#{@ecto_a}", "exclusive"),
              plan_step("analytics-#{@analytics_a}", "exclusive")
            ]
          else
            [
              plan_step("billing-#{@ecto_b}", "exclusive"),
              plan_step("analytics-#{@analytics_b}", "exclusive")
            ]
          end,
        providerPendingIDs: []
      }
    end

    assert :ok =
             Comma.Release.execute_plan_stage(
               "cutover",
               manifest,
               ["billing-#{@ecto_a}", "analytics-#{@analytics_a}"],
               plan: plan
             )

    assert ecto_applied?(@ecto_a)
    refute ecto_applied?(@ecto_b)
    assert clickhouse_applied?(clickhouse_database, @analytics_a)
    refute clickhouse_applied?(clickhouse_database, @analytics_b)
  end

  test "manifest-authorized stages can apply a lower Ecto version after a higher version" do
    manifest = "sha256:manifest-authorized-non-monotonic-ecto"

    online_plan = fn ->
      %{
        manifestDigest: manifest,
        pendingSteps:
          if(ecto_applied?(@ecto_b), do: [], else: [plan_step("billing-#{@ecto_b}", "expand")]),
        providerPendingIDs: []
      }
    end

    assert :ok =
             Comma.Release.execute_plan_stage(
               "online",
               manifest,
               ["billing-#{@ecto_b}"],
               plan: online_plan
             )

    cutover_plan = fn ->
      %{
        manifestDigest: manifest,
        pendingSteps:
          if(ecto_applied?(@ecto_a),
            do: [],
            else: [plan_step("billing-#{@ecto_a}", "exclusive")]
          ),
        providerPendingIDs: []
      }
    end

    assert :ok =
             Comma.Release.execute_plan_stage(
               "cutover",
               manifest,
               ["billing-#{@ecto_a}"],
               plan: cutover_plan
             )

    assert ecto_applied?(@ecto_a)
    assert ecto_applied?(@ecto_b)
  end

  test "ClickHouse partial apply leaves ledger pending and reports exact repair", %{
    clickhouse_database: clickhouse_database
  } do
    write_clickhouse_partial_migration(:broken)
    write_clickhouse_after_partial_migration()

    manifest = "sha256:clickhouse-partial-release-adapter-e2e"

    plan = fn ->
      %{
        manifestDigest: manifest,
        pendingSteps:
          [
            if(not clickhouse_applied?(clickhouse_database, @analytics_partial),
              do: plan_step("analytics-#{@analytics_partial}", "expand")
            ),
            if(not clickhouse_applied?(clickhouse_database, @analytics_after_partial),
              do: plan_step("analytics-#{@analytics_after_partial}", "expand")
            )
          ]
          |> Enum.reject(&is_nil/1),
        providerPendingIDs: []
      }
    end

    allowed = [
      "analytics-#{@analytics_partial}",
      "analytics-#{@analytics_after_partial}"
    ]

    assert_raise RuntimeError, ~r/analytics migration failed/, fn ->
      Comma.Release.execute_plan_stage("online", manifest, allowed, plan: plan)
    end

    assert clickhouse_table_exists?(clickhouse_database, "partial_a")
    refute clickhouse_table_exists?(clickhouse_database, "partial_b")
    refute clickhouse_table_exists?(clickhouse_database, "after_partial")
    refute clickhouse_applied?(clickhouse_database, @analytics_partial)
    refute clickhouse_applied?(clickhouse_database, @analytics_after_partial)

    repair_manifest = partial_repair_manifest()
    repair_inventory = partial_repair_inventory()

    assert {:ok, {:repair_partial_apply, "rerun_exact_version_after_idempotent_fix"}} =
             Comma.ReleaseManifestV2.diagnose(
               "analytics-#{@analytics_partial}",
               false,
               %{
                 "clickhouse.table.partial_a" => true,
                 "clickhouse.table.partial_b" => false
               },
               repair_manifest,
               repair_inventory
             )

    write_clickhouse_partial_migration(:repaired)

    assert :ok =
             Comma.Release.execute_plan_stage("online", manifest, allowed, plan: plan)

    assert clickhouse_table_exists?(clickhouse_database, "partial_a")
    assert clickhouse_table_exists?(clickhouse_database, "partial_b")
    assert clickhouse_table_exists?(clickhouse_database, "after_partial")
    assert clickhouse_applied?(clickhouse_database, @analytics_partial)
    assert clickhouse_applied?(clickhouse_database, @analytics_after_partial)

    assert {:ok, :complete} =
             Comma.ReleaseManifestV2.diagnose(
               "analytics-#{@analytics_partial}",
               true,
               %{
                 "clickhouse.table.partial_a" => true,
                 "clickhouse.table.partial_b" => true
               },
               repair_manifest,
               repair_inventory
             )
  end

  defp cleanup_ecto do
    Ecto.Adapters.SQL.query!(
      Comma.Repo,
      "CREATE TABLE IF NOT EXISTS schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp(0) without time zone)"
    )

    Ecto.Adapters.SQL.query!(
      Comma.Repo,
      "DELETE FROM schema_migrations WHERE version IN ($1, $2)",
      [@product_state_cutover, @pending_binding_repair]
    )

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "CREATE TABLE IF NOT EXISTS schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp(0) without time zone)"
    )

    Ecto.Adapters.SQL.query!(BillingCore.Repo, "DROP TABLE IF EXISTS comma_release_e2e_a")
    Ecto.Adapters.SQL.query!(BillingCore.Repo, "DROP TABLE IF EXISTS comma_release_e2e_b")

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "DELETE FROM schema_migrations WHERE version IN ($1, $2)",
      [@ecto_a, @ecto_b]
    )
  end

  defp prepare_participant_state_cutover! do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> SalixStore.S3.Fake.reset()
    end

    participant = %{
      "participant_id" => @participant_id,
      "conversation_id" => @participant_conversation_id,
      "actor_type" => "agent",
      "state" => "active"
    }

    old_key =
      SalixStore.Keys.ctl_group_conversation_participant_dir(
        @participant_group_id,
        @participant_conversation_id,
        @participant_id
      ) <> "state.json"

    new_key =
      SalixStore.Keys.ctl_group_conversation_participant_state(
        @participant_group_id,
        @participant_conversation_id,
        @participant_id
      )

    assert {:ok, _} = SalixStore.S3.put(old_key, Jason.encode!(participant))

    on_exit(fn ->
      if Process.whereis(SalixStore.S3.Fake), do: SalixStore.S3.Fake.reset()
      restore_env_for(:salix_store, :s3_backend, previous_backend)
    end)

    %{participant: participant, old_key: old_key, new_key: new_key}
  end

  defp production_release_plan do
    previous = Application.get_env(:salix_analytics, :clickhouse)

    clickhouse =
      Application.fetch_env!(:comma, :release_clickhouse_opts)
      |> Keyword.drop([:migration_dir])

    Application.put_env(:salix_analytics, :clickhouse, clickhouse)

    try do
      Comma.ReleasePlan.plan()
    after
      restore_env_for(:salix_analytics, :clickhouse, previous)
    end
  end

  defp ecto_applied?(version) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT version FROM schema_migrations WHERE version = $1",
        [version]
      )

    rows != []
  end

  defp clickhouse_applied?(database, version) do
    response =
      Req.post!(System.get_env("RELEASE_E2E_CLICKHOUSE_URL", "http://127.0.0.1:8123"),
        body: "",
        params: [
          query:
            "SELECT count() FROM #{database}.analytics_schema_migrations WHERE version = #{version}"
        ]
      )

    case Integer.parse(String.trim(to_string(response.body))) do
      {count, _} -> count == 1
      :error -> false
    end
  end

  defp clickhouse_table_exists?(database, table) do
    response =
      Req.post!(System.get_env("RELEASE_E2E_CLICKHOUSE_URL", "http://127.0.0.1:8123"),
        body: "",
        params: [
          query:
            "SELECT count() FROM system.tables WHERE database = '#{database}' AND name = '#{table}'"
        ]
      )

    String.trim(to_string(response.body)) == "1"
  end

  defp drop_clickhouse_database(database) do
    Req.post!(System.get_env("RELEASE_E2E_CLICKHOUSE_URL", "http://127.0.0.1:8123"),
      body: "",
      params: [query: "DROP DATABASE IF EXISTS #{database} SYNC"]
    )
  end

  defp clickhouse_database_exists?(database) do
    response =
      Req.post!(System.get_env("RELEASE_E2E_CLICKHOUSE_URL", "http://127.0.0.1:8123"),
        body: "",
        params: [query: "SELECT count() FROM system.databases WHERE name = '#{database}'"]
      )

    String.trim(to_string(response.body)) == "1"
  end

  defp write_ecto_migrations(dir) do
    File.write!(Path.join(dir, "#{@ecto_a}_comma_release_e2e_a.exs"), """
    defmodule Comma.ReleaseE2E.MigrationA do
      use Ecto.Migration
      def change do
        create table(:comma_release_e2e_a) do
          add :value, :text
        end
      end
    end
    """)

    File.write!(Path.join(dir, "#{@ecto_b}_comma_release_e2e_b.exs"), """
    defmodule Comma.ReleaseE2E.MigrationB do
      use Ecto.Migration
      def change do
        create table(:comma_release_e2e_b) do
          add :value, :text
        end
      end
    end
    """)
  end

  defp write_clickhouse_migrations(dir) do
    Process.put(:comma_release_adapter_e2e_migration_dir, dir)

    File.write!(
      Path.join(dir, "#{@analytics_a}_comma_release_e2e_a.sql"),
      "CREATE TABLE IF NOT EXISTS {{database}}.a (value String) ENGINE = MergeTree ORDER BY value;"
    )

    File.write!(
      Path.join(dir, "#{@analytics_b}_comma_release_e2e_b.sql"),
      "CREATE TABLE IF NOT EXISTS {{database}}.b (value String) ENGINE = MergeTree ORDER BY value;"
    )
  end

  defp write_clickhouse_partial_migration(mode) do
    dir = Process.get(:comma_release_adapter_e2e_migration_dir)

    sql =
      case mode do
        :broken ->
          """
          CREATE TABLE IF NOT EXISTS {{database}}.partial_a (value String) ENGINE = MergeTree ORDER BY value;
          THIS IS NOT SQL;
          """

        :repaired ->
          """
          CREATE TABLE IF NOT EXISTS {{database}}.partial_a (value String) ENGINE = MergeTree ORDER BY value;
          CREATE TABLE IF NOT EXISTS {{database}}.partial_b (value String) ENGINE = MergeTree ORDER BY value;
          """
      end

    File.write!(Path.join(dir, "#{@analytics_partial}_comma_release_e2e_partial.sql"), sql)
  end

  defp write_clickhouse_after_partial_migration do
    dir = Process.get(:comma_release_adapter_e2e_migration_dir)

    File.write!(
      Path.join(dir, "#{@analytics_after_partial}_comma_release_e2e_after_partial.sql"),
      "CREATE TABLE IF NOT EXISTS {{database}}.after_partial (value String) ENGINE = MergeTree ORDER BY value;"
    )
  end

  defp partial_repair_manifest do
    %{
      "schemaVersion" => 2,
      "orderingConstraints" => [],
      "steps" => [
        %{
          "id" => "analytics-#{@analytics_partial}",
          "owner" => "analytics",
          "store" => "clickhouse",
          "version" => @analytics_partial,
          "source" => "test/clickhouse-partial.sql",
          "checksum" => "sha256:test-partial",
          "phase" => "expand",
          "compatibility" => %{
            "oldRuntimeRead" => true,
            "oldRuntimeWrite" => true,
            "newRuntimeRead" => true,
            "newRuntimeWrite" => true
          },
          "execution" => %{
            "transactional" => false,
            "idempotent" => true,
            "timeoutSeconds" => 120,
            "lockBudgetSeconds" => 30
          },
          "safety" => %{
            "destructive" => false,
            "backupRequired" => false,
            "rollbackStrategy" => "none"
          },
          "postconditions" => [
            "clickhouse.table.partial_a",
            "clickhouse.table.partial_b"
          ],
          "repair" => "rerun_exact_version_after_idempotent_fix"
        }
      ]
    }
  end

  defp partial_repair_inventory do
    [
      %{
        "id" => "analytics-#{@analytics_partial}",
        "owner" => "analytics",
        "store" => "clickhouse",
        "version" => @analytics_partial,
        "source" => "test/clickhouse-partial.sql",
        "checksum" => "sha256:test-partial",
        "transactional" => false
      }
    ]
  end

  defp plan_step(id, phase) do
    %{
      "id" => id,
      "owner" => "test",
      "store" => "postgres",
      "version" => 1,
      "source" => "test",
      "checksum" => "sha256:test",
      "phase" => phase,
      "compatibility" => %{},
      "execution" => %{},
      "safety" => %{
        "destructive" => false,
        "backupRequired" => false,
        "rollbackStrategy" => "none"
      },
      "postconditions" => ["test"],
      "repair" => "retry"
    }
  end

  defp seed_final_import_ledger! do
    identity = "comma-product-state-final-import-v1"
    digest = String.duplicate("0", 64)
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
      "source_digest" => digest,
      "target_digest" => digest,
      "checkpoint_digest" => digest,
      "checkpoint_target_digest" => digest,
      "secret_posture" => "redacted"
    }

    envelope = %{
      "release_identity" => identity,
      "status" => "complete",
      "evidence" => evidence,
      "completed_at" => DateTime.to_iso8601(completed_at)
    }

    evidence_digest =
      envelope
      |> canonical()
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Comma.Repo.insert!(%Comma.Data.ImportRun{
      release_identity: identity,
      status: "complete",
      evidence: evidence,
      evidence_digest: evidence_digest,
      completed_at: completed_at
    })
  end

  defp canonical(%DateTime{} = value),
    do: {:utc_microsecond, DateTime.to_unix(value, :microsecond)}

  defp canonical(value) when is_map(value) do
    value |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end) |> Enum.sort()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp restore_env(key, nil), do: Application.delete_env(:comma, key)
  defp restore_env(key, value), do: Application.put_env(:comma, key, value)

  defp restore_env_for(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env_for(app, key, value), do: Application.put_env(app, key, value)
end
