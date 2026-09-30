defmodule SalixAgent.SessionKernelTranscriptSeedTest do
  use ExUnit.Case, async: false
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

  test "duplicate batches preserve counters and activity but still recount" do
    state = %State{
      input_dedupe: MapSet.new(["same"]),
      next_message_id: 7,
      last_seq: 11,
      last_activity_at: "before",
      messages: [%{id: 1, content: "old"}],
      live_context_bytes: 900
    }

    assert {:returned, next} = check(state, event([entry("same"), entry("same")]))
    assert next.next_message_id === 7
    assert next.last_seq === 11
    assert next.last_activity_at === "before"
    assert next.live_context_bytes === 3
  end

  test "duplicates within a batch skip before message construction and accounting" do
    assert {:returned, next} =
             check(
               %State{},
               event([
                 entry("same"),
                 entry("same", "assistant", %{
                   "content" => {:opaque, :data},
                   "tool_calls" => :not_a_list
                 })
               ])
             )

    assert length(next.messages) === 1
  end

  test "false identities survive while nil and whitespace identities are omitted" do
    entries = [
      entry(false),
      entry(false),
      entry(nil, "user", %{"dedupe_key" => " \t"}),
      entry(nil, "user", %{"dedupe_key" => " \t"})
    ]

    assert {:returned, next} = check(%State{}, event(entries))
    assert length(next.messages) === 3
    assert MapSet.member?(next.input_dedupe, false)
    refute MapSet.member?(next.input_dedupe, " \t")
  end

  test "tool identities use the original lazy fallback and participate in dedupe" do
    entries = [
      entry(nil, "tool", %{
        "tool_call_id" => false,
        "tool_use_id" => "call",
        "call_id" => "unused"
      }),
      entry(nil, "tool", %{"tool_call_id" => "call"})
    ]

    assert {:returned, next} = check(%State{}, event(entries))
    assert length(next.messages) === 1
    assert hd(next.messages).tool_call_id === "call"
  end

  test "all role construction paths preserve native fields and no wake" do
    entries = [
      entry("u"),
      entry("r", "runtime", %{"content" => false, "summary" => "fallback"}),
      entry("a", "assistant", %{"model" => false, "trace_id" => "trace", "tool_calls" => false}),
      entry("t", "tool", %{"call_id" => "call", "public_summary" => false}),
      entry("other", "unvalidated_role")
    ]

    assert {:returned, next} = check(%State{}, event(entries))
    assert Enum.all?(next.messages, &(&1.no_wake === true))
    runtime = Enum.at(next.messages, 1)
    assert runtime.content === "fallback"
    assert runtime.type === "eval_seed"
    assert runtime.source_refs === %{}
    assert Enum.at(next.messages, 2).model === false
    assert Enum.at(next.messages, 3).public_summary === false
  end

  test "entry timestamp wins and false entry timestamp falls back to event" do
    assert {:returned, next} =
             check(
               %State{created_at: "original"},
               event([
                 entry("a", "user", %{"created_at" => "entry"}),
                 entry("b", "user", %{"created_at" => false})
               ])
             )

    assert Enum.map(next.messages, & &1.created_at) === ["entry", "now"]
    assert next.created_at === "original"
  end

  test "negative integer counters retain the native integer behavior" do
    assert {:returned, next} =
             check(
               %State{next_message_id: -4, last_seq: -9},
               event([entry("a")])
             )

    assert hd(next.messages).id === -4
    assert hd(next.messages).seq === -8
    assert next.next_message_id === -3
  end

  test "duplicate detection does not skip recursive stringify failures" do
    assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
      Driver.step(
        %State{input_dedupe: MapSet.new(["same"])},
        event([entry("same", "user", %{"opaque" => %{{} => 1}})])
      )
    end
  end

  test "improper entry lists and nested payload lists keep native errors" do
    assert {:raised, _, _} = check(%State{}, event([entry("a") | :tail]))

    assert {:raised, _, _} =
             check(%State{}, event([entry("a", "user", %{"opaque" => [1 | :tail]})]))
  end
end
