defmodule SalixWeb.StationRelayTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Salix as a relay (`SalixWeb.StationRelay`): a socket that
  proves its endpoint id by signature carries packets for it; a packet goes to
  the carrier of the endpoint it names in the sender's Group, also when the
  endpoint has carriers in several Groups, and passes only within one Group; a
  wrong signature registers nothing, and a sender over its rate loses packets.
  """
  use SystemsClock.Case, async: false
  import Bitwise
  import SystemsClock.Assertions

  alias SalixWeb.StationRelay
  alias SalixWeb.StationRelay.Budget

  # Waits settle the carriers on a manual clock: no real time passes, and the
  # rate window stays where it opened.
  setup do
    SystemsClock.manual(scope: ["Elixir.SalixWeb.StationRelayTest"])
    # Each test's manual clock starts over, so it can land in a budget window another test spent.
    :atomics.put(:persistent_term.get(StationRelay), 1, 0)
    # Out of the way, but for what a test says of it.
    SystemsRuntime.put_env(:salix_web, :station_relay_node_budget, {1 <<< 40, 1 <<< 40})

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_web, :station_relay_node_budget)
      SystemsRuntime.delete_env(:salix_web, :station_relay_stopped)
      SystemsClock.reset()
    end)
  end

  @prefix "comma-salix-relay-v1:"

  defp keypair do
    {public, private} = SystemsRuntime.Proc.generate_key(:eddsa, :ed25519)
    {public, private}
  end

  defp signed(public, private, run, challenge) do
    %{
      "endpoint_id" => Base.encode16(public, case: :lower),
      "signature" =>
        Base.encode64(
          SystemsRuntime.Proc.sign(:eddsa, :none, @prefix <> run <> ":" <> challenge, [
            private,
            :ed25519
          ])
        )
    }
  end

  # A carrier socket in its own process: it registers and reports what reaches it.
  defp carrier(public, private, scope) do
    test = SystemsRuntime.Proc.self()

    pid =
      SystemsRuntime.Proc.spawn_link(fn ->
        {:ok, relay} =
          StationRelay.register("run-b", "c-b", signed(public, private, "run-b", "c-b"), scope)

        SystemsRuntime.Proc.send(test, {:registered, SystemsRuntime.Proc.self()})

        receive_loop = fn loop ->
          SystemsRuntime.Proc.receive do
            {:station_relay_packet, from, from_scope, packet} ->
              SystemsRuntime.Proc.send(
                test,
                {:arrived, SystemsRuntime.Proc.self(),
                 StationRelay.incoming(relay, from, from_scope, packet)}
              )

              loop.(loop)

            {:ping, from} ->
              SystemsRuntime.Proc.send(from, {:pong, SystemsRuntime.Proc.self()})
              loop.(loop)

            :stop ->
              :ok
          end
        end

        receive_loop.(receive_loop)
      end)

    settle_receive({:registered, ^pid})
    pid
  end

  test "a proven endpoint's packets reach the endpoint they name, within one Group" do
    {pa, ka} = keypair()
    {pb, kb} = keypair()
    scope = {"ten_1", "grp_1"}
    b = carrier(pb, kb, scope)
    {:ok, relay} = StationRelay.register("run-a", "c-a", signed(pa, ka, "run-a", "c-a"), scope)

    _relay = StationRelay.outgoing(relay, <<1, pb::binary, "hello">>)
    settle_receive({:arrived, ^b, <<1, from::binary-size(32), "hello">>})
    assert from == pa

    # From another Group: not forwarded, and dropped by a receiver given it.
    {:ok, other} =
      StationRelay.register("run-c", "c-c", signed(pa, ka, "run-c", "c-c"), {"ten_1", "grp_2"})

    StationRelay.outgoing(other, <<1, pb::binary, "intruder">>)
    SystemsRuntime.Proc.send(b, {:ping, SystemsRuntime.Proc.self()})
    settle_receive({:pong, ^b})
    refute_received {:arrived, ^b, _}
    {:ok, receiver} = StationRelay.register("run-b", "c-b", signed(pb, kb, "run-b", "c-b"), scope)
    assert StationRelay.incoming(receiver, pa, {"ten_1", "grp_2"}, "intruder") == nil
    SystemsRuntime.Proc.send(b, :stop)
  end

  # A desktop station in two Groups registers its one endpoint on a Connector run in each.
  test "a packet reaches the carrier in the sender's Group when the endpoint has carriers in two" do
    {pa, ka} = keypair()
    {pb, kb} = keypair()
    b1 = carrier(pb, kb, {"ten_1", "grp_1"})
    b2 = carrier(pb, kb, {"ten_1", "grp_2"})

    for {scope, b, other} <- [{{"ten_1", "grp_1"}, b1, b2}, {{"ten_1", "grp_2"}, b2, b1}] do
      {:ok, relay} = StationRelay.register("run-a", "c-a", signed(pa, ka, "run-a", "c-a"), scope)
      StationRelay.outgoing(relay, <<1, pb::binary, "hello">>)
      settle_receive({:arrived, ^b, <<1, from::binary-size(32), "hello">>})
      assert from == pa
      # The other carrier answers a ping only after anything sent to it before.
      SystemsRuntime.Proc.send(other, {:ping, SystemsRuntime.Proc.self()})
      settle_receive({:pong, ^other})
      refute_received {:arrived, ^other, _}
    end

    SystemsRuntime.Proc.send(b1, :stop)
    SystemsRuntime.Proc.send(b2, :stop)
  end

  test "a wrong signature registers nothing, and a sender over its rate loses packets" do
    {pa, ka} = keypair()
    {pb, kb} = keypair()

    assert {:error, :relay_registration_refused} =
             StationRelay.register(
               "run-a",
               "challenge",
               signed(pa, ka, "run-a", "other"),
               {"t", "g"}
             )

    assert {:error, :relay_registration_refused} =
             StationRelay.register(
               "run-a",
               "challenge",
               %{"endpoint_id" => "zz", "signature" => "x"},
               {"t", "g"}
             )

    b = carrier(pb, kb, {"t", "g"})
    {:ok, relay} = StationRelay.register("run-a", "c", signed(pa, ka, "run-a", "c"), {"t", "g"})
    big = :binary.copy(<<0>>, 3 * 1024 * 1024)
    relay = StationRelay.outgoing(relay, <<1, pb::binary, big::binary>>)
    settle_receive({:arrived, ^b, frame})
    assert is_binary(frame)
    StationRelay.outgoing(relay, <<1, pb::binary, big::binary>>)
    settle_refute_receive({:arrived, _, _}, 50)
    SystemsRuntime.Proc.send(b, :stop)
  end

  test "a packet does not go into a mailbox with too much waiting, whatever else may" do
    {pa, ka} = keypair()
    {pb, kb} = keypair()
    scope = {"tenant", "group"}
    test = SystemsRuntime.Proc.self()

    # A socket blocked on a peer that reads slowly: it takes nothing from its mailbox until let go.
    blocked =
      SystemsRuntime.Proc.spawn_link(fn ->
        {:ok, _relay} =
          StationRelay.register("run-b", "c-b", signed(pb, kb, "run-b", "c-b"), scope)

        SystemsRuntime.Proc.send(test, :registered)

        SystemsRuntime.Proc.receive do
          :let_go -> :ok
        end

        SystemsRuntime.Proc.send(
          test,
          {:waited, SystemsRuntime.Proc.info(SystemsRuntime.Proc.self(), :messages)}
        )
      end)

    settle_receive(:registered)
    {:ok, relay} = StationRelay.register("run-a", "c-a", signed(pa, ka, "run-a", "c-a"), scope)

    for n <- 1..1000, do: StationRelay.outgoing(relay, <<1, pb::binary, n::32>>)

    assert SystemsRuntime.Proc.info(blocked, :message_queue_len) == {:message_queue_len, 128}

    # Anything else still goes in, and the packets stay kept out.
    SystemsRuntime.Proc.send(blocked, :heartbeat)
    StationRelay.outgoing(relay, <<1, pb::binary, 1001::32>>)
    assert SystemsRuntime.Proc.info(blocked, :message_queue_len) == {:message_queue_len, 129}

    SystemsRuntime.Proc.send(blocked, :let_go)
    settle_receive({:waited, {:messages, messages}})
    assert List.last(messages) == :heartbeat

    # The first ones, in order: what came after the room ran out is what was lost.
    assert for({:station_relay_packet, ^pa, ^scope, <<n::32>>} <- messages, do: n) ==
             Enum.to_list(1..128)
  end

  # A socket that takes nothing from its mailbox, registered as `to` in `scope`.
  defp holding(public, private, scope) do
    test = SystemsRuntime.Proc.self()

    pid =
      SystemsRuntime.Proc.spawn_link(fn ->
        {:ok, _} = StationRelay.register("h", "c", signed(public, private, "h", "c"), scope)
        SystemsRuntime.Proc.send(test, {:holding, SystemsRuntime.Proc.self()})

        SystemsRuntime.Proc.receive do
          :never -> :ok
        end
      end)

    settle_receive({:holding, ^pid})
    pid
  end

  defp held(pid) do
    {:message_queue_len, queued} = SystemsRuntime.Proc.info(pid, :message_queue_len)
    queued
  end

  test "an empty packet still counts: a connection's packets are capped as its bytes are" do
    {pa, ka} = keypair()
    {:ok, relay} = StationRelay.register("run", "c", signed(pa, ka, "run", "c"), {"t", "empty"})
    to = SystemsRuntime.Proc.random_bytes(32)

    relay =
      Enum.reduce(1..5000, relay, fn _, r -> StationRelay.outgoing(r, <<1, to::binary>>) end)

    assert relay.window_packets == 4096
    assert relay.window_bytes == 4096 * 33
  end

  test "the node's budget holds across connections, in packets and in bytes, and comes back" do
    {pa, ka} = keypair()
    {pb, kb} = keypair()
    {pc, kc} = keypair()
    scope = {"t", "budget"}
    target = holding(pc, kc, scope)
    {:ok, one} = StationRelay.register("a", "c", signed(pa, ka, "a", "c"), scope)
    {:ok, two} = StationRelay.register("b", "c", signed(pb, kb, "b", "c"), scope)

    # 3 packets a window: two connections share them.
    SystemsRuntime.put_env(:salix_web, :station_relay_node_budget, {1 <<< 40, 12})
    SystemsClock.advance(250)
    one = StationRelay.outgoing(one, <<1, pc::binary, "p">>)
    two = StationRelay.outgoing(two, <<1, pc::binary, "p">>)
    one = StationRelay.outgoing(one, <<1, pc::binary, "p">>)
    two = StationRelay.outgoing(two, <<1, pc::binary, "p">>)
    assert held(target) == 3
    assert {one.window_packets, two.window_packets} == {2, 1}

    SystemsClock.advance(250)
    _ = StationRelay.outgoing(two, <<1, pc::binary, "p">>)
    assert held(target) == 4

    # 100 bytes a window: the second of these does not fit.
    SystemsRuntime.put_env(:salix_web, :station_relay_node_budget, {400, 1 <<< 40})
    SystemsClock.advance(250)
    big = :binary.copy(<<0>>, 60)
    _ = StationRelay.outgoing(one, <<1, pc::binary, big::binary>>)
    _ = StationRelay.outgoing(two, <<1, pc::binary, big::binary>>)
    assert held(target) == 5
  end

  test "each carrier a packet goes to is charged" do
    {pa, ka} = keypair()
    {pc, kc} = keypair()
    scope = {"t", "fanout"}
    first = holding(pc, kc, scope)
    second = holding(pc, kc, scope)
    {:ok, relay} = StationRelay.register("a", "c", signed(pa, ka, "a", "c"), scope)

    # 3 packets a window: one packet to two carriers takes two.
    SystemsRuntime.put_env(:salix_web, :station_relay_node_budget, {1 <<< 40, 12})
    SystemsClock.advance(250)
    relay = StationRelay.outgoing(relay, <<1, pc::binary, "p">>)
    assert {held(first), held(second)} == {1, 1}
    _ = StationRelay.outgoing(relay, <<1, pc::binary, "p">>)
    assert held(first) + held(second) == 3
  end

  # Astra's interleaving: one charger stops just as it would open a new window, and another spends all of that window.
  test "a charger stopped at a new window does not clear what another spent in it" do
    counts = Budget.new()
    budget = {524_288 * 4, 500 * 4}
    size = 65_536
    test = SystemsRuntime.Proc.self()
    :atomics.put(counts, 1, 0)
    at = fn -> 1000 end
    take = &Budget.take(counts, size, 1, budget, at, &1)

    stopped =
      SystemsRuntime.Proc.spawn_link(fn ->
        first = :atomics.new(1, [])

        once = fn ->
          if :atomics.exchange(first, 1, 1) == 0 do
            SystemsRuntime.Proc.send(test, :at_the_swap)

            SystemsRuntime.Proc.receive do
              :go_on -> :ok
            end
          end
        end

        SystemsRuntime.Proc.send(test, {:a, take.(once)})
      end)

    settle_receive(:at_the_swap)
    b = Enum.count(1..9, fn _ -> take.(fn -> :ok end) end)
    assert b == 8
    SystemsRuntime.Proc.send(stopped, :go_on)
    settle_receive({:a, a})

    assert a == false
    assert {_, 524_288, 8} = Budget.spent(counts)
  end

  test "the word: a charge is both or neither, a new window starts at nothing, and the counts cannot overflow" do
    limits = {1000, 10}
    word = Budget.charge(0, 7, 400, 1, limits)
    word = Budget.charge(word, 7, 400, 1, limits)
    assert Budget.charge(word, 7, 400, 1, limits) == :over
    assert Budget.charge(word, 7, 200, 8, limits) != :over
    assert Budget.charge(word, 7, 200, 9, limits) == :over

    counts = Budget.new()
    :atomics.put(counts, 1, Budget.charge(word, 8, 1000, 10, limits))
    assert Budget.spent(counts) == {8, 1000, 10}

    # A budget past what the word counts is clamped: the largest charge fits and the next does not, with no carry.
    {max_bytes, max_packets} = limits = Budget.per_window({1 <<< 60, 1 <<< 60})
    assert {max_bytes, max_packets} == {(1 <<< 26) - 1, (1 <<< 14) - 1}
    full = Budget.charge(0, 3, max_bytes, max_packets, limits)
    :atomics.put(counts, 1, full)
    assert Budget.spent(counts) == {3, max_bytes, max_packets}
    assert Budget.charge(full, 3, 1, 0, limits) == :over
    assert Budget.charge(full, 3, 0, 1, limits) == :over

    # The clock can be negative, and wraps into the word.
    assert Budget.window(-1) == (1 <<< 19) - 1
    assert Budget.window(250 * (1 <<< 19)) == 0
    :atomics.put(counts, 1, Budget.charge(full, Budget.window(-1), 1, 1, limits))
    assert Budget.spent(counts) == {(1 <<< 19) - 1, 1, 1}
  end

  # Close to the real path: many connections, each in its own process, all first to spend a new window.
  test "connections at a new window's start together let through its budget, and no more" do
    {pa, ka} = keypair()
    scope = {"t", "together"}
    to = SystemsRuntime.Proc.random_bytes(32)
    {:ok, relay} = StationRelay.register("a", "c", signed(pa, ka, "a", "c"), scope)
    test = SystemsRuntime.Proc.self()

    # 400 packets a window, and 8 connections trying 200 each.
    SystemsRuntime.put_env(:salix_web, :station_relay_node_budget, {1 <<< 40, 1600})

    for round <- 1..100 do
      SystemsClock.advance(250)

      fresh = %{
        relay
        | window_start: SystemsClock.monotonic_time(:millisecond),
          window_packets: 0,
          window_bytes: 0
      }

      for n <- 1..8 do
        SystemsRuntime.Proc.spawn_link(fn ->
          done =
            Enum.reduce(1..200, fresh, fn _, r ->
              StationRelay.outgoing(r, <<1, to::binary, "p">>)
            end)

          SystemsRuntime.Proc.send(test, {:passed, round, n, done.window_packets})
        end)
      end

      passed =
        for n <- 1..8 do
          settle_receive({:passed, ^round, ^n, count})
          count
        end

      assert Enum.sum(passed) == 400
    end
  end

  test "halted, no packet goes on a connection already open, and it goes again after" do
    {pa, ka} = keypair()
    {pc, kc} = keypair()
    scope = {"t", "halt"}
    target = holding(pc, kc, scope)
    {:ok, relay} = StationRelay.register("a", "c", signed(pa, ka, "a", "c"), scope)

    relay = StationRelay.outgoing(relay, <<1, pc::binary, "p">>)
    assert held(target) == 1

    SystemsRuntime.put_env(:salix_web, :station_relay_stopped, true)
    relay = StationRelay.outgoing(relay, <<1, pc::binary, "p">>)
    assert held(target) == 1

    SystemsRuntime.put_env(:salix_web, :station_relay_stopped, false)
    _ = StationRelay.outgoing(relay, <<1, pc::binary, "p">>)
    assert held(target) == 2
  end

  test "a socket gone drops the packet" do
    gone = SystemsRuntime.Proc.spawn(fn -> :ok end)
    ref = SystemsRuntime.Proc.monitor(gone)
    settle_receive({:DOWN, ^ref, :process, ^gone, _})
    assert StationRelay.deliver(gone, {:station_relay_packet, "a", {"t", "g"}, "p"}) == :dropped
  end
end
