defmodule SalixIM.Migrations.ConversationPinsAggregate do
  @moduledoc """
  Offline hard cut from one object per pin to one bounded group aggregate.

  The destination is written through `ConversationGroupActor`, the same owner
  and CAS path used by serving traffic. The source object is conditionally
  deleted only after the destination command succeeds. Runtime code never reads
  the legacy layout, so this migration must complete with IM writers quiesced
  before the new release starts.
  """

  alias SalixIM.ConversationServer
  alias SalixStore.{Ids, Keys, S3}

  @prefix "ctl/conversation_pins/"
  @max_page 500

  def run(opts \\ []) do
    limit = min(max(opts[:limit] || @max_page, 1), @max_page)
    migrate_pages(valid_cursor(opts[:cursor]), limit, empty_stats())
  end

  defp migrate_pages(cursor, limit, total) do
    list_opts = [max_keys: limit] ++ if(cursor, do: [start_after: cursor], else: [])

    case S3.list(@prefix, list_opts) do
      {:ok, %{objects: objects}} ->
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
            {:error, {:conversation_pin_migration_failed, finish_stats(total)}}

          length(objects) == limit ->
            migrate_pages(List.last(objects).key, limit, total)

          true ->
            {:ok, finish_stats(total)}
        end

      {:error, reason} ->
        {:error, {:conversation_pin_migration_failed, finish_stats(total, reason)}}
    end
  end

  defp migrate_object(key) do
    if String.ends_with?(key, "/aggregate.json") do
      :skipped
    else
      with {:ok, %{body: body, etag: etag}} <- S3.get(key),
           {:ok, pin} when is_map(pin) <- Jason.decode(body),
           group_id when is_binary(group_id) <- pin["agent_group_id"],
           conversation_id when is_binary(conversation_id) <- pin["conversation_id"],
           true <- Ids.valid_group_id?(group_id),
           true <- Ids.valid_conversation_id?(conversation_id),
           true <- key == Keys.ctl_conversation_pin(group_id, conversation_id),
           :ok <- ConversationServer.import_conversation_pin(group_id, pin),
           :ok <- delete_source(key, etag) do
        :migrated
      else
        false -> {:error, :invalid_conversation_pin}
        {:error, reason} -> {:error, reason}
        _invalid -> {:error, :invalid_conversation_pin}
      end
    end
  end

  defp delete_source(key, etag) do
    case S3.delete(key, if_match: etag) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
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

  defp valid_cursor(cursor) when is_binary(cursor) do
    cursor = String.trim(cursor)
    if String.starts_with?(cursor, @prefix), do: cursor, else: nil
  end

  defp valid_cursor(_cursor), do: nil
end
