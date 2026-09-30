defmodule SalixIM.AgentDeliveryPayloadTest do
  use ExUnit.Case, async: false

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_backend)
      restore(:salix_agent, :group_context_mod, prev_group_context)
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id)
    router = create_agent!("router", group_id, tenant_id)
    worker = create_agent!("worker", group_id, tenant_id)
    meeting = create_agent!("meeting", group_id, tenant_id)

    group =
      SalixAgent.TestSupport.create_control_group!(group_id, %{
        "router_agent_id" => router["agent_id"],
        "billing_owner" => %{"salix_tenant_id" => tenant_id}
      })

    %{group: group, router: router, worker: worker, meeting: meeting}
  end

  test "normalizes conversation delivery session hints by agent role", %{
    group: group,
    router: router,
    worker: worker,
    meeting: meeting
  } do
    conversation = %{"conversation_id" => "conv_actor", "title" => "Actor chat"}
    worker_session_id = SalixStore.Ids.new_session_id()
    meeting_session_id = SalixStore.Ids.new_session_id()

    router_conversation = %{
      "conversation_id" => group["router_conversation_id"],
      "title" => "Bridge chat"
    }

    assert {:ok, router_inbox_payload} =
             SalixIM.AgentDeliveryPayload.participant_payload(
               group,
               router,
               router_conversation,
               %{"participant_id" => "agent", "agent_id" => router["agent_id"]}
             )

    {:ok, router_session_id} = SalixStore.RuntimeIds.persisted_router_session_id(router)

    assert router_inbox_payload["session_id"] == router_session_id

    assert {:ok, router_payload} =
             SalixIM.AgentDeliveryPayload.participant_payload(
               group,
               router,
               conversation,
               %{"participant_id" => "router", "agent_id" => router["agent_id"]}
             )

    # Router participants and deliveries both use the canonical group router
    # session. Conversation source context is carried by the message delivery,
    # not by inventing a router-local per-conversation session.
    assert router_payload == %{"session_id" => router_session_id}

    assert {:ok, worker_payload} =
             SalixIM.AgentDeliveryPayload.participant_payload(
               group,
               worker,
               conversation,
               %{
                 "participant_id" => "worker",
                 "agent_id" => worker["agent_id"],
                 "payload" => %{"session_id" => worker_session_id}
               }
             )

    assert worker_payload["session_id"] == worker_session_id

    assert {:ok, meeting_payload} =
             SalixIM.AgentDeliveryPayload.participant_payload(
               group,
               meeting,
               conversation,
               %{
                 "participant_id" => "meeting",
                 "agent_id" => meeting["agent_id"],
                 "payload" => %{"session_id" => meeting_session_id}
               }
             )

    assert meeting_payload["session_id"] == meeting_session_id
  end

  test "router session id stays aligned with the router actor canonical rule", %{router: router} do
    assert {:ok, router_session_id} = SalixStore.RuntimeIds.persisted_router_session_id(router)
    assert router_session_id == router["router_session_id"]
  end

  test "router participant payload and provider inbound delivery shape are IM-owned", %{
    group: group,
    router: router,
    worker: worker
  } do
    router_conversation = %{
      "conversation_id" => group["router_conversation_id"],
      "title" => "Bridge chat"
    }

    participant = %{"participant_id" => "agent", "agent_id" => router["agent_id"]}

    assert {:ok, %{"session_id" => router_session_id}} =
             SalixIM.AgentDeliveryPayload.participant_payload(
               group,
               router,
               router_conversation,
               participant
             )

    assert router_session_id == router["router_session_id"]

    assert {:ok, %{"session_id" => router_session_id}} =
             SalixIM.AgentDeliveryPayload.participant_payload(
               group,
               router,
               %{"conversation_id" => "conv_actor", "title" => "Actor chat"},
               %{"participant_id" => "router", "agent_id" => router["agent_id"]}
             )

    assert {:ok, delivery} =
             SalixIM.AgentDeliveryPayload.provider_router_delivery(
               group,
               router,
               "hello from slack",
               %{
                 "provider" => "slack",
                 "channel_id" => "C1",
                 "thread_ts" => "1.0",
                 "message_ts" => "1.1",
                 "user_id" => "U1",
                 "connect_id" => "conn1"
               },
               source_message_id: "im_provider:slack:event-1",
               trusted_source_text: "hello from slack"
             )

    assert get_in(delivery, ["participant_payload", "session_id"]) == router_session_id
    assert delivery["participant_payload"] == %{"session_id" => router_session_id}
    assert delivery["content"] =~ "provider=slack"
    assert delivery["content"] =~ "channel_id=C1"
    assert delivery["content"] =~ "hello from slack"
    refute delivery["content"] =~ "next_before_ts"
    assert delivery["delivery_billing_context"]["entrypoint"] == "im_router"
    assert delivery["delivery_billing_context"]["im_provider"] == "slack"

    assert delivery["trusted_origin"] == %{
             "provider" => "slack",
             "agent_group_id" => group["group_id"],
             "source_actor_type" => "provider_user",
             "source_message_id" => "im_provider:slack:event-1",
             "source_text" => "hello from slack",
             "principal_ref" => %{
               "namespace" => "slack_user",
               "tenant_id" => group["tenant_id"],
               "subject_id" => "U1",
               "connect_id" => "conn1"
             },
             "provider_context" => %{
               "connect_id" => "conn1",
               "channel_id" => "C1",
               "thread_ts" => "1.0",
               "message_ts" => "1.1",
               "user_id" => "U1"
             }
           }

    assert {:ok, first_thread_delivery} =
             SalixIM.AgentDeliveryPayload.provider_router_delivery(
               group,
               router,
               "first thread trigger",
               %{
                 "provider" => "slack",
                 "connect_id" => "conn1",
                 "channel_id" => "C1",
                 "thread_ts" => "1.0",
                 "message_ts" => "1.9",
                 "slack_thread_context" => %{
                   "status" => "preloaded",
                   "message_count" => 10,
                   "has_more" => true,
                   "next_after_ts" => "1.2",
                   "latest_ts" => "1.9",
                   "root_preloaded" => true
                 }
               }
             )

    assert first_thread_delivery["content"] =~ "first entry to this Slack thread"
    assert first_thread_delivery["content"] =~ "Slack-history user delivery"
    assert first_thread_delivery["content"] =~ "im_api.slack.get_thread_replies"
    assert first_thread_delivery["content"] =~ "oldest=1.2"
    assert first_thread_delivery["content"] =~ "latest=1.9"
    assert first_thread_delivery["content"] =~ "inclusive=false"
    assert first_thread_delivery["content"] =~ "root_already_preloaded=true"
    assert first_thread_delivery["content"] =~ "limit=15"
    assert first_thread_delivery["content"] =~ "next_cursor"
    assert first_thread_delivery["content"] =~ "completed and released"
    assert first_thread_delivery["content"] =~ "local conversations.replies lease"
    refute first_thread_delivery["content"] =~ "shared lease window"
    assert first_thread_delivery["content"] =~ "retry_after"
    assert first_thread_delivery["content"] =~ "im_api.slack.fetch_file"

    assert first_thread_delivery["provider_reply_obligation"] == %{
             "provider" => "slack",
             "connect_id" => "conn1",
             "channel" => "C1",
             "thread_ts" => "1.0"
           }

    assert {:ok, empty_thread_delivery} =
             SalixIM.AgentDeliveryPayload.provider_router_delivery(
               group,
               router,
               "empty thread trigger",
               %{
                 "provider" => "slack",
                 "connect_id" => "conn1",
                 "channel_id" => "C1",
                 "thread_ts" => "1.0",
                 "message_ts" => "1.1",
                 "slack_thread_context" => %{
                   "status" => "preloaded",
                   "message_count" => 0,
                   "has_more" => false,
                   "next_after_ts" => nil,
                   "latest_ts" => "1.1",
                   "root_preloaded" => false
                 }
               }
             )

    assert empty_thread_delivery["content"] =~ "found no messages before the current trigger"
    assert empty_thread_delivery["content"] =~ "Slack-history delivery is empty"
    refute empty_thread_delivery["content"] =~ "root_already_preloaded=true"
    refute empty_thread_delivery["content"] =~ "next_cursor"

    assert {:ok, unavailable_thread_delivery} =
             SalixIM.AgentDeliveryPayload.provider_router_delivery(
               group,
               router,
               "unavailable thread trigger",
               %{
                 "provider" => "slack",
                 "connect_id" => "conn1",
                 "channel_id" => "C1",
                 "thread_ts" => "1.0",
                 "message_ts" => "1.1",
                 "slack_thread_context" => %{
                   "status" => "unavailable",
                   "message_count" => 0,
                   "has_more" => true,
                   "next_after_ts" => nil,
                   "latest_ts" => "1.1",
                   "root_preloaded" => false
                 }
               }
             )

    assert unavailable_thread_delivery["content"] =~ "prior-message page was unavailable"
    assert unavailable_thread_delivery["content"] =~ "did not complete"
    assert unavailable_thread_delivery["content"] =~ "do not assume whether Slack accepted"
    assert unavailable_thread_delivery["content"] =~ "Retry normally"
    assert unavailable_thread_delivery["content"] =~ "latest=1.1"
    assert unavailable_thread_delivery["content"] =~ "next_cursor"
    refute unavailable_thread_delivery["content"] =~ "automatic preload already used"
    refute unavailable_thread_delivery["content"] =~ "root_already_preloaded=true"

    assert {:ok, smoke_delivery} =
             SalixIM.AgentDeliveryPayload.provider_router_delivery(
               group,
               router,
               "smoke check",
               %{
                 "provider" => "feishu",
                 "connect_id" => "conn2",
                 "check_kind" => "first_message_smoke"
               }
             )

    assert get_in(smoke_delivery, ["participant_payload", "session_id"]) == router_session_id
    assert smoke_delivery["participant_payload"] == %{"session_id" => router_session_id}
    assert smoke_delivery["content"] =~ "im_api.feishu.get_chat_history"
    assert smoke_delivery["content"] =~ "im_api.feishu.get_thread_replies"
    assert smoke_delivery["content"] =~ "im_api.feishu.list_chat_files"
    assert smoke_delivery["content"] =~ "im_api.feishu.fetch_message_resource"
    assert smoke_delivery["content"] =~ "tool_call.get_result"
    assert smoke_delivery["content"] =~ "without offset or limit"

    assert smoke_delivery["content"] =~
             "Do not claim that Feishu history or group-message attachments are unavailable"

    assert smoke_delivery["provider_reply_obligation"] == nil

    assert {:error, :not_group_router_agent} =
             SalixIM.AgentDeliveryPayload.provider_router_delivery(group, worker, "hello", %{
               "provider" => "slack"
             })
  end

  test "direct Router principal stays absent for system or incomplete Slack origins", %{
    group: group,
    router: router
  } do
    base_metadata = %{
      "provider" => "slack",
      "channel_id" => "C1",
      "thread_ts" => "1.0",
      "message_ts" => "1.1",
      "user_id" => "U1",
      "connect_id" => "conn1"
    }

    for metadata <- [
          Map.put(base_metadata, "app_authored", true),
          base_metadata
          |> Map.put("provider", "feishu")
          |> Map.put("sender_type", "app")
          |> Map.put("sender_open_id", "ou_app")
          |> Map.delete("user_id"),
          base_metadata
          |> Map.put("provider", "telegram")
          |> Map.put("from_is_bot", true)
          |> Map.put("from_user_id", "9001")
          |> Map.delete("user_id"),
          Map.delete(base_metadata, "user_id"),
          Map.delete(base_metadata, "connect_id")
        ] do
      assert {:ok, delivery} =
               SalixIM.AgentDeliveryPayload.provider_router_delivery(
                 group,
                 router,
                 "untrusted principal",
                 metadata,
                 source_message_id: "im_provider:slack:event-system",
                 trusted_source_text: "untrusted principal"
               )

      refute Map.has_key?(delivery["trusted_origin"], "principal_ref")

      if metadata["app_authored"] == true or metadata["sender_type"] == "app" or
           metadata["from_is_bot"] == true do
        assert delivery["trusted_origin"]["source_actor_type"] == "provider_system"
      end
    end
  end

  test "worker participant payload uses origin session only when it is the delegator", %{
    group: group,
    worker: worker
  } do
    conversation = %{"conversation_id" => "task_actor", "title" => "Task chat"}
    origin_session_id = SalixStore.Ids.new_session_id()

    assert {:ok, %{"session_id" => ^origin_session_id}} =
             SalixIM.AgentDeliveryPayload.materialize_participant_payload(
               group,
               worker,
               conversation,
               %{
                 "participant_id" => "delegator",
                 "agent_id" => worker["agent_id"],
                 "role_label" => "delegator"
               },
               origin_session_id: origin_session_id
             )

    assert {:ok, %{"session_id" => worker_session_id}} =
             SalixIM.AgentDeliveryPayload.materialize_participant_payload(
               group,
               worker,
               conversation,
               %{
                 "participant_id" => "worker",
                 "agent_id" => worker["agent_id"],
                 "role_label" => "worker"
               },
               origin_session_id: origin_session_id
             )

    assert SalixStore.Ids.valid_session_id?(worker_session_id)
    refute worker_session_id == origin_session_id
  end

  defp create_agent!(role, group_id, tenant_id) do
    SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
      role: role,
      group_id: group_id
    })
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
