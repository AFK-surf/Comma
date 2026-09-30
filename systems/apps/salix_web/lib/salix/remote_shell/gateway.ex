defmodule Salix.RemoteShell.Gateway do
  @moduledoc """
  CP v3 credit protocol to one local SSH socket. Input is active-once, only
  after a credit; output ACK follows a bounded TCP send. Never reconnect/replay.
  WebSockex owns WebSocket framing and TLS, not handwritten wire code.
  """
  use WebSockex

  def open(handle, device, socket) do
    url =
      Salix.RemoteShell.url(handle, "sockets/connect") <>
        "?" <> URI.encode_query(%{origin: "key:" <> device.key, socket: "temporary-shell"})

    url = String.replace_prefix(url, "https:", "wss:") |> String.replace_prefix("http:", "ws:")

    state = %{
      socket: socket,
      controller: device.controller,
      owner: self(),
      opened: false,
      credit: false,
      ready: false
    }

    opts = [
      extra_headers: [{"authorization", "Bearer " <> handle.token}],
      insecure: false,
      ssl_options: [
        cacerts: :public_key.cacerts_get(),
        verify: :verify_peer,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ],
      socket_connect_timeout: 10_000,
      socket_recv_timeout: 20_000
    ]

    case WebSockex.start(url, __MODULE__, state, opts) do
      {:ok, pid} ->
        case :gen_tcp.controlling_process(socket, pid) do
          :ok ->
            WebSockex.cast(pid, :ready)
            {:ok, pid}

          _ ->
            Process.exit(pid, :kill)
            {:error, :local_transport_failed}
        end

      _ ->
        {:error, :gateway_unavailable}
    end
  end

  @impl true
  def handle_connect(_conn, state) do
    Process.monitor(state.owner)
    {:ok, state}
  end

  @impl true
  def handle_cast(:ready, state) do
    if state.credit, do: :inet.setopts(state.socket, active: :once)
    {:ok, %{state | ready: true}}
  end

  @impl true
  def handle_frame({:text, body}, state) do
    case Jason.decode(body) do
      {:ok, %{"t" => "socketopened", "controller" => key}}
      when not state.opened and key == state.controller ->
        if state.ready, do: :inet.setopts(state.socket, active: :once)
        {:ok, %{state | opened: true, credit: true}}

      {:ok, %{"t" => "credit", "n" => 1}} when state.opened and not state.credit ->
        if state.ready, do: :inet.setopts(state.socket, active: :once)
        {:ok, %{state | credit: true}}

      {:ok, %{"t" => "socketeof"}} when state.opened ->
        :gen_tcp.shutdown(state.socket, :write)
        {:ok, state}

      {:ok, %{"t" => "socketclosed"}} ->
        {:close, state}

      _ ->
        {:close, {1008, "gateway refused or violated protocol"}, state}
    end
  end

  def handle_frame({:binary, bytes}, %{opened: true} = state)
      when byte_size(bytes) in 1..65536 do
    case :gen_tcp.send(state.socket, bytes) do
      :ok -> {:reply, {:text, ~s({"t":"ack"})}, state}
      _ -> {:close, state}
    end
  end

  def handle_frame(_, state), do: {:close, {1008, "invalid gateway frame"}, state}

  @impl true
  def handle_info({:tcp, socket, bytes}, %{socket: socket, credit: true} = state)
      when byte_size(bytes) in 1..65536 do
    {:reply, {:binary, bytes}, %{state | credit: false}}
  end

  def handle_info({:tcp_closed, _}, state), do: {:close, state}
  def handle_info({:tcp_error, _, _}, state), do: {:close, state}
  def handle_info({:DOWN, _, :process, _, _}, state), do: {:close, state}
  def handle_info(_, state), do: {:close, {1008, "unexpected transport input"}, state}

  @impl true
  def handle_disconnect(_, state), do: {:ok, state}

  @impl true
  def terminate(_, state), do: :gen_tcp.close(state.socket)

  @impl true
  def format_status(_, _), do: :redacted_remote_shell
end
