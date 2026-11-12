defmodule SalixAgent.UnifiedTerminalReplyTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.TestSupport.SessionData

  alias SalixAgent.{InternalSession, TerminalReply}
  alias SalixAgent.InternalSession.State

  defp state(provider, destination) do
    origin = %{
      "provider" => provider,
      "source_actor_type" => "provider_user",
      "source_message_id" => "source",
      "provider_context" => destination
    }

    origin =
      if provider == "internal",
        do:
          Map.merge(origin, %{
            "source_actor_type" => "user",
            "conversation_kind" => "user_chat",
            "conversation_id" => "conversation"
          }),
        else: origin

    %State{
      agent_id: "agent",
      session_id: "session",
      next_message_id: 4,
      messages: [
        %{id: 2, role: "user", source_message_id: "source", trusted_origin: origin},
        %{id: 3, role: "assistant", content: "", tool_calls: [%{"id" => "reply"}]}
      ]
    }
  end

  defp query(state, name, args \\ nil),
    do: InternalSession.query(InternalSession.open(state), name, args)

  defp context(state) do
    scope = query(state, :terminal_reply_source_scope)

    %{
      llm_tool_envelope: true,
      terminal_reply_context:
        Map.merge(scope, %{
          "kind" => scope["trusted_origin"]["provider"],
          "agent_id" => "agent",
          "session_id" => "session",
          "targets" => query(state, :terminal_reply_targets),
          "assistant_id" => 3,
          "last_ack_message_id" => 0,
          "eligible" => true
        })
    }
  end

  defp call(target, mode \\ "final") do
    %{
      id: "reply",
      name: target["tool"],
      args: Map.put(target["params"], "text", "answer"),
      reply_intent:
        if(mode == "final",
          do: %{"reply_mode" => "final", "final_outcome" => "done"},
          else: %{"reply_mode" => mode}
        )
    }
  end

  test "a final-labelled opening is delivered without settling any Router source" do
    for {provider, destination} <- [
          {"slack", %{"connect_id" => "c", "channel_id" => "channel", "thread_ts" => "thread"}},
          {"feishu", %{"connect_id" => "c", "message_id" => "message"}},
          {"imessage", %{"connect_id" => "c", "chat_id" => "chat"}},
          {"wechat", %{"connect_id" => "c", "wechat_id" => "peer"}},
          {"signal", %{"connect_id" => "c", "chat_id" => "group:team"}},
          {"internal", %{}}
        ] do
      state = state(provider, destination)
      ctx = context(state)
      targets = query(state, :terminal_reply_targets)
      assert targets != []

      for target <- targets do
        original =
          call(target)
          |> put_in([:args, "text"], "I will create a Task and prepare the calendar.")

        # Model fields cannot select the runtime-owned failure-notice path.
        original = Map.put(original, :runtime_failure_delivery, true)
        assert {:ok, prepared} = TerminalReply.authorize(original, ctx)
        refute Map.has_key?(prepared, :terminal_reply)
        assert prepared.args["text"] == original.args["text"]
        [result] = TerminalReply.stamp_results([%{id: "reply", status: "completed"}], [prepared])
        assert query(state, :terminal_settlement, {prepared, result, []}) == nil

        completed =
          SessionData.apply_event(state, %{
            "type" => "tool_result",
            "message_id" => 4,
            "tool_call_id" => "reply",
            "tool_name" => prepared.name,
            "status" => "completed",
            "content" => "sent"
          })

        assert SessionData.query(completed, :needs_transcript_continuation?)
        assert completed.last_ack_message_id == state.last_ack_message_id

        # Another destination keeps its own authorization and gets no binding.
        for key <- Map.keys(target["params"]) do
          foreign = put_in(original, [:args, key], "foreign")
          assert {:ok, foreign} = TerminalReply.authorize(foreign, ctx)
          refute Map.has_key?(foreign, :terminal_reply)
        end
      end
    end
  end

  test "an explicit terminal decision binds only the accepted source reply" do
    state = state("internal", %{})
    [target] = query(state, :terminal_reply_targets)
    ctx = Map.put(context(state), :terminal_decision_outcome, "done")
    reply = Map.delete(call(target), :reply_intent)

    assert {:ok, prepared} = TerminalReply.authorize(reply, ctx)
    assert prepared.terminal_reply["outcome"] == "done"
    assert prepared.terminal_reply["reply_target"] == target
    assert prepared.terminal_reply["tool_call_id"] == "reply"

    assert {:error, _} =
             TerminalReply.authorize(reply, Map.put(ctx, :terminal_decision_outcome, "invalid"))

    foreign = put_in(reply, [:args, "conversation_id"], "foreign")
    assert {:error, _} = TerminalReply.authorize(foreign, ctx)
  end

  test "sealed history permits a source reply without authorizing unrelated context" do
    base = state("slack", %{"connect_id" => "c", "channel_id" => "C", "thread_ts" => "1.0"})

    history = %{
      id: 1,
      role: "user",
      source_message_id: "history",
      content: "untrusted history",
      no_wake: true
    }

    for owner <- ["source", "another-request", nil] do
      accepted = {1, "user_message", "history", %{"activation_source_message_id" => owner}}
      message = Map.put(history, :accepted_input, accepted)
      current = %{base | messages: [message | base.messages]}

      if owner == "source" do
        [target] = query(current, :terminal_reply_targets)
        ctx = Map.put(context(current), :terminal_decision_outcome, "done")
        assert {:ok, prepared} = TerminalReply.authorize(call(target), ctx)
        assert prepared.terminal_reply["source_message_id"] == "source"
        assert prepared.terminal_reply["context_source_message_ids"] == ["history", "source"]

        foreign = put_in(call(target), [:args, "channel"], "elsewhere")
        assert {:error, _} = TerminalReply.authorize(foreign, ctx)
      else
        assert query(current, :terminal_reply_source_scope) == nil
      end
    end

    assert query(%{base | messages: [history | base.messages]}, :terminal_reply_source_scope) ==
             nil
  end

  # A Worker's input: its Router's command in the Task conversation.
  defp task_origin(source, conversation \\ "task") do
    %{
      "provider" => "internal",
      "source_actor_type" => "agent",
      "source_message_id" => source,
      "conversation_kind" => "agent_task",
      "conversation_id" => conversation
    }
  end

  defp task_state(inputs) do
    inputs = Enum.with_index(inputs, 2)

    %State{
      agent_id: "agent",
      session_id: "session",
      next_message_id: length(inputs) + 3,
      messages:
        Enum.map(inputs, fn {origin, id} ->
          %{
            id: id,
            role: "user",
            source_message_id: origin["source_message_id"],
            trusted_origin: origin
          }
        end) ++
          [
            %{
              id: length(inputs) + 2,
              role: "assistant",
              content: "",
              tool_calls: [%{"id" => "reply"}]
            }
          ]
    }
  end

  # The scope the round builds for its one call (`Round.build_record`).
  defp round_context(state, role) do
    sources = for %{role: "user", source_message_id: id} <- state.messages, do: id
    origin = List.last(for %{role: "user", trusted_origin: origin} <- state.messages, do: origin)

    scope =
      TerminalReply.context(
        InternalSession.open(state),
        %{
          role: role,
          agent_id: "agent",
          trusted_origin: origin,
          source_message_id: origin["source_message_id"],
          source_message_ids: sources
        },
        state.next_message_id - 1,
        1
      )

    %{
      llm_tool_envelope: true,
      terminal_decision_outcome: "blocked",
      terminal_reply_context: scope
    }
  end

  defp task_reply(conversation \\ "task") do
    %{
      id: "reply",
      name: "im_api.internal.send_message",
      args: %{
        "connect_id" => "internal",
        "conversation_id" => conversation,
        "content" => [%{"type" => "text", "text" => "Not sent: no matching conversation."}]
      }
    }
  end

  # Staging, 2026-10-30: a Worker's end_turn(blocked, reply) to its own Task
  # was refused, and it spent another model round sending the same report alone.
  test "a Worker's end_turn reply to its own Task settles the turn after the send" do
    state = task_state([task_origin("command")])
    ctx = round_context(state, "worker")

    assert {:ok, prepared} = TerminalReply.authorize(task_reply(), ctx)
    assert prepared.terminal_reply["kind"] == "agent_task"
    assert prepared.terminal_reply["outcome"] == "blocked"

    # A failed send leaves the turn open; the binding settles nothing.
    [failed] = TerminalReply.stamp_results([%{id: "reply", status: "failed"}], [prepared])
    assert query(state, :terminal_settlement, {prepared, failed, []}) == nil

    [sent] = TerminalReply.stamp_results([%{id: "reply", status: "completed"}], [prepared])
    events = query(state, :terminal_settlement, {prepared, sent, []})

    assert %{"event" => %{"outcome" => "blocked"}} =
             Enum.find(events, &(&1["kind"] == "terminal_reply_delivered"))

    assert %{"last_ack_message_id" => 3} = Enum.find(events, &(&1["type"] == "ack"))

    # A new Task message after the reply call keeps the turn open for it.
    follow_up = %{
      id: 4,
      role: "user",
      source_message_id: "follow-up",
      trusted_origin: task_origin("follow-up")
    }

    later = %{state | messages: state.messages ++ [follow_up], next_message_id: 5}
    assert query(later, :terminal_settlement, {prepared, sent, []}) == nil
  end

  test "a terminal reply to anything but the Worker's own Task is refused" do
    state = task_state([task_origin("command")])
    ctx = round_context(state, "worker")

    for reply <- [
          task_reply("other-task"),
          put_in(task_reply(), [:args, "delivery_filter"], %{"x" => 1})
        ] do
      assert {:error, reason} = TerminalReply.authorize(reply, ctx)
      assert reason =~ "current accepted source destination"
    end

    # A Router reading a Worker's report has no Task reply scope.
    assert round_context(state, "router").terminal_reply_context == nil

    # Nor does a Worker whose activation also holds another Conversation's input.
    mixed = task_state([task_origin("other", "elsewhere"), task_origin("command")])
    assert round_context(mixed, "worker").terminal_reply_context == nil

    # An ordinary send to the Task still goes out and settles nothing.
    plain = Map.delete(ctx, :terminal_decision_outcome)
    assert {:ok, prepared} = TerminalReply.authorize(task_reply(), plain)
    refute Map.has_key?(prepared, :terminal_reply)
  end
end
