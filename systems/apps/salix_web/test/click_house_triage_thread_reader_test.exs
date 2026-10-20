defmodule Salix.Bindings.ClickHouseTriageThreadReaderTest do
  use SystemsClock.Case, async: true

  alias Salix.Bindings.{ClickHouseTriageThreadReader, TriageFollowUpThreadReader}

  defmodule Reader do
    def read_thread(scope, root_ts, opts) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:read_thread, scope, root_ts, opts})
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

  test "frozen message text withholds Bearer spans before the snapshot is hashed" do
    [root, reply] = page().messages

    reply =
      reply
      |> Map.put("text", "use Bearer QUJDREVGRw for the read-only tool")
      |> Map.put("payload", Jason.encode!(%{"files" => [%{"name" => "Bearer QUJDREVGRw.txt"}]}))

    Process.put(:thread_page, {:ok, %{page() | messages: [root, reply]}})

    assert {:ok, %{"messages" => [_root, withheld]}} =
             ClickHouseTriageThreadReader.read(authority(), connect(), reader: Reader)

    assert withheld["text"] == "use [Bearer-credential withheld] for the read-only tool"

    assert withheld["file_attachments"]["items"] == [
             %{"name" => "[Bearer-credential withheld]", "kind" => "file"}
           ]
  end

  test "follow-up reads the same known CH thread without a Slack reader" do
    previous = SystemsRuntime.get_env(:salix_im, :slack_triage_clickhouse_reader_mod)
    SystemsRuntime.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Reader)

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, previous)
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
