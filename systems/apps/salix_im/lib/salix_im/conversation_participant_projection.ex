defmodule SalixIM.ConversationParticipantProjection do
  @moduledoc """
  Bounded, fail-closed participant collection reads.

  Product adapters use this projection when they need the complete active
  participant set. The collection cap is part of the conversation contract,
  so callers do not implement their own pagination or partial-read fallbacks.
  """

  alias SalixIM.{ConversationLimits, Conversations}

  @participant_limit ConversationLimits.participant_limit()
  @page_limit ConversationLimits.participant_page_limit()

  def list_bounded(group_id, conversation_id),
    do: list_page(group_id, conversation_id, nil, [], MapSet.new())

  defp list_page(group_id, conversation_id, cursor, acc, seen_cursors) do
    opts =
      [limit: @page_limit]
      |> maybe_put_cursor(cursor)

    with {:ok, page} <-
           Conversations.list_group_conversation_participants(group_id, conversation_id, opts) do
      participants = acc ++ List.wrap(page["participants"])
      next_cursor = normalize_cursor(page["next_cursor"])

      cond do
        length(participants) > @participant_limit ->
          over_limit()

        next_cursor != "" and MapSet.member?(seen_cursors, next_cursor) ->
          {:error, :participant_cursor_repeated}

        next_cursor != "" and length(participants) < @participant_limit ->
          list_page(
            group_id,
            conversation_id,
            next_cursor,
            participants,
            MapSet.put(seen_cursors, next_cursor)
          )

        next_cursor != "" ->
          over_limit()

        page["has_more"] == true ->
          {:error, :participant_cursor_missing}

        true ->
          {:ok, participants}
      end
    end
  end

  defp over_limit,
    do: {:error, {:participant_collection_over_limit, @participant_limit}}

  defp maybe_put_cursor(opts, value) when value in [nil, ""], do: opts
  defp maybe_put_cursor(opts, value), do: Keyword.put(opts, :cursor, value)

  defp normalize_cursor(value) when is_binary(value), do: String.trim(value)
  defp normalize_cursor(_value), do: ""
end
