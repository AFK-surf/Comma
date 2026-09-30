defmodule SalixAgent.SSH.TailcatGateway do
  @moduledoc """
  The node's Tailcat gateway (`priv/tailcat_gateway`, built from
  `systems/tailcat-gateway`): one Go process per node for every outbound SSH
  connection over Tailcat, never one per session.

  This server owns the process as a port. It starts it on the first dial, in
  a fresh `0700` directory, and sends the configuration as the first frame:
  the Unix socket path, a random token and the trusted DERP map URL. The
  gateway exits when the port closes, so it never outlives the node. If it
  exits, the next dial starts a new one; its SSH connections have already
  ended with it.

  `dial/3` runs in the caller. The caller connects to the socket, sends one
  dial request and reads one reply. The socket then carries the SSH byte
  stream to the Tailcat server's port, and the caller hands it to
  `:ssh.connect/3`. No SSH data passes through this server.

  The gateway keeps relays to the trusted DERP map (`derp_map_url` under
  `:salix_agent, :tailcat`; default Tailscale's). Each connection gets its
  own Tailcat client with a new ephemeral node key. No Tailcat key is stored
  or shared: the Agents of one Group run on many nodes at once, and two peers
  with one node key would replace each other at the server. There is no
  node-wide connection limit; the SSH session limit per Agent session applies.
  """

  use GenServer

  require Logger

  @frame_limit 16_384
  @start_timeout_ms 5_000
  @reply_margin_ms 2_000

  @type dial_error :: %{String.t() => term()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The gateway server the SSH connections use."
  def server, do: Application.get_env(:salix_agent, :tailcat_gateway, __MODULE__)

  @doc """
  Dial `port` on the Tailcat server that `target` (a tailcat address or a DNS
  name with a `tailcat=` TXT record) names, with a new ephemeral node key.

  Returns a connected, passive, list-mode socket owned by the caller and the
  server's `nodekey:` text.
  """
  @spec dial(String.t(), pos_integer(), pos_integer()) ::
          {:ok, :gen_tcp.socket(), String.t()} | {:error, dial_error()}
  def dial(target, port, timeout_ms) do
    with {:ok, path, token} <- endpoint(),
         {:ok, socket} <- connect(path) do
      request =
        Jason.encode!(%{
          token: token,
          address: target,
          port: port,
          timeout_ms: timeout_ms
        })

      with :ok <- :gen_tcp.send(socket, request),
           {:ok, reply} <- :gen_tcp.recv(socket, 0, timeout_ms + @reply_margin_ms),
           {:ok, reply} <- Jason.decode(reply) do
        handle_reply(reply, socket)
      else
        {:error, reason} ->
          :gen_tcp.close(socket)
          {:error, unavailable(reason)}
      end
    end
  end

  defp endpoint do
    GenServer.call(server(), :endpoint, @start_timeout_ms + 1_000)
  catch
    :exit, reason -> {:error, unavailable({:gateway_down, reason})}
  end

  defp connect(path) do
    # 4-byte framing for the request and reply only; `handle_reply/2` switches
    # to raw list mode, which OTP ssh requires of a socket it takes over.
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: 4], 2_000) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, unavailable(reason)}
    end
  end

  defp handle_reply(%{"ok" => true, "server_node_key" => "nodekey:" <> _ = key}, socket) do
    case :inet.setopts(socket, [:list, packet: :raw]) do
      :ok ->
        {:ok, socket, key}

      {:error, reason} ->
        :gen_tcp.close(socket)
        {:error, unavailable(reason)}
    end
  end

  defp handle_reply(%{"code" => code, "message" => message}, socket)
       when is_binary(code) and is_binary(message) do
    :gen_tcp.close(socket)
    {:error, %{"code" => code, "message" => message}}
  end

  defp handle_reply(reply, socket) do
    :gen_tcp.close(socket)
    {:error, unavailable({:bad_reply, reply})}
  end

  defp unavailable(reason) do
    %{
      "code" => "tailcat_unavailable",
      "message" => "The node's Tailcat gateway is not available. Retry shortly.",
      "reason" => inspect(reason)
    }
  end

  # ---- server ------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{opts: opts, port: nil, dir: nil, path: nil, token: nil}}
  end

  @impl true
  def handle_call(:endpoint, _from, %{port: port} = state) when is_port(port),
    do: {:reply, {:ok, state.path, state.token}, state}

  def handle_call(:endpoint, _from, state) do
    case start_gateway(state) do
      {:ok, state} ->
        {:reply, {:ok, state.path, state.token}, state}

      {:error, reason, state} ->
        Logger.warning("tailcat gateway did not start: #{inspect(reason)}")
        {:reply, {:error, unavailable(reason)}, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("tailcat gateway exited with status #{status}")
    {:noreply, stopped(state)}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, stopped(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stopped(state)

  defp start_gateway(state) do
    dir = Path.join(System.tmp_dir!(), "salix-tailcat-" <> random(8))
    path = Path.join(dir, "gateway.sock")
    token = random(32)
    exe = option(state, :command, Path.join(:code.priv_dir(:salix_agent), "tailcat_gateway"))

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, port} <- open_port(exe) do
      config =
        Jason.encode!(%{
          socket: path,
          token: token,
          derp_map_url: option(state, :derp_map_url, nil) || ""
        })

      state = %{state | port: port, dir: dir, path: path, token: token}
      true = Port.command(port, config)

      receive do
        {^port, {:data, data}} when byte_size(data) <= @frame_limit ->
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
    end

    if state.dir, do: File.rm_rf(state.dir)
    %{state | port: nil, dir: nil, path: nil, token: nil}
  end

  # Configuration: start options first (tests), then the application env.
  defp option(state, key, default) do
    Keyword.get_lazy(state.opts, key, fn ->
      :salix_agent |> Application.get_env(:tailcat, []) |> Keyword.get(key, default)
    end)
  end

  defp random(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
