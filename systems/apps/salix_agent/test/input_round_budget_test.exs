defmodule SalixAgent.InputRoundBudgetTest do
  use ExUnit.Case, async: false

  alias SalixAgent.InternalSession
  alias SalixAgent.TestSupport.SessionData

  setup do
    previous = Application.get_env(:salix_agent, :input_round_cap)
    Application.put_env(:salix_agent, :input_round_cap, 3)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:salix_agent, :input_round_cap),
        else: Application.put_env(:salix_agent, :input_round_cap, previous)
    end)

    :ok
  end

  defp base do
    "agent-budget"
    |> InternalSession.new("ses1_0000000000000000911", %{})
    |> InternalSession.export()
  end

  defp input(id) do
    %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => id,
      "role" => "user",
      "source_message_id" => "src-#{id}",
      "content" => "input #{id}"
    }
  end

  defp assistant(id), do: %{"type" => "assistant", "message_id" => id, "content" => "round #{id}"}

  defp tool(id) do
    %{
      "type" => "tool_result",
      "message_id" => id,
      "tool_call_id" => "call-#{id}",
      "tool_name" => "web.search",
      "input" => %{"query" => "q#{id}"},
      "status" => "completed",
      "error" => false,
      "content" => "result #{id}"
    }
  end

  # The runtime's own feedback: a background completion carries the call id,
  # a wait timeout carries none.
  defp completion(id, tool_call_id) do
    %{
      "type" => "runtime_message",
      "from_queue" => true,
      "message_id" => id,
      "runtime_message_id" => "tool-call-result:#{tool_call_id}",
      "runtime_message_type" => "tool_call_completed",
      "source_tool_call_id" => tool_call_id,
      "source_message_id" => "tool-call-result:#{tool_call_id}",
      "summary" => "background call completed",
      "content" => "background call completed"
    }
  end

  defp timeout(id) do
    %{
      "type" => "runtime_message",
      "from_queue" => true,
      "message_id" => id,
      "runtime_message_id" => "wait-timeout:#{id}",
      "runtime_message_type" => "wait_expired",
      "source_message_id" => "wait-timeout:#{id}",
      "summary" => "wait timeout reached",
      "content" => "wait timeout reached"
    }
  end

  defp ack(state, hwm),
    do: %{"type" => "ack", "session_id" => state.session_id, "last_ack_message_id" => hwm}

  test "assistant rounds after the input count; tool results, completions and timeouts are transparent" do
    state =
      SessionData.apply_events(base(), [
        input(1),
        assistant(2),
        tool(3),
        completion(4, "call-3"),
        assistant(5),
        timeout(6)
      ])

    assert SessionData.query(state, :rounds_since_fresh_input) == 2
    refute SessionData.query(state, :input_round_budget_exhausted?)
    assert "stable_input_pending" in SessionData.query(state, :work_reasons)
  end

  test "the cap parks the session and fresh user input starts the count over" do
    parked =
      SessionData.apply_events(base(), [input(1), assistant(2), assistant(3), assistant(4)])

    assert SessionData.query(parked, :rounds_since_fresh_input) == 3
    assert SessionData.query(parked, :input_round_budget_exhausted?)
    assert SessionData.query(parked, :activity_status) == :failed
    assert SessionData.query(parked, :activity_issue) == "input_round_budget_parked"
    refute "stable_input_pending" in SessionData.query(parked, :work_reasons)
    refute SessionData.query(parked, :has_unprocessed_stable_work?)

    # The loop's own wake does not lift the park.
    woken = SessionData.apply_event(parked, completion(5, "call-x"))
    assert SessionData.query(woken, :rounds_since_fresh_input) == 3
    assert SessionData.query(woken, :input_round_budget_exhausted?)

    fresh = SessionData.apply_event(woken, input(6))
    assert SessionData.query(fresh, :rounds_since_fresh_input) == 0
    refute SessionData.query(fresh, :input_round_budget_exhausted?)
    assert "stable_input_pending" in SessionData.query(fresh, :work_reasons)
  end

  test "acknowledged rounds do not count, even behind a later timeout wake" do
    state = SessionData.apply_events(base(), [input(1), assistant(2), assistant(3)])
    acked = SessionData.apply_event(state, ack(state, 3))
    assert SessionData.query(acked, :rounds_since_fresh_input) == 0

    woken = SessionData.apply_event(acked, timeout(4))
    assert SessionData.query(woken, :rounds_since_fresh_input) == 0
  end

  test "a cap of zero disables the guard" do
    Application.put_env(:salix_agent, :input_round_cap, 0)
    state = SessionData.apply_events(base(), [input(1), assistant(2), assistant(3), assistant(4)])

    assert SessionData.query(state, :rounds_since_fresh_input) == 3
    refute SessionData.query(state, :input_round_budget_exhausted?)
    assert SessionData.query(state, :activity_status) == :paused
  end
end
