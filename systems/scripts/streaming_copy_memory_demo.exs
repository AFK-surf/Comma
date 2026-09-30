# Live streaming-copy validation against MinIO and the real Go Connector.
#
# Run:
#   MIX_ENV=test mix run scripts/streaming_copy_memory_demo.exs
#
# Exits non-zero on failure. The default source payload is 100 MiB: above the
# 16 KiB VFS blob threshold and above S3's 5 MiB multipart part size. Override
# with SALIX_STREAM_COPY_SIZE_MB.

defmodule StreamingCopyMemoryDemo do
  alias Salix.Control.{Groups, Plugins, Tenants}
  alias SalixAgent.{AgentWorkspace, Tools, Workspace}
  alias SalixWeb.EnvDispatch

  @size_mb String.to_integer(System.get_env("SALIX_STREAM_COPY_SIZE_MB", "100"))
  @size @size_mb * 1024 * 1024
  @chunk_size 64 * 1024
  @root "/tmp/salix-stream-copy-#{System.system_time(:second)}"
  @root2 "/tmp/salix-stream-copy-2-#{System.system_time(:second)}"
  @root_peer "/tmp/salix-stream-copy-peer-#{System.system_time(:second)}"
  @peer_http_port System.get_env("SALIX_E2E_PEER_HTTP_PORT")
  @peer_transfer_port System.get_env("SALIX_E2E_PEER_TRANSFER_PORT")

  def run do
    configure_s3_from_env!()
    Application.put_env(:salix_agent, :env_dispatch, SalixWeb.EnvDispatch)
    Application.put_env(:salix_env, :timeout_factor, e2e_perf_factor())
    configure_protocol_timeouts()
    configure_tool_timeouts()

    peer = maybe_start_multinode_peer!()

    File.rm_rf!(@root)
    File.rm_rf!(@root2)
    File.rm_rf!(@root_peer)
    File.mkdir_p!(@root)
    File.mkdir_p!(@root2)
    if multinode_enabled?(), do: File.mkdir_p!(@root_peer)

    tenant_id = create_tenant!()
    Process.put(:streaming_copy_tenant_id, tenant_id)

    {:ok, group} = Groups.create(%{"name" => "Stream Copy"}, tenant_id)
    group_id = group["group_id"]

    {:ok, agent} =
      SalixAgent.Control.create(%{"group_id" => group_id, "name" => "stream-agent"}, tenant_id)

    agent_id = agent["agent_id"]

    port_proc = start_connector(group_id, "go-laptop", @root)
    port_proc2 = start_connector(group_id, "go-laptop-2", @root2)
    peer_port_proc = maybe_start_peer_connector(peer, group_id)

    try do
      envs = wait_for_connected!(group_id, expected_aliases())
      targets = environment_targets_by_alias!(agent_id, expected_aliases())
      py_laptop = Map.fetch!(targets, "go-laptop")
      py_laptop_2 = Map.fetch!(targets, "go-laptop-2")

      for env <- envs do
        IO.puts(
          "connector env_id=#{env["env_id"]} alias=#{env["meta"]["alias"]} node=#{env["node"]}"
        )
      end

      expected_hash = hash_stream(payload_stream())
      write_file_stream!(Path.join(@root, "remote-src.bin"), payload_stream())

      {:ok, src_event} =
        AgentWorkspace.prepare_write_stream(agent_id, "/vfs-src.bin", payload_stream())

      seed_workspace_events!(
        agent_id,
        "stream-demo:source:#{group_id}",
        %{"path" => "/vfs-src.bin", "size" => src_event["size"], "hash" => src_event["hash"]},
        [src_event]
      )

      base_ctx = %{
        tenant_id: tenant_id,
        group_id: group_id,
        agent_id: agent_id,
        session_id: SalixStore.Ids.new_session_id(),
        role: "worker",
        runtime_kind: :external,
        plugin_projection: runtime_plugin_projection!(group_id)
      }

      ctx =
        Map.put(
          base_ctx,
          :tool_disclosure,
          SalixAgent.ToolDisclosure.materialize("worker", :external, base_ctx)
        )

      os_pids = [
        connector_os_pid(port_proc),
        connector_os_pid(port_proc2),
        connector_os_pid(peer_port_proc)
      ]

      {to_remote, remote_samples} =
        measured("vfs_to_connector", os_pids, fn ->
          [result] =
            Tools.execute(
              [
                call("env.copy", %{
                  "src_environment" => "vfs",
                  "src_path" => "/vfs-src.bin",
                  "dst_device_id" => py_laptop.device_id,
                  "dst_environment" => py_laptop.environment_id,
                  "dst_path" => Path.join(@root, "remote-copy.bin")
                })
              ],
              ctx
            )

          result
        end)

      assert_tool!(to_remote)
      assert_file_hash!(Path.join(@root, "remote-copy.bin"), expected_hash)
      print_samples("vfs_to_connector", remote_samples)

      {remote_to_remote_same, remote_to_remote_same_samples} =
        measured("remote_to_remote_same_connector", os_pids, fn ->
          [result] =
            Tools.execute(
              [
                call("env.copy", %{
                  "src_device_id" => py_laptop.device_id,
                  "src_environment" => py_laptop.environment_id,
                  "src_path" => Path.join(@root, "remote-src.bin"),
                  "dst_device_id" => py_laptop.device_id,
                  "dst_environment" => py_laptop.environment_id,
                  "dst_path" => Path.join(@root, "remote-to-remote-copy.bin")
                })
              ],
              ctx
            )

          result
        end)

      assert_tool!(remote_to_remote_same)
      assert_file_hash!(Path.join(@root, "remote-to-remote-copy.bin"), expected_hash)
      print_samples("remote_to_remote_same_connector", remote_to_remote_same_samples)

      {remote_to_remote_different, remote_to_remote_different_samples} =
        measured("remote_to_remote_different_connectors", os_pids, fn ->
          [result] =
            Tools.execute(
              [
                call("env.copy", %{
                  "src_device_id" => py_laptop.device_id,
                  "src_environment" => py_laptop.environment_id,
                  "src_path" => Path.join(@root, "remote-src.bin"),
                  "dst_device_id" => py_laptop_2.device_id,
                  "dst_environment" => py_laptop_2.environment_id,
                  "dst_path" => Path.join(@root2, "remote-to-remote-different-copy.bin")
                })
              ],
              ctx
            )

          result
        end)

      assert_tool!(remote_to_remote_different)
      assert_file_hash!(Path.join(@root2, "remote-to-remote-different-copy.bin"), expected_hash)
      print_samples("remote_to_remote_different_connectors", remote_to_remote_different_samples)

      maybe_run_multinode_remote_checks!(envs, targets, ctx, os_pids, expected_hash)

      {to_vfs, vfs_samples} =
        measured("connector_to_vfs", os_pids, fn ->
          [result] =
            Tools.execute(
              [
                call("env.copy", %{
                  "src_device_id" => py_laptop.device_id,
                  "src_environment" => py_laptop.environment_id,
                  "src_path" => Path.join(@root, "remote-src.bin"),
                  "dst_environment" => "vfs",
                  "dst_path" => "/vfs-copy.bin"
                })
              ],
              ctx
            )

          result
        end)

      assert_tool!(to_vfs)

      seed_workspace_events!(
        agent_id,
        "stream-demo:to-vfs:#{group_id}",
        %{
          "tool_call_id" => to_vfs[:id] || to_vfs["id"],
          "tool_name" => to_vfs[:name] || to_vfs["name"],
          "content" => to_vfs[:content] || to_vfs["content"]
        },
        to_vfs[:events] || to_vfs["events"] || []
      )

      {:ok, copied_stream, copied_size} = Workspace.stream(agent_id, "/vfs-copy.bin")

      true = copied_size == @size
      true = hash_stream(copied_stream) == expected_hash
      print_samples("connector_to_vfs", vfs_samples)

      IO.puts("STREAMING_COPY_MEMORY_DEMO: PASS size=#{@size}")
    after
      stop_connector(port_proc)
      stop_connector(port_proc2)
      stop_connector(peer_port_proc)
      stop_peer(peer)
      File.rm_rf(@root)
      File.rm_rf(@root2)
      if multinode_enabled?(), do: File.rm_rf(@root_peer)
    end
  rescue
    e ->
      IO.puts("STREAMING_COPY_MEMORY_DEMO: FAIL #{Exception.message(e)}")
      System.halt(1)
  end

  defp configure_s3_from_env! do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.AWS)
    put_env(:s3_endpoint, "SALIX_S3_ENDPOINT")
    put_env(:s3_region, "SALIX_S3_REGION")
    put_env(:s3_bucket, "SALIX_S3_BUCKET", "salix-test")
    put_env(:s3_access_key_id, "SALIX_S3_ACCESS_KEY_ID", System.get_env("AWS_ACCESS_KEY_ID"))

    put_env(
      :s3_secret_access_key,
      "SALIX_S3_SECRET_ACCESS_KEY",
      System.get_env("AWS_SECRET_ACCESS_KEY")
    )
  end

  defp put_env(key, name, fallback \\ nil) do
    case System.get_env(name) || fallback do
      value when is_binary(value) and value != "" -> Application.put_env(:salix_store, key, value)
      _ -> :ok
    end
  end

  defp measured(label, os_pids, fun) do
    garbage_collect_all()
    baseline = sample(os_pids)
    started = System.monotonic_time(:millisecond)
    task = Task.async(fun)
    {result, samples} = await_with_samples(task, os_pids, [baseline])
    duration_ms = System.monotonic_time(:millisecond) - started
    IO.puts("#{label}: duration_ms=#{duration_ms}")
    {result, samples}
  end

  defp await_with_samples(task, os_pids, samples) do
    case Task.yield(task, 20) do
      nil ->
        await_with_samples(task, os_pids, [sample(os_pids) | samples])

      {:ok, result} ->
        {result, Enum.reverse([sample(os_pids) | samples])}

      {:exit, reason} ->
        raise "copy task exited: #{inspect(reason)}"
    end
  end

  defp configure_protocol_timeouts do
    factor = e2e_perf_factor()
    stream_timeout_ms = max(90_000, 90_000 * factor)

    overrides =
      :salix_env
      |> Application.get_env(:protocol_timeouts, %{})
      |> normalize_timeout_overrides()

    Application.put_env(
      :salix_env,
      :protocol_timeouts,
      Map.merge(overrides, %{
        "read_stream" => stream_timeout_ms,
        "write_stream" => stream_timeout_ms
      })
    )
  end

  defp normalize_timeout_overrides(overrides) when is_map(overrides), do: overrides
  defp normalize_timeout_overrides(_), do: %{}

  defp configure_tool_timeouts do
    factor = e2e_perf_factor()
    copy_timeout_ms = max(600_000, 600_000 * factor)

    overrides =
      :salix_agent
      |> Application.get_env(:tool_timeouts, %{})
      |> normalize_timeout_overrides()

    Application.put_env(
      :salix_agent,
      :tool_timeouts,
      Map.merge(overrides, %{"env.copy" => copy_timeout_ms})
    )
  end

  defp runtime_plugin_projection!(group_id) do
    case Plugins.runtime_projection(%{
           "tenant_id" => tenant_id!(),
           "group_id" => group_id
         }) do
      {:ok, projection} -> projection
      {:error, reason} -> raise "plugin runtime projection failed: #{inspect(reason)}"
    end
  end

  defp e2e_perf_factor do
    case Integer.parse(System.get_env("E2E_PERF_FACTOR", "1")) do
      {factor, ""} when factor > 0 -> factor
      _ -> 1
    end
  end

  defp sample(os_pids) when is_list(os_pids) do
    %{
      beam: :erlang.memory(:total),
      connector_rss_kb: os_pids |> Enum.map(&rss_kb/1) |> Enum.sum()
    }
  end

  defp print_samples(label, samples) do
    first = hd(samples)
    peak_beam = samples |> Enum.map(& &1.beam) |> Enum.max()
    peak_rss = samples |> Enum.map(& &1.connector_rss_kb) |> Enum.max()

    IO.puts(
      "#{label}: samples=#{length(samples)} " <>
        "beam_baseline=#{first.beam} beam_peak=#{peak_beam} " <>
        "beam_delta=#{peak_beam - first.beam} " <>
        "connector_rss_baseline_kb=#{first.connector_rss_kb} " <>
        "connector_rss_peak_kb=#{peak_rss} " <>
        "connector_rss_delta_kb=#{peak_rss - first.connector_rss_kb}"
    )
  end

  defp rss_kb(nil), do: 0

  defp rss_kb(os_pid) do
    os_pid
    |> process_tree()
    |> Enum.map(&self_rss_kb/1)
    |> Enum.sum()
  end

  defp self_rss_kb(os_pid) do
    case File.read("/proc/#{os_pid}/status") do
      {:ok, status} ->
        case Regex.run(~r/^VmRSS:\s+(\d+)\s+kB/m, status) do
          [_, kb] -> String.to_integer(kb)
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp process_tree(os_pid), do: process_tree([os_pid], MapSet.new())

  defp process_tree([], seen), do: MapSet.to_list(seen)

  defp process_tree([pid | rest], seen) do
    if MapSet.member?(seen, pid) do
      process_tree(rest, seen)
    else
      children = child_pids(pid)
      process_tree(rest ++ children, MapSet.put(seen, pid))
    end
  end

  defp child_pids(parent_pid) do
    "/proc/[0-9]*/status"
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      with {:ok, status} <- File.read(path),
           [_, ppid] <- Regex.run(~r/^PPid:\s+(\d+)$/m, status),
           true <- String.to_integer(ppid) == parent_pid,
           [_, pid] <- Regex.run(~r{/proc/(\d+)/status$}, path) do
        [String.to_integer(pid)]
      else
        _ -> []
      end
    end)
  end

  defp garbage_collect_all do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
    :erlang.garbage_collect()
  end

  defp assert_tool!(%{error: false, content: content}) do
    if guidance_result?(content), do: raise("tool returned guidance: #{content}"), else: :ok
  end

  defp assert_tool!(%{content: content}), do: raise("tool failed: #{content}")

  defp guidance_result?(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"status" => "guidance"}} -> true
      _ -> false
    end
  end

  defp guidance_result?(_), do: false

  defp seed_workspace_events!(_agent_id, _operation_id, _result, []), do: :ok

  defp seed_workspace_events!(agent_id, operation_id, result, events) do
    case AgentWorkspace.seed_operation(agent_id, operation_id, result, events) do
      {:ok, _result} -> :ok
      {:error, reason} -> raise("workspace seed failed: #{inspect(reason)}")
    end
  end

  defp multinode_enabled?, do: present?(@peer_http_port) and present?(@peer_transfer_port)

  defp expected_aliases do
    ["go-laptop", "go-laptop-2"] ++ if(multinode_enabled?(), do: ["go-peer"], else: [])
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp create_tenant! do
    case Tenants.create(%{"name" => "Streaming Copy E2E"}) do
      {:ok, %{"tenant_id" => tenant_id}} -> tenant_id
      {:error, reason} -> raise("tenant create failed: #{inspect(reason)}")
    end
  end

  defp tenant_id! do
    Process.get(:streaming_copy_tenant_id) ||
      raise("streaming copy tenant identity is unavailable")
  end

  defp maybe_run_multinode_remote_checks!(envs, targets, ctx, os_pids, expected_hash) do
    if multinode_enabled?() do
      assert_alias_nodes_differ!(envs, "go-laptop", "go-peer")
      py_laptop = Map.fetch!(targets, "go-laptop")
      py_peer = Map.fetch!(targets, "go-peer")

      {cross_node, cross_node_samples} =
        measured("remote_to_remote_cross_node", os_pids, fn ->
          [result] =
            Tools.execute(
              [
                call("env.copy", %{
                  "src_device_id" => py_laptop.device_id,
                  "src_environment" => py_laptop.environment_id,
                  "src_path" => Path.join(@root, "remote-src.bin"),
                  "dst_device_id" => py_peer.device_id,
                  "dst_environment" => py_peer.environment_id,
                  "dst_path" => Path.join(@root_peer, "remote-cross-node.bin")
                })
              ],
              ctx
            )

          result
        end)

      assert_tool!(cross_node)
      assert_file_hash!(Path.join(@root_peer, "remote-cross-node.bin"), expected_hash)
      print_samples("remote_to_remote_cross_node", cross_node_samples)

      {cross_node_reverse, cross_node_reverse_samples} =
        measured("remote_to_remote_cross_node_reverse", os_pids, fn ->
          [result] =
            Tools.execute(
              [
                call("env.copy", %{
                  "src_device_id" => py_peer.device_id,
                  "src_environment" => py_peer.environment_id,
                  "src_path" => Path.join(@root_peer, "remote-cross-node.bin"),
                  "dst_device_id" => py_laptop.device_id,
                  "dst_environment" => py_laptop.environment_id,
                  "dst_path" => Path.join(@root, "remote-cross-node-back.bin")
                })
              ],
              ctx
            )

          result
        end)

      assert_tool!(cross_node_reverse)
      assert_file_hash!(Path.join(@root, "remote-cross-node-back.bin"), expected_hash)
      print_samples("remote_to_remote_cross_node_reverse", cross_node_reverse_samples)
    end
  end

  defp assert_alias_nodes_differ!(envs, left, right) do
    left_node = node_for_alias!(envs, left)
    right_node = node_for_alias!(envs, right)

    if left_node == right_node do
      raise("#{left} and #{right} connected to same Salix node: #{left_node}")
    end
  end

  defp node_for_alias!(envs, alias_name) do
    env =
      Enum.find(envs, fn env -> (env["meta"] || %{})["alias"] == alias_name end) ||
        raise("missing environment alias #{alias_name}")

    env["node"] || raise("environment #{alias_name} has no node")
  end

  defp assert_file_hash!(path, expected_hash) do
    case File.stat(path) do
      {:ok, %{size: @size}} ->
        actual = path |> File.stream!(@chunk_size, []) |> hash_stream()
        if actual == expected_hash, do: :ok, else: raise("file hash mismatch: #{path}")

      {:ok, stat} ->
        raise("file size mismatch: #{path} size=#{stat.size}")

      {:error, reason} ->
        raise("file read failed: #{path}: #{inspect(reason)}")
    end
  end

  defp write_file_stream!(path, stream) do
    {:ok, :ok} =
      File.open(path, [:write, :binary], fn file ->
        Enum.each(stream, &IO.binwrite(file, &1))
        :ok
      end)
  end

  defp payload_stream do
    base =
      :crypto.hash(:sha256, "salix-streaming-copy-memory")
      |> :binary.copy(div(@chunk_size, 32))

    Stream.unfold(0, fn offset ->
      remaining = @size - offset

      cond do
        remaining <= 0 -> nil
        remaining >= byte_size(base) -> {base, offset + byte_size(base)}
        true -> {binary_part(base, 0, remaining), @size}
      end
    end)
  end

  defp hash_stream(stream) do
    stream
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, ctx ->
      :crypto.hash_update(ctx, IO.iodata_to_binary(chunk))
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp maybe_start_multinode_peer! do
    if multinode_enabled?() do
      _ = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
      :ok = ensure_distribution!()
      {:ok, peer, node} = start_peer!()
      http_port = configure_peer!(node)
      %{peer: peer, node: node, http_port: http_port}
    end
  end

  defp ensure_distribution! do
    if Node.alive?() do
      :ok
    else
      name = :"salix_e2e_main_#{System.unique_integer([:positive])}@127.0.0.1"

      case :net_kernel.start([name, :longnames]) do
        {:ok, _} ->
          :erlang.set_cookie(Node.self(), :salix_e2e_cookie)
          :ok

        {:error, reason} ->
          raise("could not start BEAM distribution for e2e: #{inspect(reason)}")
      end
    end
  end

  defp start_peer! do
    [_, host] = String.split(to_string(Node.self()), "@")
    name = :"salix_e2e_peer_#{System.unique_integer([:positive])}"
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

  defp configure_peer!(node) do
    :erpc.call(node, :code, :add_pathsz, [:code.get_path()])

    for {key, value} <- peer_s3_config() do
      :ok = :erpc.call(node, Application, :put_env, [:salix_store, key, value])
    end

    :ok = :erpc.call(node, Application, :put_env, [:salix_store, :snowflake_worker_id, 1])

    :ok =
      :erpc.call(node, Application, :put_env, [
        :salix_store,
        SalixStore.Repo,
        Application.fetch_env!(:salix_store, SalixStore.Repo)
      ])

    :ok = :erpc.call(node, Application, :put_env, [:salix_store, :start_repo, true])

    :ok =
      :erpc.call(node, Application, :put_env, [
        :salix_web,
        :port,
        String.to_integer(@peer_http_port)
      ])

    :ok =
      :erpc.call(node, Application, :put_env, [
        :salix_web,
        :site_rate_limit_redis_url,
        Application.fetch_env!(:salix_web, :site_rate_limit_redis_url)
      ])

    :ok =
      :erpc.call(node, Application, :put_env, [
        :salix_env,
        :transfer_port,
        String.to_integer(@peer_transfer_port)
      ])

    :ok = :erpc.call(node, Application, :put_env, [:salix_env, :advertise_host, "127.0.0.1"])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:salix_web])
    :erpc.call(node, SalixWeb.Application, :http_port, [])
  end

  defp peer_s3_config do
    [
      s3_endpoint: System.get_env("SALIX_S3_ENDPOINT") || "http://127.0.0.1:19000",
      s3_region: System.get_env("SALIX_S3_REGION") || "us-east-1",
      s3_bucket: System.get_env("SALIX_S3_BUCKET") || "salix-test",
      s3_access_key_id: System.get_env("AWS_ACCESS_KEY_ID") || "minioadmin",
      s3_secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY") || "minioadmin",
      s3_backend: SalixStore.S3.AWS
    ]
  end

  defp maybe_start_peer_connector(nil, _group_id), do: nil

  defp maybe_start_peer_connector(%{http_port: http_port}, group_id) do
    start_connector(group_id, "go-peer", @root_peer, http_port)
  end

  defp stop_peer(nil), do: :ok

  defp stop_peer(%{peer: peer}) do
    try do
      :peer.stop(peer)
    catch
      _, _ -> :ok
    end
  end

  defp start_connector(group_id, name, root, http_port \\ nil) do
    binary = Path.join(@root, "salix-connect-amd64")

    unless File.exists?(binary) do
      source = Path.join([File.cwd!(), "connector", "salix-connect"])

      {output, code} =
        System.cmd("go", ["build", "-o", binary, "."], cd: source, stderr_to_stdout: true)

      if code != 0, do: raise("Go Connector build failed: #{output}")
    end

    http_port = http_port || SalixWeb.Application.http_port()
    ws_url = "ws://127.0.0.1:#{http_port}"
    token = group_connector_token!(group_id, name)

    Port.open({:spawn_executable, binary}, [
      :binary,
      :exit_status,
      args: [
        "--server",
        ws_url,
        "--name",
        name,
        "--root",
        root,
        "--state-root",
        root,
        "--connector-token",
        token
      ]
    ])
  end

  defp group_connector_token!(group_id, alias_name) do
    case SalixEnv.ConnectorTokens.create_group_connector_token(group_id, tenant_id!(), %{
           "name" => alias_name,
           "alias" => alias_name,
           "expires_in_seconds" => 3600
         }) do
      {:ok, %{"token" => token}} -> token
      {:error, reason} -> raise("connector token create failed: #{inspect(reason)}")
    end
  end

  defp connector_os_pid(nil), do: nil

  defp connector_os_pid(port_proc) do
    case Port.info(port_proc, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _ -> nil
    end
  end

  defp stop_connector(nil), do: :ok

  defp stop_connector(port_proc) do
    case Port.info(port_proc, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", [Integer.to_string(os_pid)])
      _ -> :ok
    end
  end

  defp environment_targets_by_alias!(agent_id, aliases) do
    Map.new(aliases, fn alias_name ->
      {alias_name, environment_target_by_alias!(agent_id, alias_name)}
    end)
  end

  defp environment_target_by_alias!(agent_id, alias_name) do
    case EnvDispatch.list_envs(agent_id) do
      {:ok, envs} ->
        case Enum.find(envs, &(&1["alias"] == alias_name)) do
          %{"device_id" => device_id, "environment_id" => environment_id}
          when is_binary(device_id) and device_id != "" and
                 is_binary(environment_id) and environment_id != "" ->
            %{device_id: device_id, environment_id: environment_id}

          _ ->
            raise(
              "missing device-scoped environment target for alias #{alias_name}: #{inspect(envs)}"
            )
        end

      {:error, reason} ->
        raise("env list failed for alias #{alias_name}: #{inspect(reason)}")
    end
  end

  defp wait_for_connected!(group_id, aliases, attempts \\ 100) do
    case SalixEnv.Registry.list_connected_by_group(group_id) do
      {:ok, envs} ->
        found =
          envs
          |> Enum.filter(fn env -> (env["meta"] || %{})["alias"] in aliases end)
          |> Enum.sort_by(fn env -> (env["meta"] || %{})["alias"] end)

        if length(found) == length(aliases) do
          found
        else
          retry_wait_for_connected!(group_id, aliases, attempts)
        end

      _ when attempts > 0 ->
        retry_wait_for_connected!(group_id, aliases, attempts)

      _ ->
        raise "connector never registered within timeout"
    end
  end

  defp retry_wait_for_connected!(group_id, aliases, attempts) when attempts > 0 do
    Process.sleep(100)
    wait_for_connected!(group_id, aliases, attempts - 1)
  end

  defp retry_wait_for_connected!(_group_id, _aliases, _attempts) do
    raise "connector never registered within timeout"
  end

  defp call(name, args),
    do: %{"id" => "c-#{System.unique_integer([:positive])}", "name" => name, "args" => args}
end

StreamingCopyMemoryDemo.run()
