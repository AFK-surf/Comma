defmodule SalixIM.SlackMarkdown do
  @moduledoc """
  Canonical deterministic rendering of standard Markdown for Slack.

  Ordinary messages preserve document constructs in native Markdown blocks,
  with explicit rich-text styles for supported bold prose. Task and Plan fields
  use the same boundary to produce the single `rich_text` entity Slack requires.
  """

  @markdown_source_limit 12_000
  @header_text_limit 150
  @inline_markdown ~r/[*_`~<>\[\]\\]/u
  @task_list_item ~r/^( {0,3})([-+*])[\t ]+\[[ xX]\](?:[\t ]+(.*))?$/u
  @fence_start ~r/^( {0,3})(`{3,}|~{3,})(.*)$/u

  @doc """
  Render standard Markdown into non-interactive Slack blocks.

  The limit applies to the cumulative source inside `markdown` blocks. A
  leading plain H1 may be promoted to a `header` block and therefore does not
  count toward that Markdown-source limit.
  """
  @spec render_blocks(String.t()) :: {:ok, [map()]} | {:error, :markdown_too_long}
  def render_blocks(text) when is_binary(text) do
    text = normalize_task_lists(text)

    case leading_plain_h1(text) do
      {:ok, title, body} ->
        if String.length(body) <= @markdown_source_limit do
          {:ok, header_blocks(title, body)}
        else
          {:error, :markdown_too_long}
        end

      :none ->
        if String.length(text) <= @markdown_source_limit do
          {:ok, [%{"type" => "markdown", "text" => text}]}
        else
          {:error, :markdown_too_long}
        end
    end
  end

  @doc "Convert standard Markdown into code-aware Slack mrkdwn fallback text."
  @spec to_mrkdwn(String.t(), keyword()) :: String.t()
  def to_mrkdwn(text, opts \\ []) when is_binary(text) and is_list(opts) do
    {source, entity_shield} = shield_preserved_entities(text, opts)

    source
    |> render_rich_elements()
    |> serialize_rich_elements(opts)
    |> restore_preserved_entities(entity_shield)
  end

  @doc """
  Remove presentation-only task markers from ordinary Markdown list items.

  Dedicated Task cards do not use this renderer. Task-like source inside fenced
  or indented code remains literal.
  """
  @spec normalize_task_lists(String.t()) :: String.t()
  def normalize_task_lists(text) when is_binary(text) do
    {lines, _fence} =
      text
      |> String.split("\n", trim: false)
      |> Enum.map_reduce(nil, &normalize_line/2)

    Enum.join(lines, "\n")
  end

  @doc "Validate Slack's cumulative Markdown-source limit for explicit blocks."
  @spec validate_blocks!([map()]) :: :ok
  def validate_blocks!(blocks) when is_list(blocks) do
    source_length =
      Enum.reduce(blocks, 0, fn
        %{"type" => "markdown", "text" => text}, total when is_binary(text) ->
          total + String.length(text)

        _block, total ->
          total
      end)

    if source_length > @markdown_source_limit do
      raise "cumulative markdown block text exceeds 12000 characters"
    end

    :ok
  end

  defp leading_plain_h1(text) do
    case String.split(text, "\n", parts: 2) do
      [first_line, body] -> promote_h1(first_line, body)
      [first_line] -> promote_h1(first_line, "")
    end
  end

  defp normalize_line(line, nil) do
    case fence_start(line) do
      nil -> {normalize_task_list_item(line), nil}
      fence -> {line, fence}
    end
  end

  defp normalize_line(line, fence) do
    if fence_close?(line, fence), do: {line, nil}, else: {line, fence}
  end

  defp normalize_task_list_item(line) do
    {source, suffix} = split_carriage_return(line)

    case Regex.run(@task_list_item, source, capture: :all_but_first) do
      [indent, marker, content] -> indent <> marker <> " " <> content <> suffix
      [indent, marker] -> indent <> marker <> suffix
      nil -> line
    end
  end

  defp fence_start(line) do
    {source, _suffix} = split_carriage_return(line)

    case Regex.run(@fence_start, source, capture: :all_but_first) do
      [_indent, marker, _info] -> {String.first(marker), String.length(marker)}
      nil -> nil
    end
  end

  defp fence_close?(line, {character, minimum_length}) do
    {raw_source, _suffix} = split_carriage_return(line)
    source = String.trim_leading(raw_source, " ")
    leading_spaces = String.length(raw_source) - String.length(source)
    marker_length = count_leading(source, character)
    remainder = String.slice(source, marker_length, String.length(source) - marker_length)

    leading_spaces <= 3 and marker_length >= minimum_length and String.trim(remainder) == ""
  end

  defp count_leading(source, character) do
    source
    |> String.graphemes()
    |> Enum.take_while(&(&1 == character))
    |> length()
  end

  defp split_carriage_return(line) do
    if String.ends_with?(line, "\r") do
      {String.trim_trailing(line, "\r"), "\r"}
    else
      {line, ""}
    end
  end

  defp promote_h1(first_line, body) do
    first_line = String.trim_trailing(first_line, "\r")

    case first_line do
      "# " <> raw_title ->
        title = String.trim(raw_title)

        if plain_title?(title) do
          {:ok, title, trim_title_spacing(body)}
        else
          :none
        end

      _other ->
        :none
    end
  end

  defp plain_title?(title) do
    title != "" and String.length(title) <= @header_text_limit and
      not Regex.match?(@inline_markdown, title)
  end

  defp trim_title_spacing("\r\n" <> body), do: body
  defp trim_title_spacing("\n" <> body), do: body
  defp trim_title_spacing(body), do: body

  defp header_blocks(title, "") do
    [%{"type" => "header", "text" => %{"type" => "plain_text", "text" => title}}]
  end

  defp header_blocks(title, body) do
    [
      %{"type" => "header", "text" => %{"type" => "plain_text", "text" => title}},
      %{"type" => "markdown", "text" => body}
    ]
  end

  # Task and Plan fields cannot contain a native `markdown` block: Slack's
  # schema requires one `rich_text` entity. Parse CommonMark once with the
  # already-used MDEx dependency, then adapt the same AST to rich_text or
  # legacy mrkdwn without provider-side regular-expression parsers.
  @markdown_extensions [strikethrough: true, tasklist: true]
  @language ~r/^[A-Za-z0-9_+.-]{1,64}$/u
  @literal_marker ~r/[*_~`]+/u
  @literal_marker_only ~r/\A[*_~`]+\z/u
  @slack_native_reference_at_start ~r/\A<(?:@[UW]|#[CG])[A-Z0-9]{2,}>/u
  @literal_key "__salix_literal__"
  @entity_shield_prefix "\u{FDD0}salix-slack-entity-"

  @type rich_text :: %{required(String.t()) => term()}

  @doc "Render standard Markdown into one Slack `rich_text` block."
  @spec render_rich_text(String.t()) :: rich_text()
  def render_rich_text(text) when is_binary(text) do
    %{"type" => "rich_text", "elements" => text |> render_rich_elements() |> public_elements()}
  end

  @doc "Render bold prose deterministically, retaining native Markdown for other blocks."
  def render_prose_block(text) when is_binary(text) do
    %MDEx.Document{nodes: nodes} = MDEx.parse_document!(text, extension: @markdown_extensions)

    # Slack's native Markdown parser can leave strong delimiters literal around
    # links and percentages next to CJK punctuation. Send explicit styles instead.
    # Keep document-only constructs on the native path (notably headings/tables).
    if Enum.all?(nodes, &rich_prose_node?/1) and contains_strong?(nodes) do
      render_rich_text(text)
    else
      %{"type" => "markdown", "text" => text}
    end
  end

  defp rich_prose_node?(%MDEx.Paragraph{}), do: true
  defp rich_prose_node?(%MDEx.CodeBlock{}), do: true

  defp rich_prose_node?(%{__struct__: type, nodes: nodes})
       when type in [MDEx.List, MDEx.ListItem, MDEx.BlockQuote],
       do: Enum.all?(nodes, &rich_prose_node?/1)

  defp rich_prose_node?(_node), do: false

  defp contains_strong?(nodes) do
    Enum.any?(nodes, fn
      %MDEx.Strong{} -> true
      %{nodes: children} -> contains_strong?(children)
      _node -> false
    end)
  end

  defp render_rich_elements(text) do
    source = text |> normalize_newlines() |> String.trim()

    if source == "" do
      []
    else
      %MDEx.Document{nodes: nodes} =
        MDEx.parse_document!(source, extension: @markdown_extensions)

      nodes = normalize_strikethrough_nodes(nodes, String.split(source, "\n", trim: false))
      render_ast_nodes(nodes, 0)
    end
  end

  defp normalize_newlines(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  # Comrak's GFM extension accepts both `~text~` and `~~text~~`. Our authored
  # Markdown contract reserves only the double marker for strikethrough, so
  # turn single-marker nodes back into literal source before either Slack
  # serializer sees the shared AST.
  defp normalize_strikethrough_nodes(nodes, source_lines) do
    nodes
    |> Enum.flat_map(&normalize_strikethrough_node(&1, source_lines))
    |> coalesce_mdex_text_nodes()
  end

  defp normalize_strikethrough_node(%MDEx.Strikethrough{} = node, source_lines) do
    children = normalize_strikethrough_nodes(node.nodes, source_lines)
    source = source_fragment(source_lines, node.sourcepos)

    cond do
      String.starts_with?(source, "~~") and String.ends_with?(source, "~~") ->
        [%{node | nodes: children}]

      Enum.all?(children, &match?(%MDEx.Text{}, &1)) ->
        [%MDEx.Text{literal: source, sourcepos: node.sourcepos}]

      true ->
        marker = %MDEx.Text{literal: "~", sourcepos: node.sourcepos}
        [marker | children] ++ [marker]
    end
  end

  defp normalize_strikethrough_node(%{nodes: nodes} = node, source_lines)
       when is_list(nodes) do
    [Map.put(node, :nodes, normalize_strikethrough_nodes(nodes, source_lines))]
  end

  defp normalize_strikethrough_node(node, _source_lines), do: [node]

  defp coalesce_mdex_text_nodes(nodes) do
    nodes
    |> Enum.reduce([], fn
      %MDEx.Text{} = text, [%MDEx.Text{} = previous | rest] ->
        sourcepos = %MDEx.Sourcepos{
          start: previous.sourcepos.start,
          end: text.sourcepos.end
        }

        [%{previous | literal: previous.literal <> text.literal, sourcepos: sourcepos} | rest]

      node, rendered ->
        [node | rendered]
    end)
    |> Enum.reverse()
  end

  defp source_fragment(lines, %MDEx.Sourcepos{
         start: {start_line, start_column},
         end: {end_line, end_column}
       }) do
    if start_line == end_line do
      lines
      |> Enum.at(start_line - 1, "")
      |> binary_part(start_column - 1, end_column - start_column + 1)
    else
      first = Enum.at(lines, start_line - 1, "")
      last = Enum.at(lines, end_line - 1, "")

      middle =
        lines
        |> Enum.slice(start_line, max(end_line - start_line - 1, 0))

      [
        binary_part(first, start_column - 1, byte_size(first) - start_column + 1),
        middle,
        binary_part(last, 0, end_column)
      ]
      |> List.flatten()
      |> Enum.join("\n")
    end
  end

  defp render_ast_nodes(nodes, indent) do
    Enum.flat_map(nodes, &render_ast_node(&1, indent))
  end

  defp render_ast_node(%MDEx.Paragraph{nodes: nodes}, _indent),
    do: [section_from_nodes(nodes)]

  defp render_ast_node(%MDEx.Heading{nodes: nodes}, _indent),
    do: [section_from_nodes(nodes, %{"bold" => true})]

  defp render_ast_node(%MDEx.BlockQuote{nodes: nodes}, _indent) do
    elements = block_nodes_to_inline(nodes, %{}) |> nonempty_elements()
    [%{"type" => "rich_text_quote", "elements" => elements}]
  end

  defp render_ast_node(%MDEx.CodeBlock{fenced: true, closed: false} = code, _indent),
    do: [literal_section(unclosed_fence_source(code))]

  defp render_ast_node(%MDEx.CodeBlock{} = code, _indent) do
    text = code.literal |> trim_one_trailing_newline() |> nonempty_text()

    element = %{
      "type" => "rich_text_preformatted",
      "elements" => [%{"type" => "text", "text" => text}]
    }

    [put_optional(element, "language", code_language(code.info))]
  end

  defp render_ast_node(%MDEx.List{} = list, indent),
    do: render_list_elements(list, indent)

  defp render_ast_node(%MDEx.ThematicBreak{}, _indent),
    do: [section_from_inline([text_element("────────", %{})])]

  defp render_ast_node(%MDEx.HtmlBlock{literal: literal}, _indent),
    do: [literal_section(String.trim_trailing(literal))]

  defp render_ast_node(%{nodes: nodes}, indent) when is_list(nodes),
    do: render_ast_nodes(nodes, indent)

  defp render_ast_node(%{literal: literal}, _indent) when is_binary(literal),
    do: [section_from_inline(safe_text_elements(literal, %{}))]

  defp render_ast_node(_node, _indent), do: []

  defp section_from_nodes(nodes, styles \\ %{}) do
    nodes
    |> inline_elements_from_nodes(styles)
    |> section_from_inline()
  end

  defp section_from_inline(elements) do
    %{"type" => "rich_text_section", "elements" => nonempty_elements(elements)}
  end

  defp literal_section(text) do
    %{
      "type" => "rich_text_section",
      "elements" => [literal_text_element(text, %{})]
    }
  end

  defp render_list_elements(%MDEx.List{} = list, indent) do
    {rendered, pending, pending_index} =
      list.nodes
      |> Enum.with_index()
      |> Enum.reduce({[], [], nil}, fn {item, index}, {rendered, pending, pending_index} ->
        {content, nested_lists} = list_item_parts(item, %{})
        content = task_marker(item) ++ content
        pending_index = pending_index || index
        pending = pending ++ [section_from_inline(content)]

        if nested_lists == [] do
          {rendered, pending, pending_index}
        else
          group = rich_list(list, pending, indent, pending_index)
          nested = Enum.flat_map(nested_lists, &render_ast_node(&1, indent + 1))
          {rendered ++ [group] ++ nested, [], nil}
        end
      end)

    case pending do
      [] -> rendered
      _items -> rendered ++ [rich_list(list, pending, indent, pending_index)]
    end
  end

  defp list_item_parts(%{nodes: nodes}, styles) do
    Enum.reduce(nodes, {[], []}, fn
      %MDEx.List{} = nested, {content, nested_lists} ->
        {content, nested_lists ++ [nested]}

      node, {content, nested_lists} ->
        group = block_node_to_inline(node, styles)
        {append_inline_group(content, group, styles), nested_lists}
    end)
  end

  defp task_marker(%MDEx.TaskItem{checked: true}), do: [text_element("☑ ", %{})]
  defp task_marker(%MDEx.TaskItem{}), do: [text_element("☐ ", %{})]
  defp task_marker(_item), do: []

  defp rich_list(list, sections, indent, first_index) do
    style = if list.list_type == :ordered, do: "ordered", else: "bullet"

    offset =
      if style == "ordered" do
        max((list.start || 1) + first_index - 1, 0)
      else
        0
      end

    %{"type" => "rich_text_list", "style" => style, "elements" => sections}
    |> put_optional_number("indent", min(indent, 8))
    |> put_optional_number("offset", offset)
  end

  defp block_nodes_to_inline(nodes, styles) do
    Enum.reduce(nodes, [], fn node, rendered ->
      append_inline_group(rendered, block_node_to_inline(node, styles), styles)
    end)
  end

  defp block_node_to_inline(%MDEx.Paragraph{nodes: nodes}, styles),
    do: inline_elements_from_nodes(nodes, styles)

  defp block_node_to_inline(%MDEx.Heading{nodes: nodes}, styles),
    do: inline_elements_from_nodes(nodes, Map.put(styles, "bold", true))

  defp block_node_to_inline(%MDEx.BlockQuote{nodes: nodes}, styles),
    do: block_nodes_to_inline(nodes, styles)

  defp block_node_to_inline(%MDEx.CodeBlock{fenced: true, closed: false} = code, styles),
    do: [literal_text_element(unclosed_fence_source(code), styles)]

  defp block_node_to_inline(%MDEx.CodeBlock{literal: literal}, styles),
    do: [text_element(trim_one_trailing_newline(literal), Map.put(styles, "code", true))]

  defp block_node_to_inline(%MDEx.List{} = list, styles),
    do: list_to_inline(list, styles, 0)

  defp block_node_to_inline(%MDEx.ThematicBreak{}, styles),
    do: [text_element("────────", styles)]

  defp block_node_to_inline(%MDEx.HtmlBlock{literal: literal}, styles),
    do: [text_element(String.trim_trailing(literal), styles)]

  defp block_node_to_inline(%{nodes: nodes}, styles) when is_list(nodes),
    do: block_nodes_to_inline(nodes, styles)

  defp block_node_to_inline(%{literal: literal}, styles) when is_binary(literal),
    do: safe_text_elements(literal, styles)

  defp block_node_to_inline(_node, _styles), do: []

  defp list_to_inline(%MDEx.List{} = list, styles, indent) do
    list.nodes
    |> Enum.with_index()
    |> Enum.reduce([], fn {item, index}, rendered ->
      marker =
        if list.list_type == :ordered,
          do: "#{(list.start || 1) + index}.",
          else: "-"

      {content, nested_lists} = list_item_parts(item, styles)

      line =
        [text_element(String.duplicate("  ", indent) <> marker <> " ", styles)] ++
          task_marker_with_styles(item, styles) ++ content

      rendered = append_inline_group(rendered, line, styles)

      Enum.reduce(nested_lists, rendered, fn nested, acc ->
        append_inline_group(acc, list_to_inline(nested, styles, indent + 1), styles)
      end)
    end)
  end

  defp task_marker_with_styles(%MDEx.TaskItem{checked: true}, styles),
    do: [text_element("☑ ", styles)]

  defp task_marker_with_styles(%MDEx.TaskItem{}, styles),
    do: [text_element("☐ ", styles)]

  defp task_marker_with_styles(_item, _styles), do: []

  defp append_inline_group(rendered, [], _styles), do: rendered
  defp append_inline_group([], group, _styles), do: group

  defp append_inline_group(rendered, group, styles),
    do: rendered ++ [text_element("\n", styles)] ++ group

  defp inline_elements_from_nodes(nodes, styles) do
    nodes
    |> Enum.flat_map(&inline_node_elements(&1, styles))
    |> coalesce_forward()
  end

  defp inline_node_elements(%MDEx.Text{literal: literal}, styles),
    do: safe_text_elements(literal, styles)

  defp inline_node_elements(%MDEx.Code{literal: literal}, styles),
    do: [text_element(literal, Map.put(styles, "code", true))]

  defp inline_node_elements(%MDEx.Emph{nodes: nodes}, styles),
    do: inline_elements_from_nodes(nodes, Map.put(styles, "italic", true))

  defp inline_node_elements(%MDEx.Strong{nodes: nodes}, styles),
    do: inline_elements_from_nodes(nodes, Map.put(styles, "bold", true))

  defp inline_node_elements(%MDEx.Strikethrough{nodes: nodes}, styles),
    do: inline_elements_from_nodes(nodes, Map.put(styles, "strike", true))

  defp inline_node_elements(%MDEx.Link{nodes: nodes, url: url}, styles) do
    label = inline_plain_text(nodes)

    if valid_link_url?(url) do
      [link_element(if(label == "", do: url, else: label), url, styles)]
    else
      safe_text_elements(label <> if(url == "", do: "", else: " (#{url})"), styles)
    end
  end

  defp inline_node_elements(%MDEx.Image{nodes: nodes, url: url}, styles) do
    label = inline_plain_text(nodes)
    inline_node_elements(%MDEx.Link{nodes: [%MDEx.Text{literal: label}], url: url}, styles)
  end

  defp inline_node_elements(%MDEx.SoftBreak{}, styles), do: [text_element("\n", styles)]
  defp inline_node_elements(%MDEx.LineBreak{}, styles), do: [text_element("\n", styles)]

  defp inline_node_elements(%MDEx.HtmlInline{literal: literal}, styles),
    do: safe_text_elements(literal, styles)

  defp inline_node_elements(%MDEx.ShortCode{emoji: emoji}, styles),
    do: [text_element(emoji, styles)]

  defp inline_node_elements(%{nodes: nodes}, styles) when is_list(nodes),
    do: inline_elements_from_nodes(nodes, styles)

  defp inline_node_elements(%{literal: literal}, styles) when is_binary(literal),
    do: safe_text_elements(literal, styles)

  defp inline_node_elements(_node, _styles), do: []

  defp inline_plain_text(nodes) do
    nodes
    |> inline_elements_from_nodes(%{})
    |> Enum.map_join(fn
      %{"text" => text} -> text
      _element -> ""
    end)
  end

  defp safe_text_elements(text, styles) do
    @literal_marker
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      if Regex.match?(@literal_marker_only, part) do
        literal_text_element(part, styles)
      else
        text_element(part, styles)
      end
    end)
  end

  defp text_element(text, styles) do
    %{"type" => "text", "text" => text}
    |> put_optional_style(styles)
  end

  defp literal_text_element(text, styles) do
    text_element(text, styles)
    |> Map.put(@literal_key, true)
  end

  defp link_element(text, url, styles) do
    %{"type" => "link", "text" => text, "url" => url}
    |> put_optional_style(styles)
  end

  defp nonempty_elements([]), do: [%{"type" => "text", "text" => " "}]
  defp nonempty_elements(elements), do: elements

  defp code_language(info) do
    language = info |> String.trim() |> String.split(~r/[\t ]+/u, parts: 2) |> List.first()
    if is_binary(language) and Regex.match?(@language, language), do: language, else: nil
  end

  defp unclosed_fence_source(code) do
    marker = String.duplicate(code.fence_char, max(code.fence_length, 3))
    opening = String.duplicate(" ", code.fence_offset) <> marker <> code.info
    body = trim_one_trailing_newline(code.literal)
    if body == "", do: opening, else: opening <> "\n" <> body
  end

  defp trim_one_trailing_newline(text) do
    if String.ends_with?(text, "\n") do
      binary_part(text, 0, byte_size(text) - 1)
    else
      text
    end
  end

  defp valid_link_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      %URI{scheme: "mailto", path: path} ->
        is_binary(path) and path != ""

      _uri ->
        false
    end
  end

  defp coalesce_forward(elements) do
    elements
    |> coalesce_text_elements([])
    |> Enum.reverse()
  end

  defp coalesce_text_elements([], elements), do: elements

  defp coalesce_text_elements(
         [%{"type" => "text", "text" => text} = element | rest],
         [%{"type" => "text", "text" => previous_text} = previous | elements]
       ) do
    if Map.get(element, "style") == Map.get(previous, "style") and
         Map.get(element, @literal_key) == Map.get(previous, @literal_key) do
      coalesce_text_elements(rest, [Map.put(previous, "text", previous_text <> text) | elements])
    else
      coalesce_text_elements(rest, [element, previous | elements])
    end
  end

  defp coalesce_text_elements([element | rest], elements),
    do: coalesce_text_elements(rest, [element | elements])

  defp public_elements(elements) do
    elements
    |> Enum.map(&public_element/1)
    |> coalesce_public_text()
  end

  defp public_element(%{"elements" => elements} = element) do
    element
    |> Map.delete(@literal_key)
    |> Map.put("elements", public_elements(elements))
  end

  defp public_element(element), do: Map.delete(element, @literal_key)

  defp coalesce_public_text(elements) do
    elements
    |> coalesce_text_elements([])
    |> Enum.reverse()
  end

  defp serialize_rich_elements(elements, opts) do
    elements
    |> Enum.map(fn element -> {element["type"], serialize_rich_element(element, opts)} end)
    |> Enum.reject(fn {_type, text} -> text == "" end)
    |> Enum.reduce({[], nil}, fn {type, text}, {rendered, previous_type} ->
      separator =
        cond do
          rendered == [] -> ""
          type == "rich_text_list" and previous_type == "rich_text_list" -> "\n"
          true -> "\n\n"
        end

      {[rendered, separator, text], type}
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  defp serialize_rich_element(
         %{"type" => "rich_text_section", "elements" => elements},
         opts
       ),
       do: serialize_inline_elements(elements, opts)

  defp serialize_rich_element(%{"type" => "rich_text_quote", "elements" => elements}, opts) do
    elements
    |> serialize_inline_elements(opts)
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", &("> " <> &1))
  end

  defp serialize_rich_element(
         %{"type" => "rich_text_preformatted", "elements" => elements},
         _opts
       ) do
    code = Enum.map_join(elements, "", &Map.get(&1, "text", ""))
    fenced_code(code)
  end

  defp serialize_rich_element(
         %{"type" => "rich_text_list", "style" => style, "elements" => elements} = list,
         opts
       ) do
    indent = max(Map.get(list, "indent", 0), 0)
    offset = max(Map.get(list, "offset", 0), 0)

    elements
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {%{"elements" => inline}, index} ->
      marker = if style == "ordered", do: "#{offset + index + 1}.", else: "-"
      serialize_list_item(inline, marker, indent, opts)
    end)
  end

  defp serialize_rich_element(_element, _opts), do: ""

  defp serialize_list_item(elements, marker, indent, opts) do
    indentation = String.duplicate("  ", indent)
    continuation = indentation <> String.duplicate(" ", String.length(marker) + 1)

    case elements |> serialize_inline_elements(opts) |> String.split("\n", trim: false) do
      [first | rest] ->
        indentation <>
          marker <>
          " " <>
          first <>
          Enum.map_join(rest, "", &("\n" <> continuation <> &1))

      [] ->
        indentation <> marker
    end
  end

  defp serialize_inline_elements(elements, opts) do
    {rendered, active_styles} =
      Enum.reduce(elements, {[], []}, fn element, {rendered, active_styles} ->
        {text, requested_styles} = serialize_inline_element(element, opts)
        desired_styles = preserve_active_style_order(active_styles, requested_styles)
        transition = style_transition(active_styles, desired_styles)
        {[rendered, transition, text], desired_styles}
      end)

    [rendered, close_styles(active_styles)]
    |> IO.iodata_to_binary()
  end

  defp serialize_inline_element(%{"type" => "text", "text" => text} = element, opts) do
    styles = Map.get(element, "style", %{})

    cond do
      Map.get(styles, "code", false) ->
        {code_span(text), []}

      Map.get(element, @literal_key, false) ->
        {literal_mrkdwn(text), []}

      true ->
        {escape_slack_text(text, opts), ordered_styles(styles)}
    end
  end

  defp serialize_inline_element(
         %{"type" => "link", "text" => text, "url" => url} = element,
         _opts
       ) do
    rendered = "<#{escape_slack_controls(url)}|#{escape_slack_controls(text)}>"
    {rendered, ordered_styles(Map.get(element, "style", %{}))}
  end

  defp serialize_inline_element(_element, _opts), do: {"", []}

  defp ordered_styles(styles) do
    Enum.filter(["bold", "italic", "strike"], &Map.get(styles, &1, false))
  end

  defp preserve_active_style_order(active, requested) do
    preserved = Enum.take_while(active, &(&1 in requested))
    preserved ++ Enum.reject(requested, &(&1 in preserved))
  end

  defp style_transition(active, desired) do
    shared_count = shared_style_count(active, desired, 0)

    closing = active |> Enum.drop(shared_count) |> Enum.reverse() |> Enum.map(&style_marker/1)
    opening = desired |> Enum.drop(shared_count) |> Enum.map(&style_marker/1)
    [closing, opening]
  end

  defp shared_style_count([style | active], [style | desired], count),
    do: shared_style_count(active, desired, count + 1)

  defp shared_style_count(_active, _desired, count), do: count

  defp close_styles(styles), do: styles |> Enum.reverse() |> Enum.map(&style_marker/1)

  defp style_marker("bold"), do: "*"
  defp style_marker("italic"), do: "_"
  defp style_marker("strike"), do: "~"

  defp literal_mrkdwn(text) do
    if String.contains?(text, "\n"), do: fenced_code(text), else: code_span(text)
  end

  defp code_span(text) do
    marker = String.duplicate("`", max(longest_backtick_run(text) + 1, 1))
    marker <> text <> marker
  end

  defp fenced_code(text) do
    marker = String.duplicate("`", max(longest_backtick_run(text) + 1, 3))
    trailing_newline = if String.ends_with?(text, "\n"), do: "", else: "\n"
    marker <> "\n" <> text <> trailing_newline <> marker
  end

  defp longest_backtick_run(text) do
    ~r/`+/u
    |> Regex.scan(text, capture: :first)
    |> Enum.map(fn [run] -> String.length(run) end)
    |> Enum.max(fn -> 0 end)
  end

  defp escape_slack_text(text, opts), do: escape_slack_text(text, opts, [])

  defp escape_slack_text("", _opts, rendered),
    do: rendered |> Enum.reverse() |> IO.iodata_to_binary()

  defp escape_slack_text(text, opts, rendered) do
    case preserved_slack_token(text, opts) do
      {:ok, token, rest} ->
        escape_slack_text(rest, opts, [token | rendered])

      :none ->
        {grapheme, rest} = String.next_grapheme(text)
        escape_slack_text(rest, opts, [escape_slack_control(grapheme) | rendered])
    end
  end

  defp preserved_slack_token(text, opts) do
    if Keyword.get(opts, :preserve_native_references, false) do
      case Regex.run(@slack_native_reference_at_start, text) do
        [token] -> {:ok, token, drop_prefix(text, token)}
        nil -> :none
      end
    else
      :none
    end
  end

  defp shield_preserved_entities(text, opts) do
    if Keyword.get(opts, :preserve_entities, false) do
      shield = unused_entity_shield(text, 0)

      protected =
        text
        |> String.replace("&amp;", shield <> "amp;")
        |> String.replace("&lt;", shield <> "lt;")
        |> String.replace("&gt;", shield <> "gt;")

      {protected, shield}
    else
      {text, nil}
    end
  end

  defp unused_entity_shield(text, index) do
    candidate = @entity_shield_prefix <> Integer.to_string(index) <> "-"

    if String.contains?(text, candidate),
      do: unused_entity_shield(text, index + 1),
      else: candidate
  end

  defp restore_preserved_entities(text, nil), do: text

  defp restore_preserved_entities(text, shield) do
    text
    |> String.replace(shield <> "amp;", "&amp;")
    |> String.replace(shield <> "lt;", "&lt;")
    |> String.replace(shield <> "gt;", "&gt;")
  end

  defp escape_slack_controls(text) do
    text
    |> String.graphemes()
    |> Enum.map_join(&escape_slack_control/1)
  end

  defp escape_slack_control("&"), do: "&amp;"
  defp escape_slack_control("<"), do: "&lt;"
  defp escape_slack_control(">"), do: "&gt;"
  defp escape_slack_control(grapheme), do: grapheme

  defp drop_prefix(text, prefix) do
    binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))
  end

  defp nonempty_text(""), do: " "
  defp nonempty_text(text), do: text

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp put_optional_number(map, _key, value) when value in [nil, 0], do: map
  defp put_optional_number(map, key, value), do: Map.put(map, key, value)

  defp put_optional_style(map, styles) when map_size(styles) == 0, do: map
  defp put_optional_style(map, styles), do: Map.put(map, "style", styles)
end
