defmodule SalixIM.TelegramTextTest do
  use ExUnit.Case, async: true
  alias SalixIM.TelegramText

  test "ordinary replies use normal message typography and strip blanket paragraph emphasis" do
    assert {:ok, rendered} = TelegramText.message("**整段不需要加粗。**\n\n**城市：** 新加坡")
    assert rendered.method == "sendMessage"

    assert rendered.fields == %{
             "text" => "整段不需要加粗。\n\n<b>城市：</b> 新加坡",
             "parse_mode" => "HTML"
           }
  end

  test "caption subset has no rich-only markup or overlapping code entities" do
    assert {:ok, %{fields: %{caption: html, parse_mode: "HTML"}, plain: plain}} =
             TelegramText.caption(
               "# **标题 `code`**\n\n3. 三\n4. 四\n\n| A | B |\n|---|---|\n| 中 | 😀 |"
             )

    assert html =~ "<b>"
    assert html =~ "3. 三"
    assert html =~ "4. 四"
    assert html =~ "<pre>A | B"

    for tag <- ["<h", "<p>", "<li>", "<ol", "<table>", "<td>", "<code>"] do
      refute html =~ tag
    end

    assert plain =~ "标题 code"
  end

  test "literal HTML, escaped Markdown and unsafe URLs cannot become active provider markup" do
    assert {:ok, rendered} =
             TelegramText.message(
               "\\*literal\\* <b>raw</b> [bad](javascript:alert) ![img](https://example.test/image.png)"
             )

    html = rendered.fields["text"]
    assert html =~ "*literal*"
    assert html =~ "&lt;b&gt;raw&lt;/b&gt;"
    refute html =~ "javascript:"
    refute html =~ "<img"
    assert html =~ ~s(<a href="https://example.test/image.png">img</a>)
  end

  test "Unicode boundaries count code units, not graphemes, without truncation" do
    assert {:ok, _} = TelegramText.caption(String.duplicate("😀", 512), "plain")
    assert {:error, _} = TelegramText.caption(String.duplicate("😀", 513), "plain")
    assert {:ok, _} = TelegramText.message(String.duplicate("a", 4096), "plain")
    assert {:error, _} = TelegramText.message(String.duplicate("e\u0301", 2049), "plain")
    assert {:error, _} = TelegramText.message(<<255>>)
    assert {:ok, _} = TelegramText.caption("")
  end

  test "unclosed code and task lists preserve user content" do
    assert {:ok, rendered} =
             TelegramText.message("- [x] Done\n- [ ] Todo\n\n```\n**literal** <tag>")

    html = rendered.fields["text"]
    assert html =~ "☑ "
    assert html =~ "☐ "
    assert html =~ "**literal** &lt;tag&gt;"
  end

  test "caption length decodes only generated entities once and keeps literal HTML visible" do
    for format <- ["markdown", "plain"] do
      for text <- ["<tag>", "&lt;", "&amp;", "\"<>&"] do
        literal = if format == "markdown", do: "`" <> text <> "`", else: text
        source = String.duplicate("x", 1024 - String.length(text)) <> literal
        assert {:ok, _} = TelegramText.caption(source, format)
        assert {:error, _} = TelegramText.caption("x" <> source, format)
      end
    end

    assert {:ok, _} = TelegramText.caption("> " <> String.duplicate("x", 1022))
    assert {:error, _} = TelegramText.caption("> " <> String.duplicate("x", 1023))
  end

  test "formatting shape limits reject excessive blocks, depth and table columns before delivery" do
    assert {:error, _} = TelegramText.message(String.duplicate("paragraph\n\n", 501))
    assert {:error, _} = TelegramText.message(String.duplicate("> ", 17) <> "deep")
    row = "|" <> Enum.map_join(1..21, "|", &Integer.to_string/1) <> "|\n"
    separator = "|" <> Enum.map_join(1..21, "|", fn _ -> "---" end) <> "|\n"
    assert {:error, _} = TelegramText.message(row <> separator <> row)
  end
end
