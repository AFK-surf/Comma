defmodule SalixAgent.Tailnet.Gateway do
  require SystemsClock

  @moduledoc """
  The node's tailnet gateway (`priv/tailnet_gateway`, built from
  `systems/tailnet-gateway`): one Go process per node. It runs one `tsnet`
  node for each Group whose tailnet lease this node holds.

  This server owns the process as a port. It starts it on the first node
  start, in a fresh `0700` directory, and sends the configuration as the
  first frame: the Unix socket path, a random token and a scratch directory.
  The gateway exits when the port closes, so it never outlives the node.

  Port frames from the gateway (`status`, `persist`, `activity`, `stopped`)
  go to the Group's `SalixAgent.Tailnet.Owner`. If the gateway exits, every
  owner hears `{:tailnet_gateway, :down}` and stops; the next dial starts a
  new gateway.

  `dial/6` and `peers/4` run in the caller: they connect to the socket, send
  one request with the owner's run number and read one reply. After a dial
  the socket carries the raw TCP stream. No tailnet data passes through this
  server.

  It also receives `{:config_changed, group_id}` casts from any node and
  forwards them to the local owner of that Group.
  """

  use SystemsRuntime.Server

  require Logger

  alias SalixAgent.Tailnet.Owner

  @frame_limit 262_144
  @request_limit 16_384
  @start_timeout_ms 5_000
  @reply_margin_ms 2_000

  def start_link(opts \\ []) do
    SystemsRuntime.Server.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Start the Group's node with `opts` (hostname, tags, accept_routes, state)."
  def start_node(group_id, run, opts) do
    SystemsClock.call(__MODULE__, {:start_node, group_id, run, opts}, @start_timeout_ms + 1_000)
  catch
    :exit, reason -> {:error, unavailable({:gateway_down, reason})}
  end

  @doc "Stop the Group's node. With `logout`, it first leaves the tailnet."
  def stop_node(group_id, run, logout),
    do:
      SystemsRuntime.Server.cast(
        __MODULE__,
        {:send, %{type: "stop", group_id: group_id, epoch: run, logout: logout}}
      )

  @doc "Answer a `persist` frame."
  def persisted(seq, ok?),
    do: SystemsRuntime.Server.cast(__MODULE__, {:send, %{type: "persisted", seq: seq, ok: ok?}})

  @doc "Tell every node that the Group's settings changed."
  def config_changed(group_id),
    do: GenServer.abcast([node() | Node.list()], __MODULE__, {:config_changed, group_id})

  @doc """
  Dial `host`:`port` in the Group's tailnet through the node run `run`.
  Returns a connected, passive, raw binary socket owned by the caller and the
  gateway's reply (`"addr"`, `"peer"`, `"tailnet"`).
  """
  def dial(group_id, run, host, port, timeout_ms) do
    request(
      %{
        op: "dial",
        group_id: group_id,
        epoch: run,
        host: host,
        port: port,
        timeout_ms: timeout_ms
      },
      timeout_ms,
      fn reply, socket ->
        case :inet.setopts(socket, packet: :raw) do
          :ok ->
            {:ok, socket, reply}

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, unavailable(reason)}
        end
      end
    )
  end

  @doc "One page of the tailnet's peers."
  def peers(group_id, run, cursor, timeout_ms) do
    request(
      %{op: "peers", group_id: group_id, epoch: run, cursor: cursor, timeout_ms: timeout_ms},
      timeout_ms,
      fn reply, socket ->
        :gen_tcp.close(socket)
        {:ok, reply}
      end
    )
  end

  defp request(request, timeout_ms, on_ok) do
    with {:ok, path, token} <- endpoint(),
         {:ok, socket} <- connect(path) do
      body = Jason.encode!(Map.put(request, :token, token))

      with :ok <- :gen_tcp.send(socket, body),
           {:ok, reply} <- :gen_tcp.recv(socket, 0, timeout_ms + @reply_margin_ms),
           {:ok, reply} <- Jason.decode(reply) do
        case reply do
          %{"ok" => true} ->
            on_ok.(reply, socket)

          %{"code" => code, "message" => message} when is_binary(code) and is_binary(message) ->
            :gen_tcp.close(socket)
            {:error, %{"code" => code, "message" => message}}

          other ->
            :gen_tcp.close(socket)
            {:error, unavailable({:bad_reply, other})}
        end
      else
        {:error, reason} ->
          :gen_tcp.close(socket)
          {:error, unavailable(reason)}
      end
    end
  end

  defp endpoint do
    SystemsClock.call(__MODULE__, :endpoint, @start_timeout_ms + 1_000)
  catch
    :exit, reason -> {:error, unavailable({:gateway_down, reason})}
  end

  defp connect(path) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: 4], 2_000) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, unavailable(reason)}
    end
  end

  @doc false
  def unavailable(reason) do
    %{
      "code" => "tailnet_unavailable",
      "message" => "The node's tailnet gateway is not available. Retry shortly.",
      "reason" => inspect(reason)
    }
  end

  # ---- server ------------------------------------------------------------------

  @impl true
  def init(opts) do
    SystemsRuntime.Proc.trap_exit(true)
    {:ok, %{opts: opts, port: nil, dir: nil, path: nil, token: nil}}
  end

  @impl true
  def handle_call(:endpoint, _from, %{port: port} = state) when is_port(port),
    do: {:reply, {:ok, state.path, state.token}, state}

  def handle_call(:endpoint, _from, state),
    do:
      {:reply,
       {:error,
        %{"code" => "tailnet_not_running", "message" => "No tailnet node runs on this node."}},
       state}

  def handle_call({:start_node, group_id, run, opts}, _from, state) do
    case ensure_started(state) do
      {:ok, state} ->
        frame =
          %{
            type: "start",
            group_id: group_id,
            epoch: run,
            hostname: opts.hostname,
            tags: opts.tags,
            accept_routes: opts.accept_routes,
            state: opts.state
          }

        {:reply, command(state, frame), state}

      {:error, reason, state} ->
        Logger.warning("tailnet gateway did not start: #{inspect(reason)}")
        {:reply, {:error, unavailable(reason)}, state}
    end
  end

  @impl true
  def handle_cast({:send, frame}, %{port: port} = state) when is_port(port) do
    _ = command(state, frame)
    {:noreply, state}
  end

  def handle_cast({:send, _frame}, state), do: {:noreply, state}

  def handle_cast({:config_changed, group_id}, state) do
    Owner.config_changed(group_id)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state)
      when byte_size(data) <= @frame_limit do
    case Jason.decode(data) do
      {:ok, %{"group_id" => group_id} = frame} when is_binary(group_id) ->
        Owner.notify(group_id, {:tailnet_gateway, frame})

      _other ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("tailnet gateway exited with status #{status}")
    {:noreply, stopped(state)}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, stopped(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stopped(state)

  defp command(state, frame) do
    true = Port.command(state.port, Jason.encode!(frame))
    :ok
  rescue
    error -> {:error, unavailable(error)}
  end

  defp ensure_started(%{port: port} = state) when is_port(port), do: {:ok, state}

  defp ensure_started(state) do
    dir = Path.join(System.tmp_dir!(), "salix-tailnet-" <> random(8))
    path = Path.join(dir, "gateway.sock")
    token = random(32)
    exe = option(state, :command, Path.join(:code.priv_dir(:salix_agent), "tailnet_gateway"))

    with :ok <- File.mkdir_p(Path.join(dir, "nodes")),
         :ok <- File.chmod(dir, 0o700),
         {:ok, port} <- open_port(exe) do
      config =
        Jason.encode!(%{
          socket: path,
          token: token,
          dir: Path.join(dir, "nodes"),
          # Only tests point the gateway at another coordination server.
          control_url: option(state, :control_url, "")
        })

      state = %{state | port: port, dir: dir, path: path, token: token}
      true = Port.command(port, config)

      SystemsClock.vreceive do
        {^port, {:data, data}} when byte_size(data) <= @request_limit ->
          case Jason.decode(data) do
            {:ok, %{"type" => "ready"}} -> {:ok, state}
            _ -> {:error, {:bad_ready, data}, stopped(state)}
          end

        {^port, {:exit_status, status}} ->
          {:error, {:exit_status, status}, stopped(%{state | port: nil})}
      after
        @start_timeout_ms -> {:error, :start_timeout, stopped(state)}
      end
    else
      {:error, reason} -> {:error, reason, stopped(%{state | dir: dir})}
    end
  end

  defp open_port(exe) do
    if File.exists?(exe) do
      {:ok, Port.open({:spawn_executable, exe}, [:binary, :exit_status, {:packet, 4}])}
    else
      {:error, {:missing_executable, exe}}
    end
  rescue
    error -> {:error, error}
  end

  defp stopped(state) do
    if is_port(state.port) do
      try do
        Port.close(state.port)
      rescue
        _ -> :ok
      end

      Owner.notify_all({:tailnet_gateway, :down})
    end

    if state.dir, do: File.rm_rf(state.dir)
    %{state | port: nil, dir: nil, path: nil, token: nil}
  end

  # Start options only; tests pass them. Production uses the defaults.
  defp option(state, key, default), do: Keyword.get(state.opts, key, default)

  defp random(bytes),
    do: bytes |> SystemsRuntime.Proc.random_bytes() |> Base.url_encode64(padding: false)
end
