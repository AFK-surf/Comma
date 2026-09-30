defmodule SalixAgent.SessionKernelQueueRetentionTest do
  use ExUnit.Case, async: false

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

  test "summary matching preserves final newline identities and raw binary boundaries" do
    newline_ref = @ref <> <<10>>

    for event <- [ack(), consume()] do
      initial =
        state(%{
          async_result_refs: %{newline_ref => 5},
          summary: <<255>> <> newline_ref <> <<128>>
        })

      check(initial, event, %{newline_ref => 5})
      check(%{initial | summary: @ref}, event, %{})

      for suffix <- [<<13, 10>>, <<13>>, <<10, 10>>, <<0>>, <<255>>] do
        invalid = @ref <> suffix
        check(state(%{async_result_refs: %{invalid => 5}, summary: invalid}), event, %{})
      end
    end
  end

  test "remaining queue tool identity protects compacted pointers for both reducers" do
    for event <- [ack(), consume()],
        payload <- [%{"tool_call_id" => @ref}, %{"source_tool_call_id" => @ref}] do
      check(state(%{input_queue: [item(1, payload)]}), event, %{@ref => 5, @recent => 11})
    end
  end

  test "wait aliases protect nonempty refs and empty plural suppresses singular fallback" do
    for event <- [ack(), consume()],
        wait <- [
          %{"tool_call_ids" => [@ref]},
          %{tool_call_ids: [@ref]},
          %{"tool_call_id" => @ref},
          %{tool_call_id: @ref},
          %{"tool_call_ids" => false, "tool_call_id" => @ref}
        ] do
      check(state(%{wait: wait}), event, %{@ref => 5, @recent => 11})
    end

    check(state(%{wait: %{"tool_call_ids" => [], "tool_call_id" => @ref}}), ack(), %{
      @recent => 11
    })
  end

  test "transcript atom tool_calls and either call ID alias protect pointers" do
    for event <- [ack(), consume()], call <- [%{"id" => @ref}, %{id: @ref}] do
      check(state(%{messages: [%{tool_calls: [call]}]}), event, %{@ref => 5, @recent => 11})
    end

    check(state(%{messages: [%{"tool_calls" => [%{"id" => @ref}]}]}), ack(), %{@recent => 11})
  end

  test "queued nested message refs protect without a queue tool identity" do
    payload = %{"envelope" => [%{"result_ref" => @ref}]}

    for event <- [ack(), consume()] do
      check(state(%{input_queue: [item(1, payload)]}), event, %{@ref => 5, @recent => 11})
    end
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

  test "summary protects a complete canonical known ref but not an invalid ID" do
    for event <- [ack(), consume()] do
      check(state(%{summary: "Archived result: " <> @ref <> "."}), event, %{
        @ref => 5,
        @recent => 11
      })
    end

    check(
      state(%{async_result_refs: %{"not-a-canonical-ref" => 5}, summary: "not-a-canonical-ref"}),
      ack(),
      %{}
    )
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

  test "string result_ref presence masks atom alias even when nil false or empty" do
    for masked <- [nil, false, ""] do
      message = %{"result_ref" => masked, :result_ref => @ref}
      check(state(%{messages: [message]}), ack(), %{@recent => 11})
    end

    check(state(%{messages: [%{result_ref: @ref}]}), ack(), %{@ref => 5, @recent => 11})
  end

  test "content chooses truthy atom alias before the binary alias" do
    for first <- [nil, false] do
      message = %{:content => first, "content" => %{"result_ref" => @ref}}
      check(state(%{messages: [message]}), ack(), %{@ref => 5, @recent => 11})
    end

    check(state(%{messages: [%{:content => "", "content" => %{"result_ref" => @ref}}]}), ack(), %{
      @recent => 11
    })
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

  test "consume uses loose numeric equality and does not advance ACK" do
    initial = state(%{queue_ack_id: 7, input_queue: [item(1, %{}), item(2, %{})]})
    next = check(initial, consume(1.0), %{@recent => 11})
    assert next.input_queue === [item(2, %{})]
    assert next.queue_ack_id === 7
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

  test "valid stored record aliases remain evaluated even without a binary summary" do
    for record <- [
          %{"result_ref" => @ref},
          %{result_ref: @ref},
          %{"result_ref" => "", "tool_call_id" => @ref},
          %{tool_call_id: @ref}
        ] do
      check(state(%{async_results: [record]}), ack(), %{@recent => 11})
    end
  end

  test "empty binary queue and wait IDs protect while empty result_ref does not" do
    initial = state(%{async_result_refs: %{"" => 5}})
    check(%{initial | input_queue: [item(1, %{"tool_call_id" => ""})]}, ack(), %{"" => 5})
    check(%{initial | wait: %{tool_call_id: ""}}, ack(), %{"" => 5})
    check(%{initial | messages: [%{result_ref: ""}]}, ack(), %{})
  end

  test "retention rejects a non-enumerable message container" do
    assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
      Driver.step(state(%{messages: :not_enumerable}), ack())
    end
  end

  test "wait aliases select the first truthy plain field" do
    for values <- [
          %{"tool_call_ids" => [@ref]},
          %{"tool_call_ids" => nil, :tool_call_ids => [@ref]},
          %{"tool_call_ids" => false, :tool_call_ids => [@ref]}
        ],
        event <- [ack(), consume()] do
      check(state(%{wait: values}), event, %{@ref => 5, @recent => 11})
    end
  end
end
