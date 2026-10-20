defmodule SalixAnalytics.FeishuMirrorClickHouseTest do
  @moduledoc """
  The Feishu mirror write and search path against a real ClickHouse: the
  migration, the layout probe, version merges, and the app-scoped search.
  """
  use SystemsClock.Case, async: false

  @moduletag :clickhouse

  alias SalixAnalytics.FeishuMirror
  alias SalixAnalytics.FeishuMirror.{Reader, Sink}

  @clickhouse_url System.get_env("SALIX_TEST_CLICKHOUSE_URL", "http://127.0.0.1:8123/")
  @scope %{"tenant_id" => "tenant-a", "app_id" => "cli_app_a"}

  setup do
    database = "feishu_mirror_test_#{SystemsRuntime.Proc.unique_integer([:positive])}"
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
    CREATE TABLE #{database}.feishu_messages (
      tenant_id String, app_id String, chat_id String, message_id String, version UInt64
    ) ENGINE = ReplacingMergeTree
    PARTITION BY cityHash64(tenant_id) % 16
    ORDER BY (tenant_id, app_id, chat_id, message_id)
    """)

    assert {:error, {:feishu_mirror_table_layout_mismatch, _table, what}} =
             FeishuMirror.record_batch([row("om_1", 1_000, "hello")])

    assert what =~ "version"
  end

  test "an unreachable server is a retryable outage, not a layout mismatch" do
    assert {:error, {:feishu_mirror_table_unavailable, _table, _reason}} =
             Sink.readiness(base_url: "http://127.0.0.1:1", receive_timeout_ms: 500)
  end

  test "recalls, edits and stale history converge by the message's own version", %{
    database: database
  } do
    migrate!(database)

    live = row("om_live", 1_000, "部署 deploy 完成")
    edited = row("om_edit", 2_000, "old text") |> Map.put("version", 2_000_000 * 2)
    recalled = row("om_gone", 3_000, "secret plan")

    assert :ok = FeishuMirror.record_batch([live, edited, recalled])

    # The edit lands, a history page that observed the pre-edit state arrives
    # later and must lose, and a recall tombstone without a create time hides
    # the original message.
    assert :ok =
             FeishuMirror.record_batch([
               edited |> with_text("new text") |> Map.put("version", 2_500_000 * 2),
               edited |> Map.put("ingest_source", "backfill"),
               tombstone("om_gone", 4_000)
             ])

    assert {:ok, %{messages: [hit]}} = Reader.search(@scope, patterns: ["%new%"])
    assert hit["message_id"] == "om_edit"
    assert {:ok, %{messages: []}} = Reader.search(@scope, patterns: ["%old text%"])
    assert {:ok, %{messages: []}} = Reader.search(@scope, patterns: ["%secret%"])

    # Chinese substrings match, and exclusions apply to the text.
    assert {:ok, %{messages: [%{"message_id" => "om_live"}]}} =
             Reader.search(@scope, patterns: ["%部署%"])

    assert {:ok, %{messages: []}} =
             Reader.search(@scope, patterns: ["%部署%"], exclude_patterns: ["%完成%"])
  end

  test "search is scoped to tenant and app and pages by a stable cursor", %{database: database} do
    migrate!(database)

    rows = for n <- 1..5, do: row("om_#{n}", n * 1_000, "release note #{n}")
    other_app = row("om_x", 9_000, "release note other") |> Map.put("app_id", "cli_app_b")
    other_tenant = row("om_y", 9_000, "release note tenant") |> Map.put("tenant_id", "tenant-b")
    other_chat = row("om_z", 8_000, "release note chat") |> Map.put("chat_id", "oc_other")

    assert :ok = FeishuMirror.record_batch(rows ++ [other_app, other_tenant, other_chat])

    assert {:ok, %{messages: first, has_more?: true, next_cursor: {ts, id}}} =
             Reader.search(@scope, patterns: ["%release%"], chat_id: "oc_chat", limit: 3)

    assert Enum.map(first, & &1["message_id"]) == ~w(om_5 om_4 om_3)

    assert {:ok, %{messages: rest, has_more?: false, next_cursor: nil}} =
             Reader.search(@scope,
               patterns: ["%release%"],
               chat_id: "oc_chat",
               limit: 3,
               cursor_ts_us: ts,
               cursor_message_id: id
             )

    assert Enum.map(rest, & &1["message_id"]) == ~w(om_2 om_1)

    assert {:ok, %{messages: all}} = Reader.search(@scope, patterns: ["%release%"])
    assert Enum.map(all, & &1["message_id"]) == ~w(om_z om_5 om_4 om_3 om_2 om_1)

    assert {:ok, %{messages: [%{"message_id" => "om_2"}]}} =
             Reader.search(@scope,
               patterns: ["%release%"],
               after_us: 2_000_000,
               before_us: 3_000_000
             )
  end

  defp row(message_id, create_ms, text) do
    %{
      "tenant_id" => "tenant-a",
      "app_id" => "cli_app_a",
      "chat_id" => "oc_chat",
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
      "actor_id" => "ou_sender",
      "actor_label" => "",
      "text" => text,
      "content" => Jason.encode!(%{"text" => text}),
      "file_count" => 0,
      "ingest_source" => "webhook",
      "observed_ts_us" => 0
    }
  end

  defp with_text(row, text),
    do: Map.merge(row, %{"text" => text, "content" => Jason.encode!(%{"text" => text})})

  defp tombstone(message_id, recall_ms) do
    row(message_id, 0, "")
    |> Map.merge(%{
      "create_time_us" => 0,
      "version" => recall_ms * 1_000 * 2 + 1,
      "deleted" => true,
      "content" => ""
    })
  end

  defp migrate!(database) do
    :salix_analytics
    |> Application.app_dir("priv/clickhouse/migrations/20261007000001_create_feishu_messages.sql")
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
