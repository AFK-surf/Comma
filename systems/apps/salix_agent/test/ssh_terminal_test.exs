defmodule SalixVerifiedKernel.TerminalTest do
  use SystemsClock.Case, async: true
  use ExUnitProperties

  alias SalixVerifiedKernel.Terminal

  defp screen(bytes, cols \\ 20, rows \\ 5) do
    {term, _replies} = Terminal.feed(Terminal.new(cols, rows), IO.iodata_to_binary(bytes))
    Terminal.snapshot(term)
  end

  defp lines(bytes, cols \\ 20, rows \\ 5), do: screen(bytes, cols, rows)["lines"]

  test "shell output wraps at the right edge and scrolls at the bottom" do
    snapshot =
      screen(["$ echo 1234567890123456789012345\r\n", "1234567890123456789012345\r\n", "$ "])

    assert snapshot["lines"] == [
             "$ echo 1234567890123",
             "456789012345",
             "12345678901234567890",
             "12345",
             "$"
           ]

    assert snapshot["cursor"] == %{"row" => 5, "col" => 3, "visible" => true}

    # Two more lines push the oldest rows off the top.
    assert lines(["a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng"]) == ["c", "d", "e", "f", "g"]
  end

  test "a full-screen program's alternate screen restores the shell screen on exit" do
    bytes = [
      "$ vim notes\r\n",
      "\e[?1049h\e[H\e[2J~ editing\e[5;1H-- INSERT --",
      "\e[?1049l"
    ]

    during = screen(Enum.take(bytes, 2))
    assert during["alternate_screen"]
    assert hd(during["lines"]) == "~ editing"

    after_exit = screen(bytes)
    refute after_exit["alternate_screen"]
    assert after_exit["lines"] == ["$ vim notes", "", "", "", ""]
    assert after_exit["cursor"] == %{"row" => 2, "col" => 1, "visible" => true}
  end
end
