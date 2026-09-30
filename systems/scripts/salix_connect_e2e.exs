# End-to-end validation for the Go salix-connect binary.
#
# Run through Deno:
#   deno test --allow-all e2e/tests/salix_connect_test.ts

defmodule SalixConnectE2E do
  alias Salix.Control.{Groups, Tenants}
  alias SalixWeb.EnvDispatch

  @chunk_size 64 * 1024
  @stream_size 3 * 1024 * 1024 + 123
  @local_file_token String.duplicate("A", 43)
  @local_file_ref "lfi1_" <> @local_file_token
  @local_file_payload "managed local attachment over the real connector transport\n"
  @local_file_message_id "msg_salix_connect_e2e_local_file"

  def run do
    bin = required_env!("SALIX_CONNECT_BIN")

    configure_s3_from_env!()
    Application.put_env(:salix_agent, :env_dispatch, SalixWeb.EnvDispatch)

    root = tmp_dir!("salix-connect-remote-") |> realpath!()
    local_file_index = tmp_dir!("salix-connect-local-file-index-") |> realpath!()
    owner_user_id = "user_salix_connect_e2e"
    prepare_local_file_index!(local_file_index, owner_user_id)
    tenant_id = create_tenant!()
    tenant_api_key = create_tenant_api_key!(tenant_id)

    {:ok, group} = Groups.create(%{"name" => "Go Connect E2E"}, tenant_id)
    group_id = group["group_id"]

    {:ok, agent} =
      SalixAgent.Control.create(%{"group_id" => group_id, "name" => "go-connect-e2e"}, tenant_id)

    agent_id = agent["agent_id"]

    try do
      token = mint_connector_token!(group_id, tenant_api_key, owner_user_id)
      remote_port = start_remote_connector!(bin, token, root, local_file_index)

      try do
        remote_environment_id = wait_for_alias!(agent_id, "go-remote")
        assert_system_info!(group_id, "go-remote")
        assert_system_info_advances!(group_id, "go-remote")
        exercise_env!(agent_id, remote_environment_id, "go-remote", root)
        exercise_local_file_ref!(group_id, "go-remote", local_file_index)
        IO.puts("SALIX_CONNECT_READ_REF_E2E: PASS")

        IO.puts("SALIX_CONNECT_E2E: PASS")
      after
        if is_port(remote_port), do: Port.close(remote_port)
      end
    after
      File.rm_rf(root)
      File.rm_rf(local_file_index)
    end
  end

  defp create_tenant! do
    case Tenants.create(%{"name" => "Salix Connect E2E"}) do
      {:ok, %{"tenant_id" => tenant_id}} -> tenant_id
      {:error, reason} -> raise("tenant create failed: #{inspect(reason)}")
    end
  end

  defp configure_s3_from_env! do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.AWS)
    put_env(:s3_endpoint, "SALIX_S3_ENDPOINT")
    put_env(:s3_region, "SALIX_S3_REGION")
    put_env(:s3_bucket, "SALIX_S3_BUCKET")
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

  defp create_tenant_api_key!(tenant_id) do
    case Tenants.create_api_key(tenant_id, %{"name" => "salix-connect-e2e"}) do
      {:ok, %{"key" => key}} -> key
      {:error, reason} -> raise("tenant api key create failed: #{inspect(reason)}")
    end
  end

  defp mint_connector_token!(group_id, tenant_api_key, owner_user_id) do
    url =
      SalixWeb.Application.base_url() <>
        "/v1/runtime/agent-groups/#{group_id}/connector-tokens"

    resp =
      Req.post!(url,
        headers: [{"authorization", "Bearer " <> tenant_api_key}],
        json: %{
          "name" => "Go Remote",
          "alias" => "go-remote",
          "expires_in_seconds" => 3600,
          "meta" => %{"owner_user_id" => owner_user_id}
        },
        retry: false
      )

    unless resp.status == 201 do
      raise("connector token mint failed: #{resp.status} #{inspect(resp.body)}")
    end

    resp.body["token"] || raise("connector token response did not include token")
  end

  defp start_remote_connector!(bin, token, root, local_file_index) do
    server = SalixWeb.Application.base_url()

    args = [
      "--server",
      server,
      "--connector-token",
      token,
      "--name",
      "Go Remote",
      "--alias",
      "go-remote",
      "--root",
      root,
      "--local-file-index",
      local_file_index,
      "--reconnect=false",
      "--system-info-interval",
      "1"
    ]

    Port.open({:spawn_executable, bin}, [
      :binary,
      :exit_status,
      {:args, args},
      {:env, [{~c"SALIX_API_TOKEN", false}, {~c"SALIX_CONNECTOR_TOKEN", false}]}
    ])
  end

  defp exercise_env!(agent_id, environment_id, label, root) do
    dir = Path.join(root, "docs")
    hello = Path.join(dir, "hello.txt")
    stream_path = Path.join(dir, "stream.bin")

    assert_ok!(
      EnvDispatch.exec(agent_id, environment_id, "printf remote-exec", %{"working_dir" => "/"}),
      fn result ->
        result["exit_code"] == 0 and result["stdout"] == "remote-exec"
      end,
      "#{label} exec"
    )

    assert_ok!(
      EnvDispatch.request(agent_id, environment_id, "write", %{
        "path" => hello,
        "content" => "needle one\nsecond\n"
      }),
      fn result -> result["size"] == byte_size("needle one\nsecond\n") end,
      "#{label} write"
    )

    assert_ok!(
      EnvDispatch.request(agent_id, environment_id, "read", %{"path" => hello}),
      fn result ->
        result["content"] == "needle one\nsecond\n" and result["truncated"] == false
      end,
      "#{label} read"
    )

    assert_ok!(
      EnvDispatch.request(agent_id, environment_id, "stat", %{"path" => hello}),
      fn result ->
        result["kind"] == "file" and result["size"] == byte_size("needle one\nsecond\n")
      end,
      "#{label} stat"
    )

    assert_ok!(
      EnvDispatch.request(agent_id, environment_id, "list", %{"path" => dir}),
      fn result ->
        Enum.any?(result["entries"], &(&1["name"] == "hello.txt" and &1["kind"] == "file"))
      end,
      "#{label} list"
    )

    assert_ok!(
      EnvDispatch.request(agent_id, environment_id, "glob", %{"path" => dir, "pattern" => "*.txt"}),
      fn result -> "/docs/hello.txt" in result["matches"] end,
      "#{label} glob"
    )

    assert_ok!(
      EnvDispatch.request(agent_id, environment_id, "grep", %{
        "path" => dir,
        "glob" => "*.txt",
        "pattern" => "needle"
      }),
      fn result ->
        Enum.any?(result["matches"], &(&1["path"] == "/docs/hello.txt" and &1["line"] == 1))
      end,
      "#{label} grep"
    )

    stream_hash = hash_stream(payload_stream())

    case EnvDispatch.write_stream(agent_id, environment_id, stream_path, payload_stream()) do
      {:ok, _} -> :ok
      {:error, reason} -> raise("#{label} write_stream failed: #{inspect(reason)}")
    end

    assert_file_hash!(stream_path, stream_hash)

    copied_hash =
      case EnvDispatch.read_stream(agent_id, environment_id, stream_path) do
        {:ok, stream, _size} -> hash_stream(stream)
        {:error, reason} -> raise("#{label} read_stream failed: #{inspect(reason)}")
      end

    unless copied_hash == stream_hash do
      raise("#{label} read_stream hash mismatch")
    end

    assert_ok!(
      EnvDispatch.request(agent_id, environment_id, "delete", %{"path" => hello}),
      fn result -> result["deleted"] == true end,
      "#{label} delete"
    )

    case EnvDispatch.request(agent_id, environment_id, "stat", %{"path" => hello}) do
      {:error, _} -> :ok
      other -> raise("#{label} stat after delete unexpectedly succeeded: #{inspect(other)}")
    end
  end

  # Exercise the transport/VFS boundary through SalixEnv.Connector.Live ->
  # Bridge -> the real WebSocket -> the built Go connector. This deliberately
  # seeds the strict managed index and dispatches read_ref directly; native
  # snapshot creation, canonical message binding, and final VFS publication
  # are covered by their owning integration tests. The wire request carries
  # only an opaque ref and the exact identity tuple; no host path crosses it.
  defp exercise_local_file_ref!(group_id, alias, local_file_index) do
    record = wait_for_local_file_connector!(group_id, alias)

    params = %{
      "canonical_message_id" => @local_file_message_id,
      "connection_generation" => record["connection_generation"],
      "connector_run_id" => record["connector_run_id"],
      "expected_max_bytes" => byte_size(@local_file_payload),
      "local_file_ref" => @local_file_ref,
      "owner_user_id" => get_in(record, ["meta", "owner_user_id"]),
      "stream_lease_ms" => 60_000,
      "stable_device_id" => record["device_id"]
    }

    bytes = read_ref_bytes!(params)

    unless bytes == @local_file_payload and sha256(bytes) == sha256(@local_file_payload) do
      raise("read_ref bytes or terminal integrity mismatch")
    end

    assert_read_ref_rejected!(
      Map.put(params, "owner_user_id", "user_foreign"),
      "foreign owner"
    )

    assert_read_ref_rejected!(
      Map.put(params, "stable_device_id", "dev_foreign"),
      "foreign device"
    )

    assert_read_ref_rejected!(
      Map.put(params, "connector_run_id", "run_stale"),
      "wrong run",
      params["connector_run_id"]
    )

    assert_read_ref_rejected!(
      Map.update!(params, "connection_generation", &(&1 + 1)),
      "wrong generation"
    )

    assert_read_ref_rejected!(
      Map.put(params, "local_file_ref", "lfi1_" <> String.duplicate("B", 43)),
      "unknown opaque ref"
    )

    # The connector hashes the immutable snapshot before the first data frame
    # and emits terminal EOF only after the delivered size/hash match. A
    # post-registration object mutation must therefore fail the stream rather
    # than expose bytes as a successful attachment.
    object = Path.join([local_file_index, "objects", @local_file_token])
    File.write!(object, @local_file_payload <> "corrupt")
    File.chmod!(object, 0o600)
    assert_read_ref_rejected!(params, "corrupt snapshot")
  end

  defp read_ref_bytes!(params) do
    request = SalixEnv.Protocol.request("read_ref", params)

    case SalixEnv.Connector.Live.read_stream(params["connector_run_id"], request, 10_000) do
      {:ok, stream, _reported_size} -> stream |> Enum.to_list() |> IO.iodata_to_binary()
      {:error, reason} -> raise("read_ref dispatch failed: #{inspect(reason)}")
    end
  end

  defp assert_read_ref_rejected!(params, label, route_run_id \\ nil) do
    request = SalixEnv.Protocol.request("read_ref", params)
    route_run_id = route_run_id || params["connector_run_id"]

    case SalixEnv.Connector.Live.read_stream(route_run_id, request, 10_000) do
      {:error, _reason} ->
        :ok

      {:ok, stream, _reported_size} ->
        counter = {__MODULE__, make_ref()}
        Process.put(counter, 0)

        try do
          Enum.each(stream, fn chunk ->
            emitted = chunk |> IO.iodata_to_binary() |> byte_size()
            Process.put(counter, Process.get(counter, 0) + emitted)
          end)

          raise("#{label} read_ref unexpectedly succeeded")
        rescue
          error in RuntimeError ->
            cond do
              not String.starts_with?(error.message, "connector stream failed:") ->
                reraise(error, __STACKTRACE__)

              Process.get(counter, 0) != 0 ->
                raise("#{label} read_ref emitted bytes before rejection")

              true ->
                :ok
            end
        after
          Process.delete(counter)
        end
    end
  end

  defp prepare_local_file_index!(root, owner_user_id) do
    entries = Path.join(root, "entries")
    objects = Path.join(root, "objects")
    File.mkdir_p!(entries)
    File.mkdir_p!(objects)
    Enum.each([root, entries, objects], &File.chmod!(&1, 0o700))

    object = Path.join(objects, @local_file_token)
    File.write!(object, @local_file_payload)
    File.chmod!(object, 0o600)

    entry = %{
      "created_at_ms" => System.system_time(:millisecond),
      "display_name" => "managed.txt",
      "local_file_ref" => @local_file_ref,
      "media_type" => "text/plain",
      "object_id" => @local_file_token,
      "owner_user_id" => owner_user_id,
      "sha256" => sha256(@local_file_payload),
      "size" => byte_size(@local_file_payload),
      "state" => "registered",
      "version" => 2
    }

    entry_path = Path.join(entries, @local_file_token <> ".json")
    File.write!(entry_path, Jason.encode!(entry))
    File.chmod!(entry_path, 0o600)
  end

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # The Go connector reports host facts in its metadata frame; Salix persists
  # them (plus the update time) into the connector record's meta.
  defp assert_system_info!(group_id, alias, attempts \\ 200) do
    meta = system_info_meta(group_id, alias) || %{}
    info = meta["system_info"]

    cond do
      is_map(info) and is_binary(info["hostname"]) and info["hostname"] != "" ->
        unless is_integer(meta["system_info_updated_at"]) do
          raise("#{alias} system_info_updated_at missing: #{inspect(meta)}")
        end

        :ok

      attempts > 0 ->
        Process.sleep(50)
        assert_system_info!(group_id, alias, attempts - 1)

      true ->
        raise("#{alias} never reported system_info")
    end
  end

  # The connector refreshes on its --system-info-interval timer (1s here); the
  # persisted update time advances without any reconnect.
  defp assert_system_info_advances!(group_id, alias, attempts \\ 200) do
    first = (system_info_meta(group_id, alias) || %{})["system_info_updated_at"]

    advanced? = fn ->
      case system_info_meta(group_id, alias) do
        %{"system_info_updated_at" => ts} when is_integer(ts) -> ts > first
        _ -> false
      end
    end

    if wait_until(advanced?, attempts) do
      :ok
    else
      raise("#{alias} never re-reported system_info")
    end
  end

  defp system_info_meta(group_id, alias) do
    case SalixEnv.Registry.list_connected_by_group(group_id) do
      {:ok, records} ->
        case Enum.find(records, &(get_in(&1, ["meta", "alias"]) == alias)) do
          %{"meta" => meta} -> meta
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp wait_for_local_file_connector!(group_id, alias, attempts \\ 200) do
    case SalixEnv.Registry.list_connected_by_group(group_id) do
      {:ok, records} ->
        case Enum.find(records, &(get_in(&1, ["meta", "alias"]) == alias)) do
          %{
            "connector_run_id" => run_id,
            "connection_generation" => generation,
            "device_id" => device_id,
            "meta" => %{
              "owner_user_id" => owner_user_id,
              "capabilities" => %{
                "local_file_import_v1" => true,
                "local_file_index_version" => 2
              }
            }
          } = record
          when is_binary(run_id) and run_id != "" and is_integer(generation) and
                 generation > 0 and is_binary(device_id) and device_id != "" and
                 is_binary(owner_user_id) and owner_user_id != "" ->
            record

          _ when attempts > 0 ->
            Process.sleep(50)
            wait_for_local_file_connector!(group_id, alias, attempts - 1)

          other ->
            raise("#{alias} local-file capability never became ready: #{inspect(other)}")
        end

      {:error, _reason} when attempts > 0 ->
        Process.sleep(50)
        wait_for_local_file_connector!(group_id, alias, attempts - 1)

      {:error, reason} ->
        raise("#{alias} local-file connector lookup failed: #{inspect(reason)}")
    end
  end

  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_for_alias!(agent_id, alias, attempts \\ 200) do
    case EnvDispatch.list_envs(agent_id) do
      {:ok, envs} ->
        case Enum.find(envs, &(&1["alias"] == alias)) do
          %{"device_id" => device_id, "environment_id" => environment_id}
          when is_binary(environment_id) and environment_id != "" ->
            %{device_id: device_id, environment_id: environment_id}

          _ ->
            retry_alias!(agent_id, alias, attempts, envs)
        end

      {:error, reason} ->
        retry_alias!(agent_id, alias, attempts, reason)
    end
  end

  defp retry_alias!(_agent_id, alias, 0, last),
    do: raise("timed out waiting for #{alias}: #{inspect(last)}")

  defp retry_alias!(agent_id, alias, attempts, _last) do
    Process.sleep(50)
    wait_for_alias!(agent_id, alias, attempts - 1)
  end

  defp assert_ok!({:ok, result}, predicate, label) do
    if predicate.(result), do: :ok, else: raise("#{label} unexpected result: #{inspect(result)}")
  end

  defp assert_ok!({:error, reason}, _predicate, label),
    do: raise("#{label} failed: #{inspect(reason)}")

  defp payload_stream do
    base =
      :crypto.hash(:sha256, "salix-connect-e2e")
      |> :binary.copy(div(@chunk_size, 32))

    Stream.unfold(0, fn offset ->
      remaining = @stream_size - offset

      cond do
        remaining <= 0 -> nil
        remaining >= byte_size(base) -> {base, offset + byte_size(base)}
        true -> {binary_part(base, 0, remaining), @stream_size}
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

  defp assert_file_hash!(path, expected_hash) do
    actual = path |> File.stream!(@chunk_size, []) |> hash_stream()
    if actual == expected_hash, do: :ok, else: raise("file hash mismatch: #{path}")
  end

  defp tmp_dir!(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        prefix <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp realpath!(path) do
    case System.cmd("pwd", ["-P"], cd: path, stderr_to_stdout: true) do
      {realpath, 0} -> String.trim(realpath)
      {output, code} -> raise("failed to resolve #{path}: #{String.trim(output)} code=#{code}")
    end
  end

  defp required_env!(name), do: System.get_env(name) || raise("#{name} is required")
end

try do
  SalixConnectE2E.run()
catch
  kind, reason ->
    IO.puts(:stderr, Exception.format(kind, reason, __STACKTRACE__))
    System.halt(1)
end
