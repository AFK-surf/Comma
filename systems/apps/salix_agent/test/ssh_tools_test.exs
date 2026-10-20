defmodule SalixAgent.SSHToolsTest do
  require SystemsRuntime.Proc

  @moduledoc """
  `ssh.*` tools against a real OTP SSH daemon on loopback: Group key creation,
  trust on first use, detailed connection failures, the interactive PTY
  session, exec and SFTP on the same connection, and session lifecycle.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{AgentWorkspace, Fleet, InternalSessionFleet, TestSupport}
  alias SalixAgent.SSH.{Identity, TailcatGateway}
  alias SalixAgent.Tools.SSH
  alias SalixStore.{Ids, Keys, S3}

  defmodule LinkedTaskStore do
    @moduledoc false
    # The AWS backend performs requests in linked tasks. Preserve that process
    # behavior here so a real SSH connection exercises the callback boundary.
    def get(key, opts) do
      task = SystemsRuntime.Task.async(fn -> S3.Fake.get(key, opts) end)
      {:ok, result} = SystemsRuntime.Task.yield(task, 5_000)
      result
    end

    defdelegate put(key, body, opts), to: S3.Fake
    defdelegate head(key), to: S3.Fake
    defdelegate delete(key, opts), to: S3.Fake
    defdelegate list(prefix, opts), to: S3.Fake
  end

  defmodule ServerKeys do
    @moduledoc false
    @behaviour :ssh_server_key_api

    @impl true
    def host_key(algorithm, options)
        when algorithm in [:"ssh-ed25519", :"rsa-sha2-512", :"rsa-sha2-256"] do
      name = options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:name)
      {:ok, SystemsRuntime.PersistentTerm.get({__MODULE__, name, :host_key})}
    end

    def host_key(_algorithm, _options), do: {:error, :no_host_key}

    @impl true
    def is_auth_key(key, _user, options) do
      name = options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:name)

      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, name, :test_pid}),
        {:auth_attempt, name}
      )

      key in SystemsRuntime.PersistentTerm.get({__MODULE__, name, :authorized})
    end
  end

  defmodule Shell do
    @moduledoc false
    # A scripted remote shell: a PTY with echo, a "$ " prompt and a few
    # commands, plus exec requests.
    @behaviour :ssh_server_channel

    @impl true
    def init(_args), do: {:ok, %{line: "", size: {0, 0}, exec: nil, stdin: []}}

    @impl true
    def handle_msg({:ssh_channel_up, _channel, _conn}, state), do: {:ok, state}
    def handle_msg(_message, state), do: {:ok, state}

    @impl true
    def handle_ssh_msg(
          {:ssh_cm, conn, {:pty, channel, want, {_term, cols, rows, _, _, _}}},
          state
        ) do
      :ssh_connection.reply_request(conn, want, :success, channel)
      {:ok, %{state | size: {cols, rows}}}
    end

    def handle_ssh_msg({:ssh_cm, conn, {:shell, channel, want}}, state) do
      :ssh_connection.reply_request(conn, want, :success, channel)
      :ssh_connection.send(conn, channel, "welcome\r\n$ ")
      {:ok, state}
    end

    def handle_ssh_msg({:ssh_cm, _conn, {:window_change, _channel, cols, rows, _, _}}, state),
      do: {:ok, %{state | size: {cols, rows}}}

    def handle_ssh_msg({:ssh_cm, conn, {:exec, channel, want, command}}, state) do
      :ssh_connection.reply_request(conn, want, :success, channel)

      case List.to_string(command) do
        "report" ->
          :ssh_connection.send(conn, channel, 0, "out\n")
          :ssh_connection.send(conn, channel, 1, "err\n")
          :ssh_connection.exit_status(conn, channel, 3)
          :ssh_connection.send_eof(conn, channel)
          {:stop, channel, state}

        "cat" ->
          {:ok, %{state | exec: :cat}}
      end
    end

    def handle_ssh_msg({:ssh_cm, _conn, {:data, _channel, 0, data}}, %{exec: :cat} = state),
      do: {:ok, %{state | stdin: [state.stdin, data]}}

    def handle_ssh_msg({:ssh_cm, conn, {:eof, channel}}, %{exec: :cat} = state) do
      :ssh_connection.send(conn, channel, IO.iodata_to_binary(state.stdin))
      :ssh_connection.exit_status(conn, channel, 0)
      :ssh_connection.send_eof(conn, channel)
      {:stop, channel, state}
    end

    def handle_ssh_msg({:ssh_cm, conn, {:data, channel, 0, data}}, state) do
      type(conn, channel, data, state)
    end

    def handle_ssh_msg({:ssh_cm, _conn, {:closed, channel}}, state), do: {:stop, channel, state}
    def handle_ssh_msg(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok

    defp type(_conn, _channel, "", state), do: {:ok, state}

    defp type(conn, channel, <<3, rest::binary>>, state) do
      :ssh_connection.send(conn, channel, "^C\r\n$ ")
      type(conn, channel, rest, %{state | line: ""})
    end

    defp type(conn, channel, <<?\r, rest::binary>>, state) do
      :ssh_connection.send(conn, channel, "\r\n")

      case run(conn, channel, state.line, state) do
        :exit -> {:stop, channel, state}
        state -> type(conn, channel, rest, %{state | line: ""})
      end
    end

    defp type(conn, channel, <<c, rest::binary>>, state) do
      :ssh_connection.send(conn, channel, <<c>>)
      type(conn, channel, rest, %{state | line: state.line <> <<c>>})
    end

    defp run(conn, channel, "echo " <> text, state) do
      :ssh_connection.send(conn, channel, "\e[32m" <> text <> "\e[0m\r\n$ ")
      state
    end

    defp run(_conn, _channel, "sleep", state), do: state

    defp run(conn, channel, "size", %{size: {cols, rows}} = state) do
      :ssh_connection.send(conn, channel, "#{rows} #{cols}\r\n$ ")
      state
    end

    defp run(conn, channel, "edit", state) do
      :ssh_connection.send(conn, channel, "\e[?1049h\e[H\e[2JEDITOR\e[3;5Hline three")
      state
    end

    defp run(conn, channel, "quit", state) do
      :ssh_connection.send(conn, channel, "\e[?1049l$ ")
      state
    end

    defp run(conn, channel, "flood", state) do
      for _ <- 1..24, do: :ssh_connection.send(conn, channel, :binary.copy("x", 65_536))
      :ssh_connection.send(conn, channel, "\r\ndone\r\n$ ")
      state
    end

    defp run(conn, channel, "exit " <> code, _state) do
      :ssh_connection.send(conn, channel, "logout\r\n")
      :ssh_connection.exit_status(conn, channel, String.to_integer(code))
      :ssh_connection.send_eof(conn, channel)
      :exit
    end

    defp run(conn, channel, _line, state) do
      :ssh_connection.send(conn, channel, "$ ")
      state
    end
  end

  defmodule GatewayDispatch do
    @moduledoc false
    # A gateway device whose connector runs in-process: it dials the host
    # itself and speaks the tunnel frame protocol with the relay, acknowledging
    # what it writes.
    def get_device(_agent_id, "dev-gw") do
      {:ok,
       %{
         "device_id" => "dev-gw",
         "environment_id" => "env-gw",
         "status" => "connected",
         "capabilities" => %{
           "lan_gateway" => %{
             "methods" => SystemsRuntime.PersistentTerm.get({__MODULE__, :methods})
           }
         },
         "environments" => [
           %{
             "environment_id" => "env-gw",
             "environment_provider" => "connector",
             "status" => "connected"
           }
         ]
       }}
    end

    def get_device(_agent_id, _device_id), do: {:error, :not_found}

    def open_tunnel(_agent_id, target, id, %{"host" => host, "port" => port}, relay) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :test_pid}),
        {:tunnel_opened, target, host, port}
      )

      parent = SystemsRuntime.Proc.self()
      owner = SystemsRuntime.Proc.spawn(fn -> connector(parent, id, host, port, relay) end)

      SystemsRuntime.Proc.receive do
        {^owner, :connected} ->
          # A small window makes the relay wait for acknowledgements.
          {:ok, %{owner: owner, result: %{"status" => "connected", "window" => 65_536}}}

        {^owner, {:error, reason}} ->
          {:error, reason}
      end
    end

    defp connector(parent, id, host, port, relay) do
      case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: :once], 5_000) do
        {:ok, socket} ->
          SystemsRuntime.Proc.monitor(relay)
          SystemsRuntime.Proc.send(parent, {SystemsRuntime.Proc.self(), :connected})
          relay_loop(%{socket: socket, id: id, relay: relay, written: 0})

        {:error, reason} ->
          SystemsRuntime.Proc.send(
            parent,
            {SystemsRuntime.Proc.self(), {:error, "dial tcp #{host}:#{port}: #{reason}"}}
          )
      end
    end

    defp relay_loop(%{socket: socket, id: id, relay: relay} = state) do
      SystemsRuntime.Proc.receive do
        {:tcp, ^socket, data} ->
          for <<chunk::binary-size(32_768) <- data>> do
            SystemsRuntime.Proc.send(
              relay,
              {:env_tunnel_frame, id, %{"channel" => "tcp", "data" => Base.encode64(chunk)}}
            )
          end

          rest =
            binary_part(data, div(byte_size(data), 32_768) * 32_768, rem(byte_size(data), 32_768))

          if rest != "",
            do:
              SystemsRuntime.Proc.send(
                relay,
                {:env_tunnel_frame, id, %{"channel" => "tcp", "data" => Base.encode64(rest)}}
              )

          :inet.setopts(socket, active: :once)
          relay_loop(state)

        {:tcp_closed, ^socket} ->
          SystemsRuntime.Proc.send(
            relay,
            {:env_tunnel_frame, id, %{"channel" => "tcp", "eof" => true}}
          )

        {:env_tunnel_send, ^relay, ^id, %{"channel" => "tcp", "data" => data}} ->
          bytes = Base.decode64!(data)
          :ok = :gen_tcp.send(socket, bytes)
          written = state.written + byte_size(bytes)

          SystemsRuntime.Proc.send(
            relay,
            {:env_tunnel_frame, id, %{"channel" => "tcp_ack", "seq" => written}}
          )

          relay_loop(%{state | written: written})

        {:env_tunnel_send, ^relay, ^id, %{"channel" => "tcp", "eof" => true}} ->
          :gen_tcp.close(socket)

        {:env_tunnel_send, ^relay, ^id, _ack} ->
          relay_loop(state)

        {:DOWN, _ref, :process, ^relay, _reason} ->
          :gen_tcp.close(socket)
      end
    end
  end

  setup do
    TestSupport.stop_all_agents()
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_private = SystemsRuntime.get_env(:salix_agent, :ssh_allow_private_hosts)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :ssh_allow_private_hosts, true)

    case SystemsRuntime.Proc.whereis(S3.Fake) do
      nil -> start_supervised!(S3.Fake)
      _pid -> S3.Fake.reset()
    end

    agent_id = TestSupport.new_agent_id()
    group_id = Ids.group_id_from_agent!(agent_id)

    root =
      Path.join(System.tmp_dir!(), "salix-ssh-#{SystemsRuntime.Proc.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn ->
      TestSupport.stop_all_agents()
      restore(:salix_store, :s3_backend, previous_backend)
      restore(:salix_agent, :ssh_allow_private_hosts, previous_private)
      File.rm_rf!(root)
    end)

    ctx = %{
      agent_id: agent_id,
      session_id: "ses1_0000000000000000701",
      group_id: group_id,
      tenant_id: Ids.tenant_id_from_group!(group_id),
      tool_call_id: "call-open-1"
    }

    TestSupport.create_control_agent!(agent_id)
    actor = start_actor!(ctx)

    {:ok, ctx: ctx, root: root, actor: actor}
  end

  # SSH sessions live under the Agent session's actor.
  defp start_actor!(ctx) do
    case SalixAgent.InternalSessionStore.prepare_create(ctx.agent_id, ctx.session_id, %{}) do
      {:ok, _} -> :ok
      {:error, :exists} -> :ok
    end

    {:ok, _server} = Fleet.ensure_started(ctx.agent_id, create: false, startup_mode: :passive)

    {:ok, actor} =
      InternalSessionFleet.ensure_started(ctx.agent_id, ctx.session_id, process_on_init: false)

    actor
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  # A daemon whose host key can be swapped between connections.
  defp daemon(ctx, root, opts \\ []) do
    name = SystemsRuntime.Proc.make_ref()

    host_key =
      Keyword.get_lazy(opts, :host_key, fn ->
        :public_key.generate_key({:namedCurve, :ed25519})
      end)

    {:ok, identity} = Identity.fetch(ctx.group_id)
    authorized = if Keyword.get(opts, :authorize, true), do: [identity.public_key], else: []

    SystemsRuntime.PersistentTerm.put({ServerKeys, name, :host_key}, host_key)
    SystemsRuntime.PersistentTerm.put({ServerKeys, name, :authorized}, authorized)
    SystemsRuntime.PersistentTerm.put({ServerKeys, name, :test_pid}, SystemsRuntime.Proc.self())

    {:ok, daemon} =
      :ssh.daemon({127, 0, 0, 1}, 0,
        key_cb: {ServerKeys, [name: name]},
        ssh_cli: {Shell, []},
        subsystems: [:ssh_sftpd.subsystem_spec(root: String.to_charlist(root))],
        preferred_algorithms: [public_key: Keyword.get(opts, :host_algorithms, [:"ssh-ed25519"])],
        auth_methods: ~c"publickey"
      )

    {:ok, info} = :ssh.daemon_info(daemon)

    on_exit(fn ->
      :ssh.stop_daemon(daemon)

      Enum.each(
        [:host_key, :authorized, :test_pid],
        &SystemsRuntime.PersistentTerm.erase({ServerKeys, name, &1})
      )
    end)

    %{name: name, port: Keyword.fetch!(info, :port), host_key: host_key}
  end

  defp swap_host_key(server, key),
    do: SystemsRuntime.PersistentTerm.put({ServerKeys, server.name, :host_key}, key)

  defp decode(json) when is_binary(json), do: {:ok, Jason.decode!(json)}

  defp decode({:tool_failure, diagnostic, code, "user_reportable", _summary, []}) do
    %{"ok" => false, "error" => %{"code" => ^code} = error} = Jason.decode!(diagnostic)
    {:error, error}
  end

  defp open!(ctx, server, extra \\ %{}) do
    args = Map.merge(%{"host" => "127.0.0.1", "port" => server.port, "user" => "deploy"}, extra)
    {:ok, session} = decode(SSH.open(args, ctx))
    session
  end

  defp write(ctx, id, args), do: SSH.write(Map.put(args, "ssh_session_id", id), ctx) |> decode()
  defp read(ctx, id, args), do: SSH.read(Map.put(args, "ssh_session_id", id), ctx) |> decode()

  test "a loop opens SSH, executes a command and closes its session", %{ctx: ctx, root: root} do
    alias SalixAgent.Loops
    alias SalixAgent.Loops.Capabilities

    # Exercise host calls directly without the runtime adopting the placeholder ELF.
    # A sweep in progress (host and database calls) can outlast the default
    # 5 s system-message timeout on a loaded runner; wait for it to finish.
    :ok = :sys.suspend(Loops.Reconciler, :infinity)
    on_exit(:loop_ssh_cleanup, fn -> :sys.resume(Loops.Reconciler) end)
    server = daemon(ctx, root)

    {:ok, event} =
      AgentWorkspace.prepare_write(ctx.agent_id, "/loops/ssh.elf", <<0x7F, ?E, ?L, ?F>>)

    {:ok, _} = AgentWorkspace.seed_operation(ctx.agent_id, "loop-ssh", %{}, [event])
    {:ok, loop} = Loops.create(ctx, %{"path" => "/loops/ssh.elf"})

    on_exit(:loop_ssh_cleanup, fn ->
      :sys.resume(Loops.Reconciler)
      Loops.delete(ctx.agent_id, loop["loop_id"])
    end)

    {:ok, record} = SalixStore.Loops.get(loop["loop_id"])

    ref = %{
      loop_id: record["id"],
      incarnation: record["incarnation"],
      agent_id: record["agent_id"],
      session_id: record["session_id"],
      tenant_id: record["tenant_id"],
      group_id: record["group_id"],
      ifc: record["ifc"]
    }

    args = %{"host" => "127.0.0.1", "port" => server.port, "user" => "deploy"}

    assert {:ok, %{"content" => opened}} = Capabilities.call(ref, "ssh.open", args)
    session = Jason.decode!(opened)
    assert session["output"] =~ "welcome"
    id = session["ssh_session_id"]

    assert {:ok, %{"content" => output}} =
             Capabilities.call(ref, "ssh.exec", %{"ssh_session_id" => id, "command" => "report"})

    assert %{"stdout" => "out\n", "stderr" => "err\n", "exit_status" => 3} = Jason.decode!(output)

    assert {:error, "loop incarnation " <> _} =
             Capabilities.call(%{ref | incarnation: ref.incarnation + 1}, "ssh.close", %{
               "ssh_session_id" => id
             })

    assert {:error, "Loop SSH downloads require a /drive destination." <> _} =
             Capabilities.call(ref, "ssh.download", %{
               "ssh_session_id" => id,
               "source" => "/report.txt",
               "destination" => "/report.txt"
             })

    assert {:ok, %{"content" => closed}} =
             Capabilities.call(ref, "ssh.close", %{"ssh_session_id" => id})

    assert %{"status" => "closed"} = Jason.decode!(closed)
  end

  test "the Group key is created once under concurrent first use and shown as an authorized_keys line",
       %{ctx: ctx} do
    keys =
      1..8
      |> Task.async_stream(fn _ -> decode(SSH.public_key(%{}, ctx)) end, max_concurrency: 8)
      |> Enum.map(fn {:ok, {:ok, result}} -> result end)

    assert [%{"public_key" => "ssh-ed25519 " <> _ = line, "fingerprint" => "SHA256:" <> _}] =
             Enum.uniq(keys)

    assert String.ends_with?(line, " salix-group-" <> ctx.group_id)

    assert {:ok, %{body: "-----BEGIN PRIVATE KEY-----" <> _}} =
             S3.get(Keys.ctl_group_ssh_identity(ctx.group_id))
  end

  test "an interactive session types, waits for prompts, renders the screen and reports the exit",
       %{ctx: ctx, root: root} do
    server = daemon(ctx, root)
    session = open!(ctx, server, %{"cols" => 100, "rows" => 30})
    id = session["ssh_session_id"]

    assert session["status"] == "open"
    assert session["host_key"]["status"] == "trusted_on_first_use"
    assert session["output"] =~ "welcome"

    # The same tool call opening again returns the same session.
    assert {:ok, %{"ssh_session_id" => ^id}} =
             decode(
               SSH.open(%{"host" => "127.0.0.1", "port" => server.port, "user" => "deploy"}, ctx)
             )

    assert {:ok, echoed} =
             write(ctx, id, %{
               "input" => "echo hello",
               "keys" => ["enter"],
               "until_text" => "hello\n$ "
             })

    assert echoed["matched"]
    assert echoed["output"] == "echo hello\nhello\n$ "

    assert {:ok, all} = read(ctx, id, %{"from_offset" => 0})
    assert all["output"] == "welcome\n$ echo hello\nhello\n$ "
    assert all["next_offset"] == echoed["next_offset"]
    refute all["truncated"]

    assert {:ok, _} =
             write(ctx, id, %{"input" => "sleep", "keys" => ["enter"], "wait_seconds" => 0})

    assert {:ok, interrupted} = write(ctx, id, %{"keys" => ["ctrl_c"], "until_text" => "$ "})
    assert interrupted["output"] =~ "^C"

    assert {:ok, _} =
             decode(SSH.resize(%{"ssh_session_id" => id, "cols" => 90, "rows" => 20}, ctx))

    assert {:ok, size} =
             write(ctx, id, %{"input" => "size", "keys" => ["enter"], "until_text" => "$ "})

    assert size["output"] =~ "20 90"

    assert {:ok, _} =
             write(ctx, id, %{"input" => "edit", "keys" => ["enter"], "until_text" => "three"})

    assert {:ok, screen} = decode(SSH.screen(%{"ssh_session_id" => id}, ctx))
    assert screen["alternate_screen"]
    assert Enum.take(screen["lines"], 3) == ["EDITOR", "", "    line three"]
    assert screen["cursor"] == %{"row" => 3, "col" => 15, "visible" => true}

    assert {:ok, _} =
             write(ctx, id, %{"input" => "quit", "keys" => ["enter"], "until_text" => "$ "})

    assert {:ok, screen} = decode(SSH.screen(%{"ssh_session_id" => id}, ctx))
    refute screen["alternate_screen"]
    assert Enum.at(screen["lines"], 0) == "welcome"

    assert {:ok, flood} =
             write(ctx, id, %{
               "input" => "flood",
               "keys" => ["enter"],
               "until_text" => "done",
               "wait_seconds" => 30
             })

    assert flood["matched"]
    assert {:ok, early} = read(ctx, id, %{"from_offset" => 0, "max_bytes" => 16})
    assert early["truncated"]
    assert early["more"]
    assert {:ok, tail} = read(ctx, id, %{"tail_bytes" => 10})
    assert tail["output"] =~ "done"

    assert {:ok, ended} =
             write(ctx, id, %{
               "input" => "exit 3",
               "keys" => ["enter"],
               "wait_seconds" => 5,
               "until_text" => "never"
             })

    assert ended["status"] == "closed"
    assert ended["close_reason"] == "shell_exited"
    assert ended["exit_status"] == 3
    assert ended["output"] =~ "logout"

    assert {:error, %{"code" => "session_closed"}} = write(ctx, id, %{"input" => "echo again"})
  end

  test "a changed host key is refused before authentication until the user-approved removal",
       %{ctx: ctx, root: root} do
    server = daemon(ctx, root)
    first = open!(ctx, server)
    assert_receive {:auth_attempt, _}
    assert {:ok, _} = decode(SSH.close(%{"ssh_session_id" => first["ssh_session_id"]}, ctx))
    original = first["host_key"]["fingerprint"]

    rebuilt = :public_key.generate_key({:namedCurve, :ed25519})
    swap_host_key(server, rebuilt)
    ctx = %{ctx | tool_call_id: "call-open-2"}

    assert {:error, mismatch} =
             decode(
               SSH.open(%{"host" => "127.0.0.1", "port" => server.port, "user" => "deploy"}, ctx)
             )

    assert mismatch["code"] == "host_key_mismatch"
    assert mismatch["stored_fingerprint"] == original
    assert mismatch["presented_fingerprint"] != original
    assert mismatch["presented_key_type"] == "ssh-ed25519"
    assert mismatch["first_seen_by_agent_id"] == ctx.agent_id
    assert mismatch["known_hosts_name"] == "[127.0.0.1]:#{server.port}"
    refute_received {:auth_attempt, _}

    assert {:ok, %{"hosts" => [%{"fingerprint" => ^original}]}} =
             decode(SSH.known_hosts_list(%{}, ctx))

    assert {:ok, %{"removed" => true}} =
             decode(SSH.known_hosts_remove(%{"host" => "127.0.0.1", "port" => server.port}, ctx))

    ctx = %{ctx | tool_call_id: "call-open-3"}
    reopened = open!(ctx, server)
    assert reopened["host_key"]["status"] == "trusted_on_first_use"
    assert reopened["host_key"]["fingerprint"] == mismatch["presented_fingerprint"]
  end

  test "rejected authentication and private destinations return actionable diagnostics",
       %{ctx: ctx, root: root} do
    server = daemon(ctx, root, authorize: false)
    {:ok, identity} = Identity.fetch(ctx.group_id)

    assert {:error, failed} =
             decode(
               SSH.open(%{"host" => "127.0.0.1", "port" => server.port, "user" => "deploy"}, ctx)
             )

    assert failed["code"] == "auth_failed"
    assert failed["public_key"] == identity.public_key_line
    assert failed["client_key_fingerprint"] == identity.fingerprint
    assert failed["user"] == "deploy"
    assert failed["host_key"]["status"] == "trusted_on_first_use"

    SystemsRuntime.put_env(:salix_agent, :ssh_allow_private_hosts, false)
    ctx = %{ctx | tool_call_id: "call-open-private"}

    for host <- ["127.0.0.1", "localhost", "10.0.0.8", "db.internal"] do
      assert {:error, %{"code" => "blocked_destination"}} =
               decode(SSH.open(%{"host" => host, "port" => server.port, "user" => "deploy"}, ctx))
    end

    # The namespace is discovered through help, and the dispatcher records
    # the diagnostic as a user-reportable tool failure.
    tool_ctx = Map.merge(ctx, %{role: "worker", runtime_kind: :internal})

    tool_ctx =
      Map.put(
        tool_ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize_static("worker", :internal, tool_ctx)
      )

    discovered = Jason.decode!(SalixAgent.Tools.help(%{"tool" => "ssh"}, tool_ctx))
    assert "ssh.open" in Enum.map(discovered["tools"], & &1["name"])

    [result] =
      SalixAgent.Tools.execute(
        [%{id: "blocked", name: "ssh.open", args: %{"host" => "127.0.0.1", "user" => "deploy"}}],
        tool_ctx
      )

    assert result.error
    assert result.error_class == "blocked_destination"
    assert %{"error" => %{"code" => "blocked_destination"}} = Jason.decode!(result.content)
  end

  test "exec and SFTP transfers share the session's connection with the agent file system",
       %{ctx: ctx, root: root} do
    server = daemon(ctx, root)
    id = open!(ctx, server)["ssh_session_id"]

    assert {:ok, report} = decode(SSH.exec(%{"ssh_session_id" => id, "command" => "report"}, ctx))

    assert report == %{
             "stdout" => "out\n",
             "stderr" => "err\n",
             "exit_status" => 3,
             "exit_signal" => nil,
             "stdout_truncated" => false,
             "stderr_truncated" => false,
             "timed_out" => false
           }

    assert {:ok, %{"stdout" => "piped", "exit_status" => 0}} =
             decode(
               SSH.exec(%{"ssh_session_id" => id, "command" => "cat", "stdin" => "piped"}, ctx)
             )

    body = :binary.copy("0123456789abcdef", 12 * 65_536)
    chunks = for <<chunk::binary-size(262_144) <- body>>, do: chunk
    {:ok, event} = AgentWorkspace.prepare_write_stream(ctx.agent_id, "/data/big.bin", chunks)
    {:ok, _} = AgentWorkspace.seed_operation(ctx.agent_id, "seed-big", %{"ok" => true}, [event])

    assert {:ok, %{"bytes" => 12_582_912}} =
             decode(
               SSH.upload(
                 %{
                   "ssh_session_id" => id,
                   "source" => "/data/big.bin",
                   "destination" => "big.bin"
                 },
                 ctx
               )
             )

    assert File.read!(Path.join(root, "big.bin")) == body

    assert {:error, %{"code" => "upload_failed", "message" => message}} =
             decode(
               SSH.upload(
                 %{
                   "ssh_session_id" => id,
                   "source" => "/data/big.bin",
                   "destination" => "big.bin"
                 },
                 ctx
               )
             )

    assert message =~ "already exists"

    File.write!(Path.join(root, "remote.txt"), "from the host")
    File.mkdir_p!(Path.join(root, "logs"))

    assert {:ok, listing} = decode(SSH.list_files(%{"ssh_session_id" => id, "path" => "/"}, ctx))

    assert %{"name" => "logs", "type" => "directory"} =
             Enum.find(listing["entries"], &(&1["name"] == "logs"))

    assert %{"name" => "remote.txt", "type" => "regular", "size" => 13} =
             Enum.find(listing["entries"], &(&1["name"] == "remote.txt"))

    assert {json, [download_event]} =
             SSH.download(
               %{
                 "ssh_session_id" => id,
                 "source" => "remote.txt",
                 "destination" => "/inbox/remote.txt"
               },
               ctx
             )

    assert %{"bytes" => 13} = Jason.decode!(json)

    {:ok, _} =
      AgentWorkspace.seed_operation(ctx.agent_id, "seed-download", %{"ok" => true}, [
        download_event
      ])

    assert {:ok, "from the host"} = AgentWorkspace.read(ctx.agent_id, "/inbox/remote.txt")

    assert {:error, %{"code" => "download_failed"}} =
             decode(
               SSH.download(
                 %{"ssh_session_id" => id, "source" => "logs", "destination" => "/inbox/logs"},
                 ctx
               )
             )
  end

  test "the session actor supervises its SSH sessions and stays resident while they run",
       %{ctx: ctx, root: root, actor: actor} do
    server = daemon(ctx, root)

    ids =
      for n <- 1..4 do
        open!(%{ctx | tool_call_id: "call-limit-#{n}"}, server)["ssh_session_id"]
      end

    assert {:error, limit} =
             decode(
               SSH.open(%{"host" => "127.0.0.1", "port" => server.port, "user" => "deploy"}, %{
                 ctx
                 | tool_call_id: "call-limit-5"
               })
             )

    assert limit["code"] == "ssh_session_limit"
    assert Enum.sort(limit["open_ssh_session_ids"]) == Enum.sort(ids)

    # Another Agent session sees none of them and has no actor to admit one.
    other_session = %{ctx | session_id: "ses1_0000000000000000702"}

    assert {:error, %{"code" => "ssh_session_not_found"}} =
             decode(SSH.screen(%{"ssh_session_id" => hd(ids)}, other_session))

    assert {:ok, %{"sessions" => []}} = decode(SSH.list(%{}, other_session))

    assert {:error, %{"code" => "ssh_unavailable"}} =
             decode(
               SSH.open(%{"host" => "127.0.0.1", "port" => server.port, "user" => "deploy"}, %{
                 other_session
                 | tool_call_id: "call-other"
               })
             )

    assert {:ok, %{"sessions" => listed}} = decode(SSH.list(%{}, ctx))
    assert length(listed) == 4

    # Under memory pressure an idle actor is evicted, but not one with SSH
    # sessions; without them it goes.
    sessions = Enum.map(ids, &session_pid(ctx, &1))
    previous_pressure = :ets.lookup(SalixAgent.SessionResidency, :pressure)
    :ets.insert(SalixAgent.SessionResidency, {:pressure, :high})

    try do
      refute evicted?(actor, SystemsRuntime.Proc.monitor(actor), 3)

      ref = SystemsRuntime.Proc.monitor(actor)
      Enum.each(sessions, &SystemsRuntime.Proc.exit(&1, :kill))
      assert evicted?(actor, ref, 20)
    after
      :ets.insert(SalixAgent.SessionResidency, previous_pressure)
    end

    # A stopped actor takes its SSH sessions with it.
    actor = start_actor!(ctx)
    id = open!(%{ctx | tool_call_id: "call-after-evict"}, server)["ssh_session_id"]
    session = session_pid(ctx, id)
    ref = SystemsRuntime.Proc.monitor(session)
    :ok = Fleet.stop_session_actors(ctx.agent_id)
    assert_receive {:DOWN, ^ref, :process, ^session, _}
    refute SystemsRuntime.Proc.alive?(actor)

    assert {:error, %{"code" => "ssh_session_not_found"}} =
             decode(SSH.screen(%{"ssh_session_id" => id}, ctx))
  end

  test "hosts on the user's network are reached through a gateway device's connector",
       %{ctx: ctx, root: root} do
    server = daemon(ctx, root)
    previous = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, GatewayDispatch)
    SystemsRuntime.PersistentTerm.put({GatewayDispatch, :test_pid}, SystemsRuntime.Proc.self())

    SystemsRuntime.PersistentTerm.put({GatewayDispatch, :methods}, [
      "lan_http_request",
      "lan_tcp_dial"
    ])

    on_exit(fn ->
      restore(:salix_agent, :env_dispatch, previous)
      SystemsRuntime.PersistentTerm.erase({GatewayDispatch, :test_pid})
      SystemsRuntime.PersistentTerm.erase({GatewayDispatch, :methods})
    end)

    # The gateway dials whatever host it is given; Salix neither resolves nor
    # checks it, so the public-destination policy does not apply.
    SystemsRuntime.put_env(:salix_agent, :ssh_allow_private_hosts, false)

    {:ok, session} =
      decode(
        SSH.open(
          %{
            "host" => "127.0.0.1",
            "port" => server.port,
            "via_device_id" => "dev-gw",
            "user" => "deploy"
          },
          ctx
        )
      )

    id = session["ssh_session_id"]
    port = server.port

    assert_received {:tunnel_opened, %{device_id: "dev-gw", environment_id: "env-gw"},
                     "127.0.0.1", ^port}

    host = "device:dev-gw:127.0.0.1"
    assert session["host"] == host
    assert session["host_key"]["status"] == "trusted_on_first_use"
    assert session["output"] =~ "welcome"

    assert {:ok, %{"output" => "echo via gateway\nvia gateway\n$ "}} =
             write(ctx, id, %{
               "input" => "echo via gateway",
               "keys" => ["enter"],
               "until_text" => "gateway\n$ "
             })

    # Three windows in each direction.
    stdin = :binary.copy("0123456789abcdef", 12_288)

    assert {:ok, %{"stdout" => stdout, "stdout_truncated" => false, "exit_status" => 0}} =
             decode(
               SSH.exec(%{"ssh_session_id" => id, "command" => "cat", "stdin" => stdin}, ctx)
             )

    assert stdout == stdin
    assert {:ok, %{"hosts" => [%{"name" => name}]}} = decode(SSH.known_hosts_list(%{}, ctx))
    assert name == "[#{host}]:#{server.port}"

    assert {:ok, _} = decode(SSH.close(%{"ssh_session_id" => id}, ctx))

    SystemsRuntime.PersistentTerm.put({GatewayDispatch, :methods}, ["lan_http_request"])

    assert {:error, %{"code" => "not_a_lan_gateway", "via_device_id" => "dev-gw"}} =
             decode(
               SSH.open(
                 %{"host" => "nas.local", "via_device_id" => "dev-gw", "user" => "deploy"},
                 %{ctx | tool_call_id: "call-open-device-2"}
               )
             )

    SystemsRuntime.PersistentTerm.put({GatewayDispatch, :methods}, ["lan_tcp_dial"])

    closed =
      :gen_tcp.listen(0, [])
      |> then(fn {:ok, l} ->
        {:ok, p} = :inet.port(l)
        :gen_tcp.close(l)
        p
      end)

    assert {:error, %{"code" => "connect_failed", "reason" => reason}} =
             decode(
               SSH.open(
                 %{
                   "host" => "127.0.0.1",
                   "port" => closed,
                   "via_device_id" => "dev-gw",
                   "user" => "deploy"
                 },
                 %{ctx | tool_call_id: "call-open-device-3"}
               )
             )

    assert reason =~ "econnrefused"

    assert_raise RuntimeError, fn ->
      SSH.open(%{"tailcat" => "tcabc", "via_device_id" => "dev-gw", "user" => "deploy"}, ctx)
    end
  end

  test "Tailcat servers are reached through the node's gateway with ephemeral keys",
       %{ctx: ctx, root: root} do
    server = daemon(ctx, root)
    peer = tailcat_peer!("127.0.0.1:#{server.port}")
    gateway!(peer.derp_map_url)

    {:ok, session} =
      decode(SSH.open(%{"tailcat" => peer.address, "port" => 22, "user" => "deploy"}, ctx))

    id = session["ssh_session_id"]
    assert session["status"] == "open"
    assert session["host_key"]["status"] == "trusted_on_first_use"
    assert session["output"] =~ "welcome"

    assert {:ok, %{"output" => "echo over tailcat\nover tailcat\n$ "}} =
             write(ctx, id, %{
               "input" => "echo over tailcat",
               "keys" => ["enter"],
               "until_text" => "tailcat\n$ "
             })

    assert {:ok, %{"stdout" => "out\n", "exit_status" => 3}} =
             decode(SSH.exec(%{"ssh_session_id" => id, "command" => "report"}, ctx))

    # The session and the trusted host key name the server's node key, never
    # the address, which carries the pre-shared key.
    host = "tailcat:" <> peer.node_key
    assert {:ok, %{"sessions" => [%{"host" => ^host}]}} = decode(SSH.list(%{}, ctx))
    assert {:ok, %{"hosts" => [%{"name" => ^host}]}} = decode(SSH.known_hosts_list(%{}, ctx))

    # A second session of the Group, open at the same time, gets its own
    # client key; the Group SSH key and the trusted host key still apply.
    {:ok, again} =
      decode(
        SSH.open(
          %{"tailcat" => peer.address, "user" => "deploy"},
          %{ctx | tool_call_id: "call-open-tailcat-2"}
        )
      )

    assert again["status"] == "open"
    assert again["host_key"]["status"] == "known"

    # Only the SSH key and the host keys are stored for the Group.
    {:ok, objects} = S3.list_all(Keys.ctl_group_ssh_prefix(ctx.group_id))

    assert objects |> Enum.map(& &1.key) |> Enum.sort() ==
             Enum.sort([
               Keys.ctl_group_ssh_identity(ctx.group_id),
               Keys.ctl_group_ssh_known_hosts(ctx.group_id)
             ])

    # A server that admits only listed client keys never answers an
    # ephemeral key; the diagnostic says so.
    listed = tailcat_peer!("127.0.0.1:#{server.port}", "nodekey:" <> String.duplicate("ab", 32))
    gateway!(listed.derp_map_url)

    assert {:error, unreachable} =
             decode(
               SSH.open(
                 %{"tailcat" => listed.address, "user" => "deploy"},
                 %{ctx | tool_call_id: "call-open-tailcat-3"}
               )
             )

    assert unreachable["code"] == "tailcat_unreachable"
    assert unreachable["message"] =~ "--allow"

    for {target, code} <- [
          {"tcnotanaddress", "tailcat_invalid_address"},
          {"server.internal", "blocked_destination"}
        ] do
      assert {:error, %{"code" => ^code}} =
               decode(
                 SSH.open(
                   %{"tailcat" => target, "user" => "deploy"},
                   %{ctx | tool_call_id: "call-open-" <> target}
                 )
               )
    end
  end

  test "devices in the Group's tailnet are reached through the Group's node",
       %{ctx: ctx, root: root} do
    server = daemon(ctx, root)
    peer = SalixAgent.TailnetTestPeer.start!("127.0.0.1:#{server.port}")
    {:ok, pending} = SalixAgent.Tailnet.connect(ctx.group_id, %{}, "salix_admin")
    SalixAgent.TailnetTestPeer.approve!(peer, pending["login_url"])
    running = SalixAgent.TailnetTestPeer.await_state!(ctx.group_id, "running")

    {:ok, session} =
      decode(SSH.open(%{"host" => "nas", "via_tailnet" => true, "user" => "deploy"}, ctx))

    id = session["ssh_session_id"]
    assert session["status"] == "open"
    assert session["host_key"]["status"] == "trusted_on_first_use"

    assert {:ok, %{"output" => "echo over tailnet\nover tailnet\n$ "}} =
             write(ctx, id, %{
               "input" => "echo over tailnet",
               "keys" => ["enter"],
               "until_text" => "tailnet\n$ "
             })

    # The trusted host key names the tailnet and the host as typed.
    host = "tailnet:#{running["tailnet"]}:nas"
    assert {:ok, %{"hosts" => [%{"name" => ^host}]}} = decode(SSH.known_hosts_list(%{}, ctx))
    assert {:ok, _} = decode(SSH.close(%{"ssh_session_id" => id}, ctx))

    # The node reaches only its tailnet's peers.
    assert {:error, %{"code" => "tailnet_destination_not_allowed"}} =
             decode(
               SSH.open(
                 %{
                   "host" => "127.0.0.1",
                   "port" => server.port,
                   "via_tailnet" => true,
                   "user" => "deploy"
                 },
                 %{ctx | tool_call_id: "call-open-tailnet-2"}
               )
             )

    assert_raise RuntimeError, fn ->
      SSH.open(
        %{
          "host" => "nas",
          "via_tailnet" => true,
          "via_device_id" => "dev-gw",
          "user" => "deploy"
        },
        ctx
      )
    end
  end

  # A Tailcat server behind a local relay (systems/tailcat-gateway
  # cmd/tailcat-testpeer), forwarding its port 22 to target. A given allow
  # key makes it admit only that client key.
  defp tailcat_peer!(target, allow \\ nil),
    do: start_peer!(["--target", target] ++ if(allow, do: ["--allow", allow], else: []))

  defp start_peer!(args) do
    exe = Path.join(:code.priv_dir(:salix_agent), "tailcat_testpeer")
    source = Path.expand("../../../tailcat-gateway", __DIR__)
    {_, 0} = System.cmd("make", ["-s", "-C", source, "testpeer", "TESTPEER=" <> exe])

    port = Port.open({:spawn_executable, exe}, [:binary, {:line, 65_536}, args: args])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    SystemsRuntime.Proc.receive do
      {^port, {:data, {:eol, line}}} ->
        %{"address" => address, "derp_map_url" => url, "node_key" => key} = Jason.decode!(line)
        %{address: address, derp_map_url: url, node_key: key}
    after
      15_000 -> flunk("the Tailcat test peer did not start")
    end
  end

  # A gateway that trusts the peer's local relay map.
  defp gateway!(derp_map_url) do
    name = :"tailcat_gateway_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    start_supervised!({TailcatGateway, name: name, derp_map_url: derp_map_url}, id: name)
    previous = SystemsRuntime.get_env(:salix_agent, :tailcat_gateway)
    SystemsRuntime.put_env(:salix_agent, :tailcat_gateway, name)
    on_exit(fn -> restore(:salix_agent, :tailcat_gateway, previous) end)
  end

  # Eviction also needs an empty mailbox, so retry after the session exits
  # have reached the actor.
  defp evicted?(_actor, _ref, 0), do: false

  defp evicted?(actor, ref, attempts) do
    # The residency monitor recomputes pressure; hold it high. Clear the CLOCK
    # reference bit, as the residency scan does first.
    :ets.insert(SalixAgent.SessionResidency, {:pressure, :high})
    SalixAgent.SessionResidency.second_chance(actor)
    SystemsRuntime.Proc.send(actor, :residency_evict)

    SystemsRuntime.Proc.receive do
      {:DOWN, ^ref, :process, ^actor, :normal} -> true
    after
      100 -> evicted?(actor, ref, attempts - 1)
    end
  end

  defp session_pid(ctx, id) do
    [{pid, _}] = Registry.lookup(SalixAgent.SSH.Registry, {ctx.agent_id, ctx.session_id, id})
    pid
  end
end
