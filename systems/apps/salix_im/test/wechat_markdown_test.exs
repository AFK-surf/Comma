defmodule SalixIM.WeChatMarkdownTest do
  use SystemsClock.Case, async: true

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

  test "deeply nested model output survives the native parser and serializer" do
    # mdex_native 0.2.0 crashed the entire VM on this 2,001-byte input.
    markdown = String.duplicate("*", 1000) <> "x" <> String.duplicate("*", 1000)
    assert {:ok, text} = WeChatMarkdown.render(markdown)
    assert text =~ "x"
  end
end
