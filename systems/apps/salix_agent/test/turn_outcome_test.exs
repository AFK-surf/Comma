defmodule SalixAgent.TurnOutcomeTest do
  use ExUnit.Case, async: true

  alias SalixAgent.InternalSession
  alias SalixAgent.TurnOutcome

  test "the kernel settles only a standalone valid end_turn" do
    end_turn = fn args -> %{name: "end_turn", args: args} end

    assert {:settle, "done"} = classify([end_turn.(%{"outcome" => "done"})])

    assert {:settle, "blocked"} =
             classify([
               end_turn.(%{"outcome" => "blocked", "reason" => " repository unavailable "})
             ])

    assert classify([end_turn.(%{"outcome" => "blocked"})]) == :execute_tools
    assert classify([end_turn.(%{"outcome" => "later"})]) == :execute_tools

    # end_turn beside any other call is not a turn end.
    assert classify([end_turn.(%{"outcome" => "done"}), %{name: "call", args: %{}}]) ==
             :execute_tools

    reply = %{
      "tool" => "im_api.internal.send_message",
      "params" => %{},
      "ifc" => %{"sources" => []}
    }

    # A carried reply settles through the ordinary source-bound send.
    decision = end_turn.(%{"outcome" => "done", "reply" => reply})

    # Dispatch sends the reply itself; history keeps the model's end_turn.
    assert {:reply, "done", [%{name: "call", args: ^reply}], [^decision]} = classify([decision])

    for bad <- [Map.delete(reply, "params"), Map.put(reply, "ifc", false)] do
      assert classify([end_turn.(%{"outcome" => "done", "reply" => bad})]) == :execute_tools
    end
  end

  # Drives the kernel's loop from a provider response to the record it asks for.
  defp classify(calls) do
    session = InternalSession.new("agent", "ses1_0000000000000000999")

    facts = %{
      "id_snapshot" => InternalSession.next_message_id(session),
      "guard" => :clean,
      "vphase" => :clean,
      "nonce" => 1
    }

    response = {:assistant, "", calls}

    {machine, _} =
      InternalSession.query(session, :loop_step, {nil, {:model_response, response, facts}})

    {_machine, effects} = InternalSession.query(session, :loop_step, {machine, :continue})

    case List.last(effects) do
      {:build_record, %{"mode" => "final", "terminal_call" => %{}} = spec} ->
        {:settle, spec["terminal_call"][:args]["outcome"]}

      {:build_record, %{"mode" => "tools", "decision_outcome" => outcome} = spec}
      when outcome != nil ->
        {:reply, outcome, spec["calls"], spec["record_calls"]}

      {:build_record, %{"mode" => "tools"}} ->
        :execute_tools
    end
  end

  test "derives a pending decision only from the latest clean unacknowledged prose" do
    attempt = %{
      id: 2,
      role: "assistant",
      content: "I will inspect",
      tool_calls: [],
      round_id: "round-1"
    }

    pending = %{messages: [%{id: 1, role: "user"}, attempt], last_ack_message_id: 1}
    handle = InternalSession.open(pending)

    assert TurnOutcome.decision_required?(handle)

    assert [%{role: "user"}, %{role: "summary", content: _reminder}] =
             TurnOutcome.append_reminder([%{role: "user"}], handle, true)

    assert TurnOutcome.append_reminder([%{role: "user"}], handle, false) == [%{role: "user"}]

    refute TurnOutcome.decision_required?(
             InternalSession.open(%{pending | last_ack_message_id: 2})
           )

    refute TurnOutcome.decision_required?(
             InternalSession.open(%{
               pending
               | messages: [%{attempt | tool_calls: [%{name: "call"}]}]
             })
           )

    refute TurnOutcome.decision_required?(
             InternalSession.open(%{
               pending
               | messages: [Map.put(attempt, :visible_reply_phase, :repair_required)]
             })
           )

    refute TurnOutcome.decision_required?(
             InternalSession.open(%{pending | messages: [Map.put(attempt, :no_wake, true)]})
           )
  end
end
