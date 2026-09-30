defmodule SalixIM.SlackMarkdownTest do
  use ExUnit.Case, async: true

  alias SalixIM.SlackMarkdown

  describe "to_mrkdwn/1" do
    test "preserves inline and fenced code while converting prose" do
      source =
        "`**literal** [x](https://e.test)` and **prose**\n\n" <>
          "```text\n**literal** [x](https://e.test)\n```"

      assert SlackMarkdown.to_mrkdwn(source) ==
               "`**literal** [x](https://e.test)` and *prose*\n\n" <>
                 "```\n**literal** [x](https://e.test)\n```"
    end

    test "escapes Slack control characters without escaping generated links" do
      source =
        "A < B & C > D <@U123> <!here> " <>
          "[docs](https://e.test/path?a=1&b=2)"

      assert SlackMarkdown.to_mrkdwn(source) ==
               "A &lt; B &amp; C &gt; D &lt;@U123&gt; &lt;!here&gt; " <>
                 "<https://e.test/path?a=1&amp;b=2|docs>"
    end

    test "preserves standard emphasis semantics" do
      source =
        "__bold__ _italic_ *also italic* ***both*** " <>
          "**bold and *nested italic*** *italic and **nested bold***"

      assert SlackMarkdown.to_mrkdwn(source) ==
               "*bold* _italic_ _also italic_ *_both_* " <>
                 "*bold and _nested italic_* _italic and *nested bold*_"
    end

    test "keeps escaped, intraword, and unmatched markers literal" do
      assert SlackMarkdown.to_mrkdwn(~S(config_one_name and \*literal\* and broken **marker)) ==
               "config`_`one`_`name and `*`literal`*` and broken `**`marker"
    end

    test "only treats double tildes as strikethrough" do
      assert SlackMarkdown.to_mrkdwn(~S(~x~ a~b~c ~~x~~ \~escaped\~)) ==
               "`~`x`~` a`~`b`~`c ~x~ `~`escaped`~`"
    end

    test "keeps outer styles around protected literal markers" do
      assert SlackMarkdown.to_mrkdwn("~~a~b~~") == "~a~`~`~b~"
      assert SlackMarkdown.to_mrkdwn("**a~b~c**") == "*a*`~`*b*`~`*c*"
    end

    test "degrades nested lists and tables to readable mrkdwn" do
      source =
        "- parent\n  - **child**\n\n" <>
          "| Name | State |\n| --- | --- |\n| Build | **ready** |"

      assert SlackMarkdown.to_mrkdwn(source) ==
               "- parent\n  - *child*\n\n" <>
                 "| Name | State |\n| --- | --- |\n| Build | *ready* |"
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

  test "rich text keeps single tildes literal and strikes only double tildes" do
    assert %{
             "elements" => [
               %{
                 "elements" => [
                   %{"text" => "~x~ a~b~c "},
                   %{"text" => "x", "style" => %{"strike" => true}},
                   %{"text" => " ~escaped~"}
                 ]
               }
             ]
           } = SlackMarkdown.render_rich_text(~S(~x~ a~b~c ~~x~~ \~escaped\~))
  end

  test "rich text keeps parent styles when they contain literal markers" do
    assert %{
             "elements" => [
               %{
                 "elements" => [
                   %{"text" => "a~b", "style" => %{"strike" => true}},
                   %{"text" => " and "},
                   %{"text" => "a~b~c", "style" => %{"bold" => true}}
                 ]
               }
             ]
           } = SlackMarkdown.render_rich_text("~~a~b~~ and **a~b~c**")
  end

  test "single-tilde source positions stay byte-accurate across rich block contexts" do
    source = "中文🙂 ~x~\n\n> 引用 a~b~c\n\n- 列表 ~c~\n\n硬换行  \n~d~"

    assert %{
             "elements" => [
               %{"elements" => [%{"text" => "中文🙂 ~x~"}]},
               %{"type" => "rich_text_quote", "elements" => [%{"text" => "引用 a~b~c"}]},
               %{
                 "type" => "rich_text_list",
                 "elements" => [%{"elements" => [%{"text" => "列表 ~c~"}]}]
               },
               %{"elements" => [%{"text" => "硬换行\n~d~"}]}
             ]
           } = rendered = SlackMarkdown.render_rich_text(source)

    refute Jason.encode!(rendered) =~ "strike"
  end

  test "promotes one plain leading H1 and preserves the remaining source" do
    body = "## Details\n\n- Follow up\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"

    assert {:ok,
            [
              %{
                "type" => "header",
                "text" => %{"type" => "plain_text", "text" => "Release report"}
              },
              %{"type" => "markdown", "text" => ^body}
            ]} =
             SlackMarkdown.render_blocks(
               "# Release report\n\n## Details\n\n- [ ] Follow up\n\n" <>
                 "| A | B |\n| --- | --- |\n| 1 | 2 |"
             )
  end

  test "turns ordinary Markdown task markers into non-interactive list items" do
    source = "- [ ] Todo\n* [x] Done\n+ [X] Also done\n  - [ ] Nested\n- ordinary"

    assert {:ok, [%{"type" => "markdown", "text" => text}]} =
             SlackMarkdown.render_blocks(source)

    assert text == "- Todo\n* Done\n+ Also done\n  - Nested\n- ordinary"
  end

  test "leaves task-like source inside fenced and indented code unchanged" do
    source = """
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

    expected = String.replace(source, "- [ ] visible item", "- visible item")

    assert {:ok, [%{"type" => "markdown", "text" => ^expected}]} =
             SlackMarkdown.render_blocks(source)
  end

  test "does not rewrite inline brackets or non-task list syntax" do
    source = "Text [ ] stays\n- [later] stays\n- [x](https://example.com) linked label"

    assert {:ok, [%{"type" => "markdown", "text" => ^source}]} =
             SlackMarkdown.render_blocks(source)
  end

  test "keeps non-plain and overlong H1 source inside the Markdown block" do
    styled = "# **Styled title**\n\nBody"
    overlong = "# " <> String.duplicate("a", 151) <> "\n\nBody"

    assert {:ok, [%{"type" => "markdown", "text" => ^styled}]} =
             SlackMarkdown.render_blocks(styled)

    assert {:ok, [%{"type" => "markdown", "text" => ^overlong}]} =
             SlackMarkdown.render_blocks(overlong)
  end

  test "removes only the title separator and preserves additional source whitespace" do
    assert {:ok,
            [
              %{"type" => "header"},
              %{"type" => "markdown", "text" => "\nParagraph"}
            ]} = SlackMarkdown.render_blocks("# Title\n\n\nParagraph")
  end

  test "applies the 12000-character limit cumulatively across Markdown blocks" do
    boundary = String.duplicate("a", 12_000)

    assert {:ok, [%{"type" => "markdown", "text" => ^boundary}]} =
             SlackMarkdown.render_blocks(boundary)

    assert {:error, :markdown_too_long} = SlackMarkdown.render_blocks(boundary <> "a")

    assert :ok =
             SlackMarkdown.validate_blocks!([
               %{"type" => "markdown", "text" => String.duplicate("a", 6_000)},
               %{"type" => "markdown", "text" => String.duplicate("b", 6_000)}
             ])

    assert_raise RuntimeError,
                 "cumulative markdown block text exceeds 12000 characters",
                 fn ->
                   SlackMarkdown.validate_blocks!([
                     %{"type" => "markdown", "text" => String.duplicate("a", 6_001)},
                     %{"type" => "markdown", "text" => String.duplicate("b", 6_000)}
                   ])
                 end
  end
end
