defmodule SalixSignal.Service.Chat do
  @moduledoc """
  One chat WebSocket to the Signal chat service (CRS-01 sections 6 to 11,
  CRS-15 section 9).

  The process holds one socket at a time, reconnects with backoff, and
  multiplexes requests on it. An owner process (the account actor) receives
  events as `{:signal_chat, chat_pid, event}`:

    * `{:connected, %{server_time_ms: ms | nil, alerts: [String.t()]}}`
    * `{:message, envelope, server_delivery_ms, ack_token}`: one queued
      envelope. The server deletes it only after `ack/3` answers it with a
      2xx status. Unanswered envelopes are pushed again on a later
      connection, so the owner acknowledges only after it has committed the
      envelope durably.
    * `:queue_empty`: the envelopes that were queued at connect time have
      all been pushed.

  The process answers only pushed envelopes, through `ack/3`. It sends
  nothing for `PUT /api/v1/queue/empty`, for a server request without a
  request id, or for any other server request, as deployed clients do
  (CRS-01 section 10.1, Comma decision 3). Frames that do not parse, and
  responses without a request id, are dropped and the socket stays open
  (CRS-01 section 7.1). A response that breaks the client rules of CRS-01
  section 7.3.1 fails its request with `{:error, :invalid_response}`.
    * `{:disconnected, reason}`: the socket is gone; a reconnect is
      scheduled. Outstanding requests fail with `{:error, :disconnected}`.
    * `{:stopped, reason}`: the socket is gone and the process does not
      reconnect. `reason` is `:reauthentication_required` (close 4401),
      `:connected_elsewhere` (close 4409), `:unauthorized` (upgrade 401 or
      403) or `:client_deprecated` (upgrade 499). Requests then fail with
      `{:error, reason}`. Reconnecting with the same credentials is not
      expected to succeed, so the owner decides what to do next.

  Without credentials the socket is unauthenticated and carries requests
  only. With `receive_messages: false` an authenticated socket also carries
  requests only (`X-Signal-Disable-Messages: true`).

  Keepalive: every `keepalive_interval_ms` the process sends
  `GET /v1/keepalive`. When nothing arrived for `idle_timeout_ms`, it drops
  the socket and reconnects. The server closes a socket after 90 s without
  traffic (CRS-01 section 9).

  Requests are bounded: at most `max_pending` in flight, each frame at most
  `max_frame_bytes` (the server default limit is 512 KiB, section 7.5), and
  each request has a timeout. A header value that contains `:` is refused,
  because the server drops such header lines (section 7.2).
  """

  use GenServer

  require Logger

  alias SalixSignal.Service.{Backoff, Credentials, Endpoints, Response}
  alias SalixSignalProto.Service.Frame

  @path "/v1/websocket/"
  @default_user_agent "Salix-Signal/0.1"
  @default_request_timeout_ms 30_000

  @defaults [
    environment: :production,
    host: nil,
    port: 443,
    credentials: nil,
    receive_messages: true,
    user_agent: @default_user_agent,
    roots: nil,
    tls: [],
    keepalive_interval_ms: 30_000,
    idle_timeout_ms: 45_000,
    connect_timeout_ms: 10_000,
    stable_after_ms: 60_000,
    max_pending: 256,
    max_frame_bytes: 524_288,
    backoff: [],
    clock: nil
  ]

  @type ack_token :: {non_neg_integer(), non_neg_integer()}
  @type stop_reason ::
          :reauthentication_required | :connected_elsewhere | :unauthorized | :client_deprecated

  @doc """
  Starts the process linked to the caller.

  Options: `:owner` (required pid), `:credentials`
  (`SalixSignal.Service.Credentials` or `nil`), `:environment`
  (`:production` or `:staging`), `:host`, `:port`, `:receive_messages`,
  `:user_agent`, `:roots` (DER roots to trust instead of the pinned Signal
  roots), `:tls` (extra TLS options), the timing options in the module
  documentation, `:max_pending`, `:max_frame_bytes`, `:backoff`
  (`SalixSignal.Service.Backoff` options), `:clock` (a `(-> ms)` function
  that replaces the monotonic clock of the idle and stability checks; the
  timers stay real) and `:name`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Sends a request on the socket and waits for its response.

  Options: `:headers` (list of `{name, value}`), `:body` (binary), `:json`
  (a term sent as a JSON body), `:timeout` (ms, default 30 s).
  """
  @spec request(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, Response.t()}
          | {:error,
             :not_connected
             | :disconnected
             | :timeout
             | :invalid_response
             | :too_many_pending
             | :too_large
             | {:invalid_header, String.t()}
             | stop_reason()}
  def request(chat, verb, path, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_request_timeout_ms)
    {body, headers} = body_and_headers(opts)

    with :ok <- validate_headers(headers) do
      # The process replies by `timeout`; the margin covers a connect attempt
      # that holds the process when the call arrives.
      GenServer.call(chat, {:request, verb, path, body, headers, timeout}, timeout + 15_000)
    end
  end

  @doc """
  Answers a pushed envelope. A 2xx `status` removes it from the server
  queue; any other status leaves it there (CRS-01 section 10).

  Returns `{:error, :stale}` when the token belongs to an earlier socket.
  The server pushes that envelope again on the current or a later socket.
  """
  @spec ack(GenServer.server(), ack_token(), 100..599) :: :ok | {:error, :stale}
  def ack(chat, token, status \\ 200), do: GenServer.call(chat, {:ack, token, status})

  @doc "The current phase: `:connecting`, `:open`, `:disconnected` or `{:stopped, reason}`."
  def phase(chat), do: GenServer.call(chat, :phase)

  # --- GenServer ---------------------------------------------------------

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    Process.monitor(owner)
    config = Keyword.merge(@defaults, opts) |> Map.new()
    host = config.host || Endpoints.host(config.environment, :chat)

    state =
      Map.merge(config, %{
        owner: owner,
        host: host,
        phase: :disconnected,
        stop_reason: nil,
        conn: nil,
        ws: nil,
        ref: nil,
        upgrade: nil,
        generation: 0,
        next_id: 0,
        pending: %{},
        last_rx: nil,
        opened_at: nil,
        attempt: 0,
        timer: nil
      })

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  # Status and crash reports show the connection phase only: the state
  # holds the device credentials and the socket's request headers.
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{} = state -> Map.take(state, [:phase, :host, :generation, :attempt, :stop_reason])
      other -> other
    end)
  end

  @impl true
  def handle_call(:phase, _from, %{phase: :stopped} = state),
    do: {:reply, {:stopped, state.stop_reason}, state}

  def handle_call(:phase, _from, state), do: {:reply, state.phase, state}

  def handle_call({:request, _, _, _, _, _}, _from, %{phase: :stopped} = state),
    do: {:reply, {:error, state.stop_reason}, state}

  def handle_call({:request, _, _, _, _, _}, _from, %{phase: phase} = state) when phase != :open,
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:request, verb, path, body, headers, timeout}, from, state) do
    if map_size(state.pending) >= state.max_pending do
      {:reply, {:error, :too_many_pending}, state}
    else
      request = %Frame.Request{
        verb: verb,
        path: path,
        id: state.next_id,
        body: body,
        headers: headers
      }

      case send_request(state, request, from, timeout) do
        {:ok, state} -> {:noreply, state}
        {:error, :too_large, state} -> {:reply, {:error, :too_large}, state}
        {:error, _reason, state} -> {:reply, {:error, :disconnected}, state}
      end
    end
  end

  def handle_call({:ack, {generation, id}, status}, _from, state)
      when state.phase == :open and generation == state.generation do
    response = Frame.encode_response(%Frame.Response{id: id, status: status})

    case send_frame(state, response) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, :stale}, lost(state, {:transport, reason})}
    end
  end

  def handle_call({:ack, _token, _status}, _from, state), do: {:reply, {:error, :stale}, state}

  @impl true
  def handle_info(:reconnect, %{phase: :disconnected} = state),
    do: {:noreply, connect(%{state | timer: nil})}

  def handle_info({:upgrade_timeout, ref}, %{phase: :connecting, ref: ref} = state),
    do: {:noreply, lost(state, :upgrade_timeout)}

  def handle_info({:keepalive, generation}, %{phase: :open, generation: generation} = state),
    do: {:noreply, keepalive(state)}

  def handle_info({:request_timeout, generation, id}, %{generation: generation} = state) do
    case Map.pop(state.pending, id) do
      {{:keepalive, _timer}, pending} ->
        {:noreply, %{state | pending: pending}}

      {{from, _timer}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {:noreply, handle_responses(%{state | conn: conn}, responses)}

      {:error, conn, reason, responses} ->
        state = handle_responses(%{state | conn: conn}, responses)
        {:noreply, if(state.conn, do: lost(state, {:transport, reason}), else: state)}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    :ok
  end

  # --- Connecting --------------------------------------------------------

  defp connect(state) do
    tls =
      [versions: [:"tlsv1.3"]]
      |> then(fn opts -> if state.roots, do: [{:roots, state.roots} | opts], else: opts end)
      |> Endpoints.tls_options()
      |> Keyword.merge(state.tls)

    transport_opts = tls ++ [timeout: state.connect_timeout_ms]

    with {:ok, conn} <-
           Mint.HTTP.connect(:https, state.host, state.port,
             protocols: [:http1],
             transport_opts: transport_opts
           ),
         {:ok, conn, ref} <- upgrade(conn, state) do
      timer = Process.send_after(self(), {:upgrade_timeout, ref}, state.connect_timeout_ms)

      %{
        state
        | phase: :connecting,
          conn: conn,
          ref: ref,
          upgrade: %{status: nil, headers: []},
          timer: timer
      }
    else
      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        lost(state, {:connect_failed, reason})

      {:error, reason} ->
        lost(state, {:connect_failed, reason})
    end
  end

  defp upgrade(conn, state) do
    Mint.WebSocket.upgrade(:wss, conn, @path, upgrade_headers(state))
  end

  defp upgrade_headers(state) do
    auth =
      case state.credentials do
        %Credentials{} = credentials ->
          [{"authorization", Credentials.authorization(credentials)}] ++
            if(state.receive_messages, do: [], else: [{"x-signal-disable-messages", "true"}])

        nil ->
          []
      end

    [{"user-agent", state.user_agent}, {"x-signal-receive-stories", "false"}] ++ auth
  end

  defp handle_responses(state, responses), do: Enum.reduce(responses, state, &handle_response/2)

  defp handle_response({:status, ref, status}, %{phase: :connecting, ref: ref} = state),
    do: put_in(state.upgrade.status, status)

  defp handle_response({:headers, ref, headers}, %{phase: :connecting, ref: ref} = state),
    do: put_in(state.upgrade.headers, state.upgrade.headers ++ headers)

  defp handle_response({:done, ref}, %{phase: :connecting, ref: ref} = state),
    do: finish_upgrade(state)

  defp handle_response({:data, ref, data}, %{phase: :open, ref: ref} = state),
    do: handle_data(state, data)

  defp handle_response(_response, state), do: state

  defp finish_upgrade(state) do
    %{status: status, headers: headers} = state.upgrade
    cancel(state.timer)

    case Mint.WebSocket.new(state.conn, state.ref, status, headers) do
      {:ok, conn, ws} ->
        open(%{state | conn: conn, ws: ws, timer: nil}, headers)

      {:error, conn, %Mint.WebSocket.UpgradeFailureError{status_code: code}} ->
        upgrade_rejected(%{state | conn: conn, timer: nil}, code, headers)

      {:error, conn, reason} ->
        lost(%{state | conn: conn, timer: nil}, {:upgrade_failed, reason})
    end
  end

  defp open(state, headers) do
    generation = state.generation + 1
    now = now_ms(state)
    response = %Response{status: 101, headers: lower_headers(headers)}

    alerts =
      case Response.header(response, "x-signal-alert") do
        nil ->
          []

        value ->
          value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      end

    Process.send_after(self(), {:keepalive, generation}, state.keepalive_interval_ms)

    notify(
      state,
      {:connected, %{server_time_ms: Response.server_time_ms(response), alerts: alerts}}
    )

    %{
      state
      | phase: :open,
        generation: generation,
        next_id: 0,
        last_rx: now,
        opened_at: now,
        upgrade: nil
    }
  end

  defp upgrade_rejected(state, code, headers) do
    response = %Response{status: code, headers: lower_headers(headers)}

    case Response.outcome(response) do
      outcome when outcome in [:unauthorized, :forbidden] -> stop(state, :unauthorized)
      :client_deprecated -> stop(state, :client_deprecated)
      {:rate_limited, seconds} -> lost(state, {:upgrade_rejected, code}, seconds)
      _ -> lost(state, {:upgrade_rejected, code})
    end
  end

  # --- Open socket -------------------------------------------------------

  defp handle_data(state, data) do
    state = %{state | last_rx: now_ms(state)}

    case Mint.WebSocket.decode(state.ws, data) do
      {:ok, ws, frames} ->
        Enum.reduce(frames, %{state | ws: ws}, &handle_frame/2)

      {:error, ws, reason} ->
        lost(%{state | ws: ws}, {:protocol_error, reason})
    end
  end

  defp handle_frame(_frame, %{phase: phase} = state) when phase != :open, do: state

  defp handle_frame({:binary, bytes}, state) do
    case Frame.decode(bytes) do
      {:ok, %Frame.Response{} = response} ->
        handle_frame_response(state, response)

      {:ok, %Frame.Request{} = request} ->
        handle_server_request(state, request)

      {:error, {:invalid_response, id}} ->
        fail_request(state, id, :invalid_response)

      {:error, :malformed} ->
        Logger.debug("signal chat: dropped a malformed frame")
        state
    end
  end

  defp handle_frame({:ping, data}, state) do
    case send_frame(state, {:pong, data}) do
      {:ok, state} -> state
      {:error, reason, state} -> lost(state, {:transport, reason})
    end
  end

  defp handle_frame({:close, 4401, _reason}, state), do: stop(state, :reauthentication_required)
  defp handle_frame({:close, 4409, _reason}, state), do: stop(state, :connected_elsewhere)
  defp handle_frame({:close, code, _reason}, state), do: lost(state, {:closed, code})
  defp handle_frame({:error, reason}, state), do: lost(state, {:protocol_error, reason})
  defp handle_frame(_frame, state), do: state

  defp handle_frame_response(state, %Frame.Response{id: id} = frame) do
    complete(
      state,
      id,
      {:ok,
       %Response{
         status: frame.status,
         message: frame.message,
         headers: frame.headers,
         body: frame.body || ""
       }}
    )
  end

  # A response that breaks the client rules fails the matched request; the
  # socket stays open (CRS-01 section 7.3.1).
  defp fail_request(state, id, reason), do: complete(state, id, {:error, reason})

  # Replies to the outstanding request `id`. A response that matches no
  # outstanding request is dropped (CRS-01 section 7.3 rule 3).
  defp complete(state, id, reply) do
    case Map.pop(state.pending, id) do
      {{:keepalive, timer}, pending} ->
        cancel(timer)
        %{state | pending: pending}

      {{from, timer}, pending} ->
        cancel(timer)
        GenServer.reply(from, reply)
        %{state | pending: pending}

      {nil, _} ->
        state
    end
  end

  defp handle_server_request(%{credentials: nil} = state, _request), do: state

  # Only pushed envelopes are answered, later, through ack/3 (CRS-01
  # section 10.1, Comma decision 3).
  defp handle_server_request(state, request) do
    case Frame.server_event(request) do
      {:incoming_message, envelope, delivered_ms} ->
        notify(state, {:message, envelope, delivered_ms, {state.generation, request.id}})

      :queue_empty ->
        notify(state, :queue_empty)

      :ignore ->
        :ok
    end

    state
  end

  defp keepalive(state) do
    if now_ms(state) - state.last_rx >= state.idle_timeout_ms do
      lost(state, :keepalive_timeout)
    else
      Process.send_after(self(), {:keepalive, state.generation}, state.keepalive_interval_ms)

      if map_size(state.pending) >= state.max_pending do
        state
      else
        request = %Frame.Request{verb: "GET", path: "/v1/keepalive", id: state.next_id}

        case send_request(state, request, :keepalive, state.idle_timeout_ms) do
          {:ok, state} -> state
          {:error, _reason, state} -> state
        end
      end
    end
  end

  defp send_request(state, request, from, timeout) do
    frame = Frame.encode_request(request)

    if byte_size(frame) > state.max_frame_bytes do
      {:error, :too_large, state}
    else
      case send_frame(state, frame) do
        {:ok, state} ->
          timer =
            Process.send_after(
              self(),
              {:request_timeout, state.generation, request.id},
              timeout
            )

          {:ok,
           %{
             state
             | pending: Map.put(state.pending, request.id, {from, timer}),
               next_id: Frame.next_request_id(request.id)
           }}

        {:error, reason, state} ->
          {:error, reason, lost(state, {:transport, reason})}
      end
    end
  end

  defp send_frame(state, bytes) when is_binary(bytes), do: send_frame(state, {:binary, bytes})

  defp send_frame(state, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(state.ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, %{state | ws: ws, conn: conn}}
    else
      {:error, %Mint.WebSocket{} = ws, reason} -> {:error, reason, %{state | ws: ws}}
      {:error, conn, reason} -> {:error, reason, %{state | conn: conn}}
    end
  end

  # --- Losing the socket -------------------------------------------------

  defp lost(state, reason, retry_after \\ nil) do
    state = drop_socket(state, {:error, :disconnected})
    notify(state, {:disconnected, reason})

    attempt =
      if state.opened_at && now_ms(state) - state.opened_at >= state.stable_after_ms,
        do: 0,
        else: state.attempt

    delay =
      attempt
      |> Backoff.delay_ms(state.backoff)
      |> Backoff.honor_retry_after(retry_after)

    timer = Process.send_after(self(), :reconnect, delay)
    %{state | phase: :disconnected, attempt: attempt + 1, opened_at: nil, timer: timer}
  end

  defp stop(state, reason) do
    state = drop_socket(state, {:error, reason})
    notify(state, {:stopped, reason})
    %{state | phase: :stopped, stop_reason: reason, opened_at: nil}
  end

  defp drop_socket(state, pending_reply) do
    cancel(state.timer)
    if state.conn, do: Mint.HTTP.close(state.conn)

    for {_id, {from, timer}} <- state.pending do
      cancel(timer)
      if from != :keepalive, do: GenServer.reply(from, pending_reply)
    end

    # A new generation fences acknowledgements and timers of this socket.
    %{
      state
      | conn: nil,
        ws: nil,
        ref: nil,
        upgrade: nil,
        pending: %{},
        timer: nil,
        generation: state.generation + 1
    }
  end

  # --- Helpers -----------------------------------------------------------

  defp notify(state, event), do: send(state.owner, {:signal_chat, self(), event})

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp now_ms(%{clock: nil}), do: System.monotonic_time(:millisecond)
  defp now_ms(%{clock: clock}), do: clock.()

  defp lower_headers(headers), do: Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)

  defp body_and_headers(opts) do
    headers = Keyword.get(opts, :headers, [])

    case Keyword.fetch(opts, :json) do
      {:ok, term} -> {Jason.encode!(term), headers ++ [{"content-type", "application/json"}]}
      :error -> {Keyword.get(opts, :body), headers}
    end
  end

  defp validate_headers(headers) do
    case Enum.find(headers, fn {name, value} ->
           String.contains?(name, ":") or String.contains?(value, ":")
         end) do
      nil -> :ok
      {name, _} -> {:error, {:invalid_header, name}}
    end
  end
end
