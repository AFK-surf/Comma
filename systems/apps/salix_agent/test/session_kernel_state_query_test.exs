defmodule SalixAgent.SessionKernelStateQueryTest do
  @moduledoc """
  Coverage for the resident-state query catalog.

  Each case asserts the kernel's answer for fixture states that exercise
  idle/active sessions, waits, queues, obligations, guard streaks at and below
  their caps, storage formats 1 and 3, redactions, async calls and results, and
  every transcript tail the continuation rules distinguish.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.InternalSession.State
  alias SalixAgent.Waits
  alias SalixVerifiedKernel.Session, as: Resident

  defp ask(state, name, args \\ nil) do
    Resident.query(Resident.open(state), name, args)
  end

  defp expected_snapshot(%State{} = state) do
    %{
      "wait_identity" => Waits.identity(state.wait),
      "next_message_id" => state.next_message_id,
      "last_ack_message_id" => state.last_ack_message_id,
      "active_human_source_ids" => ask(state, :active_human_source_ids)
    }
  end

  ## Fixtures ---------------------------------------------------------------

  defp base(attrs \\ %{}) do
    struct(State, Map.merge(%{agent_id: "agent-1", session_id: "session-1"}, attrs))
  end

  defp user_message(id, extra \\ %{}) do
    Map.merge(%{id: id, role: "user", content: "hello #{id}"}, extra)
  end

  defp assistant_message(id, extra \\ %{}) do
    Map.merge(%{id: id, role: "assistant", content: "reply #{id}", tool_calls: []}, extra)
  end

  defp tool_message(id, extra \\ %{}) do
    Map.merge(%{id: id, role: "tool", content: "{\"ok\":true}"}, extra)
  end

  defp runtime_message(id, extra \\ %{}) do
    Map.merge(%{id: id, role: "runtime", content: "note", type: "wait_expired"}, extra)
  end

  defp queue_item(id, kind, payload, extra \\ %{}) do
    Map.merge(
      %{"queue_id" => id, "kind" => kind, "payload" => payload, "dedupe_key" => "dedupe-#{id}"},
      extra
    )
  end

  defp slack_origin, do: %{"provider" => "slack", "source_message_id" => "slack-1"}

  defp wait_for_wait do
    %{
      "wait_id" => "wait-abc",
      "source" => "wait_for",
      "reason" => "waiting on a tool",
      "timeout_seconds" => 60,
      "deadline_ms" => 1_700_000_000_000
    }
  end

  defp fingerprint_wait do
    %{
      "source" => "auto_wait",
      "reason" => "auto",
      "timeout_seconds" => 30,
      "deadline_ms" => 1_700_000_000_123,
      "tool_call_ids" => ["call-a", "call-b"]
    }
  end

  defp fixtures do
    [
      {"idle empty", base()},
      {"active thinking", base(%{status: :active, activity_status: :thinking})},
      {"active messaging", base(%{status: :active, activity_status: :messaging})},
      {"active unknown activity", base(%{status: :active, activity_status: :waiting})},
      {"idle waiting", base(%{wait: wait_for_wait()})},
      {"idle waiting fingerprint", base(%{wait: fingerprint_wait()})},
      {"idle waiting invalid id", base(%{wait: %{"wait_id" => 7, "source" => "wait_for"}})},
      {"legacy retry",
       base(%{
         storage_format: 1,
         next_message_id: 3,
         events: [
           %{
             "kind" => "llm_call_failed",
             "event" => %{"transcript_hwm" => 2, "retry_at_ms" => 9_000}
           }
         ]
       })},
      {"legacy retry stale",
       base(%{
         storage_format: 1,
         next_message_id: 5,
         events: [
           %{
             "kind" => "llm_call_failed",
             "event" => %{"transcript_hwm" => 2, "retry_at_ms" => 9_000}
           }
         ]
       })},
      {"legacy terminal failure",
       base(%{
         storage_format: 1,
         next_message_id: 3,
         events: [
           %{
             "kind" => "llm_call_failed",
             "event" => %{"transcript_hwm" => 2, "retryable" => false}
           }
         ]
       })},
      {"legacy failures at cap",
       base(%{
         storage_format: 1,
         next_message_id: 2,
         events:
           List.duplicate(
             %{"kind" => "llm_call_failed", "event" => %{"transcript_hwm" => 1}},
             3
           )
       })},
      {"format 3 retry",
       base(%{
         storage_format: 3,
         next_message_id: 4,
         llm_failure_streak: %{"count" => 1, "hwm" => 3, "retry_at_ms" => 12_345}
       })},
      {"format 3 terminal failure",
       base(%{
         storage_format: 3,
         next_message_id: 4,
         llm_failure_streak: %{"count" => 1, "hwm" => 3, "terminal" => true}
       })},
      {"repair required",
       base(%{visible_reply_repair: %{"status" => "required", "attempts" => 1}})},
      {"repair exhausted", base(%{visible_reply_repair: %{"status" => "exhausted"}})},
      {"runaway at cap", base(%{next_message_id: 4, runaway_unsettled_streak: %{"count" => 2}})},
      {"runaway acked",
       base(%{
         next_message_id: 4,
         last_ack_message_id: 3,
         runaway_unsettled_streak: %{"count" => 2}
       })},
      {"repeated at cap",
       base(%{
         next_message_id: 4,
         repeated_tool_result_streak: %{"count" => 5, "tool_name" => "search"}
       })},
      {"repeated non binary tool",
       base(%{next_message_id: 4, repeated_tool_result_streak: %{"count" => 5, "tool_name" => 7}})},
      {"round budget below cap",
       base(%{next_message_id: 4, input_round_streak: %{"count" => 119}})},
      {"round budget at cap", base(%{next_message_id: 4, input_round_streak: %{"count" => 120}})},
      {"round budget acked",
       base(%{next_message_id: 4, last_ack_message_id: 3, input_round_streak: %{"count" => 120}})},
      {"assistant tail",
       base(%{next_message_id: 3, messages: [user_message(1), assistant_message(2)]})},
      {"tool tail",
       base(%{
         next_message_id: 4,
         messages: [
           user_message(1),
           assistant_message(2, %{tool_calls: [%{"id" => "c"}]}),
           tool_message(3)
         ]
       })},
      {"no-wake tool tail",
       base(%{
         next_message_id: 4,
         messages: [user_message(1), assistant_message(2), tool_message(3, %{no_wake: true})]
       })},
      {"string keyed tool tail",
       base(%{
         next_message_id: 4,
         messages: [%{"id" => 3, "role" => "tool", "content" => "x"}]
       })},
      {"string keyed no-wake tool tail",
       base(%{
         next_message_id: 4,
         messages: [%{"id" => 3, "role" => "tool", "content" => "x", "no_wake" => true}]
       })},
      {"runtime tail",
       base(%{next_message_id: 4, messages: [user_message(1), runtime_message(3)]})},
      {"terminal reply tail",
       base(%{
         next_message_id: 4,
         last_ack_message_id: 3,
         terminal_reply_ack_hwm: 3,
         messages: [tool_message(3)]
       })},
      {"queue wake user",
       base(%{
         next_queue_id: 3,
         input_queue: [
           queue_item(1, "user_message", %{
             "content" => "hi",
             "trusted_origin" => slack_origin(),
             "source_message_id" => "slack-1"
           })
         ]
       })},
      {"queue mixed ordering",
       base(%{
         next_queue_id: 6,
         queue_ack_id: 1,
         input_queue: [
           queue_item(5, "user_message", %{
             "content" => "second",
             "trusted_origin" => slack_origin()
           }),
           queue_item(1, "user_message", %{"content" => "acked"}),
           queue_item(3, "runtime_message", %{"type" => "wait_expired", "wait_id" => "wait-abc"}),
           queue_item(2, "user_message", %{"content" => "context"}, %{"wake" => false})
         ]
       })},
      {"runtime consume after human input",
       base(%{
         next_message_id: 3,
         next_queue_id: 4,
         messages: [
           user_message(2, %{trusted_origin: slack_origin(), source_message_id: "slack-1"})
         ],
         input_queue: [
           queue_item(1, "user_message", %{
             "content" => "queued human",
             "trusted_origin" => slack_origin()
           }),
           queue_item(2, "runtime_message", %{
             "type" => "tool_call_completed",
             "trusted_origin" => slack_origin(),
             "runtime_message_id" => "rt-inherited"
           }),
           queue_item(3, "runtime_message", %{
             "type" => "tool_call_completed",
             "trusted_origin" => %{"provider" => "slack", "source_message_id" => "other"},
             "runtime_message_id" => "rt-foreign"
           })
         ]
       })},
      {"activation retry budget",
       base(%{
         storage_format: 3,
         next_message_id: 3,
         next_queue_id: 3,
         llm_failure_streak: %{"count" => 3, "hwm" => 2},
         messages: [
           user_message(2, %{trusted_origin: slack_origin(), source_message_id: "slack-1"})
         ],
         input_queue: [
           queue_item(1, "user_message", %{
             "content" => "queued",
             "trusted_origin" => slack_origin()
           })
         ]
       })},
      {"activation retry consumed",
       base(%{
         storage_format: 3,
         next_message_id: 3,
         next_queue_id: 3,
         llm_failure_streak: %{"count" => 3, "hwm" => 2},
         messages: [
           user_message(2, %{trusted_origin: slack_origin(), source_message_id: "slack-1"})
         ],
         input_queue: [
           queue_item(
             1,
             "user_message",
             %{"content" => "queued", "trusted_origin" => slack_origin()},
             %{"activation_retry_consumed" => true}
           )
         ]
       })},
      {"yieldable provider wait",
       base(%{
         next_message_id: 3,
         next_queue_id: 3,
         last_ack_message_id: 0,
         wait: wait_for_wait(),
         messages: [
           user_message(2, %{trusted_origin: slack_origin(), source_message_id: "slack-1"})
         ],
         input_queue: [
           queue_item(1, "user_message", %{
             "content" => "queued",
             "trusted_origin" => slack_origin()
           })
         ]
       })},
      {"plain obligation",
       base(%{
         provider_reply_obligations: %{
           "k2" => %{"provider" => "slack", "key" => "k2", "channel" => "C"}
         }
       })},
      {"async running",
       base(%{async_tool_calls: %{"call-1" => %{"status" => "running", "tool_name" => "search"}}})},
      {"async external callback",
       base(%{
         async_tool_calls: %{
           "call-1" => %{"status" => "running", "completion_mode" => "external_callback"}
         }
       })},
      {"async completed",
       base(%{
         async_tool_calls: %{},
         async_results: [
           %{
             "seq" => 4,
             "tool_call_id" => "call-1",
             "result_ref" => "trf1_0000000000000000001",
             "status" => "completed"
           }
         ],
         async_result_refs: %{"call-1" => 4, "gone" => 9}
       })},
      {"context bytes live", base(%{live_context_bytes: 4_321})},
      {"observed prompt tokens fenced",
       base(%{
         summary_sequence: 2,
         compacted_through: 5,
         next_message_id: 4,
         messages: [
           assistant_message(3, %{
             input_tokens: 90_000,
             request_summary_sequence: 2,
             request_compacted_through: 5
           })
         ]
       })},
      {"observed prompt tokens stale",
       base(%{
         summary_sequence: 3,
         compacted_through: 5,
         next_message_id: 4,
         messages: [
           assistant_message(3, %{
             input_tokens: 90_000,
             request_summary_sequence: 2,
             request_compacted_through: 5
           })
         ]
       })},
      {"observed prompt tokens legacy",
       base(%{
         next_message_id: 4,
         messages: [assistant_message(3, %{input_tokens: 500})]
       })},
      {"redactions",
       base(%{
         next_message_id: 6,
         last_seq: 12,
         compacted_seq: 2,
         messages: [
           %{id: 1, seq: 3, role: "tool", content: "big tool output"},
           %{id: 2, seq: 4, role: "user", content: String.duplicate("x", 64)},
           %{"id" => 3, "seq" => 5, "role" => "assistant", "content" => "kept"},
           %{id: 4, seq: 6, role: "tool", content: "later"}
         ],
         redactions: [
           %{"seq" => 4, "replacement" => "[redacted by seq]"},
           %{"message_id" => 4, "replacement" => "[redacted by id]"},
           %{"kind" => "tool_messages_through", "through_id" => 2, "replacement" => "[tool]"},
           %{
             "kind" => "non_model_messages_over_bytes_through",
             "through_id" => 3,
             "max_bytes" => 8,
             "replacement" => "[too big]"
           }
         ]
       })},
      {"redaction predicates without ids",
       base(%{
         next_message_id: 4,
         messages: [
           %{role: "tool", content: "no id at all"},
           %{id: 2.0, role: "tool", content: "float id"},
           %{id: 2, role: "tool", content: nil}
         ],
         redactions: [
           %{"kind" => "tool_messages_through", "through_id" => 5, "replacement" => "[tool]"},
           %{"seq" => "4", "replacement" => "[ignored non integer seq]"},
           %{"message_id" => nil, "replacement" => "[ignored nil id]"}
         ]
       })},
      {"catalog",
       base(%{
         messages: [user_message(1), user_message(2)],
         archive_chunks: [[1, 5, 4, 0, 100], [6, 9, 3, 100, 50]],
         segment_catalog: [[10, 20, 7, 150, 60]]
       })}
    ]
  end

  defp fixture(label) do
    {^label, state} = Enum.find(fixtures(), fn {name, _} -> name == label end)
    state
  end

  test "the fixtures reach every interesting answer" do
    answer = fn label, query -> ask(fixture(label), query) end

    assert answer.("idle empty", :derived_state) == :paused
    assert answer.("active thinking", :derived_state) == :active
    assert answer.("queue wake user", :derived_state) == :queued
    assert answer.("idle waiting", :derived_state) == :waiting
    assert answer.("format 3 retry", :derived_state) == :waiting
    assert answer.("tool tail", :derived_state) == :queued

    assert answer.("active messaging", :activity_status) == :messaging
    assert answer.("active unknown activity", :activity_status) == :thinking
    assert answer.("idle waiting", :activity_status) == :waiting
    assert answer.("repair exhausted", :activity_status) == :failed
    assert answer.("legacy terminal failure", :activity_issue) == "model_connection_failed"
    assert answer.("runaway at cap", :activity_issue) == "runaway_guard_parked"
    assert answer.("repeated at cap", :activity_issue) == "repeated_tool_result_parked"
    assert answer.("repair exhausted", :activity_issue) == "visible_reply_repair_exhausted"
    assert answer.("idle empty", :monitored_activity_signature) == :stopped
    assert answer.("idle waiting", :monitored_activity_signature) == :active

    assert answer.("repair exhausted", :monitored_activity_signature) ==
             {:error, "visible_reply_repair_exhausted"}

    assert answer.("legacy retry", :llm_retry_at_ms) == 9_000
    assert answer.("legacy retry stale", :llm_retry_at_ms) == nil
    assert answer.("format 3 retry", :recovery_wait) == %{"deadline_ms" => 12_345}
    assert answer.("idle waiting", :recovery_wait) == wait_for_wait()
    assert answer.("legacy failures at cap", :consecutive_llm_failures) == 3
    assert answer.("legacy failures at cap", :llm_failures_exhausted?) == true
    assert answer.("format 3 terminal failure", :llm_failure_terminal?) == true
    assert answer.("runaway at cap", :consecutive_unsettled_rounds) == 2
    assert answer.("runaway acked", :consecutive_unsettled_rounds) == 0
    assert answer.("repeated at cap", :repeated_tool_result_tool) == "search"
    assert answer.("round budget below cap", :rounds_since_fresh_input) == 119
    assert answer.("round budget below cap", :input_round_budget_exhausted?) == false
    assert answer.("round budget at cap", :input_round_budget_exhausted?) == true
    assert answer.("round budget at cap", :activity_issue) == "input_round_budget_parked"
    assert answer.("round budget acked", :rounds_since_fresh_input) == 0
    assert answer.("repeated non binary tool", :repeated_tool_result_tool) == nil

    assert answer.("idle waiting", :wait_identity) == {:ok, "wait-abc"}
    assert answer.("idle waiting invalid id", :wait_identity) == {:error, :invalid_wait}
    assert answer.("idle empty", :wait_identity) == nil
    {:ok, fingerprint} = answer.("idle waiting fingerprint", :wait_identity)
    assert String.starts_with?(fingerprint, "fingerprint-")
    assert byte_size(fingerprint) == byte_size("fingerprint-") + 16
    assert {:ok, fingerprint} == Waits.identity(fingerprint_wait())

    assert answer.("catalog", :total_message_count) == 16
    assert answer.("context bytes live", :context_byte_size) == 4_321
    assert answer.("context bytes live", :estimated_tokens) == 1_080
    assert answer.("observed prompt tokens fenced", :observed_prompt_tokens) == 90_000
    assert answer.("observed prompt tokens stale", :observed_prompt_tokens) == 0
    assert answer.("observed prompt tokens legacy", :observed_prompt_tokens) == 500

    assert answer.("tool tail", :needs_transcript_continuation?) == true
    assert answer.("no-wake tool tail", :needs_transcript_continuation?) == false
    assert answer.("string keyed tool tail", :needs_transcript_continuation?) == true
    assert answer.("string keyed no-wake tool tail", :needs_transcript_continuation?) == false
    assert answer.("assistant tail", :pending_assistant_id) == 2
    assert answer.("assistant tail", :decision_required?) == true
    assert answer.("terminal reply tail", :needs_transcript_continuation?) == false
    assert answer.("runtime tail", :consecutive_timeouts) == 1

    assert answer.("yieldable provider wait", :yieldable_provider_wait?) == true
    assert answer.("idle waiting", :yieldable_provider_wait?) == false
    assert answer.("yieldable provider wait", :active_human_source_ids) == ["slack-1"]

    assert answer.("queue wake user", :work_reasons) == ["unacked_queue_item"]
    assert answer.("async running", :work_reasons) == ["process_local_background_tool_run"]

    assert answer.("async external callback", :work_reasons) == [
             "external_callback_tool_call",
             "capability_deadline"
           ]

    assert answer.("plain obligation", :work_reasons) == ["provider_reply_obligation"]

    assert [_, %{content: "[redacted by seq]"}, _, %{content: "[redacted by id]"}] =
             answer.("redactions", :masked_messages)

    assert [%{content: "[tool]"} | _] = answer.("redactions", :masked_messages)

    # A non-integer id never reaches a redaction predicate, even when its term
    # order would satisfy the watermark.
    assert answer.("redaction predicates without ids", :masked_messages) == [
             %{role: "tool", content: "no id at all"},
             %{id: 2.0, role: "tool", content: "float id"},
             %{id: 2, role: "tool", content: "[tool]"}
           ]

    {events, wake?, hwm} = answer.("queue mixed ordering", :materialize_pending_input_events)
    assert wake? == true
    assert hwm == 3

    assert Enum.map(events, & &1["type"]) == [
             "delivery",
             "runtime_message",
             "delivery",
             "queue_ack"
           ]

    {consume_events, true, 3} =
      answer.("runtime consume after human input", :materialize_pending_input_events)

    assert Enum.map(consume_events, & &1["type"]) == ["runtime_message", "queue_consume"]
    assert List.last(consume_events)["queue_id"] == 2

    assert answer.("activation retry budget", :materialize_pending_input_events) ==
             {[
                %{
                  "type" => "session_event",
                  "session_id" => "session-1",
                  "kind" => "provider_activation_retry",
                  "event" => %{"queue_id" => 1}
                }
              ], true, 0}

    assert answer.("activation retry consumed", :materialize_pending_input_events) ==
             {[], false, 0}

    assert ask(fixture("context bytes live"), :should_compact?, {nil, 8}) == false
    assert ask(fixture("context bytes live"), :should_compact?, {nil, 4_096}) == false
    assert ask(fixture("context bytes live"), :should_compact?, {10_000_000, nil}) == false
    assert ask(fixture("repair required"), :should_compact?, {0, nil}) == false

    assert ask(fixture("async completed"), :lookup_async_call, "call-1") ==
             {:ok,
              %{
                "seq" => 4,
                "tool_call_id" => "call-1",
                "result_ref" => "trf1_0000000000000000001",
                "status" => "completed"
              }}

    assert ask(fixture("async completed"), :lookup_async_call, "gone") == {:archived, 9}
    assert ask(fixture("async completed"), :lookup_async_call, "nope") == :not_found
  end

  test "provider_wait_yield_events refuses a stale snapshot" do
    state = fixture("yieldable provider wait")
    assert ask(state, :provider_wait_yield_events, expected_snapshot(state)) != []

    stale = %{expected_snapshot(state) | "next_message_id" => 99}
    assert ask(state, :provider_wait_yield_events, stale) == []

    other = %{expected_snapshot(state) | "active_human_source_ids" => ["someone-else"]}
    assert ask(state, :provider_wait_yield_events, other) == []

    replaced = %{expected_snapshot(state) | "wait_identity" => {:ok, "wait-other"}}
    assert ask(state, :provider_wait_yield_events, replaced) == []
  end

  test "should_compact? reads the configured threshold when none is supplied" do
    state = fixture("context bytes live")
    previous = Application.get_env(:salix_agent, :compaction_threshold)

    try do
      Application.put_env(:salix_agent, :compaction_threshold, 10)
      assert ask(state, :should_compact?, {nil, nil}) == true

      Application.put_env(:salix_agent, :compaction_threshold, 1_000_000)
      assert ask(state, :should_compact?, {nil, nil}) == false
    after
      if is_nil(previous) do
        Application.delete_env(:salix_agent, :compaction_threshold)
      else
        Application.put_env(:salix_agent, :compaction_threshold, previous)
      end
    end
  end
end
