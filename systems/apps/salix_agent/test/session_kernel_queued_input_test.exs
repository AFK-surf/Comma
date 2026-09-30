defmodule SalixAgent.SessionKernelQueuedInputTest do
  use ExUnit.Case, async: false
  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.InternalSession.State

  defp delivery(extra \\ %{}) do
    Map.merge(
      %{
        "type" => "delivery",
        "from_queue" => true,
        "message_id" => 4,
        "source_message_id" => "source",
        "content" => "text",
        "created_at" => "now"
      },
      extra
    )
  end

  defp runtime(extra \\ %{}) do
    Map.merge(
      %{
        "type" => "runtime_message",
        "from_queue" => true,
        "message_id" => 4,
        "runtime_message_id" => "runtime",
        "content" => "text",
        "created_at" => "now"
      },
      extra
    )
  end

  defp provider(extra \\ %{}) do
    Map.merge(
      %{
        "provider" => "slack",
        "connect_id" => "connect",
        "channel" => "channel",
        "thread_ts" => "thread"
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

  defp check(state, ev) do
    outcome(fn ->
      {:done, next} = Driver.step(state, ev)
      next
    end)
  end

  test "direct runtime and delivery Events ignore unreadable append fields" do
    for ev <- [delivery(%{"from_queue" => false}), runtime(%{"from_queue" => false})] do
      ev = Map.put(ev, "content", {:unvisited, "content"})
      state = %State{messages: :malformed, live_context_bytes: :malformed}
      assert {:returned, ^state} = check(state, ev)
    end
  end

  test "delivery appends accounts clears wait and user repair then resets scope" do
    state = %State{
      messages: [],
      last_seq: 8,
      next_message_id: 1,
      live_context_bytes: 30,
      wait: %{waiting: true},
      visible_reply_repair: %{repair: true},
      runaway_unsettled_streak: %{"count" => 7}
    }

    assert {:returned, next} = check(state, delivery())
    assert hd(next.messages).seq === 9
    assert next.last_seq === 9
    assert next.next_message_id === 5
    assert next.live_context_bytes === 34
    assert next.wait === nil
    assert next.visible_reply_repair === nil
    assert next.runaway_unsettled_streak === %{"count" => 0}
    assert next.active_source_message_ids === ["source"]
  end

  test "runtime and delivery do not deduplicate already-seen messages" do
    for ev <- [delivery(), runtime()] do
      assert {:returned, next} =
               check(%State{input_dedupe: MapSet.new(["source", "runtime"])}, ev)

      assert length(next.messages) === 1
    end
  end

  test "no-wake input keeps wait repair and malformed unvisited scope" do
    for ev <- [delivery(%{"no_wake" => true}), runtime(%{"no_wake" => true})] do
      state = %State{
        wait: false,
        visible_reply_repair: %{r: 1},
        messages: [],
        visible_reply_activation_scope: :opaque,
        compacted_through: :opaque,
        last_ack_message_id: :opaque,
        active_source_message_ids: :opaque,
        runaway_unsettled_streak: :opaque
      }

      assert {:returned, next} = check(state, ev)
      assert next.wait === false
      assert next.visible_reply_repair === %{r: 1}
      assert next.active_source_message_ids === :opaque
      assert next.runaway_unsettled_streak === :opaque
    end
  end

  test "only exact true no-wake suppresses reset" do
    for value <- [false, nil, 1, "true", []] do
      assert {:returned, next} =
               check(
                 %State{wait: %{w: 1}},
                 delivery(%{"no_wake" => value})
               )

      assert next.wait === nil
      refute Map.has_key?(hd(next.messages), :no_wake)
      assert next.runaway_unsettled_streak === %{"count" => 0}
    end
  end

  test "non-input delivery roles preserve repair and skip fresh reset" do
    for role <- ["assistant", "tool", "", 0] do
      state = %State{
        visible_reply_repair: %{keep: true},
        runaway_unsettled_streak: :opaque,
        active_source_message_ids: :opaque
      }

      assert {:returned, next} = check(state, delivery(%{"role" => role}))
      assert next.visible_reply_repair === %{keep: true}
      assert next.active_source_message_ids === :opaque
    end

    for role <- [nil, false] do
      assert {:returned, next} = check(%State{}, delivery(%{"role" => role}))
      assert hd(next.messages).role === "user"
    end
  end

  test "delivery inserts false and blank identities but skips nil" do
    assert {:returned, next} =
             check(
               %State{},
               delivery(%{"source_message_id" => false, "dedupe_key" => " \t", "no_wake" => true})
             )

    assert MapSet.member?(next.input_dedupe, false)
    assert MapSet.member?(next.input_dedupe, " \t")

    assert {:returned, next} =
             check(
               %State{input_dedupe: :opaque},
               delivery(%{"source_message_id" => nil, "dedupe_key" => nil, "no_wake" => true})
             )

    assert next.input_dedupe === :opaque
  end

  test "runtime false identity is retained and Unicode whitespace identity is missing" do
    assert {:returned, next} =
             check(%State{}, runtime(%{"runtime_message_id" => false, "no_wake" => true}))

    assert MapSet.member?(next.input_dedupe, false)

    assert {:raised, :error, %ArgumentError{}} =
             check(%State{}, runtime(%{"runtime_message_id" => "\u00A0"}))
  end

  test "context-provider precedence rejects wakeable input even with from-queue true" do
    assert {:raised, :error, %ArgumentError{message: message}} =
             check(%State{}, runtime(%{"from_context_provider" => true, "no_wake" => false}))

    assert message ===
             "context provider runtime_message invalid: :context_provider_runtime_message_must_be_no_wake"
  end

  test "runtime content alias is lazy while summary remains its own field" do
    assert {:returned, next} =
             check(
               %State{},
               runtime(%{"content" => false, "summary" => "fallback", "no_wake" => true})
             )

    assert hd(next.messages).content === "fallback"
    assert hd(next.messages).summary === "fallback"
  end

  test "runtime result pointer omits only nil and preserves false" do
    for value <- [nil, false, 0, 17, %{opaque: true}] do
      assert {:returned, next} =
               check(
                 %State{async_result_refs: %{"call" => value}},
                 runtime(%{
                   "tool_call_id" => false,
                   "source_tool_call_id" => "call",
                   "no_wake" => true
                 })
               )

      assert Map.has_key?(hd(next.messages), :result_seq) === (value !== nil)
      if value !== nil, do: assert(hd(next.messages).result_seq === value)
    end
  end

  test "runtime result refs preserve nil-key lookup" do
    refs = %{nil => false}

    assert {:returned, next} =
             check(%State{async_result_refs: refs}, runtime(%{"no_wake" => true}))

    assert hd(next.messages).result_seq === false
  end

  test "runtime malformed result refs retain native failure" do
    assert {:raised, _, _} = check(%State{async_result_refs: :opaque}, runtime())
  end

  test "compacted and live scope sources merge then sort without trimming stored IDs" do
    state = %State{
      compacted_through: 5,
      last_ack_message_id: 1,
      visible_reply_activation_scope: %{"source_message_ids" => ["z", "  kept  ", "z"]},
      messages: [%{id: 2, role: "runtime", source_message_id: "old"}]
    }

    assert {:returned, next} =
             check(state, delivery(%{"message_id" => 8, "source_message_id" => "new"}))

    assert next.active_source_message_ids === ["  kept  ", "new", "old", "z"]
  end

  test "trusted-origin source IDs override all ordinary candidate identities" do
    assert {:returned, next} =
             check(
               %State{},
               runtime(%{
                 "trusted_origin_source_message_ids" => ["trusted", 7, ["nested"], :atom],
                 "source_message_id" => "ignored"
               })
             )

    assert next.active_source_message_ids === ["7", "atom", "nested", "trusted"]
  end

  test "empty live scope falls back to stored active IDs only while unacked" do
    assert {:returned, next} =
             check(
               %State{next_message_id: 10, active_source_message_ids: ["stored"]},
               delivery(%{"message_id" => nil})
             )

    assert next.active_source_message_ids === ["stored"]

    assert {:returned, next} =
             check(
               %State{next_message_id: 1, active_source_message_ids: :unvisited},
               delivery(%{"message_id" => nil})
             )

    assert next.active_source_message_ids === []
  end

  test "only exactly empty stored IDs select the unchanged legacy map" do
    for {stored, expected} <- [{[], ["legacy"]}, {nil, []}, {false, ["false"]}] do
      state = %State{
        next_message_id: 10,
        active_source_message_ids: stored,
        runaway_unsettled_streak: %{"count" => 7, "key" => ["legacy"]}
      }

      assert {:returned, next} = check(state, delivery(%{"message_id" => nil}))
      assert next.active_source_message_ids === expected
    end

    assert {:returned, next} =
             check(
               %State{
                 next_message_id: 10,
                 active_source_message_ids: [],
                 runaway_unsettled_streak: %{key: ["not read"]}
               },
               delivery(%{"message_id" => nil})
             )

    assert next.active_source_message_ids === []
  end

  test "malformed nested scope is rejected" do
    assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
      Driver.step(
        %State{next_message_id: 10, active_source_message_ids: %{}},
        delivery(%{"message_id" => nil})
      )
    end
  end

  test "billing uses only a nonempty raw Event map and otherwise retains State fallback" do
    for supplied <- [nil, false, %{}, %{"new" => 1}, %{atom: 1}] do
      state = %State{billing_context: %{"old" => 1}}
      assert {:returned, next} = check(state, delivery(%{"billing_context" => supplied}))

      expected =
        if is_map(supplied) and map_size(supplied) > 0, do: supplied, else: state.billing_context

      assert next.billing_context === expected
    end
  end

  test "reply obligations compute the complete canonical JSON digest" do
    target =
      provider(%{
        "connect_id" => " \tconn\"\\/\ninside \t",
        "channel" => "频道",
        "thread_ts" => "\u0001thread\u007F"
      })

    assert {:returned, next} =
             check(
               %State{},
               delivery(%{"no_wake" => true, "provider_reply_obligation" => target})
             )

    [stored] = Map.values(next.provider_reply_obligations)

    canonical =
      Jason.encode!([
        "slack",
        String.trim(target["connect_id"]),
        String.trim(target["channel"]),
        String.trim(target["thread_ts"])
      ])

    expected_key = :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
    assert stored["key"] === expected_key
    assert Map.keys(next.provider_reply_obligations) === [expected_key]
  end

  test "task-card identity excludes suggested routing fields" do
    target = provider(%{"kind" => "task_card", "conversation_id" => " task "})

    assert {:returned, first} =
             check(%State{}, delivery(%{"provider_reply_obligation" => target}))

    changed = Map.merge(target, %{"connect_id" => "other", "channel" => "", "thread_ts" => nil})
    assert {:returned, second} = check(first, delivery(%{"provider_reply_obligation" => changed}))
    assert map_size(second.provider_reply_obligations) === 1
    [stored] = Map.values(second.provider_reply_obligations)
    assert stored["conversation_id"] === "task"
    assert stored["connect_id"] === "other"
    refute Map.has_key?(stored, "channel")
    refute Map.has_key?(stored, "thread_ts")
  end

  test "invalid obligation avoids malformed existing obligations and scope" do
    state = %State{
      provider_reply_obligations: :opaque,
      visible_reply_activation_scope: :opaque,
      compacted_through: :opaque
    }

    for raw <- [nil, false, [], %{}, %{"kind" => "unknown"}] do
      assert {:returned, next} =
               check(
                 state,
                 delivery(%{"no_wake" => true, "provider_reply_obligation" => raw})
               )

      assert next.provider_reply_obligations === :opaque
    end
  end

  test "obligation map uses binary State alias priority and keeps opaque old values" do
    state =
      Map.put(
        %State{provider_reply_obligations: %{"atom" => :old}},
        "provider_reply_obligations",
        %{"binary" => :opaque}
      )

    assert {:returned, next} =
             check(state, delivery(%{"provider_reply_obligation" => provider()}))

    assert next.provider_reply_obligations["binary"] === :opaque
    refute Map.has_key?(next.provider_reply_obligations, "atom")
  end

  test "recursive obligation key conversion rejects an invalid nested key" do
    assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
      Driver.step(
        %State{},
        delivery(%{
          "provider_reply_obligation" => Map.put(provider(), "opaque", %{{} => 1})
        })
      )
    end
  end

  test "provider stringify failure precedes invalid HWM and fresh scope" do
    state = %State{next_message_id: :invalid, compacted_through: :invalid}

    assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
      Driver.step(state, delivery(%{"provider_reply_obligation" => %{[] => %{{} => 1}}}))
    end
  end

  test "fresh input clears repeated results but tool feedback and no-wake input preserve them" do
    streak = %{"count" => 4, "fingerprint" => "retained"}
    original = %State{repeated_tool_result_streak: streak}

    for ev <- [delivery(), runtime()] do
      assert {:returned, next} = check(original, ev)
      assert next.repeated_tool_result_streak == nil
    end

    for source <- ["call", ""] do
      assert {:returned, next} = check(original, runtime(%{"source_tool_call_id" => source}))
      assert next.repeated_tool_result_streak == streak
    end

    for ev <- [delivery(%{"no_wake" => true}), runtime(%{"no_wake" => true})] do
      assert {:returned, next} = check(original, ev)
      assert next.repeated_tool_result_streak == streak
    end
  end

  test "runtime IFC comes only from a completed canonical result" do
    trusted = %{"label" => ["organization:approved"]}

    for type <- ["tool_call_completed", "tool_call_failed"] do
      ev =
        runtime(%{
          "runtime_message_type" => type,
          "source_tool_call_id" => "call",
          "ifc" => %{"label" => ["forged"]}
        })

      for record <- [
            %{"status" => "completed", "result" => %{"ifc" => trusted}},
            %{"status" => "completed", "result" => %{"ifc" => %{}}},
            %{"status" => "running", "result" => %{"ifc" => trusted}},
            %{"status" => "failed", "result" => %{"ifc" => trusted}},
            %{"status" => "completed", "result" => %{"ifc" => nil}}
          ] do
        assert {:returned, next} = check(%State{async_tool_calls: %{"call" => record}}, ev)

        expected =
          case record do
            %{"status" => "completed", "result" => %{"ifc" => %{} = value}} -> value
            _ -> %{"label" => ["agent_private"]}
          end

        assert hd(next.messages).ifc == expected
      end
    end
  end

  test "delivery preserves input time unchanged and omits only nil" do
    for value <- [nil, false, 0, "", %{"at" => 123, "zone" => "UTC"}, %{opaque: [false]}] do
      assert {:returned, next} =
               check(%State{}, delivery(%{"input_time" => value}))

      message = hd(next.messages)
      assert Map.has_key?(message, :input_time) === (value !== nil)
      if value !== nil, do: assert(message.input_time === value)
    end
  end

  test "runtime content kind requires the exact trusted context-provider marker" do
    for marker <- [true, false, nil, 0, "true", %{}],
        kind <- [nil, false, "context", %{"opaque" => true}] do
      assert {:returned, next} =
               check(
                 %State{},
                 runtime(%{
                   "from_context_provider" => marker,
                   "content_kind" => kind,
                   "no_wake" => true
                 })
               )

      message = hd(next.messages)
      retained = marker === true and kind !== nil
      assert Map.has_key?(message, :content_kind) === retained
      if retained, do: assert(message.content_kind === kind)
    end
  end

  test "runtime IFC lookup honors live pointers archived results and unvisited other types" do
    trusted = %{"label" => ["organization:approved"]}

    record = %{
      "tool_call_id" => "call",
      "seq" => 9,
      "status" => "completed",
      "result" => %{"ifc" => trusted}
    }

    ev =
      runtime(%{"runtime_message_type" => "tool_call_completed", "source_tool_call_id" => "call"})

    for refs <- [%{}, %{"call" => 9}] do
      assert {:returned, next} =
               check(%State{async_results: [record], async_result_refs: refs}, ev)

      assert hd(next.messages).ifc == trusted
    end

    assert {:returned, next} = check(%State{async_result_refs: %{"call" => 9}}, ev)
    assert hd(next.messages).ifc == %{"label" => ["agent_private"]}

    assert {:returned, next} =
             check(
               %State{async_tool_calls: :unvisited, async_results: :unvisited},
               runtime(%{"runtime_message_type" => "other", "ifc" => trusted})
             )

    refute Map.has_key?(hd(next.messages), :ifc)
  end
end
