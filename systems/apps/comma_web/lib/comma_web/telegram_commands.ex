defmodule CommaWeb.TelegramCommands do
  @moduledoc "Product-owned private-chat commands and deterministic, localized guidance."

  @commands [
    {"start", "Get started with Comma", "开始使用 Comma"},
    {"help", "Show help and available commands", "查看帮助和可用命令"},
    {"status", "Show your connected workspace", "查看当前绑定的工作空间"},
    {"devices", "Browse connected devices", "查看设备列表与状态"},
    {"tasks", "Open recent tasks in Comma", "在 Comma 中打开最近任务"},
    {"disconnect", "Disconnect this Telegram account", "断开此 Telegram 账号"}
  ]

  def language(code) when is_binary(code) do
    primary = code |> String.downcase() |> String.split(["-", "_"]) |> hd()
    if primary == "zh", do: "zh", else: "en"
  end

  def language(_code), do: "en"

  def menu(code) do
    language = language(code)

    Enum.map(@commands, fn {command, en, zh} ->
      %{"command" => command, "description" => if(language == "zh", do: zh, else: en)}
    end)
  end

  def parse(text, bot_username) do
    text = String.trim(text)

    if String.starts_with?(text, "/") do
      case Regex.run(~r/^\/([A-Za-z0-9_]+)(?:@([A-Za-z0-9_]+))?(?:\s+(.*))?$/us, text) do
        [_, command | rest] ->
          mention = Enum.at(rest, 0, "")
          args = Enum.at(rest, 1, "") |> String.trim()

          if mention == "" or String.downcase(mention) == String.downcase(bot_username),
            do: {:command, String.downcase(command), args},
            else: :other_bot

        _other ->
          {:command, "unknown", ""}
      end
    else
      :message
    end
  end

  def help(code) do
    commands = Enum.map_join(menu(code), "\n", &"/#{&1["command"]} — #{&1["description"]}")
    message(:welcome, code) <> "\n\n" <> commands <> "\n\n" <> message(:link, code)
  end

  def message(kind, code, workspace \\ "") do
    {en, zh} =
      case kind do
        :welcome ->
          {"Welcome to Comma. Connect your workspace, then message your Comma assistant here.",
           "欢迎使用 Comma。连接工作空间后，就能在这里与你的 Comma 助手对话。"}

        :link ->
          {"Open Comma Settings → Channels → Telegram, choose a workspace and click Connect to sign in with Telegram.",
           "打开 Comma 设置 → 消息渠道 → Telegram，选择工作空间并点击连接，通过 Telegram 登录完成绑定。"}

        :connected ->
          {"Connected to Comma workspace “#{workspace}”. You can message Comma here now.",
           "已连接 Comma 工作空间「#{workspace}」。现在可以在这里与 Comma 对话。"}

        :tasks ->
          {"Recent tasks in “#{workspace}”", "「#{workspace}」的最近任务"}

        :tasks_hint ->
          {"Tap a number to open the Task in Comma.", "点击序号，在 Comma 中打开任务。"}

        :no_tasks ->
          {"No recent tasks to show in “#{workspace}”. Send Comma a request here to start work.",
           "「#{workspace}」暂无可展示的最近任务。可以在这里向 Comma 交代工作。"}

        :status ->
          {"Connected to Comma workspace “#{workspace}”.", "已连接 Comma 工作空间「#{workspace}」。"}

        :not_linked ->
          {"This Telegram account is not connected to Comma yet. Open Comma Settings → Channels → Telegram to connect.",
           "此 Telegram 账号尚未连接 Comma。请前往 Comma 设置 → 消息渠道 → Telegram 连接。"}

        :disconnected ->
          {"Telegram has been disconnected from Comma.", "此 Telegram 账号已与 Comma 断开连接。"}

        :unknown ->
          {"Unknown command or invalid arguments. Use /help to see available commands.",
           "未知命令或参数不正确。发送 /help 查看可用命令。"}
      end

    if language(code) == "zh", do: zh, else: en
  end
end
