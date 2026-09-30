defmodule BridgeForTeamsWeb.Dashboard.Components.SlackText do
  use Phoenix.Component
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  @tokens ~r/<(?:@[UW][A-Z0-9]{2,31}(?:\|[^>]*)?|https?:\/\/[^>]+)>/

  attr(:text, :string, default: "")
  attr(:mentions, :map, default: %{})

  def slack_text(assigns) do
    assigns = assign(assigns, :parts, parts(assigns.text || "", assigns.mentions))

    # The parent preserves whitespace; template indentation would become message text.
    ~H"""
    <span :for={part <- @parts} class="contents"><.link :if={part.kind == :link} href={part.url} target="_blank" rel="noopener noreferrer" class="text-blue-600 hover:underline">{part.text}</.link><span :if={part.kind == :mention} class="text-blue-700">{part.text}</span><span :if={part.kind == :text}>{part.text}</span></span>
    """
  end

  defp parts(text, mentions) do
    Regex.split(@tokens, text, include_captures: true, trim: true)
    |> Enum.map(fn token ->
      if Regex.run(@tokens, token) == [token],
        do: token_part(token, mentions),
        else: %{kind: :text, text: decode(token)}
    end)
  end

  defp token_part("<@" <> _ = token, mentions) do
    actor =
      token
      |> String.trim_leading("<@")
      |> String.trim_trailing(">")
      |> String.split("|")
      |> hd()

    label = mentions[actor]

    label =
      if is_binary(label) and label != "" and label != actor,
        do: label,
        else: gettext("Slack participant")

    %{kind: :mention, text: "@" <> String.trim_leading(label, "@")}
  end

  defp token_part("<http" <> _ = token, _mentions) do
    [url | label] =
      token
      |> String.trim_leading("<")
      |> String.trim_trailing(">")
      |> String.split("|", parts: 2)

    url = decode(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        %{kind: :link, url: url, text: decode(List.first(label) || url)}

      _ ->
        %{kind: :text, text: decode(token)}
    end
  end

  defp decode(text),
    do:
      text
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&amp;", "&")
end
