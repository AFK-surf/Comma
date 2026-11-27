defmodule BridgeForTeams.DailyBrief.Sinks.LarkSuite do
  @moduledoc """
  Draws a brief as a Feishu or Lark interactive card, shared by
  `Sinks.Feishu` and `Sinks.Lark`: a header with the title, the text in
  `markdown` elements split by `hr`, and the sources and product notes in
  `note` elements.

  `Compose` writes a brief once, in the Slack-style markup it checks
  (`<url|label>` links, `*bold*`, `<@ou_…>` people, `&lt;`-escaped text);
  this module turns it into card Markdown: `[label](url)`, `**bold**`, and
  `<at id=ou_…></at>`, which the app shows as the person's current name.
  """

  # A card is refused over 30 KB; elements stay well under it.
  @element_chars 2_800
  @max_elements 45
  @summary_chars 200

  @doc "A member's brief: the opening, then each part, sources in small print."
  @spec render_personal(String.t(), String.t(), String.t() | nil) :: %{
          text: String.t(),
          card: map()
        }
  def render_personal(title, text, footer \\ nil) do
    {opening, rest} = text |> paragraphs() |> Enum.split(1)

    elements =
      Enum.flat_map(opening, &sourced/1) ++
        if(rest == [], do: [], else: [hr()]) ++
        Enum.flat_map(rest, &sourced/1)

    footer = if is_binary(footer), do: [note(footer)], else: []

    %{
      text: summary(title, text),
      card: card(title, Enum.take(elements, @max_elements - length(footer)) ++ footer)
    }
  end

  @doc """
  The team brief: what it read, the opening story, then one part per line of
  work, what needs everyone, and the small items in small print.
  """
  @spec render_team(String.t(), String.t(), String.t() | nil) :: %{text: String.t(), card: map()}
  def render_team(title, text, read \\ nil) do
    {opening, rest} =
      text
      |> paragraphs()
      |> Enum.reject(&heading?/1)
      |> Enum.split(1)

    elements =
      if(read, do: [note(read)], else: []) ++
        Enum.flat_map(opening, &sourced/1) ++
        if(rest == [], do: [], else: [hr()]) ++
        Enum.flat_map(rest, &part/1)

    %{text: summary(title, text), card: card(title, Enum.take(elements, @max_elements))}
  end

  @attention ~r/^需要大家注意[:：]\s*/u
  @aside ~r/^顺带一提[:：]\s*/u

  defp part(paragraph) do
    cond do
      Regex.match?(@attention, paragraph) ->
        sourced("*需要大家注意*\n" <> Regex.replace(@attention, paragraph, ""))

      Regex.match?(@aside, paragraph) ->
        [note("顺带一提：" <> Regex.replace(@aside, paragraph, ""))]

      true ->
        sourced(paragraph)
    end
  end

  # A source link as Compose writes it: "<url|群名 · 10/27 22:14>".
  @source ~r/\s*<(https:\/\/[^|>\s]+)\|([^|>]+ · \d{2}\/\d{2} \d{2}:\d{2})>/u

  defp sourced(paragraph) do
    sources = Regex.scan(@source, paragraph)

    body =
      Enum.reduce(sources, paragraph, fn [whole | _], body -> String.replace(body, whole, "") end)

    case sources do
      [] ->
        markdown_elements(paragraph)

      sources ->
        small =
          Enum.map_join(sources, "  /  ", fn [_whole, url, label] -> "<#{url}|#{label}>" end)

        markdown_elements(String.trim(body)) ++ [note(small)]
    end
  end

  defp card(title, elements) do
    %{
      "config" => %{"wide_screen_mode" => true},
      "header" => %{"title" => %{"tag" => "plain_text", "content" => title}},
      "elements" => elements
    }
  end

  defp markdown_elements(text) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(@element_chars)
    |> Enum.map(&Enum.join/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(&%{"tag" => "markdown", "content" => markdown(&1)})
  end

  defp note(text),
    do: %{
      "tag" => "note",
      "elements" => [
        %{"tag" => "lark_md", "content" => text |> String.slice(0, @element_chars) |> markdown()}
      ]
    }

  defp hr, do: %{"tag" => "hr"}

  @doc false
  # Slack-style brief markup as card Markdown.
  def markdown(text) do
    # Compose sets a zero-width space beside bold next to Chinese text; the
    # bold is read with it, then it goes.
    text
    |> then(&Regex.replace(~r/(?<![*\w])\*([^*\n]+)\*(?![*\w])/u, &1, "**\\1**"))
    |> String.replace("\u200B", "")
    |> then(&Regex.replace(~r/<@(ou_[A-Za-z0-9_-]{2,64})>/, &1, "<at id=\\1></at>"))
    |> then(&Regex.replace(~r/<((?:https?|mailto):[^|>\s]+)\|([^>]+)>/u, &1, "[\\2](\\1)"))
    |> then(&Regex.replace(~r/<((?:https?|mailto):[^|>\s]+)>/u, &1, "\\1"))
  end

  defp paragraphs(text) do
    text
    |> String.split(~r/\n{2,}/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp heading?(paragraph), do: Regex.match?(~r/^\x{200B}?\*[^*\n]+\*\x{200B}?$/u, paragraph)

  # The notification shows the first line, without its marks.
  defp summary(title, text) do
    first =
      text
      |> String.split("\n", trim: true)
      |> List.first("")
      |> then(&Regex.replace(@source, &1, ""))
      |> then(&Regex.replace(~r/<((?:https?|mailto):[^|>]+)\|([^>]*)>/, &1, "\\2"))
      |> then(&Regex.replace(~r/<@ou_[A-Za-z0-9_-]+>/, &1, ""))
      |> String.replace(["*", "\u200B"], "")
      |> String.slice(0, @summary_chars)

    if first == "", do: title, else: first
  end
end
