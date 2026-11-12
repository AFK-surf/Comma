defmodule SalixIM.LarkSocket do
  @moduledoc """
  The long connection of one Lark or Feishu connect with
  `"events" => "socket"`.

  An app made by a scan (`SalixIM.Provider.Lark.Registration`) gets its
  events through a WebSocket it opens to Lark or Feishu, not through a
  request URL. The two platforms speak the same protocol on their own hosts.
  This process holds that socket for one connect:

    1. `POST /callback/ws/endpoint` with the App ID and App Secret gives the
       socket's address and the ping interval. Lark refuses wrong
       credentials here, so an event on the socket is the app's own.
    2. Each data frame (`SalixIM.LarkSocket.Frame`) of type `event` or
       `card` is one envelope, sometimes in parts. It is handled by
       `SalixIM.LarkInbound.handle_socket_event/2` (Lark) or
       `SalixIM.ProviderHTTP.handle_feishu_socket_event/2` (Feishu) in a
       task, and answered on
       the socket once handled. An envelope that failed is answered with code
       500, as the Lark SDKs do, so Lark sends it again; receipts keep a
       message from reaching the Router twice.
    3. A ping frame goes out every ping interval. A lost socket is opened
       again after a backoff, with a new address.
    4. Lark keeps no events for a socket that is not there: each time the
       socket opens, what was said since it was lost (since shortly before
       the process started, for the first) is read back from the chats'
       history (`SalixIM.LarkSocket.CatchUp`).

  Only the holder of the connect's lease (`SalixIM.LarkSocketRuntime`)
  runs it, so a connect has one socket in the cluster. The process renews
  the lease and stops when it loses it.

  Bounds: at most `@max_in_flight` envelopes are handled at a time, and at
  most `@max_queued` more wait in order for a free slot. One past both is
  answered with code 500 for Lark to send again. Parts of an envelope wait
  at most `@parts_ttl_ms`, and at most `@max_open_parts` envelopes wait.
  """

  use SystemsRuntime.Server

  require Logger

  alias SalixIM.LarkSocket.{CatchUp, Frame}
  alias SalixIM.{LarkInbound, ProviderHTTP}

  @base_urls %{
    "lark" => {:lark_socket_base_url, "https://open.larksuite.com"},
    "feishu" => {:feishu_socket_base_url, "https://open.feishu.cn"}
  }
  @default_ping_ms 120_000
  @connect_timeout_ms 15_000
  @lease_renew_ms 10_000
  @lease_ttl_ms 30_000
  @max_in_flight 16
  @max_queued 256
  @max_open_parts 64
  @parts_ttl_ms 5 * 60_000
  @max_backoff_ms 60_000
  # What a socket that just started reads back: the longest a rollout or a
  # lease moving to another node keeps a connect without a socket.
  @fresh_catch_up_ms 10 * 60_000

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts)

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :connect)["connect_id"]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc """
  The socket process of `connect_id` on this node and the credentials it
  was opened with (`credentials/1`), or nil.
  """
  def whereis(connect_id) do
    case SystemsRuntime.Registry.lookup(SalixIM.LarkSocketRegistry, connect_id) do
      [{pid, credentials}] -> {pid, credentials}
      [] -> nil
    end
  end

  @doc "A digest of the credentials a connect's socket opens with."
  def credentials(connect),
    do: :crypto.hash(:sha256, [to_string(connect["app_id"]), 0, to_string(connect["app_secret"])])

  # ---- server ----

  @impl true
  def init(opts) do
    connect = Keyword.fetch!(opts, :connect)

    case SystemsRuntime.Registry.register(
           SalixIM.LarkSocketRegistry,
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
      lease: Keyword.get(opts, :lease),
      tasks: Keyword.get(opts, :task_supervisor, SalixIM.LarkSocketTaskSupervisor),
      handler: Keyword.get(opts, :handler, handler(connect)),
      catch_up: Keyword.get(opts, :catch_up, &CatchUp.run/3),
      # Since when nothing came: a socket that just started reads back a while.
      lost_at: SystemsClock.system_time(:millisecond) - @fresh_catch_up_ms,
      phase: :disconnected,
      conn: nil,
      ws: nil,
      ref: nil,
      upgrade: nil,
      service: 0,
      ping_ms: @default_ping_ms,
      generation: 0,
      attempt: 0,
      parts: %{},
      in_flight: %{},
      queued: :queue.new()
    }

    if state.lease, do: schedule(:renew_lease, @lease_renew_ms)
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_info(:reconnect, %{phase: :disconnected} = state), do: {:noreply, connect(state)}

  def handle_info({:upgrade_timeout, ref}, %{phase: :connecting, ref: ref} = state),
    do: {:noreply, lost(state, :upgrade_timeout)}

  def handle_info({:ping, generation}, %{phase: :open, generation: generation} = state) do
    state = send_frame(state, Frame.ping(state.service))
    if state.phase == :open, do: schedule({:ping, generation}, state.ping_ms)
    {:noreply, state}
  end

  def handle_info(:renew_lease, state) do
    case SalixStore.Lease.renew(state.lease, ttl_ms: @lease_ttl_ms) do
      {:ok, lease} ->
        schedule(:renew_lease, @lease_renew_ms)
        {:noreply, %{state | lease: lease}}

      {:error, reason} ->
        Logger.info("lark socket lease lost",
          connect_id: state.connect["connect_id"],
          reason: inspect(reason)
        )

        {:stop, :normal, %{state | lease: nil}}
    end
  end

  # A handled envelope: answered on the socket it came from, and the next
  # waiting one takes its slot.
  def handle_info({ref, result}, %{in_flight: in_flight} = state)
      when is_map_key(in_flight, ref) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])
    {{generation, frame}, in_flight} = Map.pop(in_flight, ref)
    state = %{state | in_flight: in_flight}

    payload =
      case result do
        {:ok, answer} -> answer_payload(answer)
        _failed -> failure_payload()
      end

    {:noreply, state |> answer(generation, frame, payload) |> next_queued()}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{in_flight: in_flight} = state)
      when is_map_key(in_flight, ref) do
    {{generation, frame}, in_flight} = Map.pop(in_flight, ref)

    {:noreply,
     %{state | in_flight: in_flight}
     |> answer(generation, frame, failure_payload())
     |> next_queued()}
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
    if state.conn, do: Mint.HTTP.close(state.conn)
    if state.lease, do: SalixStore.Lease.release(state.lease)
    :ok
  end

  # ---- connecting ----

  defp connect(state) do
    with {:ok, url, ping_ms} <- endpoint(state.connect),
         %URI{scheme: scheme, host: host, port: port} = uri when scheme in ["wss", "ws"] <-
           URI.parse(url),
         {:ok, conn} <-
           Mint.HTTP.connect(http_scheme(scheme), host, port,
             protocols: [:http1],
             transport_opts: [timeout: @connect_timeout_ms]
           ),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme(scheme), conn, path(uri), []) do
      generation = state.generation + 1
      schedule({:upgrade_timeout, ref}, @connect_timeout_ms)

      %{
        state
        | phase: :connecting,
          conn: conn,
          ref: ref,
          upgrade: %{status: nil, headers: []},
          service: service_id(uri),
          ping_ms: ping_ms,
          generation: generation
      }
    else
      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        lost(state, {:connect_failed, reason})

      {:error, reason} ->
        lost(state, {:connect_failed, reason})

      %URI{} ->
        lost(state, :bad_endpoint)
    end
  end

  # The address of a new socket and its ping interval.
  defp endpoint(connect) do
    {key, default} = @base_urls[platform(connect)]
    base = SystemsRuntime.get_env(:salix_im, key, default)

    case Req.post(base <> "/callback/ws/endpoint",
           json: %{"AppID" => connect["app_id"], "AppSecret" => connect["app_secret"]},
           headers: [{"locale", "zh"}],
           retry: false,
           receive_timeout: @connect_timeout_ms
         ) do
      {:ok, %{status: 200, body: %{"code" => 0, "data" => %{"URL" => url} = data}}}
      when is_binary(url) and url != "" ->
        ping_s = get_in(data, ["ClientConfig", "PingInterval"])
        ping_ms = if is_integer(ping_s) and ping_s > 0, do: ping_s * 1_000, else: @default_ping_ms
        {:ok, url, ping_ms}

      {:ok, %{body: %{"code" => code} = body}} ->
        {:error, {:endpoint_refused, code, body["msg"]}}

      {:ok, %{status: status}} ->
        {:error, {:endpoint_status, status}}

      {:error, exception} ->
        {:error, {:endpoint_failed, Exception.message(exception)}}
    end
  end

  defp platform(%{"provider" => "feishu"}), do: "feishu"
  defp platform(_connect), do: "lark"

  defp handler(connect) do
    case platform(connect) do
      "feishu" -> &ProviderHTTP.handle_feishu_socket_event/2
      "lark" -> &LarkInbound.handle_socket_event/2
    end
  end

  defp http_scheme("wss"), do: :https
  defp http_scheme("ws"), do: :http

  defp ws_scheme("wss"), do: :wss
  defp ws_scheme("ws"), do: :ws

  defp path(%URI{path: path, query: query}),
    do: (path || "/") <> if(query in [nil, ""], do: "", else: "?" <> query)

  defp service_id(%URI{query: query}) do
    case Integer.parse(URI.decode_query(query || "")["service_id"] || "") do
      {id, ""} -> id
      _ -> 0
    end
  end

  # ---- upgrade and frames ----

  defp handle_response({:status, ref, status}, %{phase: :connecting, ref: ref} = state),
    do: put_in(state.upgrade.status, status)

  defp handle_response({:headers, ref, headers}, %{phase: :connecting, ref: ref} = state),
    do: put_in(state.upgrade.headers, state.upgrade.headers ++ headers)

  defp handle_response({:done, ref}, %{phase: :connecting, ref: ref} = state) do
    %{status: status, headers: headers} = state.upgrade

    case Mint.WebSocket.new(state.conn, ref, status, headers) do
      {:ok, conn, ws} ->
        Logger.info("lark socket open", connect_id: state.connect["connect_id"])
        state = %{state | conn: conn, ws: ws, upgrade: nil, phase: :open, attempt: 0}
        state = catch_up(state)
        state = send_frame(state, Frame.ping(state.service))
        schedule({:ping, state.generation}, state.ping_ms)
        state

      {:error, conn, reason} ->
        lost(%{state | conn: conn}, {:upgrade_failed, reason})
    end
  end

  defp handle_response({:data, ref, data}, %{phase: :open, ref: ref} = state) do
    case Mint.WebSocket.decode(state.ws, data) do
      {:ok, ws, frames} -> Enum.reduce(frames, %{state | ws: ws}, &handle_frame/2)
      {:error, ws, reason} -> lost(%{state | ws: ws}, {:protocol_error, reason})
    end
  end

  defp handle_response(_response, state), do: state

  defp handle_frame(_frame, %{phase: phase} = state) when phase != :open, do: state

  defp handle_frame({:binary, bytes}, state) do
    case Frame.decode(bytes) do
      {:ok, %Frame.Pbbp2{method: method} = frame} ->
        if method == Frame.control(),
          do: control(state, frame),
          else: data(state, frame)

      :error ->
        Logger.warning("lark socket: dropped an unreadable frame",
          connect_id: state.connect["connect_id"]
        )

        state
    end
  end

  defp handle_frame({:ping, payload}, state), do: send_ws(state, {:pong, payload})
  defp handle_frame({:close, code, _reason}, state), do: lost(state, {:closed, code})
  defp handle_frame(_frame, state), do: state

  # A pong may carry a new client configuration.
  defp control(state, frame) do
    with "pong" <- Frame.header(frame, "type"),
         {:ok, %{"PingInterval" => seconds}} when is_integer(seconds) and seconds > 0 <-
           Jason.decode(frame.payload || "") do
      %{state | ping_ms: seconds * 1_000}
    else
      _ -> state
    end
  end

  defp data(state, frame) do
    type = Frame.header(frame, "type")

    with true <- type in ["event", "card"],
         {:ok, payload, state} <- whole(state, frame),
         {:ok, %{} = envelope} <- Jason.decode(payload) do
      handle_envelope(state, frame, envelope)
    else
      {:partial, state} -> state
      _other -> state
    end
  end

  # An envelope too big for one frame comes in `sum` parts numbered by `seq`.
  defp whole(state, frame) do
    sum = int(Frame.header(frame, "sum"), 1)

    if sum <= 1 do
      {:ok, frame.payload || "", state}
    else
      now = SystemsClock.monotonic_time(:millisecond)
      id = Frame.header(frame, "message_id") || ""
      seq = int(Frame.header(frame, "seq"), 0)

      open =
        state.parts
        |> Enum.reject(fn {_id, entry} -> now - entry.at > @parts_ttl_ms end)
        |> Map.new()

      entry = Map.get(open, id, %{sum: sum, got: %{}, at: now})
      entry = %{entry | got: Map.put(entry.got, seq, frame.payload || "")}

      cond do
        map_size(entry.got) == entry.sum ->
          payload = Enum.map_join(0..(entry.sum - 1), &Map.get(entry.got, &1, ""))
          {:ok, payload, %{state | parts: Map.delete(open, id)}}

        not is_map_key(open, id) and map_size(open) >= @max_open_parts ->
          {:partial, %{state | parts: open}}

        true ->
          {:partial, %{state | parts: Map.put(open, id, entry)}}
      end
    end
  end

  defp handle_envelope(state, frame, envelope) do
    cond do
      map_size(state.in_flight) < @max_in_flight ->
        run(state, state.generation, frame, envelope)

      :queue.len(state.queued) < @max_queued ->
        %{state | queued: :queue.in({state.generation, frame, envelope}, state.queued)}

      true ->
        Logger.warning("lark socket: too many envelopes waiting, one is answered as failed",
          connect_id: state.connect["connect_id"]
        )

        answer(state, state.generation, frame, failure_payload())
    end
  end

  defp run(state, generation, frame, envelope) do
    %{connect: connect, handler: handler} = state

    task =
      SystemsRuntime.TaskSupervisor.async_nolink(state.tasks, fn ->
        handler.(connect, envelope)
      end)

    %{state | in_flight: Map.put(state.in_flight, task.ref, {generation, frame})}
  end

  # An envelope that waited is handled even when its socket is gone: Lark
  # sends it again on the new one, and its receipt keeps it from the Router.
  defp next_queued(state) do
    case :queue.out(state.queued) do
      {{:value, {generation, frame, envelope}}, queued} ->
        run(%{state | queued: queued}, generation, frame, envelope)

      {:empty, _queued} ->
        state
    end
  end

  # Only the socket an envelope came on takes its answer.
  defp answer(%{generation: generation, phase: :open} = state, generation, frame, payload),
    do: send_frame(state, Frame.answer(frame, payload))

  defp answer(state, _generation, _frame, _payload), do: state

  defp failure_payload, do: Jason.encode!(%{"code" => 500})

  # What Lark gets back: the status, and for a card the card that replaces it.
  defp answer_payload(answer) do
    body =
      case answer do
        %{} = answer when map_size(answer) > 0 ->
          %{"code" => 200, "data" => Base.encode64(Jason.encode!(answer))}

        _none ->
          %{"code" => 200}
      end

    Jason.encode!(body)
  end

  # What was said while there was no socket, read back once it is open.
  defp catch_up(%{lost_at: nil} = state), do: state

  defp catch_up(state) do
    %{connect: connect, handler: handler, catch_up: catch_up, lost_at: since} = state

    SystemsRuntime.TaskSupervisor.start_child(state.tasks, fn ->
      catch_up.(connect, since, handler)
    end)

    %{state | lost_at: nil}
  end

  # ---- sending and losing ----

  defp send_frame(state, %Frame.Pbbp2{} = frame),
    do: send_ws(state, {:binary, Frame.encode(frame)})

  defp send_ws(%{phase: :open} = state, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(state.ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      %{state | ws: ws, conn: conn}
    else
      {:error, %Mint.WebSocket{} = ws, reason} -> lost(%{state | ws: ws}, {:send_failed, reason})
      {:error, conn, reason} -> lost(%{state | conn: conn}, {:send_failed, reason})
    end
  end

  defp send_ws(state, _frame), do: state

  defp lost(state, reason) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    attempt = state.attempt + 1
    delay = min(1_000 * Integer.pow(2, min(attempt - 1, 6)), @max_backoff_ms)

    Logger.warning("lark socket lost",
      connect_id: state.connect["connect_id"],
      reason: inspect(reason),
      retry_in_ms: delay
    )

    schedule(:reconnect, delay)

    %{
      state
      | phase: :disconnected,
        lost_at: state.lost_at || SystemsClock.system_time(:millisecond),
        conn: nil,
        ws: nil,
        ref: nil,
        upgrade: nil,
        attempt: attempt,
        parts: %{}
    }
  end

  defp schedule(message, ms), do: SystemsClock.send_after(SystemsRuntime.Proc.self(), message, ms)

  defp int(nil, default), do: default

  defp int(value, default) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> default
    end
  end
end
