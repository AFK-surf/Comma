defmodule Salix.Bindings.DailyBriefModelTest do
  use SystemsClock.Case, async: false

  alias Salix.Bindings.DailyBriefModel

  setup do
    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :daily_brief_test_completion) end)
    :ok
  end

  defp answers(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    SystemsRuntime.put_env(:salix_web, :daily_brief_test_completion, fn _input ->
      Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
    end)
  end

  defp response(finish, text, out),
    do:
      {:ok,
       %{
         "choices" => [%{"finish_reason" => finish, "message" => %{"content" => text}}],
         "usage" => %{"prompt_tokens" => 100, "completion_tokens" => out}
       }}

  test "a note cut off at the output limit is written again, and both calls count" do
    answers([response("length", "写到一半", 32_000), response("stop", "完整的简报", 900)])

    assert DailyBriefModel.compose(%{agent_id: "agt", input: %{}}) ==
             {:ok, %{text: "完整的简报", usage: %{input_tokens: 200, output_tokens: 32_900}}}
  end

  test "a note cut off twice is never returned" do
    answers([response("length", "半截", 32_000), response("length", "又半截", 32_000)])

    assert DailyBriefModel.compose(%{agent_id: "agt", input: %{}, view: :team}) ==
             {:error, {:truncated_model_response, %{input_tokens: 200, output_tokens: 64_000}}}
  end

  test "personal steps share an identical two-message prefix for prompt caching" do
    owner = SystemsRuntime.Proc.self()

    SystemsRuntime.put_env(:salix_web, :daily_brief_test_completion, fn _input, messages ->
      SystemsRuntime.Proc.send(owner, {:messages, messages})
      response("stop", ~s({"items": []}), 20)
    end)

    base = %{
      "previous_brief" => "上期简报",
      "items" => [%{"ref" => "m1", "text" => "进度"}],
      "me" => %{"label" => "@Alice", "names" => ["Alice"]},
      "now" => "2026-11-16T09:00:00+08:00",
      "my_talk" => [%{"where" => "t1", "in" => "#dev", "refs" => "m1"}],
      "closed" => [],
      "issues" => [%{"ref" => "#42", "state" => "merged"}],
      "my_prs" => [],
      "team_brief" => "团队简报"
    }

    mine_input = Map.put(base, "followups", [%{"what" => "旧待办", "status" => "open"}])
    compose_input = Map.put(base, "mine", [%{"what" => "新待办", "status" => "open"}])

    cover_input =
      compose_input
      |> Map.put("draft", "初稿")
      |> Map.put("missing", [%{"where" => "t1", "in" => "#dev", "refs" => "m1"}])

    assert {:ok, _} = DailyBriefModel.compose(%{agent_id: "agt", input: mine_input, view: :mine})
    assert {:ok, _} = DailyBriefModel.compose(%{agent_id: "agt", input: compose_input})
    assert {:ok, _} = DailyBriefModel.compose(%{agent_id: "agt", input: cover_input})

    assert_received {:messages, [sys_1, shared_1, step_1]}
    assert_received {:messages, [sys_2, shared_2, step_2]}
    assert_received {:messages, [sys_3, shared_3, step_3]}

    assert sys_1 == sys_2
    assert sys_2 == sys_3
    assert shared_1 == shared_2
    assert shared_2 == shared_3
    assert step_1 != step_2
    assert step_2 != step_3
    assert step_1["content"] =~ ~s("followups")
    assert step_2["content"] =~ ~s("mine")
    assert step_3["content"] =~ ~s("draft")
  end
end
