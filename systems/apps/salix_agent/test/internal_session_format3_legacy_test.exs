defmodule SalixAgent.InternalSessionFormat3LegacyTest do
  use ExUnit.Case, async: true
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSessionFormat3Legacy, as: Legacy

  test "normalizes mixed unstamped history and new results without losing result identity or redaction" do
    ref = SalixStore.Ids.new_tool_result_ref()

    result = %{
      "kind" => "tool_result",
      "seq" => 1,
      "result_ref" => ref,
      "tool_call_id" => "new-tool",
      "result_json" => "{\"answer\":42}",
      "stored_at_ms" => 20
    }

    state = %{
      InternalSession.export(InternalSession.new("agent", "ses1_0000000000000000901"))
      | storage_format: 1,
        compacted_through: 1,
        last_seq: 2,
        next_message_id: 3,
        messages: [
          %{id: 1, role: "user", content: "legacy message", created_at: 10},
          %{
            id: 2,
            seq: 2,
            result_seq: 1,
            role: "tool",
            content: %{"stored_result" => true, "result_ref" => ref},
            created_at: 21
          }
        ],
        async_results: [result],
        async_result_refs: %{ref => 1},
        redactions: [%{"seq" => 2, "replacement" => "redacted"}],
        async_tool_calls: %{
          "legacy-tool" => %{
            "status" => "completed",
            "result" => %{"old" => true},
            "completed_at" => 15
          }
        },
        runtime_epoch: 8,
        work_index_token: "keep-index"
    }

    assert {:ok, next} = state |> InternalSession.open() |> Legacy.normalize()
    assert InternalSession.storage_format(next) == 3
    results = InternalSession.get(next, :async_results)
    assert length(results) == 2
    assert InternalSession.get(next, :runtime_epoch) == 8
    assert InternalSession.work_index_token(next) == "keep-index"
    migrated = Enum.find(results, &(&1["result_ref"] == ref))
    assert Map.delete(migrated, "seq") == Map.delete(result, "seq")
    messages = InternalSession.get(next, :messages)
    message = Enum.find(messages, &(&1.id == 2))
    assert message.result_seq == migrated["seq"]

    assert InternalSession.get(next, :redactions) == [
             %{"seq" => message.seq, "replacement" => "redacted"}
           ]

    assert {:ok, ^migrated} = InternalSession.lookup_async_call(next, ref)
    assert Enum.map(messages, & &1.id) == [1, 2]
  end

  test "a captured legacy fork still copies its whole selected transcript but is born format 3" do
    state = %{
      InternalSession.export(InternalSession.new("agent", "ses1_0000000000000000901"))
      | storage_format: 1,
        compacted_through: 1,
        summary: "legacy summary",
        messages: [
          %{id: 1, role: "user", content: "covered"},
          %{id: 2, seq: 2, role: "tool", content: "live", result_seq: 1}
        ],
        async_results: [
          %{
            "seq" => 1,
            "kind" => "async_result",
            "tool_call_id" => "old",
            "result" => "omitted by legacy fork"
          }
        ]
    }

    assert {:ok, child} =
             state
             |> InternalSession.open()
             |> InternalSession.fork("ses1_0000000000000000902", %{})

    child = InternalSession.export(child)

    assert child.storage_format == 3
    assert Enum.map(child.messages, & &1.id) == [1, 2]
    assert child.summary == state.summary
    assert child.archived_through == 0
    assert child.segment_catalog == []
    assert child.async_results == []
    refute Enum.any?(child.messages, &Map.has_key?(&1, :result_seq))
  end

  test "refuses ambiguous existing coordinates before publishing any normalized snapshot" do
    state = %{
      InternalSession.export(InternalSession.new("agent", "ses1_0000000000000000901"))
      | storage_format: 1,
        messages: [%{id: 1, seq: 1, role: "user", content: "old"}],
        async_results: [%{"kind" => "async_result", "seq" => 1, "tool_call_id" => "result"}]
    }

    assert {:error, {:legacy_normalization_failed, :duplicate_legacy_seq}} =
             state |> InternalSession.open() |> Legacy.normalize()
  end
end
