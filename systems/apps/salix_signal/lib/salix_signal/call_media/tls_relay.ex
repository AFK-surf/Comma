defmodule SalixSignal.CallMedia.TLSRelay do
  @moduledoc """
  A call-local TURN-over-TLS adapter for Signal calls.

  ExICE 0.16 and ExTURN 0.2 support UDP TURN only. ExTURN still owns TURN
  authentication, allocation, permissions, channels and refresh. This adapter
  carries its datagrams over OTP TLS, with the STUN and ChannelData stream
  framing from RFC 8656 sections 6.2 and 11.5. It does not decode call audio.

  One loopback socket and one TLS connection serve one call. The first local
  ICE socket pins the peer. Other local sockets cannot mix allocations on
  that TLS connection. Each call uses only this relay.

  The authenticated Signal relay response supplies the TLS hostname. OTP
  checks its certificate against the system CA roots and that hostname.
  A failed check closes this path before any TURN credentials are sent.
  This prevents a network attacker from impersonating the advertised relay.
  The caller's lifetime owns the adapter. Buffers, each drain and network
  waits are bounded. Status reports exclude TURN packets and call data.
  """

  use GenServer, restart: :temporary
  require Logger

  @loopback {127, 0, 0, 1}
  @max_datagram 65_507
  @max_buffer 2 * 65_556
  @frames_per_drain 64

  @doc "Selects one TLS relay. Runs in the caller, outside the media supervisor."
  def prepare(servers, opts \\ []) do
    target =
      Enum.find_value(servers, fn server ->
        Enum.find_value(List.wrap(server.urls), fn url ->
          case ExSTUN.URI.parse(url) do
            {:ok, %{scheme: :turns, host: host, port: port}} -> {server, host, port}
            _ -> nil
          end
        end)
      end)

    case target do
      nil ->
        {:error, :turn_tls_unavailable}

      {server, host, port} ->
        case start([owner: self(), host: host, port: port] ++ opts) do
          {:ok, relay} ->
            local = %{server | urls: [GenServer.call(relay, :url)]}
            {:ok, [local], relay}

          {:error, _reason} ->
            Logger.warning("signal TURN TLS connection failed")
            {:error, :turn_tls_connection_failed}
        end
    end
  end

  def start(opts), do: GenServer.start(__MODULE__, opts)

  def stop(nil), do: :ok

  def stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    host = Keyword.fetch!(opts, :host) |> String.to_charlist()

    tls_opts = [
      :binary,
      active: :once,
      verify: :verify_peer,
      cacerts: Keyword.get_lazy(opts, :cacerts, &:public_key.cacerts_get/0),
      server_name_indication: host,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      send_timeout: 2_000,
      send_timeout_close: true
    ]

    case :ssl.connect(host, Keyword.fetch!(opts, :port), tls_opts, 8_000) do
      {:ok, tls} ->
        case :gen_udp.open(0, [:binary, ip: @loopback, active: :once]) do
          {:ok, udp} ->
            {:ok, {@loopback, port}} = :inet.sockname(udp)

            {:ok,
             %{
               tls: tls,
               udp: udp,
               port: port,
               peer: nil,
               buffer: <<>>,
               owner: Process.monitor(Keyword.fetch!(opts, :owner))
             }}

          {:error, reason} ->
            :ssl.close(tls)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:url, _from, state),
    do: {:reply, "turn:127.0.0.1:#{state.port}?transport=udp", state}

  @impl true
  def handle_info({:udp, udp, ip, port, packet}, %{udp: udp} = state) do
    peer = {ip, port}
    state = if state.peer == nil, do: %{state | peer: peer}, else: state

    result =
      if state.peer == peer and byte_size(packet) <= @max_datagram do
        case stream_packet(packet) do
          {:ok, framed} -> :ssl.send(state.tls, framed)
          :error -> {:error, :invalid_frame}
        end
      else
        :ok
      end

    case result do
      :ok ->
        :inet.setopts(udp, active: :once)
        {:noreply, state}

      {:error, _} ->
        {:stop, :normal, state}
    end
  end

  def handle_info({:ssl, tls, bytes}, %{tls: tls} = state) do
    if byte_size(state.buffer) + byte_size(bytes) <= @max_buffer,
      do: drain(%{state | buffer: state.buffer <> bytes}, @frames_per_drain),
      else: {:stop, :normal, state}
  end

  def handle_info(:drain, state), do: drain(state, @frames_per_drain)
  def handle_info({:ssl_closed, tls}, %{tls: tls} = state), do: {:stop, :normal, state}
  def handle_info({:ssl_error, tls, _reason}, %{tls: tls} = state), do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    :ssl.close(state.tls)
    :gen_udp.close(state.udp)
  end

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, :redacted) |> Map.put(:message, :redacted)

  defp drain(state, 0) do
    send(self(), :drain)
    {:noreply, state}
  end

  defp drain(state, budget) do
    case frame(state.buffer) do
      {:ok, packet, rest} ->
        case state.peer do
          {ip, port} -> :gen_udp.send(state.udp, ip, port, packet)
          nil -> :ok
        end

        drain(%{state | buffer: rest}, budget - 1)

      :more ->
        :ssl.setopts(state.tls, active: :once)
        {:noreply, state}

      :error ->
        {:stop, :normal, state}
    end
  end

  # STUN has a 20-byte header. ChannelData has a 4-byte header and TCP/TLS
  # padding to a four-byte boundary. UDP ChannelData needs no padding.
  defp frame(bytes) when byte_size(bytes) < 4, do: :more

  defp frame(<<0::2, _::14, length::16, _::binary>> = bytes) when rem(length, 4) == 0,
    do: take_frame(bytes, 20 + length, 20 + length)

  defp frame(<<1::2, _::14, length::16, _::binary>> = bytes),
    do: take_frame(bytes, 4 + length, 4 + length + rem(4 - rem(length, 4), 4))

  defp frame(_), do: :error

  defp take_frame(_, size, _) when size > @max_datagram, do: :error
  defp take_frame(bytes, _, padded) when byte_size(bytes) < padded, do: :more

  defp take_frame(bytes, size, padded) do
    <<packet::binary-size(^size), _padding::binary-size(^padded - ^size), rest::binary>> = bytes
    {:ok, packet, rest}
  end

  defp stream_packet(<<0::2, _::14, length::16, _::binary>> = bytes)
       when byte_size(bytes) == 20 + length and rem(length, 4) == 0, do: {:ok, bytes}

  defp stream_packet(<<1::2, _::14, length::16, _::binary>> = bytes)
       when byte_size(bytes) >= 4 + length do
    size = 4 + length
    {:ok, binary_part(bytes, 0, size) <> :binary.copy(<<0>>, rem(4 - rem(length, 4), 4))}
  end

  defp stream_packet(_), do: :error
end
