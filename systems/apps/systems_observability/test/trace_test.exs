defmodule SystemsObservability.TraceTest do
  use ExUnit.Case, async: true

  alias SystemsObservability.Trace

  test "unknown span keys and unsupported kinds fail closed" do
    assert_raise KeyError, fn ->
      Trace.with_span(:unknown, %{}, fn -> :ok end)
    end

    for kind <- [:producer, :consumer, :dynamic] do
      assert_raise ArgumentError, ~r/unsupported span kind/, fn ->
        Trace.with_span(:billing, %{}, fn -> :ok end, kind: kind)
      end
    end
  end

  test "preserves results while identifiers and content attributes are rejected" do
    assert Trace.with_span(
             :salix_llm,
             %{
               component: "tenant-component",
               surface: "tenant-42",
               operation: "read",
               provider: "custom-provider",
               model_key: "tenant-model"
             },
             fn -> {:ok, :preserved} end
           ) == {:ok, :preserved}

    forbidden = [
      :tenant_id,
      :url,
      :query,
      :command,
      :prompt,
      :tool_arguments,
      :exception,
      :outcome,
      :protocol,
      :"error.class"
    ]

    for key <- forbidden do
      assert_raise ArgumentError, fn ->
        Trace.with_span(:billing, %{key => "secret"}, fn -> :ok end)
      end
    end
  end
end
