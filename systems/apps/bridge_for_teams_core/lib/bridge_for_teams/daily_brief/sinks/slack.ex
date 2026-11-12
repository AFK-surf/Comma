defmodule BridgeForTeams.DailyBrief.Sinks.Slack do
  @moduledoc """
  Draws a brief as Slack blocks: a title, then the text the model wrote,
  already Slack mrkdwn, in sections Slack accepts. The team brief is laid out
  by its parts (`render_team/3`).
  """

  # Slack refuses a section over 3,000 characters, and with it the brief.
  @section_chars 2_900
  # Slack refuses a message over 50 blocks.
  @max_text_sections 40
  @summary_chars 200
  # Slack refuses a link over 3,000 characters in a block.
  @max_link_url 2_000

  @spec render(String.t(), String.t()) :: %{text: String.t(), blocks: [map()]}
  def render(title, text) do
    %{
      text: summary(title, text),
      blocks:
        [%{"type" => "header", "text" => plain(title)}] ++
          Enum.map(chunks(text), &%{"type" => "section", "text" => mrkdwn(&1)})
    }
  end

  @doc """
  A member's brief laid out by its parts: the title, the opening, then each
  part under its heading, one block per numbered or bulleted entry. An
  entry keeps its title, with message previews and native-open links in
  small print underneath.
  """
  @spec render_personal(String.t(), String.t()) :: %{text: String.t(), blocks: [map()]}
  def render_personal(title, text, footer \\ nil) do
    {opening, rest} =
      text
      |> String.split(~r/\n{2,}/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.split(1)

    blocks =
      Enum.flat_map(opening, &personal_part/1) ++
        if(rest == [], do: [], else: [%{"type" => "divider"}]) ++
        Enum.flat_map(rest, &personal_part/1)

    # The footer is product text, not the model's: it always keeps its place.
    footer =
      if is_binary(footer),
        do: [%{"type" => "context", "elements" => [mrkdwn(footer)]}],
        else: []

    %{
      text: summary(title, text),
      blocks:
        Enum.take([%{"type" => "header", "text" => plain(title)} | blocks], 49 - length(footer)) ++
          footer
    }
  end

  @entry ~r/^(?:\d+[.、)]|•)\s+/u

  defp personal_part(paragraph) do
    {heading, lines} =
      case String.split(paragraph, "\n") do
        [first | rest] -> if heading?(first), do: {first, rest}, else: {nil, [first | rest]}
      end

    {entries, others} = Enum.split_with(lines, &Regex.match?(@entry, &1))

    head = if heading, do: [%{"type" => "section", "text" => mrkdwn(heading)}], else: []

    rest = Enum.reject(others, &(String.trim(&1) == ""))

    head ++
      Enum.flat_map(if(rest == [], do: [], else: [Enum.join(rest, "\n")]), &sourced/1) ++
      Enum.flat_map(entries, &sourced/1)
  end

  @doc """
  The team brief laid out by its parts: the title and what it read, the
  opening story, then one section per line of work, what needs everyone, and
  the small items in small print. Sources are drawn as in a member's brief.
  """
  @spec render_team(String.t(), String.t(), String.t() | nil) :: %{
          text: String.t(),
          blocks: [map()]
        }
  def render_team(title, text, read \\ nil) do
    paragraphs =
      text
      |> String.split(~r/\n{2,}/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or heading?(&1)))

    {opening, rest} = Enum.split(paragraphs, 1)

    blocks =
      [%{"type" => "header", "text" => plain(title)}] ++
        if(read, do: [context(read)], else: []) ++
        Enum.flat_map(opening, &sourced/1) ++
        if(rest == [], do: [], else: [%{"type" => "divider"}]) ++
        Enum.flat_map(rest, &part/1)

    %{text: summary(title, text), blocks: Enum.take(blocks, 49)}
  end

  @attention ~r/^需要大家注意[:：]\s*/u
  @aside ~r/^顺带一提[:：]\s*/u

  defp part(paragraph) do
    cond do
      Regex.match?(@attention, paragraph) ->
        sourced(":warning: *需要大家注意*\n" <> Regex.replace(@attention, paragraph, ""))

      Regex.match?(@aside, paragraph) ->
        [context("顺带一提：" <> Regex.replace(@aside, paragraph, ""))]

      true ->
        line(paragraph)
    end
  end

  # A line of work: "*name*：text" becomes its name over its text.
  defp line(paragraph) do
    case Regex.run(~r/^\x{200B}?\*([^*\n]+)\*\x{200B}?[:：]\s*(.+)$/us, paragraph,
           capture: :all_but_first
         ) do
      [name, body] -> sourced("*#{name}*\n" <> body)
      nil -> sourced(paragraph)
    end
  end

  # A source link as Compose writes it: "<url|#channel · 10/27 22:14>".
  @source ~r/\s*<((?:https?|slack):\/\/[^|>]+)\|(#[^|>]+ · \d{2}\/\d{2} \d{2}:\d{2})>(?: · <(slack:\/\/[^|>]+)\|打开>)?/u
  # Keep both source actions together in the context line, including when
  # the title contains a mention or another link.
  defp sourced(text) do
    sources =
      for [whole, url, label | rest] <- Regex.scan(@source, text),
          open = List.first(rest, ""),
          byte_size(url) <= @max_link_url,
          byte_size(open) <= @max_link_url,
          do: {whole, url, label, open}

    body =
      Enum.reduce(sources, text, fn {whole, _url, _label, _open}, body ->
        String.replace(body, whole, "")
      end)

    case sources do
      [] ->
        section_blocks(text)

      sources ->
        small =
          Enum.map_join(sources, "  /  ", fn {_whole, url, label, open} ->
            "<#{url}|#{label}>" <> if(open == "", do: "", else: " · <#{open}|打开>")
          end)

        section_blocks(String.trim(body)) ++ [context(small)]
    end
  end

  defp heading?(paragraph), do: Regex.match?(~r/^\x{200B}?\*[^*\n]+\*\x{200B}?$/u, paragraph)

  defp section_blocks(text),
    do: Enum.map(chunks(text), &%{"type" => "section", "text" => mrkdwn(&1)})

  defp context(text), do: %{"type" => "context", "elements" => [mrkdwn(cut(text))]}

  defp cut(text), do: String.slice(text, 0, @section_chars)

  # The notification shows the first line, without its marks.
  defp summary(title, text) do
    first =
      text
      |> String.split("\n", trim: true)
      |> List.first("")
      |> then(&Regex.replace(@source, &1, ""))
      |> then(&Regex.replace(~r/<((?:https?|slack):[^|>]+)\|([^>]*)>/, &1, "\\2"))
      |> String.replace(["*", "​"], "")
      |> String.slice(0, @summary_chars)

    if first == "", do: title, else: first
  end

  # Whole paragraphs per section where they fit; a longer one is cut.
  defp chunks(text) do
    text
    |> String.split(~r/\n{2,}/)
    |> Enum.flat_map(fn paragraph ->
      paragraph
      |> String.graphemes()
      |> Enum.chunk_every(@section_chars)
      |> Enum.map(&Enum.join/1)
    end)
    |> Enum.reduce([], fn
      paragraph, [last | rest] ->
        if String.length(last) + 2 + String.length(paragraph) <= @section_chars,
          do: [last <> "\n\n" <> paragraph | rest],
          else: [paragraph, last | rest]

      paragraph, [] ->
        [paragraph]
    end)
    |> Enum.reverse()
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.take(@max_text_sections)
  end

  defp mrkdwn(text), do: %{"type" => "mrkdwn", "text" => text}
  defp plain(text), do: %{"type" => "plain_text", "text" => text, "emoji" => true}
end
