defmodule SalixAgent.Colab.TunnelTransferTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixAgent.AgentWorkspace
  alias SalixAgent.Colab.{Leases, Transfer, Tunnels}
  alias SalixAgent.SubscriptionStore, as: Store
  alias SalixStore.Ids

  # ---- Minimal OTP :ssh.daemon server key & exec channel ----

  defmodule DaemonKeys do
    @behaviour :ssh_server_key_api

    @impl true
    def host_key(algorithm, options) when algorithm in [:"ssh-ed25519"] do
      name = options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:name)
      {:ok, SystemsRuntime.PersistentTerm.get({__MODULE__, name, :host_key})}
    end

    def host_key(_, _), do: {:error, :no_host_key}

    @impl true
    def is_auth_key(key, ~c"root", options) do
      name = options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:name)

      case SystemsRuntime.PersistentTerm.get({__MODULE__, name, :authorized_pubkey}, nil) do
        nil -> true
        allowed -> key == allowed
      end
    end

    def is_auth_key(_, _, _), do: false
  end

  defmodule ExecShell do
    @behaviour :ssh_server_channel

    @impl true
    def init(_args), do: {:ok, %{command: nil, stdin: []}}

    @impl true
    def handle_msg(_msg, state), do: {:ok, state}

    @impl true
    def handle_ssh_msg({:ssh_cm, conn, {:exec, channel, want, cmd}}, state) do
      :ssh_connection.reply_request(conn, want, :success, channel)
      cmd_str = List.to_string(cmd)

      cond do
        String.contains?(cmd_str, "__hang__") ->
          {:ok, %{state | command: :hang}}

        String.contains?(cmd_str, "__partial_fail__") ->
          :ssh_connection.send(conn, channel, 0, "PARTIAL_BYTES_BEFORE_FAIL_")
          :ssh_connection.send(conn, channel, 1, "boom stderr\n")
          :ssh_connection.exit_status(conn, channel, 1)
          :ssh_connection.send_eof(conn, channel)
          {:stop, channel, state}

        true ->
          {:ok, %{state | command: cmd_str, stdin: []}}
      end
    end

    def handle_ssh_msg({:ssh_cm, _conn, {:data, _channel, 0, data}}, state) do
      {:ok, %{state | stdin: [state.stdin, data]}}
    end

    def handle_ssh_msg({:ssh_cm, conn, {:eof, channel}}, %{command: cmd} = state)
        when is_binary(cmd) do
      stdin_bin = IO.iodata_to_binary(state.stdin)

      tmp_in =
        Path.join(
          System.tmp_dir!(),
          "colab-test-in-#{SystemsRuntime.Proc.unique_integer([:positive])}"
        )

      tmp_err =
        Path.join(
          System.tmp_dir!(),
          "colab-test-err-#{SystemsRuntime.Proc.unique_integer([:positive])}"
        )

      File.write!(tmp_in, stdin_bin)

      try do
        wrapped = "{ #{cmd}; } < '#{tmp_in}' 2>'#{tmp_err}'"
        {stdout, status} = System.cmd("/bin/sh", ["-c", wrapped])
        stderr = File.read!(tmp_err)

        if stdout != "", do: :ssh_connection.send(conn, channel, 0, stdout)
        if stderr != "", do: :ssh_connection.send(conn, channel, 1, stderr)
        :ssh_connection.exit_status(conn, channel, status)
        :ssh_connection.send_eof(conn, channel)
      after
        File.rm(tmp_in)
        File.rm(tmp_err)
      end

      {:stop, channel, state}
    end

    def handle_ssh_msg({:ssh_cm, _conn, {:closed, channel}}, state), do: {:stop, channel, state}
    def handle_ssh_msg(_msg, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  # ---- Minimal RFC 6455 loopback WebSocket proxy -> local SSH daemon ----

  defmodule FakeWsProxy do
    @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    def start(ssh_port, daemon_name, opts \\ []) do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listen)
      status_override = Keyword.get(opts, :http_status)
      send_ping? = Keyword.get(opts, :send_ping, false)
      test_pid = Keyword.get(opts, :test_pid)

      pid =
        spawn(fn ->
          accept_loop(listen, ssh_port, daemon_name, status_override, send_ping?, test_pid)
        end)

      %{port: port, listen: listen, pid: pid}
    end

    def stop(%{listen: listen, pid: pid}) do
      :gen_tcp.close(listen)
      Process.exit(pid, :kill)
      :ok
    end

    defp accept_loop(listen, ssh_port, daemon_name, status_override, send_ping?, test_pid) do
      case :gen_tcp.accept(listen) do
        {:ok, sock} ->
          client_pid =
            spawn(fn ->
              receive do
                :socket_ready ->
                  handle_client(
                    sock,
                    ssh_port,
                    daemon_name,
                    status_override,
                    send_ping?,
                    test_pid
                  )
              end
            end)

          :ok = :gen_tcp.controlling_process(sock, client_pid)
          send(client_pid, :socket_ready)

          accept_loop(listen, ssh_port, daemon_name, status_override, send_ping?, test_pid)

        {:error, _} ->
          :ok
      end
    end

    defp handle_client(sock, ssh_port, daemon_name, status_override, send_ping?, test_pid) do
      {:ok, req} = read_http_request(sock, "")
      [request_line | header_lines] = String.split(req, "\r\n", trim: true)
      ["GET", path, _ver] = String.split(request_line, " ", parts: 3)

      headers =
        Map.new(header_lines, fn line ->
          [k, v] = String.split(line, ":", parts: 2)
          {String.downcase(String.trim(k)), String.trim(v)}
        end)

      if test_pid, do: send(test_pid, {:ws_upgrade_seen, path, headers})

      if status_override do
        :gen_tcp.send(
          sock,
          "HTTP/1.1 #{status_override} Too Many Requests\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )

        :gen_tcp.close(sock)
      else
        # Authorize the ephemeral pubkey sent in x-colab-ssh-pubkey
        if pub_line = headers["x-colab-ssh-pubkey"] do
          case :ssh_file.decode(pub_line, :public_key) do
            [{pubkey, _} | _] ->
              SystemsRuntime.PersistentTerm.put(
                {DaemonKeys, daemon_name, :authorized_pubkey},
                pubkey
              )

            _ ->
              case :ssh_file.decode(pub_line, :openssh_key) do
                [{pubkey, _} | _] ->
                  SystemsRuntime.PersistentTerm.put(
                    {DaemonKeys, daemon_name, :authorized_pubkey},
                    pubkey
                  )

                _ ->
                  :ok
              end
          end
        end

        ws_key = Map.fetch!(headers, "sec-websocket-key")
        accept = :crypto.hash(:sha, ws_key <> @ws_guid) |> Base.encode64()

        :gen_tcp.send(
          sock,
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
        )

        {:ok, ssh_sock} =
          :gen_tcp.connect({127, 0, 0, 1}, ssh_port, [:binary, active: true], 5_000)

        :ok = :inet.setopts(sock, active: true)

        if send_ping? do
          :gen_tcp.send(sock, encode_server_frame(0x9, "hi"))
        end

        bridge_loop(sock, ssh_sock, <<>>, test_pid)
      end
    end

    defp read_http_request(sock, acc) do
      if String.contains?(acc, "\r\n\r\n") do
        {:ok, acc}
      else
        case :gen_tcp.recv(sock, 0, 5_000) do
          {:ok, chunk} -> read_http_request(sock, acc <> chunk)
          error -> error
        end
      end
    end

    defp bridge_loop(ws_sock, ssh_sock, buf, test_pid) do
      receive do
        {:tcp, ^ssh_sock, data} ->
          :gen_tcp.send(ws_sock, encode_server_frame(0x2, data))
          bridge_loop(ws_sock, ssh_sock, buf, test_pid)

        {:tcp, ^ws_sock, data} ->
          {frames, rest} = decode_client_frames(buf <> data, [])

          Enum.each(frames, fn
            {:binary, payload} -> :gen_tcp.send(ssh_sock, payload)
            {:ping, payload} -> :gen_tcp.send(ws_sock, encode_server_frame(0xA, payload))
            {:pong, payload} -> if test_pid, do: send(test_pid, {:ws_pong_seen, payload})
            {:close, _} -> :gen_tcp.close(ssh_sock)
            _ -> :ok
          end)

          bridge_loop(ws_sock, ssh_sock, rest, test_pid)

        {:tcp_closed, _} ->
          :gen_tcp.close(ws_sock)
          :gen_tcp.close(ssh_sock)

        {:tcp_error, _, _} ->
          :gen_tcp.close(ws_sock)
          :gen_tcp.close(ssh_sock)
      end
    end

    defp encode_server_frame(opcode, payload) do
      len = byte_size(payload)
      first = Bitwise.bor(0x80, opcode)

      cond do
        len < 126 -> <<first, len, payload::binary>>
        len < 65_536 -> <<first, 126, len::16, payload::binary>>
        true -> <<first, 127, len::64, payload::binary>>
      end
    end

    defp decode_client_frames(
           <<_fin::1, _rsv::3, opcode::4, 1::1, len7::7, rest::binary>> = bin,
           acc
         ) do
      case parse_len(len7, rest) do
        {:ok, len, after_len} when byte_size(after_len) >= 4 + len ->
          <<mask::binary-size(4), masked::binary-size(^len), tail::binary>> = after_len
          payload = unmask(masked, mask)

          frame =
            case opcode do
              0x2 -> {:binary, payload}
              0x8 -> {:close, payload}
              0x9 -> {:ping, payload}
              0xA -> {:pong, payload}
              _ -> {:other, payload}
            end

          decode_client_frames(tail, [frame | acc])

        _ ->
          {Enum.reverse(acc), bin}
      end
    end

    defp decode_client_frames(bin, acc), do: {Enum.reverse(acc), bin}

    defp parse_len(126, <<len::16, rest::binary>>), do: {:ok, len, rest}
    defp parse_len(127, <<len::64, rest::binary>>), do: {:ok, len, rest}
    defp parse_len(len, rest) when len < 126, do: {:ok, len, rest}
    defp parse_len(_, _), do: :more

    defp unmask(data, <<m0, m1, m2, m3>>) do
      mask = {m0, m1, m2, m3}

      for <<b <- data>>, reduce: {<<>>, 0} do
        {out, i} ->
          m = elem(mask, rem(i, 4))
          {<<out::binary, Bitwise.bxor(b, m)>>, i + 1}
      end
      |> elem(0)
    end
  end

  # ---- Fake Drive implementation to verify if_none_match & zero partial commit ----

  defmodule FakeDrive do
    @behaviour SalixAgent.Drive

    def reset do
      SystemsRuntime.PersistentTerm.put({__MODULE__, :files}, %{})
      SystemsRuntime.PersistentTerm.put({__MODULE__, :writes}, [])
      SystemsRuntime.PersistentTerm.put({__MODULE__, :unknown_size_paths}, MapSet.new())
      SystemsRuntime.PersistentTerm.put({__MODULE__, :stat_errors}, %{})
    end

    def put_stat_error(path, reason) do
      errors = SystemsRuntime.PersistentTerm.get({__MODULE__, :stat_errors}, %{})
      SystemsRuntime.PersistentTerm.put({__MODULE__, :stat_errors}, Map.put(errors, path, reason))
    end

    def put_unknown_size(path, body) do
      SystemsRuntime.PersistentTerm.put({__MODULE__, :files}, Map.put(files(), path, body))

      set =
        SystemsRuntime.PersistentTerm.get({__MODULE__, :unknown_size_paths}, MapSet.new())
        |> MapSet.put(path)

      SystemsRuntime.PersistentTerm.put({__MODULE__, :unknown_size_paths}, set)
    end

    def writes, do: SystemsRuntime.PersistentTerm.get({__MODULE__, :writes}, [])
    def files, do: SystemsRuntime.PersistentTerm.get({__MODULE__, :files}, %{})

    @impl true
    def list(_g, _p), do: {:ok, []}

    @impl true
    def stat(_g, path) do
      stat_errors = SystemsRuntime.PersistentTerm.get({__MODULE__, :stat_errors}, %{})

      case Map.fetch(stat_errors, path) do
        {:ok, reason} ->
          {:error, reason}

        :error ->
          case Map.get(files(), path) do
            nil ->
              {:error, :not_found}

            body ->
              {:ok,
               %{
                 path: path,
                 name: Path.basename(path),
                 kind: "file",
                 size: byte_size(body),
                 modified_at: nil
               }}
          end
      end
    end

    @impl true
    def read(_g, path, _max) do
      case Map.get(files(), path) do
        nil -> {:error, :not_found}
        body -> {:ok, body, false}
      end
    end

    @impl true
    def stream(_g, path) do
      unknown = SystemsRuntime.PersistentTerm.get({__MODULE__, :unknown_size_paths}, MapSet.new())

      case Map.get(files(), path) do
        nil ->
          {:error, :not_found}

        body ->
          if MapSet.member?(unknown, path) do
            half = div(byte_size(body), 2)
            <<a::binary-size(^half), b::binary>> = body
            {:ok, [a, b], nil}
          else
            {:ok, [body], byte_size(body)}
          end
      end
    end

    @impl true
    def write(group_id, path, body, size, opts \\ []) do
      bytes =
        if is_binary(body),
          do: body,
          else: body |> Enum.to_list() |> IO.iodata_to_binary()

      existing = files()
      SystemsRuntime.PersistentTerm.put({__MODULE__, :writes}, [{path, size, opts} | writes()])

      if Keyword.get(opts, :if_none_match) == true and Map.has_key?(existing, path) do
        {:error, :precondition}
      else
        SystemsRuntime.PersistentTerm.put({__MODULE__, :files}, Map.put(existing, path, bytes))
        {:ok, %{size: byte_size(bytes), root: group_id}}
      end
    end

    @impl true
    def delete(_g, _p), do: {:ok, %{withdrawn: true, still_published: false}}
    @impl true
    def status(_g), do: {:ok, %{available: true, writable: true, detail: "ok"}}
  end

  setup do
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    agent = Ids.new_agent_id(group)

    prev_private = SystemsRuntime.get_env(:salix_agent, :colab_allow_private_endpoints)
    prev_drive = SystemsRuntime.get_env(:salix_agent, :drive_mod)

    SystemsRuntime.put_env(:salix_agent, :colab_allow_private_endpoints, true)
    SystemsRuntime.put_env(:salix_agent, :drive_mod, FakeDrive)
    FakeDrive.reset()

    name = SystemsRuntime.Proc.make_ref()
    host_key = :public_key.generate_key({:namedCurve, :ed25519})
    SystemsRuntime.PersistentTerm.put({DaemonKeys, name, :host_key}, host_key)
    SystemsRuntime.PersistentTerm.put({DaemonKeys, name, :authorized_pubkey}, nil)

    {:ok, daemon} =
      :ssh.daemon({127, 0, 0, 1}, 0,
        key_cb: {DaemonKeys, [name: name]},
        ssh_cli: {ExecShell, []},
        preferred_algorithms: [public_key: [:"ssh-ed25519"]],
        auth_methods: ~c"publickey"
      )

    {:ok, info} = :ssh.daemon_info(daemon)
    ssh_port = Keyword.fetch!(info, :port)

    remote_dir =
      Path.join(
        System.tmp_dir!(),
        "colab-remote-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(remote_dir)

    on_exit(fn ->
      :ssh.stop_daemon(daemon)
      File.rm_rf!(remote_dir)
      SystemsRuntime.PersistentTerm.erase({DaemonKeys, name, :host_key})
      SystemsRuntime.PersistentTerm.erase({DaemonKeys, name, :authorized_pubkey})
      restore_env(:colab_allow_private_endpoints, prev_private)
      restore_env(:drive_mod, prev_drive)
      _ = Store.query("DELETE FROM colab_vm_leases WHERE tenant_id=$1", [tenant])
      _ = Store.query("DELETE FROM colab_accounts WHERE tenant_id=$1", [tenant])
    end)

    %{
      tenant: tenant,
      group: group,
      agent: agent,
      ctx: %{tenant_id: tenant, group_id: group, agent_id: agent, session_id: "sess-tun"},
      daemon_name: name,
      ssh_port: ssh_port,
      remote_dir: remote_dir
    }
  end

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore_env(key, val), do: SystemsRuntime.put_env(:salix_agent, key, val)

  defp insert_active_lease!(tenant, group, owner_scope, proxy_url) do
    acc_id = "colab_acc_tun_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    now = SystemsClock.utc_now()

    {:ok, _} =
      Store.query(
        """
        INSERT INTO colab_accounts (
          binding_id, tenant_id, group_id, alias, google_sub, email,
          credentials_ciphertext, credential_revision, status, state,
          created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, 1, 'ok', 'active', $8, $8)
        """,
        [acc_id, tenant, group, "google-colab", "sub-tun", "tun@gmail.com", <<"unused">>, now]
      )

    spec = %{variant: "GPU", accelerator: "G4", high_mem: false}
    {:ok, l, _} = Leases.insert_assigning(tenant, group, owner_scope, nil, acc_id, spec)
    {:ok, active} = Leases.promote_active(l.vm_id, 1, "m-s-tun-1", proxy_url)
    active
  end

  test "loopback WS -> TCP -> OTP :ssh handshake, ping/pong, 429, and host key pin/mismatch", %{
    tenant: tenant,
    group: group,
    daemon_name: daemon_name,
    ssh_port: ssh_port
  } do
    # 1. HTTP 429 returns :ssh_session_limit cleanly
    proxy_429 = FakeWsProxy.start(ssh_port, daemon_name, http_status: 429)
    on_exit(fn -> FakeWsProxy.stop(proxy_429) end)

    assert {:error, :ssh_session_limit} =
             Tunnels.get_or_connect("colab_429_test", 1, %{
               proxy_url: "http://127.0.0.1:#{proxy_429.port}",
               proxy_token: "ptok-429"
             })

    # 2. Successful handshake with WS ping/pong & host key pinning
    proxy = FakeWsProxy.start(ssh_port, daemon_name, send_ping: true, test_pid: self())
    on_exit(fn -> FakeWsProxy.stop(proxy) end)

    proxy_url = "http://127.0.0.1:#{proxy.port}"
    lease = insert_active_lease!(tenant, group, "session:a:tun", proxy_url)

    assert {:ok, conn} =
             Tunnels.get_or_connect(lease.vm_id, lease.generation, %{
               proxy_url: proxy_url,
               proxy_token: "ptok-live-1"
             })

    assert is_pid(conn)

    # Verify WS upgrade path, query params, headers, and pong reply
    assert_received {:ws_upgrade_seen, path, headers}
    assert String.starts_with?(path, "/colab/ssh?")
    assert String.contains?(path, "colab-runtime-proxy-token=ptok-live-1")
    assert String.contains?(path, "colab-client-agent=colab-cli")
    assert String.contains?(path, "colab-client-agent=ssh-mode-proxy")
    assert String.starts_with?(headers["x-colab-ssh-pubkey"], "ssh-ed25519 ")
    assert headers["x-colab-client-agent"] == "colab-cli"

    # Host key fingerprint was pinned in DB
    {:ok, pinned} = Leases.get_by_id(lease.vm_id)
    assert is_binary(pinned.host_key_fingerprint)
    assert String.starts_with?(pinned.host_key_fingerprint, "SHA256:")

    # Drop tunnel (simulating reconnect) and reconnect with SAME host key -> succeeds
    Tunnels.drop(lease.vm_id)

    assert {:ok, _conn2} =
             Tunnels.get_or_connect(lease.vm_id, lease.generation, %{
               proxy_url: proxy_url,
               proxy_token: "ptok-live-2"
             })

    # Swap daemon host key -> reconnect MUST fail closed with {:host_key_mismatch, _, _}
    Tunnels.drop(lease.vm_id)
    new_key = :public_key.generate_key({:namedCurve, :ed25519})
    SystemsRuntime.PersistentTerm.put({DaemonKeys, daemon_name, :host_key}, new_key)

    assert {:error, {:host_key_mismatch, stored, presented}} =
             Tunnels.get_or_connect(lease.vm_id, lease.generation, %{
               proxy_url: proxy_url,
               proxy_token: "ptok-live-3"
             })

    assert stored == pinned.host_key_fingerprint
    assert presented != stored
  end

  test "Transfer.exec, atomic upload (overwrite/dir/wc-c), and atomic download (zero partial commit + if_none_match)",
       %{
         tenant: tenant,
         group: group,
         agent: agent,
         ctx: ctx,
         daemon_name: daemon_name,
         ssh_port: ssh_port,
         remote_dir: remote_dir
       } do
    proxy = FakeWsProxy.start(ssh_port, daemon_name)
    on_exit(fn -> FakeWsProxy.stop(proxy) end)

    proxy_url = "http://127.0.0.1:#{proxy.port}"
    lease = insert_active_lease!(tenant, group, "session:a:xfer", proxy_url)

    {:ok, conn} =
      Tunnels.get_or_connect(lease.vm_id, lease.generation, %{
        proxy_url: proxy_url,
        proxy_token: "ptok-xfer"
      })

    # 1. exec with cwd, stdin, stdout/stderr
    assert {:ok, res} =
             Transfer.exec(conn, "pwd && cat && echo err_line >&2",
               cwd: remote_dir,
               stdin: "hello_stdin\n",
               timeout_ms: 10_000
             )

    assert res["exit_status"] == 0
    assert res["timed_out"] == false
    assert String.contains?(res["stdout"], Path.basename(remote_dir))
    assert String.contains?(res["stdout"], "hello_stdin")
    assert String.contains?(res["stderr"], "err_line")

    # 2. exec timeout
    assert {:ok, timed} = Transfer.exec(conn, "__hang__", cwd: remote_dir, timeout_ms: 50)
    assert timed["timed_out"] == true

    # 3. upload from VFS -> remote with atomic overwrite: false / true / dir check
    payload = :binary.copy(<<0, 1, 2, 255, 128, 64, 32, 16>>, 256)
    {:ok, ev} = AgentWorkspace.prepare_write(agent, "/inputs/data.bin", payload)
    {:ok, _} = AgentWorkspace.seed_operation(agent, "seed-upload", %{}, [ev])

    dst = Path.join(remote_dir, "sub/data.bin")
    assert {:ok, %{"bytes" => 2048}} = Transfer.upload(conn, ctx, "/inputs/data.bin", dst, false)
    assert File.read!(dst) == payload

    # overwrite: false hits atomic ln EEXIST -> {:remote_exists, dst}
    assert {:error, {:remote_exists, ^dst}} =
             Transfer.upload(conn, ctx, "/inputs/data.bin", dst, false)

    # overwrite: true replaces atomically
    assert {:ok, %{"bytes" => 2048}} = Transfer.upload(conn, ctx, "/inputs/data.bin", dst, true)

    # existing directory rejected with {:remote_is_directory, _}
    existing_dir = Path.join(remote_dir, "adir")
    File.mkdir_p!(existing_dir)

    assert {:error, {:remote_is_directory, ^existing_dir}} =
             Transfer.upload(conn, ctx, "/inputs/data.bin", existing_dir, true)

    # Verify upload_script enforces exact wc -c check (truncation rejected with exit 3)
    trunc_dst = Path.join(remote_dir, "truncated.bin")
    script = Transfer.upload_script(trunc_dst, 100, false)

    assert {:ok, %{"exit_status" => 3}} =
             Transfer.exec(conn, script, cwd: remote_dir, stdin: "short")

    refute File.exists?(trunc_dst)

    # 4. download to VFS (overwrite: false carries if_none_match: true for atomic commit guard)
    assert {:ok, %{"bytes" => 2048}, [vfs_event]} =
             Transfer.download(conn, ctx, dst, "/outputs/data.bin", false)

    assert vfs_event["type"] == "vfs_write"
    assert vfs_event["size"] == 2048
    assert vfs_event["if_none_match"] == true

    # Concurrent writer commits /outputs/data.bin between preflight and commit:
    # atomic if_none_match rejects the racing download and preserves first writer's content!
    {:ok, first_ev} = AgentWorkspace.prepare_write(agent, "/outputs/data.bin", "first-writer")
    {:ok, _} = AgentWorkspace.seed_operation(agent, "seed-first-writer", %{}, [first_ev])

    assert {:error, :destination_exists} =
             AgentWorkspace.seed_operation(agent, "commit-racing-download", %{}, [vfs_event])

    assert {:ok, "first-writer"} = AgentWorkspace.read(agent, "/outputs/data.bin")

    # Preflight stat encountering a storage error must fail closed (never treat as absent!)
    FakeDrive.put_stat_error("out/stat-err.bin", :unavailable)

    assert {:error, {:vfs_stat_failed, reason}} =
             Transfer.download(conn, ctx, dst, "/drive/out/stat-err.bin", false)

    assert reason == :unavailable or
             (is_binary(reason) and String.contains?(reason, "unavailable"))

    # 5. download to /drive/... passes if_none_match: true when overwrite: false
    assert {:ok, %{"bytes" => 2048}, []} =
             Transfer.download(conn, ctx, dst, "/drive/out/data.bin", false)

    assert FakeDrive.files()["out/data.bin"] == payload
    assert [{"out/data.bin", 2048, [if_none_match: true]} | _] = FakeDrive.writes()

    # overwrite: false when Drive file exists fails with {:destination_exists, _}
    assert {:error, {:destination_exists, "/drive/out/data.bin"}} =
             Transfer.download(conn, ctx, dst, "/drive/out/data.bin", false)

    # 6. CRITICAL: remote exits non-zero AFTER streaming partial bytes -> ZERO Drive.write!
    writes_before = length(FakeDrive.writes())

    assert {:error, {:remote_exit, 1, nil, _}} =
             Transfer.download(conn, ctx, "__partial_fail__", "/drive/out/never.bin", true)

    assert length(FakeDrive.writes()) == writes_before
    refute Map.has_key?(FakeDrive.files(), "out/never.bin")

    # Also ZERO VFS commit event on partial failure
    assert {:error, {:remote_exit, 1, nil, _}} =
             Transfer.download(conn, ctx, "__partial_fail__", "/outputs/never.bin", true)

    # 7. Upload from Drive with unknown Content-Length (size == nil) spools and verifies exact bytes
    unknown_payload = :binary.copy(<<10, 20, 30, 40, 50>>, 100)
    FakeDrive.put_unknown_size("inputs/unknown_len.bin", unknown_payload)
    unknown_dst = Path.join(remote_dir, "unknown_len.bin")

    assert {:ok, %{"bytes" => 500}} =
             Transfer.upload(conn, ctx, "/drive/inputs/unknown_len.bin", unknown_dst, false)

    assert File.read!(unknown_dst) == unknown_payload
  end
end
