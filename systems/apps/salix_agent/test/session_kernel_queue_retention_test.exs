defmodule SalixAgent.SessionKernelQueueRetentionTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.InternalSession.State

  # Target native compatibility profile: OTP 29.0.2 / Elixir 1.20.1.
  @ref "trf1_1234567890123456789"
  @other "trf1_2234567890123456789"
  @recent "trf1_3234567890123456789"

  defp state(extra) do
    struct(
      State,
      Map.merge(
        %{
          input_queue: [],
          queue_ack_id: 0,
          compacted_seq: 10,
          async_result_refs: %{@ref => 5, @other => 10, @recent => 11},
          async_results: [],
          messages: [],
          wait: nil,
          summary: nil
        },
        extra
      )
    )
  end

  defp item(id, payload), do: %{"queue_id" => id, "payload" => payload}
  defp ack(id \\ 0), do: %{"type" => "queue_ack", "queue_ack_id" => id}
  defp consume(id \\ 999), do: %{"type" => "queue_consume", "queue_id" => id}

  defp check(state, event, expected_refs) do
    assert {:done, next} = Driver.step(state, event)
    assert next.async_result_refs === expected_refs
    next
  end

  test "transcript references support nested metadata and decoded JSON content" do
    messages = [
      %{metadata: [%{result_ref: @ref}]},
      %{content: ~s({"envelope":[{"result_ref":"#{@ref}"}]})},
      %{"content" => [%{"result_ref" => @ref}]}
    ]

    for event <- [ack(), consume()], message <- messages do
      check(state(%{messages: [message]}), event, %{@ref => 5, @recent => 11})
    end
  end

  test "JSON decode failure is not interpreted as a reference-bearing object" do
    valid = ~s({"result_ref":"#{@ref}"})
    malformed = ~s({"result_ref":"#{@ref}")
    assert {:ok, %{"result_ref" => @ref}} = Jason.decode(valid)
    assert {:error, _} = Jason.decode(malformed)

    for event <- [ack(), consume()] do
      check(state(%{messages: [%{content: valid}]}), event, %{@ref => 5, @recent => 11})
      check(state(%{messages: [%{content: malformed}]}), event, %{@recent => 11})
      check(state(%{messages: [%{content: valid <> " trailing"}]}), event, %{@recent => 11})
      check(state(%{messages: [%{content: "bare text " <> @ref}]}), event, %{@recent => 11})
      check(state(%{messages: [%{content: Jason.encode!(@ref)}]}), event, %{@recent => 11})
    end
  end

  test "retiring the final queue source removes its compacted pointer" do
    initial =
      state(%{
        input_queue: [
          item(1, %{"tool_call_id" => @ref}),
          item(2, %{"tool_call_id" => @ref})
        ]
      })

    after_one = check(initial, consume(1), %{@ref => 5, @recent => 11})
    check(after_one, consume(2), %{@recent => 11})
    check(%{after_one | wait: %{tool_call_id: @ref}}, consume(2), %{@ref => 5, @recent => 11})
    check(initial, ack(2), %{@recent => 11})
  end

  test "no-op-looking reducers normalize queue and prune unprotected pointers" do
    initial =
      state(%{
        input_queue: [
          %{queue_id: "2", payload: %{}, label: "first"},
          :discard,
          %{"queue_id" => 1.8, "payload" => %{}},
          %{"queue_id" => 2, "payload" => %{}, "label" => "second"},
          %{"queue_id" => "invalid", "payload" => %{}}
        ]
      })

    for event <- [ack(), consume()] do
      next = check(initial, event, %{@recent => 11})
      assert Enum.map(next.input_queue, & &1["queue_id"]) === [1.8, "2", 2]
      assert Enum.map(tl(next.input_queue), & &1["label"]) === ["first", "second"]
      assert next.queue_ack_id === 0
    end
  end

  test "nil false and empty refs leave unused malformed retention inputs unvisited" do
    for refs <- [nil, false, %{}], event <- [ack(), consume()] do
      initial =
        state(%{
          async_result_refs: refs,
          messages: :not_enumerable,
          async_results: [:not_a_record],
          wait: %{tool_call_ids: [:anything]}
        })

      check(initial, event, refs)
    end
  end

  test "nonempty recent refs still evaluate malformed known result records" do
    initial = state(%{async_result_refs: %{@recent => 11}, async_results: [:not_a_record]})

    for event <- [ack(), consume()] do
      assert_raise FunctionClauseError, fn -> Driver.step(initial, event) end
    end
  end

  test "retention rejects a non-enumerable message container" do
    assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
      Driver.step(state(%{messages: :not_enumerable}), ack())
    end
  end
end
