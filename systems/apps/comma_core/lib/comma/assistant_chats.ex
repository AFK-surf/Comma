defmodule Comma.AssistantChats do
  @moduledoc """
  Resolves the current Group's one fixed Router Conversation.

  Salix owns its identity, participants, transcript, and mutations. Comma only
  authorizes the exact Group and presents the canonical Conversation.
  """

  alias Comma.{Conversations, Workspaces}

  def ensure_chat(user, session, group_id, opts \\ []) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, conversation} <- ensure_router_conversation(workspace, opts) do
      {:ok, Conversations.present_canonical(workspace, conversation, user)}
    end
  end

  defp ensure_router_conversation(workspace, opts) do
    client = Comma.Salix.Client.impl()
    args = if Keyword.has_key?(opts, :message_limit), do: [workspace, opts], else: [workspace]

    if Code.ensure_loaded?(client) and
         function_exported?(client, :ensure_group_router_conversation, length(args)) do
      apply(client, :ensure_group_router_conversation, args)
    else
      {:error, :salix_router_conversation_not_supported}
    end
  end
end
