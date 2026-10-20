defmodule SalixAgent.ContextOverflowTest do
  use SystemsClock.Case, async: true
  alias SalixAgent.{ContextOverflow, InternalSession}

  test "recovery budget survives snapshots and compaction but new input gets a new budget" do
    session = InternalSession.new("agent", "ses1_0000000000000000999")

    session =
      InternalSession.apply_events(session, [
        %{"type" => "delivery", "from_queue" => true, "message_id" => 1, "content" => "keep me"}
      ])

    refute attempted?(session, 1)
    session = InternalSession.apply_events(session, [overflow_request(session, 1)])
    assert ContextOverflow.pending?(session)
    assert attempted?(session, 1)
    {:ok, restored} = session |> InternalSession.persist() |> InternalSession.load()
    assert ContextOverflow.pending?(restored)

    compacted =
      InternalSession.apply_events(restored, [
        %{
          "type" => "compaction",
          "summary" => "history",
          "compacted_through" => 0,
          "summary_sequence" => 1
        }
      ])

    refute ContextOverflow.pending?(compacted)
    assert attempted?(compacted, 1)
    assert InternalSession.get(compacted, :last_ack_message_id) == 0

    newer =
      InternalSession.apply_events(compacted, [
        %{"type" => "delivery", "from_queue" => true, "message_id" => 2, "content" => "new input"}
      ])

    refute ContextOverflow.pending?(newer)
    refute attempted?(newer, 2)
  end

  # The kernel's loop requests one recovery for an overflowing response.
  defp overflow_request(session, hwm) do
    facts = %{"id_snapshot" => hwm + 1, "guard" => :clean, "vphase" => :clean, "nonce" => 1}
    response = {:error, %{"category" => "context_overflow"}}

    {machine, _} =
      InternalSession.query(session, :loop_step, {nil, {:model_response, response, facts}})

    {_, [_draft, {:commit, [request, _idle], _, _}, {:stop, :context_overflow}]} =
      InternalSession.query(session, :loop_step, {machine, :continue})

    request
  end

  defp attempted?(session, hwm),
    do:
      match?(
        %{"transcript_hwm" => ^hwm},
        InternalSession.get(session, :context_overflow_recovery)
      )
end
