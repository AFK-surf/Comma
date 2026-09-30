defmodule CommaTUI.TerminalTest do
  use ExUnit.Case, async: true
  alias CommaTUI.{Editor, Input, Screen, Text}

  test "colors preserve cell layout, strip injected controls and repaint style changes" do
    view = %{
      title: "Comma",
      lines: [
        {:styled, :cyan, "You"},
        "Comma\e[31m\e]52;c;SECRET\a",
        {:styled, :green, "Comma"},
        "hello"
      ],
      editor: %Editor{},
      footer: "Enter send",
      offset: 0
    }

    {output, frame} = Screen.render(view, {20, 10})
    assert output =~ "\e[36mYou\e[0m"
    assert output =~ "\e[32mComma\e[0m"
    assert output =~ "\e[90mEnter send\e[0m"
    refute output =~ "\e[31m"
    refute output =~ "SECRET"
    assert Enum.all?(frame, &(Text.width(&1) <= 19))
    {diff, ^frame} = Screen.render(view, {20, 10}, frame)
    refute diff =~ "\e[36m"

    {diff, _} =
      Screen.render(%{view | lines: ["You", "Comma", "Comma", "hello"]}, {20, 10}, frame)

    assert diff =~ "\e[3;1H\e[2KYou"
    assert Screen.max_offset(view, {20, 10}) == 0

    tree = {:row, [{4, {:styled, :cyan, "中文ABC"}}, {:fill, {:text, "next"}}]}
    assert Enum.map(CommaTUI.Layout.render(tree, 8, 2), &Text.safe/1) == ["中文next", "ABC     "]
  end

  test "mouse reports survive every packet split and never type their coordinates" do
    for {report, events} <- [
          {"\e[<64;120;12M", [:scroll_up]},
          {"\e[<81;120;12M", [:scroll_down]},
          {"\e[<0;10;2M\e[<0;10;2m", []},
          {"\e[<64;10;2m", []},
          {"\e[M" <> <<96, 42, 34>>, [:scroll_up]},
          {"\e[M" <> <<97, 42, 34>>, [:scroll_down]}
        ],
        split <- 0..byte_size(report) do
      <<first::binary-size(^split), second::binary>> = report
      {:ok, before, decoder} = Input.feed(%Input{}, first)
      {:ok, after_events, decoder} = Input.feed(decoder, second <> "x")
      assert before ++ after_events == events ++ [{:text, "x"}]
      assert decoder.buffer == ""
    end

    assert {:error, :invalid_mouse_report} =
             Input.feed(%Input{}, "\e[<" <> String.duplicate("1", 32))
  end

  test "fragmented Unicode and pasted newlines edit without submitting" do
    {:ok, [], decoder} = Input.feed(%Input{}, <<0xE4>>)
    {:ok, [{:text, "中"}], decoder} = Input.feed(decoder, <<0xB8, 0xAD>>)
    {:ok, [], decoder} = Input.feed(decoder, "\e[20")
    {:ok, [], decoder} = Input.feed(decoder, "0~first\nsecond\e[2")
    {:ok, [{:text, "first\nsecond"}], _} = Input.feed(decoder, "01~")
  end

  test "editing removes whole graphemes and respects the input bound" do
    editor = Editor.update(%Editor{}, {:text, "A👩‍🔬中"})
    editor = editor |> Editor.update(:left) |> Editor.update(:backspace)
    assert editor.text == "A中"
    assert editor.cursor == 1
    assert Editor.update(editor, {:text, String.duplicate("x", 20_000)}) == editor
    assert {:error, :input_too_large} = Input.feed(%Input{}, String.duplicate("x", 70_000))
  end

  test "terminal controls from messages cannot set clipboard or title" do
    hostile = "hello\e]52;c;SECRET\a\e[2Jworld\u009b31m"
    assert Text.safe(hostile) == "helloworld31m"
    refute Text.safe(hostile) =~ "SECRET"
    assert Text.wrap("中文abc", 4) == ["中文", "abc"]
  end

  test "row and column layout clips wide text without moving the next column" do
    tree =
      {:row,
       [
         {4, {:text, "中文ABC"}},
         {:fill, {:column, [{1, {:text, "key"}}, {:fill, {:text, "value"}}]}}
       ]}

    assert CommaTUI.Layout.render(tree, 10, 2) == ["中文key   ", "ABC value "]
  end

  test "resizing and scroll offset preserve a bounded view and mask the code" do
    view = %{
      title: "Comma",
      lines: Enum.map(1..100, &"message #{&1}"),
      editor: Editor.update(%Editor{}, {:text, "123456"}),
      secret: true,
      offset: 10,
      footer: "Code"
    }

    {bytes, frame} = Screen.render(view, {40, 12})
    refute bytes =~ "123456"
    assert length(frame) == 12
    assert Enum.all?(frame, &(Text.width(&1) <= 39))
    {diff, ^frame} = Screen.render(view, {40, 12}, frame)
    refute diff =~ "message"
    {_, narrow} = Screen.render(view, {20, 8}, frame)
    assert length(narrow) == 8
  end

  test "vertical arrows edit earlier lines, including wide characters" do
    editor = Editor.update(%Editor{}, {:text, "alpha\nbeta\ngamma"})
    editor = editor |> Editor.update(:up) |> Editor.update(:up) |> Editor.update({:text, "!"})
    assert editor.text == "alph!a\nbeta\ngamma"
    editor = Editor.update(%Editor{}, {:text, "中A\nabc"}) |> Editor.update(:up)
    assert editor.cursor == 2
    assert Editor.update(editor, :down).cursor == 6
    assert Editor.update(%Editor{}, :up) == %Editor{}
    assert Editor.update(%Editor{}, :down) == %Editor{}
  end

  test "scroll bound matches the rendered viewport after wrapping and multiline editing" do
    view = %{
      title: "Comma",
      lines: Enum.map(1..40, &"line #{&1}"),
      editor: %Editor{},
      offset: 0,
      footer: "Help"
    }

    max_offset = Screen.max_offset(view, {40, 12})
    {_, top} = Screen.render(%{view | offset: max_offset}, {40, 12})
    assert Enum.at(top, 2) == "line 1"
    {_, down} = Screen.render(%{view | offset: max_offset - 1}, {40, 12})
    assert Enum.at(down, 2) == "line 2"
    multiline = %{view | editor: Editor.update(%Editor{}, {:text, "one\ntwo\nthree"})}
    assert Screen.max_offset(multiline, {40, 12}) == max_offset + 2
  end
end
