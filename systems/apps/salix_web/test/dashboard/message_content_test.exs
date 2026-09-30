defmodule SalixWeb.Dashboard.MessageContentTest do
  @moduledoc "Preview truncation must never emit invalid UTF-8."
  use ExUnit.Case, async: true

  alias SalixWeb.Dashboard.MessageContent

  # 1 ASCII byte + 40 three-byte characters = 121 bytes, so the default
  # 120-byte budget lands inside the 40th character.
  defp mid_character_cut, do: "x" <> String.duplicate("中", 40)

  test "preview/2 stays valid UTF-8 when the byte budget splits a character" do
    preview = MessageContent.preview(mid_character_cut())

    assert String.valid?(preview)
    assert preview == "x" <> String.duplicate("中", 39) <> "…"
  end

  test "preview/2 keeps the whole string when it fits the budget" do
    assert MessageContent.preview("中文", 120) == "中文"
  end

  test "preview/2 tolerates a budget smaller than the first character" do
    assert MessageContent.preview("中文", 2) == "…"
  end

  test "preview/2 still truncates ASCII on the byte budget" do
    assert MessageContent.preview(String.duplicate("a", 130)) ==
             String.duplicate("a", 120) <> "…"
  end

  test "preview/2 collapses whitespace across content blocks" do
    blocks = [%{"type" => "text", "text" => "第一段\n\n第二段"}]

    assert MessageContent.preview(blocks) == "第一段 第二段"
  end
end
