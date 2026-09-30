defmodule SalixAnalytics.SlackMirror.ReaderTest do
  use ExUnit.Case, async: false

  alias SalixAnalytics.SlackMirror.Reader

  defmodule Mock do
    @moduledoc false
    import Plug.Conn
    use Agent

    def start_link(_opts),
      do:
        Agent.start_link(fn -> %{requests: [], status: 200, bodies: [""]} end,
          name: __MODULE__
        )

    def respond_with(body), do: respond_with_many([body])

    def respond_with_many(bodies),
      do: Agent.update(__MODULE__, &%{&1 | status: 200, bodies: bodies})

    def last_request, do: Agent.get(__MODULE__, &List.first(&1.requests))
    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))
    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)

      {status, body} =
        Agent.get_and_update(__MODULE__, fn state ->
          [body | rest] = state.bodies

          {{state.status, body},
           %{
             state
             | requests: [Map.put(conn.query_params, "__body", raw) | state.requests],
               bodies: if(rest == [], do: [body], else: rest)
           }}
        end)

      send_resp(conn, status, body)
    end
  end

  setup do
    start_supervised!(Mock)

    bandit =
      start_supervised!(
        {Bandit, plug: Mock, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: {__MODULE__, :bandit}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    previous = Application.get_env(:salix_analytics, :clickhouse)

    Application.put_env(:salix_analytics, :clickhouse,
      base_url: "http://127.0.0.1:#{port}/",
      table: "test.analytics_events"
    )

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:salix_analytics, :clickhouse),
        else: Application.put_env(:salix_analytics, :clickhouse, previous)
    end)

    :ok
  end

  test "list_changes is authority-scoped, cursor-bound, and returns a bounded next cursor" do
    Mock.respond_with(Jason.encode!(row()))

    window = %{
      "lower_bound" => %{
        "ingest_at" => "2026-09-01T00:00:00.000Z",
        "message_ts_us" => 0,
        "version" => 0
      },
      "page_after" => %{
        "ingest_at" => "2026-09-01T00:00:00.500Z",
        "message_ts_us" => 1_787_019_000_000_000,
        "version" => 3_574_038_000_000_000
      },
      "tail" => %{
        "ingest_at" => "2026-09-01T00:00:02.000Z",
        "message_ts_us" => 1_787_019_002_000_000,
        "version" => 3_574_038_004_000_000
      }
    }

    assert {:ok, %{rows: [returned], next_cursor: next_cursor, has_more?: false}} =
             Reader.list_changes(scope(), window, 25)

    assert returned == row()

    assert next_cursor == %{
             "ingest_at" => row()["ingest_at"],
             "message_ts_us" => row()["message_ts_us"],
             "version" => row()["version"]
           }

    request = Mock.last_request()
    sql = request["__body"]

    assert request["param_tenant_id"] == "tenant-atlas"
    assert request["param_workspace_id"] == "T_ATLAS"
    assert request["param_channel_id"] == "C_ATLAS"
    assert request["param_lower_ingest_at"] == window["lower_bound"]["ingest_at"]
    assert request["param_tail_ingest_at"] == window["tail"]["ingest_at"]
    assert request["param_after_ingest_at"] == window["page_after"]["ingest_at"]
    assert request["param_has_page_after"] == "1"
    assert request["param_limit"] == "26"
    assert sql =~ "test.slack_message_event_triggers"
    assert sql =~ "test.slack_messages"
    assert sql =~ "FINAL"
    assert sql =~ "messages.tenant_id AS tenant_id"
    assert sql =~ "messages.message_ts_us AS message_ts_us"
    assert sql =~ "triggers.version AS version"
    refute sql =~ "messages.version AS version"
    assert sql =~ "triggers.tenant_id = {tenant_id:String}"
    assert sql =~ "triggers.workspace_id = {workspace_id:String}"
    assert sql =~ "triggers.channel_id = {channel_id:String}"
    assert sql =~ "(triggers.ingest_at, triggers.message_ts_us, triggers.version) >="
    assert sql =~ "(triggers.ingest_at, triggers.message_ts_us, triggers.version) <="
    assert sql =~ "{has_page_after:UInt8} = 0 OR"

    assert sql =~
             "ORDER BY triggers.ingest_at ASC, triggers.message_ts_us ASC, triggers.version ASC"

    refute sql =~ "ingest_source = 'webhook'"
    refute sql =~ "tenant-atlas"
  end

  test "latest_states re-reads the winning state for the requested physical messages" do
    current = row() |> Map.put("text", "edited text") |> Map.put("version", row()["version"] + 2)
    Mock.respond_with(Jason.encode!(current))

    assert {:ok, %{1_787_019_001_000_001 => ^current}} =
             Reader.latest_states(scope(), [1_787_019_001_000_001])

    request = Mock.last_request()
    sql = request["__body"]
    assert request["param_message_ts_us_0"] == "1787019001000001"
    assert sql =~ "FINAL"
    assert sql =~ "message_ts_us = {message_ts_us_0:UInt64}"
    assert sql =~ "test.slack_messages"
  end

  test "latest_states returns an empty result without querying ClickHouse" do
    assert {:ok, %{}} = Reader.latest_states(scope(), [])
    assert Mock.requests() == []
  end

  test "a new pass uses an inclusive overlap boundary and an exact captured tail" do
    Mock.respond_with("")

    lower = %{
      "ingest_at" => "2026-09-01T00:00:00.000Z",
      "message_ts_us" => 0,
      "version" => 0
    }

    tail = %{
      "ingest_at" => "2026-09-01T00:00:01.123Z",
      "message_ts_us" => 1_787_019_001_000_001,
      "version" => 3_574_038_002_000_002
    }

    assert {:ok, %{rows: [], next_cursor: nil, has_more?: false}} =
             Reader.list_changes(
               scope(),
               %{"lower_bound" => lower, "page_after" => nil, "tail" => tail},
               25
             )

    request = Mock.last_request()
    assert request["param_has_page_after"] == "0"
    assert request["param_after_ingest_at"] == lower["ingest_at"]
    assert request["param_tail_ingest_at"] == tail["ingest_at"]

    assert request["__body"] =~
             "(triggers.ingest_at, triggers.message_ts_us, triggers.version) >="

    assert request["__body"] =~
             "(triggers.ingest_at, triggers.message_ts_us, triggers.version) <="
  end

  test "an empty terminal page clears the prior page cursor" do
    Mock.respond_with("")

    lower = %{
      "ingest_at" => "2026-09-01T00:00:00.000Z",
      "message_ts_us" => 0,
      "version" => 0
    }

    page_after = %{
      "ingest_at" => "2026-09-01T00:00:00.500Z",
      "message_ts_us" => 1_787_019_000_500_000,
      "version" => 3_574_038_001_000_000
    }

    tail = %{
      "ingest_at" => "2026-09-01T00:00:01.123Z",
      "message_ts_us" => 1_787_019_001_000_001,
      "version" => 3_574_038_002_000_002
    }

    assert {:ok, %{rows: [], next_cursor: nil, has_more?: false}} =
             Reader.list_changes(
               scope(),
               %{"lower_bound" => lower, "page_after" => page_after, "tail" => tail},
               25
             )

    assert Mock.last_request()["param_has_page_after"] == "1"
  end

  test "tail captures the current ingestion tuple without exposing message content" do
    tail = Map.take(row(), ~w(ingest_at message_ts_us version))
    Mock.respond_with(Jason.encode!(tail))

    assert Reader.tail(scope()) == {:ok, tail}

    request = Mock.last_request()
    sql = request["__body"]
    assert sql =~ "slack_message_event_triggers"
    assert sql =~ "triggers.message_ts_us AS message_ts_us"
    assert sql =~ "triggers.version AS version"

    assert sql =~
             "ORDER BY triggers.ingest_at DESC, triggers.message_ts_us DESC, triggers.version DESC"

    refute sql =~ "ingest_source = 'webhook'"
    refute sql =~ "actor_id"
    refute sql =~ "text,"
  end

  test "read_thread returns bounded current messages and aggregated reaction context" do
    root = thread_row()

    reply =
      thread_row()
      |> Map.put("message_ts_us", 1_787_019_002_000_002)
      |> Map.put("message_ts", "1787019002.000002")
      |> Map.put("thread_ts", root["message_ts"])
      |> Map.put("text", "thread reply")

    reactions = [
      %{
        "message_ts_us" => reply["message_ts_us"],
        "message_ts" => reply["message_ts"],
        "reaction" => "eyes",
        "count" => 2
      }
    ]

    Mock.respond_with_many([
      Enum.map_join([index_row(root), index_row(reply)], "\n", &Jason.encode!/1),
      Enum.map_join([root, reply], "\n", &Jason.encode!/1),
      Enum.map_join(reactions, "\n", &Jason.encode!/1)
    ])

    assert {:ok,
            %{
              messages: [^root, ^reply],
              reactions: ^reactions,
              complete?: true,
              truncated_reason: nil
            }} = Reader.read_thread(scope(), root["message_ts"], limit: 20, max_bytes: 4_096)

    [index_request, message_request, reaction_request] = Mock.requests()
    index_sql = index_request["__body"]
    message_sql = message_request["__body"]
    reaction_sql = reaction_request["__body"]

    assert index_request["param_root_ts"] == root["message_ts"]
    assert index_request["param_root_ts_us"] == Integer.to_string(root["message_ts_us"])
    assert index_request["param_limit"] == "21"
    assert index_sql =~ "length(payload) AS payload_bytes"
    assert index_sql =~ "message_ts_us = {root_ts_us:UInt64}"
    assert index_sql =~ "thread_ts = {root_ts:String}"
    refute index_sql =~ "AS ingest_at"
    assert message_request["param_message_ts_us_0"] == Integer.to_string(root["message_ts_us"])
    assert message_request["param_message_ts_us_1"] == Integer.to_string(reply["message_ts_us"])
    assert message_sql =~ "ORDER BY message_ts_us ASC"
    assert message_sql =~ "payload"
    assert reaction_sql =~ "test.slack_message_reaction_deltas FINAL"
    assert reaction_sql =~ "deleted = false"
    assert reaction_sql =~ "argMax(deleted, version)"
    assert reaction_sql =~ "message_ts_us = {message_ts_us_0:UInt64}"
    assert reaction_sql =~ "message_ts_us = {message_ts_us_1:UInt64}"
  end

  test "read_thread marks count overflow as incomplete without reading reactions" do
    first = thread_row()

    second =
      thread_row()
      |> Map.put("message_ts_us", first["message_ts_us"] + 1)
      |> Map.put("message_ts", "1787019001.000002")
      |> Map.put("thread_ts", first["message_ts"])

    Mock.respond_with_many([
      Enum.map_join([index_row(first), index_row(second)], "\n", &Jason.encode!/1),
      Jason.encode!(first)
    ])

    assert {:ok, %{messages: [^first], reactions: [], complete?: false, truncated_reason: :count}} =
             Reader.read_thread(scope(), first["message_ts"], limit: 1, max_bytes: 4_096)

    assert length(Mock.requests()) == 2
  end

  test "channel batches read sibling roots, older thread context and later answers in one bounded read" do
    root = thread_row()

    sibling =
      root
      |> Map.put("message_ts_us", root["message_ts_us"] + 1)
      |> Map.put("message_ts", "1787019001.000002")
      |> Map.put("thread_ts", "")

    later =
      root
      |> Map.put("message_ts_us", root["message_ts_us"] + 2)
      |> Map.put("message_ts", "1787019001.000003")
      |> Map.put("thread_ts", root["message_ts"])

    messages = [root, sibling, later]

    window = %{
      "oldest_ts_us" => sibling["message_ts_us"],
      "latest_ts_us" => sibling["message_ts_us"],
      "thread_roots" => [root["message_ts"], sibling["message_ts"]]
    }

    Mock.respond_with_many([
      Enum.map_join(messages, "\n", &Jason.encode!(index_row(&1))),
      Enum.map_join(messages, "\n", &Jason.encode!/1),
      ""
    ])

    assert {:ok, %{messages: ^messages, complete?: true}} =
             Reader.read_channel(scope(), window, limit: 200, max_bytes: 1_048_576)

    [index, payload, reactions] = Mock.requests()
    assert index["param_limit"] == "201"
    assert index["param_oldest_ts_us"] == to_string(sibling["message_ts_us"])
    assert index["param_roots"] == "['1787019001.000001','1787019001.000002']"
    assert index["__body"] =~ "thread_ts IN {roots:Array(String)}"
    assert index["__body"] =~ "message_ts_us >= {oldest_ts_us:UInt64}"

    for request <- [index, payload, reactions] do
      assert request["param_tenant_id"] == scope()["tenant_id"]
      assert request["param_workspace_id"] == scope()["workspace_id"]
      assert request["param_channel_id"] == scope()["channel_id"]
    end
  end

  test "channel batch capacity errors remain explicit and avoid reading oversized bodies" do
    root = thread_row()

    window = %{
      "oldest_ts_us" => root["message_ts_us"],
      "latest_ts_us" => root["message_ts_us"],
      "thread_roots" => [root["message_ts"]]
    }

    Mock.respond_with(
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "payload_bytes" => 100,
        "text_bytes" => 5
      })
    )

    assert {:ok, %{messages: [], complete?: false, truncated_reason: :bytes}} =
             Reader.read_channel(scope(), window, limit: 200, max_bytes: 10)

    assert length(Mock.requests()) == 1

    assert {:error, :invalid_slack_mirror_read} =
             Reader.read_channel(scope(), Map.put(window, "thread_roots", ["untrusted'root"]), [])

    assert length(Mock.requests()) == 1
  end

  test "history returns channel-visible Slack objects newest first" do
    root = thread_row()

    payload =
      Jason.encode!(%{
        "type" => "message",
        "ts" => root["message_ts"],
        "text" => "please review this update",
        "user" => "U_HUMAN"
      })

    root = Map.put(root, "payload", payload)

    Mock.respond_with_many([
      Jason.encode!(root),
      "",
      "",
      "",
      ""
    ])

    assert {:ok, %{messages: [message], has_more?: false, next_cursor: nil}} =
             Reader.history(scope(), limit: 20)

    assert message["ts"] == root["message_ts"]
    assert message["text"] == "please review this update"
    assert message["user"] == "U_HUMAN"
    assert Mock.requests() |> hd() |> Map.get("__body") =~ "thread_ts = message_ts"
  end

  test "history accepts whole-second time bounds for neighboring messages" do
    row = thread_row()
    Mock.respond_with_many([Jason.encode!(row), "", "", "", ""])

    assert {:ok, %{messages: [_]}} =
             Reader.history(scope(), oldest: "1787019000", latest: "1787019100", limit: 10)

    request = hd(Mock.requests())
    assert request["param_oldest_us"] == "1787019000000000"
    assert request["param_latest_us"] == "1787019100000000"
  end

  test "replies returns one thread oldest first and overlays reactions" do
    root = thread_row()

    payload =
      Jason.encode!(%{
        "type" => "message",
        "ts" => root["message_ts"],
        "text" => "root",
        "user" => "U_HUMAN"
      })

    root = Map.put(root, "payload", payload)

    Mock.respond_with_many([
      Jason.encode!(root),
      "",
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "user_id" => "U_REACTOR",
        "reaction" => "eyes",
        "version" => 4,
        "deleted" => false
      }),
      "",
      ""
    ])

    assert {:ok, %{messages: [message], has_more?: false}} =
             Reader.replies(scope(), root["message_ts"], limit: 20)

    assert message["reactions"] == [
             %{"name" => "eyes", "count" => 1, "users" => ["U_REACTOR"]}
           ]
  end

  test "history prefers the payload side table over an empty message row" do
    root = thread_row()

    stored =
      Jason.encode!(%{
        "type" => "message",
        "ts" => root["message_ts"],
        "text" => "from-side-table"
      })

    Mock.respond_with_many([
      Jason.encode!(root),
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "payload" => stored,
        "observed_ts_us" => 0
      }),
      "",
      "",
      ""
    ])

    assert {:ok, %{messages: [message]}} = Reader.history(scope(), limit: 20)
    assert message["text"] == "from-side-table"
  end

  test "a reaction tombstone clears reactions still sitting on the payload" do
    root = thread_row()

    payload =
      Jason.encode!(%{
        "type" => "message",
        "ts" => root["message_ts"],
        "text" => "root",
        "reactions" => [%{"name" => "eyes", "count" => 1, "users" => ["U_REACTOR"]}]
      })

    root = Map.put(root, "payload", payload)

    Mock.respond_with_many([
      Jason.encode!(root),
      "",
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "user_id" => "U_REACTOR",
        "reaction" => "eyes",
        "version" => 5,
        "deleted" => true
      }),
      "",
      ""
    ])

    assert {:ok, %{messages: [message]}} = Reader.replies(scope(), root["message_ts"], limit: 20)
    refute Map.has_key?(message, "reactions")
  end

  test "a history reaction snapshot plus one live add keeps the snapshot count" do
    root = thread_row()

    payload =
      Jason.encode!(%{
        "type" => "message",
        "ts" => root["message_ts"],
        "text" => "root",
        "reactions" => [
          %{"name" => "eyes", "count" => 100, "users" => ["U1"]}
        ]
      })

    root = Map.put(root, "payload", payload)

    Mock.respond_with_many([
      Jason.encode!(root),
      "",
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "user_id" => "U101",
        "reaction" => "eyes",
        "version" => 4,
        "deleted" => false
      }),
      "",
      ""
    ])

    assert {:ok, %{messages: [message]}} = Reader.replies(scope(), root["message_ts"], limit: 20)

    assert message["reactions"] == [
             %{"name" => "eyes", "count" => 101, "users" => ["U1", "U101"]}
           ]
  end

  test "a reaction tombstone does not drop other snapshot reactors" do
    root = thread_row()

    payload =
      Jason.encode!(%{
        "type" => "message",
        "ts" => root["message_ts"],
        "text" => "root",
        "reactions" => [
          %{"name" => "eyes", "count" => 100, "users" => ["U1", "U2"]}
        ]
      })

    root = Map.put(root, "payload", payload)

    Mock.respond_with_many([
      Jason.encode!(root),
      "",
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "user_id" => "U1",
        "reaction" => "eyes",
        "version" => 5,
        "deleted" => true
      }),
      "",
      ""
    ])

    assert {:ok, %{messages: [message]}} = Reader.replies(scope(), root["message_ts"], limit: 20)

    assert message["reactions"] == [
             %{"name" => "eyes", "count" => 99, "users" => ["U2"]}
           ]
  end

  test "a reaction logged after the history request starts is applied" do
    root = thread_row()

    payload =
      Jason.encode!(%{
        "type" => "message",
        "ts" => root["message_ts"],
        "text" => "root",
        "reactions" => [%{"name" => "eyes", "count" => 100, "users" => ["U1"]}]
      })

    root = Map.put(root, "payload", payload)

    Mock.respond_with_many([
      Jason.encode!(root),
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "payload" => payload,
        "observed_ts_us" => 1_000
      }),
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "user_id" => "U101",
        "reaction" => "eyes",
        "version" => 4_000,
        "deleted" => false
      }),
      "",
      ""
    ])

    assert {:ok, %{messages: [message]}} = Reader.replies(scope(), root["message_ts"], limit: 20)

    assert message["reactions"] == [
             %{"name" => "eyes", "count" => 101, "users" => ["U1", "U101"]}
           ]
  end

  test "a live reaction before the snapshot cut is not applied twice" do
    root = thread_row()

    payload =
      Jason.encode!(%{
        "type" => "message",
        "ts" => root["message_ts"],
        "text" => "root",
        "reactions" => [%{"name" => "eyes", "count" => 101, "users" => ["U1"]}]
      })

    root = Map.put(root, "payload", payload)

    Mock.respond_with_many([
      Jason.encode!(root),
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "payload" => payload,
        "observed_ts_us" => 2_000
      }),
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "user_id" => "U101",
        "reaction" => "eyes",
        "version" => 2_000,
        "deleted" => false
      }),
      "",
      ""
    ])

    assert {:ok, %{messages: [message]}} = Reader.replies(scope(), root["message_ts"], limit: 20)

    assert message["reactions"] == [
             %{"name" => "eyes", "count" => 101, "users" => ["U1"]}
           ]
  end

  test "a hidden snapshot reactor is removed by a post-cut tombstone" do
    root = thread_row()

    payload =
      Jason.encode!(%{
        "type" => "message",
        "ts" => root["message_ts"],
        "text" => "root",
        "reactions" => [%{"name" => "eyes", "count" => 100, "users" => ["U1"]}]
      })

    root = Map.put(root, "payload", payload)

    Mock.respond_with_many([
      Jason.encode!(root),
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "payload" => payload,
        "observed_ts_us" => 1_000
      }),
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "user_id" => "U_HIDDEN",
        "reaction" => "eyes",
        "version" => 4_000,
        "deleted" => true
      }),
      "",
      ""
    ])

    assert {:ok, %{messages: [message]}} = Reader.replies(scope(), root["message_ts"], limit: 20)

    assert message["reactions"] == [
             %{"name" => "eyes", "count" => 99, "users" => ["U1"]}
           ]
  end

  test "a hidden tombstone does not drop listed snapshot reactors" do
    root = thread_row()

    payload =
      Jason.encode!(%{
        "type" => "message",
        "ts" => root["message_ts"],
        "text" => "root",
        "reactions" => [%{"name" => "eyes", "count" => 1, "users" => ["U1"]}]
      })

    root = Map.put(root, "payload", payload)

    Mock.respond_with_many([
      Jason.encode!(root),
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "payload" => payload,
        "observed_ts_us" => 1_000
      }),
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "user_id" => "U_HIDDEN",
        "reaction" => "eyes",
        "version" => 4_000,
        "deleted" => true
      }),
      "",
      ""
    ])

    assert {:ok, %{messages: [message]}} = Reader.replies(scope(), root["message_ts"], limit: 20)

    assert message["reactions"] == [
             %{"name" => "eyes", "count" => 1, "users" => ["U1"]}
           ]
  end

  test "add then remove after the snapshot cut nets zero" do
    root = thread_row()

    payload =
      Jason.encode!(%{
        "type" => "message",
        "ts" => root["message_ts"],
        "text" => "root",
        "reactions" => [%{"name" => "eyes", "count" => 100, "users" => ["U1"]}]
      })

    root = Map.put(root, "payload", payload)

    Mock.respond_with_many([
      Jason.encode!(root),
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "payload" => payload,
        "observed_ts_us" => 1_000
      }),
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "user_id" => "U101",
        "reaction" => "eyes",
        "version" => 4_001,
        "deleted" => true
      }) <>
        "\n" <>
        Jason.encode!(%{
          "message_ts_us" => root["message_ts_us"],
          "user_id" => "U101",
          "reaction" => "eyes",
          "version" => 4_000,
          "deleted" => false
        }),
      "",
      ""
    ])

    assert {:ok, %{messages: [message]}} = Reader.replies(scope(), root["message_ts"], limit: 20)

    assert message["reactions"] == [
             %{"name" => "eyes", "count" => 100, "users" => ["U1"]}
           ]
  end

  test "replies overlay a live pin onto the Slack object" do
    root = thread_row()
    payload = Jason.encode!(%{"type" => "message", "ts" => root["message_ts"], "text" => "root"})
    root = Map.put(root, "payload", payload)

    Mock.respond_with_many([
      Jason.encode!(root),
      "",
      "",
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "message_ts" => root["message_ts"],
        "pinned_by" => "U_PIN",
        "pinned_ts" => "1787019009",
        "version" => 3_574_038_018_000_000,
        "deleted" => false
      }),
      ""
    ])

    assert {:ok, %{messages: [message]}} = Reader.replies(scope(), root["message_ts"], limit: 20)
    assert message["pinned_to"] == ["C_ATLAS"]
    assert message["pinned_info"]["pinned_by"] == "U_PIN"
    assert message["pinned_info"]["pinned_ts"] == 1_787_019_009
    refute message["pinned_info"]["pinned_ts"] == root["message_ts"]
  end

  test "a pin overlay falls back to the event version when pinned_ts is empty" do
    root = thread_row()
    payload = Jason.encode!(%{"type" => "message", "ts" => root["message_ts"], "text" => "root"})
    root = Map.put(root, "payload", payload)

    Mock.respond_with_many([
      Jason.encode!(root),
      "",
      "",
      Jason.encode!(%{
        "message_ts_us" => root["message_ts_us"],
        "message_ts" => root["message_ts"],
        "pinned_by" => "U_PIN",
        "pinned_ts" => "",
        "version" => 3_574_038_018_000_000,
        "deleted" => false
      }),
      ""
    ])

    assert {:ok, %{messages: [message]}} = Reader.replies(scope(), root["message_ts"], limit: 20)
    assert message["pinned_info"]["pinned_ts"] == 1_787_019_009
  end

  test "read_thread counts payload bytes and does not transfer an over-budget payload" do
    first = thread_row()

    Mock.respond_with(
      Jason.encode!(%{
        "message_ts_us" => first["message_ts_us"],
        "payload_bytes" => 100,
        "text_bytes" => 5
      })
    )

    assert {:ok, %{messages: [], reactions: [], complete?: false, truncated_reason: :bytes}} =
             Reader.read_thread(scope(), first["message_ts"], limit: 20, max_bytes: 10)

    assert length(Mock.requests()) == 1
    assert Mock.last_request()["__body"] =~ "length(payload) AS payload_bytes"
    refute Mock.last_request()["__body"] =~ "AS ingest_at"
  end

  test "search uses ILIKE binds, includes thread replies, and paginates by ts+channel" do
    root =
      Map.put(thread_row(), "payload", Jason.encode!(%{"type" => "message", "text" => "deploy"}))

    Mock.respond_with_many([
      Jason.encode!(root),
      "",
      "",
      "",
      ""
    ])

    assert {:ok, %{messages: [message], has_more?: false, next_cursor: nil}} =
             Reader.search(workspace_scope(),
               patterns: ["%deploy%"],
               limit: 20
             )

    assert message["text"] == "deploy"
    sql = Mock.requests() |> hd() |> Map.get("__body")
    assert sql =~ "m.text ILIKE {term_0:String} OR m.body_text ILIKE {term_0:String}"
    assert sql =~ "p.text ILIKE {term_0:String} OR p.body_text ILIKE {term_0:String}"
    assert sql =~ "JSONExtractString(p.payload, 'text') ILIKE {term_0:String}"
    assert sql =~ "JSONExtractRaw(p.payload, 'blocks') ILIKE {term_0:String}"
    assert sql =~ "slack_message_payloads AS p FINAL"
    refute sql =~ "thread_ts = ''"
    refute sql =~ "deploy"
    assert sql =~ "ORDER BY m.message_ts_us DESC, m.channel_id DESC"
  end

  test "search in: is a channel predicate and from: binds actor_id" do
    Mock.respond_with("")

    assert {:ok, %{messages: []}} =
             Reader.search(workspace_scope(),
               patterns: ["%api%"],
               channel_id: "C_ATLAS",
               actor_id: "U_HUMAN",
               after_date: "2026-01-01",
               after_us: 1_767_225_600_000_000,
               has_file: true
             )

    sql = Mock.last_request()["__body"]
    assert sql =~ "m.channel_id = {channel_id:String}"
    assert sql =~ "m.actor_id = {actor_id:String}"
    assert sql =~ "m.file_count > 0"
    assert sql =~ "m.event_date >= {after_date:Date}"
  end

  test "search ORs AND-groups and applies exclusions to the whole query" do
    Mock.respond_with("")

    assert {:ok, %{messages: []}} =
             Reader.search(workspace_scope(),
               patterns: [["%deploy%"], ["%rollback%"]],
               exclude_patterns: ["%secret%"],
               limit: 20
             )

    sql = Mock.last_request()["__body"]
    assert sql =~ "ILIKE {term_0:String}"
    assert sql =~ ") OR ("
    assert sql =~ "ILIKE {term_1:String}"
    assert sql =~ "JSONExtractRaw(p.payload, 'blocks') ILIKE {term_0:String}"
    assert sql =~ "JSONExtractRaw(p.payload, 'blocks') ILIKE {term_1:String}"
    refute sql =~ "JSONExtractRaw(p.payload, 'blocks') ILIKE {term_2:String}"
    assert sql =~ "NOT (m.text ILIKE {term_2:String}"
    assert sql =~ "extractAll("
    assert sql =~ "JSONExtractString(concat('{\"v\":\"', x, '\"}'), 'v')"
    refute sql =~ ~S{":"([^"]*)"}
    assert sql =~ "ILIKE {term_2:String}"
  end

  test "search rejects a workspace-wide scan with no selective predicate" do
    assert {:error, :invalid_slack_mirror_read} = Reader.search(workspace_scope(), limit: 20)
  end

  test "search isolates tenants" do
    foreign = thread_row() |> Map.put("tenant_id", "other") |> Map.put("payload", "")
    Mock.respond_with(Jason.encode!(foreign))

    assert {:error, :invalid_slack_mirror_row} =
             Reader.search(workspace_scope(), patterns: ["%review%"])
  end

  defp workspace_scope do
    %{"tenant_id" => "tenant-atlas", "workspace_id" => "T_ATLAS"}
  end

  defp scope do
    %{
      "tenant_id" => "tenant-atlas",
      "workspace_id" => "T_ATLAS",
      "channel_id" => "C_ATLAS"
    }
  end

  defp row do
    %{
      "tenant_id" => "tenant-atlas",
      "workspace_id" => "T_ATLAS",
      "channel_id" => "C_ATLAS",
      "message_ts_us" => 1_787_019_001_000_001,
      "message_ts" => "1787019001.000001",
      "thread_ts" => "",
      "version" => 3_574_038_002_000_002,
      "deleted" => false,
      "actor_kind" => "user",
      "actor_id" => "U_HUMAN",
      "actor_label" => "",
      "subtype" => "",
      "text" => "please review this update",
      "ingest_at" => "2026-09-01T00:00:01.123Z"
    }
  end

  defp thread_row, do: Map.put(row(), "payload", "")

  defp index_row(row) do
    %{
      "message_ts_us" => row["message_ts_us"],
      "payload_bytes" => byte_size(row["payload"] || ""),
      "text_bytes" => byte_size(row["text"] || "")
    }
  end
end
