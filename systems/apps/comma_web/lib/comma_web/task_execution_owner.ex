defmodule CommaWeb.TaskExecutionOwner do
  @moduledoc false

  def authorize_owner(group_id, user_id) do
    case Comma.Workspaces.authorize_group(%{"id" => user_id}, nil, group_id) do
      {:ok, _workspace} -> :ok
      _ -> {:error, :task_execution_owner_invalid}
    end
  end

  # The fixed Comma Router chat belongs to the current personal Workspace owner.
  # Its generic IM participant is "current", not a provider/Comma identity.
  def conversation_members(group_id, conversation_id, "comma_user|" <> user_id = principal) do
    with {:ok, group} <- SalixIM.GroupDirectory.get_group(group_id),
         {:ok, ^conversation_id} <- SalixIM.ConversationIds.group_router(group),
         :ok <- authorize_owner(group_id, user_id) do
      [principal]
    else
      _ -> nil
    end
  end

  def conversation_members(_group_id, _conversation_id, _principal), do: nil

  # The product link is the authority for this alias. A provider room or a
  # different/unlinked private peer never inherits the Comma owner's audience.
  def direct_members(group_id, connect_id, [peer], "comma_user|" <> user_id = principal) do
    with {:ok, workspace} <- Comma.Workspaces.authorize_group(%{"id" => user_id}, nil, group_id),
         %{owner_user_id: ^user_id, connect_id: ^connect_id, telegram_user_id: ^peer} <-
           Comma.TelegramLinks.get_link(workspace["id"]),
         {:ok, %{"managed_by" => "comma_product", "managed_peer_id" => ^peer}} <-
           SalixIM.ProviderConnects.get_delegatable_connect_by_id(
             group_id,
             connect_id,
             "telegram"
           ) do
      [principal]
    else
      _ -> nil
    end
  end

  def direct_members(_group_id, _connect_id, _members, _principal), do: nil
end
