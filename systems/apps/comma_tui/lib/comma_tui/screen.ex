defmodule CommaTUI.Screen do
  @moduledoc "Bounded vertical layout and changed-row ANSI renderer."
  alias CommaTUI.Text
  def enter, do: "\e[?1049h\e[?2004h\e[?1000h\e[?1006h\e[?25l\e[2J"
  def leave, do: "\e[0m\e[?1006l\e[?1000l\e[?2004l\e[?25h\e[?1049l"
  def size(width, height), do: {min(max(width, 20), 240), min(max(height, 8), 100)}

  def max_offset(view, {width, height}) do
    {_, _, _, _, available} = editor_layout(view, width - 1, height)
    count = tuple_size(viewport(view, width - 1).rows)
    max(count - available, 0)
  end

  def render(view, {width, height}, previous \\ []) do
    # Leave the last column empty to avoid terminal autowrap.
    columns = width - 1

    {editor_lines, cursor_lines, cursor_row, first_editor_row, available} =
      editor_layout(view, columns, height)

    tree =
      {:column,
       [
         {1, {:text, Text.clip(view.title, columns)}},
         {1, {:text, String.duplicate("─", columns)}},
         {available, {:viewport, view[:offset] || 0, viewport(view, columns)}},
         {1, {:text, String.duplicate("─", columns)}},
         {length(editor_lines), {:text, Enum.join(editor_lines, "\n")}},
         {1, {:styled, :gray, Text.clip(view.footer, columns)}}
       ]}

    frame = CommaTUI.Layout.render(tree, columns, height)

    output =
      frame
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, row} ->
        if Enum.at(previous, row - 1) == line, do: [], else: ["\e[#{row};1H\e[2K", line]
      end)

    cursor =
      "\e[#{available + 4 + cursor_row - first_editor_row};#{min(Text.width(List.last(cursor_lines)) + 1, width)}H\e[?25h"

    {IO.iodata_to_binary([output, cursor]), frame}
  end

  defp viewport(view, columns),
    do: CommaTUI.Layout.prepare_viewport(view.lines, columns, view[:viewport])

  defp editor_layout(view, columns, height) do
    input =
      if view[:secret],
        do: String.duplicate("•", String.length(view.editor.text)),
        else: view.editor.text

    all_editor_lines = Text.wrap("> " <> input, columns)
    {before_cursor, _} = CommaTUI.Editor.split(view.editor)

    before_cursor =
      if view[:secret],
        do: String.duplicate("•", String.length(before_cursor)),
        else: before_cursor

    cursor_lines = Text.wrap("> " <> before_cursor, columns)
    cursor_row = length(cursor_lines) - 1
    first_editor_row = max(cursor_row - min(5, height - 5) + 1, 0)
    editor_lines = Enum.slice(all_editor_lines, first_editor_row, min(5, height - 5))
    available = max(height - length(editor_lines) - 4, 1)

    {editor_lines, cursor_lines, cursor_row, first_editor_row, available}
  end
end
