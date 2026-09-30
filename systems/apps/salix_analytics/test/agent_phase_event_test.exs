defmodule SalixAnalytics.AgentPhaseEventTest do
  use ExUnit.Case, async: true

  alias SalixAnalytics.AgentPhaseEvent
  alias SalixAnalytics.Sink.ClickHouseTyped

  @attrs %{
    source: "salix_agent.phase",
    source_key: "round-1:prepare",
    entrypoint: "agent_phase",
    surface: "comma",
    tenant_id: "t1",
    group_id: "g1",
    actor_type: "user",
    phase: :prepare,
    duration_ms: 42,
    started_at: ~U[2026-09-07 10:00:00.123Z],
    metered_at: ~U[2026-09-07 10:00:00.165Z],
    trace_id: "trace-1",
    request_id: "req-1",
    agent_id: "ag-1",
    session_id: "ses-1",
    round_id: "round-1",
    activation_key: "m1,m2",
    app_revision: "rev-1"
  }

  test "builds a row routed to agent_phase_events with the phase fields" do
    row = AgentPhaseEvent.build(@attrs)

    assert row["resource_kind"] == "agent_phase"
    assert ClickHouseTyped.table_for!(row) == "agent_phase_events"
    assert row["phase"] == "prepare"
    assert row["status"] == "ok"
    assert row["duration_ms"] == 42
    assert row["started_at"] == "2026-09-07T10:00:00.123Z"
    assert row["event_date"] == "2026-09-07"
    assert row["salix_agent_id"] == "ag-1"
    assert row["session_id"] == "ses-1"
    assert row["round_id"] == "round-1"
    assert row["activation_key"] == "m1,m2"
    assert row["charge_status"] == "unattributed"
    assert row["app_revision"] == "rev-1"
  end

  test "string keys and an explicit salix_agent_id are accepted" do
    row =
      @attrs
      |> Map.delete(:agent_id)
      |> Map.put("salix_agent_id", "ag-2")
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> AgentPhaseEvent.build()

    assert row["salix_agent_id"] == "ag-2"
    assert row["phase"] == "prepare"
  end

  test "the table is part of the sink's readiness probe" do
    assert "agent_phase_events" in ClickHouseTyped.readiness_tables()
  end

  test "a row without tenant identity is refused like every typed row" do
    assert_raise ArgumentError, ~r/tenant_id/, fn ->
      AgentPhaseEvent.build(Map.delete(@attrs, :tenant_id))
    end
  end
end
