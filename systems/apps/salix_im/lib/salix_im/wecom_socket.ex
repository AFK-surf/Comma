defmodule SalixIM.WeComSocket do
  @moduledoc """
  The long connection of one WeCom (企业微信) AI bot connect.

  A WeCom AI bot in API mode with the long connection gets its messages
  through a WebSocket it opens to `wss://openws.work.weixin.qq.com`, and it
  sends every reply on the same socket. This process holds that socket for
  one connect:

    1. After the upgrade, `aibot_subscribe` with the Bot ID and the Secret
       proves the bot. WeCom answers `errcode` 0, or refuses the credentials
       and keeps the socket open; a refusal is retried with a growing delay.
    2. Each `aibot_msg_callback` and `aibot_event_callback` frame is handled
       by `SalixIM.WeComInbound.handle_frame/2` in a task. WeCom does not
       resend a frame that the bot did not answer, and it may send one
       frame twice: the message ID keeps a message from reaching the Router
       twice.
    3. Every other frame is the answer to a request the bot sent
       (`request/4`), matched by `headers.req_id`. A reply to a message
       carries that message's `req_id`, so several requests can share one
       `req_id`; they go out one at a time, each after the answer to the one
       before, as the official SDKs do.
       A request that gets no answer in time gives the socket up: its late
       answer could otherwise be taken for the next request's.
    4. A reply that opens a stream (`msgtype` `stream`, `finish` false; see
       `SalixIM.WeComInbound`) is remembered by its `req_id`. The next
       Markdown reply to that message finishes the stream with its text, so
       the "working" line turns into the answer in place. WeCom ends a
       stream 10 minutes after it opened; one still open after
       `@stream_close_ms` is finished here with a note that the answer comes
       separately. A second opening of a stream id seen in the last
       `@stream_memory_ms` is answered here and not sent, so a message WeCom
       delivers twice does not reopen its stream. All of this is the
       process's own memory, not a lasting guarantee: after the socket
       restarts or moves to another node, an answer goes out as a plain
       reply and a late duplicate can open a second working line. The
       Router input itself is deduplicated by its source ID.
    5. A `ping` goes out every 30 seconds. A socket that misses two answers
       in a row is lost and opened again after a backoff.
    6. WeCom keeps one socket per bot: a new subscription for the same bot
       sends `disconnected_event` to the old socket and closes it. Another
       program that holds the bot's connection takes it from this one; the
       socket then waits longer each time before it takes it back, so two
       holders do not take the bot from each other without end.

  Only the holder of the connect's lease (`SalixIM.WeComSocketRuntime`) runs
  it, so a connect has one socket in the cluster. The process renews the
  lease and stops when it loses it. While subscribed it is the member of the
  `:pg` group `{:wecom_socket, connect_id}` in `SalixIM.WeComPG`, which is
  how `request/4` reaches it from any node.

  Bounds: at most `@max_in_flight` frames are handled at a time, and at most
  `@max_queued` more wait in order. One past both is dropped and logged. At
  most `@max_pending` requests wait for an answer or their turn; one past
  that is refused. A request waits at most its timeout for its answer.
  """

  use SystemsRuntime.Server

  require Logger

  alias SalixStore.ULID

  @default_url "wss://openws.work.weixin.qq.com"
  @pg SalixIM.WeComPG
  @ping_ms 30_000
  @max_missed_pongs 2
  @connect_timeout_ms 15_000
  @lease_renew_ms 10_000
  @lease_ttl_ms 30_000
  @max_in_flight 16
  @max_queued 256
  @max_pending 512
  @default_request_timeout_ms 10_000
  @max_backoff_ms 60_000
  @max_refused_backoff_ms 10 * 60_000
  # Taken back after another holder took the socket: the first time soon
  # (a credential check of the dashboard subscribes once and leaves), then
  # longer each time it happens again within `@kick_memory_ms`.
  @kick_delays_ms [5_000, 30_000, 120_000, 600_000]
  @kick_memory_ms 15 * 60_000
  # WeCom ends a stream 10 minutes after its first frame.
  @stream_close_ms 9 * 60_000
  @stream_late_note "处理时间较长，结果会另外发送。"
  @stream_memory_ms 11 * 60_000

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts)

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :connect)["connect_id"]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc "The `:pg` scope the subscribed sockets join."
  def pg_scope, do: @pg

  @doc """
  The socket process of `connect_id` on this node and the credentials it was
  opened with (`credentials/1`), or nil.
  """
  def whereis(connect_id) do
    case SystemsRuntime.Registry.lookup(SalixIM.WeComSocketRegistry, connect_id) do
      [{pid, credentials}] -> {pid, credentials}
      [] -> nil
    end
  end

  @doc "A digest of the credentials a connect's socket opens with."
  def credentials(connect),
    do: :crypto.hash(:sha256, [to_string(connect["app_id"]), 0, to_string(connect["app_secret"])])

  @doc """
  Sends one request on the connect's socket, wherever in the cluster it is,
  and returns WeCom's answer: `{:ok, frame}` when its `errcode` is 0,
  `{:error, {:wecom, errcode, errmsg}}` when WeCom refused it,
  `{:error, :not_connected}` when no socket of the connect is subscribed,
  and `{:error, :timeout}` when no answer came in time.

  `req_id` is the `req_id` of the frame a reply answers; leave it nil for a
  request of the bot's own, which gets a new one.
  """
  @spec request(String.t(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def request(connect_id, cmd, req_id, body, opts \\ [])
      when is_binary(connect_id) and is_binary(cmd) and is_map(body) do
    timeout = Keyword.get(opts, :timeout, @default_request_timeout_ms)
    req_id = if is_binary(req_id) and req_id != "", do: req_id, else: new_req_id(cmd)

    case members(connect_id) do
      [pid | _] ->
        try do
          SystemsRuntime.Server.call(pid, {:request, cmd, req_id, body, timeout}, timeout + 5_000)
        catch
          :exit, _reason -> {:error, :not_connected}
        end

      [] ->
        {:error, :not_connected}
    end
  end

  @doc "True when a socket of the connect is subscribed somewhere in the cluster."
  def connected?(connect_id) when is_binary(connect_id), do: members(connect_id) != []

  defp members(connect_id) do
    :pg.get_members(@pg, {:wecom_socket, connect_id})
  rescue
    # The scope is not running on this node: no socket is reachable.
    ArgumentError -> []
  end

  @doc "A new `req_id` for a request of the bot's own."
  def new_req_id(cmd), do: cmd <> "_" <> ULID.generate()

  # ---- server ----

  @impl true
  def init(opts) do
    connect = Keyword.fetch!(opts, :connect)

    case SystemsRuntime.Registry.register(
           SalixIM.WeComSocketRegistry,
           connect["connect_id"],
           credentials(connect)
         ) do
      {:ok, _owner} -> start(connect, opts)
      {:error, {:already_registered, _pid}} -> :ignore
    end
  end

  defp start(connect, opts) do
    state = %{
      connect: connect,
      url:
        Keyword.get(opts, :url) ||
          SystemsRuntime.get_env(:salix_im, :wecom_socket_url, @default_url),
      lease: Keyword.get(opts, :lease),
      tasks: Keyword.get(opts, :task_supervisor, SalixIM.WeComSocketTaskSupervisor),
      handler: Keyword.get(opts, :handler, &SalixIM.WeComInbound.handle_frame/2),
      ping_ms: Keyword.get(opts, :ping_ms, @ping_ms),
      phase: :disconnected,
      conn: nil,
      ws: nil,
      ref: nil,
      upgrade: nil,
      subscribe_id: nil,
      generation: 0,
      attempt: 0,
      refusals: 0,
      kicks: [],
      kicked?: false,
      missed: 0,
      joined?: false,
      # req_id => {from, timer}: the request on the wire, waiting for its answer.
      pending: %{},
      # req_id => queue of {from, cmd, body, timeout}: requests waiting for their turn.
      waiting: %{},
      waiting_count: 0,
      # req_id => stream id: a stream open on the wire, then open and not
      # finished yet.
      opening: %{},
      streams: %{},
      # Stream ids opened in the last `@stream_memory_ms`.
      known_streams: %{},
      in_flight: %{},
      queued: :queue.new()
    }

    if state.lease, do: schedule(:renew_lease, @lease_renew_ms)
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_call({:request, _cmd, _req_id, _body, _timeout}, _from, %{phase: phase} = state)
      when phase != :open,
      do: {:reply, {:error, :not_connected}, state}

  # A message WeCom delivers twice opens its stream once: the second opening
  # is answered here and never reaches WeCom, so it cannot reopen or refresh
  # a stream an answer already finished.
  def handle_call(
        {:request, "aibot_respond_msg", _req_id,
         %{"msgtype" => "stream", "stream" => %{"id" => stream_id, "finish" => false}}, _timeout},
        _from,
        state
      )
      when is_map_key(state.known_streams, stream_id),
      do: {:reply, {:ok, %{"errcode" => 0, "duplicate" => true}}, state}

  def handle_call({:request, cmd, req_id, body, timeout}, from, state),
    do: {:noreply, enqueue(remember_stream(state, cmd, body), from, cmd, req_id, body, timeout)}

  @impl true
  def handle_info({:stream_close, req_id, stream_id}, state) do
    case state.streams do
      %{^req_id => ^stream_id} when state.phase == :open ->
        body = stream_frame(stream_id, true, @stream_late_note)

        {:noreply,
         state
         |> Map.update!(:streams, &Map.delete(&1, req_id))
         |> enqueue(nil, "aibot_respond_msg", req_id, body, @default_request_timeout_ms)}

      %{^req_id => ^stream_id} ->
        {:noreply, Map.update!(state, :streams, &Map.delete(&1, req_id))}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:forget_stream, stream_id}, state),
    do: {:noreply, %{state | known_streams: Map.delete(state.known_streams, stream_id)}}

  def handle_info(:reconnect, %{phase: :disconnected} = state), do: {:noreply, connect(state)}

  def handle_info({:upgrade_timeout, ref}, %{phase: phase, ref: ref} = state)
      when phase in [:connecting, :subscribing],
      do: {:noreply, lost(state, :upgrade_timeout)}

  def handle_info({:ping, generation}, %{phase: :open, generation: generation} = state) do
    if state.missed >= @max_missed_pongs do
      {:noreply, lost(state, :missed_pongs)}
    else
      state = send_json(%{state | missed: state.missed + 1}, ping_frame())
      if state.phase == :open, do: schedule({:ping, generation}, state.ping_ms)
      {:noreply, state}
    end
  end

  # An answer carries only the req_id, which a reply shares with every other
  # reply to the same message. Once a request goes unanswered, its answer may
  # still come and be taken for the next request with that req_id, so the
  # socket is given up and opened again: no answer crosses to a new socket.
  def handle_info({:request_timeout, req_id, tag}, state) do
    case state.pending do
      %{^req_id => {from, _timer, ^tag}} ->
        reply_to(from, {:error, :timeout})

        {:noreply,
         state
         |> Map.update!(:pending, &Map.delete(&1, req_id))
         |> lost({:request_timeout, req_id})}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(:renew_lease, state) do
    case SalixStore.Lease.renew(state.lease, ttl_ms: @lease_ttl_ms) do
      {:ok, lease} ->
        schedule(:renew_lease, @lease_renew_ms)
        {:noreply, %{state | lease: lease}}

      {:error, reason} ->
        Logger.info("wecom socket lease lost",
          connect_id: state.connect["connect_id"],
          reason: inspect(reason)
        )

        {:stop, :normal, %{state | lease: nil}}
    end
  end

  # A handled frame: the next waiting one takes its slot.
  def handle_info({ref, _result}, %{in_flight: in_flight} = state)
      when is_map_key(in_flight, ref) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])
    {:noreply, next_queued(%{state | in_flight: Map.delete(in_flight, ref)})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{in_flight: in_flight} = state)
      when is_map_key(in_flight, ref) do
    Logger.warning("wecom socket: a frame failed",
      connect_id: state.connect["connect_id"],
      reason: inspect(reason)
    )

    {:noreply, next_queued(%{state | in_flight: Map.delete(in_flight, ref)})}
  end

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {:noreply, Enum.reduce(responses, %{state | conn: conn}, &handle_response/2)}

      {:error, conn, reason, _responses} ->
        {:noreply, lost(%{state | conn: conn}, {:transport, reason})}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    fail_requests(state, :not_connected)
    if state.conn, do: Mint.HTTP.close(state.conn)
    if state.lease, do: SalixStore.Lease.release(state.lease)
    :ok
  end

  # ---- connecting ----

  defp connect(state) do
    with %URI{scheme: scheme, host: host, port: port} = uri when scheme in ["wss", "ws"] <-
           URI.parse(state.url),
         {:ok, conn} <-
           Mint.HTTP.connect(http_scheme(scheme), host, port,
             protocols: [:http1],
             # WeCom answers 404 to an upgrade whose `Sec-WebSocket-Key`
             # header name is lowercased, as Mint sends it by default.
             case_sensitive_headers: true,
             transport_opts: [timeout: @connect_timeout_ms]
           ),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme(scheme), conn, path(uri), []) do
      generation = state.generation + 1
      schedule({:upgrade_timeout, ref}, @connect_timeout_ms)

      %{
        state
        | phase: :connecting,
          conn: conn,
          ref: ref,
          upgrade: %{status: nil, headers: []},
          generation: generation,
          missed: 0,
          kicked?: false
      }
    else
      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        lost(state, {:connect_failed, reason})

      {:error, reason} ->
        lost(state, {:connect_failed, reason})

      %URI{} ->
        lost(state, :bad_url)
    end
  end

  defp http_scheme("wss"), do: :https
  defp http_scheme("ws"), do: :http

  defp ws_scheme("wss"), do: :wss
  defp ws_scheme("ws"), do: :ws

  defp path(%URI{path: path, query: query}),
    do: (path || "/") <> if(query in [nil, ""], do: "", else: "?" <> query)

  # ---- upgrade and frames ----

  defp handle_response({:status, ref, status}, %{phase: :connecting, ref: ref} = state),
    do: put_in(state.upgrade.status, status)

  defp handle_response({:headers, ref, headers}, %{phase: :connecting, ref: ref} = state),
    do: put_in(state.upgrade.headers, state.upgrade.headers ++ headers)

  defp handle_response({:done, ref}, %{phase: :connecting, ref: ref} = state) do
    %{status: status, headers: headers} = state.upgrade

    case Mint.WebSocket.new(state.conn, ref, status, headers) do
      {:ok, conn, ws} ->
        subscribe_id = new_req_id("aibot_subscribe")
        state = %{state | conn: conn, ws: ws, upgrade: nil, phase: :subscribing}

        send_json(%{state | subscribe_id: subscribe_id}, %{
          "cmd" => "aibot_subscribe",
          "headers" => %{"req_id" => subscribe_id},
          "body" => %{
            "bot_id" => to_string(state.connect["app_id"]),
            "secret" => to_string(state.connect["app_secret"])
          }
        })

      {:error, conn, reason} ->
        lost(%{state | conn: conn}, {:upgrade_failed, reason})
    end
  end

  defp handle_response({:data, ref, data}, %{phase: phase, ref: ref} = state)
       when phase in [:subscribing, :open] do
    case Mint.WebSocket.decode(state.ws, data) do
      {:ok, ws, frames} -> Enum.reduce(frames, %{state | ws: ws}, &handle_frame/2)
      {:error, ws, reason} -> lost(%{state | ws: ws}, {:protocol_error, reason})
    end
  end

  defp handle_response(_response, state), do: state

  defp handle_frame(_frame, %{phase: phase} = state) when phase not in [:subscribing, :open],
    do: state

  defp handle_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, %{} = frame} ->
        handle_json(state, frame)

      _unreadable ->
        Logger.warning("wecom socket: dropped an unreadable frame",
          connect_id: state.connect["connect_id"]
        )

        state
    end
  end

  defp handle_frame({:ping, payload}, state), do: send_ws(state, {:pong, payload})
  defp handle_frame({:close, code, _reason}, state), do: lost(state, {:closed, code})
  defp handle_frame(_frame, state), do: state

  # The subscription's answer.
  defp handle_json(
         %{phase: :subscribing, subscribe_id: id} = state,
         %{
           "headers" => %{"req_id" => id}
         } = frame
       ) do
    case frame["errcode"] do
      0 ->
        Logger.info("wecom socket open", connect_id: state.connect["connect_id"])

        :ok =
          :pg.join(@pg, {:wecom_socket, state.connect["connect_id"]}, SystemsRuntime.Proc.self())

        state = %{state | phase: :open, attempt: 0, refusals: 0, joined?: true}
        schedule({:ping, state.generation}, state.ping_ms)
        state

      code ->
        refused(state, code, frame["errmsg"])
    end
  end

  defp handle_json(%{phase: :open} = state, %{"cmd" => cmd} = frame)
       when cmd in ["aibot_msg_callback", "aibot_event_callback"] do
    if get_in(frame, ["body", "event", "eventtype"]) == "disconnected_event" do
      kicked(state)
    else
      handle_callback(state, frame)
    end
  end

  # An answer: to a ping, or to a request.
  defp handle_json(%{phase: :open} = state, %{"headers" => %{"req_id" => req_id}} = frame)
       when is_binary(req_id) do
    cond do
      String.starts_with?(req_id, "ping_") ->
        %{state | missed: 0}

      is_map_key(state.pending, req_id) ->
        state = stream_opened(state, req_id, frame["errcode"])
        {{from, timer, _tag}, pending} = Map.pop(state.pending, req_id)
        SystemsClock.cancel_timer(timer)

        answer =
          case frame["errcode"] do
            0 -> {:ok, frame}
            code -> {:error, {:wecom, code, to_string(frame["errmsg"])}}
          end

        reply_to(from, answer)
        next_waiting(%{state | pending: pending}, req_id)

      true ->
        state
    end
  end

  defp handle_json(state, _frame), do: state

  # ---- requests ----

  # A request goes out now, or waits behind the one on the wire with its
  # req_id. `from` nil is the socket's own request: nobody waits for it.
  defp enqueue(state, from, cmd, req_id, body, timeout) do
    cond do
      is_map_key(state.pending, req_id) ->
        if state.waiting_count >= @max_pending do
          reply_to(from, {:error, :too_many_requests})
          state
        else
          queue = Map.get(state.waiting, req_id, :queue.new())
          queue = :queue.in({from, cmd, body, timeout}, queue)

          %{
            state
            | waiting: Map.put(state.waiting, req_id, queue),
              waiting_count: state.waiting_count + 1
          }
        end

      map_size(state.pending) >= @max_pending ->
        reply_to(from, {:error, :too_many_requests})
        state

      true ->
        put_request(state, from, cmd, req_id, body, timeout)
    end
  end

  defp reply_to(nil, _answer), do: :ok
  defp reply_to(from, answer), do: SystemsRuntime.Server.reply(from, answer)

  # A reply that opens a stream is remembered once WeCom took it
  # (`stream_opened/3`); the first Markdown reply to the same message after
  # that finishes the stream with its text. Requests with one req_id go out
  # one at a time, so the answer to the opening comes before the reply.
  defp stream_body(
         state,
         "aibot_respond_msg",
         req_id,
         %{"msgtype" => "stream", "stream" => %{"id" => stream_id, "finish" => false}} = body
       )
       when is_binary(stream_id),
       do: {body, %{state | opening: Map.put(state.opening, req_id, stream_id)}}

  defp stream_body(
         state,
         "aibot_respond_msg",
         req_id,
         %{"msgtype" => "markdown", "markdown" => %{"content" => text}} = body
       )
       when is_binary(text) do
    case Map.pop(state.streams, req_id) do
      {nil, _streams} -> {body, state}
      {stream_id, streams} -> {stream_frame(stream_id, true, text), %{state | streams: streams}}
    end
  end

  defp stream_body(state, _cmd, _req_id, body), do: {body, state}

  defp remember_stream(
         state,
         "aibot_respond_msg",
         %{"msgtype" => "stream", "stream" => %{"id" => stream_id, "finish" => false}}
       )
       when is_binary(stream_id) do
    schedule({:forget_stream, stream_id}, @stream_memory_ms)
    %{state | known_streams: Map.put(state.known_streams, stream_id, true)}
  end

  defp remember_stream(state, _cmd, _body), do: state

  defp stream_opened(state, req_id, errcode) do
    case Map.pop(state.opening, req_id) do
      {nil, _opening} ->
        state

      {stream_id, opening} when errcode == 0 ->
        schedule({:stream_close, req_id, stream_id}, @stream_close_ms)
        %{state | opening: opening, streams: Map.put(state.streams, req_id, stream_id)}

      {_stream_id, opening} ->
        %{state | opening: opening}
    end
  end

  @doc "The body of a stream reply."
  def stream_frame(stream_id, finish, content),
    do: %{
      "msgtype" => "stream",
      "stream" => %{"id" => stream_id, "finish" => finish, "content" => content}
    }

  defp put_request(state, from, cmd, req_id, body, timeout) do
    {body, state} = stream_body(state, cmd, req_id, body)
    state = send_json(state, %{"cmd" => cmd, "headers" => %{"req_id" => req_id}, "body" => body})

    if state.phase == :open do
      # The timeout names its request, so a late timeout of an earlier
      # request with the same req_id is not taken for this one's.
      tag = SystemsRuntime.Proc.make_ref()

      timer =
        SystemsClock.send_after(
          SystemsRuntime.Proc.self(),
          {:request_timeout, req_id, tag},
          timeout
        )

      %{state | pending: Map.put(state.pending, req_id, {from, timer, tag})}
    else
      reply_to(from, {:error, :not_connected})
      state
    end
  end

  defp next_waiting(state, req_id) do
    case Map.get(state.waiting, req_id) do
      nil ->
        state

      queue ->
        case :queue.out(queue) do
          {{:value, {from, cmd, body, timeout}}, rest} ->
            waiting =
              if :queue.is_empty(rest),
                do: Map.delete(state.waiting, req_id),
                else: Map.put(state.waiting, req_id, rest)

            %{state | waiting: waiting, waiting_count: state.waiting_count - 1}
            |> put_request(from, cmd, req_id, body, timeout)

          {:empty, _queue} ->
            %{state | waiting: Map.delete(state.waiting, req_id)}
        end
    end
  end

  defp fail_requests(state, reason) do
    Enum.each(state.pending, fn {_req_id, {from, timer, _tag}} ->
      SystemsClock.cancel_timer(timer)
      reply_to(from, {:error, reason})
    end)

    Enum.each(state.waiting, fn {_req_id, queue} ->
      queue
      |> :queue.to_list()
      |> Enum.each(fn {from, _cmd, _body, _timeout} ->
        reply_to(from, {:error, reason})
      end)
    end)

    # An opening whose answer never came opened nothing we know of.
    %{state | pending: %{}, waiting: %{}, waiting_count: 0, opening: %{}}
  end

  # ---- callbacks ----

  defp handle_callback(state, frame) do
    cond do
      map_size(state.in_flight) < @max_in_flight ->
        run(state, frame)

      :queue.len(state.queued) < @max_queued ->
        %{state | queued: :queue.in(frame, state.queued)}

      true ->
        Logger.warning("wecom socket: too many frames waiting, one is dropped",
          connect_id: state.connect["connect_id"]
        )

        state
    end
  end

  defp run(state, frame) do
    %{connect: connect, handler: handler} = state

    task =
      SystemsRuntime.TaskSupervisor.async_nolink(state.tasks, fn ->
        handler.(connect, frame)
      end)

    %{state | in_flight: Map.put(state.in_flight, task.ref, true)}
  end

  defp next_queued(state) do
    case :queue.out(state.queued) do
      {{:value, frame}, queued} -> run(%{state | queued: queued}, frame)
      {:empty, _queued} -> state
    end
  end

  # ---- sending and losing ----

  defp ping_frame, do: %{"cmd" => "ping", "headers" => %{"req_id" => new_req_id("ping")}}

  defp send_json(state, frame), do: send_ws(state, {:text, Jason.encode!(frame)})

  defp send_ws(%{phase: phase} = state, frame) when phase in [:subscribing, :open] do
    with {:ok, ws, data} <- Mint.WebSocket.encode(state.ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      %{state | ws: ws, conn: conn}
    else
      {:error, %Mint.WebSocket{} = ws, reason} -> lost(%{state | ws: ws}, {:send_failed, reason})
      {:error, conn, reason} -> lost(%{state | conn: conn}, {:send_failed, reason})
    end
  end

  defp send_ws(state, _frame), do: state

  # WeCom refused the Bot ID or the Secret. The socket is closed and opened
  # again later: a fixed Secret in the WeCom console is taken without a
  # change here, but nothing is gained by asking every second.
  defp refused(state, code, message) do
    refusals = state.refusals + 1
    delay = min(5_000 * Integer.pow(2, min(refusals - 1, 8)), @max_refused_backoff_ms)

    Logger.warning("wecom socket: subscription refused",
      connect_id: state.connect["connect_id"],
      errcode: inspect(code),
      errmsg: to_string(message),
      retry_in_ms: delay
    )

    state |> close(:refused) |> Map.put(:refusals, refusals) |> reconnect_in(delay)
  end

  # Another holder of the bot's connection took it.
  defp kicked(state) do
    now = SystemsClock.monotonic_time(:millisecond)
    kicks = [now | Enum.filter(state.kicks, &(now - &1 < @kick_memory_ms))]
    delay = Enum.at(@kick_delays_ms, length(kicks) - 1, List.last(@kick_delays_ms))

    Logger.warning("wecom socket: another connection took the bot",
      connect_id: state.connect["connect_id"],
      times: length(kicks),
      retry_in_ms: delay
    )

    state
    |> close(:kicked)
    |> Map.put(:kicks, kicks)
    |> Map.put(:kicked?, true)
    |> reconnect_in(delay)
  end

  defp lost(%{kicked?: true} = state, _reason), do: close(state, :kicked)

  defp lost(state, reason) do
    attempt = state.attempt + 1
    delay = min(1_000 * Integer.pow(2, min(attempt - 1, 6)), @max_backoff_ms)

    Logger.warning("wecom socket lost",
      connect_id: state.connect["connect_id"],
      reason: inspect(reason),
      retry_in_ms: delay
    )

    state |> close(reason) |> Map.put(:attempt, attempt) |> reconnect_in(delay)
  end

  defp close(state, _reason) do
    if state.conn, do: Mint.HTTP.close(state.conn)

    if state.joined?,
      do: :pg.leave(@pg, {:wecom_socket, state.connect["connect_id"]}, SystemsRuntime.Proc.self())

    state
    |> fail_requests(:not_connected)
    |> Map.merge(%{
      phase: :disconnected,
      conn: nil,
      ws: nil,
      ref: nil,
      upgrade: nil,
      subscribe_id: nil,
      joined?: false,
      missed: 0
    })
  end

  defp reconnect_in(state, delay) do
    schedule(:reconnect, delay)
    state
  end

  defp schedule(message, ms), do: SystemsClock.send_after(SystemsRuntime.Proc.self(), message, ms)
end
