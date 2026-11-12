defmodule SalixIM.Provider.Lark.MessageRenderer do
  @moduledoc """
  Render ordinary Markdown as a Lark post. Lark owns Markdown layout.
  Task cards render as interactive cards (see `render_surface/2`).

  MDEx handles images and literal HTML without changing code nodes. Only
  structured mentions can notify. A mention goes where the text places it
  with `<at user_id="ID">name</at>`, else at the start; an at-tag for an ID
  not in `mentions` stays plain text. External images become links, without IO.
  `format: "text"` retains the explicit plain-text transport.
  """

  @behaviour SalixIM.MessageRenderer

  alias SalixIM.MessageRenderer.{Input, Surface}
  alias SalixIM.Provider.Util

  @post_limit 30 * 1024
  @text_limit 150 * 1024
  @markdown_options [
    extension: [table: true, tasklist: true, strikethrough: true, autolink: true]
  ]
  @image_key ~r/\Aimg_[A-Za-z0-9_-]+\z/
  # Slack IDs are 9+ uppercase characters with a digit; shorter tenant-defined
  # Lark user IDs such as `C001` stay valid.
  @slack_id ~r/\A(?:[UWCG](?=[A-Z]*[0-9])[A-Z0-9]{8,}|<[@#][^>]+>)\z/
  @at_open ~r/\A<at\s+user_id\s*=\s*"([^"<>]+)"\s*>\z/i
  @at_close ~r/\A<\/at\s*>\z/i
  @text_at ~r/<at\s+user_id\s*=\s*"([^"<>]+)"\s*>([^<]*)<\/at\s*>/i

  # Task cards use the Lark card JSON 2.0 schema with `update_multi`, so a
  # later PATCH updates the card for every chat member. Lark rejects a card
  # over 30 KB; these bounds leave room for the title, header and JSON.
  @card_output_bytes 18_000
  @card_details_bytes 6_000
  @title_chars 200
  @summary_chars 120

  @impl true
  def render(%Input{markdown: text}, opts) when is_binary(text) do
    format = Keyword.get(opts, :format) || "markdown"

    with :ok <- validate_source(text, format),
         {:ok, mentions} <- mentions(Keyword.get(opts, :mentions)),
         {:ok, content, placed} <-
           render_text(text, format, MapSet.new(mentions, & &1["user_id"])),
         mentions <-
           mentions
           |> Enum.reject(&MapSet.member?(placed, &1["user_id"]))
           |> maybe_mention_all(Keyword.get(opts, :mention_all)),
         {:ok, body} <- render_content(content, format, mentions),
         :ok <- validate_request(body) do
      {:ok, body}
    end
  end

  def render(%Input{}, _opts), do: {:error, "text must be a UTF-8 string"}

  @impl true
  def render_surface(%Surface{kind: :task_card} = surface, _opts) do
    title = surface.title |> to_string() |> String.trim() |> String.slice(0, @title_chars)
    label = surface.subtitle |> to_string() |> String.trim()

    if title == "" or label == "" or
         surface.status not in [:pending, :in_progress, :complete, :error] do
      {:error, :invalid_task_card_surface}
    else
      {:ok,
       %{
         "schema" => "2.0",
         "config" => %{
           "update_multi" => true,
           "summary" => %{
             "content" => surface.fallback |> to_string() |> String.slice(0, @summary_chars)
           }
         },
         "header" => %{
           "title" => %{"tag" => "plain_text", "content" => title},
           "template" => template(surface.status),
           "text_tag_list" => [
             %{
               "tag" => "text_tag",
               "text" => %{"tag" => "plain_text", "content" => label},
               "color" => tag_color(surface.status)
             }
           ]
         },
         "body" => %{"elements" => task_elements(surface, label)}
       }}
    end
  end

  def render_surface(%Surface{}, _opts), do: {:error, :unsupported_surface_kind}

  defp task_elements(surface, label) do
    details = markdown_text(surface.details, @card_details_bytes)
    output = markdown_text(surface.output, @card_output_bytes)

    elements =
      [
        if(details != "",
          do: %{"tag" => "markdown", "content" => details, "text_size" => "notation"}
        ),
        if(output != "", do: %{"tag" => "markdown", "content" => output})
      ]
      |> Enum.reject(&is_nil/1)

    # A card body needs at least one element.
    if elements == [],
      do: [%{"tag" => "markdown", "content" => label, "text_size" => "notation"}],
      else: elements
  end

  defp template(:pending), do: "grey"
  defp template(:in_progress), do: "blue"
  defp template(:complete), do: "green"
  defp template(:error), do: "red"

  defp tag_color(:pending), do: "neutral"
  defp tag_color(:in_progress), do: "blue"
  defp tag_color(:complete), do: "green"
  defp tag_color(:error), do: "red"

  # Card Markdown escapes angle brackets so model text cannot inject `<at>` tags.
  defp markdown_text(value, bytes) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace("<", "&#60;")
    |> String.replace(">", "&#62;")
    |> bounded(bytes)
  end

  defp bounded(text, bytes) when byte_size(text) <= bytes, do: text

  # Truncation can split an escape such as `&#60;`. Drop the broken tail.
  defp bounded(text, bytes) do
    text
    |> Util.truncate_utf8(bytes - byte_size("…"), "")
    |> String.replace(~r/&#\d{0,2}\z/, "")
    |> Kernel.<>("…")
  end

  # Call again after the provider adds the target, UUID and thread fields.
  @spec validate_request(map()) :: :ok | {:error, String.t()}
  # A question card (`SalixIM.QuestionCard`) is measured like a post.
  def validate_request(%{"msg_type" => type} = body)
      when type in ["post", "text", "interactive"] do
    limit = if type == "text", do: @text_limit, else: @post_limit
    size = byte_size(Jason.encode!(body))

    if size <= limit,
      do: :ok,
      else:
        {:error,
         "Lark #{type} request is #{size} bytes. Limit is #{limit} bytes. Split the message before sending."}
  end

  defp validate_source(text, format) do
    cond do
      format not in ["markdown", "text"] ->
        {:error, "format must be markdown or text"}

      not String.valid?(text) ->
        {:error, "text must be a UTF-8 string"}

      String.trim(text) == "" ->
        {:error, "text is required"}

      byte_size(text) > if(format == "text", do: @text_limit, else: @post_limit) ->
        {:error,
         "Lark #{format} source exceeds the request byte limit. Split the message before sending."}

      true ->
        :ok
    end
  end

  # Keep the at-tags of IDs in `mentions` where the text puts them; every
  # other at-tag shows as typed. Returns the content and the IDs placed.
  defp render_text(text, "text", ids) do
    {parts, placed} =
      Regex.split(@text_at, String.trim(text), include_captures: true)
      |> Enum.map_reduce(MapSet.new(), fn part, placed ->
        case Regex.run(@text_at, part) do
          [^part, id, name] ->
            if MapSet.member?(ids, id),
              do: {~s(<at user_id="#{id}">#{name}</at>), MapSet.put(placed, id)},
              else: {literal_text(part), placed}

          _ ->
            {literal_text(part), placed}
        end
      end)

    {:ok, Enum.join(parts), placed}
  end

  defp render_text(text, "markdown", ids) do
    with {:ok, document} <- MDEx.parse_document(text, @markdown_options) do
      state = %{changed?: false, ids: ids, open: nil, placed: MapSet.new(), unclosed?: false}
      {document, state} = MDEx.traverse_and_update(document, state, &safe_node/2)

      cond do
        state.unclosed? or state.open != nil ->
          {:error, ~s(Close each <at user_id="..."> tag with </at> in the same paragraph)}

        not state.changed? ->
          {:ok, text, state.placed}

        true ->
          case MDEx.to_markdown(document, @markdown_options) do
            {:ok, markdown} -> {:ok, markdown, state.placed}
            {:error, _} -> {:error, "Lark Markdown could not be rendered"}
          end
      end
    else
      {:error, _} -> {:error, "Lark Markdown could not be parsed"}
    end
  end

  defp render_content(text, "text", mentions) do
    text =
      (Enum.map(mentions, fn mention ->
         ~s(<at user_id="#{xml_escape(mention["user_id"])}">#{xml_escape(mention["user_name"])}</at>)
       end) ++ [text])
      |> Enum.join(" ")

    {:ok, %{"msg_type" => "text", "content" => Jason.encode!(%{"text" => text})}}
  end

  defp render_content(markdown, "markdown", mentions) do
    rows = if mentions == [], do: [], else: [mentions]
    content = %{"zh_cn" => %{"content" => rows ++ [[%{"tag" => "md", "text" => markdown}]]}}
    {:ok, %{"msg_type" => "post", "content" => Jason.encode!(content)}}
  end

  defp safe_node(%MDEx.Image{url: url, nodes: nodes} = node, state) do
    cond do
      Regex.match?(@image_key, url) ->
        {node, state}

      web_url?(url) ->
        {%MDEx.Link{
           url: url,
           title: "",
           nodes: [%MDEx.Text{literal: "Image: "} | image_label(nodes)]
         }, changed(state)}

      true ->
        {%MDEx.Text{literal: "[Image unavailable: #{plain_label(nodes)}]"}, changed(state)}
    end
  end

  # Native at/img extensions are HTML to CommonMark. Treat model-authored HTML
  # as visible text, including tags inside image labels. Code stays literal.
  # Only an at-tag pair for an ID in `mentions` stays a tag.
  defp safe_node(%MDEx.HtmlInline{literal: literal} = node, state) do
    case {state.open, Regex.run(@at_open, literal), Regex.match?(@at_close, literal)} do
      {nil, [_, id], _} ->
        if MapSet.member?(state.ids, id),
          do: {node, %{state | open: id}},
          else: {%MDEx.Text{literal: literal}, changed(state)}

      {id, _, true} when is_binary(id) ->
        {node, %{state | open: nil, placed: MapSet.put(state.placed, id)}}

      _ ->
        {%MDEx.Text{literal: literal}, changed(state)}
    end
  end

  defp safe_node(%MDEx.HtmlBlock{literal: literal}, state),
    do:
      {%MDEx.Paragraph{nodes: [%MDEx.Text{literal: String.trim_trailing(literal)}]},
       changed(block(state))}

  defp safe_node(%block{} = node, state)
       when block in [MDEx.Paragraph, MDEx.Heading, MDEx.TableCell, MDEx.CodeBlock],
       do: {node, block(state)}

  defp safe_node(node, state), do: {node, state}

  defp changed(state), do: %{state | changed?: true}

  # A block starting while an at-tag is open means the tag was never closed.
  defp block(%{open: nil} = state), do: state
  defp block(state), do: %{state | open: nil, unclosed?: true}

  defp image_label(nodes), do: [%MDEx.Text{literal: plain_label(nodes)}]

  defp plain_label(nodes) do
    label = Enum.map_join(nodes, &node_text/1)
    if String.trim(label) == "", do: "image", else: label
  end

  defp node_text(%{literal: literal}), do: literal
  defp node_text(%{nodes: nodes}), do: Enum.map_join(nodes, &node_text/1)
  defp node_text(_node), do: ""

  defp web_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _ ->
        false
    end
  end

  @doc """
  The user IDs a send's `mentions` and `mention_all` name, checked as a post
  checks them (`all` only through `mention_all`). A question card writes them
  as its at-tags.
  """
  @spec mention_ids(term(), term()) :: {:ok, [String.t()]} | {:error, String.t()}
  def mention_ids(mentions, mention_all) do
    with {:ok, mentions} <- mentions(mentions),
         do: {:ok, mentions |> maybe_mention_all(mention_all) |> Enum.map(& &1["user_id"])}
  end

  defp mentions(nil), do: {:ok, []}

  defp mentions(value) when is_binary(value),
    do: value |> String.split(",", trim: true) |> mentions()

  defp mentions(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case mention(value) do
        {:ok, node} -> {:cont, {:ok, [node | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, nodes |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp mentions(_), do: {:error, "mentions must be a list of {user_id, name} entries"}

  defp mention(id) when is_binary(id), do: mention(%{"user_id" => id})

  defp mention(value) when is_map(value) do
    value = Map.new(value, fn {key, val} -> {to_string(key), val} end)
    id = value["user_id"] || value["open_id"] || value["id"]
    name = value["name"] || "成员"

    cond do
      not is_binary(id) or String.trim(id) == "" or not String.valid?(id) ->
        {:error, "each Lark mention requires user_id"}

      String.downcase(String.trim(id)) == "all" ->
        {:error, "use mention_all=true instead of a user_id=all mention"}

      Regex.match?(@slack_id, String.trim(id)) ->
        {:error, "Resolve Slack identifiers to Lark user IDs before mentioning a person"}

      not is_binary(name) or not String.valid?(name) ->
        {:error, "each Lark mention name must be a UTF-8 string"}

      true ->
        name = if String.trim(name) == "", do: "成员", else: String.trim(name)
        {:ok, %{"tag" => "at", "user_id" => String.trim(id), "user_name" => name}}
    end
  end

  defp mention(_), do: {:error, "each Lark mention must be a user ID or {user_id, name} object"}

  defp maybe_mention_all(mentions, value) when value in [true, "true", 1, "1"],
    do: mentions ++ [%{"tag" => "at", "user_id" => "all", "user_name" => "所有人"}]

  defp maybe_mention_all(mentions, _), do: mentions

  # A text message shows entities such as `&lt;` as typed, so the text stays as
  # written. Only an at-tag is parsed: a zero-width space after its `<` keeps
  # model text from mentioning anyone.
  defp literal_text(text), do: String.replace(text, ~r/<(?=\/?at\b)/i, "<\u200B")

  defp xml_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
