defmodule SalixAgent.SessionKernelLogMessageTest do
  use SystemsClock.Case, async: false
  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.InternalSession.State

  defp event(extra \\ %{}) do
    Map.merge(
      %{
        "type" => "session_log_message",
        "source_message_id" => "source",
        "content" => "log",
        "created_at" => "now"
      },
      extra
    )
  end

  defp outcome(fun) do
    try do
      {:returned, fun.()}
    catch
      kind, reason -> {:raised, kind, Exception.normalize(kind, reason, __STACKTRACE__)}
    end
  end

  defp compare(state, event) do
    outcome(fn ->
      {:done, next} = Driver.step(state, event)
      next
    end)
  end

  test "fallback ID is used for both record and final high-water mark" do
    for {previous, selected, next_id} <- [{nil, 1, 2}, {false, 1, 2}, {7, 7, 8}] do
      initial = %State{next_message_id: previous, live_context_bytes: 0}
      assert {:returned, next} = compare(initial, event(%{"message_id" => false}))
      assert hd(next.messages).id === selected
      assert next.next_message_id === next_id
      assert next.last_seq === 1
      assert next.live_context_bytes === 3
      assert MapSet.member?(next.input_dedupe, "source")
    end
  end

  test "explicit noninteger or negative IDs remain native values without HWM update" do
    for id <- [-1, 4.0, "id"] do
      initial = %State{
        status: :active,
        activity_status: :thinking,
        next_message_id: :unvisited,
        live_context_bytes: 0
      }

      assert {:returned, next} = compare(initial, event(%{"message_id" => id}))
      assert hd(next.messages).id === id
      assert next.next_message_id === :unvisited

      # Idle activity classification reads the original counter even when
      # the message does not cause a high-water-mark update.
      assert {:raised, :error, %ArithmeticError{}} =
               compare(%State{initial | status: :idle}, event(%{"message_id" => id}))
    end
  end

  test "empty filtered identities preserve an unreadable dedupe field without repair" do
    initial = %State{input_dedupe: :untouched, live_context_bytes: 0}

    assert {:returned, next} =
             compare(
               initial,
               event(%{"source_message_id" => " \t", "dedupe_key" => nil, "message_id" => 3})
             )

    assert next.input_dedupe === :untouched
    assert hd(next.messages).source_message_id === " \t"
  end

  test "MapSet data requires canonical membership markers" do
    raw = MapSet.new() |> Map.put(:map, %{"old" => :noncanonical_marker})

    for ev <- [event(), event(%{"source_message_id" => "old"})] do
      assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
        Driver.step(%State{input_dedupe: raw, live_context_bytes: 0}, ev)
      end
    end
  end
end
