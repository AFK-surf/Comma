defmodule SalixIM.AgentDeliveryPayloadTest do
  use SystemsClock.Case, async: false

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)
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

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
