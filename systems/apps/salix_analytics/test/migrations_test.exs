defmodule SalixAnalytics.MigrationsTest do
  use ExUnit.Case, async: false

  alias SalixAnalytics.Migrations

  setup do
    start_supervised!(SalixAnalytics.MockClickHouse)

    bandit =
      start_supervised!(
        {Bandit,
         plug: SalixAnalytics.MockClickHouse, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: {__MODULE__, :bandit}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    prev = Application.get_env(:salix_analytics, :clickhouse)

    Application.put_env(:salix_analytics, :clickhouse,
      base_url: "http://127.0.0.1:#{port}/",
      table: "test.analytics_events"
    )

    on_exit(fn -> Application.put_env(:salix_analytics, :clickhouse, prev) end)
    :ok
  end

  test "runs pending ClickHouse migrations once and records their versions" do
    expected_versions = Enum.map(Migrations.migrations(), & &1.version)

    assert {:ok, ^expected_versions} = Migrations.migrate()
    first_query_count = SalixAnalytics.MockClickHouse.queries() |> length()

    assert {:ok, []} = Migrations.migrate()

    second_queries =
      SalixAnalytics.MockClickHouse.queries()
      |> Enum.take(length(SalixAnalytics.MockClickHouse.queries()) - first_query_count)

    assert SalixAnalytics.MockClickHouse.migration_versions() |> Enum.sort() == expected_versions

    queries = SalixAnalytics.MockClickHouse.queries() |> Enum.reverse()
    assert Enum.any?(queries, &String.contains?(&1, "CREATE DATABASE IF NOT EXISTS test"))

    assert Enum.any?(
             queries,
             &String.contains?(&1, "CREATE TABLE IF NOT EXISTS test.analytics_events")
           )

    assert Enum.any?(
             queries,
             &String.contains?(&1, "CREATE TABLE IF NOT EXISTS test.llm_call_events")
           )

    assert Enum.any?(
             queries,
             &String.contains?(&1, "CREATE TABLE IF NOT EXISTS test.tool_call_events")
           )

    assert Enum.any?(
             queries,
             &String.contains?(&1, "CREATE TABLE IF NOT EXISTS test.agent_run_events")
           )

    assert Enum.any?(
             queries,
             &String.contains?(
               &1,
               "ALTER TABLE test.llm_call_events\n  ADD COLUMN IF NOT EXISTS app_revision"
             )
           )

    assert Enum.any?(
             queries,
             &String.contains?(
               &1,
               "ALTER TABLE test.llm_call_events\n  ADD COLUMN IF NOT EXISTS first_token_ms"
             )
           )

    assert Enum.any?(
             queries,
             &String.contains?(
               &1,
               "ALTER TABLE test.llm_call_events\n  ADD COLUMN IF NOT EXISTS attempts"
             )
           )

    assert Enum.any?(
             queries,
             &String.contains?(
               &1,
               "ALTER TABLE test.llm_call_events\n  ADD COLUMN IF NOT EXISTS response_kind"
             )
           )

    assert Enum.any?(
             queries,
             &(String.contains?(&1, "guidance_reason Nullable(String)") and
                 String.contains?(&1, "app_revision Nullable(String)") and
                 String.contains?(&1, "tool_call_events"))
           )

    assert Enum.any?(
             queries,
             &(String.contains?(&1, "task_origin Nullable(String)") and
                 String.contains?(&1, "platform Nullable(String)") and
                 String.contains?(&1, "source_schedule_id Nullable(String)") and
                 String.contains?(&1, "agent_run_events"))
           )

    assert Enum.any?(
             queries,
             &String.contains?(&1, "CREATE TABLE IF NOT EXISTS test.billing_source_events")
           )

    assert Enum.any?(
             queries,
             &String.contains?(
               &1,
               "ALTER TABLE test.fee_control_checks\n  ADD COLUMN IF NOT EXISTS action"
             )
           )

    assert Enum.any?(
             queries,
             &String.contains?(
               &1,
               "ALTER TABLE test.fee_control_checks\n  ADD COLUMN IF NOT EXISTS entitlement_mode"
             )
           )

    assert Enum.any?(
             queries,
             &String.contains?(
               &1,
               "ALTER TABLE test.billing_charge_events\n  ADD COLUMN IF NOT EXISTS entitlement_mode"
             )
           )

    refute Enum.any?(second_queries, &String.contains?(&1, "ALTER TABLE"))

    assert Enum.any?(queries, &String.contains?(&1, "analytics_schema_migrations"))

    v2_layout_queries =
      Enum.filter(queries, fn query ->
        String.contains?(query, "_events_v2") and String.contains?(query, "system.tables")
      end)

    assert length(v2_layout_queries) == 3

    for query <- v2_layout_queries do
      assert query =~ "engine IN ('ReplacingMergeTree', 'SharedReplacingMergeTree')"
      refute query =~ "engine = 'ReplacingMergeTree'"
    end
  end

  test "migrates and becomes ready when ClickHouse Cloud reports SharedReplacingMergeTree" do
    SalixAnalytics.MockClickHouse.report_engine_as("SharedReplacingMergeTree")

    assert {:ok, versions} = Migrations.migrate()
    assert versions != []
    assert :ok = SalixAnalytics.Sink.ClickHouseTyped.readiness()

    engine_queries =
      SalixAnalytics.MockClickHouse.queries()
      |> Enum.filter(&(String.contains?(&1, "system.tables") and String.contains?(&1, "engine")))

    assert length(engine_queries) >= 6

    assert Enum.all?(
             engine_queries,
             &String.contains?(
               &1,
               "engine IN ('ReplacingMergeTree', 'SharedReplacingMergeTree')"
             )
           )
  end

  test "skips cleanly when ClickHouse is not configured" do
    Application.delete_env(:salix_analytics, :clickhouse)

    assert {:ok, []} = Migrations.migrate()
  end

  @tag :tmp_dir
  test "refuses to run when two migration files share a version", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "20260101000001_first.sql"), "SELECT 1;\n")
    File.write!(Path.join(tmp_dir, "20260101000001_second.sql"), "SELECT 2;\n")
    File.write!(Path.join(tmp_dir, "20260101000002_ok.sql"), "SELECT 3;\n")

    assert {:error,
            {:duplicate_migration_versions,
             [{20_260_101_000_001, ["20260101000001_first.sql", "20260101000001_second.sql"]}]}} =
             Migrations.migrate(migration_dir: tmp_dir)

    refute Enum.any?(SalixAnalytics.MockClickHouse.queries(), &String.contains?(&1, "SELECT 1"))
  end

  test "bundled migrations have unique versions" do
    versions = Enum.map(Migrations.migrations(), & &1.version)

    assert versions == Enum.uniq(versions)
  end

  test "reads applied checksums deterministically across duplicate ledger rows" do
    assert {:ok, _} = Migrations.migrate()

    applied_read =
      SalixAnalytics.MockClickHouse.queries()
      |> Enum.find(&String.starts_with?(&1, "SELECT version"))

    assert applied_read =~ "argMax(checksum, applied_at)"
    assert applied_read =~ "GROUP BY version"
  end
end
