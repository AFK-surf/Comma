defmodule SalixAgent.SessionKernelReplyWaitTest do
  use ExUnit.Case, async: false
  alias SalixAgent.InternalSession.State
  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.ProviderReplyObligation

  defp apply_event(state, type, fields \\ %{}) do
    event = Map.put(fields, "type", type)
    {:done, next} = Driver.step(state, event)
    next
  end

  defp scope do
    %{
      "response_identity" => "rsp_" <> String.duplicate("A", 24),
      "conversation_id" => "conversation",
      "source_message_ids" => ["one", "two"],
      "source_messages" => [%{"source_message_id" => "one"}, %{"source_message_id" => "two"}]
    }
  end

  test "activation start retains complete normalized valid scope and unchanged activity" do
    state = %State{
      status: :active,
      activity_status: :thinking,
      activity_status_updated_at: 10,
      last_activity_at: {:opaque, 3},
      last_seq: 9,
      messages: [:untouched]
    }

    raw = %{
      response_identity: scope()["response_identity"],
      conversation_id: "conversation",
      source_message_ids: ["one", "two"],
      source_messages: [%{source_message_id: "one"}, %{source_message_id: "two"}]
    }

    assert apply_event(state, "visible_reply_activation_started", %{"scope" => raw}) ===
             %{state | visible_reply_activation_scope: scope()}
  end

  test "activation validation rejects malformed identities duplicate IDs and changed order" do
    for invalid <- [
          nil,
          %{},
          Map.put(scope(), "response_identity", "rsp_" <> String.duplicate("!", 24)),
          Map.put(scope(), "response_identity", "rsp_" <> String.duplicate("A", 23) <> "="),
          Map.put(scope(), "source_message_ids", ["one", "one"]),
          Map.put(scope(), "source_messages", Enum.reverse(scope()["source_messages"])),
          Map.put(scope(), "conversation_id", false)
        ] do
      state = %State{
        status: :active,
        activity_status: :thinking,
        activity_status_updated_at: 10,
        visible_reply_activation_scope: :old
      }

      assert apply_event(state, "visible_reply_activation_started", %{"scope" => invalid}) ===
               state
    end
  end

  test "activation matching preserves whitespace and non-UTF8 source identities" do
    for id <- [" ", <<255>>] do
      valid = %{
        scope()
        | "source_message_ids" => [id],
          "source_messages" => [%{"source_message_id" => id}]
      }

      assert apply_event(
               %State{
                 status: :active,
                 activity_status: :thinking,
                 activity_status_updated_at: 10
               },
               "visible_reply_activation_started",
               %{"scope" => valid}
             ) ===
               %State{
                 status: :active,
                 activity_status: :thinking,
                 activity_status_updated_at: 10,
                 visible_reply_activation_scope: valid
               }
    end
  end

  test "activation finish uses falsey alias and exact binary identity without validating format" do
    for identity <- ["", <<255>>, "not-minted"], first <- [nil, false, identity] do
      state = %State{
        status: :active,
        activity_status: :thinking,
        activity_status_updated_at: 10,
        visible_reply_activation_scope: %{
          "response_identity" => first,
          response_identity: identity
        }
      }

      assert apply_event(state, "visible_reply_activation_finished", %{
               "response_identity" => identity
             }) === %{state | visible_reply_activation_scope: nil}

      assert apply_event(state, "visible_reply_activation_finished", %{
               "response_identity" => "different"
             }) === state
    end
  end

  test "missing activation fields retain default inner no-op" do
    state = %State{
      status: :active,
      activity_status: :thinking,
      activity_status_updated_at: 10,
      visible_reply_activation_scope: :old
    }

    for type <- ["visible_reply_activation_started", "visible_reply_activation_finished"] do
      assert apply_event(state, type) === state
    end
  end

  test "provider resolve preserves string-first falsey map selection and nonbinary no-op" do
    state = %State{
      status: :active,
      activity_status: :thinking,
      activity_status_updated_at: 10,
      provider_reply_obligations: %{"keep" => 1, "remove" => false}
    }

    assert apply_event(state, "provider_reply_obligation_resolved", %{
             "obligation_key" => "remove"
           }) ===
             %{state | provider_reply_obligations: %{"keep" => 1}}

    for key <- [nil, false, :remove, <<1::1>>] do
      assert apply_event(state, "provider_reply_obligation_resolved", %{"obligation_key" => key}) ===
               state
    end
  end

  test "card addition respects full queued occupancy" do
    reply =
      ProviderReplyObligation.normalize(%{
        "provider" => "slack",
        "connect_id" => "connect",
        "channel" => "channel",
        "thread_ts" => "thread"
      })

    state = %State{
      status: :active,
      activity_status: :thinking,
      activity_status_updated_at: 10,
      provider_reply_obligations: %{reply["key"] => reply}
    }

    added =
      apply_event(state, "provider_card_obligation_added", %{
        "conversation_id" => "conversation",
        "limit" => 2
      })

    assert map_size(added.provider_reply_obligations) === 2

    assert apply_event(state, "provider_card_obligation_added", %{
             "conversation_id" => "conversation",
             "limit" => 1
           }) === state

    for limit <- [nil, false, 0, -1, 1.0] do
      assert apply_event(state, "provider_card_obligation_added", %{
               "conversation_id" => "conversation",
               "limit" => limit
             }) === state
    end

    queued = %{
      state
      | input_queue: [
          %{
            "payload" => %{
              "provider_reply_obligation" => %{
                "provider" => "slack",
                "kind" => "task_card",
                "conversation_id" => "queued"
              }
            }
          }
        ]
    }

    assert apply_event(queued, "provider_card_obligation_added", %{
             "conversation_id" => "conversation",
             "limit" => 2
           }) === queued
  end

  test "ACK preserves Task-card fence and clears advisory scope only on advancement" do
    base = %State{
      status: :active,
      activity_status: :thinking,
      activity_status_updated_at: 10,
      last_ack_message_id: 1,
      provider_reply_obligations: %{"reply" => %{"kind" => nil}},
      active_source_message_ids: ["source"],
      visible_reply_activation_scope: scope(),
      visible_reply_egress_facts: %{"done" => true},
      runaway_unsettled_streak: %{"count" => 3}
    }

    expected = %{
      base
      | last_ack_message_id: 2,
        provider_reply_obligations: %{},
        active_source_message_ids: [],
        visible_reply_activation_scope: nil,
        visible_reply_egress_facts: %{},
        runaway_unsettled_streak: nil
    }

    assert apply_event(base, "ack", %{"last_ack_message_id" => 2}) === expected
    assert apply_event(base, "ack", %{"last_ack_message_id" => 1}) === base
    blocked = %{base | provider_reply_obligations: %{"card" => %{"kind" => "task_card"}}}
    assert apply_event(blocked, "ack", %{"last_ack_message_id" => 2}) === blocked
    falsey = %{base | visible_reply_egress_facts: false}

    assert apply_event(falsey, "ack", %{"last_ack_message_id" => 1}) ===
             %{falsey | visible_reply_egress_facts: %{}}
  end

  test "wait setting copies raw payload and unconditional clear prunes no empty refs" do
    for wait <- [nil, false, [], %{nested: [1.5]}] do
      assert apply_event(
               %State{
                 status: :active,
                 activity_status: :thinking,
                 activity_status_updated_at: 10
               },
               "wait_set",
               %{"wait" => wait}
             ) === %State{
               status: :active,
               activity_status: :thinking,
               activity_status_updated_at: 10,
               wait: wait
             }
    end

    state = %State{
      status: :active,
      activity_status: :thinking,
      activity_status_updated_at: 10,
      wait: %{old: true},
      async_result_refs: false
    }

    for id <- [nil, false, "", :call] do
      assert apply_event(state, "wait_clear", %{"tool_call_id" => id}) === %{state | wait: nil}
    end
  end

  test "exact auto wait clear requires all referenced calls settled and prunes stale refs" do
    state = %State{
      status: :active,
      activity_status: :thinking,
      activity_status_updated_at: 10,
      wait: %{"source" => "auto_wait", "tool_call_ids" => ["one", "two"]},
      async_tool_calls: %{"one" => %{"status" => "completed"}, "two" => %{"status" => "running"}},
      async_result_refs: %{}
    }

    assert apply_event(state, "wait_clear", %{"tool_call_id" => "one"}) === state

    settled = %{
      state
      | async_tool_calls: Map.put(state.async_tool_calls, "two", %{"status" => "failed"})
    }

    assert apply_event(settled, "wait_clear", %{"tool_call_id" => "one"}) === %{
             settled
             | wait: nil
           }

    archived = %{
      state
      | async_tool_calls: %{},
        async_result_refs: %{"one" => 1, "two" => 2},
        compacted_seq: 2
    }

    assert apply_event(archived, "wait_clear", %{"tool_call_id" => "two"}) ===
             %{archived | wait: nil, async_result_refs: %{}}

    unknown = %{archived | async_result_refs: %{"one" => 1, "two" => 0}}
    assert apply_event(unknown, "wait_clear", %{"tool_call_id" => "two"}) === unknown
  end
end
