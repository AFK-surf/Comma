defmodule SalixAgent.VisibleReplyScopeTest do
  use ExUnit.Case, async: true

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State
  alias SalixAgent.TestSupport.SessionData
  alias SalixAgent.VisibleReplyScope

  @agent_id "agt1_0000000000000000001_0000000000000000002_0000000000000000003"
  @group_id "grp1_0000000000000000001_0000000000000000002"
  @conversation_id "cnv1_0000000000000000001"
  @participant_id "ptp1_0000000000000000001"
  @message_id "msg1_0000000000000000001"
  @source_id "groupconv:cnv1_0000000000000000001:msg1_0000000000000000001:ptp1_0000000000000000001"

  test "derives an exact scope only from trusted user_chat input" do
    assert {:ok, scope} =
             derive_scope(session([trusted_user_message()]), [@source_id])

    assert scope == %{
             "version" => 1,
             "provider" => "internal",
             "agent_group_id" => @group_id,
             "conversation_id" => @conversation_id,
             "conversation_kind" => "user_chat",
             "participant_id" => @participant_id,
             "source_actor_type" => "user",
             "source_message_ids" => [@source_id],
             "source_messages" => [
               %{"source_message_id" => @source_id, "message_id" => @message_id}
             ]
           }

    assert VisibleReplyScope.idempotency_key(@agent_id, scope) ==
             VisibleReplyScope.idempotency_key(@agent_id, scope)

    refute VisibleReplyScope.idempotency_key(@agent_id, scope) ==
             VisibleReplyScope.idempotency_key("another-agent", scope)
  end

  test "each activation identity gets its own append idempotency key" do
    {:ok, scope} = derive_scope(session([trusted_user_message()]), [@source_id])
    legacy_key = VisibleReplyScope.idempotency_key(@agent_id, scope)

    assert legacy_key ==
             "source-bound-visible-reply:Ky14Ou_B9eGm5yBv9mcDhUVd55YHh-4AmARmZEedN6c"

    assert legacy_key ==
             SalixStore.SourceBoundVisibleReplyIdentity.idempotency_key(@agent_id, scope)

    {:ok, first_activation} = SalixAgent.TestSupport.PresentationScope.with_identity(scope)

    {:ok, second_activation} =
      SalixAgent.TestSupport.PresentationScope.with_identity(
        Map.delete(scope, "response_identity")
      )

    first_key = VisibleReplyScope.idempotency_key(@agent_id, first_activation)
    second_key = VisibleReplyScope.idempotency_key(@agent_id, second_activation)

    assert first_key ==
             SalixStore.SourceBoundVisibleReplyIdentity.idempotency_key(
               @agent_id,
               first_activation
             )

    # A retry of the same activation replays the same key.
    assert first_key == VisibleReplyScope.idempotency_key(@agent_id, first_activation)

    # A fresh activation over the same ordered sources appends on its own key
    # instead of colliding with the earlier canonical message.
    refute first_key == second_key

    # Scopes without an identity keep the identity-free digest so durable
    # legacy intents keep replaying into their canonical append.
    refute first_key == legacy_key
    assert legacy_key == VisibleReplyScope.idempotency_key(@agent_id, scope)
  end

  test "fails closed for untrusted, agent-authored, mixed, stale, and mismatched input" do
    trusted = trusted_user_message()

    assert :none =
             derive_scope(
               session([put_in(trusted, [:trusted_origin, "source_actor_type"], "agent")]),
               [@source_id]
             )

    assert :none =
             derive_scope(
               session([Map.delete(trusted, :trusted_origin)]),
               [@source_id]
             )

    assert :none =
             derive_scope(
               session([
                 trusted,
                 %{id: 2, role: "runtime", content: "wakeable", no_wake: false}
               ]),
               [@source_id]
             )

    assert :none = derive_scope(session([trusted], 1), [@source_id])
    assert :none = derive_scope(session([trusted]), ["another-source"])
  end

  test "an exact trusted async terminal continues the source-bound user turn" do
    tool = %{
      id: 2,
      role: "tool",
      tool_call_id: "async-1",
      status: "async_running",
      content: "tool is still running"
    }

    terminal = %{
      id: 3,
      role: "runtime",
      type: "tool_call_completed",
      source_tool_call_id: "async-1",
      trusted_origin: trusted_user_message().trusted_origin,
      trusted_origin_source_message_ids: [@source_id]
    }

    assert {:ok, _scope} =
             derive_scope(session([trusted_user_message(), tool, terminal]), [
               @source_id
             ])

    assert {:ok, _scope} =
             derive_scope(
               session([trusted_user_message(), tool, %{terminal | type: "tool_call_failed"}]),
               [@source_id]
             )

    assert :none =
             derive_scope(
               session([
                 trusted_user_message(),
                 tool,
                 %{terminal | trusted_origin_source_message_ids: ["another-source"]}
               ]),
               [@source_id]
             )

    assert :none =
             derive_scope(
               session([
                 trusted_user_message(),
                 tool,
                 put_in(terminal.trusted_origin["conversation_id"], "another-conversation")
               ]),
               [@source_id]
             )

    assert :none =
             derive_scope(
               session([
                 trusted_user_message(),
                 %{tool | status: "completed"},
                 terminal
               ]),
               [@source_id]
             )

    assert :none =
             derive_scope(
               session([
                 trusted_user_message(),
                 tool,
                 %{terminal | source_tool_call_id: "another-tool"}
               ]),
               [@source_id]
             )

    assert :none =
             derive_scope(
               session([
                 trusted_user_message(),
                 tool,
                 %{terminal | type: "unrelated_runtime_event"}
               ]),
               [@source_id]
             )
  end

  test "an explicit same-source internal send owns the visible reply" do
    explicit_send = %{
      id: 2,
      role: "assistant",
      tool_calls: [
        %{
          id: "send-1",
          name: "call",
          args: %{
            "tool" => "im_api.internal.send_message",
            "params" => %{"conversation_id" => @conversation_id, "content" => "explicit"}
          }
        }
      ]
    }

    assert :none =
             derive_scope(session([trusted_user_message(), explicit_send]), [
               @source_id
             ])
  end

  test "a retired reply call does not claim source activation ownership" do
    for intent <- [
          %{},
          %{"reply_mode" => "progress"},
          %{"reply_mode" => "final", "final_outcome" => "done"},
          %{"reply_mode" => "final", "final_outcome" => "blocked"}
        ] do
      reply = %{
        id: 2,
        role: "assistant",
        tool_calls: [%{id: "bound-reply", name: "reply", args: Map.put(intent, "text", "answer")}]
      }

      assert {:ok, _scope} = derive_scope(session([trusted_user_message(), reply]), [@source_id])
    end
  end

  test "a successful nested JavaScript source send owns the visible reply" do
    key = VisibleReplyScope.egress_ownership_key(@group_id, @conversation_id, [@source_id])

    fact = %{
      "agent_group_id" => @group_id,
      "conversation_id" => @conversation_id,
      "source_message_ids" => [@source_id],
      "ownership_key" => key
    }

    assert :none =
             derive_scope(
               session([trusted_user_message()], 0, %{key => fact}),
               [@source_id]
             )

    assert {:ok, _scope} =
             derive_scope(
               session(
                 [trusted_user_message()],
                 0,
                 %{key => Map.put(fact, "conversation_id", "another-conversation")}
               ),
               [@source_id]
             )
  end

  test "compacted source ids remain available for the whole unacknowledged activation" do
    scope = activation_scope()

    pending = %{
      id: 3,
      role: "assistant",
      content: "draft",
      tool_calls: [],
      visible_reply_phase: :clean
    }

    compacted = compacted_session(scope, [pending, no_wake_context()])

    assert current_ids(compacted) == [@source_id]

    tool_round =
      put_in(compacted.messages, [
        %{pending | tool_calls: [%{id: "wait-1", name: "wait_for", args: %{}}]},
        no_wake_context()
      ])

    assert current_ids(tool_round) == [@source_id]
    assert {:ok, ^scope} = derive_scope(tool_round, [@source_id])
  end

  test "compacted scope extends for same-conversation input and rejects foreign input" do
    scope = activation_scope()

    pending = %{
      id: 3,
      role: "assistant",
      content: "draft",
      tool_calls: [],
      visible_reply_phase: :clean
    }

    compacted = compacted_session(scope, [pending, no_wake_context()])

    assert {:ok, ^scope} = derive_scope(compacted, [@source_id])

    new_message_id = "msg1_0000000000000000002"
    new_source = "groupconv:#{@conversation_id}:#{new_message_id}:#{@participant_id}"
    same_conversation = trusted_user_message(5, new_source, new_message_id)

    wakeable =
      compacted_session(scope, [
        pending,
        no_wake_context(),
        same_conversation
      ])

    assert current_ids(wakeable) == [@source_id, new_source]

    assert {:ok, extended} =
             derive_scope(wakeable, [@source_id, new_source])

    assert extended["source_message_ids"] == [@source_id, new_source]

    assert Enum.map(extended["source_messages"], & &1["message_id"]) == [
             @message_id,
             new_message_id
           ]

    refute Map.has_key?(extended, "response_identity")

    other_conversation = "cnv1_0000000000000000009"
    foreign_source = "groupconv:#{other_conversation}:#{new_message_id}:#{@participant_id}"

    foreign =
      trusted_user_message(5, foreign_source, new_message_id)
      |> put_in([:trusted_origin, "conversation_id"], other_conversation)

    mixed = compacted_session(scope, [pending, foreign])

    assert current_ids(mixed) == [@source_id, foreign_source]
    assert :none = derive_scope(mixed, [@source_id, foreign_source])

    key = VisibleReplyScope.egress_ownership_key(@group_id, @conversation_id, [@source_id])

    ownership = %{
      "agent_group_id" => @group_id,
      "conversation_id" => @conversation_id,
      "source_message_ids" => [@source_id],
      "ownership_key" => key
    }

    owned = put_in(compacted.visible_reply_egress_facts[key], ownership)
    assert :none = derive_scope(owned, [@source_id])
  end

  test "session materializes and clears nested source-send ownership with the activation ack" do
    key = VisibleReplyScope.egress_ownership_key(@group_id, @conversation_id, [@source_id])

    event = %{
      "type" => "session_event",
      "kind" => "visible_reply_egress",
      "source" => "script_host",
      "method" => "im_api.internal.send_message",
      "event" => %{
        "agent_group_id" => @group_id,
        "conversation_id" => @conversation_id,
        "source_message_ids" => [@source_id],
        "ownership_key" => key
      }
    }

    owned =
      @agent_id
      |> InternalSession.new("session-1", %{})
      |> InternalSession.apply_event(event)
      |> InternalSession.export()

    assert owned.visible_reply_egress_facts[key] == event["event"]

    acked =
      SessionData.apply_event(owned, %{
        "type" => "ack",
        "last_ack_message_id" => 1
      })

    assert acked.visible_reply_egress_facts == %{}
  end

  test "durable intent remains indexed until a matching terminal event" do
    session_id = "ses1_0000000000000000001"

    {:ok, scope} = derive_scope(session([trusted_user_message()]), [@source_id])
    {:ok, scope} = SalixAgent.TestSupport.PresentationScope.with_identity(scope)
    key = VisibleReplyScope.idempotency_key(@agent_id, scope)

    intent = %{
      "type" => "visible_reply_intent",
      "session_id" => session_id,
      "assistant_message_id" => 1,
      "content" => "Hello",
      "scope" => scope,
      "idempotency_key" => key,
      "created_at" => 100
    }

    assert :ok = State.validate_events([intent])

    pending =
      @agent_id
      |> InternalSession.new(session_id, %{})
      |> InternalSession.apply_events([intent])
      |> InternalSession.normalize()
      |> InternalSession.export()

    assert SessionData.query(pending, :pending_visible_reply?)

    assert pending.visible_reply_intent["scope"]["response_identity"] ==
             scope["response_identity"]

    assert "visible_reply_commit" in SessionData.query(pending, :work_reasons)

    unrelated =
      SessionData.apply_event(pending, %{
        "type" => "visible_reply_committed",
        "idempotency_key" => "another-key"
      })

    assert SessionData.query(unrelated, :pending_visible_reply?)

    committed =
      SessionData.apply_event(
        pending,
        %{
          "type" => "visible_reply_committed",
          "session_id" => session_id,
          "idempotency_key" => key,
          "created_at" => 101
        }
      )

    refute SessionData.query(committed, :pending_visible_reply?)
    refute "visible_reply_commit" in SessionData.query(committed, :work_reasons)
  end

  defp session(messages, last_ack \\ 0, visible_reply_egress_facts \\ %{}) do
    %{
      messages: messages,
      events: [],
      visible_reply_egress_facts: visible_reply_egress_facts,
      last_ack_message_id: last_ack,
      visible_reply_repair: nil
    }
  end

  defp trusted_user_message do
    %{
      id: 1,
      role: "user",
      content: "hello",
      source_message_id: @source_id,
      trusted_origin: %{
        "provider" => "internal",
        "agent_group_id" => @group_id,
        "conversation_id" => @conversation_id,
        "conversation_kind" => "user_chat",
        "message_id" => @message_id,
        "participant_id" => @participant_id,
        "source_actor_type" => "user"
      }
    }
  end

  defp trusted_user_message(id, source_message_id, message_id) do
    trusted_user_message()
    |> Map.merge(%{id: id, source_message_id: source_message_id})
    |> put_in([:trusted_origin, "message_id"], message_id)
  end

  defp activation_scope do
    {:ok, scope} = derive_scope(session([trusted_user_message()]), [@source_id])
    {:ok, scope} = SalixAgent.TestSupport.PresentationScope.with_identity(scope)
    scope
  end

  defp compacted_session(scope, messages) do
    session(messages, 1)
    |> Map.merge(%{
      compacted_through: 2,
      visible_reply_activation_scope: scope
    })
  end

  defp no_wake_context do
    %{id: 4, role: "user", content: "internal context", no_wake: true}
  end

  defp derive_scope(session, ids),
    do: VisibleReplyScope.derive(InternalSession.open(session), ids)

  defp current_ids(session),
    do: VisibleReplyScope.current_source_message_ids(InternalSession.open(session))
end
