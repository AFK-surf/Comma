defmodule SalixWeb.StationRelay do
  @moduledoc """
  Salix as a relay for stations (`systems/station/README.md`), ahead of an iroh
  relay or after it as `Comma.Stations.Config.route_policy/0` says:
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
  `@max_bytes_per_second` and `@max_packets_per_second`, each packet counted with
  its frame; beyond that packets are dropped, as on any lossy path, and QUIC sends
  them again.

  A sending node as a whole has a budget too, in bytes and packets over all its
  connections (config `:station_relay_node_budget`, `{bytes, packets}` a second).
  Each packet is charged before the lookup and each carrier it goes to after it.
  `@node_budget` is an experiment's value for staging, not a measured capacity.
  Windows are aligned, `Budget.window_ms` long, so traffic either side of a boundary
  can pass two windows' budget.

  Packets to another node share the distribution channel with `:erpc`, `:pg` and
  PubSub, so they are sent without waiting on it
  (`SystemsRuntime.Proc.send_nosuspend/2`) and dropped when it is busy. That and the
  budget limit what packets add to the channel. They do not put other traffic
  first: what is already in the channel goes before it.

  `halt/0` stops all relay packets on every node at once, for connections already
  open, and leaves the Connector and requests as they are. It stops everything this
  module carries, a desktop's and a client's alike: Salix cannot tell them apart.

  A socket process writes one frame at a time and blocks on a peer that reads
  slowly, so what comes for it waits in its mailbox. Before a packet goes in,
  the mailbox of its carrier is looked at, on the carrier's node (`Gate`: a
  process's queue can be read only there, so a `Gate` that is not reading has no
  cap of its own and grows at the rate the budgets let through): with `@max_queued` messages of any
  kind waiting, the packet is dropped. That bounds the backlog, about
  `@max_queued` messages (senders checking at the same moment may each add one).
  It does not put control first: a heartbeat or an answer still waits behind
  what is already in the mailbox and in the TCP connection, as packets and
  control messages share one socket.

  This adds no entity: a registration lives with the Connector run's socket
  process (a `:pg` member) and ends with it.
  """

  @pg __MODULE__.PG
  @kind 1
  @prefix "comma-salix-relay-v1:"
  @max_bytes_per_second 4 * 1024 * 1024
  @max_packets_per_second 4096
  # A packet costs its frame as well: an empty one is not free.
  @frame_bytes 33
  @node_budget {2 * 1024 * 1024, 2000}
  @max_queued 128

  def child_spec(_opts), do: %{id: @pg, start: {:pg, :start_link, [@pg]}}

  @doc "What the node's budget is counted in; kept when `Gate`, which makes it, restarts."
  def make_budget do
    if :persistent_term.get(__MODULE__, nil) == nil,
      do: :persistent_term.put(__MODULE__, __MODULE__.Budget.new())

    :ok
  end

  @doc """
  Stops relay packets on every node, on connections already open, until `resume/0`. From `bin/comma rpc`. A node that
  starts afterwards goes by `COMMA_STATION_RELAY_STOPPED`. Returns each node's answer.
  """
  def halt, do: set_stopped(true)

  @doc "Lets relay packets go again on every node."
  def resume, do: set_stopped(false)

  defp set_stopped(stopped) do
    :erpc.multicall(
      [SystemsRuntime.Proc.node() | Node.list()],
      SystemsRuntime,
      :put_env,
      [:salix_web, :station_relay_stopped, stopped],
      5_000
    )
  end

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

      {:ok,
       %{
         endpoint: key,
         scope: scope,
         window_start: monotonic_ms(),
         window_bytes: 0,
         window_packets: 0
       }}
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
        do: %{relay | window_start: now, window_bytes: 0, window_packets: 0},
        else: relay

    size = byte_size(packet) + @frame_bytes

    if relay.window_bytes + size > @max_bytes_per_second or
         relay.window_packets >= @max_packets_per_second or
         SystemsRuntime.get_env(:salix_web, :station_relay_stopped, false) or
         not spend(0, 1) do
      relay
    else
      message = {:station_relay_packet, relay.endpoint, relay.scope, packet}

      :pg.get_members(@pg, {:endpoint, relay.scope, to})
      |> Enum.with_index()
      |> Enum.each(fn {carrier, nth} ->
        # The one before the lookup paid for the first.
        if spend(size, if(nth == 0, do: 0, else: 1)),
          do: forward(carrier, message)
      end)

      %{relay | window_bytes: relay.window_bytes + size, window_packets: relay.window_packets + 1}
    end
  end

  def outgoing(relay, _frame), do: relay

  defp forward(carrier, message) do
    if SystemsRuntime.Proc.node(carrier) == SystemsRuntime.Proc.node(),
      do: deliver(carrier, message),
      else:
        SystemsRuntime.Proc.send_nosuspend(
          {__MODULE__.Gate, SystemsRuntime.Proc.node(carrier)},
          {:deliver, carrier, message}
        )
  end

  # What the node may still spend in this window. Over it, the packet is dropped.
  defp spend(bytes, packets) do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        false

      counts ->
        budget = SystemsRuntime.get_env(:salix_web, :station_relay_node_budget, @node_budget)
        __MODULE__.Budget.take(counts, bytes, packets, budget, &monotonic_ms/0)
    end
  end

  @doc "On the carrier's node: a packet goes into a mailbox that has room, and is otherwise dropped."
  def deliver(carrier, message) do
    case SystemsRuntime.Proc.info(carrier, :message_queue_len) do
      {:message_queue_len, queued} when queued < @max_queued ->
        SystemsRuntime.Proc.send(carrier, message)
        :ok

      _full_or_gone ->
        :dropped
    end
  end

  @doc "A packet for this socket's station: the frame to push, or nil when it may not pass."
  def incoming(nil, _from, _scope, _packet), do: nil

  def incoming(%{scope: scope}, from, scope, packet),
    do: <<@kind, from::binary-size(32), packet::binary>>

  def incoming(_relay, _from, _scope, _packet), do: nil

  defp monotonic_ms, do: SystemsClock.monotonic_time(:millisecond)
