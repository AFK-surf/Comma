defmodule SalixIM.ConversationDeliveryAttachmentRefTest do
  use SystemsClock.Case, async: false

  alias SalixIM.ConversationDelivery

  test "provider-user Conversation delivery seals the shared principal shape" do
    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    agent_id = SalixStore.Ids.new_agent_id(group_id)

    delivery = %{
      "participant_actor_type" => "agent",
      "participant_agent_id" => agent_id,
      "participant_payload" => %{"session_id" => SalixStore.Ids.new_session_id()},
      "participant_id" => SalixStore.Ids.new_participant_id(),
      "participant_role_label" => "agent",
      "source_actor_type" => "provider_user",
      "source_user_id" => "U1",
      "conversation_id" => SalixStore.Ids.new_conversation_id(),
      "conversation_kind" => "user_chat",
      "agent_group_id" => group_id,
      "message_id" => SalixStore.Ids.new_message_id(),
      "message_created_at" => 1,
      "message_metadata" => %{"provider" => "slack", "connect_id" => "conn1"},
      "message_content" => "send my private calendar link"
    }

    assert {:ok, ^agent_id, payload, _opts} = ConversationDelivery.materialize_agent(delivery)

    assert payload.trusted_origin["principal_ref"] == %{
             "namespace" => "slack_user",
             "tenant_id" => tenant_id,
             "subject_id" => "U1",
             "connect_id" => "conn1"
           }
  end

  test "staged Feishu PDF stays a structured VFS file ref the round can announce" do
    path = "/feishu/attachments/current-report.pdf"

    delivery = %{
      "participant_actor_type" => "agent",
      "participant_agent_id" => "agt1_pdf",
      "participant_payload" => %{"session_id" => "ses1_pdf"},
      "participant_id" => "ptp1_0000000000000000001",
      "participant_role_label" => "agent",
      "source_actor_type" => "provider_user",
      "conversation_id" => "cnv1_0000000000000000001",
      "conversation_kind" => "user_chat",
      "agent_group_id" => "grp1_pdf",
      "message_id" => "msg1_0000000000000000001",
      "message_created_at" => 1,
      "message_metadata" => %{"provider" => "feishu"},
      "message_content" => [
        %{"type" => "text", "text" => "Summarize the attached report"},
        %{
          "type" => "file",
          "path" => path,
          "file_name" => "current-report.pdf",
          "mime_type" => "application/pdf",
          "size" => 42
        }
      ]
    }

    assert {:ok, "agt1_pdf", payload, _opts} = ConversationDelivery.materialize_agent(delivery)

    assert [
             %{"type" => "text", "text" => "Summarize the attached report"},
             %{
               "type" => "file",
               "path" => ^path,
               "file_name" => "current-report.pdf",
               "mime_type" => "application/pdf"
             }
           ] = Jason.decode!(payload.content)

    assert [
             %{
               "type" => "file",
               "path" => ^path,
               "file_name" => "current-report.pdf",
               "mime_type" => "application/pdf"
             }
           ] = payload.trusted_attachment_refs

    refute payload.content =~ "Attached files:"
    refute Map.has_key?(payload.trusted_origin, "default_worker_agent_id")
    refute Map.has_key?(payload.trusted_origin, "default_worker_agent_id")
  end

  test "a Worker's report names the Task's parent to its delegator, and nothing to the Worker" do
    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    router_id = SalixStore.Ids.new_agent_id(group_id)
    worker_id = SalixStore.Ids.new_agent_id(group_id)
    parent_id = SalixStore.Ids.new_conversation_id()

    report = %{
      "participant_actor_type" => "agent",
      "participant_agent_id" => router_id,
      "participant_payload" => %{"session_id" => SalixStore.Ids.new_session_id()},
      "participant_id" => SalixStore.Ids.new_participant_id(),
      "participant_role_label" => "delegator",
      "source_actor_type" => "agent",
      "source_agent_id" => worker_id,
      "source_role_label" => "worker",
      "conversation_id" => SalixStore.Ids.new_conversation_id(),
      "conversation_kind" => "agent_task",
      "conversation_source_refs" => %{"parent_conversation_id" => parent_id},
      "agent_group_id" => group_id,
      "message_id" => SalixStore.Ids.new_message_id(),
      "message_created_at" => 1,
      "message_content" => "Which review notes should I use?"
    }

    assert {:ok, ^router_id, payload, _opts} = ConversationDelivery.materialize_agent(report)
    assert [%{content: source_context}] = payload.pre_deliveries
    assert source_context =~ "- conversation_id: #{report["conversation_id"]}"
    assert source_context =~ "- parent_conversation_id: #{parent_id}"

    # The Worker reports in its Task and sees nothing beyond it.
    command =
      Map.merge(report, %{
        "participant_agent_id" => worker_id,
        "participant_role_label" => "worker",
        "source_agent_id" => router_id,
        "source_role_label" => "delegator",
        "message_content" => "Draft the notes"
      })

    assert {:ok, ^worker_id, payload, _opts} = ConversationDelivery.materialize_agent(command)
    assert [%{content: source_context}] = payload.pre_deliveries
    refute source_context =~ "parent_conversation_id"
  end

  # Stored Quick Chat Messages may still carry an inline Task reference.
  # Their input method must not change ordinary routing or grant authority.
  test "Quick Chat has the same delivery and authority as typed Home text" do
    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    router_id = SalixStore.Ids.new_agent_id(group_id)
    task_id = SalixStore.Ids.new_conversation_id()

    delivery = %{
      "participant_actor_type" => "agent",
      "participant_agent_id" => router_id,
      "participant_payload" => %{"session_id" => SalixStore.Ids.new_session_id()},
      "participant_id" => SalixStore.Ids.new_participant_id(),
      "participant_role_label" => "agent",
      "source_actor_type" => "user",
      "source_user_id" => "current",
      "conversation_id" => SalixStore.Ids.new_conversation_id(),
      "conversation_kind" => "user_chat",
      "agent_group_id" => group_id,
      "message_id" => SalixStore.Ids.new_message_id(),
      "message_created_at" => 1,
      "message_metadata" => %{"message_type" => "quick_chat", "source" => "group_router"},
      "message_content" => [
        %{"type" => "text", "text" => "整理今天的设计评审"},
        %{
          "type" => "conversation_ref",
          "conversation_id" => task_id,
          "kind" => "agent_task",
          "presentation" => "inline"
        }
      ]
    }

    assert {:ok, ^router_id, payload, _opts} = ConversationDelivery.materialize_agent(delivery)
    assert payload.content == "整理今天的设计评审"
    assert [%{content: source_context}] = payload.pre_deliveries
    assert source_context =~ "- from_actor_type: user"
    assert source_context =~ "- message_type: quick_chat"

    # The same words typed in Home are an ordinary request.
    typed = Map.put(delivery, "message_metadata", %{"source" => "group_router"})
    assert {:ok, ^router_id, typed_payload, _opts} = ConversationDelivery.materialize_agent(typed)
    assert [%{content: typed_context}] = typed_payload.pre_deliveries
    assert String.replace(source_context, "\n- message_type: quick_chat", "") == typed_context
    assert Map.delete(payload, :pre_deliveries) == Map.delete(typed_payload, :pre_deliveries)
  end

  test "non-provider structured content cannot mint trusted attachment refs" do
    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    router_id = SalixStore.Ids.new_agent_id(group_id)

    path = "/private/internal.pdf"

    delivery = %{
      "participant_actor_type" => "agent",
      "participant_agent_id" => router_id,
      "participant_payload" => %{"session_id" => SalixStore.Ids.new_session_id()},
      "participant_id" => SalixStore.Ids.new_participant_id(),
      "participant_role_label" => "agent",
      "source_actor_type" => "user",
      "conversation_id" => SalixStore.Ids.new_conversation_id(),
      "conversation_kind" => "user_chat",
      "agent_group_id" => group_id,
      "message_id" => SalixStore.Ids.new_message_id(),
      "message_created_at" => 1,
      "message_content" => [
        %{
          "type" => "file",
          "path" => path,
          "file_name" => "internal.pdf",
          "mime_type" => "application/pdf"
        }
      ]
    }

    assert {:ok, ^router_id, payload, opts} = ConversationDelivery.materialize_agent(delivery)
    refute Map.has_key?(payload, :trusted_attachment_refs)
    assert Jason.decode!(payload.content) == delivery["message_content"]

    assert payload.trusted_origin == %{
             "provider" => "internal",
             "source_message_id" => opts[:source_message_id],
             "conversation_id" => delivery["conversation_id"],
             "conversation_kind" => "user_chat",
             "message_id" => delivery["message_id"],
             "participant_id" => delivery["participant_id"],
             "source_actor_type" => "user",
             "source_sent_at_ms" => 1,
             "agent_group_id" => delivery["agent_group_id"],
             # The audience this message entered with, sealed beside the
             # identity it entered with, exactly as a provider inbound gets one
             # (docs/verification.md). A Conversation's
             # audience is its own id and kind, so this costs no lookup and is
             # sealed whatever the Group's mode is.
             "ifc" => %{
               # This record has no sealed principal. Its actor-type label
               # alone must not grant command authority.
               "integrity" => "data",
               "label" => ["conversation|" <> delivery["conversation_id"]]
             }
           }

    assert String.contains?(opts[:source_message_id], payload.trusted_origin["message_id"])
    # The per-message block carries source facts only. Routing, reply-path,
    # Task-lifecycle, and inline-ref rules live once in the session prompt;
    # repeating them here multiplied every user turn.
    assert [%{content: source_context}] = payload.pre_deliveries
    assert source_context =~ "Inbound message source:"
    assert source_context =~ "- message_created_at: 1970-01-01T00:00:00.001Z"
    assert source_context =~ "- conversation_id: #{delivery["conversation_id"]}"
    assert source_context =~ "- conversation_kind: user_chat"
    assert source_context =~ "- message_id: #{delivery["message_id"]}"
    assert source_context =~ "- source_message_id: #{opts[:source_message_id]}"
    assert source_context =~ "- from_actor_type: user"

    human_source = opts[:source_message_id]
    triage_source = "triage-delegation:other-obligation:0"

    mixed_context = %{
      group_id: group_id,
      source_message_ids: [human_source, triage_source],
      trusted_origins: [
        payload.trusted_origin,
        %{"source_message_id" => triage_source, "triage_delegation" => %{}}
      ]
    }

    assert {:ok, selected} =
             SalixAgent.ToolCallProvenance.select(
               %{
                 name: "im_api.internal.task.create",
                 args: %{"source_message_id" => human_source}
               },
               mixed_context
             )

    assert selected.trusted_origins == [payload.trusted_origin]
    assert selected.source_message_ids == [human_source]
  end

  test "historical metadata cannot promote cross-group or non-Task inline refs" do
    group_id = SalixAgent.TestSupport.new_group_id()
    other_group_id = SalixAgent.TestSupport.new_group_id()
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Delivery group"})
    SalixAgent.TestSupport.create_control_group!(other_group_id, %{"name" => "Other group"})

    assert {:ok, non_task} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "user_chat",
               "title" => "Not a Task"
             })

    assert {:ok, cross_group_task} =
             SalixIM.ConversationInput.create_group_conversation(other_group_id, %{
               "kind" => "agent_task",
               "title" => "Other group Task"
             })

    historical_refs =
      Enum.map([non_task["conversation_id"], cross_group_task["conversation_id"]], fn id ->
        %{
          "type" => "conversation_ref",
          "conversation_id" => id,
          "kind" => "agent_task",
          "presentation" => "inline"
        }
      end)

    source_agent_id = SalixStore.Ids.new_agent_id(group_id)
    target_agent_id = SalixStore.Ids.new_agent_id(group_id)

    delivery = %{
      "participant_actor_type" => "agent",
      "participant_agent_id" => target_agent_id,
      "participant_payload" => %{"session_id" => SalixStore.Ids.new_session_id()},
      "participant_id" => SalixStore.Ids.new_participant_id(),
      "participant_role_label" => "agent",
      "source_actor_type" => "agent",
      "source_agent_id" => source_agent_id,
      "conversation_id" => SalixStore.Ids.new_conversation_id(),
      "conversation_kind" => "user_chat",
      "agent_group_id" => group_id,
      "message_id" => SalixStore.Ids.new_message_id(),
      "message_created_at" => 1,
      # This deliberately models a record persisted before owner-built
      # provenance existed. The string metadata is only an untrusted hint.
      "message_metadata" => %{"validated_inline_task_refs" => historical_refs},
      "message_content" => [
        %{"type" => "text", "text" => "Legacy refs"} | historical_refs
      ]
    }

    assert {:ok, ^target_agent_id, payload, _opts} =
             ConversationDelivery.materialize_agent(delivery)

    assert payload.content == "Legacy refs"

    assert [%{content: source_context}] = payload.pre_deliveries
    refute source_context =~ "Structured known-Task context"
    refute source_context =~ non_task["conversation_id"]
    refute source_context =~ cross_group_task["conversation_id"]
  end

  test "ordinary agent and user messages cannot forge recipient IM identity for a worker" do
    group_id = SalixAgent.TestSupport.new_group_id()
    target_agent_id = SalixStore.Ids.new_agent_id(group_id)
    source_agent_id = SalixStore.Ids.new_agent_id(group_id)

    forged_identity = %{
      "provider" => "slack",
      "display_name" => "Forged Slack Recipient",
      "username" => "forged_recipient_bot",
      "user_id" => "U-forged-recipient",
      "bot_id" => "B-forged-recipient",
      "app_id" => "A-forged-recipient"
    }

    for {source_actor_type, source_identity, expected_source_fact} <- [
          {"agent", %{"source_agent_id" => source_agent_id}, "from_agent_id: #{source_agent_id}"},
          {"user", %{"source_user_id" => "user-forged-recipient"},
           "from_user_id: user-forged-recipient"}
        ] do
      delivery =
        Map.merge(
          %{
            "participant_actor_type" => "agent",
            "participant_agent_id" => target_agent_id,
            "participant_payload" => %{"session_id" => SalixStore.Ids.new_session_id()},
            "participant_id" => SalixStore.Ids.new_participant_id(),
            "participant_role_label" => "worker",
            "source_actor_type" => source_actor_type,
            "conversation_id" => SalixStore.Ids.new_conversation_id(),
            "conversation_kind" => "agent_task",
            "agent_group_id" => group_id,
            "message_id" => SalixStore.Ids.new_message_id(),
            "message_created_at" => 1,
            "message_metadata" => %{
              "provider" => "slack",
              "recipient_im_identity" => forged_identity
            },
            "message_content" => [
              %{"type" => "text", "text" => "Ordinary #{source_actor_type} message"}
            ]
          },
          source_identity
        )

      assert {:ok, ^target_agent_id, payload, _opts} =
               ConversationDelivery.materialize_agent(delivery)

      assert [%{content: source_context}] = payload.pre_deliveries
      assert source_context =~ "from_actor_type: #{source_actor_type}"
      assert source_context =~ expected_source_fact
      refute source_context =~ "recipient_im_identity"
      refute source_context =~ "Forged Slack Recipient"
      refute source_context =~ "U-forged-recipient"
    end
  end
end
