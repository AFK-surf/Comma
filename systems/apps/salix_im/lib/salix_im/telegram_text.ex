defmodule SalixIM.TelegramText do
  @moduledoc """
  Pure Telegram text adapter. Parses CommonMark with the existing MDEx library,
  then emits an allowlisted, non-interactive subset of Telegram HTML. It never
  uploads Markdown images, activates raw HTML, splits messages, or performs I/O.
  Provider owns authorization, delivery and the one-rejection fallback policy.
  """

  @extensions [table: true, strikethrough: true, tasklist: true]
  @source_bytes 262_144
  @block_nodes [
    MDEx.Paragraph,
    MDEx.Heading,
    MDEx.CodeBlock,
    MDEx.List,
    MDEx.ListItem,
    MDEx.TaskItem,
    MDEx.BlockQuote,
    MDEx.Table,
    MDEx.TableRow,
    MDEx.ThematicBreak,
    MDEx.HtmlBlock
  ]

  def message(source, format \\ "markdown") do
    with {:ok, rendered} <- prepare(source, format, :message),
         :ok <- validate_length(caption_text(rendered.html), 4096, false) do
      if format == "plain" do
        {:ok, %{method: "sendMessage", fields: %{"text" => source}, plain: source}}
      else
        {:ok,
         %{
           method: "sendMessage",
           fields: %{"text" => rendered.html, "parse_mode" => "HTML"},
           plain: rendered.plain
         }}
      end
    end
  end

  def caption(source, format \\ "markdown") do
    with {:ok, rendered} <- prepare(source, format, :caption),
         :ok <- validate_length(caption_text(rendered.html), 1024, true) do
      fields =
        if format == "plain",
          do: %{caption: source},
          else: %{caption: rendered.html, parse_mode: "HTML"}

      {:ok, %{fields: fields, plain: rendered.plain}}
    end
  end

  def plain_fallback(text) do
    with :ok <- validate_length(text, 4096, false), do: {:ok, %{"text" => text}}
  end

  def caption_fallback(text) do
    with :ok <- validate_length(text, 1024, true), do: {:ok, %{caption: text}}
  end

  # Only consume our own escaped, allowlisted caption output, not arbitrary HTML.
  # Attributes (notably link destinations) are not visible entity text. Decode
  # ampersands last so a literal "&lt;" is not accidentally decoded twice.
  defp caption_text(html) do
    Regex.replace(~r/<[^>]*>/, html, "")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
  end

  # Conservative UTF-16 accounting also bounds Telegram entity coordinates;
  # grapheme counts alone undercount emoji and combining sequences.
  defp validate_length(text, limit, allow_empty) do
    units = div(byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :little})), 2)

    cond do
      not allow_empty and String.trim(text) == "" ->
        {:error, "Telegram text must not be empty"}

      units > limit ->
        {:error,
         "Telegram text exceeds #{limit} UTF-16 units; shorten it or send the full content using telegram.send_document"}

      true ->
        :ok
    end
  end

  defp prepare(source, format, mode) when is_binary(source) and format in ["markdown", "plain"] do
    cond do
      not String.valid?(source) ->
        {:error, "Telegram text must be valid UTF-8"}

      byte_size(source) > @source_bytes ->
        {:error, "Telegram text is too large; use telegram.send_document"}

      format == "plain" ->
        {:ok, %{plain: source, html: escape(source)}}

      true ->
        with {:ok, %{nodes: nodes}} <- MDEx.parse_document(source, extension: @extensions),
             :ok <- validate_shape(nodes) do
          {:ok,
           %{
             html: render(nodes, mode) |> String.trim(),
             plain: plain_document(nodes)
           }}
        else
          {:error, reason} when is_binary(reason) -> {:error, reason}
          _ -> {:error, "Telegram Markdown could not be parsed; use text_format plain"}
        end
    end
  end

  defp prepare(_, _, _), do: {:error, "Telegram text_format must be markdown or plain"}

  # Separate layout spacing from source whitespace. Trimming the whole output
  # corrupts indentation/trailing spaces in a leading or trailing code block.
  defp plain_document(nodes) do
    Enum.map_join(nodes, "\n\n", fn
      %MDEx.CodeBlock{literal: text} ->
        text

      %MDEx.Paragraph{nodes: children} ->
        render(children, :plain)

      %MDEx.Heading{nodes: children} ->
        render(children, :plain)

      %MDEx.BlockQuote{nodes: children} ->
        plain_document(children)

      %MDEx.List{} = list ->
        plain_list(list)

      %MDEx.ListItem{nodes: children} ->
        plain_document(children)

      %MDEx.TaskItem{nodes: children, checked: checked} ->
        if(checked, do: "☑ ", else: "☐ ") <> plain_document(children)

      node ->
        node |> render(:plain) |> String.trim_trailing("\n")
    end)
  end

  defp plain_list(%MDEx.List{nodes: nodes, list_type: type, start: start}) do
    nodes
    |> Enum.with_index(start)
    |> Enum.map_join("\n", fn {node, index} ->
      prefix = if type == :ordered, do: "#{index}. ", else: "• "
      prefix <> plain_document([node])
    end)
  end

  defp validate_shape(nodes) do
    case shape(nodes, 0, 0) do
      {:ok, _} ->
        :ok

      :too_complex ->
        {:error,
         "Telegram Markdown exceeds formatting limits (500 blocks, 16 levels, 20 table columns); simplify it or use text_format plain"}
    end
  end

  defp shape(_, depth, blocks) when depth > 16 or blocks > 500, do: :too_complex
  defp shape([], _, blocks), do: {:ok, blocks}
  defp shape([%MDEx.TableRow{nodes: cells} | _], _, _) when length(cells) > 20, do: :too_complex

  defp shape([node | rest], depth, blocks) do
    count = if node.__struct__ in @block_nodes, do: 1, else: 0

    with {:ok, blocks} <- shape(Map.get(node, :nodes, []), depth + 1, blocks + count) do
      shape(rest, depth, blocks)
    end
  end

  defp render(nodes, mode) when is_list(nodes), do: Enum.map_join(nodes, &render(&1, mode))
  defp render(%MDEx.Text{literal: text}, mode), do: literal(text, mode)
  defp render(%MDEx.SoftBreak{}, _), do: "\n"
  defp render(%MDEx.LineBreak{}, _), do: "\n"
  defp render(%MDEx.Code{literal: text}, mode), do: wrap("code", literal(text, mode), mode)

  defp render(%MDEx.CodeBlock{literal: text}, :plain), do: text <> "\n"
  defp render(%MDEx.CodeBlock{literal: text}, _), do: "<pre>" <> escape(text) <> "</pre>\n"

  defp render(%MDEx.Strong{nodes: nodes}, mode),
    do: wrap("b", inline_container(nodes, mode), mode)

  defp render(%MDEx.Emph{nodes: nodes}, mode), do: wrap("i", inline_container(nodes, mode), mode)

  defp render(%MDEx.Strikethrough{nodes: nodes}, mode),
    do: wrap("s", inline_container(nodes, mode), mode)

  defp render(%MDEx.Heading{nodes: nodes}, mode),
    do: wrap("b", inline_container(nodes, mode), mode) <> "\n\n"

  defp render(%MDEx.Paragraph{nodes: [%MDEx.Strong{nodes: nodes}]}, :message),
    do: render(nodes, :message) <> "\n\n"

  defp render(%MDEx.Paragraph{nodes: nodes}, mode), do: render(nodes, mode) <> "\n\n"

  defp render(%MDEx.BlockQuote{nodes: nodes}, mode) when mode in [:caption, :message] do
    text = render(nodes, :plain) |> String.trim() |> String.replace("\n", "\n> ")
    escape("> " <> text) <> "\n\n"
  end

  defp render(%MDEx.BlockQuote{nodes: nodes}, mode),
    do: wrap("blockquote", render(nodes, mode), mode) <> "\n"

  defp render(%MDEx.ThematicBreak{}, _), do: "—\n"

  defp render(%MDEx.List{nodes: nodes, list_type: type, start: start}, mode) do
    nodes
    |> Enum.with_index(start)
    |> Enum.map_join(fn {node, index} ->
      prefix = if type == :ordered, do: "#{index}. ", else: "• "
      prefix <> String.trim(render(node, mode)) <> "\n"
    end)
  end

  defp render(%MDEx.ListItem{nodes: nodes}, mode), do: render(nodes, mode)

  defp render(%MDEx.TaskItem{nodes: nodes, checked: checked}, mode) do
    marker = if checked, do: "☑ ", else: "☐ "

    marker <> render(nodes, mode)
  end

  defp render(%MDEx.Table{nodes: nodes}, mode),
    do: wrap("pre", literal(render(nodes, :plain), mode), mode) <> "\n"

  defp render(%MDEx.TableRow{nodes: nodes}, mode),
    do: Enum.map_join(nodes, " | ", &render(&1, mode)) <> "\n"

  defp render(%MDEx.TableCell{nodes: nodes}, mode), do: render(nodes, mode)

  defp render(%MDEx.Link{nodes: nodes, url: url}, mode), do: link(nodes, url, mode)
  defp render(%MDEx.Image{nodes: nodes, url: url}, mode), do: link(nodes, url, mode)
  # Raw HTML is visible literal content, never provider markup or buttons.
  defp render(%{literal: text}, mode) when is_binary(text), do: literal(text, mode)
  defp render(%{nodes: nodes}, mode), do: render(nodes, mode)
  defp render(_, _), do: ""

  defp link(nodes, url, mode) do
    # A Markdown badge is a link containing an image. The image becomes label
    # text here, not a second anchor inside the destination link.
    nodes =
      Enum.map(
        nodes,
        &MDEx.traverse_and_update(&1, fn
          %MDEx.Image{nodes: children, url: image_url} ->
            text = render(children, :plain)
            %MDEx.Text{literal: if(String.trim(text) == "", do: image_url, else: text)}

          node ->
            node
        end)
      )

    label = inline_container(nodes, mode)

    if safe_url?(url) do
      label = if String.trim(render(nodes, :plain)) == "", do: literal(url, mode), else: label

      cond do
        mode != :plain -> "<a href=\"" <> escape(url) <> "\">" <> label <> "</a>"
        label == url -> url
        true -> label <> " (" <> url <> ")"
      end
    else
      label
    end
  end

  # Ordinary caption entities cannot overlap code/pre with another entity.
  # Preserve the literal code text inside bold/links without an invalid nest.
  defp inline_container(nodes, mode) when mode in [:caption, :message] do
    nodes
    |> Enum.map(
      &MDEx.traverse_and_update(&1, fn
        %MDEx.Code{literal: text} -> %MDEx.Text{literal: text}
        node -> node
      end)
    )
    |> render(mode)
  end

  defp inline_container(nodes, mode), do: render(nodes, mode)

  defp safe_url?(url) do
    uri = URI.parse(url)

    not Regex.match?(~r/[\x00-\x20\x7F]/u, url) and
      ((uri.scheme in ["https", "http"] and is_binary(uri.host) and uri.host != "" and
          is_nil(uri.userinfo)) or
         (uri.scheme == "mailto" and is_binary(uri.path) and uri.path != ""))
  end

  defp wrap(_, content, :plain), do: content
  defp wrap(tag, content, _), do: "<#{tag}>" <> content <> "</#{tag}>"
  defp literal(text, :plain), do: text
  defp literal(text, _), do: escape(text)

  defp escape(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")
end
