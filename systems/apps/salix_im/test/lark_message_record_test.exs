defmodule SalixIM.LarkMessageRecordTest do
  @moduledoc """
  The writers of the Lark message record against the real PostgreSQL outbox
  and ledger, with a scripted Lark reader and a scripted ClickHouse writer.
  """
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:lark_mirror_outbox, :lark_mirror_backfill]

  alias SalixIM.LarkMessageRecord.{Backfill, BackfillRunner, OutboxDrainer, Row}
  alias SalixStore.{LarkMirrorBackfillLedger, LarkMirrorOutbox, Repo}

  @connect %{"tenant_id" => "tenant-a", "app_id" => "cli_app_a", "connect_id" => "lark-1"}
  @scope %{"tenant_id" => "tenant-a", "app_id" => "cli_app_a"}

  defmodule Writer do
    @moduledoc false
    use Agent

    def start(answers \\ []),
      do: Agent.start_link(fn -> %{rows: [], answers: answers} end, name: __MODULE__)

    def rows, do: Agent.get(__MODULE__, & &1.rows)
    def enabled?, do: true

    def write_batch(rows) do
      Agent.get_and_update(__MODULE__, fn state ->
        case state.answers do
          [answer | rest] ->
            {answer, %{state | answers: rest}}

          [] ->
            {:ok, %{state | rows: state.rows ++ rows}}
        end
      end)
      |> case do
        {:ok, _} -> :ok
        other -> other
      end
    end
  end

  defmodule Reader do
    @moduledoc false
    use Agent

    def start(script),
      do: Agent.start_link(fn -> Map.put(script, :calls, []) end, name: __MODULE__)

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def list_chats(_connect, token) do
      Agent.get_and_update(__MODULE__, fn state ->
        {Map.fetch!(state.chats, token), %{state | calls: [{:chats, token} | state.calls]}}
      end)
    end

    def list_messages(_connect, container, token, end_time) do
      key = {container["container_type"], container["container_id"]}

      Agent.get_and_update(__MODULE__, fn state ->
        [answer | rest] =
          Map.get(state.pages, key, [{:ok, %{"items" => [], "has_more" => false}}])

        pages = Map.put(state.pages, key, if(rest == [], do: [answer], else: rest))
        answer = if is_function(answer, 2), do: answer.(token, end_time), else: answer

        {answer,
         %{state | pages: pages, calls: [{:messages, key, token, end_time} | state.calls]}}
      end)
    end
  end

  defmodule Connects do
    @moduledoc "The connects the runner looks an installation up in."
    use Agent

    def start(connects), do: Agent.start_link(fn -> connects end, name: __MODULE__)

    def get_active_connect_by_id(_group_id, connect_id, "lark") do
      case Agent.get(__MODULE__, &Map.get(&1, connect_id)) do
        nil -> {:error, :not_found}
        connect -> {:ok, connect}
      end
    end
  end

  setup do
    Repo.query!("TRUNCATE lark_mirror_containers")

    # The runner works only while the record has a storage adapter.
    previous = SystemsRuntime.get_env(:salix_im, :lark_message_record_mod)
    SystemsRuntime.put_env(:salix_im, :lark_message_record_mod, Writer)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_im, :lark_message_record_mod, previous),
        else: SystemsRuntime.delete_env(:salix_im, :lark_message_record_mod)
    end)

    :ok
  end

  describe "Row" do
    test "a live post and its history page converge on one row and version" do
      event = receive_event("om_1", "1700000000000", "@_user_1 部署好了")

      assert {:ok, live} = Row.from_event(@connect, event)
      assert live["version"] == 1_700_000_000_000_000 * 2
      assert live["text"] == "@Alice 部署好了"
      assert live["actor_id"] == "ou_sender"

      history = %{
        "message_id" => "om_1",
        "chat_id" => "oc_chat",
        "msg_type" => "text",
        "create_time" => "1700000000000",
        "body" => %{"content" => event["event"]["message"]["content"]},
        "mentions" => event["event"]["message"]["mentions"],
        "sender" => %{"id" => "ou_sender", "sender_type" => "user", "sender_name" => "Bob"}
      }

      assert {:ok, backfilled} = Row.from_history(@connect, history, 5)
      assert backfilled["version"] == live["version"]
      assert backfilled["text"] == live["text"]
      assert backfilled["content"] == live["content"]
      assert backfilled["actor_label"] == "Bob"
      assert backfilled["ingest_source"] == "backfill"
      assert backfilled["observed_ts_us"] == 5
    end

    test "the bot's own message has one version from its send and from history" do
      message = %{
        "message_id" => "om_bot",
        "chat_id" => "oc_chat",
        "msg_type" => "text",
        "create_time" => "1700000001000",
        "body" => %{"content" => Jason.encode!(%{"text" => "Release 42."})},
        "sender" => %{"id" => "cli_app_a", "sender_type" => "app"}
      }

      assert {:ok, sent} = Row.from_sent(@connect, message, "Release 42.")
      assert {:ok, walked} = Row.from_history(@connect, message, 9)
      assert walked["version"] == sent["version"]
      assert walked["message_id"] == sent["message_id"]
    end

    test "a history item without an identity or a create time is no row" do
      assert :ignore = Row.from_history(%{"tenant_id" => "tenant-a"}, history("om_1", "1", ""), 0)
      assert :ignore = Row.from_history(@connect, history("om_1", "", ""), 0)
    end
  end

  describe "OutboxDrainer" do
    test "deletes rows only after the writer acknowledged them" do
      {:ok, _} = Writer.start([{:error, :clickhouse_down}])
      {:ok, row} = Row.from_event(@connect, receive_event("om_1", "1000", "hello"))
      assert :ok = LarkMirrorOutbox.append(row)

      assert {:error, :clickhouse_down} =
               OutboxDrainer.drain_once(writer: Writer, drain_ms: 0, max_backoff_ms: 0)

      assert Writer.rows() == []
      assert :idle = OutboxDrainer.drain_once(writer: Writer)
      assert [%{"message_id" => "om_1"}] = Writer.rows()
      assert {:ok, nil} = LarkMirrorOutbox.oldest_pending_age_ms()
    end
  end

  describe "Backfill" do
    test "walks chats and their threads newest first and commits only landed pages" do
      {:ok, _} = Writer.start()

      {:ok, _} =
        Reader.start(%{
          chats: %{nil => {:ok, %{"items" => [%{"chat_id" => "oc_chat"}], "has_more" => false}}},
          pages: %{
            {"chat", "oc_chat"} => [
              {:ok,
               %{
                 "items" => [history("om_2", "2000", "omt_1"), history("om_1", "1000", "")],
                 "has_more" => true,
                 "page_token" => "p2"
               }},
              {:ok, %{"items" => [history("om_0", "500", "")], "has_more" => false}}
            ],
            {"thread", "omt_1"} => [
              {:ok, %{"items" => [history("om_r", "2500", "omt_1")], "has_more" => false}}
            ]
          }
        })

      assert {:ok, :more} = Backfill.run_pass(@connect, reader: Reader, writer: Writer)
      assert {:ok, {:incomplete, nil}} = LarkMirrorBackfillLedger.coverage(@scope, nil, 0)

      assert {:ok, :idle} = Backfill.run_pass(@connect, reader: Reader, writer: Writer)
      assert {:ok, :complete} = LarkMirrorBackfillLedger.coverage(@scope, "oc_chat", 0)

      assert Enum.map(Writer.rows(), & &1["message_id"]) == ~w(om_2 om_1 om_r om_0)
      assert Enum.all?(Writer.rows(), &(&1["ingest_source"] == "backfill"))

      assert [
               {:chats, nil},
               {:messages, {"chat", "oc_chat"}, nil, nil},
               {:messages, {"thread", "omt_1"}, nil, nil},
               {:messages, {"chat", "oc_chat"}, "p2", nil}
             ] = Reader.calls()
    end

    test "a listing of chats longer than one pass goes on in the next pass" do
      {:ok, _} = Writer.start()
      empty = [{:ok, %{"items" => [], "has_more" => false}}]

      {:ok, _} =
        Reader.start(%{
          chats: %{
            nil =>
              {:ok,
               %{"items" => [%{"chat_id" => "oc_one"}], "has_more" => true, "page_token" => "c2"}},
            "c2" => {:ok, %{"items" => [%{"chat_id" => "oc_two"}], "has_more" => false}}
          },
          pages: %{{"chat", "oc_one"} => empty, {"chat", "oc_two"} => empty}
        })

      opts = [reader: Reader, writer: Writer, max_chat_pages: 1]

      # The first pass lists one page of chats and walks what it found. The
      # second page is still to list: the pass is not idle, and neither the
      # app nor the unlisted chat is covered.
      assert {:ok, :more} = Backfill.run_pass(@connect, opts)
      assert {:ok, {:unfinished, "c2"}} = LarkMirrorBackfillLedger.discovery(@scope)
      assert {:ok, :complete} = LarkMirrorBackfillLedger.coverage(@scope, "oc_one", 0)
      assert {:ok, {:incomplete, nil}} = LarkMirrorBackfillLedger.coverage(@scope, nil, 0)
      assert {:ok, :not_synced} = LarkMirrorBackfillLedger.coverage(@scope, "oc_two", 0)

      # The second pass goes on from the second page, not from the first.
      assert {:ok, :idle} = Backfill.run_pass(@connect, opts)
      assert [{:chats, nil}, {:messages, _, _, _}, {:chats, "c2"} | _walk] = Reader.calls()
      assert {:ok, :finished} = LarkMirrorBackfillLedger.discovery(@scope)
      assert {:ok, :complete} = LarkMirrorBackfillLedger.coverage(@scope, nil, 0)
      assert {:ok, :complete} = LarkMirrorBackfillLedger.coverage(@scope, "oc_two", 0)

      # A later listing looks for new chats from the first page again, and the
      # app stays covered while it runs.
      assert {:ok, :more} = Backfill.run_pass(@connect, opts)
      assert {:chats, nil} = Enum.at(Reader.calls(), -1)
      assert {:ok, {:unfinished, "c2"}} = LarkMirrorBackfillLedger.discovery(@scope)
      assert {:ok, :complete} = LarkMirrorBackfillLedger.coverage(@scope, nil, 0)
    end

    test "a page the record did not take is not committed and is walked again" do
      {:ok, _} = Writer.start([{:error, :clickhouse_down}])

      {:ok, _} =
        Reader.start(%{
          chats: %{nil => {:ok, %{"items" => [%{"chat_id" => "oc_chat"}], "has_more" => false}}},
          pages: %{
            {"chat", "oc_chat"} => [
              {:ok, %{"items" => [history("om_1", "1000", "")], "has_more" => false}}
            ]
          }
        })

      assert {:error, :clickhouse_down} =
               Backfill.run_pass(@connect, reader: Reader, writer: Writer)

      assert {:ok, {:incomplete, nil}} = LarkMirrorBackfillLedger.coverage(@scope, nil, 0)

      assert {:ok, :idle} = Backfill.run_pass(@connect, reader: Reader, writer: Writer)
      assert [%{"message_id" => "om_1"}] = Writer.rows()
      assert {:ok, :complete} = LarkMirrorBackfillLedger.coverage(@scope, nil, 0)
    end

    test "a page Lark refused makes the pass a retry and keeps the watermark" do
      {:ok, _} = Writer.start()

      {:ok, _} =
        Reader.start(%{
          chats: %{nil => {:ok, %{"items" => [%{"chat_id" => "oc_chat"}], "has_more" => false}}},
          pages: %{
            {"chat", "oc_chat"} => [
              {:ok,
               %{
                 "items" => [history("om_2", "2000", "")],
                 "has_more" => true,
                 "page_token" => "p2"
               }},
              {:error, "Lark API error 230002"},
              # The page token is gone; the walk resumes from the watermark,
              # at the next whole second.
              fn nil, "3" ->
                {:ok, %{"items" => [history("om_1", "1000", "")], "has_more" => false}}
              end
            ]
          }
        })

      assert {:ok, :more} = Backfill.run_pass(@connect, reader: Reader, writer: Writer)
      assert {:ok, :retry} = Backfill.run_pass(@connect, reader: Reader, writer: Writer)

      assert {:ok, {:incomplete, 2_000_000}} =
               LarkMirrorBackfillLedger.coverage(@scope, "oc_chat", 0)

      assert {:ok, :idle} = Backfill.run_pass(@connect, reader: Reader, writer: Writer)
      assert Enum.map(Writer.rows(), & &1["message_id"]) == ~w(om_2 om_1)
    end
  end

  describe "BackfillRunner" do
    @installation %{"connect_id" => "lark-1", "tenant_id" => "tenant-a", "group_id" => "g1"}

    test "a due installation is walked as its connect and put off when it is done" do
      {:ok, _} = Writer.start()

      {:ok, _} =
        Connects.start(%{
          "lark-1" =>
            Map.merge(@connect, %{"status" => "connected", "app_secret" => "lark-app-secret"})
        })

      {:ok, _} =
        Reader.start(%{
          chats: %{nil => {:ok, %{"items" => [%{"chat_id" => "oc_chat"}], "has_more" => false}}},
          pages: %{
            {"chat", "oc_chat"} => [
              {:ok, %{"items" => [history("om_1", "1000", "")], "has_more" => false}}
            ]
          }
        })

      assert :ok = LarkMirrorBackfillLedger.upsert_connects([@installation])
      opts = [connects: Connects, reader: Reader, writer: Writer, pace_ms: 0]

      assert {:ok, :idle} = BackfillRunner.run_once(opts)
      assert [%{"message_id" => "om_1", "app_id" => "cli_app_a"}] = Writer.rows()
      # Done: the installation is due again only after the pass interval.
      assert :empty = BackfillRunner.run_once(opts)
    end

    test "an installation whose connect is gone or has no credentials is forgotten" do
      {:ok, _} = Writer.start()
      {:ok, _} = Reader.start(%{chats: %{}, pages: %{}})
      {:ok, _} = Connects.start(%{"lark-1" => Map.put(@connect, "status", "connected")})

      assert :ok =
               LarkMirrorBackfillLedger.upsert_connects([
                 @installation,
                 %{@installation | "connect_id" => "lark-gone"}
               ])

      opts = [connects: Connects, reader: Reader, writer: Writer, pace_ms: 0]

      assert {:ok, :idle} = BackfillRunner.run_once(opts)
      assert {:ok, :idle} = BackfillRunner.run_once(opts)
      assert :empty = LarkMirrorBackfillLedger.claim_due_connect(60_000)
      assert Reader.calls() == []
    end

    test "the runner does nothing while the record is off" do
      SystemsRuntime.delete_env(:salix_im, :lark_message_record_mod)
      assert :ok = LarkMirrorBackfillLedger.upsert_connects([@installation])

      assert :empty = BackfillRunner.run_once([])
      assert {:ok, %{scan_complete: true}} = BackfillRunner.discover_once(nil, [])
      assert {:ok, %{"connect_id" => "lark-1"}} = LarkMirrorBackfillLedger.claim_due_connect(1)
    end
  end

  defp receive_event(message_id, create_time, text) do
    %{
      "header" => %{"event_type" => "im.message.receive_v1"},
      "event" => %{
        "sender" => %{"sender_id" => %{"open_id" => "ou_sender"}, "sender_type" => "user"},
        "message" => %{
          "message_id" => message_id,
          "chat_id" => "oc_chat",
          "chat_type" => "group",
          "message_type" => "text",
          "create_time" => create_time,
          "mentions" => [
            %{"key" => "@_user_1", "id" => %{"open_id" => "ou_a"}, "name" => "Alice"}
          ],
          "content" => Jason.encode!(%{"text" => text})
        }
      }
    }
  end

  defp history(message_id, create_time, thread_id) do
    %{
      "message_id" => message_id,
      "chat_id" => "oc_chat",
      "thread_id" => thread_id,
      "msg_type" => "text",
      "create_time" => create_time,
      "body" => %{"content" => Jason.encode!(%{"text" => "m #{message_id}"})},
      "sender" => %{"id" => "ou_sender", "sender_type" => "user"}
    }
  end
end
