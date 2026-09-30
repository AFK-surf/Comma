defmodule Salix.Bindings.ClickHouseTriageThreadReaderTest do
  use ExUnit.Case, async: true

  alias Salix.Bindings.{ClickHouseTriageThreadReader, TriageFollowUpThreadReader}

  defmodule Reader do
    def read_thread(scope, root_ts, opts) do
      send(self(), {:read_thread, scope, root_ts, opts})
      Process.get(:thread_page)
    end
  end

  test "reads one exact CH thread and preserves bounded reaction and source-state context" do
    Process.put(:thread_page, {:ok, page()})

    assert {:ok, %{"messages" => [root, reply], "source_snapshot" => snapshot}} =
             ClickHouseTriageThreadReader.read(authority(), connect(), reader: Reader)

    assert root["actor_kind"] == "human"
    assert root["message_ts_us"] == 100_000_001
    assert root["observed_version"] == 200_000_002
    assert root["reactions"] == [%{"name" => "eyes", "count" => 2}]
    assert reply["actor_kind"] == "agent"
    assert_snapshot_keys(root)
    assert_snapshot_keys(reply)

    assert snapshot == %{
             "schema" => "comma.triage-clickhouse-thread-snapshot.v2",
             "complete" => true,
             "message_count" => 2,
             "reaction_count" => 1
           }

    assert_receive {:read_thread,
                    %{
                      "tenant_id" => "tenant-1",
                      "workspace_id" => "T1",
                      "channel_id" => "C1"
                    }, "100.000001", [limit: 200, max_bytes: 1_048_576]}
  end

  test "truncated CH context fails closed" do
    Process.put(:thread_page, {:ok, %{page() | complete?: false, truncated_reason: :count}})

    assert {:error, :triage_clickhouse_context_truncated} =
             ClickHouseTriageThreadReader.read(authority(), connect(), reader: Reader)
  end

  test "user-authored body subtypes stay human across indexed and canonical Slack payloads" do
    for subtype <- ~w(file_share me_message thread_broadcast), payload? <- [false, true] do
      row = %{
        "message_ts" => "100.000001",
        "message_ts_us" => 100_000_001,
        "version" => 200_000_002,
        "actor_kind" => "user",
        "actor_id" => "U1",
        "subtype" => subtype,
        "text" => "orion meet bot 的 salix token 怎么被注销了"
      }

      row =
        if payload? do
          Map.put(
            row,
            "payload",
            Jason.encode!(%{
              "ts" => row["message_ts"],
              "user" => row["actor_id"],
              "subtype" => subtype,
              "text" => row["text"]
            })
          )
        else
          row
        end

      Process.put(:thread_page, {:ok, %{page() | messages: [row], reactions: []}})

      assert {:ok, %{"messages" => [message]}} =
               ClickHouseTriageThreadReader.read(authority(), connect(), reader: Reader)

      assert message["actor_kind"] == "human", "#{subtype}, payload=#{payload?}"
      assert message["text"] == row["text"]
      assert_snapshot_keys(message)
    end
  end

  test "follow-up reads the same known CH thread without a Slack reader" do
    previous = Application.get_env(:salix_im, :slack_triage_clickhouse_reader_mod)
    Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Reader)

    on_exit(fn ->
      Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, previous)
    end)

    Process.put(:thread_page, {:ok, page()})

    assert {:ok, %{"messages" => [_root, _reply]}} =
             TriageFollowUpThreadReader.read(
               authority(),
               Map.delete(connect(), "approved_channel_id"),
               %{
                 "channel_id" => "C1",
                 "thread_ts" => "100.000001"
               }
             )

    assert_receive {:read_thread, _scope, "100.000001", _opts}

    assert {:error, :invalid_triage_follow_up_target} =
             TriageFollowUpThreadReader.read(authority(), connect(), %{
               "channel_id" => "C_OTHER",
               "thread_ts" => "100.000001"
             })

    refute_receive {:read_thread, _scope, _root_ts, _opts}
  end

  test "canonical payload overlays Slack fields without leaking extra snapshot keys" do
    Process.put(
      :thread_page,
      {:ok,
       %{
         page()
         | messages: [
             %{
               "message_ts" => "100.000001",
               "message_ts_us" => 100_000_001,
               "version" => 200_000_002,
               "actor_kind" => "user",
               "actor_id" => "U1",
               "subtype" => "",
               "text" => "indexed fallback",
               "payload" =>
                 Jason.encode!(%{
                   "ts" => "100.000001",
                   "text" => "payload text",
                   "user" => "U1",
                   "blocks" => [%{"type" => "section"}],
                   "attachments" => [%{"id" => 1}],
                   "files" => [%{"id" => "F1"}],
                   "metadata" => %{"event_type" => "task_created"}
                 })
             }
           ]
       }}
    )

    assert {:ok, %{"messages" => [message]}} =
             ClickHouseTriageThreadReader.read(authority(), connect(), reader: Reader)

    assert message["text"] == "payload text"
    assert message["user"] == "U1"
    assert_snapshot_keys(message)
    refute Map.has_key?(message, "blocks")
    refute Map.has_key?(message, "attachments")
    refute Map.has_key?(message, "files")
    refute Map.has_key?(message, "metadata")
    refute Map.has_key?(message, "payload")

    assert message["file_attachments"] == %{
             "total_count" => 1,
             "truncated" => false,
             "items" => [%{"name" => "", "kind" => "file"}]
           }
  end

  test "forwarded Task context survives the mirror projection as bounded quoted evidence" do
    [row | _] = page().messages

    payload = %{
      "text" => "这个 task 完成了但没有回复？",
      "attachments" => [
        %{
          "is_msg_unfurl" => true,
          "channel_id" => "C_TASKS",
          "ts" => "100.000002",
          "from_url" =>
            "https://atlas.slack.com/archives/C_TASKS/p100000002?thread_ts=100.000001&cid=C_TASKS",
          "author_id" => "U_TASK_BOT",
          "text" => "Task Review PR #67: ready for review " <> String.duplicate("材料", 300),
          "attachments" => [%{"text" => "nested private payload"}]
        }
      ]
    }

    Process.put(:thread_page, {
      :ok,
      %{page() | messages: [Map.put(row, "payload", Jason.encode!(payload))], reactions: []}
    })

    assert {:ok, %{"messages" => [message]}} =
             ClickHouseTriageThreadReader.read(authority(), connect(), reader: Reader)

    assert String.starts_with?(message["text"], payload["text"])
    assert message["text"] =~ "untrusted Slack forwarded-message references"
    [_, quoted] = String.split(message["text"], "UNTRUSTED_SLACK_MESSAGE_REFERENCES_JSON=")
    assert %{"references" => [reference]} = Jason.decode!(quoted)
    assert reference["channel_id"] == "C_TASKS"
    assert reference["message_ts"] == "100.000002"
    assert reference["thread_ts"] == "100.000001"
    assert reference["text"] =~ "Task Review PR #67: ready for review"
    assert String.valid?(reference["text"])
    assert byte_size(reference["text"]) <= 512
    refute message["text"] =~ "nested private payload"
    refute message["text"] =~ "atlas.slack.com"
    assert_snapshot_keys(message)
  end

  defp assert_snapshot_keys(message) do
    assert Enum.sort(Map.keys(message)) ==
             Enum.sort(
               ~w(ts text subtype user bot_id app_id bot_profile_name actor_kind actor_id message_ts_us observed_version reactions file_attachments)
             )
  end

  defp authority do
    %{
      "approved_channel_id" => "C1",
      "channel_id" => "C1",
      "thread_ts" => "100.000001"
    }
  end

  defp connect do
    %{
      "tenant_id" => "tenant-1",
      "workspace_id" => "T1",
      "approved_channel_id" => "C1",
      "bot_user_id" => "BU1"
    }
  end

  defp page do
    %{
      messages: [
        %{
          "message_ts" => "100.000001",
          "message_ts_us" => 100_000_001,
          "version" => 200_000_002,
          "actor_kind" => "user",
          "actor_id" => "U1",
          "subtype" => "",
          "text" => "Can you help?"
        },
        %{
          "message_ts" => "101.000001",
          "message_ts_us" => 101_000_001,
          "version" => 202_000_002,
          "actor_kind" => "user",
          "actor_id" => "BU1",
          "subtype" => "",
          "text" => "Working on it"
        }
      ],
      reactions: [
        %{
          "message_ts" => "100.000001",
          "message_ts_us" => 100_000_001,
          "reaction" => "eyes",
          "count" => 2
        }
      ],
      complete?: true,
      truncated_reason: nil
    }
  end
end
