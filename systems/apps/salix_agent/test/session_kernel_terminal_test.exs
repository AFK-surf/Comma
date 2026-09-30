defmodule SalixAgent.SessionKernelTerminalTest do
  use ExUnit.Case, async: true

  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.TestSupport.SessionData
  alias SalixAgent.InternalSession.State

  @statuses ["completed", "failed", "cancelled"]
  @copied_fields ~w(result error error_class error_message diagnostic_visibility public_summary visible_reply_origin duration_ms completed_at cancelled_at cancel_reason)

  defp state(calls) do
    %State{
      agent_id: "agent-terminal",
      session_id: "session-terminal",
      status: :active,
      activity_status: :thinking,
      async_tool_calls: calls,
      async_results: [%{"kind" => "retained", "seq" => 4}],
      async_result_refs: %{"retained" => 4, "selected" => 2},
      last_seq: 10,
      messages: [%{"content" => "retained", "measurements" => [1.25, -0.0]}],
      billing_context: %{"nested" => [%{"ratio" => 0.125}]},
      storage_revision: "revision-terminal"
    }
  end

  defp event(status, id, fields \\ %{}) do
    Map.merge(
      %{
        "type" => "async_tool_call_#{status}",
        "session_id" => "session-terminal",
        "tool_call_id" => id
      },
      fields
    )
  end

  defp assert_done(before, ev, expected) do
    assert Driver.step(before, ev) === {:done, expected}
    assert SessionData.apply_event(before, ev) === expected
  end

  test "each terminal event moves the exact settled record and preserves all other state" do
    record = %{
      "status" => "running",
      "kind" => "old-kind",
      "tool_call_id" => "old-id",
      "seq" => 900,
      "input" => %{"weight" => [1.25, -0.0]},
      "progress" => %{"fraction" => 0.5},
      "unrelated" => "retained"
    }

    copied = Map.new(@copied_fields, &{&1, %{"field" => &1, "payload" => [0.125]}})
    other = %{"status" => "running", "input" => [2.5]}
    before = state(%{"selected" => record, "other" => other})

    for status <- @statuses do
      ev =
        event(
          status,
          "selected",
          Map.merge(copied, %{
            "kind" => "ignored",
            "seq" => -9,
            "status" => "ignored",
            "unrelated" => "ignored",
            "updated_at" => 999
          })
        )

      settled =
        record
        |> Map.merge(copied)
        |> Map.merge(%{
          "status" => status,
          "kind" => "async_result",
          "tool_call_id" => "selected",
          "seq" => 11
        })

      expected = %State{
        before
        | async_tool_calls: %{"other" => other},
          async_results: before.async_results ++ [settled],
          async_result_refs: %{"retained" => 4, "selected" => 11},
          last_seq: 11
      }

      assert_done(before, ev, expected)
      assert_done(expected, ev, expected)
    end
  end

  test "present nil and false overwrite copied fields while absent fields stay intact" do
    for status <- @statuses, replacement <- [nil, false] do
      record = Map.merge(Map.new(@copied_fields, &{&1, "old"}), %{"status" => "running"})
      before = state(%{"selected" => record})
      fields = Map.new(@copied_fields, &{&1, replacement})

      after_state =
        SessionData.apply_event(before, event(status, "selected", fields))

      settled = List.last(after_state.async_results)
      assert Map.take(settled, @copied_fields) === fields

      absent = SessionData.apply_event(before, event(status, "selected"))

      assert Map.take(List.last(absent.async_results), @copied_fields) ===
               Map.take(record, @copied_fields)
    end
  end

  test "terminal and missing selections are lazy no-ops even with unusable settlement fields" do
    containers =
      [%{}, %{"selected" => nil}] ++
        Enum.map(@statuses, &%{"selected" => %{"status" => &1}}) ++ [nil, false]

    for status <- @statuses, calls <- containers do
      before = %State{
        state(calls)
        | async_results: :invalid_results,
          async_result_refs: :invalid_refs,
          last_seq: :invalid_seq
      }

      assert_done(before, event(status, "selected"), before)
    end
  end

  test "false and other non-map selected records still raise rather than silently disappear" do
    for status <- @statuses, record <- [false, [], 1.25, :invalid_record] do
      before = state(%{"selected" => record})
      ev = event(status, "selected")
      assert_raise BadMapError, fn -> SessionData.apply_event(before, ev) end
      assert_raise BadMapError, fn -> Driver.step(before, ev) end
    end
  end

  test "falsey history references and sequence retain their native empty defaults" do
    for fallback <- [nil, false] do
      before = %State{
        state(%{"selected" => %{}})
        | async_results: fallback,
          async_result_refs: fallback,
          last_seq: fallback
      }

      expected_record = %{
        "status" => "completed",
        "kind" => "async_result",
        "tool_call_id" => "selected",
        "seq" => 1
      }

      expected = %State{
        before
        | async_tool_calls: %{},
          async_results: [expected_record],
          async_result_refs: %{"selected" => 1},
          last_seq: 1
      }

      assert_done(before, event("completed", "selected"), expected)
    end
  end

  test "pure-data identities preserve exact native keys" do
    for id <- [nil, [], 7, 1.25, %{"identity" => true}] do
      before = state(%{id => %{"status" => "unknown"}})
      ev = event("completed", id)
      assert {:done, after_state} = Driver.step(before, ev)
      assert SessionData.apply_event(before, ev) === after_state
      assert after_state.async_tool_calls === %{}
      assert Map.fetch!(after_state.async_result_refs, id) === 11
      assert List.last(after_state.async_results)["tool_call_id"] === id
    end

    before = state(%{nil => %{}})

    assert SessionData.apply_event(
             before,
             Map.delete(event("completed", nil), "tool_call_id")
           ) ===
             SessionData.apply_event(before, event("completed", nil))
  end

  test "runtime sequence arithmetic preserves float and negative integer behavior" do
    for {previous, next} <- [{1.25, 2.25}, {-3, -2}] do
      before = %State{state(%{"selected" => %{}}) | last_seq: previous}
      ev = event("completed", "selected")
      assert {:done, after_state} = Driver.step(before, ev)
      assert SessionData.apply_event(before, ev) === after_state
      assert after_state.last_seq === next
      assert after_state.async_result_refs["selected"] === next
      assert List.last(after_state.async_results)["seq"] === next
    end
  end

  test "the wrapper retains its Session identity fence before terminal dispatch" do
    before = state(%{"selected" => %{}})
    ev = event("completed", "selected", %{"session_id" => "another-session"})
    assert SessionData.apply_event(before, ev) === before
  end

  test "non-binary terminal-like statuses still settle rather than skip the event" do
    for previous_status <- [
          :completed,
          :failed,
          :cancelled,
          ~c"completed",
          ~c"failed",
          ~c"cancelled"
        ] do
      before = state(%{"selected" => %{"status" => previous_status}})
      ev = event("completed", "selected")
      assert {:done, after_state} = Driver.step(before, ev)
      assert SessionData.apply_event(before, ev) === after_state
      assert after_state.async_tool_calls === %{}
      assert after_state.last_seq === 11
      assert List.last(after_state.async_results)["status"] === "completed"
    end
  end

  test "settlement rejects non-list and improper result histories but preserves proper list entries" do
    for history <- [:invalid_results, 1.25, [%{"seq" => 4} | :invalid_tail]] do
      before = %State{state(%{"selected" => %{}}) | async_results: history}
      ev = event("completed", "selected")
      assert_raise ArgumentError, fn -> SessionData.apply_event(before, ev) end
      assert_raise ArgumentError, fn -> Driver.step(before, ev) end
    end

    for history <- [[], [nil, false, 1.25, %{"seq" => 4}]] do
      before = %State{state(%{"selected" => %{}}) | async_results: history}
      ev = event("completed", "selected")
      assert {:done, after_state} = Driver.step(before, ev)
      assert SessionData.apply_event(before, ev) === after_state
      assert Enum.drop(after_state.async_results, -1) === history
      assert List.last(after_state.async_results)["seq"] === 11
    end
  end

  test "an empty reference list is truthy and retains its native bad-map error" do
    before = %State{state(%{"selected" => %{}}) | async_result_refs: []}
    ev = event("completed", "selected")
    assert_raise BadMapError, fn -> SessionData.apply_event(before, ev) end
    assert_raise BadMapError, fn -> Driver.step(before, ev) end
  end

  test "background terminals update the business-outcome fingerprint once" do
    record = %{"tool_name" => "query", "input" => %{"x" => 1}, "status" => "running"}
    before = state(%{"selected" => record})

    ev =
      event("failed", "selected", %{
        "error_class" => "failure",
        "error_message" => "same",
        "result" => %{"content" => "done", "output" => "done"}
      })

    assert {:done, expected} = Driver.step(before, ev)
    assert expected.repeated_tool_result_streak["count"] == 1
    assert_done(before, ev, expected)
    assert_done(expected, ev, expected)
  end
end
