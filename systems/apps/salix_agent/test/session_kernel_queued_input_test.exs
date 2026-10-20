defmodule SalixAgent.SessionKernelQueuedInputTest do
  use SystemsClock.Case, async: false
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

  test "runtime result refs preserve nil-key lookup" do
    refs = %{nil => false}

    assert {:returned, next} =
             check(%State{async_result_refs: refs}, runtime(%{"no_wake" => true}))

    assert hd(next.messages).result_seq === false
  end

  test "runtime malformed result refs retain native failure" do
    assert {:raised, _, _} = check(%State{async_result_refs: :opaque}, runtime())
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
end
