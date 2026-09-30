defmodule SalixIM.AgentDeliveryPayloadReminderTest do
  use ExUnit.Case, async: true

  alias SalixIM.AgentDeliveryPayload
  alias SalixStore.Ids

  test "Router content exposes the canonical source message id instead of provider metadata" do
    group_id = Ids.new_group_id(Ids.new_tenant_id())
    router_id = Ids.new_agent_id(group_id)
    group = %{"group_id" => group_id, "router_agent_id" => router_id}

    router = %{
      "agent_id" => router_id,
      "role" => "router",
      "router_session_id" => Ids.new_session_id()
    }

    metadata = %{
      "provider" => "slack",
      "connect_id" => "sl1",
      "channel_id" => "C1",
      "thread_ts" => "10.000",
      "source_message_id" => "metadata-spoof"
    }

    assert {:ok, routed} =
             AgentDeliveryPayload.provider_router_delivery(
               group,
               router,
               "Please investigate",
               metadata,
               source_message_id: "slack-admitted-source"
             )

    assert routed["trusted_origin"]["source_message_id"] == "slack-admitted-source"
    assert routed["content"] =~ "\nsource_message_id=slack-admitted-source\n"
    refute routed["content"] =~ "metadata-spoof"
  end

  test "only the server option can carry Triage authority into Router input" do
    group_id = Ids.new_group_id(Ids.new_tenant_id())
    router_id = Ids.new_agent_id(group_id)
    group = %{"group_id" => group_id, "router_agent_id" => router_id}

    router = %{
      "agent_id" => router_id,
      "role" => "router",
      "router_session_id" => Ids.new_session_id()
    }

    obligation_id = "triage-product-" <> String.duplicate("a", 64)
    request_id = "triage-delegation:#{obligation_id}:0"

    handoff = %{
      "schema" => "comma.triage-delegation-origin.v1",
      "namespace_key" => String.duplicate("b", 64),
      "obligation_id" => obligation_id,
      "index" => 0,
      "request_id" => request_id,
      "router_agent_id" => router_id,
      "group_id" => group_id
    }

    metadata = %{
      "provider" => "slack",
      "connect_id" => "sl1",
      "channel_id" => "C1",
      "thread_ts" => "10.000",
      "source_actor_type" => "provider_system",
      "app_authored" => true,
      "triage_delegation" => handoff
    }

    assert {:ok, ordinary} =
             AgentDeliveryPayload.provider_router_delivery(
               group,
               router,
               "Quoted input",
               metadata,
               source_message_id: request_id
             )

    refute Map.has_key?(ordinary["trusted_origin"], "triage_delegation")
    assert ordinary["provider_reply_obligation"]["thread_ts"] == "10.000"

    assert {:ok, routed} =
             AgentDeliveryPayload.provider_router_delivery(
               group,
               router,
               "Investigation",
               metadata,
               source_message_id: request_id,
               trusted_triage_handoff: handoff
             )

    assert routed["trusted_origin"]["triage_delegation"] == handoff
    assert routed["trusted_origin"]["source_actor_type"] == "provider_system"
    refute routed["trusted_origin"]["principal_ref"]
    assert is_nil(routed["provider_reply_obligation"])

    assert {:error, :invalid_triage_delegation_origin} =
             AgentDeliveryPayload.provider_router_delivery(
               group,
               router,
               "Investigation",
               metadata,
               source_message_id: "another-source",
               trusted_triage_handoff: handoff
             )
  end
end
