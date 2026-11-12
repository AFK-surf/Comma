defmodule SalixAgent.SessionTracingTest do
  use SystemsClock.Case, async: false
  require SystemsClock
  use SalixAgent.TestSupport.Settle
  require Record
  require OpenTelemetry.Tracer, as: Tracer

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  alias SalixAgent.InternalSessionStore
  alias SalixStore.S3
  alias SystemsObservability.Context

  @agent "private-agent-do-not-export"
  @session "ses1_0000000000000000900"

  setup do
    old_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    :ok = :otel_batch_processor.set_exporter(:otel_exporter_pid, SystemsRuntime.Proc.self())
    :ok = :otel_tracer_provider.force_flush()

    on_exit(fn ->
      if old_backend,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, old_backend),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)
    end)

    :ok
  end

  test "the real PG read uses bound SQL parameters and returns the private Session state" do
    assert {:ok, _} =
             SalixStore.Agent.create(@agent, "owner", SalixAgent.State,
               config: %{
                 "agent_id" => @agent,
                 "tenant_id" => "private-tenant",
                 "group_id" => "private-group",
                 "role" => "worker"
               }
             )

    SalixAgent.TestSupport.SessionFixture.cleanup_on_exit(@agent)
    private = "private-result-do-not-export"

    assert {:ok, _} =
             SalixAgent.TestSupport.SessionFixture.commit(@agent, @session, [
               %{"type" => "compaction", "summary" => private, "compacted_through" => 0}
             ])

    {result, queries} = observe_queries(fn -> InternalSessionStore.read(@agent, @session) end)
    assert {:ok, loaded} = result
    assert SalixAgent.InternalSession.get(loaded, :summary) == private
    assert queries != []

    for metadata <- queries do
      refute metadata.query =~ @agent
      refute metadata.query =~ @session
      refute metadata.query =~ private
    end
  end

  test "a missing PG Session retains its not-found result and parameterized lookup" do
    {result, queries} = observe_queries(fn -> InternalSessionStore.read(@agent, @session) end)
    assert result == {:error, :not_found}
    assert Enum.any?(queries, &(@agent in &1.params and @session in &1.params))

    for metadata <- queries do
      refute metadata.query =~ @agent
      refute metadata.query =~ @session
    end
  end

  defp observe_queries(fun) do
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == owner, do: send(owner, {:pg_read, metadata})
        end,
        nil
      )

    try do
      result = fun.()
      {result, query_messages([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp query_messages(acc) do
    receive do
      {:pg_read, metadata} -> query_messages([metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "direct background configuration build exports under its captured parent" do
    {trace_id, parent_id} =
      Context.with_surface("bft", fn ->
        Tracer.with_span "test.config.parent" do
          parent = OpenTelemetry.Tracer.current_span_ctx()
          captured = Context.capture()

          task =
            SystemsRuntime.Task.async(fn ->
              Context.run(captured, fn ->
                SalixAgent.RoundConfig.build_round_config(@agent, "worker", %{})
              end)
            end)

          assert {:error, :not_found} = SystemsRuntime.Task.await(task, :infinity)
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
    SystemsClock.vreceive do
      {:span, span(trace_id: ^trace_id, name: ^name) = exported} -> exported
    after
      1_000 -> flunk("missing exported #{name}")
    end
  end
end
