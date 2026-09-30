defmodule SalixVerifiedKernel.TerminalTest do
  use ExUnit.Case, async: true
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

  test "cursor addressing and erase redraw a full screen" do
    redraw = [
      "old text everywhere\r\nmore old text",
      "\e[H\e[2J",
      "\e[2;3Hmiddle",
      "\e[1;1Htop\e[K",
      "\e[5;18Hend",
      "\e[2;5H\e[1K"
    ]

    assert lines(redraw) == ["top", "     dle", "", "", "                 end"]
    assert screen(redraw)["cursor"]["row"] == 2
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

  test "scroll region insert, delete and reverse index keep a status line fixed" do
    bytes = [
      "\e[5;1Hstatus",
      "\e[1;4r",
      "\e[1;1Hone\r\ntwo\r\nthree\r\nfour",
      "\r\nfive",
      "\e[2;1H\e[L",
      "\e[1;1H\eM",
      "\e[3;1H\e[M"
    ]

    assert lines(bytes) == ["", "two", "three", "", "status"]
  end

  test "line drawing, split UTF-8, wide characters and combining marks" do
    {term, ""} = Terminal.feed(Terminal.new(12, 3), "\e(0lqk\r\nx x\r\nmqj\e(B ok")
    assert Terminal.snapshot(term)["lines"] == ["┌─┐", "│ │", "└─┘ ok"]

    <<first::binary-size(2), second::binary>> = "日本"
    {term, _} = Terminal.feed(Terminal.new(12, 2), "a" <> first)
    {term, _} = Terminal.feed(term, second <> "é!")
    snapshot = Terminal.snapshot(term)
    assert snapshot["lines"] == ["a日本e\u0301!", ""]
    assert snapshot["cursor"]["col"] == 8
  end

  test "status queries produce replies for the remote side" do
    {term, replies} = Terminal.feed(Terminal.new(20, 5), "ab\e[3;7H\e[6n\e[5n\e[c")
    assert IO.iodata_to_binary(replies) == "\e[3;7R\e[0n\e[?1;2c"
    assert Terminal.snapshot(term)["lines"] |> hd() == "ab"

    {term, ""} = Terminal.feed(term, "\e[?1h\e[?25l\e]0;build log\a")
    assert Terminal.application_cursor?(term)
    assert Terminal.snapshot(term)["cursor"]["visible"] == false
    assert Terminal.snapshot(term)["title"] == "build log"
  end

  test "resize keeps content and the cursor row" do
    {term, _} = Terminal.feed(Terminal.new(20, 5), "1\r\n2\r\n3\r\n4\r\n5 wide line")
    term = Terminal.resize(term, 10, 3)
    snapshot = Terminal.snapshot(term)
    assert snapshot["lines"] == ["3", "4", "5 wide lin"]
    assert snapshot["cursor"] == %{"row" => 3, "col" => 10, "visible" => true}
  end

  property "splitting the byte stream anywhere yields the same screen and replies" do
    fragments =
      member_of([
        "hello ",
        "\r\n",
        "\e[2J",
        "\e[3;4H",
        "\e[K",
        "\e[?1049h",
        "\e[?1049l",
        "\e[1;3r",
        "\eM",
        "\e[L",
        "\e[6n",
        "\e]2;title\e\\",
        "\e(0q\e(B",
        "日本",
        "é",
        "\t|",
        "\e[4h",
        "\e[4l",
        "\b\b",
        "\e[31;1m",
        <<0xFF>>
      ])

    check all(
            parts <- list_of(fragments, max_length: 40),
            cuts <- list_of(integer(0..400), max_length: 8)
          ) do
      bytes = IO.iodata_to_binary(parts)
      {whole, whole_replies} = Terminal.feed(Terminal.new(16, 6), bytes)

      {pieces, pieces_replies} =
        bytes
        |> split_at(cuts)
        |> Enum.reduce({Terminal.new(16, 6), []}, fn chunk, {term, acc} ->
          {term, replies} = Terminal.feed(term, chunk)
          {term, [acc, replies]}
        end)

      assert Terminal.snapshot(pieces) == Terminal.snapshot(whole)
      assert IO.iodata_to_binary(pieces_replies) == IO.iodata_to_binary(whole_replies)
    end
  end

  defp split_at(bytes, cuts) do
    cuts
    |> Enum.map(&min(&1, byte_size(bytes)))
    |> Enum.sort()
    |> Enum.uniq()
    |> Enum.reduce({[], 0}, fn cut, {parts, from} ->
      {[binary_part(bytes, from, cut - from) | parts], cut}
    end)
    |> then(fn {parts, from} ->
      Enum.reverse([binary_part(bytes, from, byte_size(bytes) - from) | parts])
    end)
  end
end
