defmodule SalixAgent.GuardFailureReplyTest do
  use ExUnit.Case, async: true

  alias SalixAgent.{InternalSession, TerminalReply}
  alias SalixAgent.InternalSession.State

  @source "telegram-request"
  @call "guard-failure-call"

  defp origin do
    %{
      "provider" => "telegram",
      "source_actor_type" => "provider_user",
      "source_message_id" => @source,
      "provider_context" => %{"connect_id" => "telegram", "chat_id" => "42"}
    }
  end

  defp reply_binding do
    %{
      "kind" => "telegram",
      "agent_id" => "agent",
      "session_id" => "session",
      "source_message_id" => @source,
      "trusted_origin" => origin(),
      "context_source_message_ids" => [@source],
      "assistant_id" => 3,
      "last_ack_message_id" => 0,
      "tool_call_id" => @call,
      "connect_id" => "telegram",
      "chat_id" => "42",
      "message_thread_id" => "",
      "outcome" => "blocked"
    }
  end

  defp exhausted do
    InternalSession.open(%State{
      agent_id: "agent",
      session_id: "session",
      next_message_id: 3,
      messages: [
        %{id: 1, seq: 1, role: "user", source_message_id: @source, trusted_origin: origin()},
        %{id: 2, seq: 2, role: "assistant", content: "", tool_calls: []}
      ],
      last_seq: 2,
      repeated_tool_result_streak: %{"count" => 5}
    })
  end

  for {provider, actor, destination, operation, route} <- [
        {"internal", "user",
         %{"conversation_id" => "conversation", "conversation_kind" => "user_chat"},
         "im_api.internal.send_message",
         %{"connect_id" => "internal", "conversation_id" => "conversation"}},
        {"slack", "provider_user",
         %{
           "provider_context" => %{
             "connect_id" => "slack",
             "channel_id" => "channel",
             "thread_ts" => "thread"
           }
         }, "im_api.slack.reply_message",
         %{"connect_id" => "slack", "channel" => "channel", "thread_ts" => "thread"}},
        {"feishu", "provider_user",
         %{"provider_context" => %{"connect_id" => "feishu", "message_id" => "message"}},
         "im_api.feishu.reply_text", %{"connect_id" => "feishu", "message_id" => "message"}},
        {"imessage", "provider_user",
         %{"provider_context" => %{"connect_id" => "imessage", "chat_id" => "chat"}},
         "im_api.imessage.send_message", %{"connect_id" => "imessage", "chat_id" => "chat"}},
        {"wechat", "provider_user", %{"provider_context" => %{"connect_id" => "wechat"}},
         "im_api.wechat.reply_text", %{"connect_id" => "wechat"}},
        {"signal", "provider_user",
         %{"provider_context" => %{"connect_id" => "signal", "chat_id" => "peer"}},
         "im_api.signal.send_message", %{"connect_id" => "signal", "chat_id" => "peer"}}
      ] do
    test "#{provider} cold guard recovery preserves and releases the next human request" do
      origin =
        Map.merge(unquote(Macro.escape(destination)), %{
          "provider" => unquote(provider),
          "source_actor_type" => unquote(actor),
          "source_message_id" => @source
        })

      state = InternalSession.export(exhausted())
      [request, assistant] = state.messages
      state = %{state | messages: [Map.put(request, :trusted_origin, origin), assistant]}
      session = InternalSession.open(state)

      session =
        InternalSession.apply_event(session, %{
          "type" => "queue_append",
          "queue_id" => 1,
          "kind" => "user_message",
          "wake" => true,
          "dedupe_key" => "next",
          "created_at" => 123,
          "payload" => %{
            "source_message_id" => "next",
            "role" => "user",
            "content" => "next request",
            "trusted_origin" => Map.put(origin, "source_message_id", "next")
          }
        })

      {:ok, session} = InternalSession.load(InternalSession.persist(session))
      assert InternalSession.materialize_pending_input_events(session) == {[], false, 0}
      assert InternalSession.query(session, :guard_disposition_pending?)
      assert "runtime_failure_reply" in InternalSession.query(session, :work_reasons)

      {events, call, authorized} = prepare_notice(session)
      refute authorized
      assert call["args"]["tool"] == unquote(operation)

      assert Map.take(call["args"]["params"], Map.keys(unquote(Macro.escape(route)))) ==
               unquote(Macro.escape(route))

      assert State.validate_events(events) == :ok
      binding = call["runtime_failure_reply"]
      forged = put_in(binding, ["reply_target", "params", "connect_id"], "foreign")
      assert InternalSession.query(session, :guard_failure_prepare, forged) == nil

      reserved = InternalSession.apply_events(session, events)
      {:ok, reserved} = InternalSession.load(InternalSession.persist(reserved))
      assert InternalSession.query(reserved, :guard_failure_prepare, binding) == nil
      cleanup = InternalSession.query(reserved, :guard_failure_cleanup_events, {nil, 124})
      assert cleanup == []
      refusal = %{id: call["id"], name: unquote(operation), status: "guidance", error: true}
      settlement = InternalSession.query(reserved, :guard_failure_settlement, {refusal, cleanup})
      assert State.validate_events(settlement) == :ok
      settled = InternalSession.apply_events(reserved, settlement)
      assert InternalSession.last_ack_message_id(settled) == 3
      assert length(InternalSession.get(settled, :input_queue)) == 1
      {next_events, true, _} = InternalSession.materialize_pending_input_events(settled)
      next = InternalSession.apply_events(settled, next_events)
      assert "next" in InternalSession.query(next, :current_source_ids)
      refute InternalSession.repeated_tool_results_exhausted?(next)
    end
  end

  test "durable guard admission rejects a failure event without its tool owner" do
    event = InternalSession.query(exhausted(), :guard_failure_prepare, reply_binding())
    assert :ok = State.validate_events([event])

    for kind <- ["runtime_failure_reply_attempted", "runtime_failure_reply_settled"] do
      event = Map.put(event, "kind", kind)

      assert {:error, :invalid_runtime_failure_reply} =
               State.validate_events([
                 update_in(event, ["event"], &Map.delete(&1, "tool_call_id"))
               ])

      assert {:error, :invalid_runtime_failure_reply} =
               State.validate_events([put_in(event, ["event", "kind"], "channel_onboarding")])
    end

    assert {:error, :invalid_capability_request_sync} =
             State.validate_events([%{"type" => "capability_request_sync", "settled" => true}])
  end

  defp attempted do
    session = exhausted()
    event = InternalSession.query(session, :guard_failure_prepare, reply_binding())
    assert is_map(event)

    InternalSession.apply_events(session, [
      %{
        "type" => "assistant",
        "message_id" => 3,
        "content" => "",
        "tool_calls" => [%{"id" => @call, "name" => "call", "args" => %{}}]
      },
      event
    ])
  end

  defp result(status) do
    %{
      id: @call,
      name: "im_api.telegram.send_message",
      status: status,
      error: status != "completed"
    }
  end

  test "cold recovery indexes an exhausted source before reserving its failure reply" do
    {:ok, session} = InternalSession.load(InternalSession.persist(exhausted()))

    assert InternalSession.get(session, :runtime_failure_reply) == nil
    assert InternalSession.query(session, :guard_disposition_pending?)
    assert "runtime_failure_reply" in InternalSession.query(session, :work_reasons)
    refute InternalSession.query(session, :needs_transcript_continuation?)
    refute InternalSession.query(session, :has_unprocessed_stable_work?)

    reserved = attempted()
    refute InternalSession.query(reserved, :guard_disposition_pending?)
    assert "runtime_failure_reply" in InternalSession.query(reserved, :work_reasons)
  end

  test "denied send authority reserves a local refusal without granting a provider send" do
    session = exhausted()
    {events, call, authorized} = prepare_notice(session)
    refute authorized
    assert call["runtime_failure_reply"]["source_message_id"] == @source

    reserved = InternalSession.apply_events(session, events)
    refusal = %{result("guidance") | id: call["id"]}
    settlement = InternalSession.query(reserved, :guard_failure_settlement, {refusal, []})
    settled = InternalSession.apply_events(reserved, settlement)

    assert InternalSession.last_ack_message_id(settled) == 3
    refute "runtime_failure_reply" in InternalSession.query(settled, :work_reasons)
    refute Enum.any?(settlement, &(&1["kind"] == "terminal_reply_delivered"))
  end

  test "a model failure cannot cancel running work owned by the same source" do
    state = InternalSession.export(exhausted())

    session =
      InternalSession.open(%{state | repeated_tool_result_streak: nil})
      |> InternalSession.apply_events([
        %{
          "type" => "session_event",
          "kind" => "llm_call_failed",
          "event" => %{"retryable" => false, "transcript_hwm" => 2, "status" => 402}
        }
      ])

    assert InternalSession.query(session, :guard_disposition_pending?)

    running =
      InternalSession.apply_events(session, [
        %{
          "type" => "async_tool_call_started",
          "tool_call_id" => "accepted-work",
          "tool_name" => "env.exec",
          "status" => "running",
          "trusted_origin" => origin(),
          "trusted_origin_source_message_ids" => [@source]
        }
      ])

    assert InternalSession.query(running, :guard_disposition_pending?)

    {events, call, _authorized} = prepare_notice(running)

    assert call["args"]["reply_mode"] == "progress"
    reserved = InternalSession.apply_events(running, events)
    assert InternalSession.query(reserved, :guard_failure_cleanup_events, {nil, 123}) == []
    receipt = %{result("guidance") | id: call["id"]}
    settlement = InternalSession.query(reserved, :guard_failure_settlement, {receipt, []})
    settled = InternalSession.apply_events(reserved, settlement)
    assert InternalSession.last_ack_message_id(settled) == 0

    assert InternalSession.get(settled, :runtime_failure_reply)["notification_outcome"] ==
             "refused"

    refute "runtime_failure_reply" in InternalSession.query(settled, :work_reasons)
    refute InternalSession.query(settled, :has_unprocessed_stable_work?)
    assert "process_local_background_tool_run" in InternalSession.query(settled, :work_reasons)

    assert {:ok, %{"status" => "running"}} =
             InternalSession.lookup_async_call(settled, "accepted-work")

    {:ok, restored} = InternalSession.load(InternalSession.persist(settled))
    refute InternalSession.query(restored, :guard_disposition_pending?)
    assert InternalSession.query(restored, :guard_failure_settlement, {nil, []}) == nil
    refute "runtime_failure_reply" in InternalSession.query(restored, :work_reasons)

    context =
      InternalSession.apply_events(restored, [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 4,
          "source_message_id" => "context",
          "role" => "user",
          "no_wake" => true,
          "trusted_origin" => %{"provider" => "internal", "source_actor_type" => "system"}
        }
      ])

    refute InternalSession.query(context, :has_unprocessed_stable_work?)

    resumed =
      InternalSession.apply_events(context, [
        %{
          "type" => "runtime_message",
          "from_queue" => true,
          "message_id" => 5,
          "runtime_message_id" => "completion",
          "content" => "background completed",
          "trusted_origin" => origin(),
          "trusted_origin_source_message_ids" => [@source]
        }
      ])

    assert InternalSession.query(resumed, :has_unprocessed_stable_work?)

    assert {:ok, %{"status" => "running"}} =
             InternalSession.lookup_async_call(running, "accepted-work")
  end

  test "a source without a destination is settled locally after restart without a send" do
    state = InternalSession.export(exhausted())
    [request, assistant] = state.messages
    malformed = Map.put(origin(), "provider_context", %{})

    session =
      InternalSession.open(%{
        state
        | messages: [Map.put(request, :trusted_origin, malformed), assistant]
      })

    assert InternalSession.query(session, :guard_disposition_pending?)
    assert TerminalReply.disposition_context(session, 3) == nil
    {events, _next_id} = SalixAgent.Repair.plan_session(session)
    assert State.validate_events(events) == :ok
    restored = InternalSession.apply_events(session, events)
    assert InternalSession.last_ack_message_id(restored) == 2
    assert InternalSession.get(restored, :messages) == InternalSession.get(session, :messages)
    refute InternalSession.query(restored, :guard_disposition_pending?)
    assert InternalSession.get(restored, :runtime_failure_reply) == nil
    assert Enum.any?(events, &(&1["kind"] == "runtime_failure_disposed"))
  end

  test "a committed attempt consumes its budget and failure ends only its activation" do
    session = attempted()
    assert InternalSession.query(session, :guard_failure_prepare, reply_binding()) == nil

    events = InternalSession.query(session, :guard_failure_settlement, {result("guidance"), []})
    assert State.validate_events(events) == :ok
    assert TerminalReply.settled?(events)
    refute Enum.any?(events, &(&1["kind"] == "terminal_reply_delivered"))
    fact = Enum.find(events, &(&1["kind"] == "runtime_failure_reply_settled"))
    assert fact["event"]["notification_outcome"] == "refused"
    assert fact["event"]["outcome"] == "blocked"

    settled = InternalSession.apply_events(session, events)
    assert InternalSession.last_ack_message_id(settled) == 3
    assert InternalSession.get(settled, :runtime_failure_reply) == nil
    refute InternalSession.query(settled, :needs_transcript_continuation?)

    assert InternalSession.query(settled, :guard_failure_settlement, {result("guidance"), []}) ==
             nil
  end

  for target? <- [false, true] do
    test "local failure with target=#{target?} preserves foreign accepted work and queued input" do
      state = InternalSession.export(exhausted())
      [request, assistant] = state.messages

      session =
        InternalSession.open(%{
          state
          | messages: [
              if(unquote(target?), do: request, else: Map.delete(request, :trusted_origin)),
              assistant
            ]
        })

      session =
        InternalSession.apply_events(session, [
          %{
            "type" => "async_tool_call_started",
            "tool_call_id" => "foreign-work",
            "tool_name" => "env.exec",
            "status" => "running",
            "trusted_origin" => %{"source_message_id" => "foreign"},
            "trusted_origin_source_message_ids" => ["foreign"]
          },
          %{
            "type" => "queue_append",
            "queue_id" => 1,
            "kind" => "user_message",
            "wake" => true,
            "dedupe_key" => "next",
            "payload" => %{
              "source_message_id" => "next",
              "role" => "user",
              "content" => "next request",
              "trusted_origin" => Map.put(origin(), "source_message_id", "next")
            }
          }
        ])

      events = InternalSession.query(session, :guard_failure_local_settlement)
      assert is_list(events)
      settled = InternalSession.apply_events(session, events)

      assert InternalSession.get(settled, :input_queue) ==
               InternalSession.get(session, :input_queue)

      assert InternalSession.get(settled, :messages) == InternalSession.get(session, :messages)

      assert {:ok, %{"status" => "running"}} =
               InternalSession.lookup_async_call(settled, "foreign-work")

      assert InternalSession.last_ack_message_id(settled) == 2
      {next_events, true, _} = InternalSession.materialize_pending_input_events(settled)
      next = InternalSession.apply_events(settled, next_events)
      assert "next" in InternalSession.query(next, :current_source_ids)
    end
  end

  test "successful failure notification uses the ordinary blocked settlement" do
    session = attempted()

    events =
      TerminalReply.settle(session, %{terminal_reply: reply_binding()}, result("completed"), [
        %{
          "type" => "tool_result",
          "message_id" => 4,
          "tool_call_id" => @call,
          "tool_name" => "im_api.telegram.send_message",
          "status" => "completed",
          "content" => "sent"
        }
      ])

    delivered = Enum.find(events, &(&1["kind"] == "terminal_reply_delivered"))
    assert delivered["event"]["outcome"] == "blocked"
    settled = InternalSession.apply_events(session, events)
    assert InternalSession.last_ack_message_id(settled) == 4
    assert InternalSession.get(settled, :runtime_failure_reply) == nil
  end

  test "recovery retires only owned work and retains a known successful receipt" do
    session =
      InternalSession.apply_events(attempted(), [
        %{
          "type" => "async_tool_call_started",
          "tool_call_id" => @call,
          "tool_name" => "im_api.telegram.send_message",
          "status" => "running",
          "completion_mode" => "external_callback",
          "trusted_origin" => origin(),
          "trusted_origin_source_message_ids" => [@source]
        }
      ])

    cleanup =
      InternalSession.query(session, :guard_failure_cleanup_events, {result("completed"), 1234})

    assert [%{"type" => "async_tool_call_completed", "result" => receipt}] = cleanup
    assert receipt == result("completed")
    events = InternalSession.query(session, :guard_failure_settlement, {receipt, cleanup})
    assert TerminalReply.settled?(events)
    settled = InternalSession.apply_events(session, events)

    assert {:ok, %{"status" => "completed", "result" => ^receipt}} =
             InternalSession.lookup_async_call(settled, @call)
  end

  test "a restart answer after guard recovery does not settle the failure reply again" do
    started = %{
      "type" => "async_tool_call_started",
      "tool_call_id" => @call,
      "tool_name" => "im_api.telegram.send_message",
      "status" => "running",
      "completion_mode" => "external_callback",
      "trusted_origin" => origin(),
      "trusted_origin_source_message_ids" => [@source]
    }

    session = InternalSession.apply_events(attempted(), [started])
    cleanup = InternalSession.query(session, :guard_failure_cleanup_events, {nil, 1234})
    guard = cleanup ++ InternalSession.query(session, :guard_failure_settlement, {nil, cleanup})
    assert TerminalReply.settled?(guard)

    # Crash repair answers a restart request over the session with the guard
    # events applied, as its restart plan sees it.
    request = {"encode_recovered", {Map.delete(started, "type"), result("completed")}}
    {events, _handoff} = SalixAgent.Repair.reader(session).({:restart, request, guard})
    refute Enum.any?(events, &(&1["kind"] == "runtime_failure_reply_settled"))
  end

  test "unknown delivery survives archive and cold snapshot without another dispatch" do
    session = attempted()
    seq = InternalSession.get(session, :last_seq)

    archived =
      InternalSession.apply_events(session, [
        %{
          "type" => "compaction",
          "compacted_through" => 3,
          "compacted_seq" => seq,
          "summary" => "request failed",
          "summary_sequence" => 1
        },
        %{"type" => "archive_advance", "archived_through" => seq, "segments" => []}
      ])

    assert InternalSession.get(archived, :messages) == []
    {:ok, reloaded} = InternalSession.load(InternalSession.persist(archived))
    assert InternalSession.get(reloaded, :runtime_failure_reply) == reply_binding()
    assert InternalSession.query(reloaded, :guard_failure_prepare, reply_binding()) == nil

    events = InternalSession.query(reloaded, :guard_failure_settlement, {nil, []})
    fact = Enum.find(events, &(&1["kind"] == "runtime_failure_reply_settled"))
    assert fact["event"]["outcome"] == "failure_unknown"
    assert fact["event"]["notification_outcome"] == "unknown"
    refute Enum.any?(events, &(&1["type"] == "assistant"))
  end

  test "later human input remains unacknowledged after the earlier failed attempt" do
    session =
      InternalSession.apply_events(attempted(), [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 4,
          "role" => "user",
          "source_message_id" => "next",
          "content" => "next request",
          "trusted_origin" => Map.put(origin(), "source_message_id", "next")
        }
      ])

    events = InternalSession.query(session, :guard_failure_settlement, {nil, []})
    settled = InternalSession.apply_events(session, events)
    assert InternalSession.last_ack_message_id(settled) == 3
    assert Enum.any?(InternalSession.get(settled, :messages), &(&1[:source_message_id] == "next"))
  end

  test "archived later input cannot expand the failed attempt's acknowledgement" do
    session =
      InternalSession.apply_events(attempted(), [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 4,
          "role" => "user",
          "source_message_id" => "next",
          "content" => "next request",
          "trusted_origin" => Map.put(origin(), "source_message_id", "next")
        }
      ])

    seq = InternalSession.get(session, :last_seq)

    archived =
      InternalSession.apply_events(session, [
        %{
          "type" => "compaction",
          "compacted_through" => 4,
          "compacted_seq" => seq,
          "summary" => "both requests",
          "summary_sequence" => 1
        },
        %{"type" => "archive_advance", "archived_through" => seq, "segments" => []}
      ])

    assert InternalSession.get(archived, :messages) == []
    events = InternalSession.query(archived, :guard_failure_settlement, {nil, []})

    assert InternalSession.last_ack_message_id(InternalSession.apply_events(archived, events)) ==
             3
  end

  test "running work and card obligations still prevent failure settlement" do
    session =
      InternalSession.apply_events(attempted(), [
        %{
          "type" => "async_tool_call_started",
          "tool_call_id" => "work",
          "tool_name" => "env.exec",
          "status" => "running"
        }
      ])

    assert InternalSession.query(session, :guard_failure_settlement, {nil, []}) == nil

    state = InternalSession.export(attempted())

    blocked =
      InternalSession.open(%{
        state
        | provider_reply_obligations: %{
            "task" => %{"kind" => "task_card"}
          }
      })

    assert InternalSession.query(blocked, :guard_failure_settlement, {nil, []}) == nil
  end

  test "foreign destinations and unrelated running work cannot gain guard authority" do
    session = exhausted()

    for forged <- [
          Map.put(reply_binding(), "chat_id", "other"),
          Map.put(reply_binding(), "source_message_id", "other")
        ] do
      assert InternalSession.query(session, :guard_failure_prepare, forged) == nil
    end

    running =
      InternalSession.apply_events(session, [
        %{
          "type" => "async_tool_call_started",
          "tool_call_id" => "foreign",
          "tool_name" => "env.exec",
          "status" => "running",
          "trusted_origin" => origin(),
          "trusted_origin_source_message_ids" => ["foreign"]
        }
      ])

    assert InternalSession.query(running, :guard_failure_cleanup_targets) == nil
  end

  # The kernel's failure notice: the reserved events, the notice call, and
  # whether this session may send it.
  defp prepare_notice(session) do
    facts = %{"role" => "worker", "guard_config" => true, "nonce" => 1}

    {machine, [{:commit, events, _opts, _mode}, :continue]} =
      InternalSession.query(session, :loop_step, {nil, {:guard_notice, facts}})

    {events, machine["notice"], machine["notice_authorized"]}
  end
end
