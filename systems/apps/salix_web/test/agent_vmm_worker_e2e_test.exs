defmodule SalixWeb.AgentVMMWorkerE2ETest do
  @moduledoc """
  The node's Agent VMM worker (`SalixStore.AgentVMM.Worker`) between the real
  Salix store and a test Host process, over the real transports: a Host
  authenticates and connects, Salix hands it an allocation and a session
  through the worker, and typed runtime operations reach the Host from this
  node and from another one.

  The worker and the test Host are built from
  `systems/gateway/salix-vmm-worker` (`make testhost PROFILE=dev`).
  """
  use SystemsClock.Case, async: false

  @moduletag :multinode

  alias SalixStore.{AgentVMM, AgentVMMHostClient, Compute, Repo}
  alias SalixStore.AgentVMM.Worker

  @credential String.duplicate("enroll-", 4)
  @instance_id "comma-e2e-0"
  # Above 2^53 and 2^63: a connection epoch is an opaque decimal string to Salix.
  @epoch 9_223_372_036_854_775_808
  @digest String.duplicate("a", 64)
  @archive String.duplicate("b", 64)

  defmodule Notifier do
    @moduledoc false
    # Stands where SalixEnv.ComputeReconciler does: told when a Host session commits.
    def host_session_ready(allocation_id) do
      case SystemsRuntime.Proc.whereis(SalixWeb.AgentVMMWorkerE2ETest) do
        nil -> :ok
        test -> SystemsRuntime.Proc.send(test, {:host_session_ready, allocation_id})
      end

      :ok
    end
  end

  setup_all do
    source = Path.expand("../../../gateway/salix-vmm-worker", __DIR__)
    priv = to_string(:code.priv_dir(:salix_store))
    host = Path.join(priv, "salix_vmm_test_host")

    {output, status} =
      System.cmd(
        "make",
        ["-s", "-C", source, "testhost", "PROFILE=dev"] ++
          ["OUT=" <> Path.join(priv, "salix_vmm_worker"), "TESTHOST=" <> host],
        stderr_to_stdout: true
      )

    assert status == 0, output

    _ = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    unless Node.alive?() do
      name = :"agent_vmm_main_#{SystemsRuntime.Proc.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = :net_kernel.start([name, :longnames])
    end

    %{host_exe: host}
  end

  setup %{host_exe: host_exe} do
    Repo.query!(
      "TRUNCATE compute_reconciler_claims, compute_reconciler_cursors, agent_vmm_route_capabilities, agent_vmm_membership_credentials, agent_vmm_trust_anchors, agent_vmm_audit_events, agent_vmm_sessions, agent_vmm_registrations, compute_commands, compute_grants, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools CASCADE"
    )

    {:ok, _} =
      SalixStore.AgentVMMFixtures.registration(%{
        id: "registration",
        tenant_id: "tenant",
        group_id: "group",
        device_id: "device",
        credential: @credential,
        desired_enabled: true
      })

    {:ok, _} =
      Compute.create_pool(%{
        id: "pool",
        tenant_id: "tenant",
        name: "Agent VMM",
        region: "local",
        capabilities: ["runtime_exec"],
        provider_policy: %{"providers" => ["agent_vmm"]}
      })

    {:ok, _} =
      Compute.create_environment(%{
        id: "environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "project",
        pool_id: "pool"
      })

    {:ok, _} =
      Compute.create_provider_binding(%{
        id: "binding",
        pool_id: "pool",
        environment_id: "environment",
        provider: "agent_vmm",
        provider_ref: "registration"
      })

    previous = SystemsRuntime.get_env(:salix_store, :agent_vmm_session_notifier)
    SystemsRuntime.put_env(:salix_store, :agent_vmm_session_notifier, Notifier)
    SystemsRuntime.Proc.register(self(), __MODULE__)

    handler = "agent-vmm-worker-e2e-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    SystemsRuntime.Telemetry.attach(
      handler,
      [:salix, :agent_vmm, :worker, :event],
      &__MODULE__.forward_event/4,
      self()
    )

    dir =
      Path.join(
        System.tmp_dir!(),
        "agent-vmm-e2e-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    {_, 0} = System.cmd(host_exe, ["gen-cert", dir])

    on_exit(fn ->
      SystemsRuntime.Telemetry.detach(handler)
      SystemsRuntime.put_env(:salix_store, :agent_vmm_session_notifier, previous)
      File.rm_rf(dir)
    end)

    worker = :"agent_vmm_worker_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    start_supervised!(
      {Worker,
       name: worker,
       instance_id: @instance_id,
       remote_listen: "127.0.0.1:0",
       tls_cert_file: Path.join(dir, "tls.crt"),
       tls_key_file: Path.join(dir, "tls.key"),
       iroh_preset: "minimal"}
    )

    "127.0.0.1:" <> _ = addr = SystemsRuntime.Server.call(worker, :remote_addr, :infinity)
    assert Worker.online?(@instance_id)

    host =
      Port.open({:spawn_executable, host_exe}, [
        :binary,
        :exit_status,
        {:line, 1_048_576},
        args: [
          "run",
          addr,
          Path.join(dir, "tls.crt"),
          "registration",
          Base.encode64(@credential),
          Integer.to_string(@epoch)
        ]
      ])

    on_exit(fn -> if Port.info(host), do: Port.close(host) end)
    %{worker: worker, host: host}
  end

  @doc false
  def forward_event(_event, _measurements, %{event: name}, test),
    do: SystemsRuntime.Proc.send(test, {:worker_event, name})

  test "a Host connects to the node's worker and Salix runs its Workload through it", ctx do
    %{host: host, worker: worker} = ctx
    epoch = Integer.to_string(@epoch)
    assert %{"connection_epoch" => ^epoch} = host_event(host, "ready")

    # Salix authenticated the credential and settled the hello under this node's instance id.
    registration = Repo.get!(AgentVMM.Registration, "registration")
    assert registration.connected
    assert registration.current_gateway_instance_id == @instance_id
    assert registration.current_connection_epoch == epoch

    %{workload: workload, epoch: epoch} = open_session!(host)
    assert {:ok, session} = AgentVMM.current_host_session_for_workload(workload.id)
    assert session.gateway_instance_id == @instance_id
    assert session.connection_epoch == epoch
    assert session.allocation_generation == 1

    # A command of the Workload runs in the Host's one running container.
    assert {:ok, %{"stdout_base64" => stdout, "exit_code" => 0}} =
             AgentVMMHostClient.exec_workload(
               %{"command" => ["echo", "from", "salix"]},
               workload.id
             )

    assert Base.decode64!(stdout) == "from salix"

    assert %{
             "container_id" => "workload",
             "expected_instance_id" => "instance-1",
             "execution_kind" => "EXECUTION_KIND_EXEC",
             "argv" => ["echo", "from", "salix"]
           } = host_runtime(host, "Exec")

    assert {:ok, %{"content_base64" => content}} =
             AgentVMMHostClient.call(:workspace_read, %{"path" => "notes.txt"}, workload.id)

    assert Base.decode64!(content) == "hello world"

    # The Host fetches a release-owned image itself; only its identity crosses.
    reference = "comma.local/runtime/shell@sha256:" <> @digest

    image = %{
      "class" => "shell",
      "reference" => reference,
      "platform" => "linux/arm64",
      "archiveUrl" => "https://cdn.example/runtime-bundles/sha256/#{@archive}.oci.tar",
      "archiveSize" => 4096,
      "archiveSha256" => @archive,
      "manifestDigest" => "sha256:" <> @digest
    }

    assert {:ok, imported} = AgentVMMHostClient.import_workload_image(image, workload.id)

    assert imported == %{
             "reference" => reference,
             "digest" => "sha256:" <> @digest,
             "platform" => "linux/arm64",
             "logical_bytes" => 4096,
             "generation_id" => "generation-1"
           }

    assert %{"image_reference" => ^reference, "archive_size" => "4096"} =
             host_runtime(host, "ImportImage")

    # A Host refusal reaches Salix as its finite code, never as Host text.
    assert {:error, {:gateway_error, refusal}} =
             AgentVMMHostClient.provider_call(
               :container_start,
               %{"container_id" => "stale"},
               workload.id
             )

    assert refusal == %{
             "code" => "stale_container_instance",
             "stage" => "container_start",
             "resource" => "runtime",
             "message" => "Runtime operation was rejected."
           }

    # Only the exact fenced session on the worker that holds it is served.
    key = session_key(epoch)

    assert {:ok, 200, %{}} =
             Worker.session_call(@instance_id, key, "compute.image.list", %{}, 30_000)

    assert {:ok, 404, nil} =
             Worker.session_call(
               @instance_id,
               %{key | allocation_generation: 2},
               "compute.image.list",
               %{},
               30_000
             )

    assert {:error, :gateway_unavailable} =
             Worker.session_call("comma-e2e-9", key, "compute.image.list", %{}, 30_000)

    assert {:error, {:tunnel_refused, "invalid endpoint address"}} =
             Worker.open_iroh_tunnel(%{"id" => 7}, 30_000, worker)

    # When the Host leaves, the worker tells Salix which connection ended, and the session with it.
    Port.close(host)
    await_event("host_disconnected")
    refute Repo.get!(AgentVMM.Registration, "registration").connected

    assert {:ok, 404, nil} =
             Worker.session_call(@instance_id, key, "compute.image.list", %{}, 30_000)
  end

  test "a node without the Host connection reaches its session through the node that holds it",
       %{host: host} do
    assert %{"connection_epoch" => _} = host_event(host, "ready")
    %{epoch: epoch} = open_session!(host)
    key = session_key(epoch)
    peer = start_peer!()
    {:ok, _} = :erpc.call(peer, :pg, :start, [Worker.pg_scope()])
    await_member(peer)

    # The other node holds no worker: it finds this one by the session's instance id.
    assert [] ==
             :erpc.call(peer, :pg, :get_local_members, [
               Worker.pg_scope(),
               {:agent_vmm_worker, @instance_id}
             ])

    assert {:ok, 200, %{}} =
             :erpc.call(peer, Worker, :session_call, [
               @instance_id,
               key,
               "compute.image.list",
               %{},
               30_000
             ])

    assert %{} = host_runtime(host, "ListImages")

    assert {:ok, 404, nil} =
             :erpc.call(peer, Worker, :session_call, [
               @instance_id,
               %{key | allocation_generation: 2},
               "compute.image.list",
               %{},
               30_000
             ])

    assert {:error, :gateway_unavailable} =
             :erpc.call(peer, Worker, :session_call, [
               "comma-e2e-9",
               key,
               "compute.image.list",
               %{},
               30_000
             ])
  end

  test "a worker that stops takes its Host connections with it", %{host: host, worker: worker} do
    assert %{"connection_epoch" => _} = host_event(host, "ready")
    await_event("host_connected")
    assert Repo.get!(AgentVMM.Registration, "registration").connected

    :ok = stop_supervised(worker)

    # Salix is told before the worker's node forgets the connection.
    refute Repo.get!(AgentVMM.Registration, "registration").connected
    refute Worker.online?(@instance_id)

    assert {:error, :gateway_unavailable} =
             Worker.session_call(
               @instance_id,
               session_key("1"),
               "compute.image.list",
               %{},
               30_000
             )
  end

  # Drives Salix's own provider through one allocation and one runtime session
  # on the connected Host, and returns the Workload and the Host's current epoch.
  defp open_session!(host) do
    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation",
        environment_id: "environment",
        provider_binding_id: "binding",
        generation: 1
      })

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload",
        environment_id: "environment",
        allocation_id: allocation.id,
        kind: "shell",
        template_key: "shell.default",
        spec: %{
          "resources" => %{
            "cpu_max_millis" => 1_000,
            "memory_max_bytes" => 536_870_912,
            "pid_max" => 512,
            "writable_quota_bytes" => 2_147_483_648
          }
        },
        generation: 1
      })

    {:ok, credential} = Compute.WorkloadCredential.issue(workload.id, nil, ["runtime"], 300)

    assert {:ok, %{outcome: :pending}} =
             SalixEnv.ComputeProviders.AgentVMM.allocate(allocation, workload, [])

    # The worker claims the ensure and the Host runs it. Its inventory changed,
    # so the worker ends the connection, and the Host reconnects under its next
    # epoch holding the allocation.
    assert %{"command" => %{"ensureAllocation" => %{"allocationId" => "allocation"}}} =
             host_event(host, "command")

    assert %{"code" => 0} = host_event(host, "ended")
    await_event("host_disconnected")
    assert %{"connection_epoch" => epoch} = host_event(host, "ready")
    allocation = Repo.get!(Compute.Allocation, allocation.id)
    assert allocation.status == "ready"
    assert Repo.get!(AgentVMM.Registration, "registration").current_connection_epoch == epoch

    assert {:ok, %{outcome: :pending}} =
             SalixEnv.ComputeProviders.AgentVMM.bootstrap(allocation, workload, credential, [])

    # The session is observed only after the Host's result has committed.
    receive do
      {:host_session_ready, "allocation"} -> :ok
    end

    %{workload: workload, epoch: epoch}
  end

  defp session_key(epoch) do
    %{
      registration_id: "registration",
      allocation_id: "allocation",
      allocation_generation: 1,
      connection_epoch: epoch
    }
  end

  # The next event of this name the test Host printed.
  defp host_event(host, name) do
    receive do
      {^host, {:data, {:eol, line}}} ->
        case Jason.decode!(line) do
          %{"event" => ^name} = event -> event
          _other -> host_event(host, name)
        end

      {^host, {:exit_status, status}} ->
        flunk("the test Host exited with status #{status} before #{name}")
    end
  end

  # The first request of the next runtime call of this method the Host served.
  defp host_runtime(host, method) do
    case host_event(host, "runtime") do
      %{"method" => ^method, "request" => request} -> request
      _other -> host_runtime(host, method)
    end
  end

  defp await_event(name) do
    receive do
      {:worker_event, ^name} -> :ok
    end
  end

  defp start_peer! do
    [_, host] = String.split(to_string(Node.self()), "@")

    {:ok, _peer, node} =
      :peer.start_link(%{
        name: :"agent_vmm_peer_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        host: String.to_charlist(host),
        longnames: String.contains?(host, "."),
        args: [~c"-setcookie", Atom.to_charlist(:erlang.get_cookie())]
      })

    true = Node.connect(node)
    :ok = :erpc.call(node, :code, :add_pathsa, [:code.get_path()])
    node
  end

  # The peer's scope learns this node's worker when the two scopes meet.
  defp await_member(peer) do
    case :erpc.call(peer, :pg, :get_members, [
           Worker.pg_scope(),
           {:agent_vmm_worker, @instance_id}
         ]) do
      [] ->
        :erlang.yield()
        await_member(peer)

      [_worker | _] ->
        :ok
    end
  end
end
