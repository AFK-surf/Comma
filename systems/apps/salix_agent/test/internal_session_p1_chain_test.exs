defmodule SalixAgent.InternalSessionP1ChainTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixAgent.{Fleet, InternalSession, InternalSessionStore, Server}
  alias SalixStore.Repo

  @session "ses1_0000000000000000946"
  @first_output "p1-first-shell-effect-landed"
  @second_output "p1-second-shell-effect-landed"

  defmodule ScriptProvider do
    @behaviour SalixAgent.LLM

    def complete(messages, _tools) do
      owner = SystemsRuntime.fetch_env!(:salix_agent, :p1_chain_owner)
      contents = Enum.map_join(messages, "\n", &to_string(&1[:content] || &1["content"] || ""))

      cond do
        String.contains?(contents, "resume after ownership transfer") ->
          send(owner, {:p1_provider, :resumed, messages})

          {:assistant, "recovered once",
           [%{id: "p1-done", name: "end_turn", args: %{"outcome" => "done"}}]}

        String.contains?(contents, "p1-first-shell-effect-landed") and
            String.contains?(contents, "p1-second-shell-effect-landed") ->
          send(owner, {:p1_provider, :tools_settled, messages})

          {:assistant, "both effects settled; waiting",
           [
             %{
               id: "p1-wait",
               name: "wait_for",
               args: %{"reason" => "ownership transfer", "timeout_seconds" => 300}
             }
           ]}

        String.contains?(contents, "p1-tool-one") or String.contains?(contents, "p1-tool-two") ->
          {:assistant, "waiting for the other local effect",
           [
             %{
               id: "p1-effects-pending-#{SystemsRuntime.Proc.unique_integer([:positive])}",
               name: "wait_for",
               args: %{"reason" => "remaining local effect", "timeout_seconds" => 300}
             }
           ]}

        true ->
          send(owner, {:p1_provider, :accepted_input, self(), messages})

          receive do
            :run_p1_tools ->
              {:assistant, "run two local effects",
               [
                 shell("p1-tool-one", "one"),
                 shell("p1-tool-two", "two")
               ]}
          end
      end
    end

    defp shell(id, effect) do
      %{
        id: id,
        name: "call",
        args: %{
          "tool" => "env.exec",
          "params" => %{
            "device_id" => "p1-local-device",
            "environment" => "p1-local-shell",
            "command" => effect,
            "description" => "Record local effect"
          }
        }
      }
    end
  end

  # The device transport is scripted; each env.exec crosses a real local child
  # process boundary. The append file observes replay independently of SQL.
  defmodule LocalShell do
    def list_devices(_, _), do: {:ok, %{devices: [], next_cursor: nil}}
    def list_envs(_), do: {:ok, []}

    def exec(_, %{device_id: "p1-local-device", environment_id: "p1-local-shell"}, command, _) do
      file = SystemsRuntime.fetch_env!(:salix_agent, :p1_chain_effects)

      output =
        case command do
          "one" -> "p1-first-shell-effect-landed"
          "two" -> "p1-second-shell-effect-landed"
        end

      script = "printf '#{command}\\n' >> \"$P1_EFFECTS\"; printf '#{output}'"
      {output, exit_code} = System.cmd("/bin/sh", ["-c", script], env: [{"P1_EFFECTS", file}])
      {:ok, %{"output" => output, "exit_code" => exit_code}}
    end
  end

  defmodule UnavailableS3 do
    for {name, arity} <- [
          get: 2,
          put: 3,
          head: 1,
          list: 2,
          delete: 2,
          stream: 2,
          put_stream: 3,
          multipart_create: 2,
          multipart_upload_part: 4,
          multipart_complete: 3,
          multipart_abort: 2,
          multipart_uploads: 2
        ] do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)) do
        [key | _] = [unquote_splicing(args)]
        table = SystemsRuntime.fetch_env!(:salix_agent, :p1_chain_s3_calls)

        :ets.insert(
          table,
          {SystemsRuntime.Proc.unique_integer([:positive, :monotonic]), unquote(name), key}
        )

        {:error, :unavailable}
      end
    end
  end

  # All real Repo connections use this local transport. Only a frontend write
  # containing the first shell result arms its connection. Drop its actual
  # server COMMIT completion once; every other connection/reply passes through.
  defmodule CommitReplyProxy do
    def start(upstream_port, marker, owner) do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

      {:ok, {_, port}} = :inet.sockname(listener)
      caller = self()

      acceptor =
        spawn(fn ->
          table = :ets.new(__MODULE__, [:public, :set])
          send(caller, {:p1_proxy_table, table})
          accept(listener, upstream_port, marker, owner, table)
        end)

      receive do
        {:p1_proxy_table, table} ->
          %{port: port, listener: listener, acceptor: acceptor, table: table}
      end
    end

    def stop(proxy) do
      :gen_tcp.close(proxy.listener)
      for {{:relay, pid}, _} <- :ets.tab2list(proxy.table), do: Process.exit(pid, :kill)
      Process.exit(proxy.acceptor, :kill)
    end

    defp accept(listener, port, marker, owner, table) do
      case :gen_tcp.accept(listener) do
        {:ok, client} ->
          relay = spawn(__MODULE__, :serve, [port, marker, owner, table])

          :ets.insert(table, {{:relay, relay}, true})
          :ok = :gen_tcp.controlling_process(client, relay)
          send(relay, {:client, client})
          accept(listener, port, marker, owner, table)

        {:error, :closed} ->
          receive do
            :stop -> :ok
          end
      end
    end

    def serve(port, marker, owner, table) do
      receive do
        {:client, socket} -> connect(socket, port, marker, owner, table)
      end
    end

    defp connect(client, port, marker, owner, table) do
      {:ok, upstream} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: :once])
      :inet.setopts(client, active: :once)
      relay(client, upstream, marker, owner, table, false, <<>>, <<>>)
    end

    defp relay(client, upstream, marker, owner, table, armed, sent, pending) do
      receive do
        {:tcp, ^client, bytes} ->
          scan = sent <> bytes
          matched = :binary.match(scan, marker) != :nomatch

          if not armed and matched and :ets.insert_new(table, {:outage_started, true}) do
            # The matching result write cannot execute before this boundary is released.
            send(owner, {:p1_result_write_held, self()})

            receive do
              :write_result -> :ok
            end
          end

          :ok = :gen_tcp.send(upstream, bytes)
          armed = armed or matched
          keep = min(byte_size(scan), byte_size(marker) - 1)
          sent = binary_part(scan, byte_size(scan) - keep, keep)
          :inet.setopts(client, active: :once)
          relay(client, upstream, marker, owner, table, armed, sent, pending)

        {:tcp, ^upstream, bytes} ->
          case forward(pending <> bytes, client, armed, table) do
            :committed ->
              :gen_tcp.close(upstream)
              send(owner, {:p1_commit_reply_dropped, self()})

              receive do
                :close_client -> :gen_tcp.close(client)
              end

            pending ->
              :inet.setopts(upstream, active: :once)
              relay(client, upstream, marker, owner, table, armed, sent, pending)
          end

        {:tcp_closed, _} ->
          :gen_tcp.close(client)
          :gen_tcp.close(upstream)

        {:tcp_error, _, _} ->
          :gen_tcp.close(client)
          :gen_tcp.close(upstream)
      end
    end

    defp forward(<<tag, size::32, rest::binary>> = bytes, client, armed, table)
         when byte_size(rest) >= size - 4 do
      body_size = size - 4
      <<body::binary-size(^body_size), tail::binary>> = rest

      if armed and tag == ?C and body == "COMMIT\0" and :ets.insert_new(table, {:dropped, true}) do
        :committed
      else
        :ok = :gen_tcp.send(client, binary_part(bytes, 0, size + 1))
        forward(tail, client, armed, table)
      end
    end

    defp forward(bytes, _, _, _), do: bytes
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    env_keys = [
      :llm,
      :env_dispatch,
      :group_context_mod,
      :p1_chain_owner,
      :p1_chain_effects,
      :p1_chain_s3_calls
    ]

    previous = Map.new(env_keys, &{&1, SystemsRuntime.get_env(:salix_agent, &1)})
    previous_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    unless Process.whereis(SalixStore.S3.Fake), do: start_supervised!(SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :llm, ScriptProvider)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, LocalShell)
    SystemsRuntime.put_env(:salix_agent, :p1_chain_owner, self())
    table = :ets.new(__MODULE__, [:public, :ordered_set])
    SystemsRuntime.put_env(:salix_agent, :p1_chain_s3_calls, table)

    dir =
      Path.join(System.tmp_dir!(), "rfc46-p1-#{SystemsRuntime.Proc.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    file = Path.join(dir, "effects")
    SystemsRuntime.put_env(:salix_agent, :p1_chain_effects, file)
    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous_s3)

      for {key, value} <- previous do
        if value == nil,
          do: SystemsRuntime.delete_env(:salix_agent, key),
          else: SystemsRuntime.put_env(:salix_agent, key, value)
      end

      File.rm_rf!(dir)
    end)

    {:ok, agent: agent, effects: file, s3_calls: table}
  end

  @tag timeout: 120_000
  test "input, two tools, lost COMMIT reply, wait and takeover with S3 outage during result commit",
       %{agent: agent, effects: effects, s3_calls: s3_calls} do
    route_repo_through_proxy!()
    {:ok, server} = Fleet.ensure_started(agent, create: false, startup_mode: :passive)
    assert {:parked, first_owner} = Server.info(server)
    first_epoch = first_owner.epoch
    payload = %{session_id: @session, content: "run two effects and wait"}

    assert {:ok, :created} =
             SalixAgent.deliver(agent, payload, source_message_id: "p1-source")

    assert {:ok, accepted} = InternalSessionStore.read(agent, @session)

    assert length(InternalSession.get(accepted, :input_queue)) +
             Enum.count(
               InternalSession.get(accepted, :messages),
               &(&1.content == payload.content)
             ) == 1

    assert {:ok, :duplicate} =
             SalixAgent.deliver(agent, payload, source_message_id: "p1-source", no_wake: true)

    # Provider/configuration preparation may still read its S3-owned facts.
    # Start the outage before the matching result write can execute.
    settle_receive({:p1_provider, :accepted_input, provider, input_messages})
    assert Enum.any?(input_messages, &((&1[:content] || &1["content"]) == payload.content))
    send(provider, :run_p1_tools)
    settle_receive({:p1_result_write_held, writer})
    SystemsRuntime.put_env(:salix_store, :s3_backend, UnavailableS3)
    send(writer, :write_result)

    settle_receive({:p1_commit_reply_dropped, blocked_connection})

    # PostgreSQL completed the first async terminal COMMIT and its reply was
    # discarded. Keep that socket pending until an independent PG read sees
    # the canonical result, before the next activation's live config reads.
    state = read!(agent)

    first_results =
      InternalSession.get(state, :async_results)
      |> Enum.filter(&(&1["tool_call_id"] == "p1-tool-one"))

    assert [%{"status" => "completed", "result" => %{"content" => result}}] = first_results
    assert String.contains?(result, @first_output)
    assert Enum.count(effects(effects), &(&1 == "one")) == 1

    refute Enum.any?(:ets.tab2list(s3_calls), fn {_order, _operation, key} ->
             key in [
               SalixStore.Keys.agent_state(agent),
               SalixStore.Keys.ctl_agent(agent),
               SalixStore.Keys.agent_session_birth(agent, @session)
             ] or
               String.starts_with?(
                 key,
                 SalixStore.Keys.agent_internal_runtime_sessions_prefix(agent)
               )
           end)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    send(blocked_connection, :close_client)

    settle_receive({:p1_provider, :tools_settled, settled_messages})

    assert Enum.any?(
             settled_messages,
             &String.contains?(to_string(&1[:content] || &1["content"] || ""), @first_output)
           )

    assert Enum.any?(
             settled_messages,
             &String.contains?(to_string(&1[:content] || &1["content"] || ""), @second_output)
           )

    assert settle_until(fn -> InternalSession.derived_state(read!(agent)) == :waiting end)
    wait = InternalSession.wait(read!(agent))
    assert wait["reason"] == "ownership transfer"
    assert effects(effects) == ["one", "two"]

    tool_results =
      InternalSession.get(read!(agent), :messages) |> Enum.filter(&(&1.role == "tool"))

    assert tool_results
           |> Enum.filter(&(&1.tool_call_id in ["p1-tool-one", "p1-tool-two"]))
           |> Enum.map(& &1.tool_call_id) == ["p1-tool-one", "p1-tool-two"]

    assert Enum.any?(tool_results, &(&1.tool_call_id == "p1-wait"))

    terminals =
      InternalSession.get(read!(agent), :async_results)
      |> Enum.filter(&(&1["tool_call_id"] in ["p1-tool-one", "p1-tool-two"]))

    assert Enum.sort(Enum.map(terminals, &{&1["tool_call_id"], &1["status"]})) ==
             [{"p1-tool-one", "completed"}, {"p1-tool-two", "completed"}]

    # A new root claim supplies a new epoch and new Session owner. The wait
    # must survive the process boundary before fresh input resumes the kernel.
    :ok = Fleet.stop_existing(agent)
    {:ok, new_server} = Fleet.ensure_started(agent, create: false, startup_mode: :passive)
    assert {:parked, new_owner} = Server.info(new_server)
    assert new_owner.epoch > first_epoch
    assert InternalSession.wait(read!(agent))["wait_id"] == wait["wait_id"]

    assert {:ok, :created} =
             SalixAgent.deliver(
               agent,
               %{session_id: @session, content: "resume after ownership transfer"},
               source_message_id: "p1-resume"
             )

    settle_receive({:p1_provider, :resumed, _messages})

    assert settle_until(fn ->
             state = read!(agent)

             InternalSession.wait(state) == nil and InternalSession.status(state) == :idle and
               InternalSession.derived_state(state) not in [:queued, :active] and
               Enum.any?(InternalSession.get(state, :messages), &(&1.content == "recovered once"))
           end)

    assert {:ok, :duplicate} =
             SalixAgent.deliver(agent, payload, source_message_id: "p1-source", no_wake: true)

    assert effects(effects) == ["one", "two"]
    state = read!(agent)

    assert Enum.count(InternalSession.get(state, :messages), &(&1.content == payload.content)) ==
             1

    assert InternalSession.last_ack_message_id(state) > 0
  end

  defp effects(path), do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.sort()

  defp read!(agent) do
    {:ok, state} = InternalSessionStore.read(agent, @session)
    state
  end

  defp route_repo_through_proxy! do
    config = Repo.config()
    proxy = CommitReplyProxy.start(config[:port], @first_output, self())
    managed? = Enum.any?(Supervisor.which_children(SalixStore.Supervisor), &(elem(&1, 0) == Repo))

    if managed?,
      do: Supervisor.terminate_child(SalixStore.Supervisor, Repo),
      else: Supervisor.stop(Repo)

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
      SalixAgent.TestSupport.stop_all_agents()
      if pid = Process.whereis(Repo), do: Supervisor.stop(pid)
      CommitReplyProxy.stop(proxy)

      if managed? do
        {:ok, _} = Supervisor.restart_child(SalixStore.Supervisor, Repo)
      else
        {:ok, original} = Repo.start_link(config)
        Process.unlink(original)
      end

      Repo.query!("SELECT 1")
    end)

    {:ok, repo} =
      Repo.start_link(
        Keyword.merge(config, hostname: "127.0.0.1", port: proxy.port, pool_size: 2, ssl: false)
      )

    Process.unlink(repo)
    Repo.query!("SELECT 1")
    proxy
  end
end
