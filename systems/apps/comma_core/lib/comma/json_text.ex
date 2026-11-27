defmodule Comma.JsonText do
  @moduledoc """
  Bounds text by its JSON-encoded byte size without splitting grapheme clusters,
  and computes shortest-first water-filling byte allowances across entries.
  """

  @doc "JSON-encoded byte length of `text`, excluding outer quotes."
  def encoded_bytes(text) when is_binary(text), do: max(byte_size(Jason.encode!(text)) - 2, 0)

  @doc "Longest prefix of `text` whose JSON-encoded content fits within `budget` bytes."
  def fit(text, budget) when is_binary(text) and is_integer(budget) and budget > 0 do
    if encoded_bytes(text) <= budget do
      text
    else
      # Each grapheme encodes to at least one byte, so at most `budget` fit.
      text
      |> String.slice(0, budget)
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, fn grapheme, {kept, used} ->
        size = encoded_bytes(grapheme)

        if used + size <= budget,
          do: {:cont, {[grapheme | kept], used + size}},
          else: {:halt, {kept, used}}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> IO.iodata_to_binary()
    end
  end

  def fit(_text, _budget), do: ""

  @doc """
  Distributes `budget` encoded bytes across `{key, text}` entries: shortest
  texts take what they need first, leaving the remainder evenly to longer ones.
  """
  def water_fill_allowances([], _budget), do: %{}

  def water_fill_allowances(entries, budget) when is_list(entries) and is_integer(budget) do
    sized =
      entries
      |> Enum.map(fn {key, text} -> {key, encoded_bytes(text)} end)
      |> Enum.sort_by(&elem(&1, 1))

    total = length(sized)

    sized
    |> Enum.with_index()
    |> Enum.reduce({budget, %{}}, fn {{key, size}, index}, {remaining, acc} ->
      allowance = min(size, div(max(remaining, 0), total - index))
      {remaining - allowance, Map.put(acc, key, allowance)}
    end)
    |> elem(1)
  end
end
