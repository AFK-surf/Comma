defmodule BridgeForTeams.EnvironmentConnectorE2ETest do
  @moduledoc """
  Full device connector path a real end user takes, end to end, on a single
  node running both subsystems:

    1. **Create** — through BridgeForTeams' *public* contexts only: an org, a
       project, and an agent. Draining the reconcile outbox provisions the
       Salix-side tenant / group / agent via `:erpc` (BridgeForTeams holds the
       privileged erpc access; the user never sees admin/tenant tokens).
    2. **Connect** — BFT records a project device request, the org runner
       claims it, receives a real Salix connector credential once, and the
       in-repo Go `salix-connect` attaches to local Salix `/v1/connect` using
       only that credential.
    3. **Use** — a command is executed through the connected device connector and its
       output verified (validation, via the salix env dispatch the agent runtime
       uses).

  Heavy (real connector subprocess + salix HTTP + MinIO) and excluded by
  default; run with `mix test --include connector_e2e`. Requires Go, a running
  MinIO, and salix on real S3 (the test-env default).
  """
  use BridgeForTeams.DataCase, async: false

  @moduletag :connector_e2e

  alias BridgeForTeams.{Agents, Environments, Orgs, Projects}

  @root "/tmp/bft-connector-e2e-#{System.system_time(:second)}"
  @transport_perf_payload_bytes 8 * 1024 * 1024
  @transport_perf_parallel_reads 4
  @transport_perf_small_requests 64
  @transport_perf_concurrency 12
  @transport_perf_max_small_p95_ms 750.0
  @transport_perf_min_small_requests_per_second 25.0
  @transport_perf_min_bulk_mib_per_second 8.0

  setup do
    # The real path: drive Salix over erpc, not the in-memory Fake.
    prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, BridgeForTeams.Salix.Erpc)

    File.mkdir_p!(@root)

    on_exit(fn ->
      if prev_client do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev_client)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end

      File.rm_rf(@root)
    end)

    :ok
  end

  test "create → connect → use a project device connector via public APIs + salix-connect" do
    unless System.find_executable("go"), do: flunk("go not available")

    # 1. Public BridgeForTeams creation; reconcile provisions the Salix side.
    {:ok, org} = Orgs.create_org(%{"name" => "Acme", "slug" => "acme-#{uniq()}"})

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Lab", "slug" => "lab-#{uniq()}"})

    {:ok, agent} =
      Agents.create_agent(project.id, %{"role" => "worker", "name" => "laptop-agent"})

    # Provision the Salix tenant/group/agent over erpc (drain the outbox).
    :ok = drain_all()

    {:ok, provisioner} =
      Environments.register_mac_mini_provisioner(org.id, %{
        "stable_id" => "runner-#{uniq()}",
        "name" => "Lab Runner",
        "capacity" => 1
      })

    {:ok, request} =
      Environments.create_device_provision_request(project.id, %{
        "provisioner_id" => provisioner.id,
        "name" => "laptop",
        "alias" => "laptop"
      })

    # 2. The runner claims the request and receives the Salix connector
    #    credential. BFT persists only the token hash; salix-connect uses the raw
    #    token as its group-scoped connector credential.
    {:ok, %{action: "create", request: claimed, connect: connect}} =
      Environments.claim_device_provision_request(org.id, provisioner.id, %{
        "available_capacity" => 1
      })

    assert claimed.id == request.id
    assert claimed.status == "preflight"

    token = connect["token"]
    assert is_binary(token) and token != ""
    assert connect["env"]["SALIX_CONNECTOR_TOKEN"] == token
    assert is_binary(connect["env"]["SALIX_SERVER"]) and connect["env"]["SALIX_SERVER"] != ""

    port = SalixWeb.Application.http_port()
    proc = start_connector(port, token)

    try do
      # Connected: the env is registered under the project's group, and its
      # socket owner is live on this node (the durable record can land just
      # ahead of the socket-owner registration).
      env = wait_for_connected!(project.salix_group_id, proc)
      assert env["status"] == "connected"
      assert is_binary(env["device_id"]) and env["device_id"] != ""
      assert is_binary(env["connector_id"]) and env["connector_id"] != ""
      connector_run_id = env["connector_run_id"]

      assert eventually(fn -> SalixEnv.Bridge.local?(connector_run_id) end),
             "connector socket owner never registered"

      # The connector reports host facts in its metadata frame; Salix persists
      # them into the connector record along with the last-update time.
      assert eventually(fn ->
               match?(
                 {:ok, _transport_id, %{"meta" => %{"system_info" => %{"hostname" => _}}}},
                 SalixEnv.Registry.get_by_connector_run_id(connector_run_id)
               )
             end),
             "connector system info never landed in the record"

      {:ok, _transport_id, record} =
        SalixEnv.Registry.get_by_connector_run_id(connector_run_id)

      info = record["meta"]["system_info"]
      assert info["os_type"] == "Linux" or is_binary(info["os_type"])
      first_update = record["meta"]["system_info_updated_at"]
      assert is_integer(first_update)

      # The connector refreshes on a 1s timer (--system-info-interval 1); the
      # persisted update time advances without any reconnect.
      assert eventually(fn ->
               case SalixEnv.Registry.get_by_connector_run_id(connector_run_id) do
                 {:ok, _transport_id, %{"meta" => %{"system_info_updated_at" => ts}}} ->
                   ts > first_update

                 _ ->
                   false
               end
             end),
             "connector never re-reported system info"

      {:ok, %{"environment_id" => environment_id}} =
        SalixEnv.Control.get_environment(
          env["device_id"],
          project.salix_group_id,
          org.salix_tenant_id
        )

      # 3. Use it: run a command through the connector and verify the output.
      assert {:ok, %{"exit_code" => 0, "stdout" => out}} =
               SalixWeb.EnvDispatch.exec(
                 agent.salix_agent_id,
                 %{device_id: env["device_id"], environment_id: environment_id},
                 "echo bridge-e2e-ok && uname -s",
                 %{}
               )

      assert out =~ "bridge-e2e-ok"

      # Relative paths are resolved inside the connector root.
      assert {:ok, _} =
               SalixWeb.EnvDispatch.request(
                 agent.salix_agent_id,
                 %{device_id: env["device_id"], environment_id: environment_id},
                 "write",
                 %{
                   "path" => "hello.txt",
                   "content" => "from-bridge\n"
                 }
               )

      assert {:ok, %{"content" => "from-bridge\n"}} =
               SalixWeb.EnvDispatch.request(
                 agent.salix_agent_id,
                 %{device_id: env["device_id"], environment_id: environment_id},
                 "read",
                 %{
                   "path" => "hello.txt"
                 }
               )
    after
      stop_connector(proc)
    end
  end

  test "accepted exec survives a real WebSocket replacement and executes once" do
    unless System.find_executable("go"), do: flunk("go not available")

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Recovery #{uniq()}"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Recovery"}, tenant["tenant_id"])

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "recovery-agent"},
        tenant["tenant_id"]
      )

    {:ok, token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(
        group["group_id"],
        tenant["tenant_id"],
        %{"name" => "recovery-laptop", "alias" => "recovery-laptop"}
      )

    proc = start_connector(SalixWeb.Application.http_port(), token["token"])

    try do
      env = wait_for_connected!(group["group_id"], proc)
      old_run_id = env["connector_run_id"]

      {:ok, %{"environment_id" => environment_id}} =
        SalixEnv.Control.get_environment(
          env["device_id"],
          group["group_id"],
          tenant["tenant_id"]
        )

      assert eventually(fn -> SalixEnv.Bridge.local?(old_run_id) end),
             "connector socket owner never registered"

      assert eventually(fn ->
               match?(
                 {:ok, %{"processes" => _}},
                 SalixWeb.EnvDispatch.process_list(agent["agent_id"], %{
                   device_id: env["device_id"],
                   environment_id: environment_id
                 })
               )
             end),
             "connector environment never became dispatchable"

      # A transport replacement is invisible to an already accepted ordinary
      # RPC. The request id is replayed onto the replacement socket, while the
      # connector actor owns the execution and therefore performs its side
      # effect exactly once.
      started = Path.join(@root, "seamless-started")
      executions = Path.join(@root, "seamless-executions")

      command =
        "printf 'started\\n' >> #{shell_quote(executions)}; " <>
          "touch #{shell_quote(started)}; sleep 1; echo seamless-recovered"

      exec =
        Task.async(fn ->
          SalixWeb.EnvDispatch.exec(
            agent["agent_id"],
            %{device_id: env["device_id"], environment_id: environment_id},
            command,
            %{}
          )
        end)

      assert eventually(fn -> File.exists?(started) end),
             "exec never started before disconnect"

      :ok = SalixEnv.Bridge.stop_local_owner(old_run_id)

      assert {:ok, %{"exit_code" => 0, "stdout" => recovered_out}} =
               Task.await(exec, 15_000)

      assert recovered_out =~ "seamless-recovered"
      assert File.read!(executions) == "started\n"

      assert eventually(fn ->
               case SalixEnv.Registry.get_device(
                      tenant["tenant_id"],
                      group["group_id"],
                      env["device_id"]
                    ) do
                 {:ok, %{"status" => "connected", "connector_run_id" => new_run_id}} ->
                   new_run_id != old_run_id

                 _ ->
                   false
               end
             end),
             "connector did not register a replacement run"
    after
      stop_connector(proc)
    end
  end

  test "an accepted operation is not replayed into a replacement connector process" do
    unless System.find_executable("go"), do: flunk("go not available")

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Restart #{uniq()}"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Restart"}, tenant["tenant_id"])

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "restart-agent"},
        tenant["tenant_id"]
      )

    {:ok, token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(
        group["group_id"],
        tenant["tenant_id"],
        %{"name" => "restart-laptop", "alias" => "restart-laptop"}
      )

    old_connector = start_connector(SalixWeb.Application.http_port(), token["token"])

    try do
      old_env = wait_for_connected!(group["group_id"], old_connector)
      old_run_id = old_env["connector_run_id"]
      old_process_instance_id = old_env["process_instance_id"]

      assert is_binary(old_process_instance_id) and old_process_instance_id != ""

      {:ok, %{"environment_id" => environment_id}} =
        SalixEnv.Control.get_environment(
          old_env["device_id"],
          group["group_id"],
          tenant["tenant_id"]
        )

      assert eventually(fn -> SalixEnv.Bridge.local?(old_run_id) end),
             "old connector socket owner never registered"

      assert eventually(fn ->
               match?(
                 {:ok, %{"processes" => _}},
                 SalixWeb.EnvDispatch.process_list(agent["agent_id"], %{
                   device_id: old_env["device_id"],
                   environment_id: environment_id
                 })
               )
             end),
             "old connector environment never became dispatchable"

      started = Path.join(@root, "restart-started")
      executions = Path.join(@root, "restart-executions")

      command =
        "printf 'started\\n' >> #{shell_quote(executions)}; " <>
          "touch #{shell_quote(started)}; sleep 2; echo process-restart-recovered"

      exec =
        Task.async(fn ->
          SalixWeb.EnvDispatch.exec(
            agent["agent_id"],
            %{device_id: old_env["device_id"], environment_id: environment_id},
            command,
            %{}
          )
        end)

      assert eventually(fn -> File.exists?(started) end),
             "old connector never produced the first side effect"

      assert File.read!(executions) == "started\n"
      stop_connector_and_wait!(old_connector)

      replacement = start_connector(SalixWeb.Application.http_port(), token["token"])

      try do
        replacement_env = wait_for_connected!(group["group_id"], replacement)

        assert replacement_env["device_id"] == old_env["device_id"]
        assert replacement_env["connector_run_id"] != old_run_id
        assert replacement_env["process_instance_id"] != old_process_instance_id

        # Process replacement is outside the in-memory recovery contract. The
        # caller sees a disconnect, and the accepted side effect stays unique.
        result = Task.await(exec, 15_000)
        assert {result, File.read!(executions)} == {{:error, :disconnected}, "started\n"}
      after
        stop_connector(replacement)
      end
    after
      stop_connector(old_connector)
    end
  end

  test "real WebSocket transport stays within mixed-workload performance budgets" do
    unless System.find_executable("go"), do: flunk("go not available")

    connection = start_direct_connector!("Performance")

    try do
      payload =
        :binary.copy(
          "0123456789abcdef",
          div(@transport_perf_payload_bytes, byte_size("0123456789abcdef"))
        )

      payload_hash = :crypto.hash(:sha256, payload)
      path = "transport-performance.bin"
      File.write!(Path.join(@root, path), payload)

      # Prove the public resolution path once, then keep control-plane S3 reads
      # out of the transport benchmark. Every measured request still traverses
      # Connector.Live, the bridge, the WebSocket, and the real Go connector.
      assert {:ok, %{"size" => @transport_perf_payload_bytes}} =
               SalixWeb.EnvDispatch.request(
                 connection.agent_id,
                 %{device_id: connection.device_id, environment_id: connection.environment_id},
                 "stat",
                 %{"path" => path}
               )

      # Warm connector operation binding, JSON framing, and the WebSocket writer.
      for _ <- 1..4 do
        assert {:ok, %{"size" => @transport_perf_payload_bytes}} =
                 SalixEnv.Connector.Live.request(
                   connection.connector_run_id,
                   "stat",
                   %{"path" => path}
                 )
      end

      workload =
        List.duplicate(:bulk_read, @transport_perf_parallel_reads) ++
          List.duplicate(:small_stat, @transport_perf_small_requests)

      started_at = System.monotonic_time(:microsecond)

      results =
        workload
        |> Task.async_stream(
          fn kind ->
            request_started_at = System.monotonic_time(:microsecond)

            result =
              case kind do
                :bulk_read ->
                  SalixEnv.Connector.Live.request(
                    connection.connector_run_id,
                    "read",
                    %{"path" => path}
                  )

                :small_stat ->
                  SalixEnv.Connector.Live.request(
                    connection.connector_run_id,
                    "stat",
                    %{"path" => path}
                  )
              end

            {kind, System.monotonic_time(:microsecond) - request_started_at, result}
          end,
          max_concurrency: @transport_perf_concurrency,
          ordered: false,
          timeout: 30_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, reason} -> flunk("transport performance request exited: #{inspect(reason)}")
        end)

      elapsed_us = System.monotonic_time(:microsecond) - started_at

      small_latencies_us =
        for {:small_stat, latency_us,
             {:ok, %{"size" => @transport_perf_payload_bytes, "kind" => "file"}}} <- results,
            do: latency_us

      invalid_small_results =
        Enum.reject(results, fn
          {:bulk_read, _latency_us, _result} ->
            true

          {:small_stat, _latency_us,
           {:ok, %{"size" => @transport_perf_payload_bytes, "kind" => "file"}}} ->
            true

          _other ->
            false
        end)

      bulk_results =
        for {:bulk_read, _latency_us,
             {:ok,
              %{
                "content" => content,
                "size" => @transport_perf_payload_bytes,
                "truncated" => false
              }}} <- results,
            do: {byte_size(content), :crypto.hash(:sha256, content)}

      assert length(small_latencies_us) == @transport_perf_small_requests,
             "one or more small transport RPCs failed: #{inspect(invalid_small_results)}"

      assert length(bulk_results) == @transport_perf_parallel_reads,
             "one or more bulk reads failed: #{inspect(results, limit: 5)}"

      assert Enum.all?(bulk_results, fn
               {@transport_perf_payload_bytes, ^payload_hash} -> true
               _ -> false
             end)

      elapsed_seconds = max(elapsed_us / 1_000_000, 0.000_001)
      small_p95_ms = percentile(small_latencies_us, 0.95) / 1_000
      small_requests_per_second = @transport_perf_small_requests / elapsed_seconds

      bulk_mib_per_second =
        @transport_perf_parallel_reads * @transport_perf_payload_bytes / 1024 / 1024 /
          elapsed_seconds

      IO.puts(
        "connector_transport_perf " <>
          "small_p95_ms=#{Float.round(small_p95_ms, 2)} " <>
          "small_rps=#{Float.round(small_requests_per_second, 2)} " <>
          "bulk_mib_s=#{Float.round(bulk_mib_per_second, 2)}"
      )

      assert small_p95_ms <= @transport_perf_max_small_p95_ms

      assert small_requests_per_second >= @transport_perf_min_small_requests_per_second

      assert bulk_mib_per_second >= @transport_perf_min_bulk_mib_per_second

      # Preserve concurrent correctness coverage for the public EnvDispatch
      # path without folding its control-plane reads into transport latency.
      public_results =
        workload
        |> Task.async_stream(
          fn kind ->
            result =
              case kind do
                :bulk_read ->
                  SalixWeb.EnvDispatch.request(
                    connection.agent_id,
                    %{device_id: connection.device_id, environment_id: connection.environment_id},
                    "read",
                    %{"path" => path}
                  )

                :small_stat ->
                  SalixWeb.EnvDispatch.request(
                    connection.agent_id,
                    %{device_id: connection.device_id, environment_id: connection.environment_id},
                    "stat",
                    %{"path" => path}
                  )
              end

            {kind, result}
          end,
          max_concurrency: @transport_perf_concurrency,
          ordered: false,
          timeout: 30_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, reason} -> flunk("public EnvDispatch request exited: #{inspect(reason)}")
        end)

      public_small_results =
        for {:small_stat, {:ok, %{"size" => @transport_perf_payload_bytes, "kind" => "file"}}} <-
              public_results,
            do: :ok

      public_invalid_results =
        Enum.reject(public_results, fn
          {:bulk_read,
           {:ok,
            %{
              "content" => content,
              "size" => @transport_perf_payload_bytes,
              "truncated" => false
            }}}
          when byte_size(content) == @transport_perf_payload_bytes ->
            true

          {:small_stat, {:ok, %{"size" => @transport_perf_payload_bytes, "kind" => "file"}}} ->
            true

          _other ->
            false
        end)

      public_bulk_results =
        for {:bulk_read,
             {:ok,
              %{
                "content" => content,
                "size" => @transport_perf_payload_bytes,
                "truncated" => false
              }}} <- public_results,
            do: {byte_size(content), :crypto.hash(:sha256, content)}

      assert length(public_small_results) == @transport_perf_small_requests,
             "one or more public stat requests failed: #{inspect(public_invalid_results)}"

      assert length(public_bulk_results) == @transport_perf_parallel_reads,
             "one or more public reads failed: #{inspect(public_invalid_results)}"

      assert Enum.all?(public_bulk_results, fn
               {@transport_perf_payload_bytes, ^payload_hash} -> true
               _ -> false
             end)
    after
      stop_connector(connection.proc)
    end
  end

  # ---- helpers ----

  defp uniq, do: System.unique_integer([:positive])

  defp drain_all do
    case BridgeForTeams.Salix.Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp start_direct_connector!(label) do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "#{label} #{uniq()}"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => label}, tenant["tenant_id"])

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "#{String.downcase(label)}-agent"},
        tenant["tenant_id"]
      )

    {:ok, token} =
      SalixEnv.ConnectorTokens.create_group_connector_token(
        group["group_id"],
        tenant["tenant_id"],
        %{
          "name" => "#{String.downcase(label)}-laptop",
          "alias" => "#{String.downcase(label)}-laptop"
        }
      )

    proc = start_connector(SalixWeb.Application.http_port(), token["token"])
    env = wait_for_connected!(group["group_id"], proc)

    assert eventually(fn -> SalixEnv.Bridge.local?(env["connector_run_id"]) end),
           "connector socket owner never registered"

    {:ok, %{"environment_id" => environment_id}} =
      SalixEnv.Control.get_environment(
        env["device_id"],
        group["group_id"],
        tenant["tenant_id"]
      )

    assert eventually(fn ->
             match?(
               {:ok, %{"processes" => _}},
               SalixWeb.EnvDispatch.process_list(agent["agent_id"], %{
                 device_id: env["device_id"],
                 environment_id: environment_id
               })
             )
           end),
           "connector environment never became dispatchable"

    %{
      proc: proc,
      device_id: env["device_id"],
      agent_id: agent["agent_id"],
      environment_id: environment_id,
      connector_run_id: env["connector_run_id"]
    }
  end

  defp start_connector(port, token) do
    connector_dir =
      [["connector", "salix-connect"], ["..", "..", "connector", "salix-connect"]]
      |> Enum.map(&Path.expand(Path.join([File.cwd!() | &1])))
      |> Enum.find(&File.dir?/1) ||
        flunk("could not locate connector/salix-connect from #{File.cwd!()}")

    executable = connector_executable!(connector_dir)

    Port.open({:spawn_executable, executable}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      cd: connector_dir,
      args: [
        "--server",
        "http://127.0.0.1:#{port}",
        "--connector-token",
        token,
        "--name",
        "laptop",
        "--alias",
        "laptop",
        "--root",
        @root,
        "--exec-runner",
        "direct",
        "--direct-file-ops",
        "unprotected",
        "--system-info-interval",
        "1"
      ]
    ])
  end

  defp connector_executable!(connector_dir) do
    executable = Path.join(@root, "salix-connect-e2e")

    unless File.exists?(executable) do
      {output, status} =
        System.cmd(System.find_executable("go"), ["build", "-o", executable, "."],
          cd: connector_dir,
          stderr_to_stdout: true
        )

      if status != 0, do: flunk("could not build connector: #{output}")
    end

    executable
  end

  defp stop_connector_and_wait!(proc) do
    stop_connector(proc)

    receive do
      {^proc, {:exit_status, _status}} -> :ok
    after
      5_000 -> flunk("connector process did not exit")
    end
  end

  defp stop_connector(proc) do
    case Port.info(proc, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", [Integer.to_string(os_pid)])
      _ -> :ok
    end
  end

  defp wait_for_connected!(group_id, proc, attempts \\ 900, output \\ []) do
    {exited?, exit_status, output} = drain_connector_messages(proc, output)

    case SalixEnv.Registry.list_connected_by_group(group_id) do
      {:ok, [env | _]} ->
        env

      _ when exited? ->
        flunk(connector_failure("connector exited before registering", exit_status, output))

      _ when attempts > 0 ->
        Process.sleep(100) && wait_for_connected!(group_id, proc, attempts - 1, output)

      _ ->
        flunk(connector_failure("connector never registered within timeout", nil, output))
    end
  end

  defp drain_connector_messages(proc, output) do
    receive do
      {^proc, {:data, data}} ->
        drain_connector_messages(proc, [data | output])

      {^proc, {:exit_status, status}} ->
        {true, status, output}
    after
      0 ->
        {false, nil, output}
    end
  end

  defp connector_failure(message, status, output) do
    tail =
      output
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> String.slice(-4_000, 4_000)

    status_text =
      if is_integer(status), do: " exit_status=#{status}", else: ""

    message <> status_text <> "\n\nconnector output tail:\n" <> tail
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp percentile(values, percentile) do
    values
    |> Enum.sort()
    |> Enum.at(max(ceil(length(values) * percentile) - 1, 0))
  end

  defp eventually(fun, retries \\ 300) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, retries - 1)
    end
  end
end
