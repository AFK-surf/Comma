defmodule CommaWeb.StationSocket do
  @moduledoc """
  The station presence WebSocket, `GET /v1/comma/stations/connect` (contract §3).

  The upgrade is signed in `x-stillfail-*` headers over
  `comma-station-connect-v1:<origin>:<station>:<ts>`; an unknown or removed
  station gets HTTP 404 `station_removed` before the upgrade. The socket then
  holds the station online (`CommaWeb.StationPresence`), sends a `state` frame
  on connect and whenever it changes, `revoke` frames as they happen, and
  answers each text `ping` with `pong`.

  Close codes the station acts on: 4000 replaced by a newer socket of the same
  station, 4004 removed from its Group, 4008 silent for three pings.

  The station says where its mesh endpoint may be reached whenever that
  changes: `{"type":"reach","home_relay","addrs"}`. It is kept with the
  socket's presence entry only (`CommaWeb.StationPresence`), never stored, and
  each entry of `peers` in the `state` frame carries it while that station is
  online. A station that says nothing has no such hints.

  Device tool calls (`CommaWeb.StationTools`) ride the same socket: Comma
  pushes `{"type":"tool","id","request"}` and the station answers
  `{"type":"tool_result","id","response"}` with the §8 response header.
  Calls still pending when the socket ends are reported lost to their callers.
  """
  @behaviour WebSock

  import Plug.Conn

  alias Comma.Stations
  alias Comma.Stations.{Config, Signature, Window}
  alias SalixStore.Stations.Events
  alias CommaWeb.StationPresence

  @silent_ms 90_000
  @check_ms 30_000
  # Tool results carry up to 8 MiB of file content, base64-encoded.
  @max_frame_bytes 12 * 1024 * 1024
  # Where a station may be reached: a hint, so bounded and only well-formed.
  @max_addrs 16
  @max_relay_bytes 256

  def upgrade(conn) do
    started = SystemsClock.monotonic_time()
    station = header(conn, "station")

    result =
      cond do
        not websocket?(conn) ->
          {:error, 426, "websocket_required"}

        not Config.enabled?() ->
          {:error, 503, "stations_unavailable"}

        true ->
          case Signature.verify_connect(
                 CommaWeb.StationOrigin.of(conn),
                 station,
                 header(conn, "ts"),
                 header(conn, "signature")
               ) do
            :ok ->
              case Stations.active_station(station) do
                {:ok, _station} -> :ok
                {:error, :station_removed} -> {:error, 404, "station_removed"}
              end

            {:error, :invalid_signature} ->
              {:error, 401, "invalid_signature"}

            {:error, _} ->
              {:error, 400, "invalid_request"}
          end
      end

    Stations.emit_connect(connect_outcome(result), started)

    case result do
      :ok ->
        upgrade_adapter(
          conn,
          :websocket,
          {__MODULE__,
           %{
             station_id: station,
             version: header(conn, "version"),
             origin: CommaWeb.StationOrigin.of(conn)
           }, [compress: false, max_frame_size: @max_frame_bytes]}
        )

      {:error, status, error} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(%{error: error}))
    end
  end

  defp connect_outcome(:ok), do: :ok
  defp connect_outcome({:error, 404, _}), do: {:error, :station_removed}
  defp connect_outcome({:error, 503, _}), do: {:error, :stations_unavailable}
  defp connect_outcome({:error, _, error}), do: {:error, error}

  defp websocket?(conn) do
    conn.method == "GET" and
      Enum.any?(get_req_header(conn, "upgrade"), &(String.downcase(&1) == "websocket"))
  end

  defp header(conn, name) do
    case get_req_header(conn, "x-stillfail-" <> name) do
      [value | _] -> value
      [] -> nil
    end
  end

  @impl WebSock
  def init(%{station_id: station_id} = state) do
    Events.subscribe(Events.station_topic(station_id))
    Events.subscribe(Events.keys_topic())
    # Servers of the release before publish elsewhere, while one runs.
    Window.listen_station(station_id)
    # One socket per station: an older one, on any node, closes with 4000.
    Events.station_replaced(station_id, self())
    Window.tell_replaced(station_id, self())
    :ok = Stations.connected(station_id, state.version)
    SystemsClock.send_after(self(), :check_silence, @check_ms)

    state =
      Map.merge(state, %{
        group_id: nil,
        window_topic: nil,
        last_frame: nil,
        last_heard: now_ms(),
        tools: %{},
        reach: nil
      })

    case refresh(state) do
      {:ok, state, frame} -> {:push, frame, state}
      {:removed, state} -> removed(state)
    end
  end

  @impl WebSock
  def handle_in({"ping", opcode: :text}, state),
    do: {:push, {:text, "pong"}, %{state | last_heard: now_ms()}}

  def handle_in({text, opcode: :text}, state) do
    state = %{state | last_heard: now_ms()}

    case Jason.decode(text) do
      {:ok, %{"type" => "reach"} = body} ->
        {:ok, reached(state, reach(body))}

      {:ok, %{"type" => "tool_result", "id" => id, "response" => response}} ->
        case Map.pop(state.tools, id) do
          {{pid, ref}, tools} ->
            send(pid, {:comma_station_tool_result, ref, response})
            {:ok, %{state | tools: tools}}

          {nil, _tools} ->
            {:ok, state}
        end

      _other ->
        {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, %{state | last_heard: now_ms()}}

  @impl WebSock
  def handle_info({:comma_station, :removed}, state), do: removed(state)

  def handle_info({:comma_station_tool, ref, pid, %{"id" => id} = request}, state)
      when is_binary(id) do
    frame = Jason.encode!(%{"type" => "tool", "id" => id, "request" => request})
    send(pid, {:comma_station_tool_sent, ref})
    {:push, {:text, frame}, %{state | tools: Map.put(state.tools, id, {pid, ref})}}
  end

  def handle_info({:comma_station, :replaced, pid}, state) when pid != self(),
    do: {:stop, :normal, {4000, "replaced"}, state}

  def handle_info({:comma_station_ws, :revoke, revocation}, state) do
    {:push, {:text, Jason.encode!(Map.put(revocation, "type", "revoke"))}, state}
  end

  def handle_info({tag, _}, state)
      when tag in [:comma_station, :comma_station_ws, :comma_station_keys] do
    case refresh(state) do
      {:ok, state, nil} -> {:ok, state}
      {:ok, state, frame} -> {:push, frame, state}
      {:removed, state} -> removed(state)
    end
  end

  def handle_info(:check_silence, state) do
    if now_ms() - state.last_heard > @silent_ms do
      {:stop, :normal, {4008, "silent"}, state}
    else
      SystemsClock.send_after(self(), :check_silence, @check_ms)
      {:ok, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, state) do
    for {_id, {pid, ref}} <- Map.get(state, :tools, %{}),
        do: send(pid, {:comma_station_tool_lost, ref})

    Stations.disconnected(state.station_id)
    :ok
  end

  # Re-reads the owner rows; follows a move to another Group. A new socket has
  # no last frame, so every connect is told the state, and with it the
  # workspace id Salix keeps for the Group now and the ids it had before.
  defp refresh(state) do
    case Stations.presence_state(state.station_id, state.origin) do
      {:ok, frame, station} ->
        state = follow(state, station)
        reach = StationPresence.reach(station.group_id)
        text = Jason.encode!(Map.update!(frame, "peers", &StationPresence.with_reach(&1, reach)))

        if text == state.last_frame,
          do: {:ok, state, nil},
          else: {:ok, %{state | last_frame: text}, {:text, text}}

      {:error, _} ->
        {:removed, state}
    end
  end

  defp follow(%{group_id: group_id} = state, %{group_id: group_id}), do: state

  defp follow(state, station) do
    if old = state.group_id do
      Events.unsubscribe(Events.group_topic(old))
      Window.unlisten(state.window_topic)
      StationPresence.untrack(self(), old, state.station_id)
    end

    Events.subscribe(Events.group_topic(station.group_id))
    window_topic = Window.listen_group(station.group_id)

    {:ok, _ref} = StationPresence.track(self(), station.group_id, state.station_id, meta(state))
    %{state | group_id: station.group_id, window_topic: window_topic}
  end

  defp meta(state), do: %{node: node(), at: SystemsClock.system_time(:second), reach: state.reach}

  # Told where the station is now: its presence entry says so, which tells
  # the Group's sockets (`StationPresence.handle_diff/2`).
  defp reached(%{reach: reach} = state, reach), do: state

  defp reached(state, reach) do
    state = %{state | reach: reach}

    if state.group_id,
      do: StationPresence.update(self(), state.group_id, state.station_id, meta(state))

    state
  end

  # The hints a `reach` frame gives: an http(s) home relay URL and up to
  # 16 `ip:port` direct addresses; anything else is left out, and
  # nothing left is nil.
  defp reach(body) do
    relay = body["home_relay"]

    relay =
      if is_binary(relay) and byte_size(relay) <= @max_relay_bytes and
           match?(
             %URI{scheme: scheme, host: host}
             when scheme in ["http", "https"] and host not in [nil, ""],
             URI.parse(relay)
           ),
         do: relay

    addrs =
      case body["addrs"] do
        list when is_list(list) ->
          list |> Enum.filter(&socket_addr?/1) |> Enum.uniq() |> Enum.take(@max_addrs)

        _ ->
          []
      end

    case {relay, addrs} do
      {nil, []} -> nil
      {nil, addrs} -> %{"addrs" => addrs}
      {relay, []} -> %{"home_relay" => relay}
      {relay, addrs} -> %{"home_relay" => relay, "addrs" => addrs}
    end
  end

  # `a.b.c.d:port` or `[v6]:port`, as iroh writes a socket address.
  defp socket_addr?(value) when is_binary(value) and byte_size(value) <= 64 do
    with [_, host, port] <- Regex.run(~r/\A(.+):(\d{1,5})\z/, value),
         {port, ""} when port in 1..65_535 <- Integer.parse(port),
         {:ok, _ip} <- ip(host) do
      true
    else
      _ -> false
    end
  end

  defp socket_addr?(_value), do: false

  defp ip("[" <> rest) do
    with {v6, "]"} <- String.split_at(rest, -1) do
      v6
      |> String.split("%", parts: 2)
      |> hd()
      |> String.to_charlist()
      |> :inet.parse_ipv6strict_address()
    end
  end

  defp ip(v4), do: :inet.parse_ipv4strict_address(String.to_charlist(v4))

  defp removed(state), do: {:stop, :normal, {4004, "station_removed"}, state}

  defp now_ms, do: SystemsClock.monotonic_time(:millisecond)
end
