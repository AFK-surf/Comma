defmodule SalixIM.RouterConversationProjection do
  @moduledoc "Read-only projection for a group's fixed Router conversation."

  alias SalixIM.{ConversationIds, Conversations, GroupDirectory}

  @message_limit 200

  def get_group_router_conversation(group_id) do
    with {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, conversation_id} <- ConversationIds.group_router(group) do
      Conversations.get_group_conversation(group_id, conversation_id)
    end
  end

  def list_group_router_messages(group_id) do
    with {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, conversation_id} <- ConversationIds.group_router(group) do
      case Conversations.list_group_conversation_messages(group_id, conversation_id,
             tail: @message_limit
           ) do
        {:error, :not_found} -> {:ok, []}
        other -> other
      end
    end
  end
end
