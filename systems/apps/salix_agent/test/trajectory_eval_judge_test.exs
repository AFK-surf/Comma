defmodule SalixAgent.TrajectoryEvalJudgeTest do
  @moduledoc """
  The L2 judge turns one window into one small-model call with per-metric
  rubrics and parses strict-JSON verdicts. Metric selection is L1-flagged ∪
  core ∪ judge-only; unknown metrics and malformed verdicts are dropped.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State
  alias SalixAgent.LLM.Mock
  alias SalixAgent.TrajectoryEval.Judge

  setup do
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_providers = Application.get_env(:salix_agent, :trajectory_eval_judge_providers)
    start_supervised!(Mock)
    Application.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      if prev_llm,
        do: Application.put_env(:salix_agent, :llm, prev_llm),
        else: Application.delete_env(:salix_agent, :llm)

      if prev_providers,
        do: Application.put_env(:salix_agent, :trajectory_eval_judge_providers, prev_providers),
        else: Application.delete_env(:salix_agent, :trajectory_eval_judge_providers)
    end)

    :ok
  end

  @clean_verdicts ~s({"verdicts":[) <>
                    ~s({"metric":"confusion","verdict":"rejected","score":0.0,"reason":"r","evidence":""},) <>
                    ~s({"metric":"shortcut","verdict":"rejected","score":0.0,"reason":"r","evidence":""},) <>
                    ~s({"metric":"goal_drift","verdict":"rejected","score":0.0,"reason":"r","evidence":""},) <>
                    ~s({"metric":"silent_failure","verdict":"rejected","score":0.0,"reason":"r","evidence":""}]})

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

  test "judged metrics are flagged ∪ core ∪ judge-only, deduplicated" do
    assert Judge.judged_metrics(l1_result([%{metric: "tool_loop"}, %{metric: "confusion"}])) ==
             ["tool_loop", "confusion", "shortcut", "goal_drift", "silent_failure"]

    assert Judge.judged_metrics(l1_result([])) ==
             ["confusion", "shortcut", "goal_drift", "silent_failure"]
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

  test "code fences are tolerated, unknown metrics and bad verdicts dropped" do
    text = """
    ```json
    {"verdicts":[
      {"metric":"confusion","verdict":"confirmed","score":1.7,"reason":"r","evidence":"e"},
      {"metric":"made_up_metric","verdict":"confirmed","score":0.9,"reason":"r","evidence":"e"},
      {"metric":"shortcut","verdict":"maybe","score":0.5,"reason":"r","evidence":"e"}
    ]}
    ```
    """

    assert {:ok, judge} = Judge.parse(text, ["confusion", "shortcut"], "m")
    assert [verdict] = judge["verdicts"]
    assert verdict["metric"] == "confusion"
    assert verdict["score"] == 1.0
  end

  test "integer boundary scores are coerced to floats, not crashed" do
    text =
      ~s({"verdicts":[) <>
        ~s({"metric":"confusion","verdict":"confirmed","score":1,"reason":"r","evidence":"e"},) <>
        ~s({"metric":"shortcut","verdict":"rejected","score":0,"reason":"r","evidence":""}]})

    assert {:ok, judge} = Judge.parse(text, ["confusion", "shortcut"], "m")

    assert [
             %{"metric" => "confusion", "score" => confirmed_score},
             %{"metric" => "shortcut", "score" => rejected_score}
           ] = judge["verdicts"]

    assert confirmed_score === 1.0
    assert rejected_score === 0.0
  end

  test "arbitrary-precision integer scores clamp through the judge boundary" do
    huge = String.duplicate("9", 310)

    Mock.script([
      {:final,
       ~s({"verdicts":[) <>
         ~s({"metric":"confusion","verdict":"confirmed","score":#{huge},"reason":"r","evidence":"e"},) <>
         ~s({"metric":"shortcut","verdict":"rejected","score":-#{huge},"reason":"r","evidence":""}]})}
    ])

    assert {:ok, judge} =
             Judge.run("agent-j", "s1", state(messages()), l1_result([]),
               llm_opts: %{"model" => "mock"}
             )

    assert [
             %{"metric" => "confusion", "score" => confirmed_score},
             %{"metric" => "shortcut", "score" => rejected_score}
           ] = judge["verdicts"]

    assert confirmed_score === 1.0
    assert rejected_score === 0.0
  end

  test "JSON embedded in prose is extracted" do
    text =
      "Based on the transcript, here is my analysis:\n" <>
        ~s({"verdicts":[{"metric":"confusion","verdict":"rejected","score":0.0,"reason":"r","evidence":""}]}) <>
        "\nLet me know if you need more detail."

    assert {:ok, judge} = Judge.parse(text, ["confusion"], "m")
    assert [%{"metric" => "confusion", "verdict" => "rejected"}] = judge["verdicts"]
  end

  test "judge_provider option resolves the model from the allowlist" do
    Application.put_env(:salix_agent, :trajectory_eval_judge_providers, %{
      "luna" => %{
        label: "GPT-5.6 Luna",
        protocol: "chat_completions",
        base_url: "https://gw.example/v1",
        model: "luna-x",
        api_key: "k"
      }
    })

    Mock.script([{:final, @clean_verdicts}])

    assert {:ok, judge} =
             Judge.run("agent-j", "s1", state(messages()), l1_result([]), judge_provider: "luna")

    # The stored result records the allowlist model, not the template's.
    assert judge["model"] == "luna-x"
  end

  test "an explicit llm_opts still wins over a judge_provider" do
    Application.put_env(:salix_agent, :trajectory_eval_judge_providers, %{
      "luna" => %{label: "L", protocol: "chat_completions", model: "luna-x", api_key: "k"}
    })

    Mock.script([{:final, @clean_verdicts}])

    assert {:ok, judge} =
             Judge.run("agent-j", "s1", state(messages()), l1_result([]),
               llm_opts: %{"model" => "explicit-model"},
               judge_provider: "luna"
             )

    assert judge["model"] == "explicit-model"
  end

  test "a judge_provider with no resolvable key is skipped, not called blind" do
    Application.put_env(:salix_agent, :trajectory_eval_judge_providers, %{
      "luna" => %{
        label: "L",
        protocol: "chat_completions",
        model: "luna-x",
        api_key_env: "JUDGE_UNSET_KEY_#{System.unique_integer([:positive])}"
      }
    })

    # No LLM turn is scripted: resolution must fail BEFORE any provider call.
    assert {:error, {:no_key, "luna"}} =
             Judge.run("agent-j", "s1", state(messages()), l1_result([]), judge_provider: "luna")
  end

  test "non-JSON output is a bad_judge_output error" do
    assert {:error, {:bad_judge_output, _}} =
             Judge.parse("I think the agent is confused.", ["confusion"], "m")
  end

  test "LLM errors surface as llm_error" do
    Mock.script([{:error, %{"category" => "transport_error", "message" => "boom"}}])

    assert {:error, {:llm_error, _, _}} =
             Judge.run("agent-j", "s1", state(messages()), l1_result([]),
               llm_opts: %{"model" => "mock"}
             )
  end

  test "transcript rendering includes roles, tool calls and drops oldest over budget" do
    window = [
      %{id: 2, role: "assistant", content: String.duplicate("a", 300), tool_calls: []},
      %{
        id: 3,
        role: "assistant",
        content: "calling",
        tool_calls: [%{"id" => "c1", "name" => "Exec", "args" => %{"cmd" => "ls"}}]
      },
      %{id: 4, role: "tool", tool_call_id: "c1", tool_name: "Exec", content: "out", status: "ok"}
    ]

    rendered = Judge.render_transcript(window)
    assert rendered =~ "[#3 assistant] calling"
    assert rendered =~ "-> tool_call Exec"
    assert rendered =~ "[#4 tool Exec ok] out"

    small = Judge.render_transcript(window, 120)
    assert small =~ "earlier messages omitted"
    assert small =~ "[#4 tool Exec ok] out"
    refute small =~ String.duplicate("a", 50)
  end
end
