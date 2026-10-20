defmodule SalixIM.Triage.FailingTraceExporter do
  require SystemsRuntime.Proc

  @moduledoc false
  @behaviour :otel_exporter_traces

  @impl true
  def init(test_pid), do: {:ok, test_pid}

  @impl true
  def export(_spans, _resource, test_pid) do
    SystemsRuntime.Proc.send(test_pid, :triage_trace_export_failed)
    :failed_not_retryable
  end

  @impl true
  def shutdown(_test_pid), do: :ok
end

defmodule SalixIM.Triage.TelemetryTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  require SystemsClock

  use SalixAgent.TestSupport.Settle
  require Record

  Record.defrecordp(
    :otel_span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  alias SalixIM.Triage.Telemetry

  @event [:salix, :triage, :phase, :stop]

  test "a crashing telemetry handler cannot change the business result" do
    handler = "triage-telemetry-crash-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        @event,
        fn _event, _measurements, _metadata, _config ->
          raise "telemetry handler failure"
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

    assert :business_result ==
             Telemetry.observe(:evaluation, :callback, :bft, fn -> :business_result end)
  end

  test "a trace exporter failure cannot interrupt Runtime recovery" do
    :ok =
      :otel_batch_processor.set_exporter(
        SalixIM.Triage.FailingTraceExporter,
        SystemsRuntime.Proc.self()
      )

    handler = "triage-recovery-export-failure-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        @event,
        fn _event, _measurements, metadata, test_pid ->
          if metadata.phase == "recovery",
            do: SystemsRuntime.Proc.send(test_pid, :triage_recovery_completed)
        end,
        SystemsRuntime.Proc.self()
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

    runtime =
      start_supervised!(
        {SalixIM.Triage.Runtime,
         name: nil,
         mode: :off,
         namespace: "triage-export-failure-#{SystemsRuntime.Proc.unique_integer([:positive])}",
         recovery_idle_ms: 5_000,
         evaluator_port: {__MODULE__, []}}
      )

    settle_receive(:triage_recovery_completed)
    assert SystemsRuntime.Proc.alive?(runtime)

    assert :ok = :otel_tracer_provider.force_flush()
    settle_receive(:triage_trace_export_failed)
    assert SystemsRuntime.Proc.alive?(runtime)

    :ok = :otel_batch_processor.set_exporter(:otel_exporter_pid, SystemsRuntime.Proc.self())
  end
end
