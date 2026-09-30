defmodule SalixEnv.VM.Providers.Cloudflare.AttachmentTest do
  use ExUnit.Case, async: false

  alias SalixEnv.{Bridge, Control, Registry}
  alias SalixEnv.VM.Providers.Cloudflare.{Attachments, Client, MockConnectGateway}
  alias SalixStore.{Compute, Ids}

  setup context do
    gateway = start_supervised!({MockConnectGateway, Map.get(context, :mock_gateway_opts, [])})
    client = Client.new(base_url: MockConnectGateway.base_url(gateway), secret: "test-secret")
    env_id = "cloudflare-env-#{System.unique_integer([:positive])}"
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    device_id = Ids.new_device_id()

    on_exit(fn -> Attachments.stop(env_id) end)

    opts = [
      env_id: env_id,
      sandbox_id: "sb-1",
      client: client,
      meta: %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "device_id" => device_id,
        "connector_id" => "connector-cloudflare",
        "provider" => "cloudflare",
        "alias" => "cloud-vm",
        "name" => "Cloud VM"
      }
    ]

    %{
      gateway: gateway,
      env_id: env_id,
      tenant_id: tenant_id,
      group_id: group_id,
      device_id: device_id,
      opts: opts
    }
  end

  test "registers Bridge owner and passes EnvMessage frames through worker connect", %{
    gateway: gateway,
    env_id: env_id,
    opts: opts,
    tenant_id: tenant_id,
    group_id: group_id,
    device_id: device_id
  } do
    assert {:ok, pid} = Attachments.ensure(protocol_opts(opts))
    assert wait_until(fn -> Bridge.local?(env_id) end)

    assert wait_until(fn ->
             match?(
               {:ok, %{"status" => "connected"}},
               Registry.get_device(tenant_id, group_id, device_id)
             )
           end)

    assert {:ok, device} = Registry.get_device(tenant_id, group_id, device_id)
    assert device["meta"]["provider"] == "cloudflare"

    now = System.system_time(:second)
    runtime_id = "codex-attachment"
    device_runtime_id = SalixStore.RuntimeIds.device_runtime_id(device_id, "codex", runtime_id)

    assert {:ok, _} =
             Registry.update_meta(device["connector_run_id"], fn meta ->
               Map.put(meta, "agent_runtimes", [
                 %{
                   "provider" => "codex",
                   "runtime_id" => runtime_id,
                   "device_runtime_id" => device_runtime_id,
                   "version_detected" => true,
                   "auth_ready" => true,
                   "native_server_startable" => true,
                   "ready" => true,
                   "readiness_checked_at" => now,
                   "readiness_valid_until" => now + 300
                 }
               ])
             end)

    assert {:ok, %{"carrier_provider" => "cloudflare", "connector_run_id" => run_id}} =
             Control.resolve_external_runtime_binding(
               %{"provider" => "codex", "device_runtime_id" => device_runtime_id},
               tenant_id,
               group_id
             )

    assert run_id == device["connector_run_id"]

    assert {:ok, result} =
             Bridge.rpc(
               env_id,
               %{
                 "id" => "exec-1",
                 "type" => "request",
                 "method" => "exec",
                 "params" => %{"command" => "true"}
               },
               2_000
             )

    assert %{"exit_code" => 0, "stdout" => ""} = result

    assert {:ok,
            %{frame: %{"id" => "exec-1", "method" => "exec", "params" => %{"command" => "true"}}}} =
             MockConnectGateway.wait_for_frame(gateway, &(&1["id"] == "exec-1"))

    assert Process.alive?(pid)
  end

  test "lost attachment can be revived for the same env_id", %{env_id: env_id, opts: opts} do
    assert {:ok, pid} = Attachments.ensure(protocol_opts(opts))
    assert wait_until(fn -> Bridge.local?(env_id) end)

    assert :ok = Attachments.stop(env_id)
    refute wait_until(fn -> Process.alive?(pid) end, 200)

    assert {:ok, pid2} = Attachments.ensure(protocol_opts(opts))
    assert wait_until(fn -> Bridge.local?(env_id) end)
    assert pid2 != pid

    assert {:ok, %{"exit_code" => 0}} =
             Bridge.rpc(
               env_id,
               %{
                 "id" => "exec-2",
                 "type" => "request",
                 "method" => "exec",
                 "params" => %{"command" => "true"}
               },
               2_000
             )
  end

  test "Group archive hold rejects direct Connector writes after attachment reconnect", %{
    gateway: gateway,
    env_id: env_id,
    opts: opts,
    tenant_id: tenant,
    group_id: group,
    device_id: device
  } do
    opts =
      opts
      |> Keyword.put(:sandbox_id, "held-cloudflare")
      |> Keyword.update!(
        :meta,
        &Map.merge(&1, %{"managed_compute" => true, "profile_key" => "cf-standard-2"})
      )

    assert {:ok, _, _} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "provider" => "cloudflare",
               "provider_resource_name" => "held-cloudflare",
               "provider_resource_id" => "held-cloudflare",
               "provider_spec" => %{"profile_key" => "cf-standard-2"},
               "env_id" => env_id,
               "device_id" => device,
               "connector_id" => "connector-cloudflare",
               "alias" => "cloud-vm",
               "status" => "ready",
               "provider_migration" => %{
                 "operation" => "move-one",
                 "phase" => "committed",
                 "archive_hold" => "awaiting_durable_archive"
               },
               "created_at" => System.system_time(:millisecond)
             })

    for _ <- 1..2 do
      assert {:ok, _pid} = Attachments.ensure(protocol_opts(opts))
      assert wait_until(fn -> Bridge.local?(env_id) end)

      assert {:error, :provider_cutover_archive_pending} =
               Bridge.rpc(
                 env_id,
                 %{
                   "id" => "held-exec",
                   "type" => "request",
                   "method" => "exec",
                   "params" => %{"command" => "touch forbidden"}
                 },
                 500
               )

      assert {:error, :provider_cutover_archive_pending} =
               Bridge.begin_write_stream(
                 env_id,
                 %{
                   "id" => "held-stream",
                   "type" => "request",
                   "method" => "write_stream",
                   "params" => %{"path" => "/workspace/forbidden"}
                 },
                 500
               )

      for method <- ~w(cloud_runtime_resume runtime_auth_verify) do
        assert {:error, :provider_cutover_archive_pending} =
                 Bridge.rpc(
                   env_id,
                   %{"id" => "held-#{method}", "type" => "request", "method" => method},
                   500
                 )
      end

      refute Enum.any?(MockConnectGateway.frames(gateway), fn call ->
               call.frame["id"] in [
                 "held-exec",
                 "held-stream",
                 "held-cloud_runtime_resume",
                 "held-runtime_auth_verify"
               ]
             end)

      assert :ok = Attachments.stop(env_id)
      assert wait_until(fn -> not Bridge.local?(env_id) end)
    end
  end

  test "async initial gateway outage does not block supervised attachment startup" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)

    env_id = "cloudflare-env-unavailable-#{System.unique_integer([:positive])}"
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    opts = [
      env_id: env_id,
      sandbox_id: "sb-unavailable",
      client: Client.new(base_url: "http://127.0.0.1:#{port}", secret: "test-secret"),
      async: true,
      meta: %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "device_id" => Ids.new_device_id(),
        "connector_id" => "connector-unavailable",
        "alias" => "cloud-vm"
      }
    ]

    on_exit(fn -> Attachments.stop(env_id) end)

    task = Task.async(fn -> Attachments.ensure(protocol_opts(opts)) end)
    result = Task.yield(task, 250) || Task.shutdown(task, :brutal_kill)

    assert {:ok, {:ok, pid}} = result
    assert Process.alive?(pid)
    refute Bridge.local?(env_id)
  end

  test "sync initial gateway outage fails promptly without wedging the supervisor" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)

    env_id = "cloudflare-env-sync-unavailable-#{System.unique_integer([:positive])}"
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    opts = [
      env_id: env_id,
      sandbox_id: "sb-sync-unavailable",
      client: Client.new(base_url: "http://127.0.0.1:#{port}", secret: "test-secret"),
      meta: %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "device_id" => Ids.new_device_id(),
        "connector_id" => "connector-sync-unavailable",
        "alias" => "cloud-vm"
      }
    ]

    task = Task.async(fn -> Attachments.ensure(protocol_opts(opts)) end)
    result = Task.yield(task, 250) || Task.shutdown(task, :brutal_kill)

    assert {:ok, {:error, _reason}} = result
    assert wait_until(fn -> is_nil(Attachments.whereis(env_id)) end, 500)
  end

  test "stop_all returns counts and marks connected envs disconnected", %{
    env_id: _env_id,
    opts: opts,
    tenant_id: tenant_id,
    group_id: group_id,
    device_id: device_id
  } do
    assert {:ok, _pid} = Attachments.ensure(protocol_opts(opts))

    assert wait_until(fn ->
             match?(
               {:ok, %{"status" => "connected"}},
               Registry.get_device(tenant_id, group_id, device_id)
             )
           end)

    assert %{completed: completed, timeout: 0, error: 0} = Attachments.stop_all()
    assert completed >= 1

    assert wait_until(fn ->
             match?(
               {:ok, %{"status" => "disconnected"}},
               Registry.get_device(tenant_id, group_id, device_id)
             )
           end)
  end

  @tag mock_gateway_opts: [drop_heartbeats: 1]
  test "heartbeat timeout reconnects the worker bridge", %{
    gateway: gateway,
    env_id: env_id,
    opts: opts
  } do
    opts = Keyword.merge(opts, heartbeat_ms: 250, heartbeat_timeout_ms: 250)

    assert {:ok, pid} = Attachments.ensure(protocol_opts(opts))
    assert wait_until(fn -> Bridge.local?(env_id) end)

    assert wait_until(fn ->
             gateway
             |> MockConnectGateway.frames()
             |> connected_after_reconnect?()
           end)

    connect_nonces =
      gateway
      |> MockConnectGateway.frames()
      |> Enum.filter(&(&1.frame["http_op"] == "connect"))
      |> Enum.map(& &1.frame["nonce"])

    assert length(connect_nonces) >= 2
    assert length(Enum.uniq(connect_nonces)) == length(connect_nonces)

    assert Process.alive?(pid)
    assert Bridge.local?(env_id)

    assert {:ok, %{"exit_code" => 0}} =
             Bridge.rpc(
               env_id,
               %{
                 "id" => "exec-after-reconnect",
                 "type" => "request",
                 "method" => "exec",
                 "params" => %{"command" => "true"}
               },
               2_000
             )
  end

  test "pending RPC receives structured reconnect error and is not replayed" do
    gateway =
      start_supervised!(%{
        id: {:mock_connect_gateway, :held},
        start: {MockConnectGateway, :start_link, [[hold_commands: ["hold"], drop_heartbeats: 1]]}
      })

    client = Client.new(base_url: MockConnectGateway.base_url(gateway), secret: "test-secret")
    env_id = "cloudflare-env-held-#{System.unique_integer([:positive])}"
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    opts = [
      env_id: env_id,
      sandbox_id: "sb-held",
      client: client,
      heartbeat_ms: 250,
      heartbeat_timeout_ms: 250,
      meta: %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "device_id" => Ids.new_device_id(),
        "connector_id" => "connector-held",
        "alias" => "cloud-vm"
      }
    ]

    on_exit(fn -> Attachments.stop(env_id) end)

    assert {:ok, _pid} = Attachments.ensure(protocol_opts(opts))
    assert wait_until(fn -> Bridge.local?(env_id) end)

    task =
      Task.async(fn ->
        Bridge.rpc(
          env_id,
          %{
            "id" => "exec-held",
            "type" => "request",
            "method" => "exec",
            "params" => %{"command" => "hold"}
          },
          5_000
        )
      end)

    assert {:ok, %{frame: %{"id" => "exec-held"}}} =
             MockConnectGateway.wait_for_frame(gateway, &(&1["id"] == "exec-held"))

    assert {:error,
            %{
              "error_class" => "vm_reconnecting",
              "env_id" => ^env_id,
              "sandbox_id" => "sb-held",
              "connection_generation" => generation,
              "retryable" => true
            }} = Task.await(task, 3_000)

    assert is_integer(generation)

    assert wait_until(fn ->
             gateway
             |> MockConnectGateway.frames()
             |> connected_after_reconnect?()
           end)

    exec_held_frames =
      gateway
      |> MockConnectGateway.frames()
      |> Enum.count(&(&1.frame["id"] == "exec-held"))

    assert exec_held_frames == 1

    assert {:ok, %{"exit_code" => 0}} =
             Bridge.rpc(
               env_id,
               %{
                 "id" => "exec-after-held-reconnect",
                 "type" => "request",
                 "method" => "exec",
                 "params" => %{"command" => "true"}
               },
               2_000
             )
  end

  @tag mock_gateway_opts: [hold_commands: ["hold"]]
  test "caller timeout and caller DOWN release bounded RPC ownership", %{
    gateway: gateway,
    env_id: env_id,
    opts: opts
  } do
    opts =
      Keyword.merge(opts,
        pending_rpc_limit: 1,
        pending_rpc_absolute_timeout_ms: 50
      )

    assert {:ok, pid} = Attachments.ensure(protocol_opts(opts))
    assert wait_until(fn -> Bridge.local?(env_id) end)

    assert {:error, :timeout} =
             Bridge.rpc(
               env_id,
               %{
                 "id" => "held-timeout",
                 "type" => "request",
                 "method" => "exec",
                 "params" => %{"command" => "hold"}
               },
               20
             )

    assert {:ok, %{frame: %{"id" => "held-timeout"}}} =
             MockConnectGateway.wait_for_frame(gateway, &(&1["id"] == "held-timeout"))

    assert wait_until(fn -> protocol_state(pid).pending == %{} end)

    parent = self()

    caller =
      spawn(fn ->
        ref = make_ref()

        send(protocol_pid(pid), {
          :env_rpc,
          ref,
          self(),
          %{
            "id" => "held-caller-down",
            "type" => "request",
            "method" => "exec",
            "params" => %{"command" => "hold"}
          }
        })

        send(parent, {:sent, self()})
      end)

    assert_receive {:sent, ^caller}
    caller_monitor = Process.monitor(caller)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, _reason}
    assert wait_until(fn -> protocol_state(pid).pending == %{} end)

    ref = make_ref()

    send(protocol_pid(pid), {
      :env_rpc,
      ref,
      self(),
      %{
        "id" => "held-owner-deadline",
        "type" => "request",
        "method" => "exec",
        "params" => %{"command" => "hold"}
      }
    })

    assert_receive {:env_rpc_reply, ^ref, {:error, :timeout}}, 500
    assert protocol_state(pid).pending == %{}
  end

  test "read and write owners enforce caps and exact Bridge cancellation", %{
    env_id: env_id,
    opts: opts
  } do
    capture_connector_events(:websocket)

    opts =
      Keyword.merge(opts,
        read_stream_limit: 1,
        read_stream_idle_timeout_ms: 5_000,
        read_stream_absolute_timeout_ms: 5_000,
        write_stream_limit: 1,
        write_stream_idle_timeout_ms: 5_000,
        write_stream_absolute_timeout_ms: 5_000
      )

    assert {:ok, pid} = Attachments.ensure(protocol_opts(opts))
    assert wait_until(fn -> Bridge.local?(env_id) end)

    read_ref = make_ref()

    send(protocol_pid(pid), {
      :env_read_stream,
      read_ref,
      self(),
      %{"id" => "read-owned", "type" => "request", "method" => "read_stream"}
    })

    assert_receive {:env_read_stream_reply, ^read_ref, {:ok, _stream, nil}}

    read_overflow_ref = make_ref()

    send(protocol_pid(pid), {
      :env_read_stream,
      read_overflow_ref,
      self(),
      %{"id" => "read-overflow", "type" => "request", "method" => "read_stream"}
    })

    assert_receive {:env_read_stream_reply, ^read_overflow_ref,
                    {:error, :connector_read_stream_capacity_exhausted}}

    send(protocol_pid(pid), {:env_read_stream_cancel, make_ref(), self()})
    assert map_size(protocol_state(pid).read_streams) == 1
    send(protocol_pid(pid), {:env_read_stream_cancel, read_ref, self()})
    assert wait_until(fn -> protocol_state(pid).read_streams == %{} end)

    write_ref = make_ref()

    send(protocol_pid(pid), {
      :env_write_stream,
      :begin,
      write_ref,
      self(),
      %{"id" => "write-owned", "type" => "request", "method" => "write_stream"}
    })

    assert wait_until(fn -> map_size(protocol_state(pid).write_streams) == 1 end)

    write_overflow_ref = make_ref()

    send(protocol_pid(pid), {
      :env_write_stream,
      :begin,
      write_overflow_ref,
      self(),
      %{"id" => "write-overflow", "type" => "request", "method" => "write_stream"}
    })

    assert_receive {:env_write_stream_reply, ^write_overflow_ref,
                    {:error, :connector_write_stream_capacity_exhausted}}

    send(protocol_pid(pid), {:env_write_stream_cancel, make_ref(), self()})
    assert map_size(protocol_state(pid).write_streams) == 1
    send(protocol_pid(pid), {:env_write_stream_cancel, write_ref, self()})
    assert wait_until(fn -> protocol_state(pid).write_streams == %{} end)

    assert_receive {:connector_event, :read_stream, :accepted}
    assert_receive {:connector_event, :read_stream, :saturated}
    assert_receive {:connector_event, :read_stream, :cancelled}
    assert_receive {:connector_event, :write_stream, :accepted}
    assert_receive {:connector_event, :write_stream, :saturated}
    assert_receive {:connector_event, :write_stream, :cancelled}
    refute_receive {:connector_event, _kind, _outcome}, 50
  end

  test "read absolute and write idle deadlines reclaim stalled stream state", %{
    env_id: env_id,
    opts: opts
  } do
    opts =
      Keyword.merge(opts,
        heartbeat_ms: 5_000,
        heartbeat_timeout_ms: 5_000,
        read_stream_idle_timeout_ms: 500,
        read_stream_absolute_timeout_ms: 60,
        write_stream_idle_timeout_ms: 60,
        write_stream_absolute_timeout_ms: 500
      )

    assert {:ok, pid} = Attachments.ensure(protocol_opts(opts))
    assert wait_until(fn -> Bridge.local?(env_id) end)
    read_ref = make_ref()

    send(protocol_pid(pid), {
      :env_read_stream,
      read_ref,
      self(),
      %{
        "id" => "read-deadline",
        "type" => "request",
        "method" => "read_stream"
      }
    })

    assert_receive {:env_read_stream_reply, ^read_ref, {:ok, _stream, nil}}
    assert wait_until(fn -> protocol_state(pid).read_streams == %{} end, 500)

    write_ref = make_ref()

    send(protocol_pid(pid), {
      :env_write_stream,
      :begin,
      write_ref,
      self(),
      %{
        "id" => "write-deadline",
        "type" => "request",
        "method" => "write_stream"
      }
    })

    assert_receive {:env_write_stream_reply, ^write_ref, {:error, :timeout}}, 500
    assert wait_until(fn -> protocol_state(pid).write_streams == %{} end)
  end

  defp protocol_pid(pid), do: :sys.get_state(pid).protocol

  defp protocol_state(pid) do
    :sys.get_state(protocol_pid(pid)).protocol
  catch
    :exit, _ -> %{pending: %{}, read_streams: %{}, write_streams: %{}}
  end

  defp protocol_opts(opts) do
    for {option, setting} <- [
          heartbeat_ms: :connector_heartbeat_ms,
          heartbeat_timeout_ms: :connector_heartbeat_timeout_ms,
          pending_rpc_limit: :connector_socket_pending_rpc_limit,
          pending_rpc_absolute_timeout_ms: :connector_pending_rpc_absolute_timeout_ms,
          read_stream_limit: :connector_socket_read_stream_limit,
          read_stream_idle_timeout_ms: :connector_read_stream_idle_timeout_ms,
          read_stream_absolute_timeout_ms: :connector_read_stream_absolute_timeout_ms,
          write_stream_limit: :connector_socket_write_stream_limit,
          write_stream_idle_timeout_ms: :connector_write_stream_idle_timeout_ms
        ] do
      if value = opts[option] do
        prior = Application.get_env(:salix_web, setting)
        Application.put_env(:salix_web, setting, value)

        on_exit(fn ->
          if is_nil(prior),
            do: Application.delete_env(:salix_web, setting),
            else: Application.put_env(:salix_web, setting, prior)
        end)
      end
    end

    opts
  end

  defp wait_until(fun, remaining_ms \\ 2_000)
  defp wait_until(_fun, remaining_ms) when remaining_ms <= 0, do: false

  defp wait_until(fun, remaining_ms) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, remaining_ms - 20)
    end
  end

  defp capture_connector_events(transport) do
    test = self()
    handler_id = {__MODULE__, self(), make_ref()}

    events =
      for kind <- [:pending_rpc, :read_stream, :write_stream] do
        [:salix, :connector, kind]
      end

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn [:salix, :connector, kind], _measurements, metadata, _config ->
          if metadata[:transport] == transport do
            send(test, {:connector_event, kind, metadata[:outcome]})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp connected_after_reconnect?(frames) do
    Enum.count(frames, &(&1.frame["http_op"] == "connect")) >= 2 and
      Enum.count(frames, &(&1.frame["type"] == "connected")) >= 2
  end
end
