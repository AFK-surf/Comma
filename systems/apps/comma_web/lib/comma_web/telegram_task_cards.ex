defmodule CommaWeb.TelegramTaskCards do
  @moduledoc """
  Task review cards in the owner's bound Telegram private chat.

  Salix owns Task status and delivers status changes to one personal provider
  Participant. This adapter authorizes each send against the current binding,
  renders the card, and handles its buttons. A card id is a lookup handle, not
  authority: every click re-resolves the sender and calls the same Comma Task
  operations as the app. The Mini App stays read-only.
  """

  require Logger

  alias Comma.{Conversations, Workspaces}
  alias CommaWeb.{ProactiveDelivery, TelegramBot}
  alias SalixStore.CasRecord

  @attention ~w(ready_for_review escalated failed)
  @endings ~w(completed cancelled archived)
  @card_ttl 14 * 24 * 60 * 60
  @prompt_ttl 24 * 60 * 60
  @record_bytes 8_192

  ## Salix adapter

  @doc "The owner's bound Telegram chat for a Task in this Group, if any."
  def task_status_targets(group_id) do
    with {:ok, workspace} <- Workspaces.get_by_group(group_id),
         owner when is_binary(owner) <- workspace["owner_user_id"],
         {:ok, %{} = target} <- ProactiveDelivery.telegram_target(workspace, owner) do
      [target]
    else
      _ -> []
    end
  end

  @doc "Sends or retires the card for one Task status delivery."
  def deliver(rec, connect) do
    group = rec["agent_group_id"]
    payload = rec["participant_payload"] || %{}

    with {:ok, workspace} <- Workspaces.get_by_group(group),
         owner when is_binary(owner) <- workspace["owner_user_id"],
         {:ok, _} <- Workspaces.authorize_group(%{"id" => owner}, %{}, group),
         {:ok, %{} = target} <- ProactiveDelivery.telegram_target(workspace, owner),
         true <-
           target["connect_id"] == connect["connect_id"] and
             target["connect_id"] == payload["connect_id"] and
             target["chat_id"] == to_string(payload["chat_id"]) do
      language = owner_language(workspace["id"], owner)

      case rec["conversation_status"] do
        status when status in @attention -> send_card(rec, workspace, target, language)
        status when status in @endings -> retire_card(rec, status, language)
        _other -> retire_card(rec, :updated, language)
      end
    else
      _ -> {:error, :task_card_delivery_no_longer_current}
    end
  end

  ## Telegram interactions

  @doc """
  Handles a `tr:` button for a sender whose binding the caller has verified.
  """
  def act(%{user: user, workspace: workspace, link: link}, identity, data, message_id) do
    language = identity["language_code"]

    with [card_id, action] <- String.split(data, ":", parts: 2),
         {:ok, card} <- read_card(card_id),
         true <-
           card["workspace_id"] == workspace["id"] and card["connect_id"] == link.connect_id and
             card["chat_id"] == identity["id"] and card["message_id"] == message_id do
      cond do
        card["expires_at"] <= now() ->
          edit(card, card_text(card, :expired, language), [open_row(card, language)])

        action == "a" and card["acceptable"] == true ->
          accept(user, card, language)

        action == "r" ->
          prompt_changes(card, language)

        true ->
          :ok
      end
    else
      _ -> notify(identity["id"], :unavailable, language)
    end
  end

  @doc """
  Sends a reply to a change prompt to its Task as the owner. Returns
  `:not_prompt` when the reply does not answer a card prompt.
  """
  def reply(%{user: user, workspace: workspace, link: link}, identity, reply_to, text, message_id) do
    language = identity["language_code"]

    case read_record(prompt_key(identity["id"], reply_to)) do
      {:ok, prompt} ->
        with {:ok, card} <- read_card(prompt["card_id"]),
             true <-
               card["workspace_id"] == workspace["id"] and
                 card["connect_id"] == link.connect_id and card["chat_id"] == identity["id"],
             true <- prompt["expires_at"] > now() do
          case Conversations.send_message(user, %{}, card["group_id"], card["conversation_id"], %{
                 "content" => text,
                 # Keyed by the incoming reply, so a webhook redelivery is one
                 # message and a second reply to the same prompt is another.
                 "client_request_id" => "telegram-changes-" <> identity["id"] <> "-#{message_id}"
               }) do
            {:ok, _} ->
              notify(identity["id"], :sent, language)

            {:error, reason} ->
              Logger.warning("Telegram card reply failed: " <> inspect(reason))
              notify(identity["id"], :retry, language)
          end
        else
          _ -> notify(identity["id"], :prompt_expired, language)
        end

      {:error, :not_found} ->
        :not_prompt

      {:error, _} ->
        notify(identity["id"], :prompt_expired, language)
    end
  end

  @doc false
  def prompt_key(chat_id, message_id),
    do: "comma/telegram_task_cards/prompts/#{chat_id}/#{message_id}.json"

  ## Card lifecycle

  defp send_card(rec, workspace, target, language) do
    status = rec["conversation_status"]

    # Salix republishes the current status with other Task changes. A Task
    # that stays in the same attention status keeps its one live card, which
    # still carries the version it showed; Accept then reports the change.
    case live_card(rec["agent_group_id"], rec["conversation_id"]) do
      {:ok, %{"status" => ^status}} -> {:ok, %{"status" => "card_current"}}
      _ -> send_new_card(rec, workspace, target, language)
    end
  end

  defp live_card(group, conversation_id) do
    with {:ok, latest} <- read_record(latest_key(group, conversation_id)),
         {:ok, card} <- read_card(latest["card_id"]),
         true <-
           is_integer(card["message_id"]) and card["expires_at"] > now() and
             card["attention_ended"] != true do
      {:ok, card}
    else
      _ -> :none
    end
  end

  defp send_new_card(rec, workspace, target, language) do
    group = rec["agent_group_id"]
    conversation_id = rec["conversation_id"]
    status = rec["conversation_status"]

    card = %{
      "id" => Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      "workspace_id" => workspace["id"],
      "group_id" => group,
      "conversation_id" => conversation_id,
      "connect_id" => target["connect_id"],
      "chat_id" => target["chat_id"],
      "title" => rec["conversation_title"] || "Task",
      "status" => status,
      "review_version" => rec["conversation_updated_at"],
      "acceptable" => status == "ready_for_review" and acceptable?(group, conversation_id),
      "language" => language,
      "expires_at" => now() + @card_ttl
    }

    with {:ok, _} <- CasRecord.create(card_key(card["id"]), card) do
      case TelegramBot.send_card(card["chat_id"], card_text(card, status, language), rows(card)) do
        {:ok, %{"message_id" => message_id} = receipt} ->
          card = Map.put(card, "message_id", message_id)
          _ = CasRecord.update(card_key(card["id"]), fn _ -> card end)
          supersede_latest(card)
          {:ok, Map.take(receipt, ["message_id"])}

        {:ok, _receipt} ->
          {:unknown, :telegram_card_receipt_missing}

        # Telegram has no receipt lookup; the caller never resends this card.
        {:error, reason} ->
          {:unknown, reason}
      end
    end
  end

  defp retire_card(rec, status, language) do
    key = latest_key(rec["agent_group_id"], rec["conversation_id"])

    with {:ok, latest} <- read_record(key),
         {:ok, card} <- read_card(latest["card_id"]) do
      language = card["language"] || language
      rows = if status in @endings, do: [], else: [open_row(card, language)]

      # Editing a known message is safe to retry. Keep its target until both
      # the edit and pointer update succeed. The Participant owns the budget.
      # End deduplication before the edit, so an exhausted retirement cannot
      # suppress the next review round.
      with {:ok, _} <-
             CasRecord.update(card_key(card["id"]), &Map.put(&1, "attention_ended", true)),
           {:ok, _} <-
             TelegramBot.edit_card(
               card["chat_id"],
               card["message_id"],
               card_text(card, status, language),
               rows
             ),
           {:ok, _} <- CasRecord.update(key, fn _ -> %{"card_id" => nil} end) do
        {:ok, %{"status" => "card_retired"}}
      else
        {:error, {:telegram_http_error, code} = reason} ->
          {:error, reason, code in [408, 429] or code in 500..599}

        {:error, reason} ->
          {:error, reason, true}
      end
    else
      {:error, :not_found} -> {:ok, %{"status" => "no_card"}}
      {:error, reason} -> {:error, reason, true}
    end
  end

  # A newer card replaces an older one for the same Task; the older card keeps
  # only its Open button so it cannot act on a superseded review.
  defp supersede_latest(card) do
    key = latest_key(card["group_id"], card["conversation_id"])
    current_id = card["id"]

    with {:ok, previous} <- read_record(key),
         id when is_binary(id) and id != current_id <- previous["card_id"],
         {:ok, old} <- read_card(id) do
      _ = edit(old, card_text(old, :expired, old["language"]), [open_row(old, old["language"])])
    end

    _ = CasRecord.update(key, fn _ -> %{"card_id" => card["id"]} end)
    :ok
  end

  defp accept(user, card, language) do
    result =
      Conversations.accept_task_review(user, %{}, card["group_id"], card["conversation_id"], %{
        "review_version" => card["review_version"]
      })

    reviewed = card["review_version"]

    case current_task(card) do
      {:ok, %{"status" => status}} when status in @endings ->
        edit(card, card_text(card, status, language), [])

      {:ok, %{"status" => "ready_for_review", "updated_at" => ^reviewed}} ->
        # The review is unchanged, so the failed attempt can be retried.
        Logger.warning("Telegram card accept failed", reason: inspect(result))
        notify(card["chat_id"], :retry, language)

      {:ok, _changed} ->
        edit(card, card_text(card, :updated, language), [open_row(card, language)])

      {:error, _reason} ->
        notify(card["chat_id"], :retry, language)
    end
  end

  defp prompt_changes(card, language) do
    case TelegramBot.send_force_reply(card["chat_id"], card_text(card, :prompt, language)) do
      {:ok, %{"message_id" => message_id}} ->
        CasRecord.update(prompt_key(card["chat_id"], message_id), fn _ ->
          %{"card_id" => card["id"], "expires_at" => now() + @prompt_ttl}
        end)

        :ok

      _ ->
        :ok
    end
  end

  defp acceptable?(group, conversation_id) do
    case SalixIM.Conversations.get_group_conversation(group, conversation_id) do
      {:ok, conversation} -> not scheduled?(conversation)
      _ -> false
    end
  end

  defp scheduled?(conversation) do
    case get_in(conversation, ["schedule", "schedule_id"]) do
      id when is_binary(id) -> String.trim(id) != ""
      _ -> false
    end
  end

  defp current_task(card),
    do: SalixIM.Conversations.get_group_conversation(card["group_id"], card["conversation_id"])

  ## Rendering

  defp rows(card) do
    language = card["language"]

    actions =
      case card["status"] do
        "ready_for_review" ->
          if(card["acceptable"],
            do: [button(card, "a", label(:accept, language))],
            else: []
          ) ++ [button(card, "r", label(:changes, language))]

        "escalated" ->
          [button(card, "r", label(:reply, language))]

        _ ->
          []
      end

    Enum.reject([actions, open_row(card, language)], &(&1 == []))
  end

  defp button(card, action, text),
    do: %{"text" => text, "callback_data" => "tr:" <> card["id"] <> ":" <> action}

  defp open_row(card, language) do
    query =
      URI.encode_query(%{
        "group_id" => card["group_id"],
        "conversation_id" => card["conversation_id"],
        "workspace_id" => card["workspace_id"],
        "source" => "telegram"
      })

    [
      %{
        "text" => label(:open, language),
        "web_app" => %{"url" => web_origin() <> "/task-panel.html?" <> query}
      }
    ]
  end

  # Telegram HTML: a bold title over one status line.
  defp card_text(card, kind, language) do
    line = if language == "zh", do: zh(kind), else: en(kind)
    "<b>" <> html(card["title"]) <> "</b>\n" <> line
  end

  @doc "Escapes text for a Telegram HTML message."
  def html(text), do: text |> to_string() |> Plug.HTML.html_escape()

  @doc "The status glyph shared by cards and the `/tasks` list."
  def status_icon(status) do
    case status do
      "ready_for_review" -> "👀"
      "escalated" -> "✋"
      "failed" -> "⚠️"
      "completed" -> "✅"
      "cancelled" -> "🚫"
      "archived" -> "🗂"
      status when status in ["active", "in_progress", "running"] -> "🔄"
      _ -> "⚪️"
    end
  end

  defp en("ready_for_review"), do: "👀 Ready for your review"
  defp en("escalated"), do: "✋ Needs your input"
  defp en("failed"), do: "⚠️ The Task failed"
  defp en("completed"), do: "✅ Completed"
  defp en("cancelled"), do: "🚫 Cancelled"
  defp en("archived"), do: "🗂 Archived"
  defp en(:updated), do: "🔄 Task updated since this card · Open it for the latest"
  defp en(:expired), do: "⏱ This card has expired · Open the Task in Comma"
  defp en(:prompt), do: "✍️ Reply to this message with your changes"
  defp en(_other), do: "Open the Task in Comma"

  defp zh("ready_for_review"), do: "👀 已完成，等你确认"
  defp zh("escalated"), do: "✋ 需要你处理"
  defp zh("failed"), do: "⚠️ 任务失败了"
  defp zh("completed"), do: "✅ 已完成"
  defp zh("cancelled"), do: "🚫 已取消"
  defp zh("archived"), do: "🗂 已归档"
  defp zh(:updated), do: "🔄 卡片发出后任务有更新 · 打开查看最新进展"
  defp zh(:expired), do: "⏱ 此卡片已过期 · 请在 Comma 中打开任务"
  defp zh(:prompt), do: "✍️ 回复这条消息，写下你的修改意见"
  defp zh(_other), do: "请在 Comma 中打开任务"

  defp label(:accept, "zh"), do: "确认完成"
  defp label(:accept, _), do: "Confirm done"
  defp label(:changes, "zh"), do: "退回修改"
  defp label(:changes, _), do: "Request changes"
  defp label(:reply, "zh"), do: "回复"
  defp label(:reply, _), do: "Reply"
  defp label(:open, "zh"), do: "打开"
  defp label(:open, _), do: "Open"

  defp notify(chat_id, kind, "zh"), do: best_effort(chat_id, notice_zh(kind))
  defp notify(chat_id, kind, _language), do: best_effort(chat_id, notice_en(kind))

  defp notice_en(:sent), do: "Sent to the Task."
  defp notice_en(:retry), do: "Could not update the Task. Try again later."
  defp notice_en(:prompt_expired), do: "This prompt has expired. Open the Task in Comma to reply."
  defp notice_en(:unavailable), do: "This card is no longer available. Open the Task in Comma."

  defp notice_zh(:sent), do: "已发送给任务。"
  defp notice_zh(:retry), do: "暂时无法更新任务，请稍后再试。"
  defp notice_zh(:prompt_expired), do: "该提示已过期，请在 Comma 中打开任务回复。"
  defp notice_zh(:unavailable), do: "此卡片已不可用，请在 Comma 中打开任务。"

  defp best_effort(chat_id, text) do
    _ = TelegramBot.send_message(chat_id, text)
    :ok
  end

  defp edit(card, text, rows) do
    _ = TelegramBot.edit_card(card["chat_id"], card["message_id"], text, rows)
    :ok
  end

  ## Records

  defp owner_language(workspace_id, owner) do
    case Comma.Recommendations.get_runtime_profile(workspace_id, owner) do
      {:ok, %{locale: locale}} -> CommaWeb.TelegramCommands.language(locale)
      _ -> "en"
    end
  end

  defp read_card(id) when is_binary(id) do
    if Regex.match?(~r/\A[0-9a-f]{16}\z/, id),
      do: read_record(card_key(id)),
      else: {:error, :not_found}
  end

  defp read_card(_id), do: {:error, :not_found}

  defp read_record(key) do
    case CasRecord.get_bounded(key, @record_bytes) do
      {:ok, value, _size} -> {:ok, value}
      {:error, :not_found, _} -> {:error, :not_found}
      {:error, reason, _} -> {:error, reason}
    end
  end

  defp card_key(id), do: "comma/telegram_task_cards/cards/#{id}.json"

  defp latest_key(group, conversation_id),
    do: "comma/telegram_task_cards/latest/#{group}/#{conversation_id}.json"

  defp web_origin,
    do: Application.fetch_env!(:comma_web, :web_cookie_origin) |> String.trim_trailing("/")

  defp now, do: System.system_time(:second)
end
