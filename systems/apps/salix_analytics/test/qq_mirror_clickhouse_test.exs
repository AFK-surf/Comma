defmodule SalixAnalytics.QQMirrorClickHouseTest do
  @moduledoc """
  The record of QQ group messages against a real ClickHouse: the migration,
  the layout probe, the merge of a message delivered twice, and the
  bot-scoped read.
  """
  use SystemsClock.Case, async: false

  @moduletag :clickhouse

  alias SalixAnalytics.QQMirror
  alias SalixAnalytics.QQMirror.{Reader, Sink}

  @clickhouse_url System.get_env("SALIX_TEST_CLICKHOUSE_URL", "http://127.0.0.1:8123/")
  @scope %{"tenant_id" => "tenant-a", "app_id" => "1900012345"}

  setup do
    database = "qq_mirror_test_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    previous = SystemsRuntime.get_env(:salix_analytics, :clickhouse)

    query!("CREATE DATABASE #{database}")

    SystemsRuntime.put_env(:salix_analytics, :clickhouse,
      base_url: @clickhouse_url,
      table: "#{database}.events"
    )

    on_exit(fn ->
      query!("DROP DATABASE IF EXISTS #{database}")

      if is_nil(previous),
        do: SystemsRuntime.delete_env(:salix_analytics, :clickhouse),
        else: SystemsRuntime.put_env(:salix_analytics, :clickhouse, previous)
    end)

    {:ok, database: database}
  end

  test "a precreated table on the wrong key stops writes instead of losing rows", %{
    database: database
  } do
    query!("""
    CREATE TABLE #{database}.qq_messages (
      tenant_id String, app_id String, chat_id String, message_id String, version UInt64
    ) ENGINE = ReplacingMergeTree
    PARTITION BY cityHash64(tenant_id) % 16
    ORDER BY (tenant_id, app_id, chat_id, message_id)
    """)

    assert {:error, {:qq_mirror_table_layout_mismatch, _table, what}} =
             QQMirror.record_batch([row("ROBOT1.0_a", 1_000, "hello")])

    assert what =~ "version"
  end

  test "an unreachable server is a retryable outage, not a layout mismatch" do
    assert {:error, {:qq_mirror_table_unavailable, _table, _reason}} =
             Sink.readiness(base_url: "http://127.0.0.1:1", receive_timeout_ms: 500)
  end

  test "a group's record reads newest first, and a message delivered twice is one row", %{
    database: database
  } do
    migrate!(database)

    rows = for n <- 1..3, do: row("ROBOT1.0_#{n}", n * 1_000, "部署 deploy #{n}")
    assert :ok = QQMirror.record_batch(rows ++ [hd(rows)])

    assert {:ok, %{messages: messages, has_more?: false}} =
             Reader.search(@scope, chat_id: "group:B2C3")

    assert Enum.map(messages, & &1["message_id"]) == ~w(ROBOT1.0_3 ROBOT1.0_2 ROBOT1.0_1)

    # Chinese substrings match.
    assert {:ok, %{messages: [_, _, _]}} = Reader.search(@scope, patterns: ["%部署%"])

    assert {:ok, %{messages: [%{"message_id" => "ROBOT1.0_2"}]}} =
             Reader.search(@scope, patterns: ["%deploy 2%"])
  end

  test "a read is scoped to the tenant and the bot", %{database: database} do
    migrate!(database)

    mine = row("ROBOT1.0_mine", 1_000, "budget numbers")

    other_bot =
      "ROBOT1.0_bot" |> row(2_000, "budget other bot") |> Map.put("app_id", "1900099999")

    other_tenant = "ROBOT1.0_t" |> row(3_000, "budget tenant") |> Map.put("tenant_id", "tenant-b")

    assert :ok = QQMirror.record_batch([mine, other_bot, other_tenant])

    assert {:ok, %{messages: [%{"message_id" => "ROBOT1.0_mine"}]}} =
             Reader.search(@scope, patterns: ["%budget%"])

    # One message is read by its group and id, in the same scope.
    assert {:ok, %{"message_id" => "ROBOT1.0_mine", "text" => "budget numbers"}} =
             Reader.get_message(@scope, "group:B2C3", "ROBOT1.0_mine")

    assert {:error, :not_found} = Reader.get_message(@scope, "group:B2C3", "ROBOT1.0_bot")
  end

  defp row(message_id, create_ms, text) do
    %{
      "tenant_id" => "tenant-a",
      "app_id" => "1900012345",
      "chat_id" => "group:B2C3",
      "message_id" => message_id,
      "create_time_us" => create_ms * 1_000,
      "version" => create_ms * 1_000 * 2,
      "deleted" => false,
      "root_id" => "",
      "parent_id" => "",
      "thread_id" => "",
      "chat_type" => "group",
      "message_type" => "text",
      "actor_kind" => "user",
      "actor_id" => "A1B2",
      "actor_label" => "小明",
      "text" => text,
      "content" => Jason.encode!(%{"files" => []}),
      "file_count" => 0,
      "ingest_source" => "webhook",
      "observed_ts_us" => 0
    }
  end

  defp migrate!(database) do
    :salix_analytics
    |> Application.app_dir("priv/clickhouse/migrations/20261012000001_create_qq_messages.sql")
    |> File.read!()
    |> String.replace("{{database}}", database)
    |> query!()
  end

  defp query!(sql) do
    %{status: status, body: body} = Req.post!(@clickhouse_url, body: sql, receive_timeout: 20_000)
    assert status in 200..299, "clickhouse rejected #{inspect(sql)}: #{body}"
    to_string(body)
  end
end
