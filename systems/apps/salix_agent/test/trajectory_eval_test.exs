defmodule SalixAgent.TrajectoryEvalTest do
  @moduledoc """
  L1 heuristic trajectory scoring (`SalixAgent.TrajectoryEval`) is pure
  detection over a transcript window: text backtracking/shortcut markers on
  assistant messages, and structural loop patterns over the tool-call
  sequence, with thresholds mirroring the OpenHands stuck detector.
  """
  use SystemsClock.Case, async: true

  alias SalixAgent.TrajectoryEval

  # ---- fixtures ----

  defp user(id, text), do: %{id: id, role: "user", content: text}

  defp assistant(id, text, opts \\ []) do
    %{
      id: id,
      role: "assistant",
      content: text,
      tool_calls: opts[:tool_calls] || [],
      round_id: opts[:round_id]
    }
  end

  defp call(id, name, args), do: %{"id" => id, "name" => name, "args" => args}

  defp tool_result(id, call_id, name, content, opts \\ []) do
    %{
      id: id,
      role: "tool",
      tool_call_id: call_id,
      tool_name: name,
      content: content,
      status: opts[:status],
      error_class: opts[:error_class]
    }
  end

  defp finding(result, metric), do: Enum.find(result.findings, &(&1.metric == metric))

  # ---- window ----

  # ---- text signals ----

  test "flags sentence-initial confusion markers with evidence quotes" do
    messages = [
      user(1, "do the thing"),
      assistant(2, "Running the migration now."),
      assistant(3, "Wait, the table is missing. Hmm, let me reconsider the plan.")
    ]

    result = TrajectoryEval.evaluate(messages)
    found = finding(result, "confusion")

    assert found.hits == 2
    assert [%{message_id: 3, quote: "Wait, the table is missing." <> _} | _] = found.evidence
  end

  # ---- structural signals ----

  test "identical call with identical result four times is a tool loop" do
    calls_and_results =
      Enum.flat_map(1..4, fn i ->
        [
          assistant(i * 2, "retrying", tool_calls: [call("c#{i}", "Exec", %{"cmd" => "ls"})]),
          tool_result(i * 2 + 1, "c#{i}", "Exec", "same output")
        ]
      end)

    result = TrajectoryEval.evaluate([user(1, "go") | calls_and_results])
    found = finding(result, "tool_loop")

    assert found.hits == 4
    assert found.score == 0.6
    assert [%{quote: quote}] = found.evidence
    assert quote =~ "Exec"
  end

  # ---- window metadata ----
end
