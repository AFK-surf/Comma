defmodule SalixVoice.Speech do
  @moduledoc """
  Split Router text into GPT-Live append chunks (docs/messaging-voice.md).

  Each `session.*.append` takes at most 500 tokens. A chunk holds whole
  sentences up to 1,800 characters and about 480 estimated tokens (ASCII text
  counts four characters per token, other characters one each, so CJK text is
  not undercounted). A longer sentence splits at spaces, then hard.
  """

  @max_chars 1_800
  @max_tokens 480

  @doc "Chunks of `text` in order; empty text gives `[]`."
  @spec chunks(String.t()) :: [String.t()]
  def chunks(text) when is_binary(text) do
    text
    |> String.trim()
    |> SalixVoice.Transcript.sentences()
    |> Enum.flat_map(&split_long/1)
    |> Enum.reduce([], fn sentence, acc ->
      case acc do
        [current | rest] ->
          candidate = current <> " " <> sentence
          if fits?(candidate), do: [candidate | rest], else: [sentence | acc]

        [] ->
          [sentence]
      end
    end)
    |> Enum.reverse()
  end

  @doc "Rough token estimate used for the 500-token append limit."
  def estimate_tokens(text) do
    {ascii, other} =
      text
      |> String.to_charlist()
      |> Enum.reduce({0, 0}, fn char, {ascii, other} ->
        if char < 128, do: {ascii + 1, other}, else: {ascii, other + 1}
      end)

    div(ascii + 3, 4) + other
  end

  defp fits?(text), do: String.length(text) <= @max_chars and estimate_tokens(text) <= @max_tokens

  defp split_long(sentence) do
    if fits?(sentence), do: [sentence], else: split_words(String.split(sentence, ~r/\s+/u), [])
  end

  defp split_words([], acc), do: Enum.reverse(acc)

  defp split_words([word | rest], acc) do
    cond do
      not fits?(word) ->
        {head, tail} = hard_split(word)
        split_words([tail | rest], [head | acc])

      acc != [] and fits?(hd(acc) <> " " <> word) ->
        split_words(rest, [hd(acc) <> " " <> word | tl(acc)])

      true ->
        split_words(rest, [word | acc])
    end
  end

  # Take graphemes while the running character and token counts fit.
  defp hard_split(word) do
    {head, tail} = take_fitting(String.graphemes(word), [], 0, 0, 0)
    {Enum.join(head), Enum.join(tail)}
  end

  defp take_fitting([grapheme | rest] = all, acc, chars, ascii, other) do
    {ascii, other} =
      if byte_size(grapheme) == 1, do: {ascii + 1, other}, else: {ascii, other + 1}

    if acc != [] and (chars + 1 > @max_chars or div(ascii + 3, 4) + other > @max_tokens),
      do: {Enum.reverse(acc), all},
      else: take_fitting(rest, [grapheme | acc], chars + 1, ascii, other)
  end

  defp take_fitting([], acc, _chars, _ascii, _other), do: {Enum.reverse(acc), []}
end
