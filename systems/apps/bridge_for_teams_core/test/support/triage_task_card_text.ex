defmodule BridgeForTeams.TriageTaskCardText do
  @moduledoc """
  Test-only ordered text observation of Comma's native Slack Task-card payload.

  This is not a Slack UI renderer or a general Block Kit parser. Keep repeated
  inline words and fail on unknown shapes; search-index deduplication is not a
  faithful observation of a diagnostic sentence. Raw wire blocks are retained
  separately by the live probe.
  """

  def render!(%{"blocks" => blocks} = params) when is_list(blocks) and blocks != [] do
    Enum.join([params["text"] || "" | Enum.map(blocks, &task!/1)], "\n")
  end

  # Observe the native field itself: fallback text or earlier details containing
  # the answer cannot stand in for the card's current main output.
  def main_output!(%{"blocks" => [%{"type" => "task_card", "output" => output}]})
      when is_map(output),
      do: output

  def output_for_content!(content) do
    # The oracle is the complete canonical answer, not the production
    # projection's clipping behavior. Applying the same slice here hides lost
    # conclusions, qualifications and source links in long Worker results.
    output =
      content
      |> SalixIM.ConversationMessage.text_content()
      |> String.trim()

    {:ok, rendered} =
      SalixIM.MessageRenderer.render_surface(
        SalixIM.Provider.Slack.MessageRenderer,
        %SalixIM.MessageRenderer.Surface{
          kind: :task_card,
          id: "observed-worker-output",
          title: "Worker result",
          status: :complete,
          fallback: "Worker result",
          output: output
        }
      )

    main_output!(%{"blocks" => rendered.blocks})
  end

  defp task!(%{"type" => "task_card", "title" => title, "status" => status} = card) do
    [title, status, rich!(card["details"]), rich!(card["output"])]
    |> Kernel.++(Enum.map(Map.get(card, "sources", []), &source!/1))
    |> Enum.join("\n")
  end

  defp source!(%{"type" => "url", "text" => text, "url" => url}),
    do: text <> " (" <> url <> ")"

  defp rich!(nil), do: ""

  defp rich!(%{"type" => "rich_text", "elements" => elements}),
    do: Enum.map_join(elements, "\n", &section!/1)

  defp section!(%{"type" => type, "elements" => elements})
       when type in ["rich_text_section", "rich_text_preformatted"],
       do: Enum.map_join(elements, &inline!/1)

  defp section!(%{"type" => "rich_text_quote", "elements" => elements}),
    do: "> " <> Enum.map_join(elements, &inline!/1)

  defp section!(%{"type" => "rich_text_list", "elements" => elements} = list) do
    elements
    |> Enum.with_index(Map.get(list, "offset", 0) + 1)
    |> Enum.map_join("\n", fn {element, index} ->
      marker = if list["style"] == "ordered", do: "#{index}. ", else: "- "
      marker <> section!(element)
    end)
  end

  # A crossed-out claim is not equivalent to endorsing the same words.
  defp inline!(%{"style" => %{"strike" => true}} = element),
    do: "~~" <> inline!(Map.delete(element, "style")) <> "~~"

  defp inline!(%{"type" => "text", "text" => text}), do: text
  defp inline!(%{"type" => "link", "text" => text}), do: text
  defp inline!(%{"type" => "link", "url" => url}), do: url
end
