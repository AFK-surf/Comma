defmodule Salix.Bindings.MeetingSpeakerAlignment do
  @moduledoc """
  Gives each post-meeting ASR line the speaker of the live caption it matches.

  Live captions name each speaker from that participant's own audio track.
  ASR of the mixed recording cannot tell speakers apart: it labels lines
  `Speaker N`, `Unknown`, or a name it heard in the speech. The recording also
  starts before the bot is admitted, so the offset between audio time and
  caption time is measured from lines whose text matches, not taken from the
  join time.

  A line keeps its text and timestamp. Its label becomes the matched caption's
  speaker, or `Unknown` when no caption matches. Alignment is refused when too
  few lines match, so a wrong offset never relabels a whole meeting.
  """

  @window_seconds 30
  @min_score 0.35
  @anchor_score 0.6
  @anchor_min_graphemes 6
  @max_anchor_lines 200
  @min_anchors 3
  @cluster_seconds 20
  @min_matched_share 0.5
  @line ~r/\A(\[(?:(\d+):)?(\d{1,2}):([0-5]\d)\])\s*([^:：\n]{1,80})[:：]\s?(.*)\z/u

  @doc """
  Relabel `asr` lines with caption speakers. `captions` are runtime caption
  maps with `speaker`, `text` and a Unix-second `timestamp`.
  """
  @spec align(String.t(), [map()]) :: {:ok, String.t()} | :unaligned
  def align(asr, captions) when is_binary(asr) and is_list(captions) do
    captions = indexed_captions(captions)
    lines = asr |> String.split("\n") |> Enum.map(&parse_line/1)
    timed = for {:timed, line} <- lines, do: line

    with true <- captions != [] and timed != [],
         {:ok, offset} <- offset(timed, captions) do
      relabelled = Enum.map(lines, &relabel(&1, captions, offset))
      substantive = for {:timed, line} <- lines, MapSet.size(line.grams) > 1, do: line
      matched = Enum.count(relabelled, &match?({:matched, _}, &1))

      if substantive != [] and matched / length(substantive) >= @min_matched_share do
        {:ok, relabelled |> Enum.map(&elem(&1, 1)) |> Enum.join("\n")}
      else
        :unaligned
      end
    else
      _ -> :unaligned
    end
  end

  def align(_asr, _captions), do: :unaligned

  defp indexed_captions(captions) do
    for caption <- captions,
        speaker = trim(field(caption, "speaker")),
        text = trim(field(caption, "text")),
        at = timestamp(caption),
        speaker != "" and text != "" and at > 0 do
      %{at: at, speaker: speaker, grams: grams(text)}
    end
  end

  defp parse_line(line) do
    case Regex.run(@line, line) do
      [_, stamp, hours, minutes, seconds, _label, text] ->
        at =
          String.to_integer(if hours == "", do: "0", else: hours) * 3600 +
            String.to_integer(minutes) * 60 + String.to_integer(seconds)

        {:timed, %{stamp: stamp, at: at, text: text, grams: grams(text)}}

      _ ->
        {:other, line}
    end
  end

  # Lines that match one caption closely, wherever it is, vote for the
  # difference between caption time and audio time. Short repeated phrases
  # also match elsewhere, so the offset is the median of the densest
  # 20-second cluster of votes, not of all of them.
  defp offset(timed, captions) do
    deltas =
      timed
      |> Enum.filter(&(MapSet.size(&1.grams) >= @anchor_min_graphemes - 1))
      |> Enum.take(@max_anchor_lines)
      |> Enum.flat_map(fn line ->
        case best(line, captions) do
          {score, caption} when score >= @anchor_score -> [caption.at - line.at]
          _ -> []
        end
      end)
      |> Enum.sort()

    case densest(deltas) do
      cluster when length(cluster) >= @min_anchors ->
        {:ok, Enum.at(cluster, div(length(cluster), 2))}

      _ ->
        :error
    end
  end

  # At most 200 votes, so the quadratic scan stays small.
  defp densest([]), do: []

  defp densest(sorted) do
    {start, count} =
      sorted
      |> Enum.with_index()
      |> Enum.map(fn {low, index} ->
        {index, sorted |> Enum.drop(index) |> Enum.count(&(&1 - low <= @cluster_seconds))}
      end)
      |> Enum.max_by(&elem(&1, 1))

    Enum.slice(sorted, start, count)
  end

  defp relabel({:other, line}, _captions, _offset), do: {:other, line}

  defp relabel({:timed, line}, captions, offset) do
    nearby = Enum.filter(captions, &(abs(&1.at - offset - line.at) <= @window_seconds))

    case best(line, nearby) do
      {score, caption} when score >= @min_score ->
        {:matched, "#{line.stamp} #{caption.speaker}: #{line.text}"}

      _ ->
        {:unmatched, "#{line.stamp} Unknown: #{line.text}"}
    end
  end

  defp best(line, captions) do
    Enum.reduce(captions, {0.0, nil}, fn caption, {best_score, _} = acc ->
      score = score(line.grams, caption.grams)
      if score > best_score, do: {score, caption}, else: acc
    end)
  end

  defp score(a, b) do
    smaller = min(MapSet.size(a), MapSet.size(b))

    if smaller == 0,
      do: 0.0,
      else: MapSet.size(MapSet.intersection(a, b)) / smaller
  end

  # Character bigrams of the letters and digits, so CJK and Latin text compare
  # the same way and punctuation or spacing differences do not matter.
  defp grams(text) do
    text
    |> String.downcase()
    |> then(&Regex.replace(~r/[^\p{L}\p{N}]/u, &1, ""))
    |> String.graphemes()
    |> Enum.chunk_every(2, 1, :discard)
    |> MapSet.new()
  end

  defp field(map, key) when is_map(map), do: map[key] || map[String.to_atom(key)]
  defp field(_map, _key), do: nil

  defp timestamp(caption) do
    case field(caption, "timestamp") do
      n when is_integer(n) -> n
      n when is_float(n) -> trunc(n)
      _ -> 0
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
