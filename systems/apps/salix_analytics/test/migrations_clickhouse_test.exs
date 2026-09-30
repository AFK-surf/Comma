defmodule SalixAnalytics.MigrationsClickHouseTest do
  use ExUnit.Case, async: false

  alias SalixAnalytics.Migrations
  alias SalixAnalytics.{AgentRunEvent, LLMCallEvent, ToolCallEvent}
  alias SalixAnalytics.Sink.ClickHouseTyped
  alias SalixStore.Ids

  @moduletag :clickhouse

  @clickhouse_url "http://127.0.0.1:8123/"

  setup do
    Application.ensure_all_started(:req)

    database = "salix_migration_test_#{System.unique_integer([:positive])}"
    prev = Application.get_env(:salix_analytics, :clickhouse)

    clickhouse_query!("DROP DATABASE IF EXISTS #{database}")

    Application.put_env(:salix_analytics, :clickhouse,
      base_url: @clickhouse_url,
      table: "#{database}.events"
    )

    on_exit(fn ->
      Application.put_env(:salix_analytics, :clickhouse, prev)
      clickhouse_query!("DROP DATABASE IF EXISTS #{database}")
    end)

    {:ok, database: database}
  end

  test "runs all migrations against real ClickHouse syntax", %{database: database} do
    expected_versions = Enum.map(Migrations.migrations(), & &1.version)

    assert {:ok, ^expected_versions} = Migrations.migrate()
    assert {:ok, []} = Migrations.migrate()

    assert entitlement_columns(database) == [
             {"billing_charge_events", "entitlement_mode"},
             {"fee_control_checks", "entitlement_mode"}
           ]
  end

  test "typed sink inserts telemetry rows with DateTime64 fields into real ClickHouse", %{
    database: database
  } do
    assert {:ok, _versions} = Migrations.migrate()

    started_at = ~U[2026-07-08 00:00:00.123Z]

    rows = [
      LLMCallEvent.build(%{
        source: "clickhouse_test",
        source_key: "llm:datetime64",
        entrypoint: "agent_round",
        surface: "comma",
        billing_account_id: "ba_1",
        product_owner_type: "workspace",
        product_owner_id: "ws_1",
        tenant_id: "tenant_1",
        group_id: "group_1",
        actor_type: "user",
        provider: "openai",
        model: "gpt-test",
        started_at: started_at,
        duration_ms: 10,
        app_revision: "test-sha",
        usage: %{
          "prompt_tokens" => 1,
          "usage_reported" => true,
          "cache_read_tokens_reported" => false,
          "reasoning_tokens" => 30
        }
      }),
      ToolCallEvent.build(%{
        source: "clickhouse_test",
        source_key: "tool:datetime64",
        entrypoint: "tool_call",
        surface: "comma",
        tenant_id: "tenant_1",
        group_id: "group_1",
        actor_type: "tool",
        tool_name: "help",
        tool_source: "core",
        status: "completed",
        duration_ms: 10,
        started_at: started_at,
        call_index: 0,
        async: false,
        app_revision: "test-sha"
      }),
      AgentRunEvent.build(%{
        source: "clickhouse_test",
        source_key: "run:datetime64",
        entrypoint: "agent_run",
        surface: "comma",
        tenant_id: "tenant_1",
        group_id: "group_1",
        actor_type: "user",
        status: "completed",
        duration_ms: 10,
        started_at: started_at,
        app_revision: "test-sha"
      })
    ]

    assert {:ok, 3} = ClickHouseTyped.insert(rows)

    assert telemetry_columns(database) == [
             {"agent_run_events", "app_revision", "Nullable(String)"},
             {"agent_run_events", "started_at", "DateTime64(3)"},
             {"llm_call_events", "app_revision", "Nullable(String)"},
             {"llm_call_events", "started_at", "Nullable(DateTime64(3))"},
             {"tool_call_events", "app_revision", "Nullable(String)"},
             {"tool_call_events", "call_index", "Nullable(UInt64)"},
             {"tool_call_events", "guidance_reason", "Nullable(String)"},
             {"tool_call_events", "started_at", "DateTime64(3)"}
           ]

    assert String.trim(
             clickhouse_query!(
               "SELECT usage_reported, cache_read_tokens_reported, reasoning_tokens FROM #{database}.llm_call_events_v2 FORMAT TabSeparated"
             )
           ) == "true\tfalse\t30"

    # The typed sink writes the v2 generation.
    assert inserted_count(database, "llm_call_events_v2") == 1
    assert inserted_count(database, "tool_call_events_v2") == 1
    assert inserted_count(database, "agent_run_events_v2") == 1
  end

  test "agent_phase_events accepts phase rows and carries the pruned layout", %{
    database: database
  } do
    assert {:ok, _versions} = Migrations.migrate()

    row =
      SalixAnalytics.AgentPhaseEvent.build(%{
        source: "clickhouse_test",
        source_key: "round-1:prepare",
        entrypoint: "agent_phase",
        surface: "comma",
        tenant_id: "t1",
        group_id: "g1",
        actor_type: "user",
        phase: "prepare",
        duration_ms: 87,
        started_at: ~U[2026-09-07 00:00:00.456Z],
        salix_agent_id: "ag-1",
        session_id: "ses-1",
        round_id: "round-1",
        activation_key: "m1",
        app_revision: "test-sha"
      })

    assert {:ok, 1} = ClickHouseTyped.insert([row])
    assert inserted_count(database, "agent_phase_events") == 1

    assert table_layout(database, "agent_phase_events") ==
             {"toYYYYMM(event_date)", "event_date, source, source_key"}

    assert column_definition(database, "agent_phase_events", "observed_at") ==
             {"DateTime64(3)", "MATERIALIZED"}

    assert "SELECT phase, duration_ms, activation_key, toString(started_at) FROM #{database}.agent_phase_events FORMAT TSV"
           |> clickhouse_query!()
           |> String.trim() == "prepare\t87\tm1\t2026-09-07 00:00:00.456"
  end

  test "llm_attempt_events accepts attempt rows and carries the pruned layout", %{
    database: database
  } do
    assert {:ok, _versions} = Migrations.migrate()

    row =
      SalixAnalytics.LlmAttemptEvent.build(%{
        source: "clickhouse_test",
        source_key: "req-1:1",
        entrypoint: "llm_attempt",
        surface: "comma",
        tenant_id: "t1",
        group_id: "g1",
        actor_type: "user",
        provider: "anthropic",
        model: "claude-opus-5",
        attempt: 1,
        max_attempts: 6,
        outcome: "retry",
        category: "retryable_provider_error",
        reason: "rate limited",
        http_status: 429,
        duration_ms: 9_800,
        delay_ms: 5_000,
        started_at: ~U[2026-09-14 08:25:24.862Z],
        salix_agent_id: "ag-1",
        session_id: "ses-1",
        round_id: "round-1",
        app_revision: "test-sha"
      })

    # The attempt the actor killed at the deadline (20260929000001): its
    # stream progress lands in the added columns, and a row without it (the
    # retry above) leaves them NULL rather than zero.
    killed =
      SalixAnalytics.LlmAttemptEvent.build(%{
        source: "clickhouse_test",
        source_key: "req-1:2",
        entrypoint: "llm_attempt",
        surface: "cue",
        tenant_id: "t1",
        group_id: "g1",
        actor_type: "user",
        provider: "deepseek",
        model: "deepseek-flash",
        attempt: 2,
        max_attempts: 6,
        outcome: "killed",
        category: "exit",
        reason: "dependency_timeout",
        http_status: 200,
        duration_ms: 600_012,
        delay_ms: 0,
        started_at: ~U[2026-09-29 12:45:01.500Z],
        first_body_ms: 1_450,
        last_body_ms: 599_980,
        received_bytes: 48_213,
        received_chunks: 3_101,
        first_content_ms: nil,
        last_content_ms: nil,
        content_deltas: 0,
        salix_agent_id: "ag-1",
        session_id: "ses-1",
        round_id: "round-1",
        app_revision: "test-sha"
      })

    assert {:ok, 2} = ClickHouseTyped.insert([row, killed])
    assert inserted_count(database, "llm_attempt_events") == 2

    assert "SELECT outcome, first_body_ms, last_body_ms, received_bytes, received_chunks, first_content_ms, content_deltas FROM #{database}.llm_attempt_events WHERE source_key = 'req-1:2' FORMAT TSV"
           |> clickhouse_query!()
           |> String.trim() == "killed\t1450\t599980\t48213\t3101\t\\N\t0"

    assert "SELECT received_bytes, content_deltas FROM #{database}.llm_attempt_events WHERE source_key = 'req-1:1' FORMAT TSV"
           |> clickhouse_query!()
           |> String.trim() == "\\N\t\\N"

    assert table_layout(database, "llm_attempt_events") ==
             {"toYYYYMM(event_date)", "event_date, source, source_key"}

    assert column_definition(database, "llm_attempt_events", "observed_at") ==
             {"DateTime64(3)", "MATERIALIZED"}

    assert "SELECT attempt, outcome, category, http_status, delay_ms, toString(started_at) FROM #{database}.llm_attempt_events WHERE source_key = 'req-1:1' FORMAT TSV"
           |> clickhouse_query!()
           |> String.trim() ==
             "1\tretry\tretryable_provider_error\t429\t5000\t2026-09-14 08:25:24.862"
  end

  test "v2 telemetry tables carry the pruned layout and mirror v1 column order", %{
    database: database
  } do
    assert {:ok, _versions} = Migrations.migrate()

    for table <- ~w(llm_call_events_v2 tool_call_events_v2 agent_run_events_v2) do
      assert table_engine(database, table) in ~w(ReplacingMergeTree SharedReplacingMergeTree),
             "#{table} must use the local or ClickHouse Cloud replacement engine"

      assert table_layout(database, table) ==
               {"toYYYYMM(event_date)", "event_date, source, source_key"},
             "#{table} must be month-partitioned with an event_date-leading sorting key"

      assert column_definition(database, table, "observed_at") ==
               {"DateTime64(3)", "MATERIALIZED"},
             "#{table}.observed_at must be a MATERIALIZED DateTime64(3)"
    end

    # Seam readers UNION v1 and v2 with SELECT *, which ClickHouse matches BY
    # POSITION — the physical column order of the two generations must stay
    # identical (v2's MATERIALIZED observed_at is excluded from SELECT *).
    for {v1, v2} <- [
          {"llm_call_events", "llm_call_events_v2"},
          {"tool_call_events", "tool_call_events_v2"},
          {"agent_run_events", "agent_run_events_v2"}
        ] do
      assert ordered_columns(database, v1) ==
               ordered_columns(database, v2) -- ["observed_at"],
             "#{v2} column order drifted from #{v1}; seam SELECT * would misalign"
    end

    # Millisecond precision survives materialization (P2 from the withdrawn
    # rebuild: parseDateTimeBestEffortOrZero silently truncated to seconds).
    row =
      LLMCallEvent.build(%{
        source: "clickhouse_test",
        source_key: "llm:millis",
        metered_at: "2026-07-10T00:00:00.987Z",
        entrypoint: "agent_round",
        surface: "comma",
        billing_account_id: "ba_1",
        product_owner_type: "workspace",
        tenant_id: "t1",
        group_id: "g1",
        actor_type: "agent"
      })

    assert {:ok, 1} = ClickHouseTyped.insert([row])

    millis =
      """
      SELECT toUnixTimestamp64Milli(observed_at) % 1000
      FROM #{database}.llm_call_events_v2
      WHERE source_key = 'llm:millis'
      FORMAT TSV
      """
      |> clickhouse_query!()
      |> String.trim()

    assert millis == "987"
  end

  test "a precreated table with the wrong layout fails migration and readiness", %{
    database: database
  } do
    # CREATE TABLE IF NOT EXISTS is a no-op against an existing table, and a
    # presence-only postcondition would ledger that as success — the first
    # read of observed_at then fails at runtime. Both gates must reject it.
    clickhouse_query!("CREATE DATABASE IF NOT EXISTS #{database}")

    clickhouse_query!("""
    CREATE TABLE #{database}.llm_call_events_v2 (source String, source_key String)
    ENGINE = MergeTree ORDER BY source
    """)

    assert {:error, {:migration_failed, name, _reason}} = Migrations.migrate()
    assert name =~ "llm_call_events_v2"

    # Readiness must not green-light the same table either. Create the rest of
    # the schema so the only defect left is this table's layout.
    clickhouse_query!("DROP TABLE #{database}.llm_call_events_v2")
    assert {:ok, _versions} = Migrations.migrate()
    assert :ok = ClickHouseTyped.readiness()

    clickhouse_query!("DROP TABLE #{database}.llm_call_events_v2")

    clickhouse_query!("""
    CREATE TABLE #{database}.llm_call_events_v2 (source String, source_key String)
    ENGINE = MergeTree ORDER BY source
    """)

    assert {:error, {:typed_table_layout_mismatch, table, _what}} = ClickHouseTyped.readiness()
    assert table =~ "llm_call_events_v2"
  end

  test "a near-miss table with an exact-name wrong-type column is rejected", %{
    database: database
  } do
    # `tenant_id UInt64` instead of `String`: same names and order, so a
    # name-only check passes — then String writes/binds fail at runtime. The
    # full name+type contract must catch it.
    assert {:ok, _} = Migrations.migrate()
    ddl = show_create(database, "llm_call_events_v2")
    near_miss = String.replace(ddl, "`tenant_id` String", "`tenant_id` UInt64")
    refute near_miss == ddl, "SHOW CREATE did not expose the tenant_id column type"

    clickhouse_query!("DROP TABLE #{database}.llm_call_events_v2")
    clickhouse_query!(near_miss)

    assert {:error, {:typed_table_layout_mismatch, table, what}} = ClickHouseTyped.readiness()
    assert table =~ "llm_call_events_v2"
    assert what =~ "column names and types"
  end

  defp show_create(database, table) do
    "SHOW CREATE TABLE #{database}.#{table} FORMAT TabSeparatedRaw"
    |> clickhouse_query!()
    |> String.trim_trailing()
  end

  defp table_engine(database, table) do
    """
    SELECT engine
    FROM system.tables
    WHERE database = '#{database}' AND name = '#{table}'
    FORMAT TSV
    """
    |> clickhouse_query!()
    |> String.trim()
  end

  test "a near-miss table with a drifted materialized expression is rejected", %{
    database: database
  } do
    # Right engine, keys, column names+types — only the observed_at MATERIALIZED
    # expression differs. That expression is load-bearing (window predicates run
    # on observed_at), so a table that parses metered_at differently must not
    # pass. Built from the real DDL with only the expression swapped.
    assert {:ok, _} = Migrations.migrate()

    ddl = show_create(database, "agent_run_events_v2")

    near_miss =
      String.replace(
        ddl,
        "parseDateTime64BestEffortOrZero(metered_at, 3, 'UTC')",
        "toDateTime64(0, 3)"
      )

    refute near_miss == ddl, "SHOW CREATE did not expose the observed_at expression"

    # A table that DRIFTED after migration (already ledgered, so migrate/2 is a
    # no-op) is caught by readiness, which re-checks the layout every run —
    # migration-time rejection of a precreated wrong table is covered separately.
    clickhouse_query!("DROP TABLE #{database}.agent_run_events_v2")
    clickhouse_query!(near_miss)

    assert {:error, {:typed_table_layout_mismatch, table, what}} = ClickHouseTyped.readiness()
    assert table =~ "agent_run_events_v2"
    assert what =~ "observed_at"
  end

  test "rewrites the same legacy session independently for each owning agent", %{
    database: database
  } do
    assert {:ok, _versions} = Migrations.migrate()

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    agent_a = Ids.new_agent_id(group_id)
    agent_b = Ids.new_agent_id(group_id)
    legacy_session_id = "im-shared-analytics-session"
    target_a = Ids.new_session_id()
    target_b = Ids.new_session_id()

    rows =
      Enum.map([{agent_a, "analytics:a"}, {agent_b, "analytics:b"}], fn {agent_id, source_key} ->
        LLMCallEvent.build(%{
          source: "session_identity_migration_e2e",
          source_key: source_key,
          entrypoint: "agent_round",
          surface: "comma",
          billing_account_id: "ba_session_migration",
          product_owner_type: "group",
          product_owner_id: group_id,
          tenant_id: tenant_id,
          group_id: group_id,
          actor_type: "agent",
          provider: "openai",
          model: "gpt-test",
          status: "completed",
          salix_agent_id: agent_id,
          session_id: legacy_session_id,
          usage: %{"prompt_tokens" => 1}
        })
      end)

    assert {:ok, 2} = ClickHouseTyped.insert(rows)

    assert {:ok, refs} = Migrations.inventory_session_refs()
    assert {agent_a, legacy_session_id} in refs
    assert {agent_b, legacy_session_id} in refs

    assert {:ok, _tables} =
             Migrations.rewrite_session_dimensions(%{
               agent_a => %{legacy_session_id => target_a},
               agent_b => %{legacy_session_id => target_b}
             })

    assert analytics_sessions(database) == [
             {"analytics:a", agent_a, target_a},
             {"analytics:b", agent_b, target_b}
           ]
  end

  defp entitlement_columns(database) do
    sql = """
    SELECT table, name
    FROM system.columns
    WHERE database = '#{database}'
      AND table IN ('fee_control_checks', 'billing_charge_events')
      AND name = 'entitlement_mode'
    ORDER BY table, name
    FORMAT TSV
    """

    sql
    |> clickhouse_query!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [table, name] = String.split(line, "\t", parts: 2)
      {table, name}
    end)
  end

  defp telemetry_columns(database) do
    sql = """
    SELECT table, name, type
    FROM system.columns
    WHERE database = '#{database}'
      AND (
        (table = 'llm_call_events' AND name IN ('started_at', 'app_revision'))
        OR (table = 'tool_call_events' AND name IN ('started_at', 'call_index', 'guidance_reason', 'app_revision'))
        OR (table = 'agent_run_events' AND name IN ('started_at', 'app_revision'))
      )
    ORDER BY table, name
    FORMAT TSV
    """

    sql
    |> clickhouse_query!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [table, name, type] = String.split(line, "\t", parts: 3)
      {table, name, type}
    end)
  end

  defp inserted_count(database, table) do
    "SELECT count() FROM #{database}.#{table} FINAL FORMAT TSV"
    |> clickhouse_query!()
    |> String.trim()
    |> String.to_integer()
  end

  defp table_layout(database, table) do
    """
    SELECT partition_key, sorting_key
    FROM system.tables
    WHERE database = '#{database}' AND name = '#{table}'
    FORMAT TSV
    """
    |> clickhouse_query!()
    |> String.trim()
    |> String.split("\t", parts: 2)
    |> List.to_tuple()
  end

  defp column_definition(database, table, column) do
    """
    SELECT type, default_kind
    FROM system.columns
    WHERE database = '#{database}' AND table = '#{table}' AND name = '#{column}'
    FORMAT TSV
    """
    |> clickhouse_query!()
    |> String.trim()
    |> String.split("\t", parts: 2)
    |> List.to_tuple()
  end

  defp ordered_columns(database, table) do
    """
    SELECT name
    FROM system.columns
    WHERE database = '#{database}' AND table = '#{table}'
    ORDER BY position
    FORMAT TSV
    """
    |> clickhouse_query!()
    |> String.split("\n", trim: true)
  end

  defp analytics_sessions(database) do
    """
    SELECT source_key, assumeNotNull(salix_agent_id), assumeNotNull(session_id)
    FROM #{database}.llm_call_events_v2 FINAL
    WHERE source = 'session_identity_migration_e2e'
    ORDER BY source_key
    FORMAT TSV
    """
    |> clickhouse_query!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [source_key, agent_id, session_id] = String.split(line, "\t", parts: 3)
      {source_key, agent_id, session_id}
    end)
  end

  defp clickhouse_query!(sql) do
    case Req.post(@clickhouse_url, params: [query: sql], body: "", receive_timeout: 30_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        to_string(body)

      {:ok, %{status: status, body: body}} ->
        flunk("ClickHouse query failed with #{status}: #{body}\nSQL:\n#{sql}")

      {:error, reason} ->
        flunk("ClickHouse query failed: #{inspect(reason)}\nSQL:\n#{sql}")
    end
  end
end
