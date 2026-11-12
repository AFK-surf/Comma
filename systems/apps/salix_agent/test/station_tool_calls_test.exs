defmodule SalixAgent.StationToolCallsTest do
  @moduledoc """
  The bounds of a station's registry tool calls
  (`SalixAgent.StationToolCalls`), and the sealed origin they carry. Calls
  that reach a tool are covered with a real sandbox in
  `SalixWeb.StationToolCallsTest`.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{IFC, StationToolCalls}

  defmodule Facts do
    @moduledoc "An enforced Group that knows no memberships."
    def mode(_tenant_id, _group_id), do: "enforce"
    def resolve(_request), do: {:ok, %{"mode" => "enforce"}}
    def consume_receipt(_request), do: {:ok, false}
  end

  @ref %{
    tenant_id: "tnt_1",
    group_id: "grp_1",
    agent_id: "agt_worker",
    conversation_id: "cnv_1",
    device_id: "dev-sbx-cnv_1",
    session: "ember:c-1",
    requester: "usr_1",
    label: ["task:cnv_1"]
  }

  test "arguments over 1 MiB are refused before any dispatch" do
    big = %{"path" => "/a.txt", "content" => String.duplicate("x", 1024 * 1024 + 1)}
    assert {:refused, "args_too_large", _} = StationToolCalls.call(@ref, "fs.write_file", big)
  end

  test "a call's deadline is its tool's own timeout, so a long env.exec is answered" do
    assert StationToolCalls.deadline_ms("env.exec", %{"command" => "make", "timeout" => 600}) >
             600_000

    assert StationToolCalls.deadline_ms("env.exec", %{"timeout" => 100_000}) <= 19 * 60_000

    assert StationToolCalls.deadline_ms("fs.read_file", %{"path" => "/a"}) ==
             SalixAgent.Tools.tool_timeout_ms("fs.read_file", %{}) + 5_000
  end

  test "a station with its calls in flight is refused another" do
    for _ <- 1..StationToolCalls.max_in_flight(),
        do:
          {:ok, _} =
            SystemsRuntime.Registry.register(StationToolCalls.registry(), @ref.device_id, :call)

    assert {:refused, "too_many_calls", _} = StationToolCalls.call(@ref, "help", %{})
    # A refused call holds no slot of its own.
    assert length(SystemsRuntime.Registry.lookup(StationToolCalls.registry(), @ref.device_id)) ==
             StationToolCalls.max_in_flight()

    # Another station's slots are its own.
    refute match?(
             {:refused, "too_many_calls", _},
             StationToolCalls.call(%{@ref | device_id: "dev-sbx-other"}, "fs.read_file", %{
               "path" => "/none"
             })
           )
  end

  test "the origin is the kernel's delegated principal: the Task's requester, keyed by the station, under the Task's label" do
    assert %{
             "provider" => "schedule",
             "schedule_id" => "station:dev-sbx-cnv_1",
             "device_id" => "dev-sbx-cnv_1",
             "ifc" => %{
               "integrity" => "command",
               "principal" => principal,
               "label" => ["task:cnv_1"]
             }
           } = origin = IFC.station_origin("dev-sbx-cnv_1", "usr_1", ["task:cnv_1"])

    assert {:ok, {:schedule, "station:dev-sbx-cnv_1", {:comma_user, "usr_1"}}} =
             SalixIFC.Codec.decode_principal(principal)

    # What `IFC.principal/1` reads back is the requester, not the Worker.
    assert IFC.principal(origin) == {:schedule, "station:dev-sbx-cnv_1", {:comma_user, "usr_1"}}

    refute Map.has_key?(IFC.station_origin("dev-sbx-cnv_1", "usr_1", nil)["ifc"], "label")
    assert IFC.station_origin("", "usr_1", []) == nil
    assert IFC.station_origin("dev-sbx-cnv_1", nil, []) == nil
  end

  test "under audit or enforce, a Task with no requester is refused before any dispatch" do
    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, Facts)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_agent, :ifc_facts_mod) end)

    assert {:refused, "no_requester", _} =
             StationToolCalls.call(%{@ref | requester: nil}, "help", %{})

    # A read that labels nothing is agent-private, not the requester's to take
    # out of Salix.
    assert {:refused, "label_not_this_task", _} = StationToolCalls.call(@ref, "help", %{})
  end
end
