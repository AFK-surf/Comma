defmodule SalixAnalytics.SlackMirrorClickHouseTest do
  @moduledoc """
  The layout probe against a real server, because the failure it exists to stop
  is invisible to every check that does not run one.

  A table created with `ENGINE = ReplacingMergeTree` — no version argument —
  reports the same `system.tables.engine` as the correct table, has the same
  partition and sorting keys, and has a `version UInt64` column. Nothing short
  of `engine_full` tells them apart. But without the argument the engine
  replaces by insertion order, so a tombstone loses to a live row that happened
  to arrive later, and a deleted message comes back.
  """
  use ExUnit.Case, async: false

  @moduletag :clickhouse

  alias SalixAnalytics.SlackMirror
  alias SalixAnalytics.SlackMirror.Sink

  @clickhouse_url System.get_env("SALIX_TEST_CLICKHOUSE_URL", "http://127.0.0.1:8123/")

  setup do
    database = "slack_mirror_test_#{System.unique_integer([:positive])}"
    previous = Application.get_env(:salix_analytics, :clickhouse)

    query!("DROP DATABASE IF EXISTS #{database}")
    query!("CREATE DATABASE #{database}")

    Application.put_env(:salix_analytics, :clickhouse,
      base_url: @clickhouse_url,
      table: "#{database}.events",
      database: database
    )

    on_exit(fn ->
      query!("DROP DATABASE IF EXISTS #{database}")
      if previous, do: Application.put_env(:salix_analytics, :clickhouse, previous)
    end)

    {:ok, database: database}
  end

  test "the migrated table passes readiness and writes round-trip", %{database: database} do
    create_migrated_table!(database)

    assert Sink.readiness() == :ok
    assert Sink.write([row(version: 4, deleted: false, text: "original")]) == :ok

    assert survivor(database) == {"original", false}
  end

  describe "the synchronous write path" do
    test "reports durability and refuses a mismatched table", %{database: database} do
      # The outbox drainer deletes its rows and the backfill lowers its
      # watermark on the answer they get here, so `:ok` has to mean the rows
      # are in the table.
      create_migrated_table!(database)

      assert SlackMirror.record_batch([
               row(version: 4, deleted: false, text: "backfilled", source: "backfill")
             ]) == :ok

      assert survivor(database) == {"backfilled", false}

      query!("DROP TABLE #{database}.slack_messages")

      query!("""
      CREATE TABLE #{database}.slack_messages (
        event_date Date, tenant_id String, workspace_id String, channel_id String,
        message_ts_us UInt64, message_ts String, thread_ts String, version UInt64,
        deleted Bool, actor_kind LowCardinality(String), actor_id String,
        subtype LowCardinality(String), text String, files String, file_count UInt16,
        reply_count UInt32, edited_ts String, ingest_source LowCardinality(String),
        ingest_at DateTime64(3) DEFAULT now64(3)
      ) ENGINE = ReplacingMergeTree
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us)
      """)

      assert {:error, {:slack_mirror_table_layout_mismatch, _table, _what}} =
               SlackMirror.record_batch([
                 row(version: 4, deleted: false, text: "unclaimable", source: "backfill")
               ])
    end

    # `ingest_source` is the only column the two writers disagree on, and it
    # deliberately sits outside the sorting key and outside `version`. If it
    # were part of either, the same message observed twice would stop being
    # one row.
    test "a backfilled row and its webhook redelivery collapse into one", %{database: database} do
      create_migrated_table!(database)

      assert SlackMirror.record_batch([
               row(version: 8, deleted: false, text: "same message", source: "backfill")
             ]) == :ok

      assert SlackMirror.record_batch([
               row(version: 8, deleted: false, text: "same message", source: "webhook")
             ]) == :ok

      query!("OPTIMIZE TABLE #{database}.slack_messages FINAL")

      assert query!("SELECT count() FROM #{database}.slack_messages") |> String.trim() == "1"
      assert survivor(database) == {"same message", false}
    end

    # The tombstone the live path may have dropped is not recoverable, but a
    # backfill that re-reads a range must never undo one that landed.
    test "a backfilled live row cannot resurrect a tombstoned message", %{database: database} do
      create_migrated_table!(database)

      assert SlackMirror.record_batch([
               row(version: 21, deleted: true, text: "", source: "webhook")
             ]) == :ok

      assert SlackMirror.record_batch([
               row(version: 20, deleted: false, text: "deleted text", source: "backfill")
             ]) == :ok

      query!("OPTIMIZE TABLE #{database}.slack_messages FINAL")
      assert survivor(database) == {"", true}
    end

    test "add and remove of the same user both survive as reaction deltas", %{
      database: database
    } do
      create_migrated_table!(database)

      assert SlackMirror.record_batch([
               row(version: 4, deleted: false, text: "reacted", observed_ts_us: 1_000)
             ]) == :ok

      assert SlackMirror.record_reaction_batch([
               reaction_row(version: 4, deleted: false),
               reaction_row(version: 5, deleted: true)
             ]) == :ok

      query!("OPTIMIZE TABLE #{database}.slack_message_reaction_deltas FINAL")

      assert query!("SELECT count() FROM #{database}.slack_message_reaction_deltas")
             |> String.trim() == "2"

      assert query!("""
             SELECT observed_ts_us FROM #{database}.slack_messages FORMAT TSV
             """)
             |> String.trim() == "1000"
    end
  end

  describe "the block text migration" do
    # The design relies on this rule instead of a revision term in `version`:
    # a re-walk that recomputes a derived column writes the same version as
    # the row already there, and the LATER insert has to be the one that
    # survives. That is what the ReplacingMergeTree documentation promises for
    # equal versions, and it is what lets old rows be replaced by the backfill
    # rather than by a restating migration.
    test "among equal versions the most recently inserted row survives", %{database: database} do
      create_migrated_table!(database)
      apply_block_text_migration!(database)

      assert Sink.write([row(version: 8, deleted: false, text: "fallback")]) == :ok

      assert Sink.write([
               row(
                 version: 8,
                 deleted: false,
                 text: "fallback",
                 body_text: "Deploy failed api-gateway"
               )
             ]) == :ok

      query!("OPTIMIZE TABLE #{database}.slack_messages FINAL")

      assert query!("SELECT body_text FROM #{database}.slack_messages") |> String.trim() ==
               "Deploy failed api-gateway"
    end

    test "the migration is idempotent", %{database: database} do
      create_migrated_table!(database)
      apply_block_text_migration!(database)
      apply_block_text_migration!(database)

      assert query!("""
             SELECT count() FROM system.columns
             WHERE database = '#{database}' AND table = 'slack_messages'
               AND name IN ('body_text', 'blocks', 'payload')
             """)
             |> String.trim() == "3"
    end

    test "the new columns arrive with a searchable index", %{database: database} do
      create_migrated_table!(database)
      apply_block_text_migration!(database)

      assert Sink.write([
               row(version: 8, deleted: false, text: "", body_text: "Deploy failed api-gateway")
             ]) == :ok

      assert query!("""
             SELECT count() FROM #{database}.slack_messages
             WHERE body_text LIKE '%api-gateway%'
             """)
             |> String.trim() == "1"

      assert query!("""
             SELECT count() FROM system.data_skipping_indices
             WHERE database = '#{database}' AND table = 'slack_messages'
               AND name = 'idx_body_text'
             """)
             |> String.trim() == "1"
    end
  end

  test "a table created without the version argument is refused", %{database: database} do
    query!("""
    CREATE TABLE #{database}.slack_messages (
      event_date Date, tenant_id String, workspace_id String, channel_id String,
      message_ts_us UInt64, message_ts String, thread_ts String, version UInt64,
      deleted Bool, actor_kind LowCardinality(String), actor_id String,
      subtype LowCardinality(String), text String, files String, file_count UInt16,
      reply_count UInt32, edited_ts String, ingest_source LowCardinality(String),
      ingest_at DateTime64(3) DEFAULT now64(3)
    ) ENGINE = ReplacingMergeTree
    PARTITION BY toYYYYMM(event_date)
    ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us)
    """)

    assert {:error, {:slack_mirror_table_layout_mismatch, _table, what}} = Sink.readiness()
    assert what =~ "version argument"
  end

  # The reason the check above is not pedantry: on the near-miss table the
  # deleted message comes back.
  test "without the version argument a tombstone loses to a later live row", %{
    database: database
  } do
    query!("""
    CREATE TABLE #{database}.near_miss (
      event_date Date, tenant_id String, workspace_id String, channel_id String,
      message_ts_us UInt64, version UInt64, deleted Bool, text String
    ) ENGINE = ReplacingMergeTree
    PARTITION BY toYYYYMM(event_date)
    ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us)
    """)

    insert_pair!(database, "near_miss")
    assert survivor(database, "near_miss") == {"stale live text", false}

    query!("""
    CREATE TABLE #{database}.versioned (
      event_date Date, tenant_id String, workspace_id String, channel_id String,
      message_ts_us UInt64, version UInt64, deleted Bool, text String
    ) ENGINE = ReplacingMergeTree(version)
    PARTITION BY toYYYYMM(event_date)
    ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us)
    """)

    insert_pair!(database, "versioned")
    assert survivor(database, "versioned") == {"", true}
  end

  # The tombstone at v21 is written first and the stale live row at v20 after
  # it, so insertion order and version order disagree — which is the whole
  # difference between the two engines.
  defp insert_pair!(database, table) do
    query!("""
    INSERT INTO #{database}.#{table} FORMAT JSONEachRow
    {"event_date":"2026-08-31","tenant_id":"t","workspace_id":"w","channel_id":"c","message_ts_us":1,"version":21,"deleted":true,"text":""}
    {"event_date":"2026-08-31","tenant_id":"t","workspace_id":"w","channel_id":"c","message_ts_us":1,"version":20,"deleted":false,"text":"stale live text"}
    """)

    query!("OPTIMIZE TABLE #{database}.#{table} FINAL")
  end

  # Runs the real migration file rather than a copy of its statements, so a
  # drift between what is tested and what a release applies cannot hide here.
  defp apply_block_text_migration!(database) do
    apply_sql_migration!(database, "20260901000003_add_slack_message_payload.sql")
  end

  defp create_migrated_table!(database) do
    apply_sql_migration!(database, "20260831000001_create_slack_messages.sql")
    apply_sql_migration!(database, "20260901000002_add_slack_message_actor_label.sql")
    apply_sql_migration!(database, "20260901000003_add_slack_message_payload.sql")
    apply_sql_migration!(database, "20260902000001_add_slack_mirror_component_tables.sql")
    apply_sql_migration!(database, "20260902000002_add_slack_pin_ts.sql")
    apply_sql_migration!(database, "20260902000003_add_slack_payload_search_text.sql")
    apply_sql_migration!(database, "20260902000004_add_slack_reaction_deltas.sql")
    apply_sql_migration!(database, "20260902000005_reproject_payload_search_text.sql")
    apply_sql_migration!(database, "20260903000001_create_slack_message_event_triggers.sql")
  end

  defp apply_sql_migration!(database, filename) do
    :salix_analytics
    |> Application.app_dir("priv/clickhouse/migrations")
    |> Path.join(filename)
    |> File.read!()
    |> String.replace("{{database}}", database)
    |> String.split("\n")
    |> Enum.reject(&(&1 |> String.trim_leading() |> String.starts_with?("--")))
    |> Enum.join("\n")
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&query!/1)
  end

  defp row(fields) do
    %{
      "event_date" => "2026-08-31",
      "tenant_id" => "t",
      "workspace_id" => "w",
      "channel_id" => "c",
      "message_ts_us" => Keyword.get(fields, :ts_us, 1),
      "message_ts" => "0.000001",
      "thread_ts" => "",
      "version" => Keyword.fetch!(fields, :version),
      "deleted" => Keyword.fetch!(fields, :deleted),
      "actor_kind" => "user",
      "actor_id" => "U1",
      "subtype" => "",
      "text" => Keyword.fetch!(fields, :text),
      "files" => "[]",
      "file_count" => 0,
      "reply_count" => 0,
      "edited_ts" => "",
      "body_text" => Keyword.get(fields, :body_text, ""),
      "ingest_source" => Keyword.get(fields, :source, "webhook"),
      "observed_ts_us" => Keyword.get(fields, :observed_ts_us, 0)
    }
  end

  defp reaction_row(fields) do
    %{
      "event_date" => "2026-08-31",
      "tenant_id" => "t",
      "workspace_id" => "w",
      "channel_id" => "c",
      "message_ts_us" => 1,
      "message_ts" => "0.000001",
      "user_id" => "U1",
      "reaction" => "eyes",
      "version" => Keyword.fetch!(fields, :version),
      "deleted" => Keyword.fetch!(fields, :deleted),
      "ingest_source" => "webhook"
    }
  end

  defp survivor(database, table \\ "slack_messages") do
    query!("OPTIMIZE TABLE #{database}.#{table} FINAL")

    [text, deleted] =
      "SELECT text, deleted FROM #{database}.#{table} FORMAT TSV"
      |> query!()
      |> String.trim_trailing("\n")
      |> String.split("\t")

    {text, deleted == "true"}
  end

  defp query!(sql) do
    %{status: status, body: body} = Req.post!(@clickhouse_url, body: sql, receive_timeout: 20_000)
    assert status in 200..299, "clickhouse rejected #{inspect(sql)}: #{body}"
    to_string(body)
  end
end