end

defmodule SalixWeb.StationRelay.Budget do
  @moduledoc """
  A node's relay budget over one aligned window, shared by all its processes: the
  window, the bytes and the packets spent in it are one word, changed by one
  compare-and-swap. That swap is the only point at which a charge happens or a new
  window starts, so a window's counts are never cleared under a charge already made.

  The word is read before the clock. Time on a node does not go back, so a charger's
  window is never older than the word's: a late charger cannot start an old window
  over a newer one. A charge past the budget changes nothing, so the counts never
  pass the budget, and the budget is clamped to what the word holds, so they cannot
  overflow. The word holds 19 bits of window (about 36 hours), 26 of bytes and 14 of
  packets, 59 in all, so each read and swap stays a small integer. After that many
  hours exactly with no traffic, a stale word can count against one window: it only
  drops more.

  Windows are aligned to the clock, so traffic either side of a boundary can pass two
  windows' budget.
  """
  import Bitwise

  @window_ms 250
  @window_bits 19
  @bytes_bits 26
  @packets_bits 14
  @max_bytes (1 <<< @bytes_bits) - 1
  @max_packets (1 <<< @packets_bits) - 1

  def window_ms, do: @window_ms

  @doc "The word the budget is counted in."
  def new, do: :atomics.new(1, signed: false)

  @doc """
  Charges `bytes` and `packets` against `{bytes, packets}` a second, both or neither.
  `now_ms` is the clock. `before_swap` is for a test, to stop a charger at that point.
  """
  def take(counts, bytes, packets, budget, now_ms, before_swap \\ fn -> :ok end) do
    word = :atomics.get(counts, 1)

    case charge(word, window(now_ms.()), bytes, packets, per_window(budget)) do
      :over ->
        false

      next ->
        before_swap.()

        if :atomics.compare_exchange(counts, 1, word, next) == :ok,
          do: true,
          else: take(counts, bytes, packets, budget, now_ms, before_swap)
    end
  end

  @doc "`{window, bytes, packets}` as the word has them."
  def spent(counts), do: unpack(:atomics.get(counts, 1))

  @doc "The word after a charge in `window` of the masked clock, or `:over` when it does not fit."
  def charge(word, window, bytes, packets, {max_bytes, max_packets}) do
    {spent_bytes, spent_packets} =
      case unpack(word) do
        {^window, spent_bytes, spent_packets} -> {spent_bytes, spent_packets}
        _ -> {0, 0}
      end

    if spent_bytes + bytes > max_bytes or spent_packets + packets > max_packets,
      do: :over,
      else: pack(window, spent_bytes + bytes, spent_packets + packets)
  end

  @doc "A budget a second as a window holds it, within what the word can count."
  def per_window({bytes, packets}) do
    {min(div(bytes * @window_ms, 1000), @max_bytes),
     min(div(packets * @window_ms, 1000), @max_packets)}
  end

  @doc "A clock in milliseconds as the word's window."
  def window(ms), do: Integer.floor_div(ms, @window_ms) &&& (1 <<< @window_bits) - 1

  defp pack(window, bytes, packets),
    do: window <<< (@bytes_bits + @packets_bits) ||| bytes <<< @packets_bits ||| packets

  defp unpack(word),
    do:
      {word >>> (@bytes_bits + @packets_bits), word >>> @packets_bits &&& @max_bytes,
       word &&& @max_packets}
end

defmodule SalixWeb.StationRelay.Gate do
  @moduledoc """
  A node's way in for packets from other nodes: only here can a carrier's
  mailbox be read before a packet goes into it (`SalixWeb.StationRelay`). One
  process, so a sender's packets stay in order. It writes to no socket, so a
  slow peer does not hold it.
  """
  use SystemsRuntime.Server

  def start_link(_opts), do: SystemsRuntime.Server.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    SalixWeb.StationRelay.make_budget()
    {:ok, nil}
  end

  @impl true
  def handle_info({:deliver, carrier, message}, state) do
    SalixWeb.StationRelay.deliver(carrier, message)
    {:noreply, state}
  end
end
