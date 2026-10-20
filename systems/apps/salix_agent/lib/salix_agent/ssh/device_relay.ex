defmodule SalixAgent.SSH.DeviceRelay do
  require SystemsRuntime.Proc

  @moduledoc """
  An SSH byte stream through a gateway device: the gateway's connector dials
  the host on its own network (`lan_tcp_dial`) and this process relays the
  connection's bytes over the connector socket.

  `dial/5` runs in the caller and returns one end of a loopback socket pair,
  in the raw list mode OTP ssh requires, for `:ssh.connect/3`. One relay
  process per connection owns the other end. It exchanges frames with the
  connector's socket owner (`SalixWeb.ConnectorSocket`), which may run on
  another node:

    * `{:env_tunnel_send, relay, id, frame}` to the owner;
    * `{:env_tunnel_frame, id, frame}` from the owner.

  A frame is `%{"channel" => "tcp", "data" => base64}`, `%{"channel" =>
  "tcp", "eof" => true}` or `%{"channel" => "tcp_ack", "seq" => n}`, where
  `n` counts the bytes written so far. Each side keeps at most one window of
  unacknowledged bytes in flight, so neither the owner nor the connector
  buffers more than that. The relay stops reading its socket while a full
  window is unacknowledged. Frames and window follow the dial result's
  `max_frame` and `window` (a T-Circle has smaller ones than salix-connect).

  The tunnel ends when the SSH connection closes its socket, the connector
  sends eof, or the socket owner exits. The relay keeps no durable state.
  """

  use SystemsRuntime.Server

  alias SalixAgent.EnvDispatch

  @max_frame 32 * 1024
  @default_window 512 * 1024
  @accept_timeout_ms 5_000

  @doc """
  Dial `host`:`port` from the gateway `target`. Returns a connected socket
  owned by the caller and the gateway's dial result.
  """
  @spec dial(String.t(), EnvDispatch.target(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, :gen_tcp.socket(), map()} | {:error, term()}
  def dial(agent_id, target, host, port, timeout_ms) do
    with {:ok, client, local} <- socket_pair() do
      {:ok, relay} = SystemsRuntime.Server.start(__MODULE__, :ok)
      :ok = :gen_tcp.controlling_process(local, relay)
      open = {:open, agent_id, target, %{host: host, port: port, timeout_ms: timeout_ms}, local}

      try do
        SystemsClock.call(relay, open, timeout_ms + 5_000)
      catch
        :exit, reason -> {:error, {:relay_exit, reason}}
      end
      |> case do
        {:ok, result} ->
          {:ok, client, result}

        {:error, reason} ->
          :gen_tcp.close(client)
          {:error, reason}
      end
    end
  end

  # A loopback pair: OTP ssh needs a gen_tcp socket, and the relay needs the
  # other end. The accepted peer must be our own client socket. The tailnet
  # relay uses it too.
  @doc false
  def socket_pair do
    with {:ok, listen} <-
           :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, backlog: 4]) do
      try do
        with {:ok, port} <- :inet.port(listen),
             {:ok, client} <-
               :gen_tcp.connect({127, 0, 0, 1}, port, [:list, active: false, packet: :raw], 2_000) do
          case accept_peer(listen, client) do
            {:ok, local} ->
              {:ok, client, local}

            error ->
              :gen_tcp.close(client)
              error
          end
        end
      after
        :gen_tcp.close(listen)
      end
    end
  end

  defp accept_peer(listen, client) do
    with {:ok, client_name} <- :inet.sockname(client),
         {:ok, local} <- :gen_tcp.accept(listen, @accept_timeout_ms) do
      case :inet.peername(local) do
        {:ok, ^client_name} ->
          {:ok, local}

        _other ->
          :gen_tcp.close(local)
          accept_peer(listen, client)
      end
    end
  end

  @impl true
  def init(:ok), do: {:ok, nil}

  @impl true
  def handle_call({:open, agent_id, target, dial, socket}, _from, nil) do
    id = "tun_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(12), padding: false)

    params = %{
      "host" => dial.host,
      "port" => dial.port,
      "timeout_seconds" => max(div(dial.timeout_ms, 1_000), 1)
    }

    case EnvDispatch.open_tunnel(agent_id, target, id, params, SystemsRuntime.Proc.self()) do
      {:ok, %{owner: owner, result: result}} when SystemsRuntime.Proc.is_process(owner) ->
        SystemsRuntime.Proc.monitor(owner)
        :ok = :inet.setopts(socket, active: :once)

        state = %{
          id: id,
          owner: owner,
          socket: socket,
          window: window(result),
          max_frame: max_frame(result),
          sent: 0,
          acked: 0,
          received: 0,
          pending: <<>>,
          closing: false
        }

        {:reply, {:ok, result}, state}

      {:error, reason} ->
        :gen_tcp.close(socket)
        {:stop, :normal, {:error, reason}, nil}

      other ->
        :gen_tcp.close(socket)
        {:stop, :normal, {:error, {:unexpected, other}}, nil}
    end
  end

  defp window(%{"window" => window}) when is_integer(window) and window > 0, do: window
  defp window(_result), do: @default_window

  defp max_frame(%{"max_frame" => max}) when is_integer(max) and max > 0, do: min(max, @max_frame)
  defp max_frame(_result), do: @max_frame

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    %{state | pending: state.pending <> data}
    |> flush()
  end

  # Bytes still waiting for window go out before the eof.
  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    flush(%{state | closing: true})
  end

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state) do
    send_frame(state, %{"channel" => "tcp", "eof" => true})
    :gen_tcp.close(socket)
    {:stop, :normal, state}
  end

  def handle_info({:env_tunnel_frame, id, frame}, %{id: id} = state) do
    case frame do
      %{"channel" => "tcp_ack", "seq" => seq}
      when is_integer(seq) and seq > state.acked and seq <= state.sent ->
        flush(%{state | acked: seq})

      %{"channel" => "tcp", "eof" => true} ->
        :gen_tcp.close(state.socket)
        {:stop, :normal, state}

      %{"channel" => "tcp", "data" => data} when is_binary(data) ->
        write(state, data)

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state) do
    :gen_tcp.close(state.socket)
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # The connector keeps its own window, so a write never queues more than
  # one window here.
  defp write(state, data) do
    with {:ok, bytes} <- Base.decode64(data),
         :ok <- :gen_tcp.send(state.socket, bytes) do
      received = state.received + byte_size(bytes)
      send_frame(state, %{"channel" => "tcp_ack", "seq" => received})
      {:noreply, %{state | received: received}}
    else
      _error ->
        send_frame(state, %{"channel" => "tcp", "eof" => true})
        :gen_tcp.close(state.socket)
        {:stop, :normal, state}
    end
  end

  # Send pending bytes while the window allows, never more than one window
  # unacknowledged; read the socket again only when nothing is pending.
  defp flush(%{pending: pending} = state) when pending != <<>> do
    case min(min(state.max_frame, state.window - (state.sent - state.acked)), byte_size(pending)) do
      size when size > 0 ->
        <<chunk::binary-size(^size), rest::binary>> = pending
        send_frame(state, %{"channel" => "tcp", "data" => Base.encode64(chunk)})
        flush(%{state | pending: rest, sent: state.sent + size})

      _full ->
        {:noreply, state}
    end
  end

  defp flush(%{closing: true} = state) do
    send_frame(state, %{"channel" => "tcp", "eof" => true})
    {:stop, :normal, state}
  end

  defp flush(state) do
    :inet.setopts(state.socket, active: :once)
    {:noreply, state}
  end

  defp send_frame(state, frame),
    do:
      SystemsRuntime.Proc.send(
        state.owner,
        {:env_tunnel_send, SystemsRuntime.Proc.self(), state.id, frame}
      )
end
