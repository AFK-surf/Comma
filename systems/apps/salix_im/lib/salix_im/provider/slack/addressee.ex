defmodule SalixIM.Provider.Slack.Addressee do
  @moduledoc """
  Stateless Slack mention evidence shared by callback admission and Triage.

  Only the current message's text and blocks contribute recipients; forwarded
  attachments and thread history do not. This is syntactic addressing, not
  name resolution or a model inference. Thread ownership cannot override an
  explicit foreign-only recipient. An App Home DM already addresses this app.
  """

  @doc "Classifies provider IDs or projected principal refs in the same identity space."
  def classify(self_ref, mentioned_refs) do
    mentioned_refs = Enum.filter(mentioned_refs, &(is_binary(&1) and &1 != ""))

    case {self_ref in mentioned_refs, Enum.any?(mentioned_refs, &(&1 != self_ref))} do
      {true, true} -> "mixed"
      {true, false} -> "self"
      {false, true} -> "other"
      {false, false} -> "none"
    end
  end

  def for_event(connect, event) do
    self_ref = String.trim(to_string(connect["bot_user_id"] || ""))

    # The installed endpoint is already authoritative. Other candidates must
    # satisfy the same ID contract as Triage; literal <@abc-def> is not one.
    mentioned_refs =
      event
      |> mention_selectors()
      |> Map.keys()
      |> Enum.filter(&(&1 == self_ref or valid_provider_user_id?(&1)))

    classify(self_ref, mentioned_refs)
  end

  def valid_provider_user_id?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Z0-9_]+\z/, value)

  def mentions_self?(connect, event), do: for_event(connect, event) in ["self", "mixed"]

  def directed_elsewhere?(connect, event) do
    event["type"] in ["message", "app_mention"] and event["channel_type"] != "im" and
      for_event(connect, event) == "other"
  end

  @doc "Returns each mentioned provider ID with its source selectors for identity projection."
  def mention_selectors(message) do
    text_ids =
      ~r/<@([A-Za-z0-9_-]+)>/
      |> Regex.scan(recipient_text(to_string(message["text"] || "")), capture: :all_but_first)
      |> List.flatten()

    %{}
    |> put_selectors(text_ids, "text_token")
    |> put_selectors(rich_mention_ids(message["blocks"] || []), "rich_text_user")
  end

  # A terminal sending-tool attribution names the tool, not a recipient. Drop
  # only that occurrence; the same ID in the body or blocks still contributes.
  # Preserve ambiguous code/quote content and all rich-text evidence. This is
  # syntax recognition, not proof of the sending tool's identity or authority.
  defp recipient_text(text) do
    last_line = text |> String.trim_trailing() |> String.split("\n") |> List.last()

    if String.contains?(text, "`") or String.starts_with?(String.trim_leading(last_line), ">") do
      text
    else
      Regex.replace(~r/(?:\A|\s)\*Sent using\* <@[A-Z0-9_]+>\s*\z/, text, "")
    end
  end

  defp put_selectors(selectors, ids, source) do
    Enum.reduce(ids, selectors, fn id, acc ->
      if is_binary(id) and id != "" do
        Map.update(acc, id, MapSet.new([source]), &MapSet.put(&1, source))
      else
        acc
      end
    end)
  end

  defp rich_mention_ids(%{"type" => "user", "user_id" => id}), do: [id]
  defp rich_mention_ids(value) when is_list(value), do: Enum.flat_map(value, &rich_mention_ids/1)

  defp rich_mention_ids(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&rich_mention_ids/1)

  defp rich_mention_ids(_value), do: []
end
