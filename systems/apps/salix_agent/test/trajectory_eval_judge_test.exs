defmodule SalixAgent.TrajectoryEvalJudgeTest do
  @moduledoc """
  The L2 judge turns one window into one small-model call with per-metric
  rubrics and parses strict-JSON verdicts. Metric selection is L1-flagged ∪
  core ∪ judge-only; unknown metrics and malformed verdicts are dropped.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State
  alias SalixAgent.LLM.Mock
  alias SalixAgent.TrajectoryEval.Judge

  setup do
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_providers = SystemsRuntime.get_env(:salix_agent, :trajectory_eval_judge_providers)
    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      if prev_llm,
        do: SystemsRuntime.put_env(:salix_agent, :llm, prev_llm),
        else: SystemsRuntime.delete_env(:salix_agent, :llm)

      if prev_providers,
        do:
          SystemsRuntime.put_env(:salix_agent, :trajectory_eval_judge_providers, prev_providers),
        else: SystemsRuntime.delete_env(:salix_agent, :trajectory_eval_judge_providers)
    end)

    :ok
  end

  defp state(messages) do
    InternalSession.open(%State{
      InternalSession.export(InternalSession.new("agent-j", "s1", %{}))
      | messages: messages,
        billing_context: %{"surface" => "commaboard"}
    })
  end

  defp l1_result(findings) do
    %{
      findings: findings,
      window: %{message_count: 2, from_message_id: 2, to_message_id: 3, round_id: "r1"}
    }
  end

  defp messages do
    [
      %{id: 1, role: "user", content: "fix the flaky test properly"},
      %{
        id: 2,
        role: "assistant",
        content: "Wait, this fails differently.",
        tool_calls: [%{"id" => "c1", "name" => "Exec", "args" => %{"cmd" => "mix test"}}]
      },
      %{
        id: 3,
        role: "tool",
        tool_call_id: "c1",
        tool_name: "Exec",
        content: "1 failure",
        status: "ok"
      }
    ]
  end

  test "runs one LLM call and returns normalized verdicts" do
    Mock.script([
      {:final,
       ~s({"verdicts":[) <>
         ~s({"metric":"confusion","verdict":"confirmed","score":0.7,"reason":"Backtracked.","evidence":"Wait, this fails differently."},) <>
         ~s({"metric":"shortcut","verdict":"rejected","score":0.0,"reason":"Stayed on task.","evidence":""},) <>
         ~s({"metric":"goal_drift","verdict":"rejected","score":0.1,"reason":"On task.","evidence":""},) <>
         ~s({"metric":"silent_failure","verdict":"rejected","score":0.0,"reason":"No claim.","evidence":""}]})}
    ])

    assert {:ok, judge} =
             Judge.run(
               "agent-j",
               "s1",
               state(messages()),
               l1_result([%{metric: "confusion", hits: 1}]),
               llm_opts: %{"model" => "mock-haiku"}
             )

    assert judge["model"] == "mock-haiku"
    assert judge["prompt_version"] == "1"
    assert judge["metrics"] == ["confusion", "shortcut", "goal_drift", "silent_failure"]

    confirmed = Enum.find(judge["verdicts"], &(&1["verdict"] == "confirmed"))
    assert confirmed["metric"] == "confusion"
    assert confirmed["score"] == 0.7
  end
end
