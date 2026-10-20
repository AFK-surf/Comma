defmodule SalixAgent.SSHDeviceRelayTest do
  @moduledoc """
  `SalixAgent.SSH.DeviceRelay` against a socket owner played by the test:
  the relay never has more than one window unacknowledged, however much the
  local socket delivers at once, and sends its remaining bytes before eof.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.SSH.DeviceRelay

  defmodule Dispatch do
    @moduledoc false
    def open_tunnel(_agent_id, _target, _id, _params, relay) do
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})
      SystemsRuntime.Proc.send(owner, {:relay, relay})

      result =
        SystemsRuntime.PersistentTerm.get({__MODULE__, :result}, %{
          "status" => "connected",
          "window" => 65_536
        })

      {:ok, %{owner: owner, result: result}}
    end
  end

  setup do
    previous = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, Dispatch)
    SystemsRuntime.PersistentTerm.put({Dispatch, :owner}, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SystemsRuntime.PersistentTerm.erase({Dispatch, :owner})
      SystemsRuntime.PersistentTerm.erase({Dispatch, :result})

      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :env_dispatch, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :env_dispatch)
    end)
  end

  defp dial! do
    target = %{device_id: "dev-gw", environment_id: "env-gw"}
    assert {:ok, socket, _result} = DeviceRelay.dial("agent", target, "10.0.0.2", 22, 5_000)
    settle_receive({:relay, relay})
    {socket, relay}
  end

  # Collect data frames until `bytes` arrived; returns the tunnel id.
  defp receive_bytes(relay, bytes, acc \\ 0, id \\ nil)
  defp receive_bytes(_relay, bytes, acc, id) when acc >= bytes, do: {acc, id}

  defp receive_bytes(relay, bytes, acc, _id) do
    settle_receive({:env_tunnel_send, ^relay, id, %{"channel" => "tcp", "data" => data}})
    receive_bytes(relay, bytes, acc + byte_size(Base.decode64!(data)), id)
  end

  test "bytes from the gateway reach the socket and are acknowledged" do
    {socket, relay} = dial!()
    :ok = :gen_tcp.send(socket, ~c"hi")
    {2, id} = receive_bytes(relay, 2)

    SystemsRuntime.Proc.send(
      relay,
      {:env_tunnel_frame, id, %{"channel" => "tcp", "data" => Base.encode64("hello")}}
    )

    assert {:ok, ~c"hello"} = :gen_tcp.recv(socket, 5, 5_000)
    settle_receive({:env_tunnel_send, ^relay, ^id, %{"channel" => "tcp_ack", "seq" => 5}})
    SystemsRuntime.Proc.send(relay, {:env_tunnel_frame, id, %{"channel" => "tcp", "eof" => true}})
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
  end
end
