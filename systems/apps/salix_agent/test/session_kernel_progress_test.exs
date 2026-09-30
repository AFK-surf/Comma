defmodule SalixAgent.SessionKernelProgressTest do
  use ExUnit.Case, async: true

  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.InternalSession.State
  alias SalixAgent.TestSupport.SessionData

  defp state(calls) do
    %State{
      agent_id: "agent-progress",
      session_id: "session-progress",
      status: :active,
      activity_status: :thinking,
      activity_status_updated_at: 10,
      async_tool_calls: calls,
      messages: [%{"content" => "retained", "measurements" => [1.25, -0.0]}],
      billing_context: %{"nested" => %{"ratio" => 0.125}},
      storage_revision: "revision-progress"
    }
  end

  defp event(id, fields \\ %{}) do
    Map.merge(
      %{
        "type" => "async_tool_call_progress",
        "session_id" => "session-progress",
        "tool_call_id" => id
      },
      fields
    )
  end

  test "the production wrapper preserves every field outside the selected record update" do
    record = %{"status" => "running", "input" => %{"weight" => 2.5}, "started_at" => 1}
    other = %{"status" => "running", "progress" => %{"fraction" => 0.75}}
    before = state(%{"selected" => record, "other" => other})
    progress = %{"fraction" => 0.5, "details" => [%{"offset" => -0.0}]}

    after_state =
      SessionData.apply_event(
        before,
        event("selected", %{"progress" => progress, "updated_at" => 42})
      )

    expected_record = Map.merge(record, %{"progress" => progress, "updated_at" => 42})

    expected = %State{
      before
      | async_tool_calls: %{"selected" => expected_record, "other" => other}
    }

    assert after_state === expected
    assert after_state.__struct__ == State
  end

  test "terminal, absent, and non-map records do not request time or change state" do
    for record <- [
          %{"status" => "completed", "result" => 1.5},
          %{"status" => "failed"},
          %{"status" => "cancelled"},
          nil,
          false,
          [],
          1.25
        ] do
      before = state(%{"selected" => record})
      ev = event("selected")
      assert Driver.step(before, ev) === {:done, before}
      assert SessionData.apply_event(before, ev) === before
    end

    before = state(%{})
    assert SessionData.apply_event(before, event("absent")) === before

    assert Driver.step(before, event("absent")) === {:done, before}
  end

  test "missing and unknown statuses remain eligible for progress" do
    for record <- [%{}, %{"status" => "unknown"}, %{"status" => 1.5}] do
      before = state(%{"selected" => record})

      after_state =
        SessionData.apply_event(before, event("selected", %{"updated_at" => 0}))

      assert after_state.async_tool_calls["selected"] ===
               Map.merge(record, %{"progress" => %{}, "updated_at" => 0})
    end
  end

  test "nil and false select fallbacks but empty lists remain truthy" do
    for fallback <- [nil, false] do
      before = state(fallback)
      assert SessionData.apply_event(before, event("absent")) === before

      active = state(%{"selected" => %{}})

      after_state =
        SessionData.apply_event(
          active,
          event("selected", %{"progress" => fallback, "updated_at" => []})
        )

      assert after_state.async_tool_calls["selected"] === %{"progress" => %{}, "updated_at" => []}
    end

    before = state(%{"selected" => %{}})

    after_state =
      SessionData.apply_event(
        before,
        event("selected", %{"progress" => [], "updated_at" => []})
      )

    assert after_state.async_tool_calls["selected"] === %{"progress" => [], "updated_at" => []}

    assert_raise BadMapError, fn ->
      SessionData.apply_event(state([]), event("selected"))
    end
  end

  test "time is requested only for an admitted update with a false or absent timestamp" do
    before = state(%{"selected" => %{"status" => "running"}})

    for fields <- [%{}, %{"updated_at" => nil}, %{"updated_at" => false}] do
      ev = event("selected", fields)
      assert {:observe_time, continuation} = Driver.step(before, ev)
      assert {:done, observed} = Driver.step(continuation, {:observed_time, 123})
      assert observed.async_tool_calls["selected"]["updated_at"] == 123

      earliest = System.system_time(:millisecond)
      actual = SessionData.apply_event(before, ev)
      latest = System.system_time(:millisecond)
      assert actual.async_tool_calls["selected"]["updated_at"] in earliest..latest
    end

    for timestamp <- [0, [], "", 1.5] do
      ev = event("selected", %{"updated_at" => timestamp})
      assert {:done, after_state} = Driver.step(before, ev)
      assert after_state.async_tool_calls["selected"]["updated_at"] === timestamp
    end
  end

  test "pure-data identities preserve exact native keys" do
    for id <- [nil, [], 7, 1.25, %{"identity" => true}] do
      before = state(%{id => %{"status" => "running"}})

      after_state =
        SessionData.apply_event(before, event(id, %{"updated_at" => 42}))

      assert Map.fetch!(after_state.async_tool_calls, id)["updated_at"] == 42
      assert map_size(after_state.async_tool_calls) == 1
    end
  end

  test "the existing wrapper still rejects another Session before kernel admission" do
    before = state(%{"selected" => %{}})
    ev = event("selected", %{"session_id" => "another-session", "updated_at" => 42})
    assert SessionData.apply_event(before, ev) === before
  end
end
