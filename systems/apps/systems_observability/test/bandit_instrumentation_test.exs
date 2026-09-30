defmodule SystemsObservability.BanditInstrumentationTest do
  use ExUnit.Case, async: false

  require Record

  Record.defrecordp(
    :otel_span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  alias SystemsObservability.BanditInstrumentation

  defmodule FailingTracer do
    @behaviour :otel_tracer

    @impl true
    def start_span(_context, {__MODULE__, failure}, _name, _opts), do: fail(failure)

    @impl true
    def with_span(_context, {__MODULE__, failure}, _name, _opts, _fun), do: fail(failure)

    defp fail(:throw), do: throw(:injected_tracer_failure)
    defp fail(:exit), do: exit(:injected_tracer_failure)
  end

  setup do
    :ok = :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
    :ok = :otel_tracer_provider.force_flush()
    drain_exported_spans()
    :ok
  end

  test "real Bandit request events create and finish a server span" do
    conn = Plug.Test.conn(:get, "/health?token=secret")

    :telemetry.execute([:bandit, :request, :start], %{}, %{conn: conn})
    assert OpenTelemetry.Span.is_valid(OpenTelemetry.Tracer.current_span_ctx())

    conn = Plug.Conn.resp(conn, 204, "")
    :telemetry.execute([:bandit, :request, :stop], %{duration: 1}, %{conn: conn})

    refute OpenTelemetry.Span.is_valid(OpenTelemetry.Tracer.current_span_ctx())
  end

  test "removes query material before the official start handler sees it" do
    conn =
      :get
      |> Plug.Test.conn("/agents/secret-session?token=secret&_csrf_token=private")
      |> Plug.Conn.put_req_header("user-agent", "token=secret-in-user-agent")
      |> Plug.Conn.put_req_header(
        "traceparent",
        "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
      )

    sanitized =
      BanditInstrumentation.sanitize(
        [:bandit, :request, :start],
        %{conn: conn}
      )

    assert sanitized.conn.request_path == ""
    assert sanitized.conn.query_string == ""

    assert sanitized.conn.req_headers == [
             {"traceparent", "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"}
           ]

    refute inspect(sanitized) =~ "token=secret"
    refute inspect(sanitized) =~ "_csrf_token=private"
    refute inspect(sanitized) =~ "secret-session"
  end

  test "exported server spans contain no client IP address or source port" do
    trace_id_hex = "1123456789abcdef0123456789abcdef"
    trace_id = String.to_integer(trace_id_hex, 16)

    conn =
      :get
      |> Plug.Test.conn("/agents/secret-session?token=secret")
      |> Plug.Test.put_peer_data(%{
        address: {203, 0, 113, 42},
        port: 42_424,
        ssl_cert: nil
      })
      |> Plug.Conn.put_req_header(
        "traceparent",
        "00-#{trace_id_hex}-0123456789abcdef-01"
      )

    :telemetry.execute([:bandit, :request, :start], %{}, %{conn: conn})
    conn = Plug.Conn.resp(conn, 204, "")
    :telemetry.execute([:bandit, :request, :stop], %{duration: 1}, %{conn: conn})

    assert :ok = :otel_tracer_provider.force_flush()
    span = receive_span(trace_id)
    attributes = span |> otel_span(:attributes) |> :otel_attributes.map()

    assert attributes[:"client.address"] == "0.0.0.0"
    assert attributes[:"network.peer.address"] == "0.0.0.0"
    assert attributes[:"network.peer.port"] == 0
    exported_attributes = inspect(attributes, limit: :infinity, printable_limit: :infinity)
    refute exported_attributes =~ "203.0.113.42"
    refute exported_attributes =~ "42424"
    refute exported_attributes =~ "secret-session"
    refute exported_attributes =~ "token=secret"
  end

  test "upstream tracer throws and exits do not detach the safe Bandit handler" do
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
      with_application_tracer(OpentelemetryBandit, {FailingTracer, failure}, fn ->
        assert :ok ==
                 :telemetry.execute(
                   [:bandit, :request, :start],
                   %{},
                   %{conn: Plug.Test.conn(:get, "/health")}
                 )
      end)

      assert handler_attached?({BanditInstrumentation, :request})

      assert_receive {[:systems_observability, :handler, :failure], %{},
                      %{reason: "invalid_measurement"}}
    end
  end

  test "bounds raw stop errors and exception events" do
    assert %{error: "request_error"} =
             BanditInstrumentation.sanitize(
               [:bandit, :request, :stop],
               %{error: "token=secret"}
             )

    sanitized =
      BanditInstrumentation.sanitize(
        [:bandit, :request, :exception],
        %{
          exception: RuntimeError.exception("token=secret"),
          stacktrace: [{Secret.Module, :call, ["token=secret"], []}]
        }
      )

    assert sanitized.exception == RuntimeError.exception("request failed")
    assert sanitized.stacktrace == []
    refute inspect(sanitized) =~ "token=secret"
  end

  defp receive_span(trace_id, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    receive_span_until(trace_id, deadline)
  end

  defp receive_span_until(trace_id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:span, span} ->
        if otel_span(span, :trace_id) == trace_id and bandit_span?(span) do
          span
        else
          receive_span_until(trace_id, deadline)
        end
    after
      remaining -> flunk("expected exported span for trace #{trace_id}")
    end
  end

  defp bandit_span?(span) do
    match?(
      {:instrumentation_scope, "opentelemetry_bandit", _version, _schema_url},
      otel_span(span, :instrumentation_scope)
    )
  end

  defp handler_attached?(id) do
    Enum.any?(:telemetry.list_handlers([:bandit, :request, :start]), &(&1.id == id))
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

  defp drain_exported_spans do
    receive do
      {:span, _span} -> drain_exported_spans()
    after
      0 -> :ok
    end
  end
end
