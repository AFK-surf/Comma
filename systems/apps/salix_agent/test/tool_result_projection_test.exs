defmodule SalixAgent.ToolResultProjectionTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.{AsyncToolResults, ToolResultProjection}

  test "whole-envelope budget spills the largest canonical result first" do
    results = [
      tool_result("large", "demo.large", String.duplicate("L", 900)),
      tool_result("medium", "demo.medium", String.duplicate("M", 500)),
      tool_result("small", "demo.small", String.duplicate("S", 40))
    ]

    refs = ["ref-large", "ref-medium", "ref-small"]

    candidates =
      Enum.zip_with(results, refs, fn result, ref ->
        {:ok, candidate} = ToolResultProjection.prepare(result, ref)
        candidate
      end)

    envelope_fun = fn projected ->
      %{
        "request" => %{
          "messages" => projected,
          "escaped_wrapper" => "the envelope itself also consumes bytes"
        }
      }
    end

    [large, medium, small] = candidates

    one_spill_results = [
      put_content(large.result, Jason.encode!(ToolResultProjection.capsule(large))),
      medium.result,
      small.result
    ]

    one_spill_budget = encoded_bytes(envelope_fun.(one_spill_results))

    assert encoded_bytes(envelope_fun.(results)) > one_spill_budget

    assert {:ok, plan} =
             ToolResultProjection.plan(candidates, envelope_fun, one_spill_budget)

    assert plan.envelope_bytes == one_spill_budget
    assert encoded_bytes(envelope_fun.(plan.projected_results)) <= one_spill_budget
    assert Enum.at(plan.projected_results, 1) == medium.result
    assert Enum.at(plan.projected_results, 2) == small.result

    assert Jason.decode!(content(Enum.at(plan.projected_results, 0)))["result_ref"] ==
             "ref-large"

    assert Enum.map(plan.stored_events, & &1["result_ref"]) == ["ref-large"]
    assert hd(plan.stored_events)["result_json"] == large.result_json
  end

  defp tool_result(id, name, content) do
    %{
      id: id,
      name: name,
      content: content,
      error: false,
      status: "completed",
      trace_id: "trace-#{id}"
    }
  end

  defp content(result), do: result[:content] || result["content"]

  defp put_content(result, value) do
    cond do
      Map.has_key?(result, :content) -> Map.put(result, :content, value)
      Map.has_key?(result, "content") -> Map.put(result, "content", value)
      true -> Map.put(result, :content, value)
    end
  end

  defp encoded_bytes(value), do: value |> Jason.encode!() |> byte_size()
end
