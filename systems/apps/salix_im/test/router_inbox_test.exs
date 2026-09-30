defmodule SalixIM.RouterInboxTest do
  use ExUnit.Case, async: true

  alias SalixIM.AgentDeliveryPayload

  test "router billing context is derived from the stored group owner" do
    group = %{
      "group_id" => "group_bridge",
      "tenant_id" => "tenant_bridge",
      "billing_owner" => %{
        "billing_account_id" => "ba_bridge",
        "surface" => "bridge",
        "product_owner_type" => "organization",
        "product_owner_id" => "org_1",
        "project_id" => "project_1",
        "salix_tenant_id" => "tenant_bridge",
        "salix_group_id" => "group_bridge",
        "router_agent_id" => "stale_router",
        "charge_policy" => "platform_paid"
      }
    }

    router_agent = %{"agent_id" => "router_agent"}

    context =
      AgentDeliveryPayload.router_billing_context(group, router_agent, %{
        "provider" => "slack",
        "connect_id" => "slack_1",
        "billing_account_id" => "spoofed"
      })

    assert context["billing_account_id"] == "ba_bridge"
    assert context["entrypoint"] == "im_router"
    assert context["actor_type"] == "external_user"
    assert context["salix_agent_id"] == "router_agent"
    assert context["router_agent_id"] == "router_agent"
    assert context["im_provider"] == "slack"
    assert context["im_connect_id"] == "slack_1"
    refute context["billing_account_id"] == "spoofed"

    worker_context =
      AgentDeliveryPayload.participant_delivery_defaults(
        group,
        %{"agent_id" => "worker_agent", "role" => "worker"},
        %{"conversation_id" => "cnv1_worker", "title" => "Worker task"}
      )["delivery_billing_context"]

    assert worker_context["billing_account_id"] == "ba_bridge"
    assert worker_context["product_owner_id"] == "org_1"
    assert worker_context["salix_agent_id"] == "worker_agent"
    assert worker_context["entrypoint"] == "conversation_message"
  end
end
