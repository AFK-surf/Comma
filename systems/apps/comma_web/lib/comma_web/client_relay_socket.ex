defmodule CommaWeb.ClientRelaySocket do
  @moduledoc """
  The client relay WebSocket, `GET /v1/comma/station-relay?ticket=…`: Salix as
  the relay of last resort between a member's device and the Workspace's
  stations, as `SalixWeb.StationRelay` is between stations. The device asks for
  a one-minute, single-use ticket with its session
  (`POST /v1/comma/workspaces/:id/station-relay`, `Comma.Stations.relay_ticket/3`);
  a ticket that does not redeem gets HTTP 401 before the upgrade.

  On connect the socket sends `{"type":"challenge","challenge"}`. The device
  proves its iroh endpoint id with `{"type":"register","endpoint_id","signature"}`,
  an Ed25519 signature by the endpoint's key over
  `comma-salix-relay-v1:<ticket id>:<challenge>`, and is answered
  `{"type":"registered"}`; then binary frames carry its packets
  (`SalixWeb.StationRelay`: kind `1`, the peer's endpoint id, the packet),
  within the Group the ticket names and at the same rate as a station's. A text
  `ping` is answered `pong`.

  Close codes: 4003 the registration was refused, 4004 the member left the
  Group (checked every minute), 4008 silent for three minutes, 4010 the socket
  is an hour old (the device asks for another ticket). The registration lives
  with the socket.
  """
  @behaviour WebSock

  import Plug.Conn

  alias Comma.Stations
  alias SalixWeb.StationRelay

  @check_ms 60_000
  @silent_ms 180_000
  @lifetime_ms 3_600_000
  # A packet is at most a QUIC datagram; frames beyond this are not packets.
  @max_frame_bytes 64 * 1024

  def upgrade(conn) do
    conn = fetch_query_params(conn)

    result =
      cond do
        not websocket?(conn) -> {:error, 426, "websocket_required"}
        true -> Stations.redeem_relay_ticket(conn.query_params["ticket"])
      end

    case result do
      {:ok, member} ->
        upgrade_adapter(
          conn,
          :websocket,
          {__MODULE__, member, [compress: false, max_frame_size: @max_frame_bytes]}
        )

      {:error, 426, error} ->
        reply(conn, 426, error)

      {:error, :stations_unavailable} ->
        reply(conn, 503, "stations_unavailable")

      {:error, _} ->
        reply(conn, 401, "invalid_ticket")
    end
  end

  defp reply(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
  end

  defp websocket?(conn) do
    conn.method == "GET" and
      Enum.any?(get_req_header(conn, "upgrade"), &(String.downcase(&1) == "websocket"))
  end

  @impl WebSock
  def init(member) do
    challenge = StationRelay.challenge()
    SystemsClock.send_after(self(), :check, @check_ms)
    SystemsClock.send_after(self(), :lifetime, @lifetime_ms)

    state =
      Map.merge(member, %{challenge: challenge, relay: nil, last_heard: now_ms()})

    {:push, {:text, Jason.encode!(%{"type" => "challenge", "challenge" => challenge})}, state}
  end

  @impl WebSock
  def handle_in({"ping", opcode: :text}, state),
    do: {:push, {:text, "pong"}, heard(state)}

  def handle_in({text, opcode: :text}, %{relay: nil} = state) do
    with {:ok, %{"type" => "register"} = params} <- Jason.decode(text),
         {:ok, relay} <-
           StationRelay.register(
             state.ticket_id,
             state.challenge,
             params,
             {state.tenant_id, state.group_id}
           ) do
      {:push, {:text, Jason.encode!(%{"type" => "registered"})}, %{heard(state) | relay: relay}}
    else
      {:error, :relay_registration_refused} ->
        {:stop, :normal, {4003, "registration_refused"}, state}

      _ ->
        {:ok, heard(state)}
    end
  end

  def handle_in({frame, opcode: :binary}, state),
    do: {:ok, %{heard(state) | relay: StationRelay.outgoing(state.relay, frame)}}

  def handle_in(_frame, state), do: {:ok, heard(state)}

  @impl WebSock
  def handle_info({:station_relay_packet, from, scope, packet}, state) do
    case StationRelay.incoming(state.relay, from, scope, packet) do
      nil -> {:ok, state}
      frame -> {:push, {:binary, frame}, state}
    end
  end

  def handle_info(:check, state) do
    cond do
      not Stations.relay_member?(state) ->
        {:stop, :normal, {4004, "not_a_member"}, state}

      now_ms() - state.last_heard > @silent_ms ->
        {:stop, :normal, {4008, "silent"}, state}

      true ->
        SystemsClock.send_after(self(), :check, @check_ms)
        {:ok, state}
    end
  end

  def handle_info(:lifetime, state), do: {:stop, :normal, {4010, "renew"}, state}

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state), do: :ok

  defp heard(state), do: %{state | last_heard: now_ms()}

  defp now_ms, do: SystemsClock.monotonic_time(:millisecond)
end
