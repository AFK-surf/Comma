defmodule SalixAgent.TrajectoryEvalTest do
  @moduledoc """
  L1 heuristic trajectory scoring (`SalixAgent.TrajectoryEval`) is pure
  detection over a transcript window: text backtracking/shortcut markers on
  assistant messages, and structural loop patterns over the tool-call
  sequence, with thresholds mirroring the OpenHands stuck detector.
  """
  use ExUnit.Case, async: true

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

  defp metrics(result), do: Enum.map(result.findings, & &1.metric)

  defp finding(result, metric), do: Enum.find(result.findings, &(&1.metric == metric))

  # ---- window ----

  test "window keeps only messages after the last user message" do
    messages = [
      user(1, "first"),
      assistant(2, "Wait, that seems off."),
      user(3, "second"),
      assistant(4, "All good.")
    ]

    window = TrajectoryEval.window(messages)
    assert Enum.map(window, & &1.id) == [4]
  end

  test "window is capped at the configured limit" do
    messages = [user(1, "go") | Enum.map(2..100, &assistant(&1, "step #{&1}"))]
    assert length(TrajectoryEval.window(messages, window_limit: 10)) == 10
  end

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

  test "imperative wait-for usage is not confusion" do
    messages = [
      user(1, "deploy"),
      assistant(2, "Wait for the build to finish before promoting."),
      assistant(3, "Waiting on CI now.")
    ]

    refute "confusion" in metrics(TrajectoryEval.evaluate(messages))
  end

  test "confusion markers match Chinese pivots" do
    messages = [
      user(1, "跑一下迁移"),
      assistant(2, "等等，这个表不存在。不对，我记错了。")
    ]

    assert finding(TrajectoryEval.evaluate(messages), "confusion").hits >= 1
  end

  test "flags shortcut markers anywhere in a sentence" do
    messages = [
      user(1, "fix the root cause"),
      assistant(2, "This is getting complex, let me take a simpler approach instead."),
      assistant(3, "I'll skip this for now and revisit later.")
    ]

    found = finding(TrajectoryEval.evaluate(messages), "shortcut")
    assert found.hits == 2
    assert found.score == 1.0
  end

  test "text signals only inspect messages inside the window" do
    messages = [
      assistant(1, "Wait, something is wrong here."),
      user(2, "try again"),
      assistant(3, "Done, no problems this time.")
    ]

    assert metrics(TrajectoryEval.evaluate(messages)) == []
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

  test "identical call with changing results is polling, not a loop" do
    calls_and_results =
      Enum.flat_map(1..5, fn i ->
        [
          assistant(i * 2, "checking", tool_calls: [call("c#{i}", "Exec", %{"cmd" => "status"})]),
          tool_result(i * 2 + 1, "c#{i}", "Exec", "progress #{i}%")
        ]
      end)

    refute "tool_loop" in metrics(TrajectoryEval.evaluate([user(1, "go") | calls_and_results]))
  end

  test "three consecutive errors of the same tool is an error loop" do
    calls_and_results =
      Enum.flat_map(1..3, fn i ->
        [
          assistant(i * 2, "trying",
            tool_calls: [call("c#{i}", "WebSearch", %{"q" => "attempt #{i}"})]
          ),
          tool_result(i * 2 + 1, "c#{i}", "WebSearch", "boom #{i}",
            status: "error",
            error_class: "timeout"
          )
        ]
      end)

    found =
      finding(TrajectoryEval.evaluate([user(1, "go") | calls_and_results]), "tool_error_loop")

    assert found.hits == 3
  end

  test "a success between errors breaks the error streak" do
    seq = [
      user(1, "go"),
      assistant(2, "t", tool_calls: [call("c1", "Exec", %{"n" => 1})]),
      tool_result(3, "c1", "Exec", "err", status: "error"),
      assistant(4, "t", tool_calls: [call("c2", "Exec", %{"n" => 2})]),
      tool_result(5, "c2", "Exec", "ok"),
      assistant(6, "t", tool_calls: [call("c3", "Exec", %{"n" => 3})]),
      tool_result(7, "c3", "Exec", "err", status: "error"),
      assistant(8, "t", tool_calls: [call("c4", "Exec", %{"n" => 4})]),
      tool_result(9, "c4", "Exec", "err", status: "error")
    ]

    refute "tool_error_loop" in metrics(TrajectoryEval.evaluate(seq))
  end

  test "six alternating A-B calls is an alternating loop" do
    seq =
      Enum.flat_map(1..3, fn i ->
        [
          assistant(i * 10, "a", tool_calls: [call("a#{i}", "Read", %{"f" => "x"})]),
          tool_result(i * 10 + 1, "a#{i}", "Read", "content #{i}"),
          assistant(i * 10 + 2, "b", tool_calls: [call("b#{i}", "Edit", %{"f" => "x"})]),
          tool_result(i * 10 + 3, "b#{i}", "Edit", "edited #{i}")
        ]
      end)

    found = finding(TrajectoryEval.evaluate([user(1, "go") | seq]), "alternating_loop")
    assert found.hits == 6
  end

  test "distinct call sequences produce no structural findings" do
    seq =
      Enum.flat_map(1..6, fn i ->
        [
          assistant(i * 2, "step", tool_calls: [call("c#{i}", "Exec", %{"cmd" => "step #{i}"})]),
          tool_result(i * 2 + 1, "c#{i}", "Exec", "output #{i}")
        ]
      end)

    result = TrajectoryEval.evaluate([user(1, "go") | seq])
    assert Enum.filter(metrics(result), &(&1 =~ "loop")) == []
  end

  test "many assistant turns since the last user message is flagged" do
    messages = [user(1, "go") | Enum.map(2..14, &assistant(&1, "turn #{&1}"))]

    found = finding(TrajectoryEval.evaluate(messages), "excessive_turns")
    assert found.hits == 13
  end

  # ---- window metadata ----

  test "window metadata carries bounds and the last round id" do
    messages = [
      user(1, "go"),
      assistant(2, "first", round_id: "round-a"),
      assistant(3, "second", round_id: "round-b")
    ]

    %{window: window} = TrajectoryEval.evaluate(messages)

    assert window.from_message_id == 2
    assert window.to_message_id == 3
    assert window.round_id == "round-b"
    assert window.message_count == 2
  end

  test "string-keyed messages are handled" do
    messages = [
      %{"id" => 1, "role" => "user", "content" => "go"},
      %{"id" => 2, "role" => "assistant", "content" => "Wait, this looks wrong."}
    ]

    assert finding(TrajectoryEval.evaluate(messages), "confusion").hits == 1
  end
end
