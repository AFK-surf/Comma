defmodule SalixVerifiedKernel.NativeStackTest do
  use ExUnit.Case, async: false
  alias SalixVerifiedKernel.Session

  defp provider(op, payload) do
    assert {:ok, {:value, value}} = SalixVerifiedKernel.invoke(:provider, op, payload)
    value
  end

  test "stream completion joins thousands of text and reasoning fragments in order" do
    for field <- ["content", "reasoning_content", "reasoning"] do
      parts = for n <- 1..12_000, do: "#{n}雪"

      raw =
        Enum.map_join(parts, fn part ->
          event = %{"choices" => [%{"delta" => %{field => part}}]}
          "data: " <> IO.iodata_to_binary(:json.encode(event)) <> "\n\n"
        end)

      response = provider(:decode_stream, {"chat", raw <> "data: [DONE]\n\n", "test"})
      expected = Enum.join(parts)

      if field == "content" do
        assert {:final, ^expected} = response
      else
        assert {:final, "", metadata, _} = response
        assert metadata["chat_message_extra"][field] == expected
      end
    end
  end

  test "provider system fragments preserve nonempty separators and empty inputs" do
    messages = for n <- 1..12_000, do: %{role: "system", content: "#{n}"}
    assert {[], text} = provider(:responses_parts, messages)
    assert text == Enum.map_join(1..12_000, "\n\n", &Integer.to_string/1)
    assert {[], nil} = provider(:responses_parts, [])
  end

  test "deep JSON is rejected before recursive parsing exhausts the scheduler stack" do
    for {left, right} <- [{"[", "]"}, {"{\"x\":", "}"}] do
      raw = String.duplicate(left, 20_000) <> "0" <> String.duplicate(right, 20_000)
      assert provider(:normalize, raw) == raw
      # 63 enclosing containers plus the scalar fit the 64-level budget.
      boundary = String.duplicate(left, 63) <> "0" <> String.duplicate(right, 63)
      assert provider(:normalize, boundary) == :json.decode(boundary)
      over = left <> boundary <> right
      assert provider(:normalize, over) == over
    end
  end

  test "restart notices join a wide interrupted-call set without changing identity order" do
    session = Session.new("agent", "session")
    ids = Enum.map(1..12_000, &"call-#{&1}")

    context = %{
      "phase" => "failed_encoded",
      "restarted" => Enum.map(ids, &%{id: &1}),
      "next_id" => 1
    }

    assert {:return, {events, 1}} = Session.query(session, :resume_restart, {context, []})
    notice = Enum.find(events, &(&1["kind"] == "runtime_message"))

    assert notice["dedupe_key"] ==
             "runtime-recovered:missing-tool-results:session:" <> Enum.join(ids, ",")

    assert Enum.map(notice["payload"]["failed_tool_calls"], & &1["tool_call_id"]) == ids
  end

  test "materialization scans a wide no-wake prefix in order" do
    original = Session.new("agent", "session") |> Session.export()

    queue =
      for id <- 1..12_000,
          do: %{
            "queue_id" => id,
            "kind" => "user_message",
            "wake" => false,
            "payload" => %{"content" => "item-#{id}", "no_wake" => true}
          }

    session = Session.open(%{original | input_queue: queue, next_queue_id: 12_001})
    {events, false, _} = Session.query(session, :materialize_pending_input_events, 12_000)
    deliveries = Enum.filter(events, &(&1["type"] == "delivery"))
    assert length(deliveries) == 12_000
    assert hd(deliveries)["content"] == "item-1"
    assert List.last(deliveries)["content"] == "item-12000"
    assert List.last(events)["queue_ack_id"] == 12_000
  end

  test "selective materialization skips a foreign human input and selects wide runtime completions" do
    original = Session.new("agent", "session") |> Session.export()

    origin = %{
      "provider" => "internal",
      "source_actor_type" => "user",
      "source_message_id" => "active"
    }

    active = %{id: 1, seq: 1, role: "user", source_message_id: "active", trusted_origin: origin}

    deferred = %{
      "queue_id" => 1,
      "kind" => "user_message",
      "wake" => true,
      "payload" => %{
        "content" => "later",
        "trusted_origin" => Map.put(origin, "source_message_id", "later")
      }
    }

    completions =
      for id <- 2..12_001,
          do: %{
            "queue_id" => id,
            "kind" => "runtime_message",
            "wake" => true,
            "payload" => %{
              "content" => "completion-#{id}",
              "trusted_origin_source_message_ids" => ["active"]
            }
          }

    session =
      Session.open(%{
        original
        | messages: [active],
          last_seq: 1,
          next_message_id: 2,
          input_queue: [deferred | completions],
          next_queue_id: 12_002
      })

    {events, true, _} = Session.query(session, :materialize_pending_input_events, 12_000)
    consumes = Enum.filter(events, &(&1["type"] == "queue_consume"))
    assert Enum.map(consumes, & &1["queue_id"]) == Enum.to_list(2..12_001)
    refute Enum.any?(events, &(&1["type"] in ["queue_ack", "delivery"]))
    assert Session.get(session, :input_queue) == [deferred | completions]
  end

  test "wide keyed observation preludes preserve a later positional clock result" do
    # No keyed entry answers :time, so observe must scan past every one and
    # consume only the positional observation. The keyed entries remain settled.
    prelude =
      List.duplicate({:ok_for, :unrelated, nil}, 12_000) ++
        Enum.reject(Session.prelude(), &match?({:ok_for, :time, _}, &1)) ++ [{:ok, 1_700_000_000}]

    {:verified_kernel, 1, :session_state, resident} = Session.new("agent", "session")
    context = %{"phase" => "failed_encoded", "restarted" => [%{id: "call"}], "next_id" => 1}

    assert {:ok, _, {:value, {:return, {events, 1}}}} =
             SalixVerifiedKernel.invoke_session(
               resident,
               :query,
               {:resume_restart, {context, []}, prelude}
             )

    notice = Enum.find(events, &(&1["kind"] == "runtime_message"))
    assert notice["created_at"] == 1_700_000
  end

  test "JSON resource rejection does not silently prune a referenced result" do
    ref = "trf1_0000000000000000001"
    original = Session.new("agent", "session") |> Session.export()

    content =
      String.duplicate("[", 100) <> ~s({"result_ref":"#{ref}"}) <> String.duplicate("]", 100)

    session =
      Session.open(%{
        original
        | messages: [%{id: 1, seq: 1, role: "user", content: content}],
          last_seq: 1,
          # This reference must be eligible for pruning to require JSON inspection.
          compacted_seq: 1,
          next_message_id: 2,
          async_result_refs: %{ref => 1}
      })

    assert_raise RuntimeError, ~r/invalid_observation/, fn ->
      Session.step(session, %{"type" => "queue_ack", "queue_ack_id" => 1})
    end

    assert Session.get(session, :async_result_refs) == %{ref => 1}
    assert Session.get(session, :queue_ack_id) == 0
  end
end
