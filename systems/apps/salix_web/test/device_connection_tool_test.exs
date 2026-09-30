defmodule SalixWeb.DeviceConnectionToolTest do
  use ExUnit.Case, async: false

  setup_all do
    binary =
      Path.join(System.tmp_dir!(), "comma-install-go-#{System.unique_integer([:positive])}")

    source = Path.expand("../../../connector/salix-connect", __DIR__)

    {output, status} =
      System.cmd("go", ["build", "-o", binary, "."], cd: source, stderr_to_stdout: true)

    assert status == 0, output
    on_exit(fn -> File.rm(binary) end)
    %{go_binary: binary}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Connector installation test"})

    {:ok, group} =
      Salix.Control.Groups.create(%{"name" => "Installation group"}, tenant["tenant_id"])

    router =
      SalixAgent.TestSupport.create_legacy_control_agent_in_group!(
        tenant["tenant_id"],
        group["group_id"],
        %{"role" => "router"}
      )

    root = Path.join(System.tmp_dir!(), "comma-install-#{System.unique_integer([:positive])}")
    home = Path.join(root, "target-home")
    File.mkdir_p!(home)
    old_base = Application.get_env(:salix_web, :public_base_url)
    old_artifacts = Application.get_env(:salix_env, :device_install_local_artifact_root)
    old_dispatch = Application.get_env(:salix_agent, :env_dispatch)
    Application.put_env(:salix_agent, :env_dispatch, Salix.Bindings.AgentEnvDispatch)

    Application.put_env(
      :salix_env,
      :device_install_local_artifact_root,
      Path.join(root, "downloads")
    )

    listener = start_supervised!({Bandit, plug: SalixWeb.Router, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(listener)
    Application.put_env(:salix_web, :public_base_url, "http://127.0.0.1:#{port}")

    for platform <- ~w(darwin-arm64 darwin-amd64 linux-arm64 linux-amd64) do
      directory = Path.join([root, "downloads", platform])
      File.mkdir_p!(directory)

      File.write!(Path.join(directory, "salix-connect"), """
      #!/bin/sh
      printf '%s\\n' "$$" > "$HOME/fixture.pid"
      printf '%s' "#{platform}" > "$HOME/platform"
      printf '%s' "$SALIX_CONNECTOR_TOKEN" > "$HOME/token"
      printf '%s\\n' "$@" > "$HOME/args"
      exec sleep 60
      """)
    end

    on_exit(fn ->
      for {app, key, value} <- [
            {:salix_web, :public_base_url, old_base},
            {:salix_env, :device_install_local_artifact_root, old_artifacts},
            {:salix_agent, :env_dispatch, old_dispatch}
          ] do
        if value, do: Application.put_env(app, key, value), else: Application.delete_env(app, key)
      end

      case File.read(Path.join(home, "fixture.pid")) do
        {:ok, pid} -> System.cmd("kill", ["-TERM", String.trim(pid)])
        _ -> :ok
      end

      {processes, 0} = System.cmd("ps", ["-ax", "-o", "pid=,command="])

      for line <- String.split(processes, "\n"),
          String.contains?(line, home <> "/.comma/devices/") or
            String.contains?(line, home <> "/.local/share/salix/go/"),
          [pid, _] <- [String.split(String.trim(line), ~r/\s+/, parts: 2)] do
        System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)
      end

      File.rm_rf!(root)
      SalixAgent.TestSupport.stop_all_agents()
    end)

    %{
      router: router,
      tenant: tenant["tenant_id"],
      group: group["group_id"],
      root: root,
      home: home
    }
  end

  test "missing device remains an actionable lookup error through tool dispatch", ctx do
    result = invoke(ctx.router, %{"device_id" => "dev_missing"}, "device.get")
    assert result.error
    assert result.error_class == "device_not_found"
    issue = Jason.decode!(result.content)
    assert issue["device_id"] == "dev_missing"
    assert issue["message"] =~ "device.list"
    refute issue["message"] =~ "no environment connected"
  end

  test "installation downloads Connector, starts read-only, and writes its diagnostic file",
       ctx do
    name = "Target ' $(touch unwanted)"
    result = invoke(ctx.router, %{"name" => name})
    refute result.error, result.content
    install = Jason.decode!(result.content)
    state = Path.join(ctx.home, ".comma/devices/#{install["device_id"]}")
    File.mkdir_p!(state)
    File.write!(Path.join(state, "connector.pid"), System.pid())

    assert {_, 0} =
             run_install(install["command"], ctx.home)

    assert eventually(fn -> File.exists?(Path.join(ctx.home, "token")) end),
           File.read!(Path.join(state, "connector.log"))

    assert {:ok, tenant, credential} =
             SalixEnv.ConnectorTokens.validate_connector_token(
               File.read!(Path.join(ctx.home, "token"))
             )

    assert tenant == ctx.tenant
    assert credential["group_id"] == ctx.group
    assert credential["device_id"] == install["device_id"]
    assert is_nil(credential["expires_at"])
    refute credential["scope"] == "local_file_read"
    args = File.read!(Path.join(ctx.home, "args"))
    assert args =~ "--device\n--scope\nlocal_file_read"
    assert args =~ name
    refute File.exists?(Path.join(ctx.home, "unwanted"))

    assert File.read!(Path.join(state, install["verification_path"])) ==
             install["verification_content"] <> "\n"

    assert File.exists?(Path.join(state, "salix-connect"))
    assert {:ok, %{records: [_]}} = SalixEnv.Registry.page_by_group(ctx.group, limit: 20)
  end

  test "real Go installation without Python survives terminal exit, preserves identity and rejects Shell",
       ctx do
    for platform <- ~w(darwin-arm64 darwin-amd64 linux-arm64 linux-amd64) do
      File.cp!(ctx.go_binary, Path.join([ctx.root, "downloads", platform, "salix-connect"]))
    end

    bin = Path.join(ctx.root, "target-bin")
    File.mkdir_p!(bin)

    File.write!(
      Path.join(bin, "python3"),
      "#!/bin/sh\necho 'python3 is unavailable' >&2\nexit 127\n"
    )

    File.chmod!(Path.join(bin, "python3"), 0o700)
    target_env = [{"PATH", bin <> ":/usr/bin:/bin"}]

    install = invoke(ctx.router, %{"name" => "Real read-only device"}).content |> Jason.decode!()
    assert {_, 0} = run_install(install["command"], ctx.home, "yes", target_env)
    state = Path.join(ctx.home, ".comma/devices/#{install["device_id"]}")

    assert eventually(fn ->
             case SalixEnv.Control.get_environment(install["device_id"], ctx.group, ctx.tenant) do
               {:ok, %{"status" => "connected"}} -> true
               _ -> false
             end
           end),
           File.read!(Path.join(state, "connector.log"))

    {:ok, device} = SalixEnv.Control.get_environment(install["device_id"], ctx.group, ctx.tenant)
    target = %{device_id: install["device_id"], environment_id: device["environment_id"]}

    assert {:ok, %{"content" => "COMMA_CONNECTOR_READ_OK\n"}} =
             SalixWeb.EnvDispatch.request(ctx.router["agent_id"], target, "read", %{
               "path" => install["verification_path"]
             })

    assert {:error, {:permission_required, _}} =
             SalixWeb.EnvDispatch.exec(
               ctx.router["agent_id"],
               target,
               "touch should-not-exist",
               %{}
             )

    refute File.exists?(Path.join(state, "should-not-exist"))
    assert {_, 0} = run_install(install["command"], ctx.home, "yes", target_env)
    assert {:ok, %{records: [only]}} = SalixEnv.Registry.page_by_group(ctx.group, limit: 20)
    assert only["device_id"] == install["device_id"]

    assert {:ok, %{"content" => "COMMA_CONNECTOR_READ_OK\n"}} =
             SalixWeb.EnvDispatch.request(ctx.router["agent_id"], target, "read", %{
               "path" => install["verification_path"]
             })
  end

  test "rejected connection cannot complete first registration", ctx do
    {:ok, credential} =
      SalixEnv.DeviceInstall.create_token_command(ctx.tenant, ctx.group, %{
        "name" => "Rejected install"
      })

    server = Application.fetch_env!(:salix_web, :public_base_url)

    assert {:ok, %{status: 400}} =
             Req.get(server <> "/v1/connect?scope=invalid",
               headers: [{"authorization", "Bearer " <> credential["token"]}]
             )

    {:ok, _, record} = SalixEnv.ConnectorTokens.validate_connector_token(credential["token"])
    key = SalixStore.Keys.ctl_connector_token(record["token_hash"])

    {:ok, _} =
      SalixStore.S3.put(
        key,
        Jason.encode!(Map.put(record, "registration_expires_at", System.system_time(:second) - 1))
      )

    assert {:error, :unauthorized} =
             SalixEnv.ConnectorTokens.validate_connector_token(credential["token"])
  end

  test "unavailable artifacts do not create a device and Workers cannot install", ctx do
    File.rm_rf!(Path.join(ctx.root, "downloads"))
    result = invoke(ctx.router, %{"name" => "Target"})
    assert result.error
    assert Jason.decode!(result.content)["code"] == "connector_release_unavailable"
    assert {:ok, %{records: []}} = SalixEnv.Registry.page_by_group(ctx.group, limit: 20)

    worker =
      SalixAgent.TestSupport.create_legacy_control_agent_in_group!(ctx.tenant, ctx.group, %{
        "role" => "worker"
      })

    assert {:error, :forbidden} =
             SalixWeb.EnvDispatch.create_device_install(worker["agent_id"], "Target")
  end

  test "failed download does not start a partial installation", ctx do
    install = invoke(ctx.router, %{"name" => "Target"}).content |> Jason.decode!()
    File.rm_rf!(Path.join(ctx.root, "downloads"))

    assert {_, status} =
             run_install(install["command"], ctx.home)

    assert status != 0
    refute File.exists?(Path.join(ctx.home, "fixture.pid"))
    assert Path.wildcard(Path.join(ctx.home, ".comma/devices/*/.download.*")) == []
  end

  for {platform, os, arch} <- [
        {"darwin-arm64", "Darwin", "arm64"},
        {"darwin-amd64", "Darwin", "x86_64"},
        {"linux-arm64", "Linux", "aarch64"},
        {"linux-amd64", "Linux", "x86_64"}
      ] do
    @tag platform: platform, os: os, arch: arch
    test "installer selects #{platform} artifact", ctx do
      bin = Path.join(ctx.root, "bin")
      File.mkdir_p!(bin)

      File.write!(
        Path.join(bin, "uname"),
        "#!/bin/sh\ncase \"$1\" in -s) echo #{ctx.os};; -m) echo #{ctx.arch};; esac\n"
      )

      File.chmod!(Path.join(bin, "uname"), 0o700)
      install = invoke(ctx.router, %{"name" => "Platform device"}).content |> Jason.decode!()

      assert {_, 0} =
               run_install(install["command"], ctx.home, "yes", [
                 {"PATH", bin <> ":" <> System.get_env("PATH")}
               ])

      assert eventually(fn -> File.exists?(Path.join(ctx.home, "platform")) end)
      assert File.read!(Path.join(ctx.home, "platform")) == ctx.platform
    end
  end

  test "declining local consent leaves the target uninstalled", ctx do
    install = invoke(ctx.router, %{"name" => "Target"}).content |> Jason.decode!()
    assert {output, 1} = run_install(install["command"], ctx.home, "no")
    assert output =~ "Installation canceled"
    refute File.exists?(Path.join(ctx.home, ".comma"))
    refute File.exists?(Path.join(ctx.home, "token"))
  end

  defp run_install(command, home, consent \\ "yes", env \\ []) do
    System.cmd(
      System.find_executable("python3"),
      [Path.join(__DIR__, "support/device_install_terminal.py"), command, consent],
      env: [{"HOME", home}] ++ env,
      stderr_to_stdout: true
    )
  end

  defp eventually(fun, attempts \\ 500)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  defp invoke(agent, args, name \\ "device.create_connector_install_command") do
    ctx =
      %{
        agent_id: agent["agent_id"],
        session_id: agent["router_session_id"],
        role: agent["role"],
        runtime_kind: :internal
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    ctx =
      Map.put(
        ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize(agent["role"], :internal, ctx)
      )

    [result] =
      SalixAgent.Tools.execute(
        [%{"id" => "installation-test", "name" => name, "args" => args}],
        ctx
      )

    result
  end
end
