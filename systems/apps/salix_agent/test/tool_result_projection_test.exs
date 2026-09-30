defmodule SalixAgent.ToolResultProjectionTest do
  use ExUnit.Case, async: true

  alias SalixAgent.{AsyncToolResults, ToolResultProjection}

  test "prepares exact canonical bytes, characters, and hash without changing a stable ref" do
    content = "quoted: \"yes\"; slash: \\\\; newline:\n; tab:\t"
    result_ref = "result:opaque/session-owned/ref-001"

    assert {:ok, candidate} =
             ToolResultProjection.prepare(tool_result("call-1", "demo.read", content), result_ref)

    canonical = Jason.encode!(content)

    assert candidate.result_ref == result_ref
    assert candidate.result_json == canonical
    assert candidate.result_bytes == byte_size(canonical)
    assert candidate.result_chars == String.length(canonical)

    assert candidate.result_sha256 ==
             :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)

    assert Jason.decode!(candidate.result_json) == content

    assert %{
             "type" => "tool_result_stored",
             "result_ref" => ^result_ref,
             "tool_call_id" => "call-1",
             "tool_name" => "demo.read",
             "result_json" => ^canonical,
             "result_sha256" => hash,
             "result_bytes" => bytes,
             "result_chars" => chars,
             "status" => "completed",
             "is_error" => false
           } = ToolResultProjection.stored_event(candidate)

    assert hash == candidate.result_sha256
    assert bytes == candidate.result_bytes
    assert chars == candidate.result_chars
  end

  test "counts multibyte Unicode in both serialized bytes and characters" do
    content = String.duplicate("Comma 你好 🙂 é — ", 20)

    assert {:ok, candidate} =
             ToolResultProjection.prepare(tool_result("unicode", "demo.read", content), "ref-u")

    assert candidate.result_json == Jason.encode!(content)
    assert candidate.result_bytes == byte_size(candidate.result_json)
    assert candidate.result_chars == String.length(candidate.result_json)
    assert candidate.result_bytes > candidate.result_chars

    capsule = ToolResultProjection.capsule(candidate)
    assert capsule["bytes"] == candidate.result_bytes
    assert capsule["chars"] == candidate.result_chars
    assert capsule["sha256"] == candidate.result_sha256
  end

  test "normalizes only error messages that exactly duplicate the original content" do
    duplicate =
      "duplicate-error"
      |> tool_result("demo.fail", :timeout)
      |> Map.put(:error, true)
      |> Map.put(:error_message, :timeout)

    distinct =
      "distinct-error"
      |> tool_result("demo.fail", :timeout)
      |> Map.put(:error, true)
      |> Map.put(:error_message, "short diagnostic")

    assert {:ok, duplicate_candidate} =
             ToolResultProjection.prepare(duplicate, "ref-duplicate-error")

    assert {:ok, distinct_candidate} =
             ToolResultProjection.prepare(distinct, "ref-distinct-error")

    assert duplicate_candidate.result.content == "timeout"
    assert duplicate_candidate.result.error_message == "timeout"
    assert Jason.decode!(duplicate_candidate.result_json) == "timeout"

    assert distinct_candidate.result.content == "timeout"
    assert distinct_candidate.result.error_message == "short diagnostic"
  end

  test "capsule is valid compact JSON with explicit get_result instructions" do
    result_ref = "opaque-ref-without-addressing-details"

    assert {:ok, candidate} =
             ToolResultProjection.prepare(
               tool_result("call-json", "provider.search", "{\"nested\":\"value\"}"),
               result_ref
             )

    capsule = ToolResultProjection.capsule(candidate)
    encoded = Jason.encode!(capsule)

    assert Jason.decode!(encoded) == capsule

    assert capsule == %{
             "stored_result" => true,
             "result_ref" => result_ref,
             "encoding" => "json",
             "bytes" => candidate.result_bytes,
             "chars" => candidate.result_chars,
             "sha256" => candidate.result_sha256,
             "tool_name" => "provider.search",
             "get_result" => %{
               "tool" => "tool_call.get_result",
               "arguments" => %{"result_ref" => result_ref, "offset" => 0}
             }
           }
  end

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

  test "planner is deterministic and never remints caller-supplied refs" do
    results = [
      tool_result("first", "demo.equal", String.duplicate("x", 2_000)),
      tool_result("second", "demo.equal", String.duplicate("y", 2_000))
    ]

    candidates =
      Enum.zip_with(results, ["stable-first", "stable-second"], fn result, ref ->
        {:ok, candidate} = ToolResultProjection.prepare(result, ref)
        candidate
      end)

    envelope_fun = &%{"results" => &1}
    [first, second] = candidates

    budget =
      encoded_bytes(
        envelope_fun.([
          put_content(first.result, Jason.encode!(ToolResultProjection.capsule(first))),
          second.result
        ])
      )

    assert {:ok, first_plan} = ToolResultProjection.plan(candidates, envelope_fun, budget)
    assert {:ok, second_plan} = ToolResultProjection.plan(candidates, envelope_fun, budget)
    assert first_plan == second_plan
    assert Enum.map(first_plan.stored_events, & &1["result_ref"]) == ["stable-first"]
  end

  test "spilling follows duplicate output but preserves distinct trace output" do
    duplicate_content = String.duplicate("model-visible", 100)

    duplicate =
      "duplicate"
      |> tool_result("demo.read", duplicate_content)
      |> Map.put(:output, duplicate_content)
      |> Map.put(:error_message, duplicate_content)

    distinct =
      "distinct"
      |> tool_result("demo.read", String.duplicate("content", 100))
      |> Map.put(:output, "separate trace output")
      |> Map.put(:error_message, "short diagnostic")

    {:ok, duplicate_candidate} = ToolResultProjection.prepare(duplicate, "ref-duplicate")
    {:ok, distinct_candidate} = ToolResultProjection.prepare(distinct, "ref-distinct")
    envelope_fun = &%{"results" => &1}

    duplicate_capsule = Jason.encode!(ToolResultProjection.capsule(duplicate_candidate))

    expected = [
      duplicate_candidate.result
      |> put_content(duplicate_capsule)
      |> Map.put(:output, duplicate_capsule)
      |> Map.put(:error_message, duplicate_capsule),
      distinct_candidate.result
    ]

    budget = encoded_bytes(envelope_fun.(expected))

    assert {:ok, plan} =
             ToolResultProjection.plan(
               [duplicate_candidate, distinct_candidate],
               envelope_fun,
               budget
             )

    projected_duplicate = Enum.at(plan.projected_results, 0)
    assert projected_duplicate.content == duplicate_capsule
    assert projected_duplicate.output == duplicate_capsule
    assert projected_duplicate.error_message == duplicate_capsule
    assert Enum.at(plan.projected_results, 1).output == "separate trace output"
    assert Enum.at(plan.projected_results, 1).error_message == "short diagnostic"
  end

  test "reader pages shrink against the exact escaped envelope without recursive spill" do
    result_json =
      Jason.encode!(%{
        "payload" => String.duplicate("quote:\" slash:\\ controls:\n\t multibyte:雪🚀 ", 25_000)
      })

    result_ref = "trf1_0000000000000000001"

    record = %{
      "kind" => "tool_result",
      "result_ref" => result_ref,
      "result_json" => result_json,
      "result_bytes" => byte_size(result_json),
      "result_chars" => String.length(result_json),
      "result_sha256" => sha256(result_json),
      "tool_name" => "composio.execute",
      "status" => "completed",
      "is_error" => false
    }

    initial_page = AsyncToolResults.result_page_envelope(record, 0, 120_000)
    initial_content = Jason.encode!(initial_page)

    result =
      "reader-call"
      |> tool_result("tool_call.get_result", initial_content)
      |> Map.put(:input, Jason.encode!(%{"result_ref" => result_ref, "offset" => 0}))
      |> Map.put(:output, initial_content)
      |> Map.put(:error, true)
      |> Map.put(:error_message, initial_content)

    assert {:ok, candidate} =
             ToolResultProjection.prepare(result, "trf1_0000000000000000002")

    envelope_fun = fn [projected] -> reader_outer_envelope(projected) end
    initial_outer_bytes = encoded_bytes(envelope_fun.([candidate.result]))

    assert byte_size(initial_content) > 118_000
    assert byte_size(initial_content) <= ToolResultProjection.model_envelope_max_bytes()
    assert initial_outer_bytes > ToolResultProjection.model_envelope_max_bytes()

    assert {:ok, plan} =
             ToolResultProjection.plan(
               [candidate],
               envelope_fun,
               ToolResultProjection.model_envelope_max_bytes()
             )

    [projected] = plan.projected_results
    projected_content = content(projected)
    projected_page = Jason.decode!(projected_content)["result_page"]
    original_page = initial_page["result_page"]

    assert plan.stored_events == []
    assert plan.envelope_bytes <= ToolResultProjection.model_envelope_max_bytes()
    assert encoded_bytes(envelope_fun.([projected])) == plan.envelope_bytes
    assert projected.output == projected_content
    assert projected.error_message == projected_content
    assert projected_page["result_ref"] == result_ref
    refute Map.has_key?(Jason.decode!(projected_content), "stored_result")
    assert String.valid?(projected_page["content"])
    assert projected_page["content_chars"] == String.length(projected_page["content"])
    assert projected_page["next_offset"] == projected_page["content_chars"]
    assert projected_page["truncated"]
    assert projected_page["content_chars"] < original_page["content_chars"]
    assert String.starts_with?(original_page["content"], projected_page["content"])

    one_more_char = projected_page["content_chars"] + 1
    grown_content = resize_result_page(initial_page, one_more_char)

    grown_result =
      projected
      |> put_content(grown_content)
      |> Map.put(:output, grown_content)
      |> Map.put(:error_message, grown_content)

    assert encoded_bytes(envelope_fun.([grown_result])) >
             ToolResultProjection.model_envelope_max_bytes()
  end

  test "errors when the complete envelope cannot fit even with every capsule" do
    results = [
      tool_result("a", "demo.read", String.duplicate("a", 1_000)),
      tool_result("b", "demo.read", String.duplicate("b", 1_000))
    ]

    candidates =
      Enum.zip_with(results, ["ref-a", "ref-b"], fn result, ref ->
        {:ok, candidate} = ToolResultProjection.prepare(result, ref)
        candidate
      end)

    envelope_fun = fn projected ->
      %{"large_fixed_header" => String.duplicate("h", 500), "results" => projected}
    end

    all_capsules =
      Enum.map(candidates, fn candidate ->
        put_content(candidate.result, Jason.encode!(ToolResultProjection.capsule(candidate)))
      end)

    minimum_bytes = encoded_bytes(envelope_fun.(all_capsules))
    budget = minimum_bytes - 1

    assert {:error,
            {:minimum_envelope_exceeds_budget,
             %{budget: ^budget, envelope_bytes: ^minimum_bytes, envelope: minimum_envelope}}} =
             ToolResultProjection.plan(candidates, envelope_fun, budget)

    assert minimum_envelope == envelope_fun.(all_capsules)
  end

  test "keeps the complete batch inline when the serialized envelope already fits" do
    results = [tool_result("small", "demo.read", "ok")]
    {:ok, candidate} = ToolResultProjection.prepare(hd(results), "unused-until-spill")
    envelope_fun = &%{"results" => &1}
    budget = encoded_bytes(envelope_fun.(results))

    assert {:ok,
            %{
              projected_results: ^results,
              stored_events: [],
              envelope_bytes: ^budget
            }} = ToolResultProjection.plan([candidate], envelope_fun, budget)
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

  defp reader_outer_envelope(result) do
    content = content(result)
    output = result[:output] || result["output"]

    tool_message = %{
      "id" => 2,
      "role" => "tool",
      "tool_call_id" => result[:id] || result["id"],
      "tool_name" => result[:name] || result["name"],
      "status" => result[:status] || result["status"],
      "input" => result[:input] || result["input"],
      "trace_id" => result[:trace_id] || result["trace_id"],
      "content" => content,
      "output" => if(output == content, do: nil, else: output)
    }

    tool_message =
      case result[:error_message] || result["error_message"] do
        nil -> tool_message
        error_message -> Map.put(tool_message, "error_message", error_message)
      end

    %{
      "tool_results" => [
        tool_message
      ]
    }
  end

  defp resize_result_page(envelope, content_chars) do
    page = envelope["result_page"]
    content = String.slice(page["content"], 0, content_chars)
    actual_chars = String.length(content)
    next_offset = page["offset"] + actual_chars

    page =
      page
      |> Map.put("content", content)
      |> Map.put("content_chars", actual_chars)
      |> Map.put("truncated", page["offset"] > 0 or next_offset < page["total_chars"])

    page =
      if next_offset < page["total_chars"],
        do: Map.put(page, "next_offset", next_offset),
        else: Map.delete(page, "next_offset")

    envelope
    |> Map.put("result_page", page)
    |> Jason.encode!()
  end

  defp put_content(result, value) do
    cond do
      Map.has_key?(result, :content) -> Map.put(result, :content, value)
      Map.has_key?(result, "content") -> Map.put(result, "content", value)
      true -> Map.put(result, :content, value)
    end
  end

  defp encoded_bytes(value), do: value |> Jason.encode!() |> byte_size()

  defp sha256(value),
    do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
