defmodule Salix.Bindings.AgentMeetingTest do
  use ExUnit.Case, async: false

  alias Salix.Bindings.AgentMeeting
  alias Salix.Control
  alias SalixAgent.AgentControl
  alias SalixStore.{CasRecord, Keys}

  alias SalixIM.{
    ConversationServer,
    Conversations,
    ProviderConversationInput,
    RouterConversationInput
  }

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    previous_s3 = Application.get_env(:salix_store, :s3_backend)
    previous_runtime_driver = Application.get_env(:salix_meet, :runtime_driver)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.delete_env(:salix_meet, :runtime_driver)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    assert {:ok, %{"tenant_id" => tenant_id}} =
             Control.create_tenant(%{"name" => "Agent meeting source tenant"})

    assert {:ok, %{"group_id" => group_id}} =
             Control.create_group(%{"name" => "Agent meeting source group"}, tenant_id)

    assert {:ok, %{"agent_id" => router_id}} =
             AgentControl.create(
               %{"group_id" => group_id, "name" => "Router", "role" => "router"},
               tenant_id
             )

    assert {:ok, _group} =
             Control.update_group(group_id, %{"router_agent_id" => router_id}, tenant_id)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      if previous_s3,
        do: Application.put_env(:salix_store, :s3_backend, previous_s3),
        else: Application.delete_env(:salix_store, :s3_backend)

      if previous_runtime_driver,
        do: Application.put_env(:salix_meet, :runtime_driver, previous_runtime_driver),
        else: Application.delete_env(:salix_meet, :runtime_driver)
    end)

    {:ok, tenant_id: tenant_id, group_id: group_id, router_id: router_id}
  end

  test "direct Feishu human origin reaches the provider meeting boundary", %{
    tenant_id: tenant_id,
    group_id: group_id,
    router_id: router_id
  } do
    connect_id = "feishu-direct-human"

    assert {:ok, _connect} =
             CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), %{
               "tenant_id" => tenant_id,
               "group_id" => group_id,
               "connect_id" => connect_id,
               "provider" => "feishu",
               "status" => "connected"
             })

    source_message_id = "im_provider:feishu:#{connect_id}:om_direct_human"

    assert {:error, :meeting_runtime_not_configured} =
             AgentMeeting.join(group_id, %{}, %{
               "agent_id" => router_id,
               "group_id" => group_id,
               "role" => "router",
               "source_message_id" => source_message_id,
               "trusted_origin" => %{
                 "provider" => "feishu",
                 "agent_group_id" => group_id,
                 "source_actor_type" => "provider_user",
                 "source_message_id" => source_message_id,
                 "source_text" => "加入会议 https://meet.google.com/abc-defg-hij",
                 "provider_context" => %{
                   "connect_id" => connect_id,
                   "chat_id" => "oc_direct_human",
                   "chat_type" => "group",
                   "message_id" => "om_direct_human",
                   "sender_type" => "user",
                   "sender_open_id" => "ou_direct_human"
                 }
               }
             })
  end

  test "direct Feishu app origin cannot authorize Router meeting join", %{
    group_id: group_id,
    router_id: router_id
  } do
    source_message_id = "im_provider:feishu:app-direct:om_app_direct"

    assert {:error, :router_current_human_request_required} =
             AgentMeeting.join(group_id, %{}, %{
               "agent_id" => router_id,
               "group_id" => group_id,
               "role" => "router",
               "source_message_id" => source_message_id,
               "trusted_origin" => %{
                 "provider" => "feishu",
                 "agent_group_id" => group_id,
                 "source_actor_type" => "provider_user",
                 "source_message_id" => source_message_id,
                 "source_text" => "加入会议 https://meet.google.com/abc-defg-hij",
                 "provider_context" => %{
                   "connect_id" => "app-direct",
                   "chat_id" => "oc_app_direct",
                   "chat_type" => "group",
                   "message_id" => "om_app_direct",
                   "sender_type" => "app",
                   "sender_open_id" => "cli_untrusted_relay"
                 }
               }
             })
  end

  test "stored Feishu app sender cannot authorize Router meeting join", %{
    group_id: group_id,
    router_id: router_id
  } do
    assert {:ok, %{"conversation_id" => conversation_id}} =
             RouterConversationInput.ensure(group_id)

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    router_participant =
      Enum.find(participants, &(&1["actor_type"] == "agent" and &1["agent_id"] == router_id))

    metadata = %{
      "provider" => "feishu",
      "connect_id" => "feishu-app-source",
      "chat_id" => "oc_app_source",
      "chat_type" => "group",
      "message_id" => "om_app_source",
      "trigger_message_id" => "om_app_source",
      "sender_type" => "app",
      "sender_open_id" => "cli_untrusted_relay"
    }

    assert {:ok, participant_attrs} =
             ProviderConversationInput.participant_attrs(%{"metadata" => metadata})

    assert {:ok, provider_participant} =
             ConversationServer.ensure_group_conversation_provider_participant(
               group_id,
               conversation_id,
               participant_attrs
             )

    source_message_id = "im_provider:feishu:app-source"

    assert {:ok, message_attrs} =
             ProviderConversationInput.provider_message_attrs(
               %{
                 "metadata" => metadata,
                 "content" => "https://meet.google.com/abc-defg-hij",
                 "source_message_id" => source_message_id,
                 "created_at" => System.system_time(:millisecond)
               },
               provider_participant["participant_id"],
               router_participant["participant_id"],
               [],
               []
             )

    # The general projection still calls this `provider_user`; the final
    # meeting authority gate must use Feishu's sender_type instead.
    assert message_attrs["actor_type"] == "provider_user"

    assert {:ok, %{"message_id" => message_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               message_attrs
             )

    assert {:error, :router_current_human_request_required} =
             AgentMeeting.join(group_id, %{}, %{
               "agent_id" => router_id,
               "group_id" => group_id,
               "role" => "router",
               "source_message_id" => source_message_id,
               "trusted_origin" => %{
                 "provider" => "internal",
                 "agent_group_id" => group_id,
                 "conversation_kind" => "user_chat",
                 "source_actor_type" => "provider_user",
                 "conversation_id" => conversation_id,
                 "message_id" => message_id
               }
             })
  end
end
