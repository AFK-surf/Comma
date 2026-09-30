defmodule BridgeForTeams.TriageTaskCardTextTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.TriageTaskCardText
  alias SalixIM.MessageRenderer
  alias SalixIM.MessageRenderer.Surface
  alias SalixIM.Provider.Slack.MessageRenderer, as: SlackRenderer

  test "real native-card rendering preserves repeated inline evidence and earlier details" do
    surface = %Surface{
      kind: :task_card,
      id: "test-evidence",
      title: "Token investigation",
      status: :in_progress,
      fallback: "Investigation in progress",
      details: "请求为 `token_expired`。\n\n旧说法：**从未刷新**。",
      output: "过期（`token_expired`）；`null` 不等于从未刷新。\n\n- 查[日志](https://example.test/log)\n- 查覆盖范围",
      sources: [%{text: "原线程", url: "https://example.test/thread"}]
    }

    assert {:ok, rendered} = MessageRenderer.render_surface(SlackRenderer, surface)
    params = %{"text" => rendered.text, "blocks" => rendered.blocks}
    text = TriageTaskCardText.render!(params)

    assert text =~ "请求为 token_expired。\n旧说法：从未刷新。"
    assert text =~ "过期（token_expired）；null 不等于从未刷新。"
    assert text =~ "- 查日志\n- 查覆盖范围"
    assert text =~ "原线程 (https://example.test/thread)"
    assert length(Regex.scan(~r/token_expired/, text)) == 2

    # This was the live probe's prior observer: it drops repeated fragments.
    refute SalixIM.SlackMessageMirror.BlockText.flatten(params) =~ "过期（token_expired）"
  end

  test "quoting or striking an old claim remains distinguishable from endorsement" do
    assert {:ok, rendered} =
             MessageRenderer.render_surface(SlackRenderer, %Surface{
               kind: :task_card,
               id: "test-correction",
               title: "Correction",
               status: :in_progress,
               fallback: "Correction",
               output: "> 旧说法：从未刷新\n\n~~从未刷新~~：现有记录不足以支持此说法。"
             })

    text = TriageTaskCardText.render!(%{"text" => rendered.text, "blocks" => rendered.blocks})
    assert text =~ "> 旧说法：从未刷新"
    assert text =~ "~~从未刷新~~：现有记录不足以支持此说法。"
  end

  test "native main output is compared independently of an identical answer in fallback or details" do
    worker = "Incident: `null` does not prove **no refresh**.\n\n- Check the exact request."

    assert {:ok, rendered} =
             MessageRenderer.render_surface(SlackRenderer, %Surface{
               kind: :task_card,
               id: "test-output-owner",
               title: "Investigation",
               status: :complete,
               fallback: worker,
               details: worker,
               output: "Incident: acknowledged."
             })

    params = %{"text" => rendered.text, "blocks" => rendered.blocks}
    assert TriageTaskCardText.render!(params) =~ "null does not prove no refresh"

    refute TriageTaskCardText.main_output!(params) ==
             TriageTaskCardText.output_for_content!(worker)

    assert TriageTaskCardText.main_output!(params) ==
             TriageTaskCardText.output_for_content!("Incident: acknowledged.")
  end

  test "expected main output uses the native Markdown renderer without clipping long answers" do
    text = "  > `null` is unknown\n\n~~Never refreshed~~\n\n" <> String.duplicate("证据", 1_300)
    complete = String.trim(text)

    assert {:ok, rendered} =
             MessageRenderer.render_surface(SlackRenderer, %Surface{
               kind: :task_card,
               id: "test-output-bound",
               title: "Investigation",
               status: :complete,
               fallback: "Investigation",
               output: complete
             })

    assert TriageTaskCardText.output_for_content!([%{"type" => "text", "text" => text}]) ==
             TriageTaskCardText.main_output!(%{"blocks" => rendered.blocks})

    assert_raise FunctionClauseError, fn ->
      TriageTaskCardText.main_output!(%{"text" => complete, "blocks" => []})
    end
  end

  test "unsupported card and rich-text shapes fail instead of silently losing words" do
    assert_raise FunctionClauseError, fn ->
      TriageTaskCardText.render!(%{"blocks" => [%{"type" => "future_card", "text" => "lost"}]})
    end

    assert_raise FunctionClauseError, fn ->
      TriageTaskCardText.render!(%{
        "blocks" => [
          %{
            "type" => "task_card",
            "title" => "Title",
            "status" => "pending",
            "output" => %{
              "type" => "rich_text",
              "elements" => [%{"type" => "future_section", "text" => "lost"}]
            }
          }
        ]
      })
    end
  end
end
