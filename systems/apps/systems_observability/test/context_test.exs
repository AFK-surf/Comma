defmodule SystemsObservability.ContextTest do
  use ExUnit.Case, async: true
  require OpenTelemetry.Tracer, as: Tracer

  alias SystemsObservability.Context

  test "local surface context is finite, nestable, and restored" do
    assert Context.current_surface() == "system"

    assert Context.with_surface("comma", fn ->
             assert Context.current_surface() == "comma"
             Context.with_surface("tenant-123", fn -> Context.current_surface() end)
           end) == "other"

    assert Context.current_surface() == "system"
  end

  test "with_surface restores pre-existing Logger metadata" do
    Logger.metadata(existing: "before")

    Context.with_surface("comma", fn ->
      assert Logger.metadata()[:existing] == "before"
      assert Logger.metadata()[:surface] == "comma"
      assert is_binary(Logger.metadata()[:correlation_id])
    end)

    assert Logger.metadata() == [existing: "before"]
  end

  test "serialized contract contains only W3C and bounded safe correlation fields" do
    contract =
      Context.with_surface("bft", fn ->
        Context.inject(Context.capture())
      end)

    assert contract["surface"] == "bft"
    assert contract["correlation_id"] =~ ~r/\A[A-Za-z0-9_-]+\z/

    assert Map.keys(contract) -- ~w(traceparent tracestate surface correlation_id) == []
    refute inspect(contract) =~ "tenant"
    refute inspect(contract) =~ "prompt"
  end

  test "invalid remote fields fail closed without leaking into local context" do
    remote =
      Context.extract(%{
        "surface" => "customer-42",
        "correlation_id" => "secret value with spaces",
        "authorization" => "Bearer secret",
        "prompt" => "private"
      })

    assert remote.surface == "other"
    refute remote.correlation_id == "secret value with spaces"

    Context.run(remote, fn ->
      assert Context.current_surface() == "other"
      assert Logger.metadata()[:correlation_id] == remote.correlation_id
    end)
  end

  test "Task capture-attach and persisted links keep the trace without implicit process inheritance" do
    Tracer.with_span "context_test.parent" do
      parent = OpenTelemetry.Tracer.current_span_ctx()
      captured = Context.with_surface("comma", &Context.capture/0)

      task =
        Task.async(fn ->
          Context.run(captured, fn ->
            OpenTelemetry.Tracer.current_span_ctx()
          end)
        end)

      child_process_context = Task.await(task)

      assert OpenTelemetry.Span.trace_id(child_process_context) ==
               OpenTelemetry.Span.trace_id(parent)

      serialized = Context.inject(captured)
      link = SystemsObservability.Trace.link_from(serialized, %{:"async.kind" => "persisted"})
      assert link.trace_id == OpenTelemetry.Span.trace_id(parent)
      assert link.span_id == OpenTelemetry.Span.span_id(parent)
    end
  end
end
