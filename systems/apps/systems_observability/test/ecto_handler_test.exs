defmodule SystemsObservability.EctoHandlerTest do
  use ExUnit.Case, async: false

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
    :ok = :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
    :ok = :otel_tracer_provider.force_flush()
    drain_exported_spans()
    :ok
  end

  test "Ecto query events export one fixed, content-safe database span" do
    event = [:billing_core, :repo, :query]
    duration = System.convert_time_unit(5, :millisecond, :native)

    :telemetry.execute(
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

    assert :ok = :otel_tracer_provider.force_flush()
    spans = receive_exported_spans()

    db_spans =
      Enum.filter(spans, fn span ->
        otel_span(span, :name) == "comma.db.query" and
          span
          |> otel_span(:attributes)
          |> :otel_attributes.map()
          |> Map.get("repo") == "billing"
      end)

    assert [span] = db_spans

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
    handler = {__MODULE__, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:systems_observability, :handler, :failure],
        fn event, measurements, metadata, _ ->
          send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok ==
             SystemsObservability.EctoHandler.handle_event(
               [:unknown, :repo, :query],
               %{},
               %{},
               nil
             )

    assert_receive {[:systems_observability, :handler, :failure], %{},
                    %{reason: "invalid_measurement"}}
  end

  test "owned tracer throws and exits do not detach the Ecto handler" do
    failure_handler = {__MODULE__, make_ref()}
    test = self()

    :ok =
      :telemetry.attach(
        failure_handler,
        [:systems_observability, :handler, :failure],
        fn event, measurements, metadata, _ -> send(test, {event, measurements, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(failure_handler) end)

    for failure <- [:throw, :exit] do
      with_application_tracer(SystemsObservability.EctoHandler, {FailingTracer, failure}, fn ->
        assert :ok ==
                 :telemetry.execute(
                   [:billing_core, :repo, :query],
                   %{total_time: 1, query_time: 1, queue_time: 0},
                   %{query: "SELECT 1", result: {:ok, nil}}
                 )
      end)

      assert handler_attached?(SystemsObservability.EctoHandler)

      assert_receive {[:systems_observability, :handler, :failure], %{},
                      %{reason: "invalid_measurement"}}
    end
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

  defp handler_attached?(id) do
    Enum.any?(:telemetry.list_handlers([:billing_core, :repo, :query]), &(&1.id == id))
  end

  defp with_application_tracer(module, tracer, fun) do
    {name, version, schema_url} = :opentelemetry.get_application(module)

    key = {:opentelemetry, :global, :tracer, {name, version, schema_url}}

    original = :opentelemetry.get_application_tracer(module)
    :persistent_term.put(key, tracer)

    try do
      fun.()
    after
      :persistent_term.put(key, original)
    end
  end
end
