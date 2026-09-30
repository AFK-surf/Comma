defmodule SalixIM.Migrations.ConversationParticipantNotificationFilter do
  @moduledoc """
  One-shot migration to the canonical participant `notification_filter`.

  Discovery reads flat participant-state objects. Every mutation runs through
  the exact ConversationActor and ParticipantActor, preserving participant
  ownership. Every existing notification filter wins unchanged. Otherwise
  `wake_on_message` maps losslessly to `messages: all|none` with
  `statuses: none`. The legacy field is removed.
  """

  alias SalixIM.{ConversationFleet, ConversationServer}
  alias SalixStore.{Crypto, Ids, Keys, S3}

  @participant_re ~r|^ctl/group_conversations/([^/]+)/([^/]+)/participant_states/([^/]+)\.json$|
  @max_page 500

  def run(opts \\ []) do
    limit = min(max(opts[:limit] || @max_page, 1), @max_page)
    migrate_pages(opts[:continuation_token], limit, empty_stats())
  end

  defp migrate_pages(token, limit, total) do
    opts =
      [max_keys: limit] ++
        if(is_binary(token) and token != "", do: [continuation_token: token], else: [])

    case S3.list(Keys.ctl_group_conversations_prefix(), opts) do
      {:ok, %{objects: objects, next: next}} ->
        page =
          objects
          |> Enum.map(& &1.key)
          |> Enum.filter(&Regex.match?(@participant_re, &1))
          |> Enum.reduce(%{migrated: 0, skipped: 0, failed: []}, &migrate_key/2)

        total = merge_stats(total, page)

        cond do
          total.failed != [] ->
            {:error, {:participant_notification_filter_migration_failed, finish_stats(total)}}

          is_binary(next) and next != "" ->
            migrate_pages(next, limit, total)

          true ->
            {:ok, finish_stats(total)}
        end

      {:error, reason} ->
        {:error, {:participant_notification_filter_migration_failed, finish_stats(total, reason)}}
    end
  end

  defp migrate_key(key, stats) do
    case migrate_key(key) do
      :migrated -> Map.update!(stats, :migrated, &(&1 + 1))
      :skipped -> Map.update!(stats, :skipped, &(&1 + 1))
      {:error, reason} -> Map.update!(stats, :failed, &[{key, reason} | &1])
    end
  end

  defp migrate_key(key) do
    with [_, group_id, conversation_id, participant_hash] <-
           Regex.run(@participant_re, key),
         true <- Ids.valid_group_id?(group_id),
         true <- Ids.valid_conversation_id?(conversation_id),
         {:ok, %{body: body}} <- S3.get(key),
         {:ok, participant} when is_map(participant) <- Jason.decode(body),
         participant_id when is_binary(participant_id) <- participant["participant_id"],
         true <- Ids.valid_participant_id?(participant_id),
         true <- participant["conversation_id"] == conversation_id,
         true <- Crypto.hex(participant_id) == participant_hash do
      migrate_participant(group_id, conversation_id, participant_id)
    else
      false -> {:error, :invalid_participant_identity}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_participant_state_key}
    end
  end

  defp migrate_participant(group_id, conversation_id, participant_id) do
    case ConversationFleet.ensure_started(
           group_id,
           conversation_id,
           wake_on_recovery: false
         ) do
      {:ok, _pid} ->
        try do
          case ConversationServer.migrate_participant_notification_filter(
                 group_id,
                 conversation_id,
                 participant_id
               ) do
            :migrated -> :migrated
            :skipped -> :skipped
            {:error, reason} -> {:error, reason}
          end
        after
          ConversationFleet.stop(group_id, conversation_id)
        end

      {:error, :not_found} ->
        :skipped

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp empty_stats, do: %{migrated: 0, skipped: 0, pages: 0, failed: []}

  defp merge_stats(total, page) do
    %{
      migrated: total.migrated + page.migrated,
      skipped: total.skipped + page.skipped,
      pages: total.pages + 1,
      failed: total.failed ++ Enum.reverse(page.failed)
    }
  end

  defp finish_stats(stats, list_error \\ nil),
    do:
      stats
      |> Map.put(:list_error, list_error)
      |> Map.put(:complete, list_error == nil and stats.failed == [])
end
