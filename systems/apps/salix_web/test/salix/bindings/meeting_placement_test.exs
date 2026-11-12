defmodule Salix.Bindings.MeetingPlacementTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixMeet", "Elixir.SalixEnv"]

  alias SalixMeet.{CommaProvider, JoinDispatch, Store}
  alias SalixStore.{AgentVMM, Compute, Ids, Keys, Repo, S3}

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
      send(state.test, {:connected_request, state.device, message})

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
    SalixAgent.TestSupport.stop_all_agents()
    stop_meetings()

    envs = [
      {:salix_store, :s3_backend, S3.Fake},
      {:salix_meet, :runtime_driver, SalixMeet.RuntimeDriver.Connector},
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
      "TRUNCATE agent_vmm_sessions, compute_commands, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
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

  test "a Group with an Agent VMM Host has its meeting on its VMM Station", ctx do
    vmm!(ctx)
    {:ok, station} = Compute.ensure_group_station(ctx.tenant, ctx.group)
    device = "dev-station-" <> station.id
    connected!(ctx, {:ok, %{"accepted" => true}}, device)
    connected!(ctx, {:ok, %{"accepted" => true}})

    assert {:ok, %{"meeting_id" => meeting_id}} = CommaProvider.join_from_router(ctx.source, %{})
    assert_received {:connected_request, ^device, %{"method" => "meeting_join"}}
    refute_received {:connected_request, "meeting-device", _}
    refute_received {:fake_session, _, _}

    assert {:ok, %{"state" => state}, _} = Store.get(meeting_id)
    assert state["runtime_source"] == "connected_runtime"
    assert state["runtime_target"]["device_id"] == device

    assert {:ok, _} = SalixMeet.Runtime.send_chat(meeting_id, "hello", "chat-1")
    assert_received {:connected_request, ^device, %{"method" => "meeting_send_chat"}}
  end

  test "a VMM Station that does not connect in 15 seconds leaves the meeting to another runtime",
       ctx do
    vmm!(ctx)
    connected!(ctx, {:ok, %{"accepted" => true}})
    started_at = SystemsClock.monotonic_time(:millisecond)

    assert {:ok, %{"meeting_id" => meeting_id}} = CommaProvider.join_from_router(ctx.source, %{})
    assert SystemsClock.monotonic_time(:millisecond) - started_at >= 15_000
    assert_received {:connected_request, "meeting-device", %{"method" => "meeting_join"}}
    assert {:ok, %{"state" => state}, _} = Store.get(meeting_id)
    assert state["runtime_target"]["device_id"] == "meeting-device"
  end

  test "a VMM Station that rejects the join leaves the meeting to the native runtime", ctx do
    vmm!(ctx)
    {:ok, station} = Compute.ensure_group_station(ctx.tenant, ctx.group)
    device = "dev-station-" <> station.id
    connected!(ctx, {:ok, %{"accepted" => false, "error" => "runtime unavailable"}}, device)

    assert {:ok, %{"meeting_id" => meeting_id}} = CommaProvider.join_from_router(ctx.source, %{})
    assert_received {:connected_request, ^device, %{"method" => "meeting_join"}}
    assert_received {:fake_session, _session, _opts}
    assert {:ok, %{"state" => state}, _} = Store.get(meeting_id)
    assert state["runtime_source"] == "native_runtime"

    assert [%{"source" => "connected_runtime", "device_id" => ^device}] =
             state["join_dispatch"]["runtime_rejections"]
  end

  test "a connected timeout pins the selected device and never starts a native bot", ctx do
    connected!(ctx, {:error, :timeout})
    assert {:error, {:join_failed, _}} = CommaProvider.join_from_router(ctx.source, %{})
    assert {:ok, [meeting_id]} = Store.list()
    assert {:ok, %{"state" => state}, _} = Store.get(meeting_id)
    assert state["runtime_target"]["source"] == "connected_runtime"
    vmm!(ctx)
    assert {:error, :join_liveness_unavailable} = JoinDispatch.run(meeting_id)
    assert_received {:connected_request, _, %{"method" => "meeting_join"}}
    assert_received {:connected_request, _, %{"method" => "meeting_session_status"}}
    refute_received {:fake_session, _, _}
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
      SalixStore.AgentVMMFixtures.registration(%{
        id: "placement-host",
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        device_id: "host-device",
        credential: String.duplicate("e", 32),
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
        generation: 1
      })

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    %{registration: registration, environment: environment, binding: binding}
  end

  defp connected!(ctx, result, device \\ "meeting-device") do
    {:ok, transport, _record} =
      SalixEnv.Registry.connect(to_string(node()), %{
        "tenant_id" => ctx.tenant,
        "group_id" => ctx.group,
        "device_id" => device,
        "connector_id" => device <> "-connector",
        "connect_id" => device <> "-connect",
        "capabilities" => %{"meeting_runtime" => true}
      })

    start_supervised!(
      Supervisor.child_spec(
        {Connector, transport: transport, test: self(), result: result, device: device},
        id: device
      )
    )
  end

  defp stop_meetings do
    if Process.whereis(SalixMeet.MeetingSup) do
      for {_, pid, _, _} <- DynamicSupervisor.which_children(SalixMeet.MeetingSup),
          is_pid(pid),
          do: DynamicSupervisor.terminate_child(SalixMeet.MeetingSup, pid)
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
