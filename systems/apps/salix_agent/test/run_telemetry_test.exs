defmodule SalixAgent.RunTelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SalixAgent.RunTelemetry

  defp recorded_status(status) do
    %{status: recorded} =
      RunTelemetry.build_agent_run(%{
        status: status,
        agent_id: "agt1_test",
        session_id: "ses1_test"
      })

    recorded
  end

  test "a guard park keeps its own name instead of reading as a crash" do
    # These three used to reach ClickHouse as `actor_failed`, so an operator
    # could not tell a guard stopping a loop from an actor that died.
    for parked <- RunTelemetry.parked_statuses() do
      assert recorded_status(parked) == parked
    end

    assert "runaway_guard_parked" in RunTelemetry.parked_statuses()
    assert "repeated_tool_result_parked" in RunTelemetry.parked_statuses()
    assert "input_round_budget_parked" in RunTelemetry.parked_statuses()
  end

  test "a repair failure keeps its own name" do
    assert recorded_status("repair_failed") == "repair_failed"
  end

  test "the three original endings are unchanged" do
    assert recorded_status("completed") == "completed"
    assert recorded_status("llm_failed") == "llm_failed"
    assert recorded_status("actor_failed") == "actor_failed"
  end

  test "an atom status records the same as its string" do
    assert recorded_status(:repair_failed) == "repair_failed"
    assert recorded_status(:completed) == "completed"
  end

  test "an ending this module cannot name stays a failure and says so" do
    log = capture_log(fn -> assert recorded_status("invented_ending") == "actor_failed" end)

    assert log =~ "unregistered status"
    assert log =~ "invented_ending"
  end

  test "a run with no status recorded is a failure, and is not logged as unknown" do
    log = capture_log(fn -> assert recorded_status(nil) == "actor_failed" end)

    refute log =~ "unregistered status"
  end
end
