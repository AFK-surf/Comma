defmodule CommaWeb.TelegramIntegration do
  @moduledoc """
  Comma product orchestration for one Telegram private chat per Workspace.
  Modeled in tla/salix/CommaTelegramBinding.tla: retire, prepare disabled,
  commit binding, activate; no atomic cross-store rollback is claimed.
  """

  alias Comma.{TelegramLinks, Workspaces}
  alias CommaWeb.{TelegramBot, TelegramCommands, TelegramOIDC, TelegramTaskCards}
  alias SalixIM.{ProviderConnects, ProviderHTTP}

  def state(user, session, workspace_id) do
    with {:ok, workspace, link} <- TelegramLinks.get(user, session, workspace_id) do
      configured? = TelegramBot.configured?()

      {:ok,
       %{
         "bot_url" => if(configured?, do: TelegramBot.bot_url()),
         "bot_username" => if(configured?, do: TelegramBot.bot_username()),
         "configured" => configured?,
         "link" => TelegramLinks.public_link(link),
         "connection_active" => connection_active?(workspace, link),
         "official_login_available" => TelegramOIDC.configured?(),
         "pending_claim" => nil,
         "workspace_id" => workspace["id"],
         "workspace_name" => workspace["name"]
       }}
    end
  end

  defp connection_active?(_workspace, nil), do: false

  defp connection_active?(workspace, link) do
    case ProviderConnects.get_active_connect_by_id(
           workspace["default_group_id"],
           link.connect_id,
           "telegram"
         ) do
      {:ok, connect} ->
        managed_connect_matches?(connect, workspace, %{"id" => link.telegram_user_id})

      _ ->
        false
    end
  end

  def start_connect(user, session, workspace_id, environment \\ nil),
    do: TelegramOIDC.start(user, session, workspace_id, environment)

  def disconnect(user, session, workspace_id) do
    TelegramLinks.with_lifecycle_lock(fn ->
      with {:ok, workspace, link} <- TelegramLinks.get(user, session, workspace_id),
           :ok <- retire_link(link, workspace),
           {:ok, _workspace, removed?} <- TelegramLinks.delete(user, session, workspace_id) do
        {:ok, %{"disconnected" => removed?}}
      end
    end)
  end

  def complete_connect(code, state) do
    with :ok <- require_bot(),
         {:ok, result} <- TelegramOIDC.complete(code, state),
         {:ok, _} <- TelegramBot.verify_private_chat_access(result.identity["id"]),
         {:ok, link} <-
           link_identity(result.user, result.workspace, result.identity, result.attempt) do
      _ =
        TelegramBot.send_message(
          result.identity["id"],
          "Telegram is now connected to Comma workspace “#{result.workspace["name"]}”."
        )

      {:ok, Map.put(TelegramLinks.public_link(link), "workspace_id", result.workspace["id"])}
    end
  end

  def handle_webhook(update) when is_map(update) do
    with :ok <- require_bot(),
         {:ok, message, identity} <- private_user_message(update) do
      if Map.has_key?(update, "callback_query"),
        do: handle_callback(update, identity),
        else: handle_message(update, message, identity)
    else
      {:error, :ignored} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def handle_webhook(_update), do: {:error, :invalid_telegram_update}

  defp handle_message(update, %{"text" => text} = message, identity) when is_binary(text) do
    case TelegramCommands.parse(text, TelegramBot.bot_username()) do
      {:command, "link", _args} ->
        reply(identity, :link)

      {:command, command, _args} when command in ["start", "help"] ->
        best_effort_message(identity["id"], TelegramCommands.help(identity["language_code"]))

      {:command, "status", ""} ->
        send_status(identity)

      {:command, "devices", ""} ->
        send_devices(identity, "list", nil)

      {:command, "tasks", ""} ->
        send_tasks(identity)

      {:command, "disconnect", ""} ->
        disconnect_from_telegram(identity)

      {:command, _command, _args} ->
        reply(identity, :unknown)

      :other_bot ->
        :ok

      :message ->
        card_reply(update, message, text, identity)
    end
  end

  defp handle_message(update, _message, identity), do: deliver_or_onboard(update, identity)

  defp handle_callback(%{"callback_query" => %{"data" => "cd:" <> action} = callback}, identity) do
    # The webhook authenticated the bot and private chat. Re-resolve the current
    # Comma binding on every click; navigation tokens never grant authority.
    _ = TelegramBot.answer_device_callback(callback["id"], "")
    send_devices(identity, action, get_in(callback, ["message", "message_id"]))
  end

  defp handle_callback(%{"callback_query" => %{"data" => "tr:" <> data} = callback}, identity) do
    # Task card ids only locate a card; the current binding is re-resolved on
    # every click and the Task operation applies the app's authorization.
    _ = TelegramBot.answer_device_callback(callback["id"], "")

    with_bound_sender(identity, fn binding ->
      CommaWeb.TelegramTaskCards.act(
        binding,
        identity,
        data,
        get_in(callback, ["message", "message_id"])
      )
    end)
  end

  defp handle_callback(update, identity), do: deliver_or_onboard(update, identity)

  defp with_bound_sender(identity, fun) do
    case TelegramLinks.resolve_sender(identity["id"]) do
      {:ok, %{link: link, workspace: workspace} = binding} ->
        with {:ok, connect} <-
               ProviderConnects.get_active_connect_by_id(
                 workspace["default_group_id"],
                 link.connect_id,
                 "telegram"
               ),
             true <- managed_connect_matches?(connect, workspace, identity) do
          fun.(binding)
        else
          _ -> {:error, :telegram_link_inconsistent}
        end

      {:error, :telegram_not_linked} ->
        reply(identity, :not_linked)
    end
  end

  # A reply to a Task card's change prompt goes to that Task, never the Router.
  defp card_reply(
         update,
         %{"reply_to_message" => %{"message_id" => reply_to}} = message,
         text,
         identity
       )
       when is_integer(reply_to) do
    result =
      with_bound_sender(identity, fn binding ->
        CommaWeb.TelegramTaskCards.reply(binding, identity, reply_to, text, message["message_id"])
      end)

    if result == :not_prompt, do: deliver_or_onboard(update, identity), else: result
  end

  defp card_reply(update, _message, _text, identity), do: deliver_or_onboard(update, identity)

  defp send_devices(identity, action, message_id) do
    with {:ok, %{user: user, workspace: workspace, link: link}} <-
           TelegramLinks.resolve_sender(identity["id"]),
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(
             workspace["default_group_id"],
             link.connect_id,
             "telegram"
           ),
         true <- managed_connect_matches?(connect, workspace, identity),
         {:ok, result} <- Comma.ChatDevices.browse(user, workspace, link.connect_id, action) do
      view = CommaWeb.ChatDeviceView.render(result, workspace, identity["language_code"])

      buttons =
        Enum.map(view.choices, fn {label, value} ->
          %{"text" => label, "callback_data" => "cd:" <> value}
        end)

      delivery =
        if is_integer(message_id),
          do: TelegramBot.edit_device_view(identity["id"], message_id, view.text, buttons),
          else: TelegramBot.send_task_links(identity["id"], view.text, buttons)

      case delivery do
        {:ok, _} -> :ok
        {:error, _} -> {:error, :telegram_delivery_unavailable}
      end
    else
      {:error, :telegram_not_linked} ->
        reply(identity, :not_linked)

      _ ->
        best_effort_message(
          identity["id"],
          if(identity["language_code"] == "zh",
            do: "设备列表已过期或暂不可用。请发送 /devices 重新查询。",
            else: "Device view expired or unavailable. Send /devices to read it again."
          )
        )
    end
  end

  defp send_status(identity) do
    case TelegramLinks.resolve_sender(identity["id"]) do
      {:ok, %{workspace: workspace}} -> reply(identity, :status, workspace["name"])
      {:error, :telegram_not_linked} -> reply(identity, :not_linked)
    end
  end

  # One authorized, bounded canonical Task read per explicit command. No
  # background projection, Topic->Task guess, or second Task lifecycle owner.
  defp send_tasks(identity) do
    case TelegramLinks.resolve_sender(identity["id"]) do
      {:ok, %{user: user, workspace: workspace}} ->
        with {:ok, page} <-
               Comma.Conversations.list_page(user, %{}, workspace["default_group_id"], limit: 8) do
          tasks = page["data"]

          if tasks == [] do
            reply(identity, :no_tasks, workspace["name"])
          else
            # The list is message text; the keyboard carries one compact
            # button per numbered row, since only buttons open the Mini App.
            lines =
              tasks
              |> Enum.with_index(1)
              |> Enum.map(fn {task, index} ->
                "#{index}. #{TelegramTaskCards.status_icon(task["status"])} " <>
                  TelegramTaskCards.html(String.slice(task["title"] || "Task", 0, 120))
              end)

            numbers =
              tasks
              |> Enum.with_index(1)
              |> Enum.map(fn {task, index} ->
                %{
                  "text" => Integer.to_string(index),
                  "web_app" => %{
                    "url" => task_panel_url(workspace, conversation_id: task["id"])
                  }
                }
              end)
              |> Enum.chunk_every(4)

            all_tasks = %{
              "text" => if(identity["language_code"] == "zh", do: "全部任务", else: "All tasks"),
              "web_app" => %{"url" => task_panel_url(workspace)}
            }

            name = TelegramTaskCards.html(workspace["name"])

            text =
              "<b>" <>
                TelegramCommands.message(:tasks, identity["language_code"], name) <>
                "</b>\n" <>
                TelegramCommands.message(:tasks_hint, identity["language_code"]) <>
                "\n\n" <> Enum.join(lines, "\n")

            case TelegramBot.send_card(identity["id"], text, numbers ++ [[all_tasks]]) do
              {:ok, _} -> :ok
              {:error, _} -> {:error, :telegram_delivery_unavailable}
            end
          end
        end

      {:error, :telegram_not_linked} ->
        reply(identity, :not_linked)
    end
  end

  defp task_panel_url(workspace, opts \\ []) do
    query =
      [
        {"group_id", workspace["default_group_id"]},
        {"conversation_id", opts[:conversation_id]},
        {"workspace_id", workspace["id"]},
        {"source", "telegram"}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> URI.encode_query()

    web_origin() <> "/task-panel.html?" <> query
  end

  defp web_origin,
    do: Application.fetch_env!(:comma_web, :web_cookie_origin) |> String.trim_trailing("/")

  defp disconnect_from_telegram(identity) do
    TelegramLinks.with_lifecycle_lock(fn ->
      case TelegramLinks.resolve_sender(identity["id"]) do
        {:ok, %{link: link, user: user, workspace: workspace}} ->
          with :ok <- retire_link(link, workspace),
               {:ok, _workspace, _removed?} <- TelegramLinks.delete(user, %{}, workspace["id"]) do
            reply(identity, :disconnected)
          end

        {:error, :telegram_not_linked} ->
          reply(identity, :not_linked)
      end
    end)
  end

  defp deliver_or_onboard(update, identity) do
    case TelegramLinks.resolve_sender(identity["id"]) do
      {:ok, %{link: link, workspace: workspace}} ->
        with {:ok, connect} <-
               ProviderConnects.get_active_connect_by_id(
                 workspace["default_group_id"],
                 link.connect_id,
                 "telegram"
               ),
             true <- managed_connect_matches?(connect, workspace, identity),
             {:ok, _status} <- ProviderHTTP.handle_telegram_update(connect, update) do
          :ok
        else
          false -> {:error, :telegram_link_inconsistent}
          {:error, :ignored} -> :ok
          {:error, _reason} -> {:error, :telegram_delivery_unavailable}
        end

      {:error, :telegram_not_linked} ->
        reply(identity, :not_linked)
    end
  end

  defp link_identity(user, workspace, identity, proof) do
    TelegramLinks.with_lifecycle_lock(fn ->
      with :ok <- TelegramLinks.validate_connection_attempt(user["id"], workspace["id"], proof),
           :ok <- retire_conflicting_sender(identity["id"], workspace["id"]),
           :ok <- retire_workspace_link(workspace),
           {:ok, connect} <- ensure_connect(workspace, identity),
           {:ok, %{link: link}} <-
             TelegramLinks.put_link(
               user["id"],
               workspace["id"],
               identity,
               connect["connect_id"],
               proof
             ),
           :ok <-
             ProviderConnects.activate_managed_telegram_im_connect(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               connect["connect_id"]
             ) do
        {:ok, link}
      end
    end)
  end

  # Retire before changing the authoritative binding. A provider or database
  # failure may make the old route temporarily unavailable, but it can never
  # leave an enabled connect addressing the newly supplied Telegram peer.
  defp retire_workspace_link(workspace) do
    workspace["id"]
    |> TelegramLinks.get_link()
    |> retire_link(workspace)
  end

  defp ensure_connect(workspace, identity) do
    ProviderConnects.ensure_managed_telegram_im_connect(
      workspace["salix_tenant_id"],
      workspace["default_group_id"],
      %{
        "bot_token" => TelegramBot.bot_token(),
        "telegram_user_id" => identity["id"]
      }
    )
  end

  defp retire_conflicting_sender(telegram_user_id, target_workspace_id) do
    case TelegramLinks.get_link_by_sender(telegram_user_id) do
      %{workspace_id: workspace_id} = link when workspace_id != target_workspace_id ->
        with {:ok, workspace} <- Workspaces.get(workspace_id), do: retire_link(link, workspace)

      _same_workspace_or_absent ->
        :ok
    end
  end

  defp retire_link(nil, _workspace), do: :ok

  defp retire_link(link, workspace) do
    case ProviderConnects.delete_im_connect(
           workspace["salix_tenant_id"],
           workspace["default_group_id"],
           link.connect_id
         ) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp private_user_message(%{"callback_query" => %{"message" => message, "from" => from}})
       when is_map(message) and is_map(from) do
    private_user_message(%{"message" => Map.put(message, "from", from)})
  end

  defp private_user_message(%{"message" => message}) when is_map(message) do
    chat = message["chat"] || %{}
    from = message["from"] || %{}
    chat_id = normalize_id(chat["id"])
    user_id = normalize_id(from["id"])

    if chat["type"] == "private" and from["is_bot"] != true and chat_id != "" and
         chat_id == user_id do
      {:ok, message,
       %{
         "id" => user_id,
         "username" => from["username"],
         "language_code" => TelegramCommands.language(from["language_code"])
       }}
    else
      {:error, :ignored}
    end
  end

  defp private_user_message(_update), do: {:error, :ignored}

  defp managed_connect_matches?(connect, workspace, identity) do
    connect["managed_by"] == "comma_product" and connect["runtime_mode"] == "webhook" and
      connect["tenant_id"] == workspace["salix_tenant_id"] and
      connect["group_id"] == workspace["default_group_id"] and
      normalize_id(connect["managed_peer_id"]) == identity["id"]
  end

  defp reply(identity, kind, workspace \\ ""),
    do:
      best_effort_message(
        identity["id"],
        TelegramCommands.message(kind, identity["language_code"], workspace)
      )

  defp best_effort_message(chat_id, text) do
    case TelegramBot.send_message(chat_id, text) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp require_bot,
    do: if(TelegramBot.configured?(), do: :ok, else: {:error, :telegram_unavailable})

  defp normalize_id(nil), do: ""
  defp normalize_id(value), do: value |> to_string() |> String.trim()
end
