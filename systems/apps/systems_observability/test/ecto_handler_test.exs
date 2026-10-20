defmodule SystemsObservability.EctoHandlerTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  require SystemsClock

  use SystemsClock.Test, scope: ["Elixir.SalixStore", "Elixir.SystemsObservability"]
  require Record

  Record.defrecordp(
    :otel_span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  defmodule FailingTracer do
    @behaviour :otel_tracer

    @impl true
    def start_span(_context, {__MODULE__, failure}, _name, _opts), do: fail(failure)

    @impl true
    def with_span(_context, {__MODULE__, failure}, _name, _opts, _fun), do: fail(failure)

    defp fail(:throw), do: throw(:injected_tracer_failure)
    defp fail(:exit), do: exit(:injected_tracer_failure)
  end

  defmodule HostileRepo do
    def config do
      [
        url: "postgres://secret-user:secret-password@secret-db.example/private",
        hostname: "secret-db.example",
        database: "private"
      ]
    end

    def __adapter__, do: Ecto.Adapters.Postgres
  end

  setup do
    :ok = :otel_batch_processor.set_exporter(:otel_exporter_pid, SystemsRuntime.Proc.self())
    :ok = :otel_tracer_provider.force_flush()
    drain_exported_spans()
    :ok
  end

  test "Ecto query events export one fixed, content-safe database span" do
    event = [:billing_core, :repo, :query]
    duration = System.convert_time_unit(5, :millisecond, :native)

    SystemsRuntime.Telemetry.execute(
      event,
      %{total_time: duration, query_time: duration, queue_time: 0},
      %{
        query: "SELECT secret-query-sentinel FROM private",
        source: "secret-source-sentinel",
        result: {:error, RuntimeError.exception("secret-exception-sentinel")},
        repo: HostileRepo,
        type: :ecto_sql_query
      }
    )

    # The flush is a cast and the export runs apart from it: wait for the span
    # itself, not for a window to pass.
    assert :ok = :otel_tracer_provider.force_flush()

    SystemsClock.settle(
      eager: true,
      until: fn ->
        {:messages, messages} = Process.info(SystemsRuntime.Proc.self(), :messages)
        Enum.any?(messages, &(match?({:span, _}, &1) and billing_query?(elem(&1, 1))))
      end
    )

    spans = received_spans([])
    assert [span] = Enum.filter(spans, &billing_query?/1)

    assert span |> otel_span(:attributes) |> :otel_attributes.map() == %{
             "component" => "billing",
             "operation" => "query",
             "outcome" => "error",
             "repo" => "billing"
           }

    exported = inspect(spans, limit: :infinity, printable_limit: :infinity)
    refute exported =~ "secret-user"
    refute exported =~ "secret-password"
    refute exported =~ "secret-db.example"
    refute exported =~ "secret-query-sentinel"
    refute exported =~ "secret-source-sentinel"
    refute exported =~ "secret-exception-sentinel"
  end

  test "invalid Ecto telemetry is isolated and counted without raising" do
    handler = {__MODULE__, SystemsRuntime.Proc.make_ref()}
    parent = SystemsRuntime.Proc.self()

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:systems_observability, :handler, :failure],
        fn event, measurements, metadata, _ ->
          SystemsRuntime.Proc.send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

    assert :ok ==
             SystemsObservability.EctoHandler.handle_event(
               [:unknown, :repo, :query],
               %{},
               %{},
               nil
             )

    settle_receive(
      {[:systems_observability, :handler, :failure], %{}, %{reason: "invalid_measurement"}}
    )
  end

  test "owned tracer throws and exits do not detach the Ecto handler" do
    failure_handler = {__MODULE__, SystemsRuntime.Proc.make_ref()}
    test = SystemsRuntime.Proc.self()

    :ok =
      SystemsRuntime.Telemetry.attach(
        failure_handler,
        [:systems_observability, :handler, :failure],
        fn event, measurements, metadata, _ ->
          SystemsRuntime.Proc.send(test, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(failure_handler) end)

    for failure <- [:throw, :exit] do
      with_application_tracer(SystemsObservability.EctoHandler, {FailingTracer, failure}, fn ->
        assert :ok ==
                 SystemsRuntime.Telemetry.execute(
                   [:billing_core, :repo, :query],
                   %{total_time: 1, query_time: 1, queue_time: 0},
                   %{query: "SELECT 1", result: {:ok, nil}}
                 )
      end)

      assert handler_attached?(SystemsObservability.EctoHandler)

      settle_receive(
        {[:systems_observability, :handler, :failure], %{}, %{reason: "invalid_measurement"}}
      )
    end
  end

  defp billing_query?(span) do
    otel_span(span, :name) == "comma.db.query" and
      span |> otel_span(:attributes) |> :otel_attributes.map() |> Map.get("repo") == "billing"
  end

  defp received_spans(spans) do
    SystemsRuntime.Proc.receive do
      {:span, span} -> received_spans([span | spans])
    after
      0 -> Enum.reverse(spans)
    end
  end

  defp drain_exported_spans do
    SystemsRuntime.Proc.receive do
      {:span, _span} -> drain_exported_spans()
    after
      0 -> :ok
    end
  end

  defp handler_attached?(id) do
    Enum.any?(
      SystemsRuntime.Telemetry.list_handlers([:billing_core, :repo, :query]),
      &(&1.id == id)
    )
  end

  defp with_application_tracer(module, tracer, fun) do
    {name, version, schema_url} = :opentelemetry.get_application(module)

    key = {:opentelemetry, :global, :tracer, {name, version, schema_url}}

    original = :opentelemetry.get_application_tracer(module)
    SystemsRuntime.PersistentTerm.put(key, tracer)

    try do
      fun.()
    after
      SystemsRuntime.PersistentTerm.put(key, original)
    end
  end
end
