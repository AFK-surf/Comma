defmodule SalixAgent.Browser.Connection do
  @moduledoc """
  Bounded CDP transport over Mint. No reconnect or command replay.
  The socket process retains one frame per attached target and never forwards
  page events into a consumer mailbox.
  """
  use SystemsRuntime.Server

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts)

  def command(pid, method, params \\ %{}, session \\ nil, timeout \\ 15_000),
    do: SystemsClock.call(pid, {:command, method, params, session, timeout}, timeout + 2000)

  def storage_session(pid, session),
    do: SystemsRuntime.Server.call(pid, {:storage_session, session})

  def origins(pid), do: SystemsRuntime.Server.call(pid, :origins)
  def forget_origin(pid, origin), do: SystemsRuntime.Server.call(pid, {:forget_origin, origin})
  def remember_origin(pid, origin), do: SystemsRuntime.Server.call(pid, {:origin, origin})

  def frame(pid, session), do: SystemsRuntime.Server.call(pid, {:frame, session})
  def dialog(pid, session), do: SystemsRuntime.Server.call(pid, {:dialog, session})
  @doc "How many loads `frame` started, and its phase: `:navigating`, `:loading` or `:idle`."
  def load(pid, session, frame), do: SystemsRuntime.Server.call(pid, {:load, session, frame})
  def clear_frame(pid, session), do: SystemsRuntime.Server.call(pid, {:clear_frame, session})
  def generation(pid, session), do: SystemsRuntime.Server.call(pid, {:generation, session})

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :browser_connection, message: :redacted, log: []})

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    SystemsRuntime.Proc.monitor(owner)
    uri = URI.parse(Keyword.fetch!(opts, :url))
    scheme = if uri.scheme == "wss", do: :https, else: :http
    ws_scheme = if uri.scheme == "wss", do: :wss, else: :ws
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    with {:ok, conn} <-
           Mint.HTTP.connect(
             scheme,
             uri.host,
             uri.port || if(scheme == :https, do: 443, else: 80),
             protocols: [:http1],
             transport_opts: [timeout: 10_000]
           ),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, conn, path, Keyword.get(opts, :headers, [])) do
      timer = SystemsClock.send_after(SystemsRuntime.Proc.self(), :upgrade_timeout, 10_000)
      SystemsClock.awaiting({__MODULE__, :upgrade})

      {:ok,
       %{
         conn: conn,
         ref: ref,
         ws: nil,
         status: nil,
         headers: [],
         timer: timer,
         owner: owner,
         serial: 0,
         pending: %{},
         frames: %{},
         dialogs: %{},
         loading: %{},
         sessions: MapSet.new(),
         generations: %{},
         origins: Map.new(Enum.with_index(Keyword.get(opts, :origins, []))),
         origin_queue:
           :gb_sets.from_list(
             Enum.with_index(Keyword.get(opts, :origins, []))
             |> Enum.map(fn {origin, i} -> {i, origin} end)
           ),
         origin_serial: length(Keyword.get(opts, :origins, [])),
         origin_access: Keyword.get(opts, :origin_access, %{}),
         storage_session: nil
       }}
    else
      _ -> {:stop, :browser_driver_unavailable}
    end
  end

  @impl true
  def handle_call({:command, method, params, session, timeout}, from, state) do
    cond do
      map_size(state.pending) >= 32 ->
        {:reply, {:error, :browser_driver_busy}, state}

      # The page answers nothing while a JavaScript dialog is open. Input
      # after the event that opened it (a key or button release) is dropped
      # and the action ends there; any other command fails unsent.
      Map.has_key?(state.dialogs, session) and String.starts_with?(method, "Input.") ->
        {:reply, {:ok, %{"dialog" => true}}, state}

      Map.has_key?(state.dialogs, session) and method != "Page.handleJavaScriptDialog" ->
        {:reply, {:error, "dialog_open"}, state}

      true ->
        id = state.serial + 1
        message = %{id: id, method: method, params: params}
        message = if session, do: Map.put(message, :sessionId, session), else: message
        timer = SystemsClock.send_after(SystemsRuntime.Proc.self(), {:timeout, id}, timeout)
        pending = Map.put(state.pending, id, {from, timer, message})
        # The browser answers in real time: a manual clock holds while it does.
        SystemsClock.awaiting({__MODULE__, id})
        state = %{state | serial: id, pending: pending}
        if state.ws, do: {:noreply, send_json(state, message)}, else: {:noreply, state}
    end
  end

  def handle_call({:storage_session, session}, _, state),
    do: {:reply, :ok, %{state | storage_session: session}}

  def handle_call(:origins, _, state) do
    count = min(4, map_size(state.origins))
    {origins, state} = take_origins(state, count, [])

    {:reply,
     {:ok, Enum.reverse(origins), map_size(state.origins),
      Map.take(state.origin_access, origins)}, state}
  end

  def handle_call({:forget_origin, origin}, _, state) do
    case Map.pop(state.origins, origin) do
      {nil, _} ->
        {:reply, :ok, state}

      {serial, origins} ->
        {:reply, :ok,
         %{
           state
           | origins: origins,
             origin_access: Map.delete(state.origin_access, origin),
             origin_queue: :gb_sets.delete({serial, origin}, state.origin_queue)
         }}
    end
  end

  def handle_call({:origin, origin}, _, state), do: {:reply, :ok, remember(state, origin)}

  def handle_call({:frame, session}, _, state),
    do: {:reply, Map.get(state.frames, session), state}

  def handle_call({:generation, session}, _, state),
    do: {:reply, Map.get(state.generations, session, 0), state}

  def handle_call({:dialog, session}, _, state),
    do: {:reply, Map.get(state.dialogs, session), state}

  def handle_call({:load, session, frame}, _, state),
    do: {:reply, get_in(state.loading, [session, frame]) || {0, :idle}, state}

  def handle_call({:clear_frame, session}, _, state),
    do: {:reply, :ok, %{state | frames: Map.delete(state.frames, session)}}

  @impl true
  def handle_info(:upgrade_timeout, %{ws: nil} = state), do: {:stop, :normal, state}
  def handle_info(:upgrade_timeout, state), do: {:noreply, state}

  def handle_info({:timeout, id}, state) do
    if Map.has_key?(state.pending, id) do
      SystemsClock.replied({__MODULE__, id})
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        try do
          {:noreply, Enum.reduce(responses, %{state | conn: conn}, &response/2)}
        catch
          :connection_failed -> {:stop, :normal, %{state | conn: conn}}
        end

      {:error, conn, _, _} ->
        {:stop, :normal, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  defp response({:status, _, status}, state), do: %{state | status: status}
  defp response({:headers, _, headers}, state), do: %{state | headers: headers}

  defp response({:done, _}, state) do
    case Mint.WebSocket.new(state.conn, state.ref, state.status, state.headers) do
      {:ok, conn, ws} ->
        SystemsClock.cancel_timer(state.timer)
        SystemsClock.replied({__MODULE__, :upgrade})

        Enum.reduce(Enum.sort(state.pending), %{state | conn: conn, ws: ws, headers: []}, fn {_,
                                                                                              {_,
                                                                                               _,
                                                                                               message}},
                                                                                             acc ->
          send_json(acc, message)
        end)

      _ ->
        throw(:connection_failed)
    end
  end

  defp response({:data, _, data}, state) do
    # Bound incomplete WebSocket messages as well as decoded CDP packets.
    case Mint.WebSocket.decode(state.ws, data) do
      {:ok, ws, frames} ->
        fragment_size = if ws.fragment, do: byte_size(elem(ws.fragment, 3)), else: 0
        if byte_size(ws.buffer) + fragment_size > 2_097_152, do: throw(:connection_failed)
        Enum.reduce(frames, %{state | ws: ws}, &receive_frame/2)

      _ ->
        throw(:connection_failed)
    end
  end

  defp response(_, state), do: state

  defp receive_frame({:text, data}, state) when byte_size(data) <= 2_097_152 do
    case Jason.decode(data) do
      {:ok, %{"id" => id} = packet} ->
        case Map.pop(state.pending, id) do
          {nil, _} ->
            state

          {{from, timer, command}, pending} ->
            SystemsClock.cancel_timer(timer)
            SystemsClock.replied({__MODULE__, id})

            result =
              if Map.has_key?(packet, "result"),
                do: {:ok, packet["result"]},
                else: {:error, "browser_operation_failed"}

            state = track_session(state, command, result)
            SystemsRuntime.Server.reply(from, result)
            %{state | pending: pending}
        end

      {:ok, %{"method" => "Fetch.requestPaused", "sessionId" => session, "params" => params}}
      when session == state.storage_session and not is_nil(session) ->
        # Only the private storage target enables Fetch. No request from this
        # target reaches a website or runs website scripts during restoration.
        next = %{state | serial: state.serial + 1}

        send_json(next, %{
          id: next.serial,
          sessionId: session,
          method: "Fetch.fulfillRequest",
          params: %{
            requestId: params["requestId"],
            responseCode: 200,
            responseHeaders: [%{name: "Content-Type", value: "text/html"}],
            body: Base.encode64("<!doctype html><title>Storage</title>")
          }
        })

      {:ok,
       %{
         "method" => "Page.frameNavigated",
         "sessionId" => session,
         "params" => %{"frame" => frame}
       }}
      when session != state.storage_session ->
        remember(state, frame["securityOrigin"])

      {:ok, %{"method" => "Page.screencastFrame", "sessionId" => session, "params" => frame}} ->
        state =
          send_json(state, %{
            id: state.serial + 1,
            method: "Page.screencastFrameAck",
            sessionId: session,
            params: %{sessionId: frame["sessionId"]}
          })

        state = %{state | serial: state.serial + 1}
        previous = state.frames[session]
        now = SystemsClock.monotonic_time(:millisecond)

        if MapSet.member?(state.sessions, session) and byte_size(frame["data"] || "") <= 1_400_000 and
             (is_nil(previous) or now - previous["received_at"] >= 100) do
          value =
            frame
            |> Map.take(~w(data metadata))
            |> Map.put("received_at", now)
            |> Map.put("sequence", SystemsRuntime.Proc.unique_integer([:positive, :monotonic]))

          %{state | frames: Map.put(state.frames, session, value)}
        else
          state
        end

      # A JavaScript dialog blocks page scripts until it is handled. The driver
      # reports it instead of waiting on an evaluation that cannot finish.
      {:ok,
       %{"method" => "Page.javascriptDialogOpening", "sessionId" => session, "params" => params}} ->
        dialog = %{
          "type" => params["type"],
          "message" => String.slice(params["message"] || "", 0, 2000),
          "default_prompt" => String.slice(params["defaultPrompt"] || "", 0, 2000)
        }

        # The page answers none of this session's commands until the dialog
        # closes. Each one was delivered and opened it, or runs on after it
        # closes: answer it now. A late answer finds no pending command.
        {opened, pending} =
          Enum.split_with(state.pending, fn {_, {_, _, message}} ->
            message[:sessionId] == session
          end)

        Enum.each(opened, fn {id, {from, timer, _}} ->
          SystemsClock.cancel_timer(timer)
          SystemsClock.replied({__MODULE__, id})
          SystemsRuntime.Server.reply(from, {:ok, %{"dialog" => true}})
        end)

        %{state | dialogs: Map.put(state.dialogs, session, dialog), pending: Map.new(pending)}

      {:ok, %{"method" => "Page.javascriptDialogClosed", "sessionId" => session}} ->
        %{state | dialogs: Map.delete(state.dialogs, session)}

      # A frame navigates from the start of a load until its new document
      # commits (or the load is cancelled), then loads until the document and
      # its resources have loaded. A click's navigation starts before the
      # browser acknowledges the click.
      {:ok, %{"method" => "Page.frameStartedLoading", "sessionId" => session, "params" => params}} ->
        {starts, _} = get_in(state.loading, [session, params["frameId"]]) || {0, :idle}
        frames = Map.get(state.loading, session, %{})
        frames = Map.put(frames, params["frameId"], {starts + 1, :navigating})
        %{state | loading: Map.put(state.loading, session, frames)}

      {:ok, %{"method" => "Page.frameNavigated", "sessionId" => session, "params" => params}} ->
        load_phase(state, session, params["frame"]["id"], :loading)

      {:ok,
       %{"method" => "Page.navigatedWithinDocument", "sessionId" => session, "params" => params}} ->
        state
        |> load_phase(session, params["frameId"], :loading)
        |> next_generation(session)

      {:ok, %{"method" => "Page.frameStoppedLoading", "sessionId" => session, "params" => params}} ->
        load_phase(state, session, params["frameId"], :idle)

      {:ok, %{"method" => "Runtime.executionContextsCleared", "sessionId" => session}} ->
        next_generation(state, session)

      {:ok, %{"method" => "Target.detachedFromTarget", "params" => %{"sessionId" => session}}} ->
        %{
          state
          | sessions: MapSet.delete(state.sessions, session),
            frames: Map.delete(state.frames, session),
            dialogs: Map.delete(state.dialogs, session),
            loading: Map.delete(state.loading, session),
            generations: Map.delete(state.generations, session)
        }

      {:ok, _} ->
        state

      _ ->
        throw(:connection_failed)
    end
  end

  defp receive_frame({:ping, data}, state), do: send_frame(state, {:pong, data})
  defp receive_frame({:pong, _}, state), do: state
  defp receive_frame(_, _), do: throw(:connection_failed)

  defp next_generation(state, session) do
    if MapSet.member?(state.sessions, session),
      do: %{state | generations: Map.update(state.generations, session, 1, &(&1 + 1))},
      else: state
  end

  defp load_phase(state, session, frame, phase) do
    case get_in(state.loading, [session, frame]) do
      {starts, _} -> put_in(state.loading[session][frame], {starts, phase})
      nil -> state
    end
  end

  defp take_origins(state, 0, origins), do: {origins, state}

  defp take_origins(state, count, origins) do
    {{_, origin}, queue} = :gb_sets.take_smallest(state.origin_queue)
    serial = state.origin_serial + 1

    state = %{
      state
      | origins: Map.put(state.origins, origin, serial),
        origin_queue: :gb_sets.add({serial, origin}, queue),
        origin_serial: serial
    }

    take_origins(state, count - 1, [origin | origins])
  end

  defp remember(state, origin) when is_binary(origin) do
    uri = URI.parse(origin)

    cond do
      uri.scheme not in ["http", "https"] or is_nil(uri.host) ->
        state

      Map.has_key?(state.origins, origin) ->
        %{
          state
          | origin_access:
              Map.put(state.origin_access, origin, SystemsClock.system_time(:microsecond))
        }

      true ->
        serial = state.origin_serial + 1

        %{
          state
          | origins: Map.put(state.origins, origin, serial),
            origin_queue: :gb_sets.add({serial, origin}, state.origin_queue),
            origin_serial: serial,
            origin_access:
              Map.put(state.origin_access, origin, SystemsClock.system_time(:microsecond))
        }
    end
  end

  defp remember(state, _), do: state

  defp track_session(state, %{method: "Target.attachToTarget"}, {:ok, %{"sessionId" => session}}) do
    if MapSet.size(state.sessions) >= 33, do: throw(:connection_failed)
    %{state | sessions: MapSet.put(state.sessions, session)}
  end

  defp track_session(state, _, _), do: state

  defp send_json(state, message), do: send_frame(state, {:text, Jason.encode!(message)})

  defp send_frame(state, frame) do
    with {:ok, ws, bytes} <- Mint.WebSocket.encode(state.ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, bytes) do
      %{state | conn: conn, ws: ws}
    else
      _ -> throw(:connection_failed)
    end
  end

  @impl true
  def terminate(_, state) do
    Enum.each(state.pending, fn {_, {from, _, _}} ->
      SystemsRuntime.Server.reply(from, {:error, :browser_outcome_unknown})
    end)

    Mint.HTTP.close(state.conn)
    :ok
  end
end
