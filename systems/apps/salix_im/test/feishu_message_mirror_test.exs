defmodule SalixIM.FeishuMessageMirrorTest do
  @moduledoc """
  The Feishu mirror writers against the real PostgreSQL outbox and ledger,
  with a scripted Feishu reader and a scripted ClickHouse writer.
  """
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:feishu_mirror_outbox, :feishu_mirror_backfill]

  alias SalixIM.FeishuMessageMirror.{Backfill, OutboxDrainer, Row}
  alias SalixStore.{FeishuMirrorBackfillLedger, FeishuMirrorOutbox, Repo}

  @connect %{"tenant_id" => "tenant-a", "app_id" => "cli_app_a", "connect_id" => "fs-1"}
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

  setup do
    Repo.query!("TRUNCATE feishu_mirror_containers")

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
    end
  end

  describe "OutboxDrainer" do
    test "deletes rows only after the writer acknowledged them" do
      {:ok, _} = Writer.start([{:error, :clickhouse_down}])
      {:ok, row} = Row.from_event(@connect, receive_event("om_1", "1000", "hello"))
      assert :ok = FeishuMirrorOutbox.append(row)

      assert {:error, :clickhouse_down} =
               OutboxDrainer.drain_once(writer: Writer, drain_ms: 0, max_backoff_ms: 0)

      assert Writer.rows() == []
      assert :idle = OutboxDrainer.drain_once(writer: Writer)
      assert [%{"message_id" => "om_1"}] = Writer.rows()
      assert {:ok, nil} = FeishuMirrorOutbox.oldest_pending_age_ms()
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
      assert {:ok, {:incomplete, nil}} = FeishuMirrorBackfillLedger.coverage(@scope, nil, 0)

      assert {:ok, :idle} = Backfill.run_pass(@connect, reader: Reader, writer: Writer)
      assert {:ok, :complete} = FeishuMirrorBackfillLedger.coverage(@scope, "oc_chat", 0)

      assert Enum.map(Writer.rows(), & &1["message_id"]) == ~w(om_2 om_1 om_r om_0)
      assert Enum.all?(Writer.rows(), &(&1["ingest_source"] == "backfill"))

      assert [
               {:chats, nil},
               {:messages, {"chat", "oc_chat"}, nil, nil},
               {:messages, {"thread", "omt_1"}, nil, nil},
               {:messages, {"chat", "oc_chat"}, "p2", nil}
             ] = Reader.calls()
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
