defmodule SalixAgent.Tailnet.Relay do
  @moduledoc """
  A tailnet connection for a caller on a node that does not own the Group's
  tailnet node.

  `dial/6` runs in the caller. It makes a loopback socket pair and starts a
  pump that owns one end; the caller gets the other end. On the owner node,
  `open/6` dials the gateway and starts a second pump that owns the gateway
  socket. The two pumps exchange bytes over Erlang distribution:

    * `{:tailnet_relay, pump, {:data, binary}}`;
    * `{:tailnet_relay, pump, {:ack, bytes}}`, where `bytes` counts the bytes
      written so far;
    * `{:tailnet_relay, pump, :eof}`.

  Each pump keeps at most one window of unacknowledged bytes in flight and
  stops reading its socket while the window is full. The connection ends when
  either socket closes or either pump exits. Nothing is durable.
  """

  use SystemsRuntime.Server

  alias SalixAgent.SSH.DeviceRelay
  alias SalixAgent.Tailnet.Gateway

  @max_frame 32 * 1024
  @window 512 * 1024

  @doc """
  Dial through the owner `owner_node`. Returns a passive raw binary socket
  owned by the caller and the gateway's reply.
  """
  def dial(owner_node, group_id, host, port, timeout_ms) do
    with {:ok, client, local} <- DeviceRelay.socket_pair() do
      {:ok, near} = SystemsRuntime.Server.start(__MODULE__, local)
      :ok = :gen_tcp.controlling_process(local, near)

      result =
        try do
          :erpc.call(
            owner_node,
            __MODULE__,
            :open,
            [group_id, host, port, timeout_ms, near],
            timeout_ms + 10_000
          )
        catch
          :error, {:erpc, reason} -> {:error, Gateway.unavailable({:owner_unreachable, reason})}
          :exit, reason -> {:error, Gateway.unavailable({:owner_unreachable, reason})}
        end

      case result do
        {:ok, far, reply} ->
          SystemsRuntime.Server.cast(near, {:peer, far})
          :ok = :inet.setopts(client, [:binary, packet: :raw])
          {:ok, client, reply}

        {:error, error} ->
          SystemsRuntime.Server.stop(near)
          :gen_tcp.close(client)
          {:error, error}
      end
    end
  end

  @doc false
  # On the owner node: dial the local gateway and pump its socket to `near`.
  def open(group_id, host, port, timeout_ms, near) do
    with {:ok, socket, reply} <- SalixAgent.Tailnet.local_dial(group_id, host, port, timeout_ms) do
      {:ok, far} = SystemsRuntime.Server.start(__MODULE__, socket)
      :ok = :gen_tcp.controlling_process(socket, far)
      SystemsRuntime.Server.cast(far, {:peer, near})
      {:ok, far, reply}
    end
  end

  @impl true
  def init(socket) do
    {:ok,
     %{socket: socket, peer: nil, sent: 0, acked: 0, received: 0, pending: <<>>, closing: false}}
  end

  @impl true
  def handle_cast({:peer, peer}, %{peer: nil} = state), do: {:noreply, adopt(state, peer)}
  def handle_cast({:peer, _peer}, state), do: {:noreply, state}

  # The far pump can send before the dial result reaches the near one (an
  # SSH server speaks first), so the near pump adopts its first sender.
  defp adopt(state, peer) do
    SystemsRuntime.Proc.monitor(peer)
    :ok = :inet.setopts(state.socket, [:binary, packet: :raw, active: :once])
    %{state | peer: peer}
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state),
    do: flush(%{state | pending: state.pending <> data})

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: flush(%{state | closing: true})

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state) do
    send_peer(state, :eof)
    {:stop, :normal, state}
  end

  def handle_info({:tailnet_relay, peer, _message} = relayed, %{peer: nil} = state),
    do: handle_info(relayed, adopt(state, peer))

  def handle_info({:tailnet_relay, peer, message}, %{peer: peer} = state) do
    case message do
      {:data, bytes} when is_binary(bytes) ->
        case :gen_tcp.send(state.socket, bytes) do
          :ok ->
            received = state.received + byte_size(bytes)
            send_peer(state, {:ack, received})
            {:noreply, %{state | received: received}}

          {:error, _} ->
            send_peer(state, :eof)
            {:stop, :normal, state}
        end

      {:ack, bytes} when is_integer(bytes) and bytes > state.acked and bytes <= state.sent ->
        flush(%{state | acked: bytes})

      :eof ->
        {:stop, :normal, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, peer, _reason}, %{peer: peer} = state),
    do: {:stop, :normal, state}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: :gen_tcp.close(state.socket)

  defp flush(%{pending: pending} = state) when pending != <<>> do
    case min(min(@max_frame, @window - (state.sent - state.acked)), byte_size(pending)) do
      size when size > 0 ->
        <<chunk::binary-size(^size), rest::binary>> = pending
        send_peer(state, {:data, chunk})
        flush(%{state | pending: rest, sent: state.sent + size})

      _full ->
        {:noreply, state}
    end
  end

  defp flush(%{closing: true} = state) do
    send_peer(state, :eof)
    {:stop, :normal, state}
  end

  defp flush(state) do
    :inet.setopts(state.socket, active: :once)
    {:noreply, state}
  end

  defp send_peer(%{peer: nil}, _message), do: :ok

  defp send_peer(state, message),
    do:
      SystemsRuntime.Proc.send(state.peer, {:tailnet_relay, SystemsRuntime.Proc.self(), message})
end
