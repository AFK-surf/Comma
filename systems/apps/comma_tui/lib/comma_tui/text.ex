defmodule CommaTUI.Text do
  @moduledoc "Safe terminal text and cell-aware wrapping."
  def safe(text) do
    text = if String.valid?(text), do: text, else: "[invalid text]"

    text
    |> String.replace(~r/\e\][^\a\e]*(?:\a|\e\\|$)/u, "")
    |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/u, "")
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F-\x9F]/u, "")
    |> String.replace("\t", "    ")
  end

  def width(text), do: max(Ucwidth.width(safe(text)), 0)

  def wrap(text, columns) do
    text
    |> safe()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      {lines, current, _} =
        Enum.reduce(String.graphemes(line), {[], "", 0}, fn g, {lines, current, used} ->
          # The input was sanitized once before splitting into graphemes.
          n = max(Ucwidth.width(g), 0)

          cond do
            n > columns -> {lines, current, used}
            used + n > columns -> {[current | lines], g, n}
            true -> {lines, current <> g, used + n}
          end
        end)

      Enum.reverse([current | lines])
    end)
  end

  def clip(text, columns), do: text |> wrap(columns) |> hd()
end
