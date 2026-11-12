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
end
