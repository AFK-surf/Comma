defmodule CommaTUI.Layout do
  @moduledoc "Cell-based text, row, column, and scroll viewport primitives. Sizes are fixed or :fill."
  alias CommaTUI.Text

  def render(tree, width, height) when width > 0 and height > 0 do
    tree |> lines(width, height) |> Enum.take(height) |> pad(height)
  end

  def render(_, _, _), do: []

  def wrap_line({:styled, color, text}, width) do
    code =
      case color do
        :gray -> "90"
        :cyan -> "36"
        :green -> "32"
      end

    text |> Text.wrap(width) |> Enum.map(&("\e[#{code}m" <> &1 <> "\e[0m"))
  end

  def wrap_line(text, width), do: Text.wrap(text, width)

  def prepare_viewport(content, width, previous \\ nil) do
    case previous do
      %{source: ^content, width: ^width} ->
        previous

      _ ->
        %{
          source: content,
          width: width,
          rows: content |> Enum.flat_map(&wrap_line(&1, width)) |> List.to_tuple()
        }
    end
  end

  defp lines({:text, text}, width, _height), do: Text.wrap(text, width)
  defp lines({:styled, _, _} = text, width, _height), do: wrap_line(text, width)

  defp lines({:column, children}, width, height) do
    children
    |> allocate(height)
    |> Enum.flat_map(fn {size, child} -> render(child, width, size) end)
  end

  defp lines({:row, children}, width, height) do
    children
    |> allocate(width)
    |> Enum.map(fn {size, child} ->
      render(child, size, height)
      |> Enum.map(fn line -> line <> String.duplicate(" ", max(size - Text.width(line), 0)) end)
      |> pad(height)
    end)
    |> Enum.zip_with(&Enum.join/1)
  end

  defp lines({:viewport, offset, %{rows: rows}}, _width, height) do
    count = tuple_size(rows)
    offset = min(max(offset, 0), max(count - height, 0))
    first = max(count - height - offset, 0)
    for index <- first..(min(first + height, count) - 1)//1, do: elem(rows, index)
  end

  defp lines({:viewport, offset, content}, width, height),
    do: lines({:viewport, offset, prepare_viewport(content, width)}, width, height)

  defp allocate(total_children, total) do
    fixed =
      Enum.reduce(total_children, 0, fn
        {:fill, _}, n -> n
        {size, _}, n -> n + max(size, 0)
      end)

    flexible = Enum.count(total_children, &(elem(&1, 0) == :fill))
    remaining = max(total - fixed, 0)

    {result, _, _, _} =
      Enum.reduce(total_children, {[], total, remaining, flexible}, fn {size, child},
                                                                       {result, left, spare,
                                                                        slots} ->
        requested =
          if size == :fill, do: div(spare + max(slots - 1, 0), max(slots, 1)), else: max(size, 0)

        granted = min(requested, left)

        {[{granted, child} | result], left - granted,
         if(size == :fill, do: spare - granted, else: spare),
         if(size == :fill, do: slots - 1, else: slots)}
      end)

    Enum.reverse(result)
  end

  defp pad(lines, height), do: lines ++ List.duplicate("", max(height - length(lines), 0))
end
