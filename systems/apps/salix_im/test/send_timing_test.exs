defmodule SalixIM.SendTimingTest do
  use ExUnit.Case, async: false
  alias SalixIM.SendTiming
  alias SystemsObservability.Context

  test "the owner envelope keeps the caller trace across processes" do
    trace_id = "0123456789abcdef0123456789abcdef"

    context =
      Context.extract(%{
        "traceparent" => "00-" <> trace_id <> "-0123456789abcdef-01",
        "surface" => "comma"
      })

    envelope = Context.run(context, fn -> SendTiming.envelope("agent", %{}) end)
    {:observed_agent_message, carrier, sent, _, _} = envelope

    task =
      Task.async(fn ->
        SendTiming.receive_message(carrier, sent, fn ->
          OpenTelemetry.Tracer.current_span_ctx() |> OpenTelemetry.Span.trace_id()
        end)
      end)

    assert Task.await(task) == String.to_integer(trace_id, 16)
  end

  test "remote timestamps do not produce queue durations and receiver context is restored" do
    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:salix, :operation, :stop],
      fn _, _, metadata, _ ->
        send(parent, {:stage, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    context = Context.with_surface("comma", &Context.inject/0)

    assert {:error, :timeout} =
             SendTiming.receive_message(context, {:remote_node, 0}, fn ->
               assert Context.current_surface() == "comma"
               {:error, :timeout}
             end)

    assert_receive {:stage, %{operation: "im_send_actor", outcome: "timeout", surface: "comma"}}
    refute_receive {:stage, %{operation: "im_send_queue"}}
    assert Context.current_surface() == "system"

    assert_raise RuntimeError, "business failure", fn ->
      SendTiming.run("im_send_total", fn -> raise "business failure" end)
    end

    assert_receive {:stage, %{operation: "im_send_total", outcome: "error"}}
    assert SendTiming.measure("im_send_commit", fn -> :outside_send end) == :outside_send
    refute_receive {:stage, %{operation: "im_send_commit"}}
  end
end
