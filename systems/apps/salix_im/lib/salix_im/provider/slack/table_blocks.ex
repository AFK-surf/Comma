defmodule SalixIM.Provider.Slack.TableBlocks do
  @moduledoc """
  Renders Slack `table` blocks as bounded Markdown tables.

  A table pasted or composed in Slack is not in the message's `text`: Slack
  carries it as a `table` block inside an attachment (`text` holds only the
  words around it, and the attachment's `fallback` is a placeholder). Agents
  read `text`, so without this projection a message that is mostly a table
  reaches them as its caption alone.

  Tables are read from the message's own `blocks` and from its non-unfurl
  attachments. A message unfurl is someone else's message and stays limited to
  the bounded coordinates `MessageReferences` projects.
  """

  alias SalixIM.Provider.Util

  @max_tables 3
  @max_rows 100
  @max_columns 20
  @max_table_bytes 4_000

  @spec from_message(map()) :: [String.t()]
  def from_message(message) when is_map(message) do
    attachment_blocks =
      message["attachments"]
      |> maps()
      |> Enum.reject(&(&1["is_msg_unfurl"] == true))
      |> Enum.flat_map(&maps(&1["blocks"]))

    (maps(message["blocks"]) ++ attachment_blocks)
    |> Enum.filter(&(&1["type"] == "table"))
    |> Enum.take(@max_tables)
    |> Enum.map(&render/1)
    |> Enum.reject(&(&1 == ""))
  end

  def from_message(_message), do: []

  @doc "The message's tables as text to append after its `text`, or `\"\"`."
  @spec content_suffix(map()) :: String.t()
  def content_suffix(message) do
    case from_message(message) do
      [] -> ""
      tables -> "\n\n" <> Enum.join(tables, "\n\n")
    end
  end

  defp render(%{"rows" => rows}) when is_list(rows) do
    rows =
      rows
      |> Enum.filter(&is_list/1)
      |> Enum.take(@max_rows)
      |> Enum.map(fn row -> row |> Enum.take(@max_columns) |> Enum.map(&cell_text/1) end)

    case rows do
      [] ->
        ""

      [header | body] ->
        width = rows |> Enum.map(&length/1) |> Enum.max()
        separator = List.duplicate("---", width)

        [header, separator | body]
        |> Enum.map(&row_line(&1, width))
        |> Enum.join("\n")
        |> Util.truncate_utf8(@max_table_bytes)
    end
  end

  defp render(_block), do: ""

  defp row_line(cells, width) do
    cells = cells ++ List.duplicate("", width - length(cells))
    "| " <> Enum.join(cells, " | ") <> " |"
  end

  defp cell_text(%{"type" => "raw_text", "text" => text}) when is_binary(text), do: clean(text)
  defp cell_text(%{"type" => "rich_text"} = cell), do: cell |> inline() |> clean()
  defp cell_text(_cell), do: ""

  # The rich-text elements that stand for something are written the way Slack
  # writes them in `text`, so a mention reads the same in a cell as in prose.
  defp inline(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp inline(%{"type" => "user", "user_id" => id}) when is_binary(id), do: "<@#{id}>"
  defp inline(%{"type" => "channel", "channel_id" => id}) when is_binary(id), do: "<##{id}>"

  defp inline(%{"type" => "usergroup", "usergroup_id" => id}) when is_binary(id),
    do: "<!subteam^#{id}>"

  defp inline(%{"type" => "broadcast", "range" => range}) when is_binary(range),
    do: "<!#{range}>"

  defp inline(%{"type" => "emoji", "name" => name}) when is_binary(name), do: ":#{name}:"

  defp inline(%{"type" => "link", "url" => url} = link) when is_binary(url) do
    case link["text"] do
      text when is_binary(text) and text != "" and text != url -> "[#{text}](#{url})"
      _text -> url
    end
  end

  defp inline(%{"elements" => elements}) when is_list(elements),
    do: Enum.map_join(elements, &inline/1)

  defp inline(_element), do: ""

  # One cell is one Markdown table cell: no line breaks, no bare pipes.
  defp clean(text) do
    text
    |> String.replace(~r/\s*\R\s*/u, " ")
    |> String.replace("|", "\\|")
    |> String.trim()
  end

  defp maps(values) when is_list(values), do: Enum.filter(values, &is_map/1)
  defp maps(_values), do: []
end
