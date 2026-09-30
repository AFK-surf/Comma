defmodule SalixIM.Migrations.TaskGraphRetirement do
  @moduledoc "Bounded, owner-driven graph retirement with all writers stopped."

  alias SalixIM.{ConversationFleet, ConversationServer}
  alias SalixStore.{Ids, Keys, S3}

  @meta_re ~r|^ctl/group_conversations/([^/]+)/([^/]+)/meta\.json$|
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
          |> Enum.filter(&Regex.match?(@meta_re, &1))
          |> Enum.reduce(%{migrated: 0, skipped: 0, failed: []}, &migrate_key/2)

        total = merge_stats(total, page)

        cond do
          total.failed != [] ->
            {:error, {:task_graph_retirement_migration_failed, finish_stats(total)}}

          is_binary(next) and next != "" ->
            migrate_pages(next, limit, total)

          true ->
            {:ok, finish_stats(total)}
        end

      {:error, reason} ->
        {:error, {:task_graph_retirement_migration_failed, finish_stats(total, reason)}}
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
    with [_, group_id, conversation_id] <- Regex.run(@meta_re, key),
         true <- Ids.valid_group_id?(group_id),
         true <- Ids.valid_conversation_id?(conversation_id) do
      migrate_conversation(group_id, conversation_id)
    else
      false -> {:error, :invalid_conversation_identity}
      _ -> {:error, :invalid_conversation_meta_key}
    end
  end

  defp migrate_conversation(group_id, conversation_id) do
    case ConversationFleet.ensure_started(
           group_id,
           conversation_id,
           wake_on_recovery: false
         ) do
      {:ok, _pid} ->
        try do
          case ConversationServer.retire_task_graph(group_id, conversation_id) do
            {:ok, result} ->
              if result["inserted"] || result["migrated"], do: :migrated, else: :skipped

            {:error, :not_found} ->
              :skipped

            {:error, reason} ->
              {:error, reason}
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
