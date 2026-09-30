defmodule SalixAgent.SessionKernelQueueAppendTest do
  use ExUnit.Case, async: false
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

  test "missing kind retains the original invalid-input exception class" do
    ev = Map.delete(event(), "kind")
    assert_raise FunctionClauseError, fn -> native(%State{}, ev) end

    assert_raise FunctionClauseError, fn ->
      SessionData.apply_event(%State{}, ev)
    end
  end

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

  test "false identities are retained and nil fields alone are omitted" do
    state = %State{last_activity_at: 42, next_queue_id: false, input_dedupe: false}
    ev = event(%{"dedupe_key" => false, "wake" => false, "created_at" => false})
    assert {:returned, next} = compare(state, ev)
    item = hd(next.input_queue)
    assert item["dedupe_key"] === false
    assert item["wake"] === false
    assert item["created_at"] === false
    assert next.last_activity_at == 42
    assert MapSet.member?(next.input_dedupe, false)

    assert {:returned, ^next} =
             compare(
               next,
               event(%{"dedupe_key" => false, "payload" => %{"source_message_id" => "different"}})
             )

    assert {:returned, omitted} = compare(%State{}, event(%{"created_at" => nil}))
    refute Map.has_key?(hd(omitted.input_queue), "created_at")
    assert hd(omitted.input_queue)["wake"] === true
  end

  test "ASCII identity normalization handles blank and nonblank input" do
    assert {:raised, _, _} =
             compare(%State{}, event(%{"payload" => %{"source_message_id" => "\t \r"}}))

    assert {:returned, next} =
             compare(%State{}, event(%{"payload" => %{"source_message_id" => " id "}}))

    assert MapSet.member?(next.input_dedupe, " id ")
    refute MapSet.member?(next.input_dedupe, "id")
  end

  test "recursive binary-key payloads preserve opaque scalar values" do
    payload = %{
      "source_message_id" => "source-1",
      "nested" => [
        %{"data" => [%{"empty" => %{}, "false" => false, "nil" => nil}]},
        %{"tuple" => {:opaque, %{atom_key: :not_visited}}, "bytes" => <<255>>}
      ]
    }

    assert {:returned, next} = compare(%State{}, event(%{"payload" => payload}))
    assert hd(next.input_queue)["payload"] === payload
  end

  test "nonbinary key collisions retain the original native winner" do
    collision =
      Map.new([
        {:content, "atom-value"},
        {"content", "binary-value"},
        {:source_message_id, "atom-id"},
        {"source_message_id", "binary-id"}
      ])

    assert {:returned, _} = compare(%State{}, event(%{"payload" => collision}))

    # Both map representations and nested collisions matter. No canonical
    # key order is used to predict the winning original value.
    large = Enum.reduce(1..40, collision, fn i, acc -> Map.put(acc, "extra-#{i}", i) end)
    assert {:returned, _} = compare(%State{}, event(%{"payload" => large}))

    assert {:returned, _} =
             compare(
               %State{},
               event(%{
                 "payload" => %{
                   "source_message_id" => "source-1",
                   "nested" => [large]
                 }
               })
             )
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

  test "summary admission still precedes duplicate suppression" do
    state = %State{input_dedupe: MapSet.new(["source-1"])}
    ev = event(%{"payload" => %{"source_message_id" => "source-1", "role" => "summary"}})
    assert {:raised, _, _} = compare(state, ev)
    assert {:returned, ^state} = compare(state, Map.put(ev, "wake", false))
  end

  test "raw atom-key identities are normalized inside original validation" do
    assert {:returned, next} =
             compare(%State{}, event(%{"payload" => %{source_message_id: "atom-id"}}))

    assert MapSet.member?(next.input_dedupe, "atom-id")
    assert hd(next.input_queue)["payload"] == %{"source_message_id" => "atom-id"}

    runtime =
      event(%{"kind" => "runtime_message", "payload" => %{runtime_message_id: "runtime-id"}})

    assert {:returned, next_runtime} = compare(%State{}, runtime)
    assert MapSet.member?(next_runtime.input_dedupe, "runtime-id")
  end

  test "raw role normalization and collisions retain original validation" do
    assert {:returned, _} =
             compare(
               %State{},
               event(%{
                 "wake" => false,
                 "payload" => %{source_message_id: "atom-id", role: "summary"}
               })
             )

    assert {:raised, _, _} =
             compare(
               %State{},
               event(%{
                 "payload" => %{source_message_id: "atom-id", role: "summary"}
               })
             )
  end

  test "nested payload conversion can fail before invalid role admission" do
    payload = %{
      source_message_id: "source-1",
      role: "invalid",
      nested: %{{:bad_key, 1} => :value}
    }

    assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
      Driver.step(%State{}, event(%{"payload" => payload}))
    end

    assert {:raised, _, _} =
             compare(
               %State{},
               event(%{"payload" => %{source_message_id: "source-1", role: "invalid"}})
             )
  end

  test "a string __struct__ payload key is ordinary user data" do
    payload = %{"source_message_id" => "source-1", "__struct__" => "opaque-label"}
    assert {:returned, next} = compare(%State{}, event(%{"payload" => payload}))
    assert hd(next.input_queue)["payload"] == payload
  end
end
