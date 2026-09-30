defmodule CommaWeb.WeChatDeviceCommands do
  @moduledoc "Explicit read-only device commands after managed WeChat peer admission."

  def handle(connect, %{"item_list" => [%{"type" => 1}]} = message) do
    case parse(SalixIM.WeChatMessages.text_body(message, false), message) do
      nil ->
        :unhandled

      action ->
        text =
          with {:ok, %{user: user, workspace: workspace}} <-
                 Comma.WeChatLinks.resolve_sender(connect),
               {:ok, result} <-
                 Comma.ChatDevices.browse(user, workspace, connect["connect_id"], action) do
            result
            |> CommaWeb.ChatDeviceView.render(workspace, "zh")
            |> CommaWeb.ChatDeviceView.wechat_text()
          else
            _ -> "设备列表已过期或暂不可用。请发送「设备列表」重新查询。"
          end

        with {:ok, current} <-
               SalixIM.ProviderConnects.get_active_connect_by_id(
                 connect["group_id"],
                 connect["connect_id"],
                 "wechat"
               ),
             {:ok, _} <- Comma.WeChatLinks.resolve_sender(current),
             {:ok, _} <-
               SalixIM.Provider.WeChat.call(
                 nil,
                 Map.put(current, "latest_context_token", message["context_token"]),
                 "wechat.reply_text",
                 %{"text" => text}
               ) do
          :handled
        else
          {:error, :wechat_not_linked} -> :handled
          {:error, _} = error -> error
        end
    end
  end

  def handle(_connect, _message), do: :unhandled

  defp parse(text, message) do
    case String.trim(text) do
      value when value in ["设备列表", "/devices", "刷新设备"] ->
        "list"

      value ->
        case Regex.run(~r/^设备 ([A-Za-z0-9_-]{12}) ([1-6]|refresh|next|first)$/u, value) do
          [_, revision, action] -> revision <> ":" <> action
          _ -> quoted_action(value, message)
        end
    end
  end

  # A quoted list supplies navigation context only. The current text requests
  # the read, and browse/4 still checks the current owner, binding and Device.
  defp quoted_action(text, message) do
    choice =
      case text do
        value when value in ~w(1 2 3 4 5 6) -> value
        "下一页" -> "next"
        "刷新" -> "refresh"
        "列表" -> "refresh"
        "首页" -> "first"
        _ -> nil
      end

    quoted =
      message
      |> SalixIM.WeChatMessages.items()
      |> Enum.flat_map(fn item ->
        get_in(item, ["ref_msg", "resolved_items"]) || []
      end)

    if choice do
      case Regex.run(
             ~r/设备 ([A-F0-9]{12}) (?:[1-6]|refresh|next|first)/u,
             SalixIM.WeChatMessages.text_body(%{"item_list" => quoted}, false)
           ) do
        [_, revision] -> revision <> ":" <> choice
        _ -> nil
      end
    end
  end
end
