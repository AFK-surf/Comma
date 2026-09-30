defmodule SalixAgent.ContextOverflowTest do
  use ExUnit.Case, async: true
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

  test "usage from a different model does not trigger compaction" do
    session = InternalSession.new("agent", "ses1_0000000000000000997")

    session =
      InternalSession.apply_events(session, [
        %{
          "type" => "assistant",
          "message_id" => 1,
          "content" => "ok",
          "model" => "old-model",
          "input_tokens" => 120_000
        }
      ])

    assert SalixAgent.Compaction.should_compact?(session,
             model: "old-model",
             context_tokens: 128_000
           )

    refute SalixAgent.Compaction.should_compact?(session,
             model: "new-model",
             context_tokens: 128_000
           )
  end

  test "large text and image base64 never trigger compaction without observed usage" do
    metadata = %{
      "responses_items" => [
        %{"type" => "image_generation_call", "result" => String.duplicate("A", 1_216_388)}
      ]
    }

    for usage <- [nil, 56_514] do
      session = InternalSession.new("agent", "ses1_0000000000000000998")

      session =
        InternalSession.apply_events(session, [
          %{
            "type" => "assistant",
            "message_id" => 1,
            "content" => String.duplicate("x", 600_000),
            "provider_meta" => metadata,
            "input_tokens" => usage
          }
        ])

      refute SalixAgent.Compaction.should_compact?(session, context_tokens: 128_000)
      assert List.last(InternalSession.get(session, :messages)).provider_meta == metadata
      {:ok, restored} = session |> InternalSession.persist() |> InternalSession.load()
      refute SalixAgent.Compaction.should_compact?(restored, context_tokens: 128_000)
    end
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
