defmodule SalixWeb.ConnectorMultinodeTest do
  @moduledoc """
  Real two-node remote-connector test (the multi-node claim, end to end with the
  actual Go connector):

    * **Node B** (a `:peer` BEAM node) runs `salix_web` — the `/v1/connect`
      WebSocket endpoint and the `SalixEnv.Bridges` registry.
    * The **real Go connector** (`connector/salix-connect`) attaches to
      node B's WebSocket. Its group-owned device points at a current connector
      run stamped with node B.
    * **Node A** (this VM) runs the agent dispatch. `SalixEnv.Connector.Live`
      reads the record, sees the owner is node B, and forwards the RPC via
      `:erpc` to `SalixEnv.Bridge.rpc/3` on B — which runs the WebSocket round
      trip to the Go process. There is NO local connector socket on A.

  Both nodes share the same MinIO bucket (`salix-test`) so the durable record is
  visible cross-node. Requires BEAM distribution + MinIO + Go; the module fails
  if distribution is unavailable.
  """
  use SystemsClock.Case, async: false

  @moduletag :multinode

  alias SalixAgent.{AgentWorkspace, ToolDisclosure, Tools}
  alias SalixWeb.ComputeProviders.Cloudflare
  alias SalixWeb.MockCloudflareGateway
  @root "/tmp/salix-mn-connector-#{SystemsClock.system_time(:second)}"

  @binary_dir @root <> "-binary"
  setup_all do
    File.mkdir_p!(@binary_dir)
    source = Path.expand("../../../connector/salix-connect", __DIR__)

    {output, status} =
      System.cmd("go", ["build", "-o", Path.join(@binary_dir, "salix-connect"), "."],
        cd: source,
        stderr_to_stdout: true
      )

    assert status == 0, output
    on_exit(fn -> File.rm_rf(@binary_dir) end)
    _ = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    case ensure_distribution() do
      :ok ->
        restart_local_ring!()
        {:ok, peer, node} = start_peer()
        peer_port = configure_peer(node)

        on_exit(fn ->
          try do
            :peer.stop(peer)
          catch
            _, _ -> :ok
          end
        end)

        {:ok, node: node, peer_port: peer_port}

      {:error, reason} ->
        flunk("BEAM distribution is unavailable: #{inspect(reason)}")
    end
  end

  setup do
    # Node A also talks to the shared MinIO bucket (fakes are per-VM).
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.AWS)
    SystemsRuntime.put_env(:salix_store, :s3_bucket, "salix-test")
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, SalixWeb.EnvDispatch)
    File.mkdir_p!(@root)
    on_exit(fn -> File.rm_rf(@root) end)
    :ok
  end

  test "agent on node A drives a real connector bridged on node B via :erpc", ctx do
    run(ctx)
  end

  test "idle archive on node A reaches a Cloud VM station connected to node B", ctx do
    run_remote_idle_archive(ctx.node)
  end

  defp run_remote_idle_archive(peer_node) do
    gateway = start_supervised!(MockCloudflareGateway)
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "MN archive"})
    tenant_id = tenant["tenant_id"]

    {:ok, group} =
      Salix.Control.Groups.create(
        %{
          "name" => "MN archive",
          "billing_owner" => %{"surface" => "bridge", "vm_profile_key" => "cf-standard-2"}
        },
        tenant_id
      )

    group_id = group["group_id"]

    {:ok, _} =
      Salix.Control.Tenants.update(tenant_id, %{
        "config" =>
          Jason.encode!(%{
            "vm" => %{
              "default_provider" => "cloudflare",
              "providers" => %{
                "cloudflare" => %{
                  "enabled" => true,
                  "gateway_base_url" => MockCloudflareGateway.base_url(gateway),
                  "gateway_secret" => "test-secret"
                }
              }
            }
          })
      })

    previous_vm = SystemsRuntime.get_env(:salix_web, :sprites)
    previous_r2 = SystemsRuntime.get_env(:salix_web, :cloud_vm_archive_r2)
    SystemsRuntime.put_env(:salix_web, :sprites, auto_provision: false)

    # The station exports its archive straight to R2; the Gateway mock stores the parts.
    SystemsRuntime.put_env(:salix_web, :cloud_vm_archive_r2, %{
      "endpoint" => "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
      "bucket" => "test-archive",
      "access_key_id" => "testaccess",
      "secret_access_key" => "testsecret"
    })

    # R2 itself is the store the Gateway mock's stations write their parts to.
    SystemsRuntime.put_env(:salix_web, :cloud_vm_archive_r2_req,
      plug: &SalixWeb.MockCloudflareGateway.r2/1
    )

    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :cloud_vm_archive_r2_req) end)

    on_exit(fn ->
      if previous_vm,
        do: SystemsRuntime.put_env(:salix_web, :sprites, previous_vm),
        else: SystemsRuntime.delete_env(:salix_web, :sprites)

      if previous_r2,
        do: SystemsRuntime.put_env(:salix_web, :cloud_vm_archive_r2, previous_r2),
        else: SystemsRuntime.delete_env(:salix_web, :cloud_vm_archive_r2)
    end)

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "group_id" => group_id,
          "name" => "MN archive agent"
        },
        tenant_id
      )

    assert {:ok, %{"provider_spec" => %{"profile_key" => "cf-standard-2"}}} =
             Cloudflare.ensure_provisioning(agent)

    assert {:ok, :ready} = Cloudflare.provision_once(group_id, force: true)
    assert {:ok, rec} = Cloudflare.get_record(group_id)
    env_id = rec["env_id"]
    assert Registry.lookup(SalixEnv.Bridges, env_id) != []

    # The VM's station reconnects, to node B.
    :ok =
      MockCloudflareGateway.set_station_server(
        gateway,
        :erpc.call(peer_node, SalixWeb.Application, :base_url, [])
      )

    :ok = MockCloudflareGateway.restart_station(gateway, rec["provider_resource_name"])

    assert eventually(fn ->
             Registry.lookup(SalixEnv.Bridges, env_id) == [] and
               :erpc.call(peer_node, Registry, :lookup, [SalixEnv.Bridges, env_id]) != []
           end)

    assert {:ok, %{"status" => "archived"}} = Cloudflare.archive_idle_once(group_id, force: true)
    assert Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy))

    assert {:ok, %{"status" => "ready"}} = Cloudflare.wake_archived_vm(group_id)
  end

  defp run(%{node: node, peer_port: peer_port}) do
    {:ok, tenant} =
      Salix.Control.Tenants.create(%{"name" => "MN"})

    tenant_id = tenant["tenant_id"]

    {:ok, group} = Salix.Control.Groups.create(%{"name" => "MN"}, tenant_id)
    group_id = group["group_id"]

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"group_id" => group_id, "name" => "mn-agent"},
        tenant_id
      )

    agent_id = agent["agent_id"]

    {:ok, token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
        "name" => "mn-laptop",
        "alias" => "mn-laptop"
      })

    port_proc = start_connector(peer_port, group_id, token["token"])

    try do
      device = wait_for_connected!(group_id)
      connector_run_id = device["connector_run_id"]
      device_id = device["device_id"]

      {:ok, %{"environment_id" => environment_id}} =
        SalixEnv.Control.get_environment(device_id, group_id, tenant_id)

      # The record is owned by node B, not node A.
      assert device["node"] == to_string(node)
      refute SalixEnv.Bridge.local?(connector_run_id), "connector socket must NOT be on node A"

      assert eventually(fn -> :erpc.call(node, SalixEnv.Bridge, :local?, [connector_run_id]) end),
             "connector socket must be bridged on node B"

      # env.exec from node A → routed by :erpc to node B → WebSocket → Go → /bin/sh.
      assert {:ok, %{"exit_code" => 0, "stdout" => out}} =
               SalixWeb.EnvDispatch.exec(
                 agent_id,
                 %{device_id: device_id, environment_id: environment_id},
                 "echo cross-node && uname -s",
                 %{}
               )

      assert out =~ "cross-node"

      # A file written through the connector is readable back through it.
      assert {:ok, %{"size" => _}} =
               SalixWeb.EnvDispatch.request(
                 agent_id,
                 %{device_id: device_id, environment_id: environment_id},
                 "write",
                 %{
                   "path" => Path.join(@root, "mn.txt"),
                   "content" => "two-node bytes\n"
                 }
               )

      assert {:ok, %{"content" => "two-node bytes\n"}} =
               SalixWeb.EnvDispatch.request(
                 agent_id,
                 %{device_id: device_id, environment_id: environment_id},
                 "read",
                 %{
                   "path" => Path.join(@root, "mn.txt")
                 }
               )

      # Streaming copy runs on node A, but its connector socket and transfer
      # owner live on node B. This exercises the h2c transfer/VFS path both
      # directions instead of the legacy inline read/write RPCs.
      body = large_body()
      {:ok, src_event} = AgentWorkspace.prepare_write(agent_id, "/vfs-src.bin", body)

      assert {:ok, _} =
               AgentWorkspace.seed_operation(agent_id, "connector-mn-src", %{}, [src_event])

      ctx = tool_ctx(agent_id)

      [to_remote] =
        Tools.execute(
          [
            call("env.copy", %{
              "src_environment" => "vfs",
              "src_path" => "/vfs-src.bin",
              "dst_device_id" => device_id,
              "dst_environment" => environment_id,
              "dst_path" => Path.join(@root, "copied-from-vfs.bin")
            })
          ],
          ctx
        )

      assert to_remote.error == false
      assert %{"copied" => true, "size" => size} = Jason.decode!(to_remote.content)
      assert size == byte_size(body)
      assert File.read!(Path.join(@root, "copied-from-vfs.bin")) == body

      [to_vfs] =
        Tools.execute(
          [
            call("env.copy", %{
              "src_device_id" => device_id,
              "src_environment" => environment_id,
              "src_path" => Path.join(@root, "copied-from-vfs.bin"),
              "dst_environment" => "vfs",
              "dst_path" => "/copied-back.bin"
            })
          ],
          ctx
        )

      assert to_vfs.error == false, to_vfs.content
      assert [%{"type" => "vfs_write"} = write_back] = to_vfs.events

      assert {:ok, _} =
               AgentWorkspace.seed_operation(agent_id, "connector-mn-back", %{}, [write_back])

      assert {:ok, ^body} = AgentWorkspace.read(agent_id, "/copied-back.bin")

      # The agent's env.list tool (running on A) sees the B-bridged env.
      envs =
        Jason.decode!(
          SalixAgent.Tools.Peers.list_devices(%{}, %{
            agent_id: agent_id,
            session_id: SalixStore.Ids.new_session_id()
          })
        )["devices"]

      assert "mn-laptop" in Enum.map(envs, & &1["alias"])

      stop_connector(port_proc)

      assert eventually(fn ->
               match?(
                 {:ok, %{"status" => "disconnected"}},
                 SalixEnv.Registry.get_device(tenant_id, group_id, device_id)
               )
             end)

      assert {:error, :not_found} =
               SalixEnv.Registry.get_by_connector_run_id(connector_run_id)

      second_port = start_connector(peer_port, group_id, token["token"])

      try do
        reconnected = wait_for_connected!(group_id)
        assert reconnected["device_id"] == device_id
        refute reconnected["connector_run_id"] == connector_run_id

        assert {:ok, [listed]} = SalixEnv.Registry.list_by_group(group_id)
        assert listed["device_id"] == device_id

        assert {:ok, %{"environment_id" => ^environment_id}} =
                 SalixEnv.Control.get_environment(device_id, group_id, tenant_id)

        assert {:ok, %{"exit_code" => 0, "stdout" => reconnected_out}} =
                 SalixWeb.EnvDispatch.exec(
                   agent_id,
                   %{device_id: device_id, environment_id: environment_id},
                   "echo reconnected-cross-node",
                   %{}
                 )

        assert reconnected_out =~ "reconnected-cross-node"
      after
        stop_connector(second_port)
      end
    after
      stop_connector(port_proc)
    end
  end

  defp large_body do
    chunk = :crypto.hash(:sha256, "salix-multinode-stream")
    IO.iodata_to_binary(List.duplicate(chunk, 262_144))
  end

  defp call(name, args),
    do: %{
      "id" => "c-#{SystemsRuntime.Proc.unique_integer([:positive])}",
      "name" => name,
      "args" => args
    }

  defp tool_ctx(agent_id) do
    ctx =
      %{
        agent_id: agent_id,
        session_id: SalixStore.Ids.new_session_id(),
        role: "worker",
        runtime_kind: :internal
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", :internal, ctx))
  end

  # ---- the real Go connector, attached to node B ----

  defp start_connector(peer_port, _group_id, connector_token) do
    Port.open({:spawn_executable, Path.join(@binary_dir, "salix-connect")}, [
      :binary,
      :exit_status,
      args: [
        "--server",
        "ws://127.0.0.1:#{peer_port}",
        "--name",
        "mn-laptop",
        "--connector-token",
        connector_token,
        "--state-root",
        @root,
        "--root",
        @root
      ]
    ])
  end

  defp stop_connector(port_proc) do
    case Port.info(port_proc, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", [Integer.to_string(os_pid)])
      _ -> :ok
    end
  end

  defp wait_for_connected!(group_id, attempts \\ 100) do
    case SalixEnv.Registry.list_connected_by_group(group_id) do
      {:ok, [env | _]} ->
        env

      _ when attempts > 0 ->
        SystemsRuntime.Proc.sleep(100)
        wait_for_connected!(group_id, attempts - 1)

      _ ->
        flunk("connector never registered within timeout")
    end
  end

  defp eventually(fun, retries \\ 1500) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> SystemsRuntime.Proc.sleep(20) && eventually(fun, retries - 1)
    end
  end

  # ---- distribution + peer (node B runs salix_web on MinIO) ----

  defp restart_local_ring! do
    # The umbrella starts before this test enables BEAM distribution, so the
    # original Ring was initialized with `nonode@nohost`. Production nodes are
    # named before applications start; rebuild here to exercise that topology
    # instead of hashing a test-only pseudo-node that the peer never sees.
    :ok = Supervisor.terminate_child(SalixCluster.Supervisor, SalixCluster.Ring)

    case Supervisor.restart_child(SalixCluster.Supervisor, SalixCluster.Ring) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      other -> flunk("could not restart the local Ring: #{inspect(other)}")
    end

    assert eventually(fn -> SalixCluster.Ring.nodes() == [node()] end)
  end

  defp ensure_distribution do
    if Node.alive?() do
      :ok
    else
      name = :"salix_web_main_#{SystemsRuntime.Proc.unique_integer([:positive])}@127.0.0.1"

      case :net_kernel.start([name, :longnames]) do
        {:ok, _} ->
          :erlang.set_cookie(Node.self(), :salix_test_cookie)
          :ok

        {:error, _} ->
          case :net_kernel.start([:salix_web_main, :shortnames]) do
            {:ok, _} -> :erlang.set_cookie(Node.self(), :salix_test_cookie) && :ok
            {:error, reason} -> {:error, reason}
          end
      end
    end
  rescue
    e -> {:error, e}
  end

  defp start_peer do
    [_, host] = String.split(to_string(Node.self()), "@")
    name = :"salix_web_peer_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    cookie = Atom.to_charlist(:erlang.get_cookie())
    long? = String.contains?(host, ".")

    {:ok, peer, node} =
      :peer.start_link(%{
        name: name,
        host: String.to_charlist(host),
        longnames: long?,
        args: [~c"-setcookie", cookie]
      })

    true = Node.connect(node)
    {:ok, peer, node}
  end

  defp configure_peer(node) do
    :erpc.call(node, :code, :add_pathsz, [:code.get_path()])

    for {k, v} <- [
          s3_endpoint: "http://127.0.0.1:19000",
          s3_region: "us-east-1",
          s3_bucket: "salix-test",
          s3_access_key_id: "minioadmin",
          s3_secret_access_key: "minioadmin",
          s3_backend: SalixStore.S3.AWS,
          snowflake_worker_id: 1,
          # A Cloud VM station connecting to node B signs in with node A's Workload credential.
          compute_workload_credential_secret:
            SystemsRuntime.fetch_env!(:salix_store, :compute_workload_credential_secret)
        ] do
      :ok = :erpc.call(node, Application, :put_env, [:salix_store, k, v])
    end

    :ok =
      :erpc.call(node, Application, :put_env, [
        :salix_store,
        SalixStore.Repo,
        SystemsRuntime.fetch_env!(:salix_store, SalixStore.Repo)
      ])

    :ok = :erpc.call(node, Application, :put_env, [:salix_store, :start_repo, true])

    # Node B serves the WebSocket endpoint on an ephemeral port. The real
    # connector authenticates with the group connector token minted on node A.
    :ok = :erpc.call(node, Application, :put_env, [:salix_web, :port, 0])

    :ok =
      :erpc.call(node, Application, :put_env, [
        :salix_web,
        :site_rate_limit_redis_url,
        SystemsRuntime.fetch_env!(:salix_web, :site_rate_limit_redis_url)
      ])

    :ok = :erpc.call(node, Application, :put_env, [:salix_env, :transfer_port, free_tcp_port()])
    :ok = :erpc.call(node, Application, :put_env, [:salix_env, :advertise_host, "127.0.0.1"])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:salix_web])
    :erpc.call(node, SalixWeb.Application, :http_port, [])
  end

  defp free_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
