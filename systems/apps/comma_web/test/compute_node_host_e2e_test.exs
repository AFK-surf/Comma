defmodule CommaWeb.ComputeNodeHostE2ETest.Router do
  def init(opts), do: opts

  def call(conn, _opts) do
    if String.starts_with?(conn.request_path, "/v1/comma/"),
      do: CommaWeb.Router.call(conn, CommaWeb.Router.init([])),
      else: SalixWeb.Router.call(conn, SalixWeb.Router.init([]))
  end
end

defmodule CommaWeb.ComputeNodeHostE2ETest do
  use SystemsClock.Case, async: false
  import Ecto.Query
  alias SalixStore.{Compute, Repo, AgentVMMHostClient}
  @moduletag timeout: 1_000_000
  @moduletag skip: System.get_env("COMMA_COMPUTE_HOST_E2E") != "1"

  test "settings uses real Main, API and isolated Host for Shell creation and offline deletion" do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:multi_connection)
    on_exit(fn -> CommaWeb.TestRepoSandbox.stop_owner(owner) end)
    Logger.configure(level: :warning)

    root =
      Path.join(
        System.tmp_dir!(),
        "cue-compute-chain-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

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

    listener =
      start_supervised!(
        {Bandit, plug: CommaWeb.ComputeNodeHostE2ETest.Router, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_, control_port}} = ThousandIsland.listener_info(listener)
    remote_port = free_port()
    internal_port = free_port()
    secret = Base.url_encode64(SystemsRuntime.Proc.random_bytes(32))
    image = System.fetch_env!("COMMA_COMPUTE_HOST_IMAGE") |> File.read!() |> Jason.decode!()
    configure(:salix_web, :public_base_url, "http://127.0.0.1:#{control_port}")
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

    configure(:salix_store, :agent_vmm_install_material, %{
      "remote_enrollment" => %{
        "gateway_endpoint" => "localhost:#{remote_port}",
        "trust_bundle" => Base.encode64(File.read!(ca))
      }
    })

    configure(:salix_store, :agent_vmm_environment_scoped_bindings_enabled, true)
    configure(:salix_store, :compute_runtime_base_url, "http://127.0.0.1:18081")
    configure(:salix_store, :compute_workload_credential_secret, secret)
    configure(:salix_store, :runtime_bundle_root, root)
    {_public, private} = SystemsRuntime.Proc.generate_key(:ecdh, :secp256r1)

    configure(
      :salix_store,
      :agent_vmm_managed_trust_signing,
      SalixStore.AgentVMMManagedTrustSigning.from_json(%{"private_key" => Base.encode64(private)})
    )

    suffix = SystemsRuntime.Proc.uuid()
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "host-chain-#{suffix}@example.test"})
    {:ok, session} = Comma.Accounts.create_session(user["id"])
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    workspace =
      Comma.Repo.insert!(%Comma.Data.Workspace{
        id: "wsp_#{suffix}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "1",
        salix_router_agent_id: SalixStore.Ids.new_agent_id(group),
        salix_worker_agent_id: SalixStore.Ids.new_agent_id(group),
        billing_owner_id: "billing-#{suffix}",
        name: "Isolated Host",
        status: "active"
      })

    Comma.Repo.insert!(%Comma.Data.WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: "owner",
      status: "active"
    })

    config = %{
      remote_endpoint: "localhost:#{remote_port}",
      internal_listen: "127.0.0.1:#{internal_port}",
      control_url: "http://127.0.0.1:#{control_port}",
      control_secret: secret,
      ca_file: ca,
      cert_file: cert,
      key_file: key,
      image: image,
      archive_path: System.fetch_env!("COMMA_COMPUTE_HOST_ARCHIVE"),
      api_base_url: "http://127.0.0.1:#{control_port}",
      email: user["email"],
      user_id: user["id"],
      session_id: session["id"],
      token: session["token"],
      workspace_id: workspace.id
    }

    File.write!(config_path, Jason.encode!(config))
    File.chmod!(config_path, 0o600)

    gateway =
      launch(
        System.fetch_env!("COMMA_COMPUTE_HOST_GATEWAY"),
        "TestCommaVMMPressureGatewayE2E",
        config_path,
        root,
        "gateway"
      )

    eventually(fn -> File.exists?(config_path <> ".gateway-ready") end, 30_000)

    host =
      launch(
        System.fetch_env!("COMMA_COMPUTE_HOST_BINARY"),
        "TestCueComputeSettingsBridgeE2E",
        config_path,
        root,
        "host"
      )

    eventually(fn -> File.exists?(config_path <> ".host-ready") end, 120_000)
    ready = File.read!(config_path <> ".host-ready") |> Jason.decode!()

    images =
      for class <- ~w(meeting shell station),
          do:
            Map.merge(image, %{
              "class" => class,
              "reference" => "comma.local/runtime/#{class}@#{image["manifestDigest"]}",
              "archiveUrl" => ready["archive_url"]
            })

    File.write!(
      Path.join(root, "manifest.json"),
      Jason.encode!(%{
        "schemaVersion" => 3,
        "sourceRevision" => "isolated-settings-fixture",
        "images" => images
      })
    )

    IO.puts("compute chain fixture: #{config_path}")

    ui =
      SystemsRuntime.Task.async(fn ->
        {output, status} =
          System.cmd(
            "pnpm",
            [
              "exec",
              "playwright",
              "test",
              "--config",
              "playwright.config.ts",
              "--project=electron-shell",
              "apps/electron/e2e/compute-node-host.spec.ts"
            ],
            cd: Path.expand("../../../../clients", __DIR__),
            env: [
              {"COMMA_COMPUTE_HOST_CONFIG", config_path},
              {"COMMA_PLAYWRIGHT_SKIP_WEB_SERVER", "1"},
              {"COMMA_PLAYWRIGHT_OUTPUT_DIR", Path.join(root, "playwright")}
            ],
            stderr_to_stdout: true
          )

        File.write!(Path.join(root, "ui.log"), output)
        assert status == 0, "settings UI failed: #{root}/ui.log"
      end)

    # Only this workspace's two Shells are reconciled; never scan other tenants.
    deadline = SystemsClock.monotonic_time(:millisecond) + 300_000
    drive(config_path, workspace, deadline, MapSet.new())
    settled_await(ui)

    shells =
      Repo.all(
        from(w in Compute.Workload,
          join: e in Compute.Environment,
          on: e.id == w.environment_id,
          where: e.tenant_id == ^tenant and w.kind == "shell",
          limit: 3
        )
      )

    assert length(shells) == 2
    assert Enum.count(shells, &(&1.deletion && &1.deletion["phase"] == "complete")) == 1
    retained = Enum.find(shells, &is_nil(&1.deletion))

    {:ok, credential} = Compute.WorkloadCredential.issue(retained.id, nil, ["runtime"], 900)

    eventually(
      fn ->
        SalixEnv.ComputeReconciler.reconcile_workload(retained.id, retained.generation,
          credential: credential
        )

        match?({:ok, _}, SalixStore.AgentVMM.current_host_session_for_workload(retained.id))
      end,
      30_000
    )

    assert {:ok, %{"content_base64" => content}} =
             AgentVMMHostClient.provider_call(
               :workspace_read,
               %{"path" => "sentinel.txt", "max_bytes" => 1024},
               retained.id
             )

    assert Base.decode64!(content) == retained.id
    File.write!(config_path <> ".stop", "stop")
    settled_await(host)
    settled_await(gateway)
  end

  defp drive(path, workspace, deadline, written) do
    assert SystemsClock.monotonic_time(:millisecond) < deadline,
           "settings chain exceeded five minutes"

    rows =
      Repo.all(
        from(w in Compute.Workload,
          join: e in Compute.Environment,
          on: e.id == w.environment_id,
          where: e.tenant_id == ^workspace.salix_tenant_id and w.kind == "shell",
          limit: 3
        )
      )

    assert length(rows) <= 2

    written =
      Enum.reduce(rows, written, fn w, acc ->
        opts =
          if is_nil(w.deletion) and w.desired_state == "ready" do
            {:ok, credential} = Compute.WorkloadCredential.issue(w.id, nil, ["runtime"], 900)
            [credential: credential]
          else
            []
          end

        waiting_import =
          match?({:ok, _}, SalixStore.AgentVMM.current_host_session_for_workload(w.id)) and
            not File.exists?(path <> ".imported-" <> w.allocation_id)

        unless waiting_import and is_nil(w.deletion),
          do: SalixEnv.ComputeReconciler.reconcile_workload(w.id, w.generation, opts)

        current = Repo.get!(Compute.Workload, w.id)

        if current.observed_state == "ready" and is_nil(current.deletion) and
             not MapSet.member?(acc, w.id) do
          case AgentVMMHostClient.provider_call(
                 :workspace_write,
                 %{
                   "path" => "sentinel.txt",
                   "content_base64" => Base.encode64(w.id),
                   "request_id" => "sentinel-#{MapSet.size(acc)}"
                 },
                 w.id
               ) do
            {:ok, _} ->
              File.write!(path <> ".written-" <> w.id, "written")
              MapSet.put(acc, w.id)

            _ ->
              acc
          end
        else
          acc
        end
      end)

    if File.exists?(path <> ".ui-complete"),
      do: :ok,
      else:
        (
          SystemsClock.sleep(250)
          drive(path, workspace, deadline, written)
        )
  end

  defp configure(app, key, value) do
    previous = SystemsRuntime.fetch_env(app, key)
    SystemsRuntime.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> SystemsRuntime.put_env(app, key, old)
        :error -> SystemsRuntime.delete_env(app, key)
      end
    end)
  end

  defp launch(binary, test, config, root, name) do
    SystemsRuntime.Task.async(fn ->
      output = File.stream!(Path.join(root, name <> ".log"))

      result =
        System.cmd(binary, ["-test.run=^#{test}$", "-test.v", "-test.timeout=16m"],
          env: [{"COMMA_VMM_E2E_CONFIG", config}],
          cd:
            if(name == "host",
              do: System.fetch_env!("COMMA_COMPUTE_HOST_SOURCE") <> "/test/e2e",
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

  # The chain waits on a real Host, Guest, gateway and Electron, so this opt-in
  # fixture runs on the machine clock: a manual clock would skip past their work.
  defp eventually(fun, ms), do: wait(fun, SystemsClock.monotonic_time(:millisecond) + ms)

  defp settled_await(task), do: Task.await(task, :infinity)

  defp wait(fun, deadline) do
    if fun.(),
      do: :ok,
      else:
        (
          assert SystemsClock.monotonic_time(:millisecond) < deadline
          SystemsClock.sleep(100)
          wait(fun, deadline)
        )
  end
end
