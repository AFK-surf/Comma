defmodule SalixIM.SourceBoundVisibleReplyTest do
  use ExUnit.Case, async: false

  alias SalixIM.{ConversationInput, ConversationServer, Conversations, SourceBoundVisibleReply}
  alias SalixStore.Ids

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()

    previous_s3 = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SalixIM.TestSupport.Fleet.stop_all!()

      if is_nil(previous_s3) do
        Application.delete_env(:salix_store, :s3_backend)
      else
        Application.put_env(:salix_store, :s3_backend, previous_s3)
      end
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Visible reply"})

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", agent["agent_id"])
      end)

    {:ok, conversation} =
      ConversationInput.create_group_conversation(group_id, %{
        "kind" => "user_chat",
        "title" => "Identity",
        "participants" => [
          %{
            "actor_type" => "user",
            "user_id" => "user-visible-reply",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          },
          %{
            "actor_type" => "agent",
            "agent_id" => agent["agent_id"],
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          }
        ]
      })

    conversation_id = conversation["conversation_id"]

    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(group_id, conversation_id)

    agent_participant = Enum.find(participants, &(&1["agent_id"] == agent["agent_id"]))

    {:ok, source_message} =
      ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
        "actor_type" => "user",
        "user_id" => "user-visible-reply",
        "client_request_id" => "source-visible-reply",
        "content" => "hello",
        "delivery_filter" => %{"participant_ids" => []}
      })

    {:ok, source_identity} =
      SalixIM.ConversationSourceIdentity.encode(
        conversation_id,
        source_message["message_id"],
        agent_participant["participant_id"]
      )

    scope = %{
      "version" => 1,
      "provider" => "internal",
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "conversation_kind" => "user_chat",
      "participant_id" => agent_participant["participant_id"],
      "source_actor_type" => "user",
      "source_message_ids" => [source_identity],
      "source_messages" => [
        %{
          "source_message_id" => source_identity,
          "message_id" => source_message["message_id"]
        }
      ]
    }

    {:ok,
     group_id: group_id,
     agent_id: agent["agent_id"],
     conversation_id: conversation_id,
     source_message_id: source_message["message_id"],
     scope: scope}
  end

  test "authorizes the exact Participant draft source scope", context do
    assert :ok = SourceBoundVisibleReply.authorize(context.agent_id, context.scope)

    wrong_scope =
      put_in(
        context.scope,
        ["source_message_ids"],
        Enum.reverse(context.scope["source_message_ids"]) ++ ["not-a-source"]
      )

    assert {:error, {:permanent, :visible_reply_source_mismatch}} =
             SourceBoundVisibleReply.authorize(context.agent_id, wrong_scope)
  end

  test "retired implicit append fails closed without writing a Message", context do
    assert {:error, {:permanent, :retired_visible_reply_append}} =
             SourceBoundVisibleReply.append(context.agent_id, %{
               "content" => "must not become a canonical Message",
               "scope" => context.scope,
               "idempotency_key" => "retired-visible-reply-append"
             })

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(
               context.group_id,
               context.conversation_id
             )

    assert Enum.map(messages, & &1["message_id"]) == [context.source_message_id]
  end
end
