defmodule SalixAgent.LoopBudgetTest do
  # Issue #2070, property C: only fresh input starts the round budget over.
  # These tests drive the kernel loop and its activation decision with no
  # credit after the first input, in a session without a reply destination.
  # A retryable model failure keeps the source unacknowledged, a final failure
  # ACK keeps the round count, and the guard settlement after a park closes the
  # turn. Before these fixes, model failures and park settlements started the
  # budget over, so model requests continued with no new input. Retry resume
  # stops at the failure cap, and context-overflow recovery runs once for each
  # transcript position.
  use ExUnit.Case, async: false

  alias SalixAgent.InternalSession

  @sid "ses1_0000000000000000912"
  @cap 3

  setup do
    keys = [:input_round_cap, :llm_activation_retry_base_ms]
    previous = Map.new(keys, &{&1, Application.get_env(:salix_agent, &1)})
    Application.put_env(:salix_agent, :input_round_cap, @cap)
    # The retry deadline passes at once, so activation resumes without a timer.
    Application.put_env(:salix_agent, :llm_activation_retry_base_ms, 1)

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:salix_agent, key),
          else: Application.put_env(:salix_agent, key, value)
      end
    end)

    session =
      InternalSession.new("agent-loop-budget", @sid)
      |> InternalSession.apply_events([
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 1,
          "role" => "user",
          "source_message_id" => "src-1",
          "content" => "keep working"
        }
      ])

    %{session: session}
  end

  test "without model failures the round budget parks after the cap", %{session: session} do
    session =
      Enum.reduce(1..@cap, session, fn round, session ->
        assert :run == activation(session)
        {session, decision} = tool_round(session, round)
        if round < @cap, do: assert(decision == :boundary), else: assert({:park, _} = decision)
        session
      end)

    assert InternalSession.query(session, :input_round_budget_exhausted?)
    assert :idle == activation(session)
  end

  test "a retryable model failure neither ACKs nor resets the round budget", %{
    session: session
  } do
    {session, requests} =
      Enum.reduce_while(1..(4 * @cap), {session, 0}, fn cycle, {session, requests} ->
        # A model request that returns tool calls.
        assert :run == activation(session)

        case tool_round(session, cycle) do
          {session, {:park, _machine}} ->
            {:halt, {session, requests + 1}}

          {session, :boundary} ->
            assert InternalSession.query(session, :rounds_since_fresh_input) == cycle

            # The next model request fails and a retry follows. The source
            # stays unacknowledged, so the round count stays visible.
            acked = InternalSession.get(session, :last_ack_message_id)
            assert :run == activation(session)
            {session, acked?} = failed_round(session, cycle)
            refute acked?
            assert InternalSession.get(session, :last_ack_message_id) == acked
            assert InternalSession.query(session, :rounds_since_fresh_input) == cycle
            {:cont, {session, requests + 2}}
        end
      end)

    # The cap parks the session after `@cap` tool rounds and the failures
    # between them, with one credit (the first input) and no other input.
    assert requests == 2 * @cap - 1
    assert InternalSession.query(session, :input_round_budget_exhausted?)
    assert :idle == activation(session)
  end

  test "a final model-failure ACK keeps the round count", %{session: session} do
    assert :run == activation(session)
    {session, :boundary} = tool_round(session, 1)

    # Consecutive retryable failures reach the failure cap. Only the final
    # failure ACKs the source, and that ACK keeps the round count.
    {session, acks} =
      Enum.reduce(1..3, {session, []}, fn n, {session, acks} ->
        {session, events} = failed_round_events(session, n)
        {session, acks ++ Enum.filter(events, &(&1["type"] == "ack"))}
      end)

    assert [%{"keep_round_budget" => true}] = acks
    assert InternalSession.get(session, :input_round_streak)["count"] == 1
  end

  # Issue #2070, property C. When the round budget parks a session without a
  # reply destination, `guard_notice` commits the local guard settlement. Its
  # ACK closes the turn, so the tool-result tail does not continue by itself.
  # Before the fix, activation resumed the continuation and each cycle ran
  # `@cap` more model requests with no credit.
  test "the guard settlement after a round-budget park stops the session", %{
    session: session
  } do
    session =
      Enum.reduce(1..@cap, session, fn round, session ->
        assert :run == activation(session)

        case tool_round(session, round) do
          {session, :boundary} ->
            assert round < @cap
            session

          {session, {:park, machine}} ->
            assert round == @cap
            assert InternalSession.query(session, :input_round_budget_exhausted?)
            {session, events} = settle_park(session, machine)

            assert Enum.any?(
                     events,
                     &(&1["type"] == "session_event" and
                         &1["kind"] == "runtime_failure_disposed")
                   )

            session
        end
      end)

    # No credit arrived after the settlement, so no model round starts.
    assert :idle == activation(session)
  end

  # Retry resume is bounded by the failure cap. Consecutive model failures at
  # one transcript position count up. The last failure is final, and its ACK
  # keeps the round count. Then activation runs nothing until a credit arrives.
  test "consecutive model failures stop at the failure cap", %{session: session} do
    {session, requests} =
      Enum.reduce_while(1..10, {session, 0}, fn n, {session, requests} ->
        case activation_after_retry(session) do
          :idle ->
            {:halt, {session, requests}}

          :run ->
            {session, _events} = failed_round_events(session, n)
            {:cont, {session, requests + 1}}
        end
      end)

    assert requests == 3
    assert InternalSession.query(session, :llm_failures_exhausted?)
    assert :idle == activation(session)
  end

  # Context-overflow recovery runs at most once for each transcript position.
  # A second overflow at the same position is an ordinary model failure, so it
  # counts toward the failure cap and does not start another recovery.
  test "context-overflow recovery runs once per transcript position", %{session: session} do
    assert :run == activation(session)
    snapshot = InternalSession.next_message_id(session)

    {session, first} = overflow_round(session, snapshot, 1)
    assert {:stop, :context_overflow} = List.last(first.effects)

    assert Enum.any?(
             first.events,
             &(&1["kind"] == "context_overflow_recovery_requested")
           )

    # The host compacts and runs one round at the same position.
    {_session, second} = overflow_round(session, snapshot, 2)
    assert :continue == List.last(second.effects)
    assert Enum.any?(second.events, &(&1["kind"] == "llm_call_failed"))
    refute Enum.any?(second.events, &(&1["kind"] == "context_overflow_recovery_requested"))
  end

  # The activation decision after a retry deadline: wait for the deadline, then
  # decide again.
  defp activation_after_retry(session) do
    facts = %{"ceiling_ms" => 1_800_000}
    Process.sleep(2)

    case step(session, nil, {:activate, facts}) do
      {_, [{:set_timer, :retry, _at}, {:stop, :wait}]} ->
        Process.sleep(5)
        activation_after_retry(session)

      _ ->
        activation(session)
    end
  end

  # One model round whose provider call fails with a context overflow.
  defp overflow_round(session, snapshot, n) do
    {:error, meta} = SalixAgent.LLM.Error.context_overflow("anthropic", "prompt is too long")
    facts = facts(snapshot, 100 + n)
    {machine, _} = step(session, nil, {:model_response, {:error, meta}, facts})
    {_, effects} = step(session, machine, :continue)
    [{:commit, events, _, _}] = Enum.filter(effects, &match?({:commit, _, _, _}, &1))
    {InternalSession.apply_events(session, events), %{events: events, effects: effects}}
  end

  # The kernel's activation decision: `:run` when it hands the session to a
  # model round (`run` or `resume`), `:idle` when it runs nothing.
  defp activation(session) do
    facts = %{"ceiling_ms" => 1_800_000}
    Process.sleep(2)

    case step(session, nil, {:activate, facts}) do
      {_, [{:materialize, :run}]} -> :run
      {_, [{:cancel_timer, :retry}, {:materialize, :run}]} -> :run
      {_, [{:stop, :idle}]} -> :idle
      other -> flunk("unexpected activation #{inspect(other)}")
    end
  end

  # One model round with one completed tool call, driven through the loop.
  defp tool_round(session, n) do
    aid = InternalSession.next_message_id(session)
    call = %{id: "call-#{n}", name: "call", args: %{"tool" => "fs.list", "n" => n}}
    facts = facts(aid, 2 * n)
    {machine, _} = step(session, nil, {:model_response, {:assistant, "", [call]}, facts})
    {machine, [_draft, {:build_record, _spec}]} = step(session, machine, :continue)

    intent = [
      %{
        "type" => "assistant",
        "session_id" => @sid,
        "message_id" => aid,
        "content" => "",
        "tool_calls" => [call]
      }
    ]

    record = %{
      "intent" => intent,
      "aid" => aid,
      "base" => aid,
      "admission" => nil,
      "speculative" => false
    }

    {machine, [{:commit, events, _, _} | _]} = step(session, machine, {:record, record})
    session = InternalSession.apply_events(session, events)

    result = %{id: "call-#{n}", name: "call", status: "completed", content: "listing #{n}"}
    {machine, [{:store_results, _, _}]} = step(session, machine, {:tools_done, [result], false})

    stored = [
      %{
        "type" => "tool_result",
        "session_id" => @sid,
        "message_id" => aid + 1,
        "tool_call_id" => "call-#{n}",
        "tool_name" => "fs.list",
        "status" => "completed",
        "content" => "listing #{n}"
      }
    ]

    {machine, [{:commit, events, _, _} | _]} =
      step(session, machine, {:results_stored, stored, aid + 1, aid + 1, [result]})

    session = InternalSession.apply_events(session, events)

    case step(session, machine, :continue) do
      {%{"phase" => "boundary_after_tools"} = machine, _} ->
        {_, [{:commit, events, _, _} | _]} = step(session, machine, :continue)
        {InternalSession.apply_events(session, events), :boundary}

      {%{"phase" => "guard_notice"} = machine, _} ->
        {session, {:park, machine}}
    end
  end

  # The rest of a parked round: `guard_notice` commits the guard settlement.
  defp settle_park(session, machine) do
    {_, effects} = step(session, machine, :continue)
    [{:commit, events, _, _}, {:stop, :final}] = effects
    {InternalSession.apply_events(session, events), events}
  end

  # One model round whose provider call fails with a retryable error.
  defp failed_round(session, n) do
    {session, events} = failed_round_events(session, n)
    {session, Enum.any?(events, &(&1["type"] == "ack"))}
  end

  # One model round whose provider call fails with a retryable error: the
  # applied session and the committed events.
  defp failed_round_events(session, n) do
    snapshot = InternalSession.next_message_id(session)

    {:error, meta} =
      SalixAgent.LLM.Error.http("anthropic", 529, ~s({"error":{"message":"overloaded"}}))

    facts = facts(snapshot, 2 * n + 1)
    {machine, _} = step(session, nil, {:model_response, {:error, meta}, facts})
    {_, [_draft, {:commit, events, _, _}, :continue]} = step(session, machine, :continue)
    {InternalSession.apply_events(session, events), events}
  end

  defp facts(snapshot, nonce),
    do: %{"id_snapshot" => snapshot, "guard" => :clean, "vphase" => :clean, "nonce" => nonce}

  defp step(session, machine, event),
    do: InternalSession.query(session, :loop_step, {machine, event})
end
