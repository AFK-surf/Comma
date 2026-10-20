defmodule SalixIM.SlackMarkdownTest do
  use SystemsClock.Case, async: true

  alias SalixIM.SlackMarkdown

  describe "to_mrkdwn/1" do
    for {name, source, expected} <- [
          {"preserves inline and fenced code while converting prose",
           "`**literal** [x](https://e.test)` and **prose**\n\n" <>
             "```text\n**literal** [x](https://e.test)\n```",
           "`**literal** [x](https://e.test)` and *prose*\n\n" <>
             "```\n**literal** [x](https://e.test)\n```"},
          {"escapes Slack control characters without escaping generated links",
           "A < B & C > D <@U123> <!here> " <> "[docs](https://e.test/path?a=1&b=2)",
           "A &lt; B &amp; C &gt; D &lt;@U123&gt; &lt;!here&gt; " <>
             "<https://e.test/path?a=1&amp;b=2|docs>"},
          {"preserves standard emphasis semantics",
           "__bold__ _italic_ *also italic* ***both*** " <>
             "**bold and *nested italic*** *italic and **nested bold***",
           "*bold* _italic_ _also italic_ *_both_* " <>
             "*bold and _nested italic_* _italic and *nested bold*_"},
          {"keeps escaped, intraword, and unmatched markers literal",
           ~S(config_one_name and \*literal\* and broken **marker),
           "config`_`one`_`name and `*`literal`*` and broken `**`marker"},
          {"only treats double tildes as strikethrough", ~S(~x~ a~b~c ~~x~~ \~escaped\~),
           "`~`x`~` a`~`b`~`c ~x~ `~`escaped`~`"},
          {"keeps outer strikethrough around a protected literal marker", "~~a~b~~", "~a~`~`~b~"},
          {"keeps outer bold around protected literal markers", "**a~b~c**", "*a*`~`*b*`~`*c*"},
          {"degrades nested lists and tables to readable mrkdwn",
           "- parent\n  - **child**\n\n" <>
             "| Name | State |\n| --- | --- |\n| Build | **ready** |",
           "- parent\n  - *child*\n\n" <>
             "| Name | State |\n| --- | --- |\n| Build | *ready* |"}
        ] do
      @source source
      @expected expected
      test name do
        assert SlackMarkdown.to_mrkdwn(@source) == @expected
      end
    end
  end

  test "rich text supports combined emphasis and treats an unclosed fence literally" do
    assert %{
             "elements" => [
               %{
                 "elements" => [
                   %{"text" => "both", "style" => %{"bold" => true, "italic" => true}},
                   %{"text" => " and "},
                   %{"text" => "also", "style" => %{"bold" => true, "italic" => true}}
                 ]
               },
               %{
                 "elements" => [
                   %{"type" => "text", "text" => "```md\n**literal** [x](https://e.test)"}
                 ]
               }
             ]
           } =
             SlackMarkdown.render_rich_text(
               "***both*** and ___also___\n\n```md\n**literal** [x](https://e.test)"
             )
  end

  # Each row renders to one Markdown block; only task markers outside code are
  # rewritten, and an H1 that cannot be a plain header stays in the block.
  fenced_source = """
  Before

      - [ ] indented literal

  ```md
  - [ ] fenced literal
  ```

  ~~~~
  * [x] alternate fence
  ~~~~

  - [ ] visible item
  """

  for {name, source, expected} <- [
        {"turns ordinary Markdown task markers into non-interactive list items",
         "- [ ] Todo\n* [x] Done\n+ [X] Also done\n  - [ ] Nested\n- ordinary",
         "- Todo\n* Done\n+ Also done\n  - Nested\n- ordinary"},
        {"leaves task-like source inside fenced and indented code unchanged", fenced_source,
         String.replace(fenced_source, "- [ ] visible item", "- visible item")},
        {"does not rewrite inline brackets or non-task list syntax",
         "Text [ ] stays\n- [later] stays\n- [x](https://example.com) linked label", :same},
        {"keeps a non-plain H1 source inside the Markdown block", "# **Styled title**\n\nBody",
         :same},
        {"keeps an overlong H1 source inside the Markdown block",
         "# " <> String.duplicate("a", 151) <> "\n\nBody", :same}
      ] do
    @source source
    @expected if expected == :same, do: source, else: expected
    test name do
      assert {:ok, [%{"type" => "markdown", "text" => text}]} =
               SlackMarkdown.render_blocks(@source)

      assert text == @expected
    end
  end
end
