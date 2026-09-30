defmodule SalixAgent.SessionTracingTest do
  use ExUnit.Case, async: false
  require Record
  require OpenTelemetry.Tracer, as: Tracer

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  alias SalixAgent.InternalSessionStore
  alias SalixStore.{Codec, Keys, S3}
  alias SystemsObservability.Context

  @agent "private-agent-do-not-export"
  @session "ses1_0000000000000000900"

  setup do
    old_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    :ok = :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
    :ok = :otel_tracer_provider.force_flush()

    on_exit(fn ->
      if old_backend,
        do: Application.put_env(:salix_store, :s3_backend, old_backend),
        else: Application.delete_env(:salix_store, :s3_backend)
    end)

    :ok
  end

  test "real session read exports nested decode span without identifiers or snapshot content" do
    state = %{
      SalixAgent.InternalSession.export(SalixAgent.InternalSession.new(@agent, @session))
      | summary: "private-result-do-not-export"
    }

    key = Keys.agent_internal_runtime_session(@agent, @session)

    {:ok, _} =
      S3.put(key, Codec.encode_session_snapshot(state))

    trace_id =
      Context.with_surface("bft", fn ->
        Tracer.with_span "test.session.parent" do
          trace_id = OpenTelemetry.Span.trace_id(OpenTelemetry.Tracer.current_span_ctx())
          assert {:ok, loaded} = InternalSessionStore.read(@agent, @session)
          assert SalixAgent.InternalSession.get(loaded, :summary) == state.summary
          trace_id
        end
      end)

    :ok = :otel_tracer_provider.force_flush()
    read = receive_span(trace_id, "salix.session.read")
    get = receive_span(trace_id, "salix.session.get")
    assert span(get, :parent_span_id) == span(read, :span_id)
    decode = receive_span(trace_id, "salix.session.decode")
    assert span(decode, :parent_span_id) == span(read, :span_id)
    assert span(decode, :start_time) >= span(read, :start_time)
    assert span(decode, :end_time) <= span(read, :end_time)

    assert span(get, :end_time) <= span(decode, :start_time)

    for exported <- [read, get, decode] do
      attrs = exported |> span(:attributes) |> :otel_attributes.map()
      assert attrs["component"] == "salix_agent"
      assert attrs["surface"] == "bft"
      refute inspect(exported) =~ @agent
      refute inspect(exported) =~ @session
      refute inspect(exported) =~ state.summary
    end
  end

  test "read failures retain their business result and do not expose the object key" do
    trace_id =
      Tracer.with_span "test.session.parent" do
        trace_id = OpenTelemetry.Span.trace_id(OpenTelemetry.Tracer.current_span_ctx())
        assert {:error, :not_found} = InternalSessionStore.read(@agent, @session)
        trace_id
      end

    :ok = :otel_tracer_provider.force_flush()
    exported = receive_span(trace_id, "salix.session.read")
    refute inspect(exported) =~ @agent
    refute inspect(exported) =~ @session
  end

  test "direct background configuration build exports under its captured parent" do
    {trace_id, parent_id} =
      Context.with_surface("bft", fn ->
        Tracer.with_span "test.config.parent" do
          parent = OpenTelemetry.Tracer.current_span_ctx()
          captured = Context.capture()

          task =
            Task.async(fn ->
              Context.run(captured, fn ->
                SalixAgent.RoundConfig.build_round_config(@agent, "worker", %{})
              end)
            end)

          assert {:error, :not_found} = Task.await(task)
          {OpenTelemetry.Span.trace_id(parent), OpenTelemetry.Span.span_id(parent)}
        end
      end)

    :ok = :otel_tracer_provider.force_flush()
    exported = receive_span(trace_id, "salix.round.config.build")
    assert span(exported, :parent_span_id) == parent_id
    assert (exported |> span(:attributes) |> :otel_attributes.map())["surface"] == "bft"
    refute inspect(exported) =~ @agent
  end

  # Selective receive leaves child spans in the mailbox when the parent is
  # requested first (export order need not match start order).
  defp receive_span(trace_id, name) do
    receive do
      {:span, span(trace_id: ^trace_id, name: ^name) = exported} -> exported
    after
      1_000 -> flunk("missing exported #{name}")
    end
  end
end
