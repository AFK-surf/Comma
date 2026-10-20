defmodule SalixAgent.LanCodecRequestTest do
  use SystemsClock.Case, async: false
  use SystemsClock.Test

  alias SalixAgent.LanCodec
  alias SalixAgent.LanCodec.Miio

  @token Base.decode16!("00112233445566778899AABBCCDDEEFF")
  @device_id <<10, 27, 44, 61>>
  @host "192.168.5.19"

  # The connector seam returns the bounded receive batch from one send.
  # Scheduled responses model arrival within its original deadline.
  defmodule Dispatch do
    def get_device(_agent_id, _device_id) do
      {:ok,
       %{
         "status" => "connected",
         "environment_id" => "env-gw",
         "capabilities" => %{"lan_gateway" => %{"methods" => ["udp_request"]}},
         "environments" => [%{"environment_id" => "env-gw", "status" => "connected"}]
       }}
    end

    def request(_agent_id, _target, "udp_request", params) do
      packet = Base.decode64!(params["payload_b64"])
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:udp, packet, params})
      replies = Process.get(:udp_device).(packet)

      replies =
        replies
        |> Enum.take_while(fn {arrival_ms, _} -> arrival_ms < params["timeout_ms"] end)
        |> Enum.take(params["max_responses"])

      elapsed =
        if length(replies) == params["max_responses"],
          do: elem(List.last(replies), 0),
          else: params["timeout_ms"]

      SystemsClock.advance(elapsed)

      {:ok,
       %{
         "responses" =>
           Enum.map(replies, fn {_, reply} ->
             %{"from" => "192.168.5.19:54321", "payload_b64" => Base.encode64(reply)}
           end),
         "timed_out" => elapsed == params["timeout_ms"]
       }}
    end
  end

  setup do
    previous = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, Dispatch)

    if :ets.whereis(:salix_agent_lan_codec_sessions) == :undefined, do: LanCodec.create_table()
    :ets.delete_all_objects(:salix_agent_lan_codec_sessions)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :env_dispatch, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :env_dispatch)
    end)

    device(fn request -> [{0, reply(request["id"])}] end)
    :ok
  end

  test "a cached toggle with a lost reply executes once and invalidates the session" do
    assert {:ok, _} = request()
    assert_received {:udp, _, _}
    assert_received {:udp, _, _}
    refute_received {:udp, _, _}

    Process.put(:power, false)

    device(fn %{"method" => "toggle"} ->
      Process.put(:power, not Process.get(:power))
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), :toggled)
      []
    end)

    assert {:tool_failure, _, "device_no_reply", _, message, []} = request("toggle")
    assert Process.get(:power)
    assert_received :toggled
    refute_received :toggled
    assert_received {:udp, command, %{"timeout_ms" => 3_000}}
    refute command == Miio.hello()
    refute_received {:udp, _, _}
    assert message =~ "may have executed"
    assert message =~ "Read its state before retrying"

    # A later explicit state read must start a new session.
    device(fn request -> [{0, reply(request["id"], @device_id, 7)}] end)
    assert {:ok, _} = request()
    assert_received {:udp, hello, _}
    assert hello == Miio.hello()
    assert_received {:udp, _, _}
    refute_received {:udp, _, _}
  end

  test "a matching reply after malformed and unverifiable packets is still accepted" do
    device(fn request ->
      bad_token = Miio.build(Jason.encode!(%{"id" => request["id"]}), <<0::128>>, @device_id, 1)
      [{100, "junk"}, {200, bad_token}, {500, reply(request["id"])}]
    end)

    assert {:ok, %{"result" => ["ok"]}} = request()
  end

  defp request(method \\ "get_prop") do
    LanCodec.request(Miio, "dev-gw", @host, @token, %{"method" => method, "params" => []}, %{
      agent_id: "agent-1"
    })
  end

  defp device(command) do
    Process.put(:udp_device, fn packet ->
      if packet == Miio.hello() do
        [{0, <<0x2131::16, 32::16, 0::32, @device_id::binary, 1_000::32, 0::128>>}]
      else
        {:ok, request, _} = Miio.decode(packet, @token)
        command.(request)
      end
    end)
  end

  defp reply(id, device_id \\ @device_id, stamp \\ 1_005) do
    Miio.build(Jason.encode!(%{"id" => id, "result" => ["ok"]}), @token, device_id, stamp)
  end
end
