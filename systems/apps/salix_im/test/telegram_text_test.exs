defmodule SalixIM.TelegramTextTest do
  use SystemsClock.Case, async: true
  alias SalixIM.TelegramText

  test "ordinary replies use normal message typography and strip blanket paragraph emphasis" do
    assert {:ok, rendered} = TelegramText.message("**整段不需要加粗。**\n\n**城市：** 新加坡")
    assert rendered.method == "sendMessage"

    assert rendered.fields == %{
             "text" => "整段不需要加粗。\n\n<b>城市：</b> 新加坡",
             "parse_mode" => "HTML"
           }
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
end
