defmodule SalixIM.WeChatMarkdownTest do
  use ExUnit.Case, async: true

  alias SalixIM.WeChatMarkdown

  test "keeps supported formatting and literal code while adapting prose" do
    markdown = """
    ## Result

    **粗体** and *English* and *中文斜体*

    ##### Detail

    > quoted text

    - first
    - second

    | Name | Value |
    | --- | --- |
    | CPU | 80% |

    `![literal](image.png) *中文* <tag>`

    ```md
    ##### unchanged
    ![literal](image.png) *中文* <tag>
    ```
    """

    assert {:ok, text} = WeChatMarkdown.render(markdown)
    assert text =~ "## Result"
    assert text =~ "**粗体** and *English* and 中文斜体"
    assert text =~ "\n\nDetail\n\n"
    assert text =~ "> quoted text"
    assert text =~ "first"
    assert text =~ "| Name | Value |"
    assert text =~ "`![literal](image.png) *中文* <tag>`"
    assert text =~ "```md\n##### unchanged\n![literal](image.png) *中文* <tag>\n```"
  end

  test "removes unsupported images while retaining surrounding prose and ordinary links" do
    markdown = """
    Before ![图][preview] after [report](https://example.com/report).

    [preview]: https://example.com/image.png
    """

    assert {:ok, text} = WeChatMarkdown.render(markdown)
    assert text == "Before  after [report](https://example.com/report)."

    for image <- [
          "![foo [bar](https://page)](https://image)",
          "[![Preview](https://image)](https://page)",
          "[![](https://image)](https://page)",
          "**![image](https://image)**",
          "[**![image](https://image)**](https://page)"
        ] do
      assert {:ok, ""} = WeChatMarkdown.render(image)
    end
  end

  test "escapes comparisons and HTML-like prose while preserving following text" do
    assert {:ok, text} = WeChatMarkdown.render("当 CPU<80% 时 **正常**。 <b>原文</b>")
    assert text =~ "CPU\\<80%"
    assert text =~ "**正常**"
    assert text =~ "\\<b\\>原文\\</b\\>"

    assert {:ok, text} = WeChatMarkdown.render("<div>literal content</div>")
    assert text == "\\<div\\>literal content\\</div\\>"
  end

  test "indented code remains code when it starts the reply" do
    assert {:ok, text} = WeChatMarkdown.render("    ![literal](image.png)\n    *中文* <tag>")

    assert [%MDEx.CodeBlock{literal: "![literal](image.png)\n*中文* <tag>\n"}] =
             MDEx.parse_document!(text).nodes
  end

  test "deeply nested model output survives the native parser and serializer" do
    # mdex_native 0.2.0 crashed the entire VM on this 2,001-byte input.
    markdown = String.duplicate("*", 1000) <> "x" <> String.duplicate("*", 1000)
    assert {:ok, text} = WeChatMarkdown.render(markdown)
    assert text =~ "x"
  end
end
