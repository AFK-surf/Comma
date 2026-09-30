defmodule CommaTUI.Editor do
  @moduledoc "Grapheme-aware bounded multiline composer."
  defstruct text: "", cursor: 0
  @limit 16_384
  def update(editor, {:text, value}) do
    value = CommaTUI.Text.safe(value)

    if byte_size(editor.text) + byte_size(value) <= @limit do
      {left, right} = split(editor)
      text = left <> value <> right
      %{editor | text: text, cursor: String.length(left <> value)}
    else
      editor
    end
  end

  def update(editor, direction) when direction in [:up, :down] do
    lines = String.split(editor.text, "\n")
    {left, _} = split(editor)
    before = String.split(left, "\n")
    row = length(before) - 1
    column = CommaTUI.Text.width(List.last(before))
    target = row + if(direction == :up, do: -1, else: 1)

    if target < 0 or target >= length(lines) do
      editor
    else
      line = Enum.at(lines, target)

      {count, _} =
        line
        |> String.graphemes()
        |> Enum.reduce_while({0, 0}, fn grapheme, {count, width} ->
          next = width + CommaTUI.Text.width(grapheme)
          if next <= column, do: {:cont, {count + 1, next}}, else: {:halt, {count, width}}
        end)

      start = lines |> Enum.take(target) |> Enum.reduce(0, &(String.length(&1) + 1 + &2))
      %{editor | cursor: start + count}
    end
  end

  def update(editor, :newline), do: update(editor, {:text, "\n"})
  def update(editor, :left), do: %{editor | cursor: max(0, editor.cursor - 1)}

  def update(editor, :right),
    do: %{editor | cursor: min(String.length(editor.text), editor.cursor + 1)}

  def update(editor, :home), do: %{editor | cursor: 0}
  def update(editor, :end), do: %{editor | cursor: String.length(editor.text)}
  def update(%{cursor: 0} = editor, :backspace), do: editor

  def update(editor, :backspace) do
    {left, right} = split(editor)
    %{editor | text: String.slice(left, 0, editor.cursor - 1) <> right, cursor: editor.cursor - 1}
  end

  def update(editor, :delete) do
    {left, right} = split(editor)
    %{editor | text: left <> String.slice(right, 1..-1//1)}
  end

  def update(editor, _), do: editor

  def split(editor),
    do:
      {String.slice(editor.text, 0, editor.cursor),
       String.slice(editor.text, editor.cursor..-1//1)}
end
