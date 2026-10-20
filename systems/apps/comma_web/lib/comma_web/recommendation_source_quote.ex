defmodule CommaWeb.RecommendationSourceQuote do
  @moduledoc """
  The quote that the briefing hover shows for one source record. Each product
  adapter builds it at collection from the provider record: the record title,
  who wrote the quoted words, status facts, and the words in their source
  format. This module turns every format into quote lines, and
  `Comma.RecommendationDraft.quoted_context/2` renders a quote for the hover.

  Quote lines use one markup: one line per source line, "• " before a list
  item, `<https://…|label>` for a link, Slack `<@U…|name>` and `<#C…|name>`
  mentions, and `&lt;`, `&gt;` and `&amp;` for literal characters.

  A quote is display text, not evidence. The model reads
  `CommaWeb.RecommendationSourceContext`, and the pooled item version does not
  cover the quote. An adapter can change a quote's wording without sending
  items to consumers again.
  """

  @markdown [autolink: true, shortcodes: true, strikethrough: true, table: true, tasklist: true]
  # Stored lines stay bounded. The hover shows at most 600 UTF-16 units.
  @line_bytes 2_000
  @urls ~w(url webUrl html_url htmlLink webViewLink permalink)
  @html_blocks ~w(address article blockquote br dd div dl dt figcaption footer h1 h2 h3 h4 h5 h6
                  header hr ol p pre section table tr ul)
  @html_hidden ~w(head script style template title)
  @mail_quoted_ids ~w(divRplyFwdMsg appendonsend)
  @mail_quoted_classes ~w(gmail_quote gmail_attr yahoo_quoted)
  @mail_history ~r/^(?:&gt;|On .+ wrote:$|-{2,} ?Original Message|_{10,}$|.+写道[:：]$)/u
  # Outlook writes an image in a text body as its address in brackets.
  @mail_images ~r/\[(?:cid:|https?:\/\/)[^\]\s]*\]/i

  @doc """
  Puts the quote of `record` under "quote".

  Options:
    * `:title` and `:author` are plain text.
    * `:facts` is a keyword list: `status:` a product's own status text,
      `checks:` `:passing`, `:failing` or `:pending`, `review:` `:approved`,
      `:changes_requested` or `:review_required`, and `draft: true`.
    * `:body` is `{format, text}`. The format is `:plain`, `:markdown`,
      `:html`, `:slack`, or `:mail` and `:mail_html` for mail text and mail
      HTML that quote earlier messages.
  """
  def put(record, opts) when is_map(record), do: Map.put(record, "quote", new(opts))

  def new(opts) do
    %{
      "title" => plain(opts[:title]),
      "author" => plain(opts[:author]),
      "facts" => Enum.flat_map(opts[:facts] || [], &fact/1),
      "lines" => opts[:body] |> body() |> bound(@line_bytes)
    }
    |> Map.reject(fn {_key, value} -> value in [nil, "", []] end)
  end

  @doc """
  Moves every record's "quote" out of `data` and keys it by the record URL,
  as `RecommendationSourceContext.separate/1` does for model context.
  """
  def separate(data) when is_map(data) do
    quotes =
      with %{} = quote when map_size(quote) > 0 <- data["quote"],
           url when is_binary(url) <- Enum.find_value(@urls, &data[&1]) do
        %{url => quote}
      else
        _ -> %{}
      end

    data
    |> Map.delete("quote")
    |> Enum.reduce({%{}, quotes}, fn {key, value}, {data, quotes} ->
      {value, nested} = separate(value)
      {Map.put(data, key, value), Map.merge(quotes, nested)}
    end)
  end

  def separate(data) when is_list(data) do
    Enum.map_reduce(data, %{}, fn value, quotes ->
      {value, nested} = separate(value)
      {value, Map.merge(quotes, nested)}
    end)
  end

  def separate(data), do: {data, %{}}

  @doc "The quotes of the records that the bounded `data` still holds."
  def retain(quotes, data) do
    allowed = Comma.RecommendationContract.http_urls(data)
    Map.filter(quotes, fn {url, _quote} -> MapSet.member?(allowed, url) end)
  end

  defp fact({:status, text}) do
    case plain(text) do
      nil -> []
      text -> [%{"kind" => "status", "value" => text}]
    end
  end

  defp fact({:checks, value}) when value in [:passing, :failing, :pending],
    do: [%{"kind" => "checks", "value" => Atom.to_string(value)}]

  defp fact({:review, value}) when value in [:approved, :changes_requested, :review_required],
    do: [%{"kind" => "review", "value" => Atom.to_string(value)}]

  defp fact({:draft, true}), do: [%{"kind" => "draft"}]
  defp fact(_fact), do: []

  defp body({_format, text}) when not is_binary(text) or text == "", do: []
  defp body({:plain, text}), do: text |> escape() |> lines()
  defp body({:slack, text}), do: text |> slack() |> lines()

  # An image in mail text has no words to quote.
  defp body({:mail, text}),
    do: text |> String.replace(@mail_images, "") |> escape() |> lines() |> own_words()

  # In HTML mail, the quoting blocks of Gmail, Outlook and Yahoo end its own
  # words, as an original-message rule does in text.
  defp body({:mail_html, text}) do
    case Floki.parse_document(text) do
      {:ok, nodes} ->
        nodes
        |> Floki.traverse_and_update(fn
          {tag, attributes, _children} = node ->
            if mail_quoted?(tag, attributes), do: {"hr", [], ["__________"]}, else: node

          node ->
            node
        end)
        |> html()
        |> lines()
        |> own_words()

      _ ->
        body({:plain, text})
    end
  end

  defp body({:markdown, text}) do
    case MDEx.parse_document(text, extension: @markdown) do
      {:ok, %{nodes: nodes}} -> nodes |> Enum.map_join("\n", &markdown/1) |> lines()
      _ -> body({:plain, text})
    end
  end

  defp body({:html, text}) do
    case Floki.parse_fragment(text) do
      {:ok, nodes} -> nodes |> html() |> lines()
      _ -> body({:plain, text})
    end
  end

  defp body(_body), do: []

  # Block nodes end lines. A list item starts with a bullet.
  defp markdown(%{__struct__: type, nodes: nodes}) when type in [MDEx.ListItem, MDEx.TaskItem],
    do: "\n• " <> Enum.map_join(nodes, "\n", &markdown/1) <> "\n"

  defp markdown(%MDEx.CodeBlock{literal: text}), do: escape(text)

  defp markdown(%MDEx.HtmlBlock{literal: text}) do
    case Floki.parse_fragment(text) do
      {:ok, nodes} -> html(nodes)
      _ -> ""
    end
  end

  defp markdown(%MDEx.ThematicBreak{}), do: ""

  defp markdown(%MDEx.TableRow{nodes: cells}),
    do: Enum.map_join(cells, " · ", &inline(&1.nodes)) <> "\n"

  defp markdown(%type{nodes: nodes}) when type in [MDEx.Paragraph, MDEx.Heading],
    do: inline(nodes) <> "\n"

  defp markdown(%{nodes: nodes}), do: Enum.map_join(nodes, "\n", &markdown/1)
  defp markdown(_node), do: ""

  defp inline(nodes) when is_list(nodes), do: Enum.map_join(nodes, &inline/1)
  defp inline(%type{literal: text}) when type in [MDEx.Text, MDEx.Code], do: escape(text)
  defp inline(%type{}) when type in [MDEx.SoftBreak, MDEx.LineBreak], do: "\n"
  defp inline(%MDEx.ShortCode{emoji: emoji}), do: emoji
  defp inline(%MDEx.HtmlInline{literal: "<br" <> _}), do: "\n"
  defp inline(%MDEx.HtmlInline{}), do: ""

  defp inline(%type{url: url, nodes: nodes}) when type in [MDEx.Link, MDEx.Image],
    do: link(url, inline(nodes))

  defp inline(%{nodes: nodes}), do: inline(nodes)
  defp inline(_node), do: ""

  defp html(nodes) when is_list(nodes), do: Enum.map_join(nodes, &html/1)
  defp html(text) when is_binary(text), do: escape(text)
  defp html({:comment, _text}), do: ""
  defp html({tag, _attributes, _children}) when tag in @html_hidden, do: ""
  defp html({"li", _attributes, children}), do: "\n• " <> html(children) <> "\n"

  defp html({"a", attributes, children}),
    do: link(attribute(attributes, "href"), html(children))

  defp html({"img", attributes, _children}),
    do: link(attribute(attributes, "src"), escape(attribute(attributes, "alt") || ""))

  defp html({tag, _attributes, children}) when tag in @html_blocks,
    do: "\n" <> html(children) <> "\n"

  defp html({_tag, _attributes, children}), do: html(children)
  defp html(_node), do: ""

  defp attribute(attributes, name),
    do: Enum.find_value(attributes, fn {key, value} -> if key == name, do: value end)

  # A link keeps an http(s) destination with its label. Any other link is its
  # label.
  defp link(url, label) do
    label = label |> String.replace(~r/\s+/u, " ") |> String.trim()

    if is_binary(url) and Regex.match?(~r{^https?://}i, url) do
      url = url |> String.replace("|", "%7C") |> String.replace(">", "%3E")
      if label == "", do: "<#{url}>", else: "<#{url}|#{label}>"
    else
      label
    end
  end

  # Slack text is already quote markup. Emphasis marks, emoji codes and
  # special mentions become words.
  defp slack(text) do
    text
    |> String.replace(~r/<!(here|channel|everyone)(?:\|[^>]*)?>/, "@\\1")
    |> String.replace(~r/<!subteam\^[^|>]+\|([^>]+)>/, "\\1")
    |> String.replace(~r/<!date\^[^|>]+\|([^>]+)>/, "\\1")
    |> String.replace(
      ~r/(^|[\s(])([*_~])(?=\S)([^*_~\n]+?)(?<=\S)\2(?=$|[\s.,;:!?)])/um,
      "\\1\\3"
    )
    |> String.replace(~r/`([^`\n]+)`/, "\\1")
    |> String.replace(~r/:([a-z0-9_+-]+):/, fn code ->
      case MDEx.parse_document(code, extension: [shortcodes: true]) do
        {:ok, %{nodes: [%MDEx.Paragraph{nodes: [%MDEx.ShortCode{emoji: emoji}]}]}} -> emoji
        _ -> code
      end
    end)
  end

  defp mail_quoted?(tag, attributes) do
    classes = String.split(attribute(attributes, "class") || "")

    tag == "blockquote" or attribute(attributes, "id") in @mail_quoted_ids or
      Enum.any?(classes, &(&1 in @mail_quoted_classes))
  end

  # Mail text ends where the earlier messages it quotes begin: a quoted line, an
  # attribution, possibly wrapped over two lines ("On …" then "… wrote:"), an
  # original-message rule, or a reply header ("From:" then "Sent:").
  defp own_words([line | rest]) do
    next = List.first(rest) || ""

    if Regex.match?(@mail_history, line) or
         Regex.match?(~r/^On .+ wrote:$/u, line <> " " <> next) or
         (Regex.match?(~r/^(?:From|发件人)[:：]/u, line) and
            Regex.match?(~r/^(?:Sent|Date|发送时间|时间|日期)[:：]/u, next)),
       do: [],
       else: [line | own_words(rest)]
  end

  defp own_words([]), do: []

  defp lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.replace(~r/[^\S\n]+/u, " ") |> String.trim()))
    |> Enum.reject(&(&1 in ["", "•"]))
  end

  defp plain(text) when is_binary(text) do
    case text |> escape() |> String.replace(~r/\s+/u, " ") |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  defp plain(_text), do: nil

  defp escape(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp bound(lines, budget) do
    lines
    |> Enum.reduce_while({[], budget}, fn line, {kept, left} ->
      cond do
        byte_size(line) <= left -> {:cont, {[line | kept], left - byte_size(line) - 1}}
        left > 0 -> {:halt, {[prefix(line, left) | kept], 0}}
        true -> {:halt, {kept, 0}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp prefix(text, bytes) do
    value = binary_part(text, 0, bytes)
    if String.valid?(value), do: value, else: prefix(text, bytes - 1)
  end
end
