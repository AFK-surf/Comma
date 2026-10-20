defmodule SalixWeb.StationRelay do
  @moduledoc """
  Salix as the relay of last resort for stations (`systems/station/README.md`):
  a station whose Connector proves its iroh endpoint id (`relay_register`,
  an Ed25519 signature by the endpoint's key over the run and a challenge
  Salix gave on `connected`) may send iroh packets in binary frames, and
  Salix forwards each to the connection of the endpoint it names, on any node.

  A binary frame is kind `1`, the peer's 32-byte endpoint id, then the packet.
  Going out, the id is the destination; coming in, it is the source. The
  packets are iroh's QUIC, encrypted end to end: Salix reads only the ids.
  Forwarding stays inside one Group: a registration is kept under the
  connection's Group, and a packet goes to the named endpoint's carriers in the
  sender's Group only. A station in several Groups (a desktop signed in to
  several Workspaces) has a carrier in each; one Group has more than one only
  while a run replaces another. The receiving connection also drops
  a packet from another tenant or Group. Each connection may send at most
  `@max_bytes_per_second`; beyond that packets are dropped, as on any lossy
  path, and QUIC sends them again.

  This adds no entity: a registration lives with the Connector run's socket
  process (a `:pg` member) and ends with it.
  """

  @pg __MODULE__.PG
  @kind 1
  @prefix "comma-salix-relay-v1:"
  @max_bytes_per_second 4 * 1024 * 1024

  def child_spec(_opts), do: %{id: @pg, start: {:pg, :start_link, [@pg]}}

  @doc "A fresh challenge for `connected`."
  def challenge, do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(24), padding: false)

  @doc """
  Registers the calling socket process as the carrier of `endpoint_id` when
  the signature proves it. Returns the relay state for the socket.
  """
  def register(run_id, challenge, %{"endpoint_id" => id, "signature" => signature}, scope)
      when is_binary(run_id) and is_binary(challenge) and is_binary(id) and is_binary(signature) do
    with {:ok, key} <- Base.decode16(id, case: :lower),
         32 <- byte_size(key),
         {:ok, sig} <- Base.decode64(signature),
         true <-
           :crypto.verify(:eddsa, :none, @prefix <> run_id <> ":" <> challenge, sig, [
             key,
             :ed25519
           ]) do
      :ok = :pg.join(@pg, {:endpoint, scope, key}, SystemsRuntime.Proc.self())
      {:ok, %{endpoint: key, scope: scope, window_start: monotonic_ms(), window_bytes: 0}}
    else
      _ -> {:error, :relay_registration_refused}
    end
  end

  def register(_run_id, _challenge, _params, _scope), do: {:error, :relay_registration_refused}

  @doc """
  A binary frame from the station: forwarded to the destination's carriers in
  the sender's Group.
  Returns the updated relay state (its rate window).
  """
  def outgoing(nil, _frame), do: nil

  def outgoing(relay, <<@kind, to::binary-size(32), packet::binary>>) do
    now = monotonic_ms()

    relay =
      if now - relay.window_start >= 1_000,
        do: %{relay | window_start: now, window_bytes: 0},
        else: relay

    size = byte_size(packet)

    if relay.window_bytes + size > @max_bytes_per_second do
      relay
    else
      for carrier <- :pg.get_members(@pg, {:endpoint, relay.scope, to}) do
        SystemsRuntime.Proc.send(
          carrier,
          {:station_relay_packet, relay.endpoint, relay.scope, packet}
        )
      end

      %{relay | window_bytes: relay.window_bytes + size}
    end
  end

  def outgoing(relay, _frame), do: relay

  @doc "A packet for this socket's station: the frame to push, or nil when it may not pass."
  def incoming(nil, _from, _scope, _packet), do: nil

  def incoming(%{scope: scope}, from, scope, packet),
    do: <<@kind, from::binary-size(32), packet::binary>>

  def incoming(_relay, _from, _scope, _packet), do: nil

  defp monotonic_ms, do: SystemsClock.monotonic_time(:millisecond)
end
