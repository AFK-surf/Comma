defmodule SalixIM.Provider.Feishu.MessageRenderer do
  @moduledoc """
  Render ordinary Markdown as a Feishu post. Feishu owns Markdown layout.
  Task cards render as interactive cards (see `render_surface/2`).

  MDEx handles images and literal HTML without changing code nodes. Only
  structured mentions can notify. External images become links, without IO.
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
  # Feishu user IDs such as `C001` stay valid.
  @slack_id ~r/\A(?:[UWCG](?=[A-Z]*[0-9])[A-Z0-9]{8,}|<[@#][^>]+>)\z/

  # Task cards use the Feishu card JSON 2.0 schema with `update_multi`, so a
  # later PATCH updates the card for every chat member. Feishu rejects a card
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
         mentions <- maybe_mention_all(mentions, Keyword.get(opts, :mention_all)),
         {:ok, body} <- render_content(text, format, mentions),
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
         "Feishu #{type} request is #{size} bytes. Limit is #{limit} bytes. Split the message before sending."}
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
         "Feishu #{format} source exceeds the request byte limit. Split the message before sending."}

      true ->
        :ok
    end
  end

  defp render_content(text, "text", mentions) do
    text =
      (Enum.map(mentions, fn mention ->
         ~s(<at user_id="#{xml_escape(mention["user_id"])}">#{xml_escape(mention["user_name"])}</at>)
       end) ++ [xml_escape(String.trim(text))])
      |> Enum.join(" ")

    {:ok, %{"msg_type" => "text", "content" => Jason.encode!(%{"text" => text})}}
  end

  defp render_content(text, "markdown", mentions) do
    with {:ok, document} <- MDEx.parse_document(text, @markdown_options) do
      {document, changed?} = MDEx.traverse_and_update(document, false, &safe_node/2)

      case if(changed?, do: MDEx.to_markdown(document, @markdown_options), else: {:ok, text}) do
        {:ok, markdown} ->
          rows = if mentions == [], do: [], else: [mentions]
          content = %{"zh_cn" => %{"content" => rows ++ [[%{"tag" => "md", "text" => markdown}]]}}
          {:ok, %{"msg_type" => "post", "content" => Jason.encode!(content)}}

        {:error, _} ->
          {:error, "Feishu Markdown could not be rendered"}
      end
    else
      {:error, _} -> {:error, "Feishu Markdown could not be parsed"}
    end
  end

  defp safe_node(%MDEx.Image{url: url, nodes: nodes} = node, changed?) do
    cond do
      Regex.match?(@image_key, url) ->
        {node, changed?}

      web_url?(url) ->
        {%MDEx.Link{
           url: url,
           title: "",
           nodes: [%MDEx.Text{literal: "Image: "} | image_label(nodes)]
         }, true}

      true ->
        {%MDEx.Text{literal: "[Image unavailable: #{plain_label(nodes)}]"}, true}
    end
  end

  # Native at/img extensions are HTML to CommonMark. Treat model-authored HTML
  # as visible text, including tags inside image labels. Code stays literal.
  defp safe_node(%MDEx.HtmlInline{literal: literal}, _changed?),
    do: {%MDEx.Text{literal: literal}, true}

  defp safe_node(%MDEx.HtmlBlock{literal: literal}, _changed?),
    do: {%MDEx.Paragraph{nodes: [%MDEx.Text{literal: String.trim_trailing(literal)}]}, true}

  defp safe_node(node, changed?), do: {node, changed?}

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
        {:error, "each Feishu mention requires user_id"}

      String.downcase(String.trim(id)) == "all" ->
        {:error, "use mention_all=true instead of a user_id=all mention"}

      Regex.match?(@slack_id, String.trim(id)) ->
        {:error, "Resolve Slack identifiers to Feishu user IDs before mentioning a person"}

      not is_binary(name) or not String.valid?(name) ->
        {:error, "each Feishu mention name must be a UTF-8 string"}

      true ->
        name = if String.trim(name) == "", do: "成员", else: String.trim(name)
        {:ok, %{"tag" => "at", "user_id" => String.trim(id), "user_name" => name}}
    end
  end

  defp mention(_), do: {:error, "each Feishu mention must be a user ID or {user_id, name} object"}

  defp maybe_mention_all(mentions, value) when value in [true, "true", 1, "1"],
    do: mentions ++ [%{"tag" => "at", "user_id" => "all", "user_name" => "所有人"}]

  defp maybe_mention_all(mentions, _), do: mentions

  defp xml_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
