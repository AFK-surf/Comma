defmodule SalixAgent.IFC.Provenance do
  @moduledoc """
  Rule B of `docs/verification.md` §6.4: content that
  reached its destination by a *declassification* — a member answering in
  place, a requester's instruction, or a confirmed receipt — says where it
  came from.

  Pure flow adds nothing. The model's own text is never edited: the footer is
  composed by the runtime from the archived `Evidence` and appended as its
  own trailing block, the same way rich cards are runtime-owned. This is what
  makes "you asked here, so I answered here" visible to everyone in the
  destination and not only to the asker.
  """

  @declassified [:in_place, :instruction]

  @doc """
  The footer for one decision, or `nil` when every source flowed purely.

  `names` maps an encoded audience atom to its display name; a source whose
  origin has no display name is described by its kind, never by content.

  Composed by the runtime, so it is written in the Group's language rather
  than in whatever language the model was answering in (§6.4, §15).
  """
  @spec footer([String.t()], SalixAgent.IFC.language()) :: String.t() | nil
  def footer(names, language \\ :zh)

  def footer([], _language), do: nil

  def footer(names, :en) when is_list(names),
    do: "Includes information from " <> Enum.join(names, ", ")

  def footer(names, _zh) when is_list(names),
    do: "包含来自 " <> Enum.join(names, "、") <> " 的信息"

  @doc "The refs of the sources an evidence admitted by declassification."
  @spec declassified_refs(SalixIFC.Evidence.t()) :: [String.t()]
  def declassified_refs(%SalixIFC.Evidence{sources: sources}) do
    Enum.flat_map(sources, fn
      {ref, clause} when clause in @declassified -> [ref]
      {ref, {:receipt, _id}} -> [ref]
      _other -> []
    end)
  end

  def declassified_refs(_evidence), do: []

  @doc """
  Appends the footer to the outgoing text of one call.

  Only operations with an unambiguous text body carry it; for the others the
  decision and its evidence are still archived, and the adapter can render
  the footer natively later.
  """
  @spec apply(String.t(), map(), String.t() | nil) :: map()
  def apply(_name, args, nil), do: args
  def apply(_name, args, "") when is_map(args), do: args

  def apply(name, args, footer) when is_map(args) and is_binary(footer) do
    case text_key(name) do
      {:text, key} -> append_text(args, key, footer)
      :content_blocks -> append_content_block(args, footer)
      :none -> args
    end
  end

  def apply(_name, args, _footer), do: args

  defp text_key(name)
       when name in [
              "im_api.slack.post_message",
              "im_api.slack.reply_message",
              "im_api.slack.post_channel_message"
            ],
       do: {:text, "text"}

  defp text_key("im_api.slack.send_dm"), do: {:text, "text"}
  defp text_key("im_api.slack.update_message"), do: {:text, "text"}
  defp text_key("im_api.feishu.send_text"), do: {:text, "text"}
  defp text_key("im_api.feishu.reply_text"), do: {:text, "text"}
  defp text_key("im_api.telegram.send_message"), do: {:text, "text"}
  defp text_key("im_api.internal.send_message"), do: :content_blocks
  defp text_key(_name), do: :none

  defp append_text(args, key, footer) do
    case Map.get(args, key, Map.get(args, safe_atom(key))) do
      text when is_binary(text) and text != "" ->
        args
        |> Map.delete(safe_atom(key))
        |> Map.put(key, text <> "\n\n" <> footer)

      _other ->
        args
    end
  end

  defp append_content_block(args, footer) do
    case Map.get(args, "content", Map.get(args, :content)) do
      blocks when is_list(blocks) ->
        args
        |> Map.delete(:content)
        |> Map.put("content", blocks ++ [%{"type" => "text", "text" => footer}])

      _other ->
        args
    end
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
