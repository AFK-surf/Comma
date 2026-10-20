defmodule SalixWeb.Dashboard.MessageContentTest do
  @moduledoc "Preview truncation must never emit invalid UTF-8."
  use SystemsClock.Case, async: true

  alias SalixWeb.Dashboard.MessageContent

  # 1 ASCII byte + 40 three-byte characters = 121 bytes, so the default
  # 120-byte budget lands inside the 40th character.
  defp mid_character_cut, do: "x" <> String.duplicate("中", 40)

  test "preview/2 stays valid UTF-8 when the byte budget splits a character" do
    preview = MessageContent.preview(mid_character_cut())

    assert String.valid?(preview)
    assert preview == "x" <> String.duplicate("中", 39) <> "…"
  end
end
