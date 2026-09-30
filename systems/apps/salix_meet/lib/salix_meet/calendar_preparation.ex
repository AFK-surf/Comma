defmodule SalixMeet.CalendarPreparation do
  @moduledoc "Owns only the Comma preparation block inside a calendar description."

  @block_begin "<!-- comma:meeting-preparation:begin -->"
  @block_end "<!-- comma:meeting-preparation:end -->"
  @max_report_bytes 16_000
  @max_description_bytes 128_000

  @doc "Preserve all bytes outside the single Comma block; reject ambiguous boundaries."
  def merge(description, report)
      when is_binary(description) and is_binary(report) and
             byte_size(description) <= @max_description_bytes and
             byte_size(report) <= @max_report_bytes do
    with true <- String.trim(report) != "",
         {:ok, before, after_block} <- split(description),
         {:ok, html} <-
           MDEx.to_html(report, render: [escape: true, hardbreaks: true]) do
      block =
        @block_begin <>
          "<h3>Meeting preparation</h3>" <> html <> @block_end

      {:ok, before <> block <> after_block}
    else
      false -> {:error, :empty_meeting_preparation}
      {:error, _} = error -> error
    end
  end

  def merge(nil, report), do: merge("", report)
  def merge(_description, _report), do: {:error, :invalid_meeting_preparation}

  @doc "Remove the managed block when comparing human-authored calendar facts."
  def human_description(description) when is_binary(description) do
    case split(description) do
      {:ok, before, after_block} -> {:ok, before <> after_block}
      {:error, _} = error -> error
    end
  end

  def human_description(nil), do: {:ok, ""}
  def human_description(_description), do: {:error, :invalid_calendar_description}

  defp split(description) do
    case {:binary.matches(description, @block_begin), :binary.matches(description, @block_end)} do
      {[], []} ->
        {:ok, description, ""}

      {[{start, _}], [{finish, size}]} when finish > start ->
        tail = finish + size

        {:ok, binary_part(description, 0, start),
         binary_part(description, tail, byte_size(description) - tail)}

      _ ->
        {:error, :ambiguous_calendar_preparation_block}
    end
  end
end
