defmodule SalixAgent.SessionKernelHistoryTest do
  use ExUnit.Case, async: false
  alias SalixAgent.InternalSession.State
  alias SalixAgent.TestSupport.SessionData
  alias SalixStore.Ids

  defp state(fields) do
    struct!(
      %State{
        session_id: Ids.new_session_id(),
        status: :active,
        activity_status: :thinking,
        activity_status_updated_at: 10
      },
      fields
    )
  end

  defp apply_event(state, type, fields) do
    SessionData.apply_event(
      state,
      Map.merge(fields, %{"type" => type, "session_id" => state.session_id})
    )
  end

  test "legacy microcompaction changes only selected content and invalidates byte cache" do
    first = %{id: 1, role: "tool", content: "first"}
    second = %{"id" => 2, "role" => "user", "content" => "long content"}
    assistant = %{id: 3, role: "assistant", content: "long assistant"}

    before =
      state(storage_format: 1, messages: [first, second, assistant], live_context_bytes: 99)

    ev = %{
      "message_ids" => [1],
      "new_content" => "x",
      "non_model_messages_over_bytes_through" => 3,
      "non_model_message_max_bytes" => 4
    }

    assert apply_event(before, "session_microcompact", ev) ===
             %{
               before
               | messages: [%{first | content: "x"}, %{second | "content" => "x"}, assistant],
                 live_context_bytes: nil
             }
  end

  test "legacy microcompaction updates plain message fields" do
    message = %{path: "opaque", id: 1, role: "tool", content: "raw"}
    before = state(storage_format: 1, messages: [message], live_context_bytes: 3)

    assert apply_event(before, "session_microcompact", %{
             "message_ids" => [1],
             "new_content" => "x"
           }) ===
             %{before | messages: [Map.put(message, :content, "x")], live_context_bytes: nil}
  end

  test "format two microcompaction appends sorted overlays and leaves raw bytes intact" do
    message = %{id: 2, seq: 7, role: "tool", content: "raw"}
    old = %{"message_id" => 1, "replacement" => "old"}

    before =
      state(storage_format: 2, messages: [message], redactions: [old], live_context_bytes: 3)

    expected = [
      old,
      %{
        "message_id" => 2,
        "seq" => 7,
        "replacement" => "[microcompacted]",
        "reason" => "microcompact",
        "created_at" => 0
      },
      %{
        "message_id" => 9,
        "replacement" => "[microcompacted]",
        "reason" => "microcompact",
        "created_at" => 0
      }
    ]

    assert apply_event(before, "session_microcompact", %{
             "message_ids" => [9, 2, 2],
             "new_content" => false,
             "created_at" => 0
           }) === %{before | redactions: expected}
  end

  test "predicate overlays retain monotone bounds and the strictest byte threshold" do
    kind = "non_model_messages_over_bytes_through"
    old = %{"kind" => kind, "through_id" => 8, "replacement" => "old", "max_bytes" => 100}
    other = %{"message_id" => 1, "replacement" => "unrelated"}
    before = state(storage_format: 2, redactions: [old, other])

    assert apply_event(before, "session_microcompact", %{
             "non_model_messages_over_bytes_through" => 4,
             "non_model_message_max_bytes" => 20,
             "new_content" => "new"
           }) ===
             %{before | redactions: [other, %{old | "replacement" => "new", "max_bytes" => 20}]}
  end

  test "stale compaction baselines are complete no-ops before malformed payload reads" do
    before =
      state(
        summary_sequence: 4,
        summary: "current",
        compacted_through: 5,
        compacted_seq: 6,
        messages: :unvisited,
        async_result_refs: :unvisited
      )

    for type <- ["compaction", "provider_compaction"], sequence <- [3, 4] do
      assert apply_event(before, type, %{
               "summary_sequence" => sequence,
               "compacted_through" => :malformed,
               "items" => :malformed
             }) === before
    end
  end

  test "advancing summary and provider compaction recompute exact live bytes" do
    messages = [%{id: 1, seq: 1, content: "old"}, %{id: 2, seq: 2, content: "keep"}]

    before =
      state(
        messages: messages,
        last_seq: 2,
        summary_sequence: 1,
        compaction_failure: %{old: true},
        live_context_bytes: 999
      )

    fields = %{
      "summary_sequence" => 2,
      "compacted_through" => 1,
      "compacted_seq" => 99,
      "summary" => "s"
    }

    assert apply_event(before, "compaction", fields) ===
             %{
               before
               | summary_sequence: 2,
                 compacted_through: 1,
                 compacted_seq: 2,
                 summary: "s",
                 provider_compaction: nil,
                 compaction_failure: nil,
                 live_context_bytes: 5
             }

    provider = %{"items" => "provider", "compacted_through" => 1, "created_at" => 20}

    assert apply_event(before, "provider_compaction", provider) ===
             %{
               before
               | summary_sequence: 2,
                 compacted_through: 1,
                 compacted_seq: 1,
                 summary: nil,
                 provider_compaction: Map.put(provider, "strategy", "openai_responses"),
                 compaction_failure: nil,
                 live_context_bytes: 12,
                 last_activity_at: 20
             }
  end

  test "compact-result writes append exact facts and keep eight newest manual records" do
    manual = Map.new(1..10, fn n -> {"manual-#{n}", %{"seq" => n}} end)

    before =
      state(
        last_seq: 10,
        compact_results: Map.put(manual, 1, %{"seq" => 1}),
        llm_failure_streak: %{"count" => 2}
      )

    fact = %{
      "source_message_id" => "new",
      "status" => false,
      "kind" => "session_compact_result",
      "seq" => 11
    }

    kept =
      Map.take(manual, Enum.map(4..10, &"manual-#{&1}"))
      |> Map.put(1, %{"seq" => 1})
      |> Map.put("new", fact)

    assert apply_event(before, "session_compact_result", %{
             "source_message_id" => "new",
             "status" => false,
             "reason" => nil
           }) ===
             %{
               before
               | events: [fact],
                 last_seq: 11,
                 llm_failure_streak: nil,
                 compact_results: kept
             }
  end

  test "archive advance replaces sorted valid catalog and removes only covered records" do
    kept_message = %{id: 2, seq: 3, content: "keep"}
    kept_event = %{"seq" => 3, "kind" => "fact"}
    kept_result = %{"seq" => 3, "tool_call_id" => "call"}
    overlay = %{"message_id" => 1, "replacement" => "masked"}

    before =
      state(
        last_seq: 3,
        compacted_seq: 2,
        live_context_bytes: 999,
        messages: [%{id: 1, seq: 1, content: "gone"}, kept_message],
        events: [%{"seq" => 2}, kept_event],
        async_results: [%{"seq" => 1}, kept_result],
        redactions: [overlay],
        segment_catalog: [[9, 9, 0, 1]]
      )

    catalog = [[2, 2, 0, 20], [1, 1, 1, 10], [0, 0, 0, 1], [1, 1, 2, 1], :invalid]

    assert apply_event(before, "archive_advance", %{
             "archived_through" => 2,
             "segments" => catalog
           }) ===
             %{
               before
               | archived_through: 2,
                 segment_catalog: [[1, 1, 1, 10], [2, 2, 0, 20]],
                 messages: [kept_message],
                 events: [kept_event],
                 async_results: [kept_result],
                 live_context_bytes: 4
             }

    for fields <- [
          %{"archived_through" => 3, "segments" => []},
          %{"archived_through" => 0, "segments" => []},
          %{"archived_through" => 2, "segments" => false}
        ] do
      assert apply_event(before, "archive_advance", fields) === before
    end
  end

  defp stored_event(state, text) do
    %{
      "type" => "tool_result_stored",
      "session_id" => state.session_id,
      "result_ref" => Ids.new_tool_result_ref(),
      "tool_call_id" => "call",
      "tool_name" => "tool",
      "result_json" => text,
      "result_bytes" => byte_size(text),
      "result_chars" => 2,
      "result_sha256" => Base.encode16(:crypto.hash(:sha256, text), case: :lower),
      "status" => "completed",
      "is_error" => false,
      "stored_at_ms" => 20
    }
  end

  test "stored results validate Unicode graphemes and remain idempotent while referenced" do
    before = state(last_seq: 3)
    ev = stored_event(before, "e\u0301👩‍💻")

    record =
      ev |> Map.drop(["type", "session_id"]) |> Map.merge(%{"kind" => "tool_result", "seq" => 4})

    expected = %{
      before
      | last_seq: 4,
        async_results: [record],
        async_result_refs: %{ev["result_ref"] => 4},
        last_activity_at: 20
    }

    assert SessionData.apply_event(before, ev) === expected
    assert SessionData.apply_event(expected, ev) === expected
    archived = %{expected | async_results: []}
    assert SessionData.apply_event(archived, ev) === archived
  end

  test "invalid stored results cannot change durable state even with malformed append fields" do
    before = state(last_seq: :unvisited, async_results: :unvisited, async_result_refs: :unvisited)
    valid = stored_event(before, "e\u0301👩‍💻")

    for {key, value} <- [
          {"result_bytes", 2},
          {"result_chars", 5},
          {"result_chars", 2.0},
          {"result_sha256", String.duplicate("0", 64)},
          {"result_json", <<255>>},
          {"result_ref", "invalid"},
          {"tool_name", " \t"},
          {"is_error", nil},
          {"stored_at_ms", -1}
        ] do
      assert SessionData.apply_event(before, Map.put(valid, key, value)) === before
    end
  end
end
