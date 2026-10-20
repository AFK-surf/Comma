defmodule SalixMeetNative.Transcript do
  @moduledoc false

  @spec build([map()]) :: String.t()
  def build(captions) do
    {order, sections} =
      Enum.reduce(captions, {[], %{}}, fn caption, {order, sections} ->
        if caption["text"] in [nil, ""] do
          {order, sections}
        else
          label = source_label(caption["source"])
          order = if Map.has_key?(sections, label), do: order, else: order ++ [label]
          {order, Map.update(sections, label, [caption], &(&1 ++ [caption]))}
        end
      end)

    sections =
      Map.new(sections, fn {label, list} ->
        {label, Enum.sort_by(list, &{sort_ms(&1), &1["segment_id"] || ""})}
      end)

    case order do
      [] ->
        ""

      [label] ->
        lines(sections[label])

      _ ->
        Enum.map_join(order, "\n", fn label ->
          "## #{blank_or(label, "Unlabeled")}\n" <> lines(sections[label])
        end)
    end
  end

  defp lines(captions) do
    Enum.map_join(captions, fn c ->
      source = source_label(c["source"])
      ts = c["timestamp"] || 0

      prefix =
        cond do
          ts > 0 and source != "" -> "[#{clock(ts)}@#{source}] "
          ts > 0 -> "[#{clock(ts)}] "
          source != "" -> "[#{source}] "
          true -> ""
        end

      speaker = if c["speaker"] in [nil, ""], do: "", else: c["speaker"] <> ": "
      prefix <> speaker <> c["text"] <> "\n"
    end)
  end

  defp sort_ms(caption) do
    case caption["timestamp_ms"] do
      ms when is_integer(ms) and ms != 0 -> ms
      _ -> (caption["timestamp"] || 0) * 1000
    end
  end

  defp clock(unix), do: unix |> DateTime.from_unix!() |> Calendar.strftime("%H:%M:%S")

  @spec source_label(String.t() | nil) :: String.t()
  def source_label(source) do
    case String.trim(source || "") do
      "" ->
        ""

      s ->
        if String.downcase(s) in ["captions", "google", "google captions"],
          do: "Google",
          else: label(s)
    end
  end

  defp label(s), do: String.upcase(String.first(s)) <> String.slice(s, 1..-1//1)

  defp blank_or("", fallback), do: fallback
  defp blank_or(value, _fallback), do: value
end
