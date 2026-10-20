defmodule SalixWeb.StationRelayTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Salix as the relay of last resort (`SalixWeb.StationRelay`): a socket that
  proves its endpoint id by signature carries packets for it; a packet goes to
  the carrier of the endpoint it names in the sender's Group, also when the
  endpoint has carriers in several Groups, and passes only within one Group; a
  wrong signature registers nothing, and a sender over its rate loses packets.
  """
  use SystemsClock.Case, async: false
  import SystemsClock.Assertions

  alias SalixWeb.StationRelay

  # Waits settle the carriers on a manual clock: no real time passes, and the
  # rate window stays where it opened.
  setup do
    SystemsClock.manual(scope: ["Elixir.SalixWeb.StationRelayTest"])
    on_exit(&SystemsClock.reset/0)
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
end
