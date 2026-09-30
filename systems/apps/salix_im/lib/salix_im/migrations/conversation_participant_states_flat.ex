defmodule SalixIM.Migrations.ConversationParticipantStatesFlat do
  @moduledoc """
  Offline, bounded migration of participant membership facts to the flat
  `participant_states/` projection.

  The migration walks every bounded S3 page, writes the destination first, and
  conditionally deletes the old nested state. Re-running is safe; any divergent
  destination or read/write failure fails the whole cutover.
  """

  alias SalixStore.{CasRecord, Crypto, Ids, Keys, S3}

  @prefix "ctl/group_conversations/"
  @old_state ~r|^ctl/group_conversations/([^/]+)/([^/]+)/participants/([^/]+)/state\.json$|
  @max_page 500

  def run(opts \\ []) do
    limit = min(max(opts[:limit] || @max_page, 1), @max_page)
    migrate_pages(valid_cursor(opts[:cursor]), limit, empty_stats())
  end

  defp migrate_pages(cursor, limit, total) do
    list_opts = [max_keys: limit] ++ if(cursor, do: [start_after: cursor], else: [])

    case S3.list(@prefix, list_opts) do
      {:ok, %{objects: objects, next: next}} ->
        page =
          Enum.reduce(objects, %{migrated: 0, skipped: 0, failed: []}, fn object, acc ->
            case migrate_object(object.key) do
              :migrated -> Map.update!(acc, :migrated, &(&1 + 1))
              :skipped -> Map.update!(acc, :skipped, &(&1 + 1))
              {:error, reason} -> Map.update!(acc, :failed, &[{object.key, reason} | &1])
            end
          end)

        total = merge_stats(total, page)

        cond do
          total.failed != [] ->
            {:error, {:participant_state_migration_failed, finish_stats(total)}}

          not is_nil(next) and objects == [] ->
            {:error,
             {:participant_state_migration_failed, finish_stats(total, :truncated_empty_page)}}

          not is_nil(next) ->
            migrate_pages(List.last(objects).key, limit, total)

          true ->
            {:ok, finish_stats(total)}
        end

      {:error, reason} ->
        {:error, {:participant_state_migration_failed, finish_stats(total, reason)}}
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

  defp migrate_object(key) do
    case Regex.run(@old_state, key) do
      [_, group_id, conversation_id, participant_hash] ->
        with true <- Ids.valid_group_id?(group_id),
             true <- Ids.valid_conversation_id?(conversation_id),
             {:ok, %{body: body, etag: etag}} <- S3.get(key),
             {:ok, participant} when is_map(participant) <- Jason.decode(body),
             participant_id when is_binary(participant_id) <- participant["participant_id"],
             true <- Crypto.hex(participant_id) == participant_hash,
             true <- participant["conversation_id"] == conversation_id,
             destination =
               Keys.ctl_group_conversation_participant_state(
                 group_id,
                 conversation_id,
                 participant_id
               ),
             {:ok, _} <-
               CasRecord.update(destination, fn
                 nil -> participant
                 ^participant -> {:unchanged, participant}
                 _divergent -> {:error, :participant_state_conflict}
               end),
             :ok <- delete_source(key, etag) do
          :migrated
        else
          false -> {:error, :invalid_participant_state}
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_participant_state}
        end

      _ ->
        :skipped
    end
  end

  defp delete_source(key, etag) do
    case S3.delete(key, if_match: etag) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_cursor(cursor) when is_binary(cursor) do
    cursor = String.trim(cursor)
    if String.starts_with?(cursor, @prefix), do: cursor, else: nil
  end

  defp valid_cursor(_cursor), do: nil
end
