defmodule CommaWeb.ProactiveDelivery do
  @moduledoc "Personal binding lookup for owner authority and Task status cards."
  alias SalixIM.ProviderConnects

  def principal_owner(group, connect_id, subject) do
    with {:ok, connect} <- ProviderConnects.get_active_connect_by_id(group, connect_id),
         "comma_product" <- connect["managed_by"] do
      case connect["provider"] do
        "telegram" ->
          with {:ok, %{link: link, user: user, workspace: workspace}} <-
                 Comma.TelegramLinks.resolve_sender(subject),
               true <- link.connect_id == connect_id and workspace["default_group_id"] == group,
               do: {:ok, user["id"]}

        "wechat" ->
          owner = connect["owner_user_id"]

          with true <- connect["wechat_id"] == subject and is_binary(owner),
               {:ok, workspace} <- Comma.Workspaces.authorize_group(%{"id" => owner}, %{}, group),
               {:ok, %{current: ^connect_id}} <- Comma.WeChatLinks.references(workspace["id"]),
               do: {:ok, owner}

        _ ->
          {:error, :comma_owner_authority_required}
      end
    else
      _ -> {:error, :comma_owner_authority_required}
    end
  end

  @doc """
  The owner's bound personal chats where the Router may send a reminder it
  decided on, as the exact reply tool and arguments. The server never sends
  through them. WeChat can only reply after the owner has written once since
  binding; until then its target is not `ready`. Credentials stay out.
  """
  def personal_targets(workspace, owner) do
    telegram =
      case telegram_target(workspace, owner) do
        {:ok, %{"connect_id" => connect, "chat_id" => chat}} ->
          [
            %{
              "provider" => "telegram",
              "tool" => "im_api.telegram.send_message",
              "connect_id" => connect,
              "chat_id" => chat,
              "ready" => true
            }
          ]

        _ ->
          []
      end

    telegram ++ wechat_target(workspace, owner)
  end

  defp wechat_target(workspace, owner) do
    with {:ok, %{current: id}} when is_binary(id) <- Comma.WeChatLinks.references(workspace["id"]),
         {:ok, %{"managed_by" => "comma_product", "owner_user_id" => ^owner} = connect} <-
           ProviderConnects.get_active_connect_by_id(workspace["default_group_id"], id, "wechat") do
      [
        %{
          "provider" => "wechat",
          "tool" => "im_api.wechat.reply_text",
          "connect_id" => id,
          "ready" =>
            is_binary(connect["latest_context_token"]) and connect["latest_context_token"] != ""
        }
      ]
    else
      _ -> []
    end
  end

  @doc "The owner's current bound Telegram private chat, shared with Task review cards."
  def telegram_target(workspace, owner) do
    case Comma.TelegramLinks.get_link(workspace["id"]) do
      nil ->
        {:ok, nil}

      %{owner_user_id: ^owner} = link ->
        case ProviderConnects.get_active_connect_by_id(
               workspace["default_group_id"],
               link.connect_id,
               "telegram"
             ) do
          {:ok, %{"managed_by" => "comma_product", "managed_peer_id" => peer}}
          when peer == link.telegram_user_id ->
            {:ok,
             %{
               "provider" => "telegram",
               "connect_id" => link.connect_id,
               "chat_id" => peer,
               "chat_type" => "private"
             }}

          {:error, :not_found} ->
            {:ok, nil}

          _ ->
            {:error, :telegram_link_inconsistent}
        end

      _ ->
        {:ok, nil}
    end
  end
end
