defmodule SalixAgent.SessionKernelTranscriptSeedTest do
  use SystemsClock.Case, async: false
  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.InternalSession.State

  defp event(entries, extra \\ %{}) do
    Map.merge(%{"type" => "transcript_seed", "entries" => entries, "created_at" => "now"}, extra)
  end

  defp entry(id, role \\ "user", extra \\ %{}) do
    Map.merge(%{"role" => role, "source_message_id" => id, "content" => "text"}, extra)
  end

  defp outcome(fun) do
    try do
      {:returned, fun.()}
    catch
      kind, reason -> {:raised, kind, Exception.normalize(kind, reason, __STACKTRACE__)}
    end
  end

  defp check(state, ev) do
    outcome(fn ->
      {:done, next} = Driver.step(state, ev)
      next
    end)
  end

  test "seed appends in entry order and owns exactly seven fields" do
    initial = %State{
      messages: [%{id: 1, content: "old"}],
      next_message_id: 8,
      last_seq: 20,
      live_context_bytes: 999,
      created_at: nil,
      last_activity_at: "before"
    }

    assert {:returned, next} = check(initial, event([entry("a"), entry("b")]))
    assert Enum.map(next.messages, & &1.id) === [1, 8, 9]
    assert Enum.map(tl(next.messages), & &1.seq) === [21, 22]
    assert next.next_message_id === 10
    assert next.last_seq === 22
    assert next.live_context_bytes === 11
    assert next.created_at === "now"
    assert next.last_activity_at === "now"

    written = [
      :messages,
      :next_message_id,
      :last_seq,
      :input_dedupe,
      :created_at,
      :last_activity_at,
      :live_context_bytes
    ]

    assert Map.drop(next, written) === Map.drop(initial, written)
  end

  test "empty batch normalizes false history counters and dedupe and recounts" do
    assert {:returned, next} =
             check(
               %State{
                 messages: false,
                 next_message_id: false,
                 input_dedupe: false,
                 last_seq: false,
                 live_context_bytes: 999,
                 last_activity_at: "before"
               },
               event([])
             )

    assert next.messages === []
    assert next.next_message_id === 1
    assert next.last_seq === 0
    assert next.input_dedupe === MapSet.new()
    assert next.live_context_bytes === 0
    assert next.last_activity_at === "before"
  end

  test "empty identity lists do not inspect a malformed truthy dedupe value" do
    assert {:returned, next} = check(%State{input_dedupe: :opaque}, event([entry(nil)]))
    assert next.input_dedupe === :opaque
    assert length(next.messages) === 1
  end
end
