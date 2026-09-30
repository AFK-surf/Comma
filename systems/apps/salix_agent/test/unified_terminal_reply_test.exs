defmodule SalixAgent.UnifiedTerminalReplyTest do
  use ExUnit.Case, async: true

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

  test "a Signal source targets its bound chat with the send operation" do
    state = state("signal", %{"connect_id" => "c", "chat_id" => "peer-aci"})

    assert [%{"tool" => "im_api.signal.send_message", "params" => params}] =
             query(state, :terminal_reply_targets)

    assert params == %{"connect_id" => "c", "chat_id" => "peer-aci"}
    assert query(state, :terminal_reply_source_scope)["source_message_id"] == "source"
  end

  test "Slack source targets disclose only the required-thread reply operation" do
    state = state("slack", %{"connect_id" => "c", "channel_id" => "C", "thread_ts" => "1.000001"})

    assert [%{"tool" => "im_api.slack.reply_message", "params" => params}] =
             query(state, :terminal_reply_targets)

    assert params == %{"connect_id" => "c", "channel" => "C", "thread_ts" => "1.000001"}
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

  test "broadcast, filtered Comma delivery, unknown providers and incomplete targets get no binding" do
    for {provider, destination, extra} <- [
          {"slack", %{"connect_id" => "c", "channel_id" => "C", "thread_ts" => "T"},
           %{"reply_broadcast" => true}},
          {"internal", %{}, %{"delivery_filter" => %{"participant_ids" => []}}}
        ] do
      state = state(provider, destination)
      [target | _] = query(state, :terminal_reply_targets)
      call = call(target)

      assert {:ok, delivered} =
               TerminalReply.authorize(
                 %{call | args: Map.merge(call.args, extra)},
                 context(state)
               )

      refute Map.has_key?(delivered, :terminal_reply)
    end

    for {provider, destination} <- [
          {"unknown", %{"connect_id" => "c"}},
          {"slack", %{"connect_id" => "c", "channel_id" => "C"}},
          {"feishu", %{"connect_id" => "c"}},
          {"signal", %{"connect_id" => "c"}}
        ] do
      assert query(state(provider, destination), :terminal_reply_source_scope) == nil
      assert query(state(provider, destination), :terminal_reply_targets) == []
    end
  end

  # Staging issue #2026: both sends were refused until the model removed
  # final metadata, although neither destination or authorization changed.
  test "Worker Task reports and deferred Router replies accept final metadata" do
    task_origin = %{
      "provider" => "internal",
      "source_actor_type" => "agent",
      "conversation_kind" => "agent_task",
      "conversation_id" => "task",
      "source_message_id" => "source"
    }

    state = %{
      state("internal", %{})
      | messages: [
          %{id: 2, role: "user", source_message_id: "source", trusted_origin: task_origin},
          %{id: 3, role: "assistant", content: "", tool_calls: [%{"id" => "reply"}]}
        ]
    }

    assert query(state, :terminal_reply_targets) == []

    for {role, conversation_id} <- [{"worker", "task"}, {"router", "user-chat"}] do
      call = %{
        id: "reply",
        name: "im_api.internal.send_message",
        args: %{"connect_id" => "internal", "conversation_id" => conversation_id},
        reply_intent: %{"reply_mode" => "final", "final_outcome" => "done"}
      }

      ctx = %{role: role, llm_tool_envelope: true, terminal_reply_context: nil}
      assert {:ok, delivered} = TerminalReply.authorize(call, ctx)
      refute Map.has_key?(delivered, :terminal_reply)
    end
  end
end
