defmodule SalixStore.ConversationLogRecovery do
  @moduledoc """
  Coalesced discovery index for unfinished Conversation log consumption.

  Writers mark canonical targets in their source transaction.
  Recovery may remove only the observed target after publication and durable
  consumer progress. The row contains no Message payload or delivery outcome.
  """

  alias SalixStore.Repo

  @session_id "CASE WHEN a.role = 'router' THEN a.router_session_id ELSE p.session_id END"
  @agent """
  p.actor_type = 'agent' AND p.state IS DISTINCT FROM 'inactive'
    AND p.deleted_at IS NULL AND p.receives_messages IS DISTINCT FROM FALSE
    AND a.agent_id IS NOT NULL AND (#{@session_id}) IS NOT NULL
  """
  @retired "s.birth_kind = 'retired' OR s.deleted_at IS NOT NULL"
  @unfinished """
  (p.actor_type = 'provider'
    AND GREATEST(COALESCE(p.delivery_log_cursor_seq, 0), COALESCE(c.log_start_seq, 0)) < c.message_tail_seq)
  OR ((#{@agent}) AND NOT COALESCE((#{@retired}), FALSE)
    AND GREATEST(COALESCE(f.seq, 0), COALESCE(c.log_start_seq, 0), COALESCE(p.source_start_seq, 0))
        < c.message_tail_seq)
  """
  @consumer_scope """
  FROM salix_conversation_participants p
  LEFT JOIN salix_agents a ON a.agent_id = p.agent_id AND a.group_id = c.group_id
    AND a.config_revision > 0 AND a.archived_at IS NULL
  LEFT JOIN salix_sessions s ON s.agent_id = a.agent_id AND s.session_id = (#{@session_id})
  LEFT JOIN salix_session_sources f ON f.agent_id = a.agent_id AND f.session_id = (#{@session_id})
    AND f.participant_id = p.participant_id AND f.conversation_id = c.conversation_id
    AND f.generation = (#{@session_id})
  WHERE p.group_id = c.group_id AND p.conversation_id = c.conversation_id
  """

  @doc "Read one bounded canonical consumer snapshot without calling Participant or Session owners."
  def consumers(%{group_id: group, conversation_id: conversation}) do
    query(
      """
      SELECT CASE WHEN row_number() OVER (ORDER BY work.participant_id COLLATE "C") = 1 THEN c.metadata END,
             c.kind,c.updated_at,c.message_tail_seq,c.message_head_seq,c.log_start_seq,
             c.provider_status_version,c.membership_revision,c.deleted_at,
             CASE WHEN row_number() OVER (ORDER BY work.participant_id COLLATE "C") = 1 THEN tail.payload END,
             tail.seq,tail.message_id,tail.request_identity,tail.request_fingerprint,tail.revision,
             tail.tombstone,tail.archive_first_seq,archive.last_seq,archive.object_key,archive.encoding,
             work.participant_id,work.participant_payload,work.agent_payload,work.session_id,
             work.retired,work.unfinished
      FROM salix_conversations c
      LEFT JOIN LATERAL (
        SELECT p.participant_id,p.payload AS participant_payload,a.config_payload AS agent_payload,
               (#{@session_id}) AS session_id,
               ((#{@agent}) AND COALESCE((#{@retired}), FALSE)) AS retired,
               (#{@unfinished}) AS unfinished
        #{@consumer_scope}
          AND ((#{@unfinished}) OR ((#{@agent}) AND COALESCE((#{@retired}), FALSE)))
        ORDER BY p.participant_id COLLATE "C" LIMIT 200
      ) work ON TRUE
      LEFT JOIN salix_conversation_messages tail
        ON tail.group_id = c.group_id AND tail.conversation_id = c.conversation_id
           AND tail.seq = c.message_tail_seq AND NOT tail.tombstone
      LEFT JOIN salix_conversation_archives archive
        ON archive.group_id = c.group_id AND archive.conversation_id = c.conversation_id
           AND archive.first_seq = tail.archive_first_seq
      WHERE c.group_id=$1 AND c.conversation_id=$2 AND c.revision > 0
      ORDER BY work.participant_id COLLATE "C"
      """,
      [group, conversation]
    )
  end

  # The due index visits pending Conversations only. SKIP LOCKED lets pods
  # share discovery work. This reservation does not authorize delivery.
  def claim(limit, now \\ SystemsClock.system_time(:millisecond)) when limit in 1..8 do
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
      RETURNING r.group_id, r.conversation_id, r.target_seq, r.status_version, r.membership_revision
      """,
      [now, limit]
    )
    |> case do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [group, conversation, seq, status_version, membership] ->
           %{
             group_id: group,
             conversation_id: conversation,
             target_seq: seq,
             status_version: status_version,
             membership_revision: membership
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
        status_version: status_version,
        membership_revision: membership
      }) do
    query(
      """
      DELETE FROM conversation_log_recovery r
      WHERE r.group_id = $1 AND r.conversation_id = $2 AND r.target_seq = $3
        AND r.status_version = $4 AND r.membership_revision = $5
        AND NOT EXISTS (
          SELECT 1 FROM salix_conversations c
          WHERE c.group_id = r.group_id AND c.conversation_id = r.conversation_id
            AND c.deleted_at IS NULL
            AND (c.message_tail_seq <> $3 OR c.provider_status_version <> $4 OR c.membership_revision <> $5
                 OR EXISTS (SELECT 1 #{@consumer_scope} AND (#{@unfinished})))
        )
      """,
      [group, conversation, seq, status_version, membership]
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
