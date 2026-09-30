defmodule BridgeForTeams.Migrations.ConversationIdentity do
  @moduledoc """
  Inventories and transactionally rewrites BFT-owned Salix conversation refs.
  """

  alias SalixStore.{ConversationIdMigration, Ids}

  @spec inventory_refs() :: {:ok, [map()]} | {:error, term()}
  def inventory_refs do
    Application.load(:bridge_for_teams_core)

    repos()
    |> Enum.reduce_while({:ok, []}, fn repo, {:ok, refs} ->
      case Ecto.Migrator.with_repo(repo, &inventory_repo/1) do
        {:ok, {:ok, repo_refs}, _started} ->
          {:cont, {:ok, repo_refs ++ refs}}

        {:ok, {:error, reason}, _started} ->
          {:halt, {:error, reason}}

        {:error, reason} ->
          {:halt, {:error, {:bft_conversation_identity_repo_failed, repo, reason}}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, merge_refs(refs)}
      {:error, _} = error -> error
    end
  end

  @spec run(map()) :: {:ok, map()} | {:error, term()}
  def run(maps) when is_map(maps) do
    Application.load(:bridge_for_teams_core)

    with {:ok, maps} <- ConversationIdMigration.normalize_all(maps),
         {:ok, true} <- ConversationIdMigration.phase_complete?(:s3, maps),
         {:ok, summaries} <- rewrite_repos(maps),
         :ok <- ConversationIdMigration.mark_phase_complete(:bft, maps) do
      {:ok, %{repos: summaries}}
    else
      {:ok, false} -> {:error, :conversation_identity_s3_phase_incomplete}
      {:error, _} = error -> error
    end
  end

  defp inventory_repo(repo) do
    repo.transaction(
      fn ->
        rows = assistant_chat_rows(repo) ++ workspace_item_rows(repo) ++ cursor_rows(repo)

        Enum.reduce_while(rows, [], fn row, refs ->
          case row_ref(row) do
            {:ok, ref} -> {:cont, [ref | refs]}
            {:error, reason} -> repo.rollback(reason)
          end
        end)
      end,
      timeout: :infinity
    )
  end

  defp row_ref(["workspace_items", row_id, group_id, conversation_id, _source_refs]) do
    row_ref(["workspace_items", row_id, group_id, conversation_id])
  end

  defp row_ref([_table, row_id, group_id, conversation_id | message_values]) do
    cond do
      not Ids.valid_group_id?(group_id) ->
        {:error, {:invalid_bft_conversation_group, row_id, group_id}}

      not is_binary(conversation_id) or conversation_id == "" ->
        {:error, {:invalid_bft_conversation_reference, row_id}}

      true ->
        {:ok,
         %{
           "group_id" => group_id,
           "conversation_id" => conversation_id,
           "message_ids" => collect_message_ids(message_values)
         }}
    end
  end

  defp rewrite_repos(maps) do
    Enum.reduce_while(repos(), {:ok, []}, fn repo, {:ok, summaries} ->
      case Ecto.Migrator.with_repo(repo, &rewrite_repo(&1, maps)) do
        {:ok, {:ok, summary}, _started} ->
          {:cont, {:ok, [summary | summaries]}}

        {:ok, {:error, reason}, _started} ->
          {:halt, {:error, reason}}

        {:error, reason} ->
          {:halt, {:error, {:bft_conversation_identity_repo_failed, repo, reason}}}
      end
    end)
    |> case do
      {:ok, summaries} -> {:ok, Enum.reverse(summaries)}
      {:error, _} = error -> error
    end
  end

  defp rewrite_repo(repo, maps) do
    repo.transaction(
      fn ->
        with {:ok, chats} <- rewrite_simple_rows(repo, assistant_chat_rows(repo), maps),
             {:ok, items} <- rewrite_workspace_items(repo, workspace_item_rows(repo), maps),
             {:ok, cursors} <- rewrite_cursors(repo, cursor_rows(repo), maps),
             :ok <- verify_repo(repo, maps) do
          %{assistant_chats: chats, workspace_items: items, cursors: cursors}
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end,
      timeout: :infinity
    )
  end

  defp rewrite_simple_rows(repo, rows, maps) do
    reduce_updates(rows, fn [table, id, group_id, conversation_id] ->
      with {:ok, map} <- ConversationIdMigration.resolve(maps, group_id, conversation_id),
           target <- get_in(map, ["conversation_id", "target"]) do
        if target == conversation_id do
          {:ok, :unchanged}
        else
          case repo.query("UPDATE #{table} SET conversation_id = $1 WHERE id::text = $2", [
                 target,
                 id
               ]) do
            {:ok, _} -> {:ok, :migrated}
            {:error, reason} -> {:error, {table, id, reason}}
          end
        end
      end
    end)
  end

  defp rewrite_workspace_items(repo, rows, maps) do
    reduce_updates(rows, fn [table, id, group_id, conversation_id, source_refs] ->
      with {:ok, map} <- ConversationIdMigration.resolve(maps, group_id, conversation_id) do
        target = get_in(map, ["conversation_id", "target"])
        rewritten_refs = rewrite_workspace_item_conversation_ref(source_refs, target)

        if target == conversation_id and rewritten_refs == source_refs do
          {:ok, :unchanged}
        else
          case repo.query(
                 "UPDATE #{table} SET salix_conversation_id = $1, source_refs = $2 WHERE id::text = $3",
                 [target, rewritten_refs, id]
               ) do
            {:ok, _} -> {:ok, :migrated}
            {:error, reason} -> {:error, {table, id, reason}}
          end
        end
      end
    end)
  end

  defp rewrite_cursors(repo, rows, maps) do
    reduce_updates(rows, fn
      [table, id, group_id, conversation_id, last_seen, catchup_after, pending, reconciled] ->
        with {:ok, map} <- ConversationIdMigration.resolve(maps, group_id, conversation_id) do
          values = [
            get_in(map, ["conversation_id", "target"]),
            rewrite_message_id(last_seen, map),
            rewrite_message_id(catchup_after, map),
            Enum.map(pending || [], &rewrite_message_id(&1, map)),
            Enum.map(reconciled || [], &rewrite_message_id(&1, map))
          ]

          if values == [
               conversation_id,
               last_seen,
               catchup_after,
               pending || [],
               reconciled || []
             ] do
            {:ok, :unchanged}
          else
            case repo.query(
                   """
                   UPDATE #{table}
                   SET salix_conversation_id = $1,
                       last_seen_message_id = $2,
                       catchup_after_message_id = $3,
                       pending_followup_message_ids = $4,
                       reconciled_followup_message_ids = $5
                   WHERE id::text = $6
                   """,
                   values ++ [id]
                 ) do
              {:ok, _} -> {:ok, :migrated}
              {:error, reason} -> {:error, {table, id, reason}}
            end
          end
        end
    end)
  end

  defp reduce_updates(rows, fun) do
    Enum.reduce_while(rows, {:ok, %{migrated: 0, unchanged: 0}}, fn row, {:ok, stats} ->
      case fun.(row) do
        {:ok, status} when status in [:migrated, :unchanged] ->
          {:cont, {:ok, increment(stats, status)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_repo(repo, maps) do
    rows = assistant_chat_rows(repo) ++ workspace_item_rows(repo) ++ cursor_rows(repo)

    Enum.reduce_while(rows, :ok, fn row, :ok ->
      [_table, id, group_id, conversation_id | message_values] = row

      with true <- Ids.valid_conversation_id?(conversation_id),
           {:ok, map} <- ConversationIdMigration.resolve(maps, group_id, conversation_id),
           true <- conversation_id == get_in(map, ["conversation_id", "target"]),
           true <- row_conversation_refs_canonical?(row, map),
           true <- all_message_ids_canonical?(row_message_values(row, message_values)) do
        {:cont, :ok}
      else
        false ->
          {:halt, {:error, {:bft_conversation_identity_verify_failed, id}}}

        {:error, reason} ->
          {:halt, {:error, {:bft_conversation_identity_verify_failed, id, reason}}}
      end
    end)
  end

  defp assistant_chat_rows(repo) do
    repo.query!("""
    SELECT 'user_assistant_chats', chat.id::text, project.salix_group_id, chat.conversation_id
    FROM user_assistant_chats AS chat
    JOIN projects AS project ON project.id = chat.project_id
    """).rows
  end

  defp workspace_item_rows(repo) do
    repo.query!("""
    SELECT 'workspace_items', item.id::text, project.salix_group_id,
           item.salix_conversation_id, item.source_refs
    FROM workspace_items AS item
    JOIN projects AS project ON project.id = item.project_id
    WHERE item.salix_conversation_id IS NOT NULL AND item.salix_conversation_id <> ''
    """).rows
  end

  defp cursor_rows(repo) do
    repo.query!("""
    SELECT 'workspace_item_conversation_cursors', cursor.id::text, project.salix_group_id,
           cursor.salix_conversation_id, cursor.last_seen_message_id,
           cursor.catchup_after_message_id, cursor.pending_followup_message_ids,
           cursor.reconciled_followup_message_ids
    FROM workspace_item_conversation_cursors AS cursor
    JOIN projects AS project ON project.id = cursor.project_id
    """).rows
  end

  defp merge_refs(refs) do
    refs
    |> Enum.group_by(&{&1["group_id"], &1["conversation_id"]})
    |> Enum.map(fn {{group_id, conversation_id}, grouped} ->
      %{
        "group_id" => group_id,
        "conversation_id" => conversation_id,
        "message_ids" =>
          grouped |> Enum.flat_map(& &1["message_ids"]) |> Enum.uniq() |> Enum.sort()
      }
    end)
    |> Enum.sort_by(&{&1["group_id"], &1["conversation_id"]})
  end

  defp collect_message_ids(values) do
    values
    |> Enum.flat_map(fn
      value when is_binary(value) and value != "" -> [value]
      value when is_list(value) -> Enum.filter(value, &(is_binary(&1) and &1 != ""))
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp rewrite_workspace_item_conversation_ref(source_refs, target)
       when is_map(source_refs) and is_binary(target) do
    case source_refs["conversation_id"] do
      value when is_binary(value) and value != "" ->
        Map.put(source_refs, "conversation_id", target)

      _ ->
        source_refs
    end
  end

  defp rewrite_workspace_item_conversation_ref(source_refs, _target), do: source_refs

  defp row_conversation_refs_canonical?(
         ["workspace_items", _id, _group_id, _conversation_id, source_refs],
         map
       )
       when is_map(source_refs) do
    source_refs["conversation_id"] in [nil, "", get_in(map, ["conversation_id", "target"])]
  end

  defp row_conversation_refs_canonical?(_row, _map), do: true

  defp row_message_values(["workspace_items" | _rest], _message_values), do: []
  defp row_message_values(_row, message_values), do: message_values

  defp rewrite_message_id(nil, _map), do: nil

  defp rewrite_message_id(message_id, map) when is_binary(message_id) do
    targets = map["message_ids"] || %{}
    targets[message_id] || message_id
  end

  defp all_message_ids_canonical?(values) do
    values
    |> collect_message_ids()
    |> Enum.all?(&Ids.valid_message_id?/1)
  end

  defp increment(stats, key), do: Map.update!(stats, key, &(&1 + 1))
  defp repos, do: Application.fetch_env!(:bridge_for_teams_core, :ecto_repos)
end
