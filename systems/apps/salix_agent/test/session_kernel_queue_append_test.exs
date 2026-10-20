defmodule SalixAgent.SessionKernelQueueAppendTest do
  use SystemsClock.Case, async: false
  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.InternalSession.State
  alias SalixAgent.TestSupport.SessionData

  defp event(extra \\ %{}) do
    Map.merge(
      %{
        "type" => "queue_append",
        "kind" => "user_message",
        "payload" => %{"source_message_id" => "source-1"}
      },
      extra
    )
  end

  defp native(state, event) do
    {:done, next} = Driver.step(state, event)
    next
  end

  defp outcome(fun) do
    try do
      {:returned, fun.()}
    catch
      kind, reason -> {:raised, kind, Exception.normalize(kind, reason, __STACKTRACE__)}
    end
  end

  defp compare(state, event), do: outcome(fn -> native(state, event) end)

  test "duplicate hits skip the queue's normalization and preserve every field" do
    malformed = [%{{:cannot_stringify, :queued_key} => :value, "queue_id" => 1} | :improper_tail]

    state = %State{
      input_queue: malformed,
      next_queue_id: :not_an_integer,
      input_dedupe: MapSet.new(["source-1"]),
      last_activity_at: :unchanged
    }

    assert {:returned, ^state} = compare(state, event(%{"created_at" => :later}))

    # Without the duplicate, the exact same malformed State must reach a failure.
    assert {:raised, _, _} = compare(%{state | input_dedupe: MapSet.new()}, event())
  end

  test "existing equal queue IDs retain their input order" do
    items = [
      %{"queue_id" => 3, "label" => "third-a"},
      %{"queue_id" => 1, "label" => "first-a"},
      %{"queue_id" => 3, "label" => "third-b"},
      %{"queue_id" => 1, "label" => "first-b"},
      %{"queue_id" => 2, "label" => "second"}
    ]

    assert {:returned, next} = compare(%State{input_queue: items, next_queue_id: 3}, event())

    assert Enum.map(next.input_queue, & &1["label"]) ==
             ["first-a", "first-b", "second", "third-a", "third-b", nil]

    assert List.last(next.input_queue)["queue_id"] == 3
    assert next.next_queue_id == 4
  end

  test "improper payload and queue lists preserve original errors" do
    for payload <- [
          [%{"ok" => true} | :bad_tail],
          %{"source_message_id" => "source-1", "nested" => [1 | :bad_tail]}
        ] do
      assert {:raised, _, _} = compare(%State{}, event(%{"payload" => payload}))
    end

    assert {:raised, _, _} =
             compare(%State{input_queue: [%{"queue_id" => 1} | :bad_tail]}, event())
  end

  test "large payloads reject keys without a schema-defined string conversion" do
    payload =
      Enum.reduce(1..40, %{"source_message_id" => "source-1"}, fn i, acc ->
        Map.put(acc, "nested-#{i}", %{{:bad_nested_key, i} => :value})
      end)

    assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
      Driver.step(%State{}, event(%{"payload" => payload}))
    end
  end
end
