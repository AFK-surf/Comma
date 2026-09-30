defmodule SalixAgent.SessionKernelEventTest do
  use ExUnit.Case, async: false
  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.InternalSession.State
  alias SalixAgent.VisibleReplyScope

  defp event(kind, extra \\ %{}) do
    Map.merge(%{"type" => "session_event", "kind" => kind}, extra)
  end

  defp outcome(fun) do
    try do
      {:returned, fun.()}
    catch
      kind, reason -> {:raised, kind, Exception.normalize(kind, reason, __STACKTRACE__)}
    end
  end

  defp check(state, event) do
    outcome(fn ->
      {:done, next} = Driver.step(state, event)
      next
    end)
  end

  test "ordinary fact asserts all eight writes while preserving unrelated State fields" do
    initial = %State{
      events: [%{"old" => true}],
      last_seq: 10,
      llm_failure_streak: %{"count" => 9},
      input_queue: :unvisited_queue,
      runaway_unsettled_streak: %{"count" => 7},
      visible_reply_egress_facts: false,
      terminal_reply_ack_hwm: 6,
      last_activity_at: "old"
    }

    ev =
      event("ordinary", %{
        "created_at" => "new",
        "stale" => false,
        "event" => nil,
        "not_copied" => 1
      })

    assert {:returned, next} = check(initial, ev)
    fact = %{"kind" => "ordinary", "created_at" => "new", "stale" => false, "seq" => 11}
    assert next.events === initial.events ++ [fact]
    assert next.last_seq === 11
    assert next.llm_failure_streak === nil
    assert next.input_queue === :unvisited_queue
    assert next.runaway_unsettled_streak === initial.runaway_unsettled_streak
    assert next.visible_reply_egress_facts === %{}
    assert next.terminal_reply_ack_hwm === 6
    assert next.last_activity_at === "new"

    written = [
      :events,
      :last_seq,
      :llm_failure_streak,
      :input_queue,
      :runaway_unsettled_streak,
      :visible_reply_egress_facts,
      :terminal_reply_ack_hwm,
      :last_activity_at
    ]

    assert Map.drop(next, written) === Map.drop(initial, written)
  end

  test "nil-only fact omission and false timestamp fallback remain distinct" do
    for timestamp <- [nil, false] do
      initial = %State{events: false, last_seq: false, last_activity_at: "old"}
      assert {:returned, next} = check(initial, event("ordinary", %{"created_at" => timestamp}))
      assert next.last_seq === 1
      assert next.last_activity_at === "old"
      assert Map.has_key?(hd(next.events), "created_at") === (timestamp === false)
    end
  end

  test "failure HWM aliases false handling and terminal key presence" do
    payloads = [
      {%{"transcript_hwm" => 4, "retryable" => false}, 4, true},
      {%{transcript_hwm: 4, retryable: false}, 4, true},
      {%{"transcript_hwm" => false, :transcript_hwm => false}, 0, false},
      {%{"transcript_hwm" => 4, "retryable" => nil, :retryable => false}, 4, false}
    ]

    for {payload, hwm, terminal} <- payloads do
      assert {:returned, next} = check(%State{}, event("llm_call_failed", %{"event" => payload}))
      assert next.llm_failure_streak === %{"count" => 1, "hwm" => hwm, "terminal" => terminal}
    end

    assert {:returned, absent} = check(%State{}, event("llm_call_failed"))
    assert absent.llm_failure_streak === %{"count" => 0, "hwm" => nil}
  end

  test "streak HWM binding is strict while native integer conversion remains intact" do
    for {old_hwm, expected_count} <- [{4, 3}, {4.0, 1}] do
      initial = %State{llm_failure_streak: %{"count" => 2, "hwm" => old_hwm}}

      assert {:returned, next} =
               check(
                 initial,
                 event("llm_call_failed", %{"event" => %{"transcript_hwm" => "4"}})
               )

      assert next.llm_failure_streak["count"] === expected_count
    end
  end

  test "runaway bump depends on unsettled transcript and reset is unconditional" do
    for {ack, expected} <- [{0, 4}, {4, 1}] do
      initial = %State{
        last_ack_message_id: ack,
        next_message_id: 5,
        runaway_unsettled_streak: %{"count" => 3}
      }

      assert {:returned, next} = check(initial, event("runaway_unsettled_round"))
      assert next.runaway_unsettled_streak === %{"count" => expected}
      assert {:returned, reset} = check(initial, event("runaway_guard_reset"))
      assert reset.runaway_unsettled_streak === %{"count" => 0}
    end
  end

  test "retry marking uses loose equality without queue normalization or reordering" do
    queue = [
      %{"queue_id" => "2", "tag" => "first"},
      %{queue_id: 1},
      %{"queue_id" => 2, "tag" => "last"}
    ]

    assert {:returned, next} =
             check(
               %State{input_queue: queue},
               event("provider_activation_retry", %{"event" => %{"queue_id" => 2.0}})
             )

    assert next.input_queue === [
             Map.put(hd(queue), "activation_retry_consumed", true),
             Enum.at(queue, 1),
             Map.put(List.last(queue), "activation_retry_consumed", true)
           ]
  end

  test "retry marks the matching plain queue item" do
    item = %{"queue_id" => 7}

    assert {:returned, next} =
             check(
               %State{input_queue: [item]},
               event("provider_activation_retry", %{"event" => %{"queue_id" => 7}})
             )

    assert next.input_queue === [Map.put(item, "activation_retry_consumed", true)]
  end

  test "a retry without the exact nested queue key leaves malformed queue unvisited" do
    initial = %State{input_queue: :not_enumerable}

    for payload <- [%{}, %{queue_id: 7}, nil, false] do
      assert {:returned, next} =
               check(
                 initial,
                 event("provider_activation_retry", %{"event" => payload})
               )

      assert next.input_queue === :not_enumerable
    end
  end

  test "terminal acknowledgment traverses the raw payload and preserves false" do
    for kind <- ["terminal_reply_delivered", "channel_onboarding_settled"],
        {payload, expected} <- [
          {nil, nil},
          {%{}, nil},
          {%{"settled_ack_hwm" => false}, false},
          {%{"settled_ack_hwm" => 8}, 8},
          {%{settled_ack_hwm: 8}, nil}
        ] do
      assert {:returned, next} =
               check(
                 %State{terminal_reply_ack_hwm: 3},
                 event(kind, %{"event" => payload})
               )

      assert next.terminal_reply_ack_hwm === expected
    end
  end

  test "positive egress writes the exact source-bound key and preserves prior facts" do
    for sources <- [
          [],
          ["source-a", "source-b"],
          ["source-b", "source-a"],
          ["source-a", "source-a"]
        ] do
      key = VisibleReplyScope.egress_ownership_key("group", "conversation", sources)

      payload = %{
        "ownership_key" => key,
        "agent_group_id" => "group",
        "conversation_id" => "conversation",
        "source_message_ids" => sources
      }

      initial = %State{visible_reply_egress_facts: %{"old" => :retained}}

      assert {:returned, next} =
               check(
                 initial,
                 event(
                   "visible_reply_egress",
                   %{
                     "source" => "script_host",
                     "method" => "im_api.internal.send_message",
                     "event" => payload
                   }
                 )
               )

      assert next.visible_reply_egress_facts === %{"old" => :retained, key => payload}
    end
  end

  test "negative egress key or shape retains nil false fallback and does not insert" do
    for old <- [nil, false, %{"old" => true}],
        payload <- [
          %{
            "ownership_key" => "wrong",
            "agent_group_id" => "group",
            "conversation_id" => "conversation",
            "source_message_ids" => ["source"]
          },
          %{
            "ownership_key" => "wrong",
            "agent_group_id" => false,
            "conversation_id" => "conversation",
            "source_message_ids" => ["source"]
          },
          %{"ownership_key" => false},
          nil
        ] do
      assert {:returned, next} =
               check(
                 %State{visible_reply_egress_facts: old},
                 event("visible_reply_egress", %{
                   "source" => "script_host",
                   "method" => "im_api.internal.send_message",
                   "event" => payload
                 })
               )

      assert next.visible_reply_egress_facts === (old || %{})
    end
  end
end
