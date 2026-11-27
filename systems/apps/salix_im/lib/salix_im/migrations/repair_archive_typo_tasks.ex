defmodule SalixIM.Migrations.RepairArchiveTypoTasks do
  @moduledoc """
  Idempotent serving-node repair for `agent_task` Conversations whose canonical
  `status` was corrupted to the non-canonical typo `"archive"`.

  Discovery reads `salix_conversations` in PostgreSQL. Every write goes through
  `SalixIM.ConversationServer.update_group_conversation/3` so the Conversation
  owner, metadata, top-level status column, list timestamp, and projections stay
  on one serving write path.
  """

  alias SalixIM.ConversationServer
  alias SalixStore.Repo

  @default_limit 200
  @max_limit 500
  @allowed_targets ~w(completed cancelled failed ready_for_review escalated)

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run, true) != false
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    target_status = Keyword.get(opts, :target_status, "completed")
    group_id = Keyword.get(opts, :group_id)

    with :ok <- validate_target(target_status),
         {:ok, rows} <- find_candidates(group_id, limit) do
      if dry_run? do
        {:ok,
         %{
           "dry_run" => true,
           "target_status" => target_status,
           "candidates" => length(rows),
           "repaired" => 0,
           "failed" => [],
           "sample" => Enum.take(rows, 20)
         }}
      else
        {repaired, failed} =
          Enum.reduce(rows, {0, []}, fn %{"group_id" => gid, "conversation_id" => cid},
                                        {ok_count, errs} ->
            case ConversationServer.update_group_conversation(gid, cid, %{
                   "status" => target_status
                 }) do
              {:ok, %{"status" => ^target_status}} ->
                {ok_count + 1, errs}

              {:error, reason} ->
                {ok_count,
                 [
                   %{"group_id" => gid, "conversation_id" => cid, "error" => inspect(reason)}
                   | errs
                 ]}
            end
          end)

        {:ok,
         %{
           "dry_run" => false,
           "target_status" => target_status,
           "candidates" => length(rows),
           "repaired" => repaired,
           "failed" => Enum.reverse(failed)
         }}
      end
    end
  end

  defp validate_target(status) when status in @allowed_targets, do: :ok
  defp validate_target(other), do: {:error, {:invalid_target_status, other}}

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp clamp_limit(_), do: @default_limit

  defp find_candidates(group_id, limit) when is_binary(group_id) and group_id != "" do
    query_candidates(
      """
      SELECT group_id, conversation_id
      FROM salix_conversations
      WHERE revision > 0 AND deleted_at IS NULL AND kind = 'agent_task'
        AND status = 'archive' AND group_id = $1
      ORDER BY group_id ASC, conversation_id ASC
      LIMIT $2
      """,
      [group_id, limit]
    )
  end

  defp find_candidates(_group_id, limit) do
    query_candidates(
      """
      SELECT group_id, conversation_id
      FROM salix_conversations
      WHERE revision > 0 AND deleted_at IS NULL AND kind = 'agent_task'
        AND status = 'archive'
      ORDER BY group_id ASC, conversation_id ASC
      LIMIT $1
      """,
      [limit]
    )
  end

  defp query_candidates(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [gid, cid] -> %{"group_id" => gid, "conversation_id" => cid} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
