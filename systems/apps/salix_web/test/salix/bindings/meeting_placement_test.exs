defmodule Salix.Bindings.MeetingPlacementTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixMeet", "Elixir.SalixEnv"]
  require SystemsClock

  import Ecto.Query
  alias SalixMeet.{CommaProvider, JoinDispatch, MeetingComputeCarrier, Store}
  alias SalixStore.{AgentVMM, Compute, ComputeRuntimeCarrier, Ids, Keys, Repo, S3}

  defmodule Chat do
    def post(_group, _conversation, _agent, key, _text), do: {:ok, %{"message_id" => key}}
  end

  defmodule FeishuDelivery do
    def post_text(_connect, _target, _text, _mentions, key), do: {:ok, %{"operation_ref" => key}}
  end

  defmodule Connector do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(opts) do
      :ok = SalixEnv.Bridge.register_owner(opts[:transport])
      {:ok, Map.new(opts)}
    end

    def handle_info({:env_rpc, ref, caller, message}, state) do
      send(state.test, {:connected_request, message})

      result =
        if message["method"] == "meeting_session_status",
          do: {:ok, %{"status" => "unavailable"}},
          else: state.result

      send(caller, {:env_rpc_reply, ref, result})
      {:noreply, state}
    end
  end

  defmodule HTTPRuntime do
    def init(test), do: test

    def call(conn, test) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:http_join, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 503, "response unavailable")
    end
  end

  setup do
    SalixStore.RepoTestSetup.ensure!()
    SalixAgent.TestSupport.stop_all_agents()
    stop_meetings()

    envs = [
      {:salix_store, :s3_backend, S3.Fake},
      {:salix_meet, :runtime_driver, SalixMeet.RuntimeDriver.SalixConnect},
      {:salix_meet, :meeting_dispatch_mod, Salix.Bindings.MeetingConnectDispatch},
      {:salix_meet, :agent_runtime_mod, SalixMeet.TestAgentRuntime},
      {:salix_meet, :comma_chat_mod, Chat},
      {:salix_web, :meeting_native_runtime_opts,
       [session_module: SalixMeetNative.FakeSession, session: [test_pid: self()]]},
      {:salix_store, :compute_workload_credential_secret, String.duplicate("m", 40)}
    ]

    previous =
      Enum.map(envs, fn {app, key, value} ->
        old = SystemsRuntime.fetch_env(app, key)
        SystemsRuntime.put_env(app, key, value)
        {app, key, old}
      end)

    if is_nil(Process.whereis(S3.Fake)), do: start_supervised!(S3.Fake)
    S3.Fake.reset()

    Repo.query!(
      "TRUNCATE compute_runtime_inputs, agent_vmm_sessions, compute_commands, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    {:ok, _} =
      S3.put(
        Keys.ctl_group(group),
        Jason.encode!(%{
          "tenant_id" => tenant,
          "group_id" => group,
          "name" => "Meeting placement"
        }),
        if_none_match: "*"
      )

    source = %{
      "tenant_id" => tenant,
      "group_id" => group,
      "conversation_id" => Ids.new_conversation_id(),
      "message_id" => "message-1",
      "user_id" => "usr_sender",
      "agent_id" => Ids.new_agent_id(group),
      "language" => "en",
      "text" => "join https://meet.google.com/abc-defg-hij"
    }

    on_exit(fn ->
      Enum.each(SalixMeetNative.list(), &SalixMeetNative.leave/1)
      stop_meetings()
      SalixAgent.TestSupport.stop_all_agents()

      Enum.each(previous, fn
        {app, key, {:ok, value}} -> SystemsRuntime.put_env(app, key, value)
        {app, key, :error} -> SystemsRuntime.delete_env(app, key)
      end)
    end)

    %{source: source, tenant: tenant, group: group}
  end

  test "a product Meeting uses its own VMM carrier, survives actor reload, and stops at terminal",
       ctx do
    vmm = vmm!(ctx)
    connected!(ctx, {:ok, %{"accepted" => true}})
    task = SystemsRuntime.Task.async(fn -> CommaProvider.join_from_router(ctx.source, %{}) end)
    workload = wait_selected_workload!()
    runtime = ready_runtime!(vmm, workload)
    assert {:ok, %{"meeting_id" => meeting_id}} = settled_await(task)
    assert {:ok, [input]} = ComputeRuntimeCarrier.claim_inputs(runtime.id, "1", nil, 32)
    assert input["payload"]["payload"]["meeting_id"] == meeting_id
    assert input["payload"]["payload"]["runtime_policy"]["join_as"] == "guest"
    assert {:ok, _} = ComputeRuntimeCarrier.ack(input["id"], runtime.id, "1")
    refute_received {:connected_request, _}
    refute_received {:fake_session, _, _}

    assert {:ok, _} = SalixMeet.Runtime.send_chat(meeting_id, "hello", "chat-1")
    assert {:ok, [chat]} = ComputeRuntimeCarrier.claim_inputs(runtime.id, "1", nil, 32)
    assert chat["payload"]["frame_type"] == "meeting.chat"

    stop_meetings()
    assert {:ok, _pid} = SalixMeet.Application.start_meeting(meeting_id)
    assert settle_until(fn -> SalixMeet.Meeting.leader?(meeting_id) end)
    assert {:ok, _} = SalixMeet.Meeting.join(meeting_id)

    assert Repo.aggregate(
             from(i in ComputeRuntimeCarrier.Input, where: i.workload_id == ^workload.id),
             :count
           ) == 2

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, &Map.put(&1, "status", "cancelled"))

    assert Repo.get!(Compute.Workload, workload.id).desired_state == "stopped"

    assert {:error, :meeting_workload_terminal} =
             MeetingComputeCarrier.join(carrier_payload!(meeting_id))
  end

  test "an accepted VMM join with a lost checkpoint remains pinned after retry", ctx do
    vmm = vmm!(ctx)
    task = SystemsRuntime.Task.async(fn -> CommaProvider.join_from_router(ctx.source, %{}) end)
    workload = wait_selected_workload!()
    meeting_id = workload.owner_ref["id"]
    S3.Fake.set_fault({:pause, :put, Keys.meet_state(meeting_id)})
    runtime = ready_runtime!(vmm, workload)
    assert settle_until(&S3.Fake.paused?/0)

    assert Repo.exists?(
             from(i in ComputeRuntimeCarrier.Input, where: i.workload_id == ^workload.id)
           )

    _ = SystemsRuntime.Task.shutdown(task, :brutal_kill)
    S3.Fake.fail_pause(503)
    connected!(ctx, {:ok, %{"accepted" => true}})
    settle_after(Store.join_reclaim_after_ms() + 1)
    assert {:error, :join_liveness_unavailable} = JoinDispatch.run(meeting_id)

    assert {:ok, :unavailable} =
             MeetingComputeCarrier.session_status(carrier_payload!(meeting_id))

    assert {:ok, [input]} = ComputeRuntimeCarrier.claim_inputs(runtime.id, "1", nil, 32)
    assert input["payload"]["frame_type"] == "meeting.join"
    refute_received {:connected_request, _}
    refute_received {:fake_session, _, _}
  end

  test "the Feishu product entry uses the same per-Meeting VMM carrier", ctx do
    override(:salix_im, :feishu_direct_delivery_mod, FeishuDelivery)
    vmm = vmm!(ctx)

    connect = %{
      "tenant_id" => ctx.tenant,
      "group_id" => ctx.group,
      "connect_id" => "feishu-connect"
    }

    source = %{
      "connect_id" => "feishu-connect",
      "source_message_id" => "feishu-source",
      "text" => ctx.source["text"],
      "metadata" => %{
        "message_id" => "feishu-message",
        "chat_id" => "oc_chat",
        "chat_type" => "group",
        "sender_open_id" => "ou_sender"
      }
    }

    task =
      SystemsRuntime.Task.async(fn ->
        SalixMeet.FeishuProvider.join_from_router(connect, source, %{})
      end)

    workload = wait_selected_workload!()
    runtime = ready_runtime!(vmm, workload)
    assert {:ok, %{"meeting_id" => meeting_id, "provider" => "feishu"}} = settled_await(task)
    assert {:ok, [input]} = ComputeRuntimeCarrier.claim_inputs(runtime.id, "1", nil, 32)
    assert input["payload"]["payload"]["meeting_id"] == meeting_id

    assert {:ok, %{"state" => %{"runtime_source" => "compute_workload"}}, _} =
             Store.get(meeting_id)

    refute_received {:fake_session, _, _}
  end

  test "cold VMM timeout stops its unaccepted Workload, then a connected rejection reaches native",
       ctx do
    vmm!(ctx)
    connected!(ctx, {:ok, %{"accepted" => false, "error" => "runtime unavailable"}})
    handler = {__MODULE__, make_ref()}

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, meta, owner ->
          if String.contains?(meta.query, "FROM \"compute_runtime_instances\""),
            do: send(owner, :runtime_status_read)
        end,
        self()
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)
    task = SystemsRuntime.Task.async(fn -> CommaProvider.join_from_router(ctx.source, %{}) end)
    workload = wait_selected_workload!()
    started_at = SystemsClock.monotonic_time(:millisecond)
    assert {:ok, %{"meeting_id" => meeting_id}} = settled_await(task)
    assert SystemsClock.monotonic_time(:millisecond) - started_at <= 15_000
    assert count_runtime_reads() == 15
    assert Repo.get!(Compute.Workload, workload.id).desired_state == "stopped"
    assert {:ok, %{"state" => state}, _} = Store.get(meeting_id)
    assert state["runtime_source"] == "native_runtime"

    assert Enum.map(state["join_dispatch"]["runtime_rejections"], & &1["source"]) == [
             "compute_workload",
             "connected_runtime"
           ]

    assert_received {:connected_request, %{"method" => "meeting_join"}}
    assert_received {:fake_session, _session, _opts}
    refute Repo.exists?(ComputeRuntimeCarrier.Input)
  end

  test "a connected timeout pins the selected device and never starts a native bot", ctx do
    connected!(ctx, {:error, :timeout})
    assert {:error, {:join_failed, _}} = CommaProvider.join_from_router(ctx.source, %{})
    assert {:ok, [meeting_id]} = Store.list()
    assert {:ok, %{"state" => state}, _} = Store.get(meeting_id)
    assert state["runtime_target"]["source"] == "connected_runtime"
    vmm!(ctx)
    assert {:error, :join_liveness_unavailable} = JoinDispatch.run(meeting_id)
    assert_received {:connected_request, %{"method" => "meeting_join"}}
    assert_received {:connected_request, %{"method" => "meeting_session_status"}}
    refute_received {:fake_session, _, _}
    refute Repo.exists?(from(w in Compute.Workload, where: w.kind == "meeting_runtime"))
  end

  test "a provider denial stays on the connected runtime", ctx do
    connected!(ctx, {:ok, %{"accepted" => false, "reason_code" => "admission_denied"}})
    assert {:error, {:join_failed, _}} = CommaProvider.join_from_router(ctx.source, %{})
    assert {:ok, [meeting_id]} = Store.list()
    assert {:ok, %{"state" => state}, _} = Store.get(meeting_id)
    assert state["runtime_source"] == "connected_runtime"
    assert state["status"] == "failed"
    assert state["reason_code"] == "admission_denied"
    refute_received {:fake_session, _, _}
  end

  test "an unavailable Compute preparation does not switch to another runtime", ctx do
    vmm!(ctx)
    connected!(ctx, {:ok, %{"accepted" => true}})
    # The catalog cannot load. Compute reports an unavailable transaction.
    override(:salix_store, :runtime_bundle_root, :unavailable)

    assert {:error, {:join_failed, ":meeting_compute_unavailable"}} =
             CommaProvider.join_from_router(ctx.source, %{})

    refute_received {:connected_request, _}
    refute_received {:fake_session, _, _}
    refute Repo.exists?(ComputeRuntimeCarrier.Input)
  end

  test "a failed target CAS after Workload preparation does not dispatch another carrier", ctx do
    vmm!(ctx)
    connected!(ctx, {:ok, %{"accepted" => true}})
    handler = {__MODULE__, :selection_cas, make_ref()}

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, meta, owner ->
          if String.contains?(meta.query, "INSERT INTO \"compute_workloads\"") do
            send(owner, {:compute_placement_written, self()})

            SystemsClock.vreceive do
              :continue_placement -> :ok
            after
              5_000 -> raise "placement barrier timed out"
            end
          end
        end,
        self()
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)
    task = SystemsRuntime.Task.async(fn -> CommaProvider.join_from_router(ctx.source, %{}) end)
    settle_receive({:compute_placement_written, caller})
    assert {:ok, [meeting_id]} = Store.list()
    S3.Fake.set_fault_for(caller, {:fail, 503, :put, Keys.meet_state(meeting_id)})
    send(caller, :continue_placement)
    assert {:error, {:join_failed, _}} = settled_await(task)

    assert %Compute.Workload{desired_state: "ready"} =
             workload =
             Repo.one!(from(w in Compute.Workload, where: w.kind == "meeting_runtime"))

    refute_received {:connected_request, _}
    refute_received {:fake_session, _, _}
    refute Repo.exists?(ComputeRuntimeCarrier.Input)

    assert {:ok, _doc, _etag} =
             Store.update_state_retrying(meeting_id, &Map.put(&1, "status", "cancelled"))

    assert Repo.get!(Compute.Workload, workload.id).desired_state == "stopped"
  end

  test "retry recovers a stopped unaccepted target before its rejection checkpoint", ctx do
    vmm = vmm!(ctx)
    meeting_id = "meeting-stop-before-reject"

    payload = %{
      "tenant_id" => ctx.tenant,
      "group_id" => ctx.group,
      "meeting_id" => meeting_id,
      "compute_environment_id" => vmm.environment.id,
      "runtime_source" => "automatic",
      "runtime_policy" => %{"source" => "automatic", "join_as" => "guest"},
      "meet_url" => "https://meet.google.com/abc-defg-hij",
      "runtime_token" => "business-token"
    }

    {:ok, workload} = MeetingComputeCarrier.ensure_workload(payload)

    target = %{
      "source" => "compute_workload",
      "workload_id" => workload.id,
      "compute_environment_id" => vmm.environment.id
    }

    {:ok, _, _} = Store.create_once(meeting_id, state: payload)

    {:ok, :claimed, _, _, _} =
      Store.claim_join_dispatch(meeting_id, %{"generation" => "first", "claimed_by" => "crashed"})

    {:ok, _, _} = Store.select_join_runtime(meeting_id, "first", target)

    assert {:ok, _} =
             MeetingComputeCarrier.release_unaccepted(
               Map.put(payload, "workload_id", workload.id)
             )

    {:ok, _, _} = Store.checkpoint_join_dispatch(meeting_id, "first", {:failed, :caller_died})
    assert {:ok, _} = JoinDispatch.run(meeting_id)
    assert {:ok, %{"state" => state}, _} = Store.get(meeting_id)
    assert state["runtime_source"] == "native_runtime"
    assert [%{"source" => "compute_workload"}] = state["join_dispatch"]["runtime_rejections"]
    assert_received {:fake_session, _, _}
    refute Repo.exists?(ComputeRuntimeCarrier.Input)
  end

  test "an explicit HTTP runtime error does not prove that it accepted no join", ctx do
    server = start_supervised!({Bandit, plug: {HTTPRuntime, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    override(:salix_meet, :runtime_driver, SalixMeet.RuntimeDriver.HTTP)
    override(:salix_meet, :runtime_base_url, "http://127.0.0.1:#{port}")
    assert SalixMeet.MeetingRuntimePolicy.default_source() == "connected_runtime"
    override(:salix_meet, :http_runtime_source, "native_runtime")
    assert {:error, {:join_failed, _}} = CommaProvider.join_from_router(ctx.source, %{})
    assert_received {:http_join, payload}
    assert payload["runtime_source"] == "native_runtime"
    assert payload["runtime_policy"] == %{"source" => "native_runtime", "join_as" => "guest"}
    assert {:error, :join_liveness_unavailable} = JoinDispatch.run(payload["meeting_id"])
    refute_received {:http_join, _}
    refute_received {:fake_session, _, _}
  end

  test "a stale claim cannot replace the durable runtime target", ctx do
    meeting_id = "meeting-fence"

    {:ok, _, _} =
      Store.create_once(meeting_id,
        state: %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "runtime_source" => "automatic"
        }
      )

    {:ok, :claimed, _, _, _} =
      Store.claim_join_dispatch(meeting_id, %{"generation" => "current", "claimed_by" => "test"})

    target = %{"source" => "native_runtime"}
    S3.Fake.set_fault({:pause, :get, Keys.meet_state(meeting_id)})

    selection =
      SystemsRuntime.Task.async(fn ->
        Store.select_join_runtime(meeting_id, "current", target)
      end)

    assert settle_until(&S3.Fake.paused?/0)

    assert {:ok, _, _} =
             Store.update_state_retrying(meeting_id, &Map.put(&1, "title", "Concurrent update"))

    S3.Fake.release_pause()
    assert {:ok, _, _} = settled_await(selection)

    assert {:error, :fenced} =
             Store.select_join_runtime(meeting_id, "stale", %{"source" => "connected_runtime"})

    assert {:ok, %{"state" => %{"runtime_target" => ^target}}, _} = Store.get(meeting_id)
  end

  defp vmm!(ctx) do
    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "placement-host",
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        device_id: "host-device",
        enrollment_token: String.duplicate("e", 32),
        desired_enabled: true
      })

    Repo.update_all(AgentVMM.Registration, set: [status: "ready"])

    {:ok, pool} =
      Compute.create_pool(%{
        id: "placement-pool",
        tenant_id: ctx.tenant,
        name: "Meeting",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec", "runtime_process"]
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "placement-env",
        tenant_id: ctx.tenant,
        owner_type: "project",
        owner_id: "placement-project",
        pool_id: pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "placement-binding",
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration.id,
        generation: 1,
        observation: %{"gateway_instance_id" => "gateway", "connection_epoch" => "1"}
      })

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    %{registration: registration, environment: environment, binding: binding}
  end

  defp wait_selected_workload! do
    settle_until(fn ->
      case Repo.one(from(w in Compute.Workload, where: w.kind == "meeting_runtime", limit: 1)) do
        nil ->
          false

        workload ->
          case Store.get(workload.owner_ref["id"]) do
            {:ok, %{"state" => %{"runtime_target" => %{"workload_id" => id}}}, _}
            when id == workload.id ->
              workload

            _ ->
              false
          end
      end
    end)
  end

  defp ready_runtime!(vmm, workload) do
    allocation = Repo.get!(Compute.Allocation, workload.allocation_id)

    {:ok, allocation} =
      Compute.observe_allocation(allocation.id, allocation.revision, 1, "ready", "succeeded", %{
        "container_status" => "running",
        "runtime_container_instance_id" => "container-1",
        "runtime_verified_host_epoch" => "1",
        "runtime_execution_epoch" => "1",
        "current_container" => %{"instance_id" => "container-1"}
      })

    {:ok, runtime} =
      Compute.observe_runtime(%{
        id: "runtime:" <> workload.id,
        workload_id: workload.id,
        allocation_id: allocation.id,
        generation: 1,
        connection_epoch: "1"
      })

    Repo.insert!(%AgentVMM.Session{
      id: "session:" <> workload.id,
      registration_id: vmm.registration.id,
      runtime_instance_id: runtime.id,
      allocation_id: allocation.id,
      allocation_generation: 1,
      connection_epoch: "1",
      gateway_instance_id: "gateway",
      status: "ready",
      expires_at: DateTime.add(SystemsClock.utc_now(), 3600),
      updated_at: SystemsClock.utc_now()
    })

    {:ok, runtime} = Compute.complete_runtime_catch_up(runtime.id, runtime.revision, "1")
    runtime
  end

  defp connected!(ctx, result) do
    {:ok, transport, _record} =
      SalixEnv.Registry.connect(to_string(node()), %{
        "tenant_id" => ctx.tenant,
        "group_id" => ctx.group,
        "device_id" => "meeting-device",
        "connector_id" => "meeting-connector",
        "connect_id" => "meeting-connect",
        "capabilities" => %{"meeting_runtime" => true}
      })

    start_supervised!({Connector, transport: transport, test: self(), result: result})
  end

  defp carrier_payload!(meeting_id) do
    {:ok, %{"state" => state}, _} = Store.get(meeting_id)
    Map.put(state, "meeting_id", meeting_id)
  end

  defp stop_meetings do
    if Process.whereis(SalixMeet.MeetingSup) do
      for {_, pid, _, _} <- DynamicSupervisor.which_children(SalixMeet.MeetingSup),
          is_pid(pid),
          do: DynamicSupervisor.terminate_child(SalixMeet.MeetingSup, pid)
    end
  end

  defp count_runtime_reads(count \\ 0) do
    receive do
      :runtime_status_read -> count_runtime_reads(count + 1)
    after
      0 -> count
    end
  end

  defp override(app, key, value) do
    previous = SystemsRuntime.fetch_env(app, key)
    SystemsRuntime.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> SystemsRuntime.put_env(app, key, old)
        :error -> SystemsRuntime.delete_env(app, key)
      end
    end)
  end
end
