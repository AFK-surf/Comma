defmodule SalixVerifiedKernel.LocalFailureSettlementTest do
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel.Session

  defp stopped(patch \\ %{}) do
    Session.new("agent", "session")
    |> Session.export()
    |> Map.merge(%{
      status: :idle,
      next_message_id: 3,
      last_seq: 2,
      repeated_tool_result_streak: %{"count" => 5},
      messages: [
        %{id: 1, seq: 1, role: "user", content: "notice", source_message_id: "old"},
        %{id: 2, seq: 2, role: "assistant", content: "stopped", tool_calls: []}
      ]
    })
    |> Map.merge(patch)
    |> Session.open()
  end

  test "no-destination failure retires locally without a notification" do
    {:ok, state} = Session.load(Session.persist(stopped()))
    events = Session.query(state, :guard_failure_local_settlement)
    assert is_list(events)
    refute Enum.any?(events, &(&1["type"] in ["assistant", "queue_ack", "queue_consume"]))
    retired = Session.apply_batch(state, events)
    assert Session.get(retired, :last_ack_message_id) == 2
    assert Session.query(retired, :guard_failure_local_settlement) == nil
    fact = Enum.find(events, &(&1["kind"] == "runtime_failure_disposed"))
    assert fact["event"]["notification_outcome"] == "unavailable"
    assert fact["event"]["outcome"] == "blocked"
  end

  test "non-runaway fallback cannot abandon blocking cards or pending visible commits" do
    for patch <- [
          %{
            provider_reply_obligations: %{
              "card" => %{
                "kind" => "task_card",
                "provider" => "slack",
                "conversation_id" => "task"
              }
            }
          },
          %{visible_reply_intent: %{"idempotency_key" => "pending", "scope" => %{}}}
        ] do
      assert Session.query(stopped(patch), :guard_failure_local_settlement) == nil
    end
  end

  test "runaway uses its existing stronger retirement path, never the local fallback" do
    state = stopped(%{runaway_unsettled_streak: %{"count" => 2}})
    assert Session.query(state, :guard_failure_local_settlement) == nil
    assert is_list(Session.query(state, :runaway_retirement))
  end
end
