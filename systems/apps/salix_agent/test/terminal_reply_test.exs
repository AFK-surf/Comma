defmodule SalixAgent.TerminalReplyTest do
  use ExUnit.Case, async: true

  alias SalixAgent.TestSupport.SessionData

  alias SalixAgent.{AsyncToolResults, SessionToolExecution, TerminalReply, Tools}
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State

  # Fixtures stay plain state maps; the runtime API takes the opaque handle.
  defp settle(session, record, result, events),
    do: TerminalReply.settle(InternalSession.open(session), record, result, events)

  defp source_scope(session), do: TerminalReply.source_scope(InternalSession.open(session))

  defp recovered_internal_events(record, result, session),
    do:
      SessionToolExecution.recovered_internal_events(
        record,
        result,
        InternalSession.open(session)
      )

  @tool "im_api.telegram.send_message"
  @source "tg-source-A"
  @call "final-A"

  defp telegram_origin do
    %{
      "provider" => "telegram",
      "source_actor_type" => "provider_user",
      "source_message_id" => @source,
      "provider_context" => %{"connect_id" => "telegram-1", "chat_id" => "42"}
    }
  end

  defp reply_binding do
    %{
      "kind" => "telegram",
      "trusted_origin" => telegram_origin(),
      "agent_id" => "agent",
      "session_id" => "session",
      "assistant_id" => 2,
      "last_ack_message_id" => 0,
      "source_message_id" => @source,
      "context_source_message_ids" => [@source],
      "connect_id" => "telegram-1",
      "chat_id" => "42",
      "message_thread_id" => "",
      "tool_call_id" => @call,
      "outcome" => "done"
    }
  end

  defp session do
    SalixAgent.InternalSession.new("agent", "session", %{})
    |> SalixAgent.InternalSession.export()
    |> SessionData.apply_events([
      %{
        "type" => "delivery",
        "from_queue" => true,
        "message_id" => 1,
        "role" => "user",
        "source_message_id" => @source,
        "content" => "answer",
        "trusted_origin" => telegram_origin()
      },
      %{
        "type" => "assistant",
        "message_id" => 2,
        "content" => "",
        "tool_calls" => [
          %{"id" => @call, "name" => "call", "args" => %{}}
        ]
      }
    ])
  end

  defp pending do
    %{
      session_id: "session",
      tool_call_id: @call,
      tool_name: @tool,
      terminal_reply: reply_binding(),
      trusted_origin_source_message_ids: [@source]
    }
  end

  defp result do
    %{
      id: @call,
      name: @tool,
      error: false,
      status: "completed",
      content: ~s({"message_id":42}),
      events: []
    }
  end

  defp running do
    session()
    |> SessionData.apply_events([
      %{
        "type" => "async_tool_call_started",
        "tool_call_id" => @call,
        "tool_name" => @tool,
        "terminal_reply" => reply_binding(),
        "status" => "running"
      },
      %{
        "type" => "tool_result",
        "message_id" => 3,
        "tool_call_id" => @call,
        "tool_name" => @tool,
        "status" => "async_running",
        "content" => "running"
      },
      %{"type" => "wait_set", "wait" => %{"source" => "auto_wait", "tool_call_id" => @call}}
    ])
  end

  defp completion_events, do: AsyncToolResults.internal_events(pending(), result())

  test "successful async final reply atomically persists delivery, retires wait and ACKs its tool tail" do
    events = settle(running(), pending(), result(), completion_events())
    assert State.validate_events(events) == :ok
    refute Enum.any?(events, &(&1["type"] == "queue_append"))
    settled = SessionData.apply_events(running(), events)
    assert settled.last_ack_message_id == 3
    assert settled.wait == nil
    assert TerminalReply.settled?(settled.events)
    refute SessionData.query(settled, :needs_transcript_continuation?)
    assert SessionData.query(settled, :work_reasons) == []
  end

  test "runtime recovery retains its source provenance without taking the Telegram reply destination" do
    origin = %{
      "provider" => "internal",
      "source_actor_type" => "user",
      "source_message_id" => "comma-context"
    }

    state =
      session()
      |> SessionData.apply_events([
        %{
          "type" => "runtime_message",
          "from_queue" => true,
          "message_id" => 3,
          "runtime_message_id" => "recovery-context",
          "runtime_message_type" => "runtime_recovered",
          "content" => "An earlier capability request expired.",
          "diagnostic_visibility" => "model_only",
          "trusted_origin" => origin,
          "trusted_origins" => [origin],
          "trusted_origin_source_message_ids" => ["comma-context"]
        }
      ])

    assert %{"source_message_id" => @source, "context_source_message_ids" => sources} =
             source_scope(state)

    assert sources == [@source, "comma-context"]
    assert source_scope(state)["trusted_origin"] == telegram_origin()
    assert InternalSession.query(InternalSession.open(state), :current_source_ids) == sources

    # The same human owns the reply, but an already accepted call cannot ACK
    # runtime input which arrived after its assistant fence.
    assert settle(state, pending(), result(), completion_events()) == nil

    current =
      SessionData.apply_event(state, %{
        "type" => "assistant",
        "message_id" => 4,
        "tool_calls" => [%{"id" => @call, "name" => "call", "args" => %{}}]
      })

    binding =
      Map.merge(reply_binding(), %{
        "assistant_id" => 4,
        "context_source_message_ids" => sources
      })

    events = [
      %{
        "type" => "tool_result",
        "message_id" => 5,
        "tool_call_id" => @call,
        "status" => "completed",
        "content" => "delivered"
      }
    ]

    assert TerminalReply.settled?(settle(current, %{terminal_reply: binding}, result(), events))
  end

  test "reply settlement rejects forged destinations, origin, and pre-contract bindings" do
    for binding <- [
          Map.put(reply_binding(), "chat_id", "foreign-chat"),
          Map.put(reply_binding(), "connect_id", "foreign-connect"),
          Map.put(reply_binding(), "message_thread_id", "foreign-thread"),
          Map.put(reply_binding(), "trusted_origin", %{"source_message_id" => @source}),
          reply_binding()
          |> Map.delete("context_source_message_ids")
          |> Map.put("source_message_ids", [@source])
        ] do
      assert settle(
               running(),
               %{pending() | terminal_reply: binding},
               result(),
               completion_events()
             ) ==
               nil
    end
  end

  test "synchronous final reply uses the same settlement boundary" do
    events = [
      %{
        "type" => "tool_result",
        "message_id" => 3,
        "tool_call_id" => @call,
        "tool_name" => @tool,
        "content" => "delivered",
        "status" => "completed"
      }
    ]

    events = settle(session(), pending(), result(), events)
    settled = SessionData.apply_events(session(), events)
    assert settled.last_ack_message_id == 3
    refute SessionData.query(settled, :needs_transcript_continuation?)
  end

  test "one Telegram request owns a final while complete trusted context provenance is retained" do
    for {provider, actor_type, no_wake} <- [
          {"internal", "agent", false},
          {"internal", "system", false},
          {"internal", "provider_system", true},
          {"slack", "provider_system", true}
        ] do
      context = %{
        "type" => "delivery",
        "from_queue" => true,
        "message_id" => 3,
        "role" => "user",
        "source_message_id" => "context",
        "content" => "trusted background context",
        "no_wake" => no_wake,
        "trusted_origin" => %{
          "provider" => provider,
          "source_actor_type" => actor_type,
          "source_message_id" => "context"
        }
      }

      current =
        SessionData.apply_events(session(), [
          context,
          %{
            "type" => "assistant",
            "message_id" => 4,
            "tool_calls" => [%{"id" => @call, "name" => "call", "args" => %{}}]
          }
        ])

      assert %{
               "source_message_id" => @source,
               "context_source_message_ids" => [@source, "context"]
             } =
               source_scope(current)

      binding =
        Map.merge(reply_binding(), %{
          "assistant_id" => 4,
          "context_source_message_ids" => [@source, "context"]
        })

      record = %{pending() | terminal_reply: binding}

      result_events = [
        %{
          "type" => "tool_result",
          "message_id" => 5,
          "tool_call_id" => @call,
          "content" => "delivered",
          "status" => "completed"
        }
      ]

      events = settle(current, record, result(), result_events)
      assert TerminalReply.settled?(events)
      assert SessionData.apply_events(current, events).last_ack_message_id == 5

      assert Enum.find(events, &(&1["kind"] == "terminal_reply_delivered"))["event"][
               "context_source_message_ids"
             ] == [@source, "context"]

      # A late context item is not covered by the accepted reply, even though
      # it is trusted and does not introduce a second human request.
      late = Map.merge(context, %{"message_id" => 5, "source_message_id" => "late-context"})
      late = put_in(late, ["trusted_origin", "source_message_id"], "late-context")

      assert settle(
               SessionData.apply_event(current, late),
               record,
               result(),
               result_events
             ) == nil

      for bad_origin <- [
            nil,
            %{"provider" => "internal", "source_actor_type" => "user"},
            %{"provider" => "internal", "source_actor_type" => "unknown"},
            %{
              "provider" => "internal",
              "source_actor_type" => "agent",
              "source_message_id" => "different"
            }
          ] do
        unsafe =
          %{
            current
            | messages:
                Enum.map(current.messages, fn message ->
                  if message.id == 3,
                    do: Map.merge(message, %{trusted_origin: bad_origin, no_wake: false}),
                    else: message
                end)
          }

        assert source_scope(unsafe) == nil
        assert settle(unsafe, record, result(), result_events) == nil
      end
    end
  end

  test "settlement survives snapshot reload and archived facts without fencing later work" do
    settled =
      SessionData.apply_events(
        running(),
        settle(running(), pending(), result(), completion_events())
      )

    assert settled.terminal_reply_ack_hwm == 3

    restored =
      settled
      |> SessionData.reload()

    refute SessionData.query(restored, :needs_transcript_continuation?)

    archived =
      %{settled | compacted_seq: settled.last_seq}
      |> SessionData.apply_events([
        %{"type" => "archive_advance", "archived_through" => settled.last_seq, "segments" => []}
      ])

    assert archived.events == []

    reloaded =
      archived
      |> SessionData.reload()

    assert reloaded.terminal_reply_ack_hwm == 3
    refute SessionData.query(reloaded, :needs_transcript_continuation?)
    assert {:ok, child} = SessionData.fork(settled, "child")
    assert child.terminal_reply_ack_hwm == nil

    next_input =
      SessionData.apply_events(reloaded, [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 4,
          "role" => "user",
          "source_message_id" => "tg-source-B",
          "content" => "next question"
        },
        %{
          "type" => "assistant",
          "message_id" => 5,
          "content" => "",
          "tool_calls" => [
            %{"id" => "B-work", "name" => "call", "args" => %{}}
          ]
        },
        %{
          "type" => "tool_result",
          "message_id" => 6,
          "tool_call_id" => "B-work",
          "content" => "B result"
        },
        %{"type" => "ack", "last_ack_message_id" => 6}
      ])

    assert SessionData.query(next_input, :needs_transcript_continuation?)

    later =
      SessionData.apply_events(reloaded, [
        %{
          "type" => "tool_result",
          "message_id" => 4,
          "tool_call_id" => "later",
          "content" => "new work"
        },
        %{"type" => "ack", "last_ack_message_id" => 4}
      ])

    assert SessionData.query(later, :needs_transcript_continuation?)
  end

  test "ordinary ACKed tool tails retain continuation and legacy snapshots default to no settlement" do
    ordinary =
      SessionData.apply_events(session(), [
        %{
          "type" => "tool_result",
          "message_id" => 3,
          "tool_call_id" => @call,
          "content" => "ordinary"
        },
        %{"type" => "ack", "last_ack_message_id" => 3}
      ])

    assert ordinary.terminal_reply_ack_hwm == nil
    assert SessionData.query(ordinary, :needs_transcript_continuation?)

    legacy =
      ordinary |> Map.delete(:terminal_reply_ack_hwm) |> SessionData.normalize()

    assert legacy.terminal_reply_ack_hwm == nil
    assert SessionData.query(legacy, :needs_transcript_continuation?)
  end

  test "durable pending intent survives reload and staged-result recovery without a model wake" do
    reloaded = SessionData.normalize(running())
    record = Map.put(reloaded.async_tool_calls[@call], "session_id", reloaded.session_id)
    assert record["terminal_reply"] == reply_binding()
    events = recovered_internal_events(record, result(), reloaded)
    assert TerminalReply.settled?(events)
    refute Enum.any?(events, &(&1["type"] == "queue_append"))
    settled = SessionData.apply_events(reloaded, events)
    assert settled.last_ack_message_id == 3
    refute SessionData.query(settled, :needs_transcript_continuation?)
    # Settlement cannot happen again even if called below the actor's exact
    # durable-terminal retry fence.
    assert settle(settled, record, result(), completion_events()) == nil
  end

  test "failed, running, guidance and absent intent cannot settle" do
    for failure <- [
          %{result() | error: true, status: "error"},
          %{result() | status: "async_running"},
          %{result() | status: "guidance"}
        ] do
      assert settle(running(), pending(), failure, completion_events()) == nil
    end

    for invalid <- [
          nil,
          %{},
          Map.put(reply_binding(), "context_source_message_ids", [@source, "B"])
        ] do
      assert settle(
               running(),
               %{pending() | terminal_reply: invalid},
               result(),
               completion_events()
             ) == nil
    end
  end

  test "source, session, ACK and post-dispatch transcript changes fence stale final success" do
    for stale <- [
          %{running() | last_ack_message_id: 1},
          %{running() | agent_id: "other"},
          %{running() | session_id: "other"},
          SessionData.apply_event(running(), %{
            "type" => "delivery",
            "from_queue" => true,
            "message_id" => 4,
            "role" => "user",
            "source_message_id" => "B",
            "content" => "next"
          }),
          SessionData.apply_event(running(), %{
            "type" => "assistant",
            "message_id" => 4,
            "content" => "another round"
          })
        ] do
      assert settle(stale, pending(), result(), completion_events()) == nil
    end

    # Revalidate projected side effects too: no result batch may smuggle B
    # across A's contiguous ACK.
    incoming = %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => 4,
      "role" => "user",
      "source_message_id" => "B",
      "content" => "next"
    }

    assert settle(running(), pending(), result(), completion_events() ++ [incoming]) ==
             nil
  end

  test "running independent work, private repair and required cards keep final success nonterminal" do
    for fenced <- [
          SessionData.apply_event(running(), %{
            "type" => "async_tool_call_started",
            "tool_call_id" => "other",
            "tool_name" => "env.exec",
            "status" => "running"
          }),
          %{running() | visible_reply_repair: %{"status" => "required", "attempts" => 0}},
          %{running() | provider_reply_obligations: %{"card" => %{"kind" => "task_card"}}}
        ] do
      assert settle(fenced, pending(), result(), completion_events()) == nil
    end
  end

  test "model reply metadata neither gates nor settles a Telegram send" do
    ctx = %{
      terminal_reply_context: Map.put(reply_binding(), "eligible", true),
      llm_tool_envelope: true
    }

    call = %{
      id: @call,
      name: @tool,
      args: %{"connect_id" => "telegram-1", "chat_id" => "42", "text" => "answer"},
      reply_intent: %{"reply_mode" => "final", "final_outcome" => "done"}
    }

    padded = %{call | args: Map.put(call.args, "connect_id", " telegram-1 ")}

    for intent <- [
          %{},
          %{"reply_mode" => "progress"},
          %{"reply_mode" => "final", "final_outcome" => "done"},
          %{"reply_mode" => "final"}
        ],
        candidate <- [
          call,
          padded,
          %{call | args: Map.put(call.args, "chat_id", "other")},
          %{call | args: Map.put(call.args, "message_thread_id", "other")}
        ],
        scope_ctx <- [
          ctx,
          %{ctx | terminal_reply_context: nil},
          %{ctx | llm_tool_envelope: false}
        ] do
      assert {:ok, delivered} =
               TerminalReply.authorize(%{candidate | reply_intent: intent}, scope_ctx)

      refute Map.has_key?(delivered, :terminal_reply)
    end
  end

  test "a runtime failure reply retains source checks and its settlement binding" do
    ctx = %{
      terminal_reply_context: Map.put(reply_binding(), "eligible", true),
      llm_tool_envelope: true,
      runtime_failure_delivery: true
    }

    call = %{
      id: @call,
      name: @tool,
      args: %{"connect_id" => "telegram-1", "chat_id" => "42", "text" => "answer"},
      reply_intent: %{"reply_mode" => "final", "final_outcome" => "blocked"}
    }

    assert {:ok, %{terminal_reply: %{"outcome" => "blocked", "tool_call_id" => @call}}} =
             TerminalReply.authorize(call, ctx)

    assert {:ok, progress} =
             TerminalReply.authorize(%{call | reply_intent: %{"reply_mode" => "progress"}}, ctx)

    refute Map.has_key?(progress, :terminal_reply)

    for refused <- [
          %{call | args: Map.put(call.args, "chat_id", "other")},
          %{call | reply_intent: %{}},
          %{call | reply_intent: %{"reply_mode" => "final"}}
        ] do
      assert {:error, _} = TerminalReply.authorize(refused, ctx)
    end

    assert {:error, _} =
             TerminalReply.authorize(call, %{
               ctx
               | terminal_reply_context: Map.put(reply_binding(), "eligible", false)
             })
  end

  test "source replies default to the provider message and preserve an explicit reply target" do
    ctx = %{
      terminal_reply_context:
        reply_binding()
        |> Map.put("eligible", true)
        |> Map.put("reply_to_message_id", "81"),
      llm_tool_envelope: true
    }

    for intent <- [
          %{"reply_mode" => "progress"},
          %{"reply_mode" => "final", "final_outcome" => "done"}
        ] do
      call = %{
        id: @call,
        name: @tool,
        args: %{"connect_id" => "telegram-1", "chat_id" => "42", "text" => "answer"},
        reply_intent: intent
      }

      assert {:ok, reply} = TerminalReply.authorize(call, ctx)
      assert reply.args["reply_to_message_id"] == "81"
      assert reply.args["allow_sending_without_reply"] == true

      explicit = %{call | args: Map.put(call.args, "reply_to_message_id", "73")}
      assert {:ok, reply} = TerminalReply.authorize(explicit, ctx)
      assert reply.args["reply_to_message_id"] == "73"
      refute Map.has_key?(reply.args, "allow_sending_without_reply")

      ordinary = %{call | reply_intent: %{}}

      assert {:ok, reply} =
               TerminalReply.authorize(ordinary, %{ctx | terminal_reply_context: nil})

      refute Map.has_key?(reply.args, "reply_to_message_id")

      other_chat = %{ordinary | args: Map.put(ordinary.args, "chat_id", "other")}
      assert {:ok, reply} = TerminalReply.authorize(other_chat, ctx)
      refute Map.has_key?(reply.args, "reply_to_message_id")
    end
  end

  test "an IFC-refused welcome retires only its source and never claims delivery" do
    source = "im_provider:slack:slack-1:channel_joined:C1:Ev1"

    origin = %{
      "provider" => "slack",
      "source_actor_type" => "provider_user",
      "source_message_id" => source,
      "provider_context" => %{
        "connect_id" => "slack-1",
        "channel_id" => "C1",
        "event_id" => "Ev1",
        "event_type" => "member_joined_channel"
      }
    }

    current = %{
      session()
      | messages:
          Enum.map(session().messages, fn m ->
            if m.id == 1, do: %{m | source_message_id: source, trusted_origin: origin}, else: m
          end),
        active_source_message_ids: [source]
    }

    binding =
      Map.merge(reply_binding(), %{
        "kind" => "channel_onboarding",
        "trusted_origin" => origin,
        "connect_id" => "slack-1",
        "chat_id" => "C1",
        "source_message_id" => source,
        "context_source_message_ids" => [source]
      })

    denied = %{result() | status: "guidance", content: "flow denied"}

    events = [
      %{
        "type" => "tool_result",
        "message_id" => 3,
        "tool_call_id" => @call,
        "status" => "guidance",
        "content" => "flow denied"
      },
      %{"type" => "visible_reply_repair", "status" => "required"}
    ]

    settled_events = settle(current, %{terminal_reply: binding}, denied, events)
    assert State.validate_events(settled_events) == :ok
    settled = SessionData.apply_events(current, settled_events)
    assert settled.last_ack_message_id == 3
    assert settled.terminal_reply_ack_hwm == 3
    refute SessionData.query(settled, :needs_transcript_continuation?)
    refute Enum.any?(settled.events, &(&1["kind"] == "terminal_reply_delivered"))

    assert Enum.find(settled.events, &(&1["kind"] == "channel_onboarding_settled"))["event"][
             "outcome"
           ] == "blocked"

    assert settle(settled, %{terminal_reply: binding}, denied, events) == nil
    # A later human is not covered by this binding, even in another Slack channel.
    next =
      SessionData.apply_event(current, %{
        "type" => "delivery",
        "from_queue" => true,
        "message_id" => 3,
        "role" => "user",
        "source_message_id" => "human-B",
        "content" => "hi",
        "trusted_origin" => %{
          "provider" => "slack",
          "source_actor_type" => "provider_user",
          "source_message_id" => "human-B",
          "provider_context" => %{"channel_id" => "C2"}
        }
      })

    assert settle(next, %{terminal_reply: binding}, denied, events) == nil
  end

  test "call normalization cannot import a forged runtime terminal binding" do
    call = %{
      id: @call,
      name: "call",
      terminal_reply: reply_binding(),
      reply_intent: %{"reply_mode" => "final"},
      args: %{"tool" => "help", "params" => %{}}
    }

    [prepared] = Tools.prepare_for_dispatch([call], %{llm_tool_envelope: true})
    refute Map.has_key?(prepared, :terminal_reply)
    assert prepared[:reply_intent] in [nil, %{}]
  end
end
