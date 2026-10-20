defmodule SalixAgent.GreeToolTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.TestSupport.FakeGreeUnit
  alias SalixAgent.Tools.Gree, as: Tool

  @host "192.168.5.31"
  @ctx %{agent_id: "agent-1"}

  # A gateway whose udp_request reaches the unit in Process :unit, or nothing.
  defmodule Dispatch do
    def get_device(_agent_id, _device_id), do: Process.get(:lan_device)

    def request(_agent_id, _target, "udp_request", params) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:udp, params})

      reply =
        with %{} = unit <- Process.get(:unit) do
          {reply, unit} = FakeGreeUnit.answer(Base.decode64!(params["payload_b64"]), unit)
          Process.put(:unit, unit)
          Process.get(:garble, & &1).(reply)
        end

      {:ok,
       %{
         "responses" =>
           if(reply,
             do: [%{"from" => "#{params["host"]}:7000", "payload_b64" => Base.encode64(reply)}],
             else: []
           ),
         "timed_out" => is_nil(reply)
       }}
    end
  end

  setup do
    previous = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, Dispatch)
    capabilities = %{"lan_gateway" => %{"methods" => ["http_request", "udp_request"]}}

    Process.put(
      :lan_device,
      {:ok,
       %{
         "device_id" => "dev-gw",
         "environment_id" => "env-gw",
         "status" => "connected",
         "capabilities" => capabilities,
         "environments" => [
           %{
             "environment_id" => "env-gw",
             "environment_provider" => "connector",
             "status" => "connected",
             "capabilities" => capabilities
           }
         ]
       }}
    )

    Process.put(:unit, FakeGreeUnit.unit())

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :env_dispatch, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :env_dispatch)
    end)
  end

  defp call(args),
    do: Tool.request(Map.merge(%{"device_id" => "dev-gw", "host" => @host}, args), @ctx)

  defp failure_code({:tool_failure, _content, code, "user_reportable", _message, []}), do: code

  defp sent do
    receive do
      {:udp, params} -> [params | sent()]
    after
      0 -> []
    end
  end

  test "reads and sets a unit with no key from the user" do
    assert %{
             "host" => @host,
             "mac" => "f4911e7aca59",
             "name" => "Living room",
             "values" => %{"Pow" => 0, "SetTem" => 26}
           } = call(%{"status" => ["Pow", "SetTem"]}) |> Jason.decode!()

    # A scan, a bind and the request, each to the unit's own address and port.
    assert [%{"host" => @host, "port" => 7000, "max_responses" => 1}, _bind, _status] = sent()

    assert %{"values" => %{"Pow" => 1, "SetTem" => 24}} =
             call(%{"set" => %{"Pow" => 1, "SetTem" => 24}}) |> Jason.decode!()

    assert %{"values" => %{"Pow" => 1, "SetTem" => 24, "Mod" => 1}} =
             call(%{"status" => ["Pow", "SetTem", "Mod"]}) |> Jason.decode!()
  end

  test "the unit's key never reaches the result" do
    result = call(%{"status" => ["Pow"]})
    refute result =~ Process.get(:unit).key
  end

  test "binds with the newer cipher when the scan cipher gets no answer" do
    for {scan, bind, binds} <- [{:ecb, :gcm, 2}, {:gcm, :gcm, 1}] do
      Process.put(:unit, FakeGreeUnit.unit(scan: scan, bind: bind))
      assert %{"values" => %{"Pow" => 0}} = call(%{"status" => ["Pow"]}) |> Jason.decode!()
      assert length(sent()) == 2 + binds
    end
  end

  test "reports a silent, foreign or refusing device without retrying the request" do
    Process.put(:unit, nil)
    assert "device_not_answering" = failure_code(call(%{"status" => ["Pow"]}))
    assert [_scan] = sent()

    # Something else answers on UDP 7000.
    Process.put(:unit, FakeGreeUnit.unit())
    Process.put(:garble, fn _reply -> "hello" end)
    assert "device_reply_malformed" = failure_code(call(%{"status" => ["Pow"]}))
    Process.delete(:garble)

    # A unit that answers the scan and never binds.
    Process.put(:unit, FakeGreeUnit.unit(scan: :gcm, bind: :ecb))
    assert "device_bind_failed" = failure_code(call(%{"status" => ["Pow"]}))
    sent()

    # A command without an answer is sent once; it may have been applied.
    Process.put(:unit, FakeGreeUnit.unit())
    Process.put(:answers, 0)

    Process.put(:garble, fn reply ->
      Process.put(:answers, Process.get(:answers) + 1)
      if Process.get(:answers) < 3, do: reply
    end)

    assert "device_no_reply" = failure_code(call(%{"set" => %{"Pow" => 1}}))
    assert [_scan, _bind, _command] = sent()
  end

  test "refuses a call that is not one status or one set" do
    for args <- [
          %{},
          %{"status" => []},
          %{"set" => %{}},
          %{"status" => ["Pow"], "set" => %{"Pow" => 1}},
          %{"status" => ["Pow; rm"]},
          %{"set" => %{"Pow" => "on"}},
          %{"status" => Enum.map(1..25, &"C#{&1}")}
        ] do
      assert_raise RuntimeError, fn -> call(args) end
    end

    assert [] = sent()
  end
end
