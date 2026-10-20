defmodule SalixAgent.SessionKernelEventOuterTest do
  use SystemsClock.Case, async: true
  alias SalixAgent.InternalSession.State

  defp state(fields \\ []) do
    struct!(
      State,
      Keyword.merge(
        [
          session_id: "session",
          status: :idle,
          activity_status: :paused,
          storage_format: 2,
          next_message_id: 1,
          last_ack_message_id: 0,
          llm_failure_streak: nil,
          runaway_unsettled_streak: nil,
          visible_reply_repair: nil,
          wait: nil,
          events: []
        ],
        fields
      )
    )
  end

  # Steps the kernel and answers its clock and configuration requests from
  # `script`, in order. An empty script answers each request with its default.
  # Returns the result, the unused script, and the requests in order.
  defp run(state, event, script \\ []) do
    finish(SalixVerifiedKernel.Session.step(state, event), script, [])
  end

  defp finish({:done, next}, script, trace), do: {{:ok, next}, {script, Enum.reverse(trace)}}

  defp finish({:observe_time, token}, script, trace) do
    {value, script} = reply(:time, 123_456, script)
    next = SalixVerifiedKernel.Session.step(token, {:observed_time, value})
    finish(next, script, [:time | trace])
  end

  defp finish({:observe_config, :salix_agent, key, default, token}, script, trace) do
    request = {:config, key, default}
    {value, script} = reply(request, default, script)
    next = SalixVerifiedKernel.Session.step(token, {:observed_config, value})
    finish(next, script, [request | trace])
  end

  defp reply(_request, default, []), do: {default, []}
  defp reply(request, _default, [{request, value} | rest]), do: {value, rest}

  defp reply(request, _default, [other | _]),
    do: raise("unexpected observation #{inspect(request)}, expected #{inspect(other)}")

  test "binary session mismatch skips inner errors and all observations" do
    assert {{:ok, original}, {[], []}} =
             run(state(), %{
               "session_id" => "other",
               "type" => "status",
               "status" => :invalid
             })

    assert original == state()
  end

  test "key conversion errors precede the session filter" do
    assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
      SalixVerifiedKernel.Session.step(state(), %{"session_id" => "other", {:invalid, :key} => 1})
    end
  end

  test "activity configuration suspension preserves model notice and continuation inputs" do
    notice = %{
      "failure_reason" => "model",
      "notification_outcome" => "delivered",
      "notification_hwm" => 1
    }

    for {attempt, messages, expected} <- [
          {nil, [], :paused},
          {notice, [], :failed},
          {notice, [%{id: 2, role: "runtime", no_wake: true}], :failed},
          {notice, [%{id: 2, role: "runtime", content: "background completed"}], :paused}
        ] do
      original = state(runtime_failure_reply: attempt, messages: messages)

      assert {:observe_config, :salix_agent, :llm_failure_activation_cap, 3, _} =
               suspended = SalixVerifiedKernel.Session.step(original, %{"type" => "unknown"})

      {{:ok, next}, _} = finish(suspended, [], [])
      assert next.activity_status == expected
      assert next.runtime_failure_reply == attempt
      assert next.messages == messages
    end
  end

  test "repeated-result cap is lazy after the runaway cap and preserves raw cap values" do
    repeated = {:config, :repeated_tool_result_cap, 5}
    original = state(next_message_id: 2, repeated_tool_result_streak: %{"count" => 5})
    assert {{:ok, failed}, {[], trace}} = run(original, %{})
    assert failed.activity_status == :failed
    assert Enum.count(trace, &(&1 == repeated)) == 3

    assert {{:ok, _}, {[], trace}} =
             run(
               %{original | runaway_unsettled_streak: %{"count" => 8}},
               %{}
             )

    refute repeated in trace

    for cap <- [false, nil, 0, -1, "5"] do
      script =
        List.duplicate(
          [
            {{:config, :llm_failure_activation_cap, 3}, 3},
            {{:config, :runaway_unsettled_round_cap, 2}, 8},
            {repeated, cap},
            {{:config, :input_round_cap, 120}, 120}
          ],
          3
        )
        |> List.flatten()

      assert {{:ok, next}, {[], _}} = run(original, %{}, script)
      assert next.activity_status == :paused
    end
  end
end
