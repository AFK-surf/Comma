defmodule SalixWeb.ComputePressureE2ETest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias SalixStore.{AgentVMM, AgentVMMHostClient, Compute, Repo}

  @moduletag timeout: 1_200_000
  @moduletag skip: System.get_env("COMMA_VMM_PRESSURE_E2E") != "1"

  test "six isolated runtimes remain warm until real host pressure" do
    previous_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    root = Path.join(System.tmp_dir!(), "comma-pressure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    config_path = Path.join(root, "fixture.json")
    on_exit(fn -> File.write!(config_path <> ".stop", "stop") end)
    ca = Path.join(root, "ca.pem")
    ca_key = Path.join(root, "ca-key.pem")
    cert = Path.join(root, "leaf.pem")
    key = Path.join(root, "key.pem")
    csr = Path.join(root, "leaf.csr")
    extensions = Path.join(root, "extensions.cnf")

    File.write!(
      extensions,
      "subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\n"
    )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-days",
          "1",
          "-subj",
          "/CN=Comma pressure fixture CA",
          "-addext",
          "basicConstraints=critical,CA:TRUE",
          "-keyout",
          ca_key,
          "-out",
          ca
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-new",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-subj",
          "/CN=localhost",
          "-keyout",
          key,
          "-out",
          csr
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "x509",
          "-req",
          "-in",
          csr,
          "-CA",
          ca,
          "-CAkey",
          ca_key,
          "-CAcreateserial",
          "-days",
          "1",
          "-extfile",
          extensions,
          "-out",
          cert
        ],
        stderr_to_stdout: true
      )

    File.chmod!(ca_key, 0o600)
    File.chmod!(key, 0o600)
    listener = start_supervised!({Bandit, plug: SalixWeb.Router, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, control_port}} = ThousandIsland.listener_info(listener)
    remote_port = free_port()
    internal_port = free_port()
    secret = Base.url_encode64(:crypto.strong_rand_bytes(32))
    image = System.fetch_env!("COMMA_VMM_PRESSURE_IMAGE") |> File.read!() |> Jason.decode!()

    images =
      for class <- ~w(external meeting shell),
          do:
            Map.merge(image, %{
              "class" => class,
              "reference" => "comma.local/runtime/#{class}@#{image["manifestDigest"]}"
            })

    File.write!(
      Path.join(root, "manifest.json"),
      Jason.encode!(%{
        "schemaVersion" => 3,
        "sourceRevision" => "isolated-pressure-fixture",
        "images" => images
      })
    )

    configure(:salix_web, :agent_vmm_gateway_control_secret, secret)

    configure(:salix_store, :agent_vmm_gateway_instances, %{
      "pressure-gateway" => "https://localhost:#{internal_port}"
    })

    configure(:salix_store, :agent_vmm_gateway_tls,
      cacertfile: ca,
      certfile: cert,
      keyfile: key,
      verify: :verify_peer
    )

    configure(:salix_store, :compute_runtime_base_url, "http://127.0.0.1:18081")
    configure(:salix_store, :compute_workload_credential_secret, secret)
    configure(:salix_store, :runtime_bundle_root, root)

    suffix = System.unique_integer([:positive])

    registrations =
      for n <- 1..6 do
        id = "pressure-#{suffix}-#{n}"
        enrollment = :crypto.strong_rand_bytes(32)
        credential = :crypto.strong_rand_bytes(32)

        {:ok, registration} =
          AgentVMM.create_registration(%{
            id: id,
            tenant_id: id,
            group_id: id,
            device_id: id,
            enrollment_token: enrollment,
            desired_enabled: true
          })

        {:ok, _} = AgentVMM.enroll(id, enrollment, credential)

        {:ok, pool} =
          Compute.create_pool(%{
            id: id,
            tenant_id: id,
            name: "pressure",
            region: "local",
            provider_policy: %{"providers" => ["agent_vmm"]},
            capabilities: ["runtime_exec", "runtime_process"]
          })

        {:ok, environment} =
          Compute.create_environment(%{
            id: id,
            tenant_id: id,
            owner_type: "project",
            owner_id: id,
            pool_id: pool.id
          })

        {:ok, _binding} =
          Compute.create_provider_binding(%{
            id: id,
            pool_id: pool.id,
            environment_id: environment.id,
            provider: "agent_vmm",
            provider_ref: id,
            generation: 1
          })

        {registration, %{id: id, credential: Base.encode64(credential)}}
      end

    config = %{
      remote_endpoint: "localhost:#{remote_port}",
      internal_listen: "127.0.0.1:#{internal_port}",
      control_url: "http://127.0.0.1:#{control_port}",
      control_secret: secret,
      ca_file: ca,
      cert_file: cert,
      key_file: key,
      image: image,
      archive_path: System.fetch_env!("COMMA_VMM_PRESSURE_ARCHIVE"),
      registrations: Enum.map(registrations, &elem(&1, 1))
    }

    File.write!(config_path, Jason.encode!(config))
    File.chmod!(config_path, 0o600)

    gateway =
      launch(
        System.fetch_env!("COMMA_VMM_PRESSURE_GATEWAY"),
        "TestCommaVMMPressureGatewayE2E",
        config_path,
        root,
        "gateway"
      )

    eventually(fn -> File.exists?(config_path <> ".gateway-ready") end, 30_000)

    host =
      launch(
        System.fetch_env!("COMMA_VMM_PRESSURE_HOST"),
        "TestCommaPressureBridgeE2E",
        config_path,
        root,
        "host"
      )

    eventually(fn -> File.exists?(config_path <> ".host-ready") end, 180_000)
    IO.puts("pressure fixture ready: #{root}")

    workloads =
      for {registration, _} <- registrations do
        id = registration.id
        eventually(fn -> Repo.get(AgentVMM.RegistrationObservation, id) != nil end, 30_000)

        eventually(fn -> Repo.get!(Compute.ProviderBinding, id).status == "available" end, 30_000)

        {:ok, allocation} =
          Compute.allocate(%{
            id: id,
            environment_id: id,
            provider_binding_id: id,
            generation: 1
          })

        {:ok, workload} =
          Compute.create_workload(%{
            id: id,
            environment_id: id,
            allocation_id: allocation.id,
            kind: "external_worker",
            template_key: "external.pi",
            capability_requirements: ["runtime_exec", "runtime_process"],
            generation: 1
          })

        {:ok, credential} = Compute.WorkloadCredential.issue(id, nil, ["runtime"], 900)

        eventually(
          fn ->
            case AgentVMM.current_host_session_for_workload(id) do
              {:ok, _} ->
                File.exists?(config_path <> ".imported-" <> allocation.id)

              _ ->
                SalixEnv.ComputeReconciler.reconcile_workload(id, 1,
                  credential: credential,
                  external_demand: true
                )

                false
            end
          end,
          120_000
        )

        eventually(
          fn ->
            SalixEnv.ComputeReconciler.reconcile_workload(id, 1,
              credential: credential,
              external_demand: true
            )

            Repo.exists?(
              from(r in Compute.RuntimeInstance,
                where: r.workload_id == ^id and r.status == "connected"
              )
            )
          end,
          120_000
        )

        IO.puts("pressure runtime connected: #{id}")
        workload
      end

    for workload <- workloads do
      # Each idle container has reclaimable anonymous memory. The child is
      # bounded to five minutes and has no provider or session credentials.
      script =
        "require('child_process').spawn(process.execPath,['-e', 'globalThis.memory=Buffer.alloc(256*1024*1024,1);setTimeout(()=>process.exit(0),300000)'],{detached:true,stdio:'ignore'}).unref()"

      assert {:ok, %{"exit_code" => 0}} = exec(workload.id, ["node", "-e", script])
    end

    # The idle deadline alone must not stop any of these real carriers.
    Process.sleep(65_000)

    for workload <- workloads do
      SalixEnv.ComputeReconciler.reconcile_workload(workload.id, 1)

      assert {:ok, %{"containers" => [container]}} =
               AgentVMMHostClient.provider_call(:container_list, %{}, workload.id)

      assert container["state"] == "CONTAINER_STATE_RUNNING"

      assert {:ok, %{"status" => "EXECUTION_LIST_STATUS_EMPTY"}} =
               AgentVMMHostClient.provider_call(
                 :execution_list,
                 %{
                   "container_id" => container["id"],
                   "expected_instance_id" => container["instance_id"]
                 },
                 workload.id
               )

      assert Repo.exists?(
               from(r in Compute.RuntimeInstance,
                 where: r.workload_id == ^workload.id and r.status == "connected"
               )
             )
    end

    [busy | _] = workloads
    sample = guest_sample(config_path)
    assert abs(sample["limit"] - sample["total"]) < 4096
    assert sample["oom"] == 0

    assert Regex.match?(
             ~r/PRESSURE_CHILD_OOM child=[1-9][0-9]* parent_before=0 parent_after=0/,
             guest_log(config_path)
           )

    # Use the actual Guest MemTotal-derived parent limit, not the VZ memory size.
    extra_bytes = trunc(sample["limit"] * 0.95) - sample["current"]
    assert extra_bytes > 0 and extra_bytes < 2 * 1024 * 1024 * 1024
    IO.puts("pressure baseline=#{inspect(sample)}; injection bytes=#{extra_bytes}")

    {:ok, %{"containers" => [busy_container]}} =
      AgentVMMHostClient.provider_call(:container_list, %{}, busy.id)

    execution = %{
      "execution_id" => "fixture-busy",
      "container_id" => busy_container["id"],
      "expected_instance_id" => busy_container["instance_id"],
      "deadline_unix_nano" => "0",
      "kind" => "main_execution"
    }

    assert {:ok, %{"acquired" => true}} =
             AgentVMMHostClient.provider_call(:execution_acquire, execution, busy.id)

    pressure =
      Task.async(fn ->
        exec(busy.id, [
          "node",
          "-e",
          "globalThis.memory=Buffer.alloc(#{extra_bytes},1);setTimeout(()=>process.exit(0),80000)"
        ])
      end)

    eventually(
      fn ->
        sample = guest_sample(config_path)
        sample["current"] >= sample["limit"] * 0.9
      end,
      30_000
    )

    eventually(fn -> Enum.any?(workloads, &candidate?/1) end, 45_000)
    candidates = Enum.filter(workloads, &candidate?/1)
    assert [idle] = candidates
    refute idle.id == busy.id
    peak = guest_sample(config_path)
    assert peak["current"] >= peak["limit"] * 0.9
    assert peak["available"] > 128 * 1024 * 1024
    assert peak["oom"] == 0
    IO.puts("pressure peak=#{inspect(peak)}")
    IO.puts("pressure candidate: #{idle.id}; busy protected: #{busy.id}")

    eventually(
      fn ->
        SalixEnv.ComputeReconciler.reconcile_workload(idle.id, 1)

        {:ok, %{"containers" => [container]}} =
          AgentVMMHostClient.provider_call(:container_list, %{}, idle.id)

        container["state"] == "CONTAINER_STATE_STOPPED"
      end,
      30_000
    )

    for workload <- workloads, workload.id != idle.id do
      assert {:ok, %{"containers" => [container]}} =
               AgentVMMHostClient.provider_call(:container_list, %{}, workload.id)

      assert container["state"] == "CONTAINER_STATE_RUNNING"
      refute candidate?(busy)
    end

    assert {:ok, %{"exit_code" => 0}} = Task.await(pressure, 90_000)
    assert {:ok, _} = AgentVMMHostClient.provider_call(:execution_release, execution, busy.id)

    # With every surviving instance execution-held, only the kernel may choose
    # an OOM victim. This deliberately exceeds the isolated VM's parent limit.
    survivors = Enum.reject(workloads, &(&1.id == idle.id))

    activities =
      for workload <- survivors do
        {:ok, %{"containers" => [container]}} =
          AgentVMMHostClient.provider_call(:container_list, %{}, workload.id)

        activity = %{
          "execution_id" => "fixture-oom-#{workload.id}",
          "container_id" => container["id"],
          "expected_instance_id" => container["instance_id"],
          "deadline_unix_nano" => "0",
          "kind" => "main_execution"
        }

        assert {:ok, %{"acquired" => true}} =
                 AgentVMMHostClient.provider_call(:execution_acquire, activity, workload.id)

        {workload, activity}
      end

    eventually(fn -> Enum.all?(survivors, &(not candidate?(&1))) end, 30_000)
    before_oom = guest_sample(config_path)["oom"]

    oom_task =
      Task.async(fn ->
        exec(busy.id, [
          "node",
          "-e",
          "globalThis.memory=Buffer.alloc(4*1024*1024*1024,1);setTimeout(()=>process.exit(0),60000)"
        ])
      end)

    eventually(fn -> guest_sample(config_path)["oom"] > before_oom end, 45_000)
    IO.puts("pressure parent OOM=#{inspect(guest_sample(config_path))}")

    for _ <- 1..10 do
      for workload <- survivors, do: refute(candidate?(workload))
      Process.sleep(1_000)
    end

    refute match?({:ok, %{"exit_code" => 0}}, Task.await(oom_task, 90_000))

    # Parent OOM may affect any workload. The contract above is that the
    # pressure controller does not select an execution-held instance.
    for {workload, activity} <- activities do
      AgentVMMHostClient.provider_call(:execution_release, activity, workload.id)
    end

    File.write!(config_path <> ".stop", "stop")
    assert {_, 0} = Task.await(host, 30_000)
    assert {_, 0} = Task.await(gateway, 30_000)
  end

  defp candidate?(workload) do
    candidate =
      Repo.get!(AgentVMM.RegistrationObservation, workload.id).usage["workload_reclaim_candidate"]

    is_map(candidate) and candidate["expires_at_ms"] > System.system_time(:millisecond)
  end

  defp guest_log(config_path) do
    %{"serial_log" => path} =
      config_path |> Kernel.<>(".host-ready") |> File.read!() |> Jason.decode!()

    File.read!(path)
  end

  defp guest_sample(config_path) do
    line =
      guest_log(config_path)
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "PRESSURE_FIXTURE "))
      |> List.last()

    assert is_binary(line), "Guest pressure diagnostics are absent"

    for [_, key, value] <- Regex.scan(~r/(\w+)=(\d+)/, line),
        into: %{},
        do: {key, String.to_integer(value)}
  end

  defp exec(id, argv) do
    {:ok, %{"containers" => [container]}} =
      AgentVMMHostClient.provider_call(:container_list, %{}, id)

    AgentVMMHostClient.provider_call(
      :container_exec,
      %{"container_id" => container["id"], "argv" => argv},
      id
    )
  end

  defp configure(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(app, key, old)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp launch(binary, test, config, root, name) do
    Task.async(fn ->
      output = File.stream!(Path.join(root, name <> ".log"))

      result =
        System.cmd(binary, ["-test.run=^#{test}$", "-test.v", "-test.timeout=16m"],
          env: [{"COMMA_VMM_E2E_CONFIG", config}],
          cd:
            if(name == "host",
              do: System.fetch_env!("COMMA_VMM_SOURCE") <> "/test/e2e",
              else: File.cwd!()
            ),
          into: output,
          stderr_to_stdout: true
        )

      assert elem(result, 1) == 0, "#{name} fixture failed; see #{root}/#{name}.log"
      result
    end)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp eventually(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    unless fun.() do
      assert System.monotonic_time(:millisecond) < deadline, "pressure fixture did not converge"
      Process.sleep(1_000)
      poll(fun, deadline)
    end
  end
end
