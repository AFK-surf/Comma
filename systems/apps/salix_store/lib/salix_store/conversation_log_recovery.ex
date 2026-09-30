defmodule SalixStore.ConversationLogRecovery do
  @moduledoc """
  Coalesced discovery index for unfinished Conversation log consumption.

  Writers mark a fully prepared sequence before publishing the log tail.
  Recovery may remove only the observed target after publication and durable
  consumer progress. The row contains no Message payload or delivery outcome.
  """

  alias SalixStore.Repo

  def mark(group, conversation, seq, status_version \\ 0) do
    query(
      """
      INSERT INTO conversation_log_recovery (group_id, conversation_id, target_seq, due_at_ms, status_version)
      VALUES ($1, $2, $3, $4, $5)
      ON CONFLICT (group_id, conversation_id) DO UPDATE
      SET target_seq = GREATEST(conversation_log_recovery.target_seq, EXCLUDED.target_seq),
          status_version = GREATEST(conversation_log_recovery.status_version, EXCLUDED.status_version)
      """,
      [group, conversation, seq, System.system_time(:millisecond), status_version]
    )
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # The due index visits pending Conversations only. SKIP LOCKED lets pods
  # share discovery work. This reservation does not authorize delivery.
  def claim(limit, now \\ System.system_time(:millisecond)) when limit in 1..8 do
    query(
      """
      WITH pending AS (
        SELECT group_id, conversation_id FROM conversation_log_recovery
        WHERE due_at_ms <= $1
        ORDER BY due_at_ms, group_id, conversation_id
        LIMIT $2 FOR UPDATE SKIP LOCKED
      )
      UPDATE conversation_log_recovery AS r SET due_at_ms = $1 + 1000
      FROM pending AS p
      WHERE r.group_id = p.group_id AND r.conversation_id = p.conversation_id
      RETURNING r.group_id, r.conversation_id, r.target_seq, r.status_version
      """,
      [now, limit]
    )
    |> case do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [group, conversation, seq, status_version] ->
           %{
             group_id: group,
             conversation_id: conversation,
             target_seq: seq,
             status_version: status_version
           }
         end)}

      error ->
        error
    end
  end

  def complete(%{
        group_id: group,
        conversation_id: conversation,
        target_seq: seq,
        status_version: status_version
      }) do
    query(
      """
      DELETE FROM conversation_log_recovery
      WHERE group_id = $1 AND conversation_id = $2 AND target_seq = $3 AND status_version = $4
      """,
      [group, conversation, seq, status_version]
    )
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp query(sql, args) do
    Repo.query(sql, args)
  rescue
    _ -> {:error, :conversation_recovery_index_unavailable}
  catch
    :exit, _ -> {:error, :conversation_recovery_index_unavailable}
  end
end
