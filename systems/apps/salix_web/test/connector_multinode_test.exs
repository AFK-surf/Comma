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
  visible cross-node. Requires BEAM distribution + MinIO + Go; the module skips itself if distribution is unavailable.
  """
  use ExUnit.Case, async: false

  @moduletag :multinode

  alias SalixAgent.{AgentWorkspace, ToolDisclosure, Tools}
  alias SalixEnv.VM.Providers.Cloudflare.{Attachments, Client}
  alias SalixWeb.ComputeProviders.Cloudflare
  alias SalixWeb.MockCloudflareGateway
  @root "/tmp/salix-mn-connector-#{System.system_time(:second)}"

  @blocking_coordinator_handler_source ~S"""
  defmodule SalixWeb.ConnectorMultinodeTest.BlockingCoordinatorHandler do
    @moduledoc false

    def handle_connector_event(_connector_run_id, params, _meta) do
      send(params["test_pid"], {:multinode_coordinator_started, self()})

      receive do
        :release_multinode_coordinator ->
          {:ok, %{"event_id" => params["event_id"]}}
      end
    end

    def forward_remote_socket(test_pid) do
      receive do
        message ->
          send(test_pid, {:multinode_remote_socket, message})
          forward_remote_socket(test_pid)
      end
    end
  end
  """

  defmodule BlockingCoordinatorHandler do
    @moduledoc false

    def handle_connector_event(_connector_run_id, params, _meta) do
      send(params["test_pid"], {:multinode_coordinator_started, self()})

      receive do
        :release_multinode_coordinator ->
          {:ok, %{"event_id" => params["event_id"]}}
      end
    end

    def forward_remote_socket(test_pid) do
      receive do
        message ->
          send(test_pid, {:multinode_remote_socket, message})
          forward_remote_socket(test_pid)
      end
    end
  end

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
        {:ok, skip: reason}
    end
  end

  setup context do
    if context[:skip] do
      {:ok, skip: true}
    else
      # Node A also talks to the shared MinIO bucket (fakes are per-VM).
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.AWS)
      Application.put_env(:salix_store, :s3_bucket, "salix-test")
      Application.put_env(:salix_agent, :env_dispatch, SalixWeb.EnvDispatch)
      File.mkdir_p!(@root)
      on_exit(fn -> File.rm_rf(@root) end)
      :ok
    end
  end

  test "agent on node A drives a real connector bridged on node B via :erpc", ctx do
    if ctx[:skip], do: skip(), else: run(ctx)
  end

  test "idle archive on node A reaches a Cloudflare Connector owned by node B", ctx do
    if ctx[:skip], do: skip(), else: run_remote_idle_archive(ctx.node)
  end

  test "external-event submits from two nodes converge on the stable Ring owner", ctx do
    if ctx[:skip], do: skip(), else: run_coordinator_route(ctx.node)
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

    previous_vm = Application.get_env(:salix_web, :sprites)
    Application.put_env(:salix_web, :sprites, auto_provision: false)

    on_exit(fn ->
      if previous_vm,
        do: Application.put_env(:salix_web, :sprites, previous_vm),
        else: Application.delete_env(:salix_web, :sprites)
    end)

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "group_id" => group_id,
          "name" => "MN archive agent",
          "vm" => %{"enabled" => true, "provider" => "cloudflare"}
        },
        tenant_id
      )

    assert {:ok, %{"provider_spec" => %{"profile_key" => "cf-standard-2"}}} =
             Cloudflare.ensure_provisioning(agent)

    assert {:ok, :ready} = Cloudflare.provision_once(group_id, force: true)
    assert {:ok, rec} = Cloudflare.get_record(group_id)
    env_id = rec["env_id"]
    assert Registry.lookup(SalixEnv.Bridges, env_id) != []

    :ok = Attachments.stop(env_id)

    assert eventually(fn -> Registry.lookup(SalixEnv.Bridges, env_id) == [] end)

    {:ok, cfg} = SalixWeb.CloudVM.cloudflare_config(tenant_id)

    client =
      Client.new(
        base_url: cfg.base_url,
        secret: cfg.secret,
        worker_name: cfg.worker_name,
        worker_version_id: rec["current_worker_version_id"],
        group_id: group_id,
        backoff_ms: 1
      )

    assert {:ok, _pid} =
             :erpc.call(peer_node, Cloudflare, :attach_existing, [rec, %{}, [client: client]])

    on_exit(fn -> :erpc.call(peer_node, Attachments, :stop, [env_id]) end)

    assert eventually(fn ->
             Registry.lookup(SalixEnv.Bridges, env_id) == [] and
               :erpc.call(peer_node, Registry, :lookup, [SalixEnv.Bridges, env_id]) != []
           end)

    assert {:ok, %{"status" => "archived"}} = Cloudflare.archive_idle_once(group_id, force: true)
    assert Enum.any?(MockCloudflareGateway.calls(gateway), &(&1.op == :destroy))

    assert {:ok, %{"status" => "ready"}} = Cloudflare.wake_archived_vm(group_id)
    assert eventually(fn -> :erpc.call(peer_node, Attachments, :whereis, [env_id]) == nil end)
  end

  defp run_coordinator_route(peer_node) do
    load_blocking_coordinator_handler!(peer_node)

    assert eventually(fn ->
             expected_nodes = MapSet.new([node(), peer_node])
             local_nodes = MapSet.new(SalixCluster.Ring.nodes())
             peer_nodes = MapSet.new(:erpc.call(peer_node, SalixCluster.Ring, :nodes, []))

             local_nodes == expected_nodes and peer_nodes == expected_nodes
           end)

    assert SalixCluster.Ring.owner("connector-external-event-coordinator") ==
             :erpc.call(
               peer_node,
               SalixCluster.Ring,
               :owner,
               ["connector-external-event-coordinator"]
             )

    owner = SalixCluster.Ring.owner("connector-external-event-coordinator")
    previous = Application.get_env(:salix_web, :connector_external_runtime_handler)

    peer_previous =
      :erpc.call(peer_node, Application, :get_env, [
        :salix_web,
        :connector_external_runtime_handler
      ])

    Application.put_env(
      :salix_web,
      :connector_external_runtime_handler,
      __MODULE__.BlockingCoordinatorHandler
    )

    :ok =
      :erpc.call(peer_node, Application, :put_env, [
        :salix_web,
        :connector_external_runtime_handler,
        __MODULE__.BlockingCoordinatorHandler
      ])

    on_exit(fn ->
      restore_env(:connector_external_runtime_handler, previous)

      case peer_previous do
        nil ->
          :erpc.call(peer_node, Application, :delete_env, [
            :salix_web,
            :connector_external_runtime_handler
          ])

        value ->
          :erpc.call(peer_node, Application, :put_env, [
            :salix_web,
            :connector_external_runtime_handler,
            value
          ])
      end
    end)

    id = "multinode-coordinator-event"
    lane = {"tenant-multinode", "group-multinode", "device-multinode"}
    params = %{"event_id" => id, "test_pid" => self()}
    context = {:connector_context, "run-multinode", %{}}

    socket =
      if owner == node() do
        :erpc.call(peer_node, :erlang, :spawn, [
          __MODULE__.BlockingCoordinatorHandler,
          :forward_remote_socket,
          [self()]
        ])
      else
        self()
      end

    assert node(socket) != owner

    if node(socket) != node(), do: on_exit(fn -> Process.exit(socket, :kill) end)

    assert {:wait, waiter_ref} =
             SalixWeb.ConnectorExternalEventCoordinator.submit(
               socket,
               lane,
               1,
               id,
               params,
               context
             )

    assert_receive {:multinode_coordinator_started, worker}, 1_000

    assert {:reply, %{"id" => ^id, "type" => "error"}} =
             :erpc.call(
               peer_node,
               SalixWeb.ConnectorExternalEventCoordinator,
               :submit,
               [self(), lane, 1, id, params, context]
             )

    state =
      if owner == node() do
        :sys.get_state(SalixWeb.ConnectorExternalEventCoordinator)
      else
        :erpc.call(owner, :sys, :get_state, [SalixWeb.ConnectorExternalEventCoordinator])
      end

    assert state.retained_count == 1
    send(worker, :release_multinode_coordinator)

    if socket == self() do
      assert_receive {:connector_external_event_reply, ^waiter_ref,
                      %{"id" => ^id, "type" => "response"}},
                     1_000
    else
      assert_receive {:multinode_remote_socket,
                      {:connector_external_event_reply, ^waiter_ref,
                       %{"id" => ^id, "type" => "response"}}},
                     1_000
    end
  end

  defp load_blocking_coordinator_handler!(peer_node) do
    # Modules declared in a test .exs are loaded only in this VM, so adding the
    # local code paths does not make this callback available to the peer.
    expected = __MODULE__.BlockingCoordinatorHandler

    assert [{^expected, _beam}] =
             :erpc.call(peer_node, Code, :compile_string, [
               @blocking_coordinator_handler_source
             ])

    assert :erpc.call(peer_node, Code, :ensure_loaded?, [expected])

    assert :erpc.call(peer_node, :erlang, :function_exported, [
             expected,
             :handle_connector_event,
             3
           ])

    assert :erpc.call(peer_node, :erlang, :function_exported, [
             expected,
             :forward_remote_socket,
             1
           ])
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
    do: %{"id" => "c-#{System.unique_integer([:positive])}", "name" => name, "args" => args}

  defp tool_ctx(agent_id) do
    ctx =
      %{
        agent_id: agent_id,
        session_id: SalixStore.Ids.new_session_id(),
        role: "worker",
        runtime_kind: :external
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", :external, ctx))
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
        Process.sleep(100)
        wait_for_connected!(group_id, attempts - 1)

      _ ->
        flunk("connector never registered within timeout")
    end
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, retries - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:salix_web, key)
  defp restore_env(key, value), do: Application.put_env(:salix_web, key, value)

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
      name = :"salix_web_main_#{System.unique_integer([:positive])}@127.0.0.1"

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
    name = :"salix_web_peer_#{System.unique_integer([:positive])}"
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
          snowflake_worker_id: 1
        ] do
      :ok = :erpc.call(node, Application, :put_env, [:salix_store, k, v])
    end

    :ok =
      :erpc.call(node, Application, :put_env, [
        :salix_store,
        SalixStore.Repo,
        Application.fetch_env!(:salix_store, SalixStore.Repo)
      ])

    :ok = :erpc.call(node, Application, :put_env, [:salix_store, :start_repo, true])

    # Node B serves the WebSocket endpoint on an ephemeral port. The real
    # connector authenticates with the group connector token minted on node A.
    :ok = :erpc.call(node, Application, :put_env, [:salix_web, :port, 0])

    :ok =
      :erpc.call(node, Application, :put_env, [
        :salix_web,
        :site_rate_limit_redis_url,
        Application.fetch_env!(:salix_web, :site_rate_limit_redis_url)
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

  defp skip, do: ExUnit.configure(exclude: [])
end
