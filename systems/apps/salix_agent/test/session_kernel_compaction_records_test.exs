defmodule SalixAgent.SessionKernelCompactionRecordsTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.TestSupport.SessionData
  alias SalixAgent.InternalSession.State

  defp state do
    %State{
      agent_id: "agent-compaction-records",
      session_id: "session-compaction-records",
      status: :active,
      activity_status: :execution,
      activity_status_updated_at: 11,
      last_activity_at: 12,
      last_seq: 4,
      events: [%{"kind" => "older", "seq" => 4}],
      compaction_failure: %{"reason" => "previous failure"},
      last_compaction_recovery: %{"seq" => 2},
      llm_failure_streak: %{"attempts" => 3},
      messages: [%{id: 1, role: "user", content: "retained", payload: [1.25 | false]}],
      storage_revision: "records-revision"
    }
  end

  defp event(type, fields) do
    Map.merge(%{"type" => type, "session_id" => "session-compaction-records"}, fields)
  end

  test "failure replaces the whitelist record, omits nil, and retains false and arbitrary payloads" do
    before = state()

    fields = %{
      "category" => false,
      "retryable" => false,
      "reason" => nil,
      "attempts" => 0,
      "live_context_watermark" => [],
      "config_fingerprint" => "",
      "failed_at" => false,
      "next_retry_at" => 1.25,
      "recovery_summary_written" => %{"nested" => [1.25 | false]},
      "unrelated" => "excluded",
      "seq" => 999
    }

    failure = Map.drop(fields, ["reason", "unrelated", "seq"])
    expected = %State{before | compaction_failure: failure}

    assert Driver.step(before, event("compaction_failure", fields)) === {:done, expected}

    assert SessionData.apply_event(before, event("compaction_failure", fields)) === expected

    assert Driver.step(before, event("compaction_failure", %{})) ===
             {:done, %State{before | compaction_failure: %{}}}
  end

  test "recovery defaults missing kind before nil filtering and appends one exact fact" do
    before = state()

    for {kind_fields, kind_fact} <- [
          {%{}, %{"kind" => "compaction_recovery"}},
          {%{"kind" => nil}, %{}},
          {%{"kind" => false}, %{"kind" => false}},
          {%{"kind" => "custom"}, %{"kind" => "custom"}}
        ] do
      fields =
        Map.merge(
          %{
            "category" => false,
            "reason" => nil,
            "compacted_through" => 0,
            "summary_sequence" => 1.25,
            "created_at" => 20,
            "seq" => 999,
            "unrelated" => "excluded"
          },
          kind_fields
        )

      fact =
        Map.merge(kind_fact, %{
          "category" => false,
          "compacted_through" => 0,
          "summary_sequence" => 1.25,
          "created_at" => 20,
          "seq" => 5
        })

      expected = %State{
        before
        | events: before.events ++ [fact],
          last_seq: 5,
          llm_failure_streak: nil,
          last_compaction_recovery: fact,
          last_activity_at: 20
      }

      assert Driver.step(before, event("compaction_recovery", fields)) === {:done, expected}

      assert SessionData.apply_event(before, event("compaction_recovery", fields)) === expected

      # Recovery records a fact. It does not erase the prior failure record.
      assert expected.compaction_failure === before.compaction_failure
    end
  end

  test "recovery preserves native falsey and numeric sequence behavior and ordered history" do
    for previous <- [nil, false, 0, -3, 4, 1.25],
        history <- [nil, false, [], [%{"seq" => 1}, %{"seq" => 2}]] do
      before = %State{state() | last_seq: previous, events: history}
      next_seq = (previous || 0) + 1
      fact = %{"kind" => "compaction_recovery", "seq" => next_seq}

      expected = %State{
        before
        | events: (history || []) ++ [fact],
          last_seq: next_seq,
          llm_failure_streak: nil,
          last_compaction_recovery: fact
      }

      assert Driver.step(before, event("compaction_recovery", %{})) === {:done, expected}
    end
  end
end
