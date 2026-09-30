defmodule SalixIM.Triage.FailingTraceExporter do
  @moduledoc false
  @behaviour :otel_exporter_traces

  @impl true
  def init(test_pid), do: {:ok, test_pid}

  @impl true
  def export(_spans, _resource, test_pid) do
    send(test_pid, :triage_trace_export_failed)
    :failed_not_retryable
  end

  @impl true
  def shutdown(_test_pid), do: :ok
end

defmodule SalixIM.Triage.TelemetryTest do
  use ExUnit.Case, async: false

  require Record

  Record.defrecordp(
    :otel_span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  alias SalixIM.Triage.Telemetry

  @event [:salix, :triage, :phase, :stop]

  test "owns the phase and recovery metric definitions it emits" do
    names = Telemetry.metrics() |> Enum.map(& &1.name) |> MapSet.new()

    assert names ==
             MapSet.new([
               [:salix, :triage, :phases, :total],
               [:salix, :triage, :phase, :duration, :seconds],
               [:salix, :triage, :recovery, :backlog],
               [:salix, :triage, :recovery, :record_errors, :total],
               [:salix, :triage, :clickhouse, :etl, :batches, :total],
               [:salix, :triage, :clickhouse, :etl, :rows, :total]
             ])
  end

  test "ClickHouse patrol settlement emits only finite batch and row outcomes" do
    batch_event = [:salix, :triage, :clickhouse_etl, :batch]
    row_event = [:salix, :triage, :clickhouse_etl, :row]
    handler = "triage-clickhouse-etl-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [batch_event, row_event],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:triage_clickhouse_etl, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok =
             Telemetry.emit_clickhouse_batch(:ok, %{
               created: 2,
               duplicate: 1,
               ineligible: 0
             })

    assert_receive {:triage_clickhouse_etl, ^batch_event, %{count: 1}, %{outcome: "ok"}}
    assert_receive {:triage_clickhouse_etl, ^row_event, %{count: 2}, %{outcome: "created"}}
    assert_receive {:triage_clickhouse_etl, ^row_event, %{count: 1}, %{outcome: "duplicate"}}
    refute_receive {:triage_clickhouse_etl, ^row_event, _measurements, %{outcome: "ineligible"}}

    assert :ok = Telemetry.emit_clickhouse_batch(:inactive, %{})
    assert_receive {:triage_clickhouse_etl, ^batch_event, %{count: 1}, %{outcome: "inactive"}}
    refute_receive {:triage_clickhouse_etl, ^row_event, _measurements, _metadata}
  end

  test "normalizes every telemetry label to a finite public value" do
    handler = "triage-telemetry-finite-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        @event,
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:triage_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok =
             Telemetry.emit(
               "run-U_SECRET",
               "error-U_SECRET",
               "callback-U_SECRET",
               "surface-U_SECRET",
               System.monotonic_time()
             )

    assert_receive {:triage_telemetry, @event, %{duration: duration}, metadata}
    assert is_integer(duration) and duration >= 0

    assert metadata == %{
             phase: "other",
             outcome: "other",
             source_mode: "other",
             surface: "other"
           }

    refute inspect({duration, metadata}) =~ "U_SECRET"
  end

  # A return shape this module does not classify is not evidence of success.
  # Labelling it "ok" made every unrecognized result read as a healthy run.
  test "an unclassified observed result is labelled unknown, not ok" do
    handler = "triage-telemetry-unknown-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        @event,
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, {:triage_outcome, metadata.outcome})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :surprise = Telemetry.observe(:evaluation, :callback, :bft, fn -> :surprise end)
    assert_receive {:triage_outcome, "unknown"}

    assert {:wat, 1} = Telemetry.observe(:evaluation, :callback, :bft, fn -> {:wat, 1} end)
    assert_receive {:triage_outcome, "unknown"}

    # The shapes it does classify keep their exact labels.
    assert :ok = Telemetry.observe(:evaluation, :callback, :bft, fn -> :ok end)
    assert_receive {:triage_outcome, "ok"}
  end

  # A recovery page that listed cleanly but could not be READ is not a clean
  # lane. Reporting `:ok` with no count hid every poison or vanished record.
  test "recovery lane status carries its read-error count and stops claiming ok" do
    handler = "triage-recovery-errors-#{System.unique_integer([:positive])}"
    event = [:salix, :triage, :recovery, :status]

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, measurements, metadata, test_pid ->
          send(test_pid, {:triage_recovery_status, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = Telemetry.emit_recovery_status(:buckets, :error, 0, 3)
    assert_receive {:triage_recovery_status, measurements, metadata}
    assert measurements.record_errors == 3
    assert metadata == %{lane: "buckets", outcome: "error"}

    assert :ok = Telemetry.emit_recovery_status(:fences, :ok, 1)
    assert_receive {:triage_recovery_status, %{record_errors: 0, backlog: 1}, _metadata}
  end

  test "a crashing telemetry handler cannot change the business result" do
    handler = "triage-telemetry-crash-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        @event,
        fn _event, _measurements, _metadata, _config ->
          raise "telemetry handler failure"
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :business_result ==
             Telemetry.observe(:evaluation, :callback, :bft, fn -> :business_result end)
  end

  test "a Runtime recovery tick starts one exported system trace" do
    :ok = :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
    :ok = :otel_tracer_provider.force_flush()
    drain_exported_spans()

    handler = "triage-recovery-trace-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        @event,
        fn _event, _measurements, metadata, test_pid ->
          if metadata.phase == "recovery" do
            send(test_pid, {
              :triage_recovery_context,
              OpenTelemetry.Tracer.current_span_ctx(),
              SystemsObservability.Context.current_surface()
            })
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    runtime =
      start_supervised!(
        {SalixIM.Triage.Runtime,
         name: nil,
         mode: :off,
         namespace: "triage-trace-#{System.unique_integer([:positive])}",
         recovery_idle_ms: 5_000,
         evaluator_port: {__MODULE__, []}}
      )

    assert_receive {:triage_recovery_context, span_context, "system"}, 500
    assert OpenTelemetry.Span.is_valid(span_context)
    assert Process.alive?(runtime)

    assert :ok = :otel_tracer_provider.force_flush()

    recovery_spans =
      receive_exported_spans()
      |> Enum.filter(&(otel_span(&1, :name) == "salix.triage.recovery"))
      |> Enum.filter(&(otel_span(&1, :trace_id) == OpenTelemetry.Span.trace_id(span_context)))

    assert [span] = recovery_spans

    assert span |> otel_span(:attributes) |> :otel_attributes.map() == %{
             "component" => "salix_im",
             "operation" => "triage_recovery",
             "surface" => "system"
           }
  end

  test "a trace exporter failure cannot interrupt Runtime recovery" do
    :ok =
      :otel_batch_processor.set_exporter(
        SalixIM.Triage.FailingTraceExporter,
        self()
      )

    handler = "triage-recovery-export-failure-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        @event,
        fn _event, _measurements, metadata, test_pid ->
          if metadata.phase == "recovery", do: send(test_pid, :triage_recovery_completed)
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    runtime =
      start_supervised!(
        {SalixIM.Triage.Runtime,
         name: nil,
         mode: :off,
         namespace: "triage-export-failure-#{System.unique_integer([:positive])}",
         recovery_idle_ms: 5_000,
         evaluator_port: {__MODULE__, []}}
      )

    assert_receive :triage_recovery_completed, 500
    assert Process.alive?(runtime)

    assert :ok = :otel_tracer_provider.force_flush()
    assert_receive :triage_trace_export_failed, 500
    assert Process.alive?(runtime)

    :ok = :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
  end

  defp receive_exported_spans(timeout \\ 250) do
    deadline = System.monotonic_time(:millisecond) + timeout
    receive_exported_spans_until(deadline, [])
  end

  defp receive_exported_spans_until(deadline, spans) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:span, span} -> receive_exported_spans_until(deadline, [span | spans])
    after
      remaining -> Enum.reverse(spans)
    end
  end

  defp drain_exported_spans do
    receive do
      {:span, _span} -> drain_exported_spans()
    after
      0 -> :ok
    end
  end
end
