defmodule SalixVerifiedKernel.RunawayRetirementTest do
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel.Session

  defp origin(actor, source) do
    %{
      "provider" => "slack",
      "source_actor_type" => actor,
      "source_message_id" => source,
      "provider_context" => %{
        "connect_id" => "slack",
        "channel_id" => "channel",
        "thread_ts" => "thread"
      }
    }
  end

  defp parked(actor) do
    Session.new("agent", "session")
    |> Session.export()
    |> Map.merge(%{
      status: :idle,
      activity_status: :failed,
      next_message_id: 4,
      last_seq: 3,
      runaway_unsettled_streak: %{"count" => 2},
      active_source_message_ids: ["old"],
      messages: [
        %{
          id: 1,
          seq: 1,
          role: "user",
          source_message_id: "old",
          trusted_origin: origin(actor, "old")
        },
        %{id: 2, seq: 2, role: "assistant", content: "Done", tool_calls: []},
        %{id: 3, seq: 3, role: "assistant", content: "No reply needed", tool_calls: []}
      ],
      provider_reply_obligations: %{
        "reminder" => %{
          "key" => "reminder",
          "provider" => "slack",
          "connect_id" => "slack",
          "channel" => "channel",
          "thread_ts" => "thread"
        },
        "card" => %{
          "key" => "card",
          "kind" => "task_card",
          "provider" => "slack",
          "conversation_id" => "task"
        }
      },
      input_queue: [
        %{
          "queue_id" => 1,
          "kind" => "user_message",
          "wake" => true,
          "dedupe_key" => "next",
          "created_at" => 123,
          "payload" => %{
            "source_message_id" => "next",
            "role" => "user",
            "content" => "Next request",
            "trusted_origin" => origin("provider_user", "next")
          }
        }
      ],
      next_queue_id: 2
    })
    |> Session.open()
  end

  for actor <- ["provider_user", "provider_system", "unknown"] do
    test "#{actor}: cold recovery abandons current replies, not queued human input" do
      {:ok, session} = Session.load(Session.persist(parked(unquote(actor))))
      assert Session.query(session, :materialize_pending_input_events, 100) == {[], false, 0}
      assert map_size(Session.get(session, :provider_reply_obligations)) == 2
      assert Session.query(session, :guard_disposition_pending?)
      events = Session.query(session, :runaway_retirement)
      assert is_list(events)
      refute Enum.any?(events, &(&1["type"] in ["assistant", "queue_ack", "queue_consume"]))
      retired = Session.apply_batch(session, events)
      assert Session.get(retired, :last_ack_message_id) == 3
      assert Session.get(retired, :queue_ack_id) == 0
      assert length(Session.get(retired, :input_queue)) == 1
      assert Session.get(retired, :provider_reply_obligations) == %{}
      assert Session.get(retired, :runtime_failure_reply) == nil
      assert Session.query(retired, :runaway_retirement) == nil
      fact = List.last(Session.get(retired, :events))
      assert fact["kind"] == "runtime_runaway_retired"
      assert fact["event"]["outcome"] == "blocked"
      assert length(fact["event"]["abandoned_reply_obligations"]) == 2
      assert fact["event"]["consecutive_unsettled_rounds"] == 2

      {:ok, retired} = Session.load(Session.persist(retired))
      {next_events, true, _} = Session.query(retired, :materialize_pending_input_events, 100)
      next = Session.apply_batch(retired, next_events)
      assert Session.get(next, :last_ack_message_id) == 3
      assert Session.get(next, :next_message_id) == 5
      assert "next" in Session.query(next, :current_source_ids)
      refute Session.query(next, :runaway_unsettled_rounds_exhausted?)
      assert Session.query(next, :runaway_retirement) == nil
    end
  end

  test "accepted async work remains live while reply work is explicitly abandoned" do
    original = parked("provider_user") |> Session.export()

    calls = %{
      "local" => %{"status" => "running", "trusted_origin" => origin("provider_user", "old")},
      "callback" => %{
        "status" => "running",
        "completion_mode" => "external_callback",
        "trusted_origin" => origin("provider_user", "old")
      }
    }

    state =
      Map.merge(original, %{
        async_tool_calls: calls,
        visible_reply_intent: %{"idempotency_key" => "send", "scope" => %{}},
        visible_reply_repair: %{"status" => "required"},
        wait: %{"source" => "wait_for", "reason" => "accepted work"}
      })

    session = Session.open(state)
    events = Session.query(session, :runaway_retirement)
    retired = Session.apply_batch(session, events)
    assert Session.get(retired, :async_tool_calls) == calls
    assert Session.get(retired, :visible_reply_intent) == nil
    assert Session.get(retired, :visible_reply_repair) == nil
    assert Session.get(retired, :wait) == nil
    assert Session.get(retired, :last_ack_message_id) == 3
    assert Session.get(retired, :input_queue) == state.input_queue
  end

  test "one reflection, a settled turn, and other guards are not runaway retirement" do
    state = parked("provider_system") |> Session.export()

    for patch <- [
          %{runaway_unsettled_streak: %{"count" => 1}},
          %{last_ack_message_id: 3},
          %{runaway_unsettled_streak: nil, repeated_tool_result_streak: %{"count" => 5}},
          %{runaway_unsettled_streak: nil, input_round_streak: %{"count" => 120}}
        ] do
      assert Session.query(Session.open(Map.merge(state, patch)), :runaway_retirement) == nil
    end
  end
end
