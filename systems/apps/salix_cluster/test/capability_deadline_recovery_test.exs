defmodule SalixCluster.CapabilityDeadlineRecoveryTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  alias SalixStore.Ids
  alias SalixStore.S3.Fake

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixAgent.TestSupport.reset_session_work!()
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
    prev_placement = SystemsRuntime.get_env(:salix_agent, :placement)
    SystemsRuntime.put_env(:salix_store, :s3_backend, Fake)
    start_supervised!(Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
      put_or_delete_env(:salix_agent, :group_context_mod, prev_group_context)
      put_or_delete_env(:salix_agent, :placement, prev_placement)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    create_owned_control!(agent)

    {:ok, agent: agent, session: Ids.new_session_id()}
  end

  describe "location deadlines" do
    test "expires the tool after its session wait was cleared", ctx do
      request = location_request!(ctx, SystemsClock.system_time(:second) - 1)
      assert %{failed: 0} = SalixAgent.SessionWorkRecovery.sweep()
      assert_location_terminal(ctx, "failed")
      assert {:ok, %{"status" => "expired"}} = location_record(request)

      assert {:error, {:conflict, :already_settled}} =
               SalixAgent.CapabilityRequests.share_location(
                 request["group_id"],
                 request["request_id"],
                 %{"status" => "success", "location" => %{"latitude" => 1, "longitude" => 2}},
                 request["tenant_id"]
               )

      assert_location_terminal(ctx, "failed")
    end

    test "slow result acceptance retains due work and does not block another Session", ctx do
      blocked = location_request!(ctx, SystemsClock.system_time(:second) - 1)
      healthy_ctx = %{ctx | session: Ids.new_session_id()}
      healthy = location_request!(healthy_ctx, SystemsClock.system_time(:second) - 1)
      {:ok, _} = SalixAgent.Fleet.ensure_started(ctx.agent, create: false)
      {:ok, actor} = SalixAgent.InternalSessionFleet.ensure_started(ctx.agent, ctx.session)
      :ok = :sys.suspend(actor)

      on_exit(fn -> :sys.resume(actor) end)

      result = SalixAgent.SessionWorkRecovery.sweep(session_work_wake_timeout: 50)
      assert result.failed > 0
      assert {:ok, %{"status" => "expired"}} = location_record(blocked)
      assert {:ok, %{"status" => "expired"}} = location_record(healthy)

      %{rows: [[blocked_due, healthy_done]]} =
        SalixStore.Repo.query!(
          "SELECT b.result_delivery_due_at IS NOT NULL, h.result_delivered_at IS NOT NULL " <>
            "FROM salix_capability_requests b, salix_capability_requests h " <>
            "WHERE b.group_id=$1 AND b.request_id=$2 AND h.group_id=$1 AND h.request_id=$3",
          [blocked["group_id"], blocked["request_id"], healthy["request_id"]]
        )

      assert blocked_due
      assert healthy_done
    end

    test "a deadline retry preserves a location response that won before expiry", ctx do
      request = location_request!(ctx, SystemsClock.system_time(:second) + 60)
      shared = %{"status" => "success", "location" => %{"latitude" => 1, "longitude" => 2}}

      assert {:ok, %{"status" => "completed", "response_payload" => response}} =
               SalixAgent.CapabilityRequests.share_location(
                 request["group_id"],
                 request["request_id"],
                 shared,
                 request["tenant_id"]
               )

      assert %{"latitude" => 1, "longitude" => 2, "read_at" => _read_at} = response["location"]

      assert :ok =
               SalixAgent.CapabilityRequests.expire_location(
                 request["group_id"],
                 request["request_id"],
                 request["tenant_id"]
               )

      assert_location_terminal(ctx, "completed")
      assert {:ok, %{"response_payload" => ^response}} = location_record(request)
    end
  end

  defp location_request!(ctx, deadline) do
    seed_location_call!(ctx, deadline)
    {:ok, request} = create_location_request(ctx, deadline)
    request
  end

  defp seed_location_call!(ctx, deadline) do
    {:ok, _} =
      SalixAgent.InternalSessionStore.prepare_commit(ctx.agent, ctx.session, [
        %{"type" => "session_created", "session_id" => ctx.session},
        %{
          "type" => "async_tool_call_started",
          "session_id" => ctx.session,
          "tool_call_id" => "location-call",
          "tool_name" => "location.request",
          "status" => "running",
          "completion_mode" => "external_callback",
          "completion_owner" => "direct_poll",
          "started_at" => (deadline - 120) * 1000
        }
      ])

    :ok
  end

  defp create_location_request(ctx, deadline) do
    SalixAgent.CapabilityRequests.create_capability_request(%{
      "source_agent_id" => ctx.agent,
      "source_session_id" => ctx.session,
      "tool_call_id" => "location-call",
      "request_type" => "location",
      "request_payload" => %{"location" => %{"reason" => "test location"}},
      "expires_at" => deadline
    })
  end

  defp location_record(request) do
    SalixAgent.CapabilityRequests.get(
      request["group_id"],
      request["request_id"],
      request["tenant_id"]
    )
  end

  defp assert_location_terminal(ctx, status) do
    {:ok, session} = SalixAgent.InternalSessionStore.read(ctx.agent, ctx.session)
    state = SalixAgent.InternalSession.export(session)
    refute state.async_tool_calls["location-call"]["status"] == "running"

    assert Enum.any?(
             state.async_results,
             &(&1["tool_call_id"] == "location-call" and &1["status"] == status)
           )

    # Result publication can precede request synchronization. The indexed
    # recovery path must retire that terminal projection without new input.
    assert %{failed: 0} = SalixAgent.SessionWorkRecovery.sweep()

    assert eventually(fn ->
             {:ok, session} = SalixAgent.InternalSessionStore.read(ctx.agent, ctx.session)

             not Map.has_key?(
               SalixAgent.InternalSession.get(session, :async_tool_calls),
               "location-call"
             )
           end)
  end

  defp eventually(fun), do: settle_until(fun)

  defp create_owned_control!(agent) do
    SalixAgent.TestSupport.create_control_agent!(agent)
    {:ok, owned} = SalixStore.Agent.claim(agent, to_string(node()), SalixAgent.State)
    :ok = SalixAgent.OwnershipCell.install(agent, owned.epoch)
    owned
  end

  defp put_or_delete_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
