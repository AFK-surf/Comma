defmodule SalixAgent.TerminalReplyTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.TestSupport.SessionData

  alias SalixAgent.{AsyncToolResults, SessionToolExecution, TerminalReply, Tools}
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State

  # Fixtures stay plain state maps; the runtime API takes the opaque handle.
  defp settle(session, record, result, events),
    do: TerminalReply.settle(InternalSession.open(session), record, result, events)

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

    # The running placeholder stays as committed. Its completion follows as a
    # no-wake runtime message, and the ACK covers it.
    assert [%{id: 3, content: "running"}, completion] = Enum.drop(settled.messages, 2)
    assert completion.role == "runtime"
    assert completion.source_tool_call_id == @call
    assert completion.no_wake == true
    assert settled.last_ack_message_id == 4
    assert settled.wait == nil
    assert TerminalReply.settled?(settled.events)
    refute SessionData.query(settled, :needs_transcript_continuation?)
    assert SessionData.query(settled, :work_reasons) == []
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
    assert settled.last_ack_message_id == 4
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
