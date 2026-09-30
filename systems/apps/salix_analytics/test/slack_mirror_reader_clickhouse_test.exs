defmodule SalixAnalytics.SlackMirrorReaderClickHouseTest do
  use ExUnit.Case, async: false

  @moduletag :clickhouse

  alias SalixAnalytics.SlackMirror.Reader

  @clickhouse_url System.get_env("SALIX_TEST_CLICKHOUSE_URL", "http://127.0.0.1:8123/")

  setup do
    database = "slack_mirror_reader_test_#{System.unique_integer([:positive])}"
    previous = Application.get_env(:salix_analytics, :clickhouse)

    query!("CREATE DATABASE #{database}")
    migrate!(database)

    assert "DateTime64(3)" ==
             query!(
               "SELECT type FROM system.columns WHERE database = '#{database}' AND table = 'slack_messages' AND name = 'ingest_at' FORMAT TSV"
             )
             |> String.trim()

    Application.put_env(:salix_analytics, :clickhouse,
      base_url: @clickhouse_url,
      table: "#{database}.events"
    )

    on_exit(fn ->
      query!("DROP DATABASE IF EXISTS #{database}")

      if is_nil(previous) do
        Application.delete_env(:salix_analytics, :clickhouse)
      else
        Application.put_env(:salix_analytics, :clickhouse, previous)
      end
    end)

    {:ok, database: database}
  end

  test "low milliseconds remain valid zero-padded ISO8601 timestamps", %{database: database} do
    for fraction <- ["001", "010", "042"] do
      row =
        message_row(ingest_at: "2026-09-02 05:38:41.#{fraction}")
        |> Map.put("channel_id", "C#{fraction}")

      insert_rows!(database, "slack_messages", [row])
      scope = Map.take(row, ~w(tenant_id workspace_id channel_id))

      assert {:ok, states} = Reader.latest_states(scope, [row["message_ts_us"]])
      timestamp = states[row["message_ts_us"]]["ingest_at"]
      assert timestamp == "2026-09-02T05:38:41.#{fraction}Z"
      refute String.contains?(timestamp, <<0>>)
      assert {:ok, _, 0} = DateTime.from_iso8601(timestamp)
    end
  end

  test "production reader query families execute against the migrated ClickHouse schema", %{
    database: database
  } do
    root = message_row(ingest_at: "2026-09-02 05:38:41.042")

    reply =
      message_row(
        message_ts_us: 1_700_000_001_000_002,
        message_ts: "1700000001.000002",
        thread_ts: root["message_ts"],
        version: 3_400_000_002_000_004,
        text: "thread reply",
        ingest_at: "2026-09-02 05:38:42.456"
      )

    insert_rows!(database, "slack_messages", [root, reply])
    insert_rows!(database, "slack_message_payloads", [payload_row(root), payload_row(reply)])
    insert_rows!(database, "slack_message_reaction_deltas", [reaction_row(reply)])

    insert_rows!(database, "slack_message_event_triggers", [trigger_row(root), trigger_row(reply)])

    scope = %{
      "tenant_id" => root["tenant_id"],
      "workspace_id" => root["workspace_id"],
      "channel_id" => root["channel_id"]
    }

    assert {:ok, tail} = Reader.tail(scope)

    assert tail == %{
             "ingest_at" => "2026-09-02T05:38:42.456Z",
             "message_ts_us" => reply["message_ts_us"],
             "version" => reply["version"]
           }

    window = %{
      "lower_bound" => %{
        "ingest_at" => "1970-01-01T00:00:00.000Z",
        "message_ts_us" => 0,
        "version" => 0
      },
      "page_after" => nil,
      "tail" => tail
    }

    assert {:ok, %{rows: [first_change], next_cursor: first_cursor, has_more?: true}} =
             Reader.list_changes(scope, window, 1)

    assert first_change["ingest_at"] == "2026-09-02T05:38:41.042Z"
    assert first_cursor == Map.take(first_change, ~w(ingest_at message_ts_us version))

    assert {:ok, %{rows: [second_change], next_cursor: second_cursor, has_more?: false}} =
             Reader.list_changes(scope, %{window | "page_after" => first_cursor}, 1)

    assert second_change["ingest_at"] == "2026-09-02T05:38:42.456Z"
    assert second_cursor == Map.take(second_change, ~w(ingest_at message_ts_us version))

    assert {:ok, latest} =
             Reader.latest_states(scope, [root["message_ts_us"], reply["message_ts_us"]])

    assert latest[root["message_ts_us"]]["ingest_at"] == "2026-09-02T05:38:41.042Z"
    assert latest[reply["message_ts_us"]]["ingest_at"] == "2026-09-02T05:38:42.456Z"

    assert {:ok,
            %{
              messages: [thread_root, thread_reply],
              reactions: [reaction],
              complete?: true,
              truncated_reason: nil
            }} = Reader.read_thread(scope, root["message_ts"], limit: 20, max_bytes: 4_096)

    assert thread_root["ingest_at"] == "2026-09-02T05:38:41.042Z"
    assert thread_reply["ingest_at"] == "2026-09-02T05:38:42.456Z"

    assert reaction == %{
             "message_ts_us" => reply["message_ts_us"],
             "message_ts" => reply["message_ts"],
             "reaction" => "eyes",
             "count" => 1
           }

    assert {:ok, %{messages: [history_message], has_more?: false}} =
             Reader.history(scope, limit: 1)

    assert history_message["ts"] == root["message_ts"]
    # The parent payload predates the reply. Onboarding must still discover
    # its archived reply stream rather than trust the stale payload count.
    assert history_message["reply_count"] == 1

    assert {:ok, %{messages: reply_messages, has_more?: false}} =
             Reader.replies(scope, root["message_ts"], limit: 20)

    assert Enum.map(reply_messages, & &1["ts"]) == [root["message_ts"], reply["message_ts"]]

    workspace_scope = Map.take(scope, ~w(tenant_id workspace_id))

    assert {:ok, %{messages: [search_message], has_more?: false}} =
             Reader.search(workspace_scope,
               patterns: ["%thread%"],
               channel_id: scope["channel_id"],
               limit: 20
             )

    assert search_message["ts"] == reply["message_ts"]

    # A reply in another workspace and a deleted reply cannot inflate the
    # selected channel's count, even when timestamps and thread ids match.
    foreign = Map.put(reply, "workspace_id", "T_OTHER")
    deleted = reply |> Map.put("deleted", true) |> Map.update!("version", &(&1 + 1))
    insert_rows!(database, "slack_messages", [foreign, deleted])
    assert {:ok, %{messages: [parent]}} = Reader.history(scope, limit: 1)
    assert parent["reply_count"] == 0
  end

  test "list_changes omits backfill while tail, history, and search still see it", %{
    database: database
  } do
    live = message_row()

    historical =
      message_row(
        message_ts_us: 1_600_000_000_000_001,
        message_ts: "1600000000.000001",
        version: 3_200_000_000_000_002,
        text: "old channel discussion",
        ingest_at: "2026-09-02 06:00:00.000"
      )
      |> Map.put("ingest_source", "backfill")

    insert_rows!(database, "slack_messages", [live, historical])
    insert_rows!(database, "slack_message_payloads", [payload_row(live), payload_row(historical)])
    insert_rows!(database, "slack_message_event_triggers", [trigger_row(live)])

    scope = %{
      "tenant_id" => live["tenant_id"],
      "workspace_id" => live["workspace_id"],
      "channel_id" => live["channel_id"]
    }

    assert {:ok, tail} = Reader.tail(scope)
    assert tail["ingest_at"] == "2026-09-02T05:38:41.123Z"
    assert tail["message_ts_us"] == live["message_ts_us"]

    window = %{
      "lower_bound" => %{
        "ingest_at" => "1970-01-01T00:00:00.000Z",
        "message_ts_us" => 0,
        "version" => 0
      },
      "page_after" => nil,
      "tail" => tail
    }

    assert {:ok, %{rows: changes, has_more?: false}} = Reader.list_changes(scope, window, 20)
    assert Enum.map(changes, & &1["message_ts_us"]) == [live["message_ts_us"]]

    assert {:ok, %{messages: history_messages}} = Reader.history(scope, limit: 20)

    assert Enum.map(history_messages, & &1["ts"]) == [
             live["message_ts"],
             historical["message_ts"]
           ]

    workspace_scope = Map.take(scope, ~w(tenant_id workspace_id))

    assert {:ok, %{messages: [search_message]}} =
             Reader.search(workspace_scope, patterns: ["%old channel%"], limit: 20)

    assert search_message["ts"] == historical["message_ts"]
  end

  test "a later backfill of the same message does not drop an unconsumed webhook trigger", %{
    database: database
  } do
    live = message_row()
    insert_rows!(database, "slack_messages", [live])
    insert_rows!(database, "slack_message_event_triggers", [trigger_row(live)])

    scope = %{
      "tenant_id" => live["tenant_id"],
      "workspace_id" => live["workspace_id"],
      "channel_id" => live["channel_id"]
    }

    {:ok, tail} = Reader.tail(scope)

    window = %{
      "lower_bound" => %{
        "ingest_at" => "1970-01-01T00:00:00.000Z",
        "message_ts_us" => 0,
        "version" => 0
      },
      "page_after" => nil,
      "tail" => tail
    }

    assert {:ok, %{rows: [first]}} = Reader.list_changes(scope, window, 20)
    assert first["message_ts_us"] == live["message_ts_us"]

    insert_rows!(database, "slack_messages", [
      live
      |> Map.put("ingest_source", "backfill")
      |> Map.put("ingest_at", "2026-09-02 06:00:01.000")
    ])

    query!("OPTIMIZE TABLE #{database}.slack_messages FINAL")

    assert {:ok, %{rows: [still]}} = Reader.list_changes(scope, window, 20)
    assert still["message_ts_us"] == live["message_ts_us"]
  end

  test "list_changes cursor stays on the trigger version after a newer message rewrite", %{
    database: database
  } do
    live = message_row()
    insert_rows!(database, "slack_messages", [live])
    insert_rows!(database, "slack_message_event_triggers", [trigger_row(live)])

    scope = %{
      "tenant_id" => live["tenant_id"],
      "workspace_id" => live["workspace_id"],
      "channel_id" => live["channel_id"]
    }

    {:ok, tail} = Reader.tail(scope)
    assert tail["version"] == live["version"]

    window = %{
      "lower_bound" => %{
        "ingest_at" => "1970-01-01T00:00:00.000Z",
        "message_ts_us" => 0,
        "version" => 0
      },
      "page_after" => nil,
      "tail" => tail
    }

    insert_rows!(database, "slack_messages", [
      live
      |> Map.put("ingest_source", "backfill")
      |> Map.put("version", live["version"] + 2)
      |> Map.put("ingest_at", "2026-09-02 06:00:01.000")
    ])

    query!("OPTIMIZE TABLE #{database}.slack_messages FINAL")

    assert {:ok, %{rows: [row], next_cursor: cursor, has_more?: false}} =
             Reader.list_changes(scope, window, 20)

    assert row["message_ts_us"] == live["message_ts_us"]
    assert row["version"] == live["version"]
    assert cursor["version"] == tail["version"]
    assert cursor["message_ts_us"] == tail["message_ts_us"]
  end

  test "search exclusions match block content, not JSON type labels", %{database: database} do
    text = "Deploy ready"

    blocks = [
      %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => text}}
    ]

    payload =
      Jason.encode!(%{
        "type" => "message",
        "ts" => "1700000000.000001",
        "text" => text,
        "blocks" => blocks
      })

    live =
      message_row(text: text)
      |> Map.put("payload", payload)
      |> Map.put("blocks", Jason.encode!(blocks))

    insert_rows!(database, "slack_messages", [live])
    insert_rows!(database, "slack_message_payloads", [payload_row(live)])

    workspace_scope = %{
      "tenant_id" => live["tenant_id"],
      "workspace_id" => live["workspace_id"]
    }

    assert {:ok, %{messages: [kept]}} =
             Reader.search(workspace_scope,
               patterns: ["%deploy%"],
               exclude_patterns: ["%type%"],
               limit: 20
             )

    assert kept["ts"] == live["message_ts"]

    assert {:ok, %{messages: []}} =
             Reader.search(workspace_scope,
               patterns: ["%deploy%"],
               exclude_patterns: ["%ready%"],
               limit: 20
             )

    assert {:ok, %{messages: [_secret_ok]}} =
             Reader.search(workspace_scope,
               patterns: ["%deploy%"],
               exclude_patterns: ["%secret%"],
               limit: 20
             )
  end

  test "search exclusions decode escaped JSON when body_text is empty", %{database: database} do
    quoted = empty_projection_message("Deploy \"secret\"", message_ts_us: 1_700_000_000_000_001)
    newline = empty_projection_message("Deploy\nsecret", message_ts_us: 1_700_000_000_000_002)
    slash = empty_projection_message("Deploy \\secret", message_ts_us: 1_700_000_000_000_003)

    insert_rows!(database, "slack_messages", [quoted, newline, slash])

    insert_rows!(
      database,
      "slack_message_payloads",
      Enum.map([quoted, newline, slash], &payload_row/1)
    )

    workspace_scope = %{
      "tenant_id" => quoted["tenant_id"],
      "workspace_id" => quoted["workspace_id"]
    }

    assert {:ok, %{messages: []}} =
             Reader.search(workspace_scope,
               patterns: ["%deploy%"],
               exclude_patterns: ["%secret%"],
               limit: 20
             )

    assert {:ok, %{messages: kept}} =
             Reader.search(workspace_scope,
               patterns: ["%deploy%"],
               exclude_patterns: ["%type%"],
               limit: 20
             )

    assert Enum.map(kept, & &1["ts"]) |> Enum.sort() ==
             Enum.map([quoted, newline, slash], & &1["message_ts"]) |> Enum.sort()
  end

  defp migrate!(database) do
    for migration <- [
          "20260831000001_create_slack_messages.sql",
          "20260901000001_create_slack_message_reactions.sql",
          "20260901000002_add_slack_message_actor_label.sql",
          "20260901000003_add_slack_message_payload.sql",
          "20260902000001_add_slack_mirror_component_tables.sql",
          "20260902000002_add_slack_pin_ts.sql",
          "20260902000003_add_slack_payload_search_text.sql",
          "20260902000004_add_slack_reaction_deltas.sql",
          "20260902000005_reproject_payload_search_text.sql",
          "20260903000001_create_slack_message_event_triggers.sql"
        ] do
      :salix_analytics
      |> Application.app_dir("priv/clickhouse/migrations")
      |> Path.join(migration)
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
  end

  defp insert_rows!(database, table, rows) do
    body = Enum.map_join(rows, "\n", &Jason.encode!/1)
    query!("INSERT INTO #{database}.#{table} FORMAT JSONEachRow\n#{body}")
  end

  defp empty_projection_message(block_text, fields) do
    message_ts_us = Keyword.fetch!(fields, :message_ts_us)
    seconds = div(message_ts_us, 1_000_000)
    micros = rem(message_ts_us, 1_000_000)
    message_ts = "#{seconds}.#{String.pad_leading(Integer.to_string(micros), 6, "0")}"

    blocks = [
      %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => block_text}}
    ]

    payload =
      Jason.encode!(%{
        "type" => "message",
        "ts" => message_ts,
        "text" => "Deploy",
        "blocks" => blocks
      })

    message_row(
      text: "Deploy",
      message_ts: message_ts,
      message_ts_us: message_ts_us,
      version: message_ts_us * 2
    )
    |> Map.put("body_text", "")
    |> Map.put("payload", payload)
    |> Map.put("blocks", "")
  end

  defp message_row(fields \\ []) do
    message_ts = Keyword.get(fields, :message_ts, "1700000000.000001")
    text = Keyword.get(fields, :text, "please review this update")

    %{
      "event_date" => "2026-09-02",
      "tenant_id" => "tenant-atlas",
      "workspace_id" => "T_ATLAS",
      "channel_id" => "C_ATLAS",
      "message_ts_us" => Keyword.get(fields, :message_ts_us, 1_700_000_000_000_001),
      "message_ts" => message_ts,
      "thread_ts" => Keyword.get(fields, :thread_ts, ""),
      "version" => Keyword.get(fields, :version, 3_400_000_000_000_002),
      "deleted" => false,
      "actor_kind" => "user",
      "actor_id" => "U_HUMAN",
      "actor_label" => "Human",
      "subtype" => "",
      "text" => text,
      "body_text" => text,
      "blocks" => "",
      "payload" => Jason.encode!(%{"type" => "message", "ts" => message_ts, "text" => text}),
      "observed_ts_us" => Keyword.get(fields, :version, 3_400_000_000_000_002) |> div(2),
      "files" => "[]",
      "file_count" => 0,
      "reply_count" => 0,
      "edited_ts" => "",
      "ingest_source" => "webhook",
      "ingest_at" => Keyword.get(fields, :ingest_at, "2026-09-02 05:38:41.123")
    }
  end

  defp trigger_row(message) do
    Map.take(message, [
      "event_date",
      "tenant_id",
      "workspace_id",
      "channel_id",
      "message_ts_us",
      "version",
      "ingest_at"
    ])
  end

  defp payload_row(message) do
    %{
      "event_date" => message["event_date"],
      "tenant_id" => message["tenant_id"],
      "workspace_id" => message["workspace_id"],
      "channel_id" => message["channel_id"],
      "message_ts_us" => message["message_ts_us"],
      "version" => message["version"],
      "payload" => message["payload"],
      "observed_ts_us" => message["observed_ts_us"],
      "text" => message["text"],
      "body_text" => message["body_text"]
    }
  end

  defp reaction_row(message) do
    %{
      "event_date" => "2026-09-02",
      "tenant_id" => message["tenant_id"],
      "workspace_id" => message["workspace_id"],
      "channel_id" => message["channel_id"],
      "message_ts_us" => message["message_ts_us"],
      "message_ts" => message["message_ts"],
      "user_id" => "U_REACTOR",
      "reaction" => "eyes",
      "version" => message["version"] + 1,
      "deleted" => false,
      "ingest_source" => "webhook",
      "ingest_at" => "2026-09-02 05:38:42.789"
    }
  end

  defp query!(sql) do
    %{status: status, body: body} = Req.post!(@clickhouse_url, body: sql, receive_timeout: 20_000)
    assert status in 200..299, "clickhouse rejected #{inspect(sql)}: #{body}"
    to_string(body)
  end
end
