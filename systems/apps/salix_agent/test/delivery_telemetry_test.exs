defmodule SalixAgent.DeliveryTelemetryTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  require SystemsRuntime.Proc
  alias SalixAgent.DeliveryTelemetry, as: Diagnostic

  defmodule LogCapture do
    require SystemsRuntime.Proc

    def log(%{meta: %{diagnostic: event}}, %{config: %{owner: owner}}),
      do: SystemsRuntime.Proc.send(owner, {:diagnostic, event})

    def log(_, _), do: :ok
  end

  setup do
    SystemsRuntime.ETS.delete_all_objects(SalixAgent.DeliveryTelemetry.Buffer)

    :ok =
      :logger.add_handler(:delivery_diagnostic_test, LogCapture, %{
        config: %{owner: SystemsRuntime.Proc.self()}
      })

    on_exit(fn -> :logger.remove_handler(:delivery_diagnostic_test) end)
    %{worker: start_supervised!(Diagnostic)}
  end

  test "bounded diagnostics survive a stopped exporter and exclude content", %{worker: worker} do
    reporter = Module.concat(__MODULE__, Reporter)
    metrics = SystemsObservability.Metrics.enabled_metrics([:salix])
    core = Enum.reject(metrics, &match?(%Telemetry.Metrics.Distribution{}, &1))

    start_supervised!(
      {TelemetryMetricsPrometheus.Core, name: reporter, metrics: core, start_async: false}
    )

    fields = Diagnostic.identity("agt1_123", "ses1_456", "private-provider-message")

    fields =
      Map.merge(fields, %{
        cached_revision: 7,
        current_revision: 8,
        content: "DO NOT EXPORT",
        request_key: "DO NOT EXPORT"
      })

    for _ <- 1..300,
        do: assert(:ok == Diagnostic.emit(:revision_conflict, :stale_revision, 0, fields))

    scrape = TelemetryMetricsPrometheus.Core.scrape(reporter)
    assert scrape =~ "salix_delivery_total"
    assert scrape =~ ~r/salix_delivery_total\{[^}]*outcome="stale_revision"[^}]*\} 300/

    assert scrape =~
             ~r/salix_delivery_diagnostic_drops_total\{[^}]*reason="buffer_full"[^}]*\} 44/

    assert SystemsRuntime.ETS.info(SalixAgent.DeliveryTelemetry.Buffer, :size) == 257
    refute scrape =~ "agt1_123"
    refute scrape =~ "private-provider-message"

    SystemsRuntime.Proc.send(worker, :flush)
    settle_receive({:diagnostic, event})
    assert event.cached_revision == 7
    assert event.current_revision == 8
    assert event.source_key == Diagnostic.source_key("private-provider-message")
    refute Map.has_key?(event, :content)
    assert event.request_key == nil
    refute inspect(event) =~ "DO NOT EXPORT"
  end

  test "rate limiting keeps whole chains of the same sampled sources", %{worker: worker} do
    {sampled, other} =
      1..400
      |> Enum.map(&"source-#{&1}")
      |> Enum.split_with(&match?("0" <> _, Diagnostic.source_key(&1)))

    for source <- Enum.take(sampled, 20) ++ Enum.take(other, 20) do
      fields = Diagnostic.identity("agt1_123", "ses1_456", source)
      assert :ok == Diagnostic.emit(:model_started, :ok, 0, fields)
    end

    SystemsRuntime.Proc.send(worker, :flush)

    logged =
      for _ <- 1..36 do
        settle_receive({:diagnostic, %{phase: "model_started"} = event})
        event.source_key
      end

    settle_refute_receive({:diagnostic, %{phase: "model_started"}})
    # All sampled sources pass; the others share the ordinary budget of 16.
    assert Enum.count(logged, &match?("0" <> _, &1)) == 20
  end

  test "an admission failure is logged by its class, without its data", %{worker: worker} do
    exception = %DBConnection.ConnectionError{message: "private query text"}

    assert Diagnostic.error_class({:error, {:retired_router_session, "ses1_789"}}) ==
             "retired_router_session"

    assert Diagnostic.error_class({:error, {:unavailable, {:session_probe, exception}}}) ==
             "unavailable:session_probe:DBConnection.ConnectionError"

    assert Diagnostic.error_class({:error, {:input_failed, "private message"}}) == "input_failed"
    assert Diagnostic.error_class({:error, "private message"}) == nil

    fields =
      "agt1_123"
      |> Diagnostic.identity("ses1_456", "source")
      |> Map.put(:error_class, Diagnostic.error_class({:error, {:input_exit, exception}}))

    assert :ok == Diagnostic.emit(:admission_attempt, :error, 1, fields)
    assert :ok == Diagnostic.emit(:admission_attempt, :error, 1, %{error_class: "a b"})
    SystemsRuntime.Proc.send(worker, :flush)

    settle_receive({:diagnostic, %{agent_id: "agt1_123"} = event})
    assert event.error_class == "input_exit:DBConnection.ConnectionError"
    refute inspect(event) =~ "private"
    settle_receive({:diagnostic, %{agent_id: nil} = event})
    assert event.error_class == nil
  end

  test "a failed telemetry handler cannot fail the producer" do
    handler = {__MODULE__, :failure}

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:salix, :delivery, :stop],
        &__MODULE__.fail/4,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)
    assert :ok = Diagnostic.emit(:retry_exhausted, :stale_revision, 0)
    assert :ok = Diagnostic.emit(:admission_attempt, "private error body", 1)
  end

  def fail(_, _, _, _), do: raise("unavailable telemetry sink")
end
