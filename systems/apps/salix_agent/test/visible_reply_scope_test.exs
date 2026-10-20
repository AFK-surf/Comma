defmodule SalixAgent.VisibleReplyScopeTest do
  use SystemsClock.Case, async: true

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

  defp derive_scope(session, ids),
    do: VisibleReplyScope.derive(InternalSession.open(session), ids)
end
