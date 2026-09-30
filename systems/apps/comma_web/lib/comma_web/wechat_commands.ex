defmodule CommaWeb.WeChatCommands do
  @moduledoc "Read-only commands from the current Comma-managed WeChat peer."

  alias Comma.{Conversations, WeChatLinks}
  alias SalixIM.{ProviderConnects, WeChatMessages}

  @task_commands ["任务列表", "查看任务列表", "/tasks"]

  def handle(connect, %{"item_list" => [%{"type" => 1}]} = message) do
    text = message |> WeChatMessages.text_body(false) |> String.trim()

    if text in @task_commands do
      send_tasks(connect, message)
    else
      CommaWeb.WeChatDeviceCommands.handle(connect, message)
    end
  end

  def handle(connect, message), do: CommaWeb.WeChatDeviceCommands.handle(connect, message)

  defp send_tasks(connect, message) do
    with {:ok, current} <-
           ProviderConnects.get_active_connect_by_id(
             connect["group_id"],
             connect["connect_id"],
             "wechat"
           ),
         {:ok, %{user: user, workspace: workspace}} <- WeChatLinks.resolve_sender(current),
         {:ok, page} <-
           Conversations.list_page(user, %{}, workspace["default_group_id"], limit: 8),
         {:ok, _} <-
           SalixIM.Provider.WeChat.call(
             nil,
             Map.put(current, "latest_context_token", message["context_token"]),
             "wechat.reply_text",
             %{"text" => task_list_text(page["data"], workspace)}
           ) do
      :handled
    else
      {:error, :wechat_not_linked} -> :handled
      {:error, _} = error -> error
    end
  end

  defp task_list_text(tasks, workspace) do
    list =
      case tasks do
        [] ->
          "暂无任务。"

        tasks ->
          titles =
            tasks
            |> Enum.with_index(1)
            |> Enum.map_join("\n", fn {task, index} ->
              "#{index}. #{String.slice(task["title"] || "Task", 0, 64)}"
            end)

          "最近任务：\n" <> titles
      end

    query =
      URI.encode_query(%{
        "group_id" => workspace["default_group_id"],
        "workspace_id" => workspace["id"]
      })

    origin = Application.fetch_env!(:comma_web, :web_cookie_origin) |> String.trim_trailing("/")
    url = origin <> "/task-panel.html?" <> query

    list <> "\n\n[查看全部任务](" <> url <> ")\n打开后请使用 Comma 账号登录。"
  end
end
