defmodule SalixIM.TelegramCommands do
  @moduledoc """
  The task commands of a CFT Telegram bot: `/newgpttask` and `/newclaudetask`.

  `sync/1` writes them to the bot's command list (`setMyCommands`), so
  Telegram offers them when a person types a slash. It runs when a connect is
  created or gets a new token. The control commands (`/status`, `/compact`,
  `/help`) are not in the list: Telegram chats cannot run them
  (`SalixIM.ControlCommand`).

  `expand_message_text/3` gives the Router a task request in place of a
  command. Only a new message expands. An edited message does not, so an
  edit never creates a second task. A Comma product connect has no commands.
  """

  require Logger

  @commands [
    %{"command" => "newgpttask", "description" => "Create a Codex task"},
    %{"command" => "newclaudetask", "description" => "Create a Claude task"}
  ]

  @workers %{"newgpttask" => "Codex", "newclaudetask" => "Claude"}

  @command ~r/\A\/(newgpttask|newclaudetask)(?:@([A-Za-z0-9_]+))?(?:\s+(.*))?\z/si
  @addressed_command ~r/\A\/[A-Za-z0-9_]+@([A-Za-z0-9_]+)(?:\s|\z)/

  @doc """
  Writes the task commands to the bot of a connect. Returns `:error` on a
  failure and logs it; a connect is still created or updated.
  """
  @spec sync(map()) :: :ok | :error | :skipped
  def sync(%{"provider" => "telegram"} = connect) do
    token = text(connect["bot_token"])

    if connect["managed_by"] != "comma_product" and token != "" do
      base =
        :salix_im
        |> SystemsRuntime.get_env(:telegram_api_base_url, "https://api.telegram.org")
        |> text()
        |> case do
          "" -> "https://api.telegram.org"
          base -> String.trim_trailing(base, "/")
        end

      case Req.post("#{base}/bot#{token}/setMyCommands",
             json: %{"commands" => @commands},
             retry: false
           ) do
        {:ok, %{status: status, body: %{"ok" => true}}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: body}} ->
          Logger.warning("telegram_set_my_commands_failed",
            status: status,
            description: description(body)
          )

          :error

        {:error, reason} ->
          Logger.warning("telegram_set_my_commands_failed", reason: inspect(reason))
          :error
      end
    else
      :skipped
    end
  end

  def sync(_connect), do: :skipped

  @doc """
  The text the Router gets for a Telegram update: the task request when a new
  message is a task command for this bot, or `raw_text` as it is.
  """
  @spec expand_message_text(map(), map(), String.t()) :: String.t()
  def expand_message_text(connect, update, raw_text)
      when is_map(connect) and is_map(update) and is_binary(raw_text) do
    with true <- connect["managed_by"] != "comma_product",
         %{} <- update["message"],
         [_all, command | rest] <- Regex.run(@command, String.trim(raw_text)),
         false <- for_other_bot?(connect, Enum.at(rest, 0, "")) do
      expand(Map.fetch!(@workers, String.downcase(command)), command, Enum.at(rest, 1, ""))
    else
      _not_a_task_command -> raw_text
    end
  end

  def expand_message_text(_connect, _update, raw_text), do: raw_text

  @doc """
  Whether `text` is a slash command addressed to another bot
  (`/command@other_bot`). Such a command in a group does not wake this bot.
  """
  @spec for_other_bot_command?(map(), String.t()) :: boolean()
  def for_other_bot_command?(connect, text) when is_map(connect) and is_binary(text) do
    case Regex.run(@addressed_command, String.trim(text)) do
      [_all, target] -> for_other_bot?(connect, target)
      _none -> false
    end
  end

  def for_other_bot_command?(_connect, _text), do: false

  defp for_other_bot?(_connect, ""), do: false

  defp for_other_bot?(connect, target) do
    username = text(connect["bot_username"])
    username != "" and String.downcase(target) != String.downcase(username)
  end

  defp expand(worker, command, content) do
    case String.trim(content) do
      "" ->
        "The user sent /#{String.downcase(command)} without a task description. " <>
          "Reply briefly asking what #{worker} task they want to create, and create it once they reply."

      content ->
        "Create a task using a #{worker} worker. Task content: " <> content
    end
  end

  defp description(%{"description" => description}) when is_binary(description), do: description
  defp description(_body), do: ""

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_value), do: ""
end
