defmodule SalixAgent.SessionKernelHistoryTest do
  use SystemsClock.Case, async: false
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

  test "archive advance replaces sorted valid catalog and retains uncompacted records" do
    kept_message = %{id: 2, seq: 3, content: "keep"}
    kept_event = %{"seq" => 3, "kind" => "fact"}
    kept_result = %{"seq" => 3, "tool_call_id" => "call"}

    before =
      state(
        last_seq: 3,
        compacted_seq: 2,
        live_context_bytes: 999,
        messages: [%{id: 1, seq: 1, content: "gone"}, kept_message],
        events: [%{"seq" => 2}, kept_event],
        async_results: [%{"seq" => 1}, kept_result],
        segment_catalog: [[9, 9, 0, 1]]
      )

    catalog = [[2, 2, 0, 20], [1, 1, 1, 10], [0, 0, 0, 1], [1, 1, 2, 1], :invalid]

    released = %{
      before
      | archived_through: 2,
        segment_catalog: [[1, 1, 1, 10], [2, 2, 0, 20]],
        messages: [kept_message],
        events: [kept_event],
        async_results: [kept_result],
        live_context_bytes: 4
    }

    assert apply_event(before, "archive_advance", %{
             "archived_through" => 2,
             "segments" => catalog
           }) === released

    assert apply_event(before, "archive_advance", %{
             "archived_through" => 3,
             "segments" => [[1, 3, 2, 30]]
           }) === %{released | archived_through: 3, segment_catalog: [[1, 3, 2, 30]]}

    for fields <- [
          %{"archived_through" => 4, "segments" => []},
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

  test "stored results validate Unicode graphemes and remain idempotent through PG reload" do
    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    session = Ids.new_session_id()
    ev = stored_event(%{session_id: session}, "e\u0301👩‍💻")
    assert {:ok, written} = SalixAgent.TestSupport.SessionFixture.commit(agent, session, [ev])
    assert {:ok, reloaded} = SalixAgent.InternalSessionStore.read(agent, session)
    record = SalixAgent.InternalSession.get(reloaded, :async_results) |> hd()
    assert record["result_json"] == ev["result_json"]
    assert record["result_chars"] == 2
    assert {:ok, duplicate} = SalixAgent.TestSupport.SessionFixture.commit(agent, session, [ev])

    assert SalixAgent.InternalSession.get(duplicate, :last_seq) ==
             SalixAgent.InternalSession.get(written, :last_seq)

    assert SalixAgent.InternalSession.get(duplicate, :async_results) == [record]
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
