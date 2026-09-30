defmodule CommaWeb.TelegramBot.Req do
  @moduledoc false

  @api_base "https://api.telegram.org"

  def send_message(token, chat_id, text),
    do: call(token, "sendMessage", %{"chat_id" => to_string(chat_id), "text" => text})

  def edit_device_view(token, chat_id, message_id, text, buttons),
    do:
      call(token, "editMessageText", %{
        "chat_id" => chat_id,
        "message_id" => message_id,
        "text" => text,
        "reply_markup" => %{"inline_keyboard" => Enum.map(buttons, &[&1])}
      })

  def answer_device_callback(token, callback_id, text),
    do: call(token, "answerCallbackQuery", %{"callback_query_id" => callback_id, "text" => text})

  def get_me(token), do: call(token, "getMe", %{})

  def send_task_links(token, chat_id, text, buttons),
    do:
      call(token, "sendMessage", %{
        "chat_id" => chat_id,
        "text" => text,
        "reply_markup" => %{"inline_keyboard" => Enum.map(buttons, &[&1])}
      })

  # Card and prompt text is HTML; callers escape user content.
  def send_card(token, chat_id, text, rows),
    do:
      call(token, "sendMessage", %{
        "chat_id" => chat_id,
        "text" => text,
        "parse_mode" => "HTML",
        "link_preview_options" => %{"is_disabled" => true},
        "reply_markup" => %{"inline_keyboard" => rows}
      })

  def edit_card(token, chat_id, message_id, text, rows),
    do:
      call(token, "editMessageText", %{
        "chat_id" => chat_id,
        "message_id" => message_id,
        "text" => text,
        "parse_mode" => "HTML",
        "link_preview_options" => %{"is_disabled" => true},
        "reply_markup" => %{"inline_keyboard" => rows}
      })

  def send_force_reply(token, chat_id, text),
    do:
      call(token, "sendMessage", %{
        "chat_id" => chat_id,
        "text" => text,
        "parse_mode" => "HTML",
        "reply_markup" => %{"force_reply" => true, "selective" => true}
      })

  def verify_private_chat_access(token, chat_id),
    do: call(token, "sendChatAction", %{"chat_id" => chat_id, "action" => "typing"})

  def set_webhook(token, url, secret) do
    call(token, "setWebhook", %{
      "allowed_updates" => ["message", "callback_query"],
      "drop_pending_updates" => false,
      "secret_token" => secret,
      "url" => url
    })
  end

  def get_webhook_info(token), do: call(token, "getWebhookInfo", %{})

  def set_commands(token, commands, language) do
    call(token, "setMyCommands", %{
      "commands" => commands,
      "scope" => %{"type" => "all_private_chats"},
      "language_code" => language
    })
  end

  def get_commands(token, language),
    do:
      call(token, "getMyCommands", %{
        "scope" => %{"type" => "all_private_chats"},
        "language_code" => language
      })

  def set_command_menu(token),
    do: call(token, "setChatMenuButton", %{"menu_button" => %{"type" => "commands"}})

  def get_menu_button(token), do: call(token, "getChatMenuButton", %{})

  defp call(token, method, body) do
    base =
      :comma_web
      |> Application.get_env(:telegram, [])
      |> Keyword.get(:api_base_url, @api_base)
      |> String.trim_trailing("/")

    case Req.post("#{base}/bot#{token}/#{method}",
           json: body,
           retry: false,
           redirect: false,
           receive_timeout: 2_000,
           connect_options: [timeout: 2_000]
         ) do
      {:ok, %{status: status, body: %{"ok" => true, "result" => result}}}
      when status in 200..299 ->
        {:ok, result}

      {:ok, %{status: 400, body: %{"description" => "Bad Request: message is not modified" <> _}}}
      when method == "editMessageText" ->
        {:ok, :unchanged}

      {:ok, %{status: status, body: %{"ok" => false, "error_code" => code}}}
      when status in 200..299 and is_integer(code) and code in 400..599 ->
        {:error, {:telegram_http_error, code}}

      {:ok, %{status: status}} ->
        {:error, {:telegram_http_error, status}}

      {:error, _reason} ->
        {:error, :telegram_unavailable}
    end
  end
end
