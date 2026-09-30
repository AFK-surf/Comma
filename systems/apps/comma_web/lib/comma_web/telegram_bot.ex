defmodule CommaWeb.TelegramBot do
  @moduledoc "Comma-owned Telegram bot operations with credentials kept server-side."

  def configured? do
    config = config()

    config[:enabled] == true and
      Enum.all?([:bot_token, :bot_username, :public_base_url, :webhook_secret], fn key ->
        nonblank?(config[key])
      end)
  end

  def bot_username, do: config()[:bot_username] |> to_string() |> String.trim_leading("@")
  def bot_url, do: "https://t.me/" <> bot_username()
  def bot_token, do: config()[:bot_token]

  def send_message(chat_id, text),
    do:
      CommaWeb.TelegramTelemetry.observe(:telegram_send_message, fn ->
        adapter().send_message(bot_token(), chat_id, text)
      end)

  def edit_device_view(chat_id, message_id, text, buttons),
    do:
      CommaWeb.TelegramTelemetry.observe(:telegram_send_message, fn ->
        adapter().edit_device_view(bot_token(), chat_id, message_id, text, buttons)
      end)

  def answer_device_callback(callback_id, text),
    do: adapter().answer_device_callback(bot_token(), callback_id, text)

  def get_me, do: adapter().get_me(bot_token())

  def send_task_links(chat_id, text, buttons),
    do:
      CommaWeb.TelegramTelemetry.observe(:telegram_send_message, fn ->
        adapter().send_task_links(bot_token(), chat_id, text, buttons)
      end)

  def send_card(chat_id, text, rows),
    do:
      CommaWeb.TelegramTelemetry.observe(:telegram_send_message, fn ->
        adapter().send_card(bot_token(), chat_id, text, rows)
      end)

  def edit_card(chat_id, message_id, text, rows),
    do:
      CommaWeb.TelegramTelemetry.observe(:telegram_send_message, fn ->
        adapter().edit_card(bot_token(), chat_id, message_id, text, rows)
      end)

  def send_force_reply(chat_id, text),
    do:
      CommaWeb.TelegramTelemetry.observe(:telegram_send_message, fn ->
        adapter().send_force_reply(bot_token(), chat_id, text)
      end)

  def verify_private_chat_access(chat_id),
    do: adapter().verify_private_chat_access(bot_token(), chat_id)

  def set_webhook(url, secret),
    do: adapter().set_webhook(bot_token(), url, secret)

  def get_webhook_info, do: adapter().get_webhook_info(bot_token())

  def set_commands(commands, language),
    do: adapter().set_commands(bot_token(), commands, language)

  def get_commands(language), do: adapter().get_commands(bot_token(), language)
  def set_command_menu, do: adapter().set_command_menu(bot_token())
  def get_menu_button, do: adapter().get_menu_button(bot_token())

  def verify_webhook_secret(presented) when is_binary(presented) do
    expected = config()[:webhook_secret]

    if nonblank?(expected) do
      Plug.Crypto.secure_compare(
        :crypto.hash(:sha256, presented),
        :crypto.hash(:sha256, expected)
      )
    else
      false
    end
  end

  def verify_webhook_secret(_presented), do: false

  def webhook_url,
    do:
      String.trim_trailing(config()[:public_base_url], "/") <> "/v1/comma/integrations/telegram/webhook"

  defp adapter, do: config()[:bot_adapter] || CommaWeb.TelegramBot.Req
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp config, do: Application.get_env(:comma_web, :telegram, [])
end
