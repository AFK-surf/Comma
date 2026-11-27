defmodule SalixAgent.Colab.Tunnel do
  @moduledoc """
  Pure Elixir WebSocket-over-HTTP/1.1 (`Mint.HTTP` + `Mint.WebSocket`) to
  loopback TCP (`SalixAgent.SSH.DeviceRelay.socket_pair/0`) to OTP `:ssh` bridge
  for a single Google Colab runtime (`vm_id`).

  Rolling deploy safety: `terminate/2` only closes the WebSocket and `:ssh`
  connection; it NEVER calls Colab `unassign`.
  """

  require Logger
  require SystemsClock

  use SystemsRuntime.Server, restart: :temporary

  alias SalixAgent.Colab.{Client, KeyCallback, Tunnels}
  alias SalixAgent.SSH.DeviceRelay

  @ws_ping_interval_ms 25_000
  @upgrade_timeout_ms 25_000
  @ssh_negotiation_timeout_ms 20_000
  @connect_call_timeout_ms 40_000
  @ssh_keepalive %{count_max: 3, interval: 30_000}
  @max_ws_buffer_bytes 4 * 1024 * 1024

  def start_link(opts) do
    vm_id = Keyword.fetch!(opts, :vm_id)

    SystemsRuntime.Server.start_link(__MODULE__, opts,
      name: {:via, SystemsRuntime.Registry, {Tunnels.registry(), vm_id}}
    )
  end

  @doc """
  Ensure the tunnel is connected at `generation` and return its OTP `:ssh`
  connection pid.
  """
  @spec connect(pid(), pos_integer(), map()) :: {:ok, pid()} | {:error, term()}
  def connect(pid, generation, connect_opts) when is_pid(pid) and is_integer(generation) do
    SystemsClock.call(pid, {:connect, generation, connect_opts}, @connect_call_timeout_ms)
  end

  @impl true
  def format_status(status) do
    Map.merge(status, %{state: :colab_tunnel, message: :redacted, log: []})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       vm_id: Keyword.fetch!(opts, :vm_id),
       generation: Keyword.fetch!(opts, :generation),
       status: :idle,
       conn: nil,
       ref: nil,
       ws: nil,
       http_status: nil,
       http_headers: [],
       local_socket: nil,
       ssh_conn: nil,
       ssh_mon: nil,
       ssh_task: nil,
       keypair: nil,
       pin_fn: nil,
       waiters: [],
       upgrade_timer: nil,
       ping_timer: nil,
       awaiting?: false,
       fallback_error: nil
     }}
  end

  @impl true
  def handle_call({:connect, gen, _opts}, _from, %{generation: cur_gen} = state)
      when gen != cur_gen do
    {:reply, {:error, :stale_tunnel}, state}
  end

  def handle_call({:connect, _gen, _opts}, _from, %{status: :connected, ssh_conn: conn} = state) do
    if is_pid(conn) and Process.alive?(conn) do
      {:reply, {:ok, conn}, state}
    else
      {:stop, :normal, {:error, :tunnel_closed}, state}
    end
  end

  def handle_call({:connect, _gen, _opts}, from, %{status: status} = state)
      when status in [:upgrading, :ssh_handshaking] do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call({:connect, _gen, connect_opts}, from, %{status: :idle} = state) do
    proxy_url = Map.get(connect_opts, :proxy_url)
    proxy_token = Map.get(connect_opts, :proxy_token)

    if not is_binary(proxy_url) or proxy_url == "" or not is_binary(proxy_token) or
         proxy_token == "" do
      {:reply, {:error, :not_connected}, state}
    else
      pin_fn = Map.get(connect_opts, :pin_fn)
      transport_opts = Map.get(connect_opts, :transport_opts, [])

      with {:ok, validated} <- Client.validate_proxy_url(proxy_url),
           keypair = KeyCallback.generate_ephemeral_keypair(),
           {:ok, conn} <- open_mint(validated, transport_opts),
           {:ok, conn, ref} <- upgrade_websocket(conn, validated, proxy_token, keypair) do
        timer =
          SystemsClock.send_after(
            SystemsRuntime.Proc.self(),
            :upgrade_timeout,
            @upgrade_timeout_ms
          )

        SystemsClock.awaiting({__MODULE__, state.vm_id})

        {:noreply,
         %{
           state
           | status: :upgrading,
             conn: conn,
             ref: ref,
             keypair: keypair,
             pin_fn: pin_fn,
             waiters: [from],
             upgrade_timer: timer,
             awaiting?: true
         }}
      else
        {:error, reason} ->
          {:stop, :normal, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_info(:upgrade_timeout, %{status: status} = state)
      when status in [:upgrading, :ssh_handshaking] do
    state = fail_waiters(state, {:error, :tunnel_timeout})
    {:stop, :normal, state}
  end

  def handle_info(:upgrade_timeout, state), do: {:noreply, state}

  def handle_info(:ws_ping, %{status: :connected, ws: ws} = state) when not is_nil(ws) do
    case send_ws_frame(state, {:ping, ""}) do
      {:ok, state} ->
        {:noreply, %{state | ping_timer: schedule_ping()}}

      {:error, state} ->
        {:stop, :normal, state}
    end
  end

  def handle_info(:ws_ping, state), do: {:noreply, state}

  def handle_info({:tcp, socket, data}, %{local_socket: socket, ws: ws} = state)
      when not is_nil(ws) do
    case send_ws_frame(state, {:binary, data}) do
      {:ok, state} ->
        :ok = :inet.setopts(socket, active: :once)
        {:noreply, state}

      {:error, state} ->
        {:stop, :normal, state}
    end
  end

  def handle_info(
        {:tcp_closed, socket},
        %{local_socket: socket, status: :ssh_handshaking, ssh_task: task} = state
      )
      when not is_nil(task) do
    # During SSH handshake, OTP :ssh closes `client` right after host-key
    # rejection; wait for `ssh_task` to deliver the exact host_key_mismatch error.
    :gen_tcp.close(socket)

    {:noreply,
     %{state | local_socket: nil, fallback_error: state.fallback_error || :local_socket_closed}}
  end

  def handle_info({:tcp_closed, socket}, %{local_socket: socket} = state) do
    state = fail_waiters(state, {:error, :tunnel_closed})
    {:stop, :normal, state}
  end

  def handle_info(
        {:tcp_error, socket, _reason},
        %{local_socket: socket, status: :ssh_handshaking, ssh_task: task} = state
      )
      when not is_nil(task) do
    :gen_tcp.close(socket)

    {:noreply,
     %{state | local_socket: nil, fallback_error: state.fallback_error || :local_socket_closed}}
  end

  def handle_info({:tcp_error, socket, _reason}, %{local_socket: socket} = state) do
    state = fail_waiters(state, {:error, :tunnel_closed})
    {:stop, :normal, state}
  end

  def handle_info(
        {ref, {:ssh_connected, ssh_result, host_key_result}},
        %{ssh_task: %{ref: ref}} = state
      ) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])
    state = %{state | ssh_task: nil}
    state = cancel_upgrade_timer(state)
    state = clear_awaiting(state)

    case {ssh_result, host_key_result} do
      {{:ok, ssh_conn}, {:ok, _status, _fp}} ->
        mon = SystemsRuntime.Proc.monitor(ssh_conn)

        state = %{
          state
          | status: :connected,
            ssh_conn: ssh_conn,
            ssh_mon: mon,
            ping_timer: schedule_ping()
        }

        state = reply_waiters(state, {:ok, ssh_conn})
        {:noreply, state}

      {{:ok, ssh_conn}, _missing} ->
        safe_close_ssh(ssh_conn)
        state = fail_waiters(state, {:error, :host_key_unverified})
        {:stop, :normal, state}

      {{:error, _reason}, {:error, {:host_key_mismatch, stored, presented}}} ->
        state = fail_waiters(state, {:error, {:host_key_mismatch, stored, presented}})
        {:stop, :normal, state}

      {{:error, _reason}, {:error, reason}} ->
        state = fail_waiters(state, {:error, reason})
        {:stop, :normal, state}

      {{:error, reason}, _} ->
        reply_error =
          if is_nil(reason) and not is_nil(state.fallback_error),
            do: state.fallback_error,
            else: {:ssh_connect_failed, reason}

        state = fail_waiters(state, {:error, reply_error})
        {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ssh_task: %{ref: ref}} = state) do
    state = %{state | ssh_task: nil}
    err = state.fallback_error || {:ssh_handshake_exit, reason}
    state = fail_waiters(state, {:error, err})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{ssh_mon: mon} = state) do
    {:stop, :normal, %{state | ssh_conn: nil, ssh_mon: nil}}
  end

  def handle_info(
        {:ssh_disconnected, _reason},
        %{status: :ssh_handshaking, ssh_task: task} = state
      )
      when not is_nil(task) do
    {:noreply, state}
  end

  def handle_info({:ssh_disconnected, _reason}, state) do
    {:stop, :normal, state}
  end

  def handle_info(message, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        try do
          state = Enum.reduce(responses, %{state | conn: conn}, &handle_mint_response/2)
          {:noreply, state}
        catch
          {:tunnel_stop, reason, next_state} ->
            next_state = fail_waiters(next_state, {:error, reason})
            {:stop, :normal, next_state}
        end

      {:error, conn, reason, _responses} ->
        if state.status == :ssh_handshaking and not is_nil(state.ssh_task) do
          _ = Mint.HTTP.close(conn)
          {:noreply, %{state | conn: nil}}
        else
          state = fail_waiters(%{state | conn: conn}, {:error, {:ws_transport_error, reason}})
          {:stop, :normal, state}
        end

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Rolling deploy safety: close local SSH and WS only; NEVER call Colab unassign!
    _ = cancel_upgrade_timer(state)
    if state.ping_timer, do: SystemsClock.cancel_timer(state.ping_timer)
    _ = clear_awaiting(state)
    _ = fail_waiters(state, {:error, :tunnel_closed})
    if state.ssh_conn, do: safe_close_ssh(state.ssh_conn)
    if state.local_socket, do: :gen_tcp.close(state.local_socket)
    if state.conn, do: Mint.HTTP.close(state.conn)
    :ok
  end

  # ---- Mint HTTP / WebSocket helpers ----

  defp open_mint(validated, extra_transport_opts) do
    http_scheme = if validated.uri.scheme in ["http", "ws"], do: :http, else: :https

    base_transport =
      if http_scheme == :https do
        [
          timeout: 10_000,
          server_name_indication: String.to_charlist(validated.host)
        ] ++ extra_transport_opts
      else
        [timeout: 10_000] ++ extra_transport_opts
      end

    mint_opts = [
      protocols: [:http1],
      hostname: validated.host,
      transport_opts: base_transport
    ]

    validated.addresses
    |> Enum.take(2)
    |> connect_addresses(http_scheme, validated.port, mint_opts, {:error, :connect_failed})
  end

  defp connect_addresses([], _scheme, _port, _opts, last_error), do: last_error

  defp connect_addresses([address | rest], scheme, port, opts, _last_error) do
    case Mint.HTTP.connect(scheme, address, port, opts) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> connect_addresses(rest, scheme, port, opts, {:error, reason})
    end
  end

  defp upgrade_websocket(conn, validated, proxy_token, keypair) do
    ws_scheme = if validated.uri.scheme in ["http", "ws"], do: :ws, else: :wss

    query =
      URI.encode_query([
        {"colab-runtime-proxy-token", proxy_token},
        {"colab-client-agent", "colab-cli"},
        {"colab-client-agent", "ssh-mode-proxy"}
      ])

    path = "/colab/ssh?" <> query

    headers = [
      {"x-colab-ssh-pubkey", keypair.public_key_line},
      {"x-colab-client-agent", "colab-cli"}
    ]

    Mint.WebSocket.upgrade(ws_scheme, conn, path, headers)
  end

  defp handle_mint_response({:status, ref, status}, %{ref: ref} = state) do
    %{state | http_status: status}
  end

  defp handle_mint_response({:headers, ref, headers}, %{ref: ref} = state) do
    %{state | http_headers: state.http_headers ++ headers}
  end

  defp handle_mint_response({:done, ref}, %{ref: ref, status: :upgrading} = state) do
    cond do
      state.http_status == 429 ->
        throw({:tunnel_stop, :ssh_session_limit, state})

      true ->
        case Mint.WebSocket.new(state.conn, ref, state.http_status, state.http_headers) do
          {:ok, conn, ws} ->
            start_ssh_handshake(%{state | conn: conn, ws: ws, http_headers: []})

          {:error, conn, reason} ->
            throw(
              {:tunnel_stop, {:ws_upgrade_failed, state.http_status, reason},
               %{state | conn: conn}}
            )
        end
    end
  end

  defp handle_mint_response({:data, ref, data}, %{ref: ref, ws: ws} = state)
       when not is_nil(ws) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} ->
        fragment_size = if ws.fragment, do: byte_size(elem(ws.fragment, 3)), else: 0

        if byte_size(ws.buffer) + fragment_size > @max_ws_buffer_bytes do
          throw({:tunnel_stop, :ws_buffer_overflow, %{state | ws: ws}})
        end

        Enum.reduce(frames, %{state | ws: ws}, &handle_ws_frame/2)

      {:error, ws, reason} ->
        throw({:tunnel_stop, {:ws_decode_failed, reason}, %{state | ws: ws}})
    end
  end

  defp handle_mint_response(_other, state), do: state

  defp handle_ws_frame({:binary, payload}, %{local_socket: socket} = state)
       when not is_nil(socket) do
    case :gen_tcp.send(socket, payload) do
      :ok ->
        state

      {:error, _reason} ->
        if state.status == :ssh_handshaking and not is_nil(state.ssh_task) do
          :gen_tcp.close(socket)

          %{
            state
            | local_socket: nil,
              fallback_error: state.fallback_error || :local_socket_closed
          }
        else
          throw({:tunnel_stop, :local_socket_closed, state})
        end
    end
  end

  defp handle_ws_frame({:ping, payload}, state) do
    case send_ws_frame(state, {:pong, payload}) do
      {:ok, next_state} -> next_state
      {:error, next_state} -> throw({:tunnel_stop, :ws_send_failed, next_state})
    end
  end

  defp handle_ws_frame({:pong, _payload}, state), do: state

  defp handle_ws_frame({:close, _code, _reason}, state) do
    if state.status == :ssh_handshaking and not is_nil(state.ssh_task) do
      if state.local_socket, do: :gen_tcp.close(state.local_socket)
      %{state | local_socket: nil, fallback_error: state.fallback_error || :ws_closed}
    else
      throw({:tunnel_stop, :ws_closed, state})
    end
  end

  defp handle_ws_frame({:text, payload}, state) do
    Logger.warning("colab tunnel received unexpected text frame",
      bytes: byte_size(payload)
    )

    throw({:tunnel_stop, :unexpected_ws_text_frame, state})
  end

  defp handle_ws_frame(_other, state), do: state

  defp send_ws_frame(%{ws: ws, conn: conn, ref: ref} = state, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, %{state | ws: ws, conn: conn}}
    else
      {:error, %Mint.WebSocket{} = ws, _reason} -> {:error, %{state | ws: ws}}
      {:error, conn, _reason} -> {:error, %{state | conn: conn}}
    end
  end

  # ---- Loopback TCP + OTP :ssh handoff ----

  defp start_ssh_handshake(state) do
    case DeviceRelay.socket_pair() do
      {:ok, client, local} ->
        tunnel_pid = SystemsRuntime.Proc.self()
        keypair = state.keypair
        vm_id = state.vm_id
        generation = state.generation
        pin_fn = state.pin_fn

        task =
          SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
            # Wait until Tunnel transfers `client` socket ownership to us
            SystemsClock.vreceive do
              :socket_ready -> :ok
            after
              5_000 -> exit(:socket_handoff_timeout)
            end

            owner = SystemsRuntime.Proc.self()
            ref = SystemsRuntime.Proc.make_ref()

            key_cb_opts =
              [
                vm_id: vm_id,
                generation: generation,
                owner: owner,
                ref: ref,
                public_key: keypair.public_key,
                private_key: keypair.private_key
              ]
              |> then(fn opts ->
                if is_function(pin_fn, 3), do: Keyword.put(opts, :pin_fn, pin_fn), else: opts
              end)

            ssh_opts = [
              user: ~c"root",
              user_interaction: false,
              silently_accept_hosts: false,
              save_accepted_host: false,
              auth_methods: ~c"publickey",
              pref_public_key_algs: [:"ssh-ed25519"],
              key_cb: {KeyCallback, key_cb_opts},
              connect_timeout: 10_000,
              idle_time: :infinity,
              alive: @ssh_keepalive,
              disconnectfun: fn reason ->
                SystemsRuntime.Proc.send(tunnel_pid, {:ssh_disconnected, reason})
              end
            ]

            ssh_result = :ssh.connect(client, ssh_opts, @ssh_negotiation_timeout_ms)

            host_key_result =
              SystemsClock.vreceive do
                {^ref, {:host_key, res}} -> res
              after
                0 -> nil
              end

            if match?({:error, _}, ssh_result) do
              :gen_tcp.close(client)
            end

            {:ssh_connected, ssh_result, host_key_result}
          end)

        :ok = :gen_tcp.controlling_process(client, task.pid)
        SystemsRuntime.Proc.send(task.pid, :socket_ready)
        # Enable active: :once on `local` only AFTER `client` handoff completes
        :ok = :inet.setopts(local, active: :once)

        %{state | status: :ssh_handshaking, local_socket: local, ssh_task: task}

      {:error, reason} ->
        throw({:tunnel_stop, {:socket_pair_failed, reason}, state})
    end
  end

  defp schedule_ping do
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :ws_ping, @ws_ping_interval_ms)
  end

  defp cancel_upgrade_timer(%{upgrade_timer: nil} = state), do: state

  defp cancel_upgrade_timer(%{upgrade_timer: timer} = state) do
    SystemsClock.cancel_timer(timer)
    %{state | upgrade_timer: nil}
  end

  defp clear_awaiting(%{awaiting?: false} = state), do: state

  defp clear_awaiting(%{awaiting?: true} = state) do
    SystemsClock.replied({__MODULE__, state.vm_id})
    %{state | awaiting?: false}
  end

  defp reply_waiters(%{waiters: waiters} = state, reply) do
    Enum.each(Enum.reverse(waiters), &SystemsRuntime.Server.reply(&1, reply))
    %{state | waiters: []}
  end

  defp fail_waiters(%{waiters: []} = state, _reply), do: state
  defp fail_waiters(state, reply), do: reply_waiters(state, reply)

  defp safe_close_ssh(conn) do
    :ssh.close(conn)
  catch
    _, _ -> :ok
  end
end
