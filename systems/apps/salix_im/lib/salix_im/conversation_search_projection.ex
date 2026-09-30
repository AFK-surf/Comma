defmodule SalixIM.ConversationSearchProjection do
  @moduledoc """
  Bounded convergence from canonical Task state to the PostgreSQL projection.

  A rebuild reads only the latest 64 canonical Message slots. Each source
  segment is capped at 1 MiB, projected text is capped at 32 KiB per Message,
  and an atomic replacement writes at most 256 KiB of Message text plus a
  16-KiB title. Missing canonical metadata is never deletion authority. Claim
  application and physical projection deletion map to
  `tla/salix/ConversationTaskSearchQueue.tla`.
  """

  alias SalixIM.{ConversationMessage, Conversations}
  alias SalixStore.{ConversationSearch, SearchDocumentEnvelope}

  @group_page_limit 100

  @spec schedule_rebuild(String.t(), String.t()) :: :ok | {:error, :full | :unavailable}
  def schedule_rebuild(group_id, conversation_id),
    do: SalixIM.ConversationSearchEnqueuer.submit(:rebuild, group_id, conversation_id)

  @spec schedule_message(String.t(), String.t(), String.t(), pos_integer()) ::
          :ok | {:error, :full | :unavailable}
  def schedule_message(group_id, conversation_id, message_id, seq),
    do:
      SalixIM.ConversationSearchEnqueuer.submit_message(
        group_id,
        conversation_id,
        message_id,
        seq
      )

  @spec schedule_delete(String.t(), String.t()) :: :ok | {:error, :full | :unavailable}
  def schedule_delete(group_id, conversation_id),
    do: SalixIM.ConversationSearchEnqueuer.submit(:delete, group_id, conversation_id)

  @spec process_claim(ConversationSearch.claim()) :: :ok | {:error, term()}
  def process_claim(%{operation: :delete} = claim), do: ConversationSearch.apply_delete(claim)

  def process_claim(%{operation: :message} = claim) do
    case Conversations.get_group_conversation_record(
           claim.agent_group_id,
           claim.conversation_id
         ) do
      {:ok, %{"kind" => "agent_task"} = conversation} ->
        apply_exact_message(claim, conversation)

      {:ok, %{"kind" => "user_chat"}} ->
        ConversationSearch.apply_non_task(claim)

      {:ok, _invalid} ->
        {:error, :invalid_conversation_kind}

      {:error, :not_found} ->
        settle_missing_source(claim)

      {:error, _reason} = error ->
        error
    end
  end

  def process_claim(%{operation: :rebuild} = claim), do: rebuild(claim)

  @doc "Queue a bounded Task page for an explicit repair operation."
  @spec rebuild_group(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rebuild_group(group_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @group_page_limit)
    cursor = Keyword.get(opts, :cursor)

    with true <- Keyword.keys(opts) -- [:limit, :cursor] == [],
         true <- is_integer(limit) and limit in 1..@group_page_limit,
         {:ok, page} <-
           Conversations.list_group_conversations(
             group_id,
             limit: limit,
             cursor: cursor,
             kind: "agent_task"
           ),
         :ok <- enqueue_page(group_id, page["data"]) do
      {:ok,
       %{
         "queued" => length(page["data"]),
         "has_more" => page["has_more"],
         "next_cursor" => page["next_cursor"]
       }}
    else
      false -> {:error, {:bad_request, "invalid rebuild options"}}
      {:error, _reason} = error -> error
    end
  end

  defp apply_exact_message(claim, conversation) do
    snapshot = snapshot(conversation)

    case Conversations.get_group_conversation_message(
           claim.agent_group_id,
           claim.conversation_id,
           claim.source_id
         ) do
      {:ok, message} ->
        projected = project_message(message)

        if claim.source_seq == snapshot.message_tail_seq do
          case ConversationSearch.apply_message(claim, snapshot, projected) do
            {:error, :requires_rebuild} -> rebuild_task(claim, conversation, snapshot)
            result -> result
          end
        else
          rebuild_task(claim, conversation, snapshot)
        end

      {:error, :not_found} ->
        rebuild_task(claim, conversation, snapshot)

      {:error, _reason} = error ->
        error
    end
  end

  defp rebuild(claim) do
    case Conversations.get_group_conversation_record(
           claim.agent_group_id,
           claim.conversation_id
         ) do
      {:ok, %{"kind" => "agent_task"} = conversation} ->
        snapshot = snapshot(conversation)
        rebuild_task(claim, conversation, snapshot)

      {:ok, %{"kind" => "user_chat"}} ->
        ConversationSearch.apply_non_task(claim)

      {:ok, _invalid} ->
        {:error, :invalid_conversation_kind}

      {:error, :not_found} ->
        settle_missing_source(claim)

      {:error, _reason} = error ->
        error
    end
  end

  defp rebuild_task(claim, conversation, snapshot) do
    with {:ok, %{messages: messages}} <-
           Conversations.task_search_content_window(conversation),
         :ok <- ConversationSearch.replace_task(claim, snapshot, messages) do
      :ok
    end
  end

  defp settle_missing_source(claim) do
    case ConversationSearch.missing_source_safe_noop?(claim) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :live_projection_missing_canonical_source}
      {:error, _reason} = error -> error
    end
  end

  defp snapshot(conversation) do
    tail = conversation["message_tail_seq"] || conversation["message_count"] || 0
    head = conversation["message_head_seq"] || if(tail > 0, do: 1, else: 0)

    %{
      group_id: conversation["agent_group_id"],
      conversation_id: conversation["conversation_id"],
      title_envelope: SearchDocumentEnvelope.build(:title, conversation["title"]),
      mail_account_id: mail_ref(conversation, "connection_id"),
      mail_thread_id: mail_ref(conversation, "thread_id"),
      source_version: max(conversation["updated_at"] || conversation["created_at"] || 0, 0),
      message_head_seq: head,
      message_tail_seq: tail
    }
  end

  # Correlation metadata is never an authority to read a mailbox or mutate a Task.
  defp mail_ref(conversation, key) do
    case get_in(conversation, ["source_refs", "comma_mail", key]) do
      value when is_binary(value) and byte_size(value) in 1..256 -> value
      _ -> nil
    end
  end

  defp project_message(message) do
    content = ConversationMessage.visible_text(message)

    with {:ok, slot} <-
           SearchDocumentEnvelope.message_slot(%{
             id: message["message_id"],
             seq: message["seq"],
             created_at: message["created_at"],
             content: content
           }) do
      slot.message
    end
  end

  defp enqueue_page(group_id, conversations) do
    Enum.reduce_while(conversations, :ok, fn conversation, :ok ->
      case ConversationSearch.enqueue_rebuild(group_id, conversation["conversation_id"]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
