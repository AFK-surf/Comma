defmodule SalixAgent.PhaseTelemetryTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.PhaseTelemetry

  defmodule Collector do
    @moduledoc false
    @behaviour SalixAgent.Observability

    @impl true
    def tool_call(_fact), do: :ok

    @impl true
    def agent_run(_fact), do: :ok

    @impl true
    def round_phase(fact) do
      test_pid = SystemsRuntime.fetch_env!(:salix_agent, :phase_test_pid)

      if SystemsRuntime.Proc.self() == test_pid,
        do: SystemsRuntime.Proc.send(test_pid, {:phase, fact})

      :ok
    end
  end

  # A sink from before the callback existed: phase facts must be dropped,
  # not raise.
  defmodule LegacySink do
    @moduledoc false
    def tool_call(_fact), do: :ok
    def agent_run(_fact), do: :ok
  end

  @meter_ctx %{
    agent_id: "ag-1",
    salix_agent_id: "ag-1",
    session_id: "ses-1",
    tenant_id: "t1",
    group_id: "g1",
    round_id: "round-abc",
    request_id: "req-abc",
    trace_id: "trace-abc",
    app_revision: "rev-1",
    actor_type: "user",
    billing_context: %{"surface" => "comma"}
  }

  setup do
    prev = SystemsRuntime.get_env(:salix_agent, :agent_observability_mod)
    SystemsRuntime.put_env(:salix_agent, :agent_observability_mod, Collector)
    SystemsRuntime.put_env(:salix_agent, :phase_test_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      if prev,
        do: SystemsRuntime.put_env(:salix_agent, :agent_observability_mod, prev),
        else: SystemsRuntime.delete_env(:salix_agent, :agent_observability_mod)

      SystemsRuntime.delete_env(:salix_agent, :phase_test_pid)
    end)

    :ok
  end

  test "emit reaches the observability sink; a nil start emits nothing" do
    assert :ok = PhaseTelemetry.emit(:boundary, @meter_ctx, nil, 10, 30)
    settle_receive({:phase, %{phase: "boundary", duration_ms: 20, round_id: "round-abc"}})
    assert :skip = PhaseTelemetry.emit(:boundary, @meter_ctx, nil, nil)
    settle_refute_receive({:phase, _})
  end

  test "earliest_delivered_at_ms picks the oldest stamped source message of the activation" do
    session = %{
      messages: [
        %{source_message_id: "old", delivered_at_ms: 500, role: "user"},
        %{"source_message_id" => "m1", "delivered_at_ms" => 2_000, "role" => "user"},
        %{source_message_id: "m2", delivered_at_ms: 1_500},
        %{source_message_id: "m3"}
      ]
    }

    assert PhaseTelemetry.earliest_delivered_at_ms(SalixAgent.InternalSession.open(session), [
             "m1",
             "m2",
             "m3"
           ]) == 1_500

    assert PhaseTelemetry.earliest_delivered_at_ms(SalixAgent.InternalSession.open(session), [
             "m3"
           ]) == nil

    assert PhaseTelemetry.earliest_delivered_at_ms(SalixAgent.InternalSession.open(session), []) ==
             nil

    assert PhaseTelemetry.earliest_delivered_at_ms(SalixAgent.InternalSession.open(%{}), ["m1"]) ==
             nil
  end

  test "a sink without the callback drops the fact instead of raising" do
    SystemsRuntime.put_env(:salix_agent, :agent_observability_mod, LegacySink)
    assert :ok = PhaseTelemetry.emit(:finalize, @meter_ctx, nil, 1, 2)
    settle_refute_receive({:phase, _})
  end
end
