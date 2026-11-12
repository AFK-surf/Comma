defmodule SalixWeb.StationRelayMultinodeTest do
  @moduledoc """
  A carrier on another node (`SalixWeb.StationRelay.Gate`): its mailbox can be
  read only there, so a sender on this node hands the packet to that node's Gate,
  and a socket that is not reading holds no more than the bound.
  """
  use SystemsClock.Case, async: false

  @moduletag :multinode

  alias SalixWeb.StationRelay

  @pg StationRelay.PG
  @prefix "comma-salix-relay-v1:"

  setup_all do
    _ = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    unless Node.alive?() do
      name = :"station_relay_main_#{SystemsRuntime.Proc.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = :net_kernel.start([name, :longnames])
    end

    [_, host] = String.split(to_string(Node.self()), "@")

    {:ok, peer, node} =
      :peer.start_link(%{
        name: :"station_relay_peer_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        host: String.to_charlist(host),
        longnames: String.contains?(host, "."),
        args: [~c"-setcookie", Atom.to_charlist(:erlang.get_cookie())]
      })

    true = Node.connect(node)
    :ok = :erpc.call(node, :code, :add_pathsa, [:code.get_path()])
    {:ok, _} = :erpc.call(node, :pg, :start, [@pg])

    {:ok, _} =
      :erpc.call(node, GenServer, :start, [StationRelay.Gate, nil, [name: StationRelay.Gate]])

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        _, _ -> :ok
      end
    end)

    {:ok, node: node}
  end

  test "halt reaches the other node, and resume", %{node: node} do
    stopped = fn ->
      :erpc.call(node, Application, :get_env, [:salix_web, :station_relay_stopped])
    end

    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :station_relay_stopped) end)

    StationRelay.halt()
    assert stopped.() == true
    StationRelay.resume()
    assert stopped.() == false
  end

  test "a socket on another node that is not reading holds no more than the bound", %{node: node} do
    SystemsRuntime.put_env(:salix_web, :station_relay_node_budget, {1_000_000_000, 1_000_000})
    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :station_relay_node_budget) end)
    {public, private} = SystemsRuntime.Proc.generate_key(:eddsa, :ed25519)
    scope = {"tenant", "group"}
    to = SystemsRuntime.Proc.random_bytes(32)

    carrier = :erpc.call(node, :erlang, :spawn, [:timer, :sleep, [:infinity]])
    :ok = :erpc.call(node, :pg, :join, [@pg, {:endpoint, scope, to}, carrier])
    assert eventually(fn -> :pg.get_members(@pg, {:endpoint, scope, to}) == [carrier] end)

    signature =
      SystemsRuntime.Proc.sign(:eddsa, :none, @prefix <> "run:c", [private, :ed25519])

    {:ok, relay} =
      StationRelay.register(
        "run",
        "c",
        %{
          "endpoint_id" => Base.encode16(public, case: :lower),
          "signature" => Base.encode64(signature)
        },
        scope
      )

    for n <- 1..1000, do: StationRelay.outgoing(relay, <<1, to::binary, n::32>>)

    # From this same sender, so it reaches the Gate after them all, and is answered once it has handled them.
    _ = :sys.get_state({StationRelay.Gate, node})

    assert :erpc.call(node, Process, :info, [carrier, :message_queue_len]) ==
             {:message_queue_len, 128}

    {:messages, messages} = :erpc.call(node, Process, :info, [carrier, :messages])

    assert for({:station_relay_packet, ^public, ^scope, <<n::32>>} <- messages, do: n) ==
             Enum.to_list(1..128)
  end

  defp eventually(fun, retries \\ 500) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> SystemsRuntime.Proc.sleep(20) && eventually(fun, retries - 1)
    end
  end
end
