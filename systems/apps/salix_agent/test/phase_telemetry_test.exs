defmodule SalixAgent.PhaseTelemetryTest do
  use ExUnit.Case, async: false

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
      test_pid = Application.fetch_env!(:salix_agent, :phase_test_pid)
      if self() == test_pid, do: send(test_pid, {:phase, fact})
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

  test "provider timing excludes earlier preparation and later persistence waits" do
    epoch = 1_800_000_000_000
    timing = SalixAgent.ExecutionTiming.finish_at({epoch, 1_000}, 1_050, 1_010)
    assert timing["duration_ms"] == 50
    assert timing["completed_at_ms"] == epoch + 50
    assert timing["first_token_at_ms"] == epoch + 10

    ctx =
      PhaseTelemetry.execution_meter_context(
        %{started_at_ms: epoch - 500},
        %{execution_timing: timing}
      )

    assert PhaseTelemetry.response_at_ms(ctx, timing["duration_ms"]) == epoch + 50

    assert PhaseTelemetry.build(:response_pickup, ctx, nil, epoch + 50, epoch + 75).duration_ms ==
             25
  end

  setup do
    prev = Application.get_env(:salix_agent, :agent_observability_mod)
    Application.put_env(:salix_agent, :agent_observability_mod, Collector)
    Application.put_env(:salix_agent, :phase_test_pid, self())

    on_exit(fn ->
      if prev,
        do: Application.put_env(:salix_agent, :agent_observability_mod, prev),
        else: Application.delete_env(:salix_agent, :agent_observability_mod)

      Application.delete_env(:salix_agent, :phase_test_pid)
    end)

    :ok
  end

  test "build carries the round identity, the span and the activation key" do
    fact = PhaseTelemetry.build(:tool_commit, @meter_ctx, ["m2", "m1", "m2"], 1_000, 1_450)

    assert fact.source == "salix_agent.phase"
    assert fact.source_key == "round-abc:tool_commit"
    assert fact.entrypoint == "agent_phase"
    assert fact.phase == "tool_commit"
    assert fact.status == "ok"
    assert fact.duration_ms == 450
    assert fact.started_at == DateTime.from_unix!(1_000, :millisecond)
    assert fact.surface == "comma"
    assert fact.tenant_id == "t1"
    assert fact.group_id == "g1"
    assert fact.salix_agent_id == "ag-1"
    assert fact.session_id == "ses-1"
    assert fact.round_id == "round-abc"
    assert fact.trace_id == "trace-abc"
    assert fact.activation_key == "m1,m2"
    assert fact.app_revision == "rev-1"
    assert fact.charge_status == "unattributed"
  end

  test "a clock that ran backwards never yields a negative duration" do
    assert PhaseTelemetry.build(:prepare, @meter_ctx, nil, 2_000, 1_900).duration_ms == 0
  end

  test "a scoped fact keys itself under the round, the phase and the scope" do
    ctx = Map.put(@meter_ctx, :source_scope, "call_42")

    assert PhaseTelemetry.build(:async_commit, ctx, nil, 0, 1).source_key ==
             "round-abc:async_commit:call_42"

    # An empty scope is no scope.
    ctx = Map.put(@meter_ctx, :source_scope, "")

    assert PhaseTelemetry.build(:async_commit, ctx, nil, 0, 1).source_key ==
             "round-abc:async_commit"
  end

  test "a missing round id still yields a unique source key" do
    fact = PhaseTelemetry.build(:prepare, Map.delete(@meter_ctx, :round_id), nil, 0, 1)
    assert fact.round_id == nil
    assert fact.source_key =~ ~r/^round:[0-9a-f]{16}:prepare$/
  end

  test "activation keys normalize to a stable joined string or nil" do
    assert PhaseTelemetry.normalize_key(nil) == nil
    assert PhaseTelemetry.normalize_key([]) == nil
    assert PhaseTelemetry.normalize_key("") == nil
    assert PhaseTelemetry.normalize_key("k") == "k"
    assert PhaseTelemetry.normalize_key(["b", "a", "", "b"]) == "a,b"
  end

  test "emit reaches the observability sink; a nil start emits nothing" do
    assert :ok = PhaseTelemetry.emit(:boundary, @meter_ctx, nil, 10, 30)
    assert_receive {:phase, %{phase: "boundary", duration_ms: 20, round_id: "round-abc"}}

    assert :skip = PhaseTelemetry.emit(:boundary, @meter_ctx, nil, nil)
    refute_receive {:phase, _}
  end

  test "emit_pre_dispatch emits activation only when the actor stamped one, and always prepare" do
    opts = [round_started_ms: 500, activation_started_ms: 100]
    PhaseTelemetry.emit_pre_dispatch(@meter_ctx, opts, ["m1"])

    assert_receive {:phase, %{phase: "activation", duration_ms: 400, activation_key: "m1"}}
    assert_receive {:phase, %{phase: "prepare", activation_key: "m1"} = prepare}
    assert prepare.started_at == DateTime.from_unix!(500, :millisecond)

    PhaseTelemetry.emit_pre_dispatch(@meter_ctx, [round_started_ms: 700], nil)
    assert_receive {:phase, %{phase: "prepare", activation_key: nil}}
    refute_receive {:phase, %{phase: "activation"}}
  end

  test "response_at_ms is the provider completion instant when the context carries a start" do
    assert PhaseTelemetry.response_at_ms(%{started_at_ms: 1_000}, 250) == 1_250
    assert PhaseTelemetry.response_at_ms(%{"started_at_ms" => 1_000}, 250) == 1_250

    now = PhaseTelemetry.now_ms()
    assert PhaseTelemetry.response_at_ms(%{}, 250) >= now
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

  test "an input the runtime already began answering reports no delivery wait" do
    # m1 was answered by a tool round (assistant turn id 11 follows it); the
    # continuation round must not report arrival→now again. m2 arrived after
    # that turn and is still unanswered, so it does.
    session = %{
      messages: [
        %{id: 10, role: "user", source_message_id: "m1", delivered_at_ms: 1_000},
        %{id: 11, role: "assistant", content: "calling a tool"},
        %{id: 12, role: "tool", content: "result"},
        %{id: 13, role: "user", source_message_id: "m2", delivered_at_ms: 5_000}
      ]
    }

    assert PhaseTelemetry.earliest_delivered_at_ms(SalixAgent.InternalSession.open(session), [
             "m1"
           ]) == nil

    assert PhaseTelemetry.earliest_delivered_at_ms(SalixAgent.InternalSession.open(session), [
             "m1",
             "m2"
           ]) == 5_000
  end

  test "a no_wake context delivery reports no wait of its own" do
    # Staging 2026-09-21: a triage-participation note is staged with
    # no_wake, so it schedules no round and sits until an unrelated group
    # message activates the Router 20 minutes later. Both ids reach that
    # round, and charging the note's arrival reported 1,232 s of queueing
    # for an input that was never waiting for a round.
    session = %{
      messages: [
        %{
          id: 10,
          role: "user",
          source_message_id: "triage-participation:ob1",
          delivered_at_ms: 1_000,
          no_wake: true
        },
        %{id: 11, role: "user", source_message_id: "groupconv:m2", delivered_at_ms: 1_233_000}
      ]
    }

    assert PhaseTelemetry.earliest_delivered_at_ms(SalixAgent.InternalSession.open(session), [
             "triage-participation:ob1",
             "groupconv:m2"
           ]) == 1_233_000

    assert PhaseTelemetry.earliest_delivered_at_ms(SalixAgent.InternalSession.open(session), [
             "triage-participation:ob1"
           ]) == nil
  end

  test "emit_delivery_wait spans arrival to the activation stamp, never negative, never unstamped" do
    opts = [round_started_ms: 900, activation_started_ms: 700]

    assert :ok = PhaseTelemetry.emit_delivery_wait(@meter_ctx, opts, ["m1"], 100)
    assert_receive {:phase, %{phase: "delivery_wait", duration_ms: 600, activation_key: "m1"} = f}
    assert f.started_at == DateTime.from_unix!(100, :millisecond)

    # Without an activation stamp (a direct round) it ends at Round.run.
    assert :ok = PhaseTelemetry.emit_delivery_wait(@meter_ctx, [round_started_ms: 900], nil, 100)
    assert_receive {:phase, %{phase: "delivery_wait", duration_ms: 800}}

    # Clock skew: an arrival stamped after the activation is a zero, not a negative.
    assert :ok = PhaseTelemetry.emit_delivery_wait(@meter_ctx, opts, nil, 5_000)
    assert_receive {:phase, %{phase: "delivery_wait", duration_ms: 0}}

    assert :skip = PhaseTelemetry.emit_delivery_wait(@meter_ctx, opts, nil, nil)
    refute_receive {:phase, _}
  end

  test "a sink without the callback drops the fact instead of raising" do
    Application.put_env(:salix_agent, :agent_observability_mod, LegacySink)
    assert :ok = PhaseTelemetry.emit(:finalize, @meter_ctx, nil, 1, 2)
    refute_receive {:phase, _}
  end
end
