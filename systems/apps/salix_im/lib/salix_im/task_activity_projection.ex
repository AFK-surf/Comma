defmodule SalixIM.TaskActivityProjection do
  @moduledoc "The two latest running or attention Tasks from canonical PostgreSQL rows."
  alias SalixIM.ConversationPGStore
  alias SalixStore.Repo

  def list(group_id) do
    case Repo.query(
           """
           SELECT conversation_id,metadata,kind,status,updated_at,message_tail_seq,
                  message_head_seq,log_start_seq,provider_status_version,membership_revision,deleted_at
           FROM salix_conversations
           WHERE group_id=$1 AND revision>0 AND deleted_at IS NULL AND kind='agent_task'
             AND status IN ('active','in_progress','running','working','needs_review',
                            'ready_for_review','escalated','review','waiting_for_review')
           ORDER BY COALESCE(updated_at,to_timestamp(0)) DESC,conversation_id COLLATE "C" DESC LIMIT 2
           """,
           [group_id]
         ) do
      {:ok, %{rows: rows}} ->
        records =
          Enum.map(rows, fn [
                              id,
                              payload,
                              kind,
                              status,
                              updated,
                              tail,
                              head,
                              start,
                              provider,
                              membership,
                              deleted
                            ] ->
            ConversationPGStore.decode_projection(group_id, id, payload, %{
              "kind" => kind,
              "status" => status,
              "updated_at" => updated,
              "message_tail_seq" => tail,
              "message_head_seq" => head,
              "log_start_seq" => start,
              "provider_status_version" => provider,
              "membership_revision" => membership,
              "deleted_at" => deleted
            })
          end)

        {:ok, %{"data" => records}}

      _ ->
        {:error, :unavailable}
    end
  end
end
