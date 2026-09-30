defmodule SalixIM.WeChatMarkdown do
  @moduledoc """
  Adapts complete replies to the Markdown subset used by Tencent's plugin.
  MDEx owns parsing and escaping. Code and supported formatting stay intact.
  Unsupported inline images are removed. Send visible images with reply_image.
  This adapter does not fetch URLs or promise client-side link previews.
  """

  @extensions [table: true, strikethrough: true, tasklist: true]
  @cjk ~r/[\x{2E80}-\x{9FFF}\x{AC00}-\x{D7AF}\x{F900}-\x{FAFF}]/u

  def render(text) when is_binary(text) do
    with {:ok, document} <- MDEx.parse_document(text, extension: @extensions) do
      document
      |> Map.update!(:nodes, &normalize/1)
      # Fences keep a first indented code block literal after MDEx trims output.
      |> MDEx.to_markdown(render: [prefer_fenced: true])
    end
  rescue
    _ -> {:error, "WeChat message formatting failed"}
  end

  defp normalize(nodes), do: Enum.flat_map(nodes, &normalize_node/1)

  defp normalize_node(%MDEx.Image{}), do: []

  defp normalize_node(%kind{nodes: nodes} = node)
       when kind in [MDEx.Link, MDEx.Strong, MDEx.Strikethrough] do
    case normalize(nodes) do
      [] -> []
      children -> [%{node | nodes: children}]
    end
  end

  defp normalize_node(%MDEx.Heading{level: level, nodes: nodes}) when level in [5, 6],
    do: [%MDEx.Paragraph{nodes: normalize(nodes)}]

  defp normalize_node(%MDEx.Emph{nodes: nodes} = emphasis) do
    children = normalize(nodes)

    if children == [] or Regex.match?(@cjk, content(children)),
      do: children,
      else: [%{emphasis | nodes: children}]
  end

  # WeChat treats raw HTML-like text as markup. Serialize it as literal text
  # instead of allowing a tag or comparison to hide the rest of the reply.
  defp normalize_node(%MDEx.HtmlInline{literal: literal}),
    do: [%MDEx.Text{literal: literal}]

  defp normalize_node(%MDEx.HtmlBlock{literal: literal}),
    do: [%MDEx.Paragraph{nodes: [%MDEx.Text{literal: literal}]}]

  defp normalize_node(%{nodes: nodes} = node), do: [%{node | nodes: normalize(nodes)}]
  defp normalize_node(node), do: [node]

  defp content(nodes) when is_list(nodes), do: Enum.map_join(nodes, &content/1)
  defp content(%{literal: literal}), do: literal
  defp content(%{nodes: nodes}), do: content(nodes)
  defp content(_), do: ""
end
