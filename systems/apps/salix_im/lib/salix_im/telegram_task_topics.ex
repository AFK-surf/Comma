defmodule SalixIM.TelegramTaskTopics do
  @moduledoc "Telegram topic addresses for existing Tasks. Conversation owns all work and messages."

  alias SalixIM.{ConversationServer, Conversations, ProviderConnects, ProviderConversationInput}
  alias SalixIM.ProviderRecipientIdentity
  alias SalixIM.Provider.Telegram
  alias SalixStore.{CasRecord, Keys, Ids}

  def open(%{agent: %{"role" => "router"}, agent_id: agent, group_id: group}, connect, params) do
    task_id = params["conversation_id"]
    chat = to_string(params["chat_id"] || "")

    with true <- Ids.valid_conversation_id?(task_id),
         {:ok, connect} <- active_connect(connect),
         true <- connect["group_id"] == group and chat == connect["managed_peer_id"],
         {:ok, task} <- Conversations.get_group_conversation_record(group, task_id),
         true <- task["kind"] == "agent_task" and task["created_by_agent_id"] == agent,
         true <- task["status"] not in ["archived", "cancelled"],
         {:ok, binding} <- ensure_topic(connect, task, task_id),
         {:ok, participant} <- attach(connect, binding) do
      {:ok,
       Map.merge(binding, %{
         "status" => "ready",
         "participant_id" => participant["participant_id"]
       })}
    else
      false -> {:error, "Task topic requires a Router-owned Task and its linked private chat"}
      error -> error
    end
  end

  def open(_, _, _), do: {:error, "Only the Router can open a Task topic"}

  def append(connect, content, metadata, source_id, opts) do
    topic = to_string(metadata["message_thread_id"] || "")

    # Telegram addresses survive a Comma reconnect or Workspace switch. Resolve
    # the provider address before checking its connection owner, so an old Task
    # topic cannot become a fresh Router request in another Workspace.
    if connect["managed_by"] == "comma_product" and topic != "" do
      key =
        Keys.ctl_im_telegram_topic_route(
          connect["bot_user_id"],
          metadata["chat_id"],
          topic
        )

      case CasRecord.get(key) do
        {:ok, binding} -> append_bound(connect, binding, content, metadata, source_id, opts)
        {:error, :not_found} -> :unbound
        error -> error
      end
    else
      :unbound
    end
  end

  defp ensure_topic(connect, task, task_id) do
    key = Keys.ctl_im_telegram_task_topic(connect["group_id"], connect["connect_id"], task_id)

    case CasRecord.get(key) do
      {:ok, %{"message_thread_id" => _} = binding} ->
        {:ok, binding}

      {:ok, _} ->
        {:error,
         "Topic creation is pending or uncertain. Check Telegram before recovery; do not create another Task."}

      {:error, :not_found} ->
        create_topic(connect, task, task_id, key)

      error ->
        error
    end
  end

  defp create_topic(connect, task, task_id, key) do
    binding = %{
      "conversation_id" => task_id,
      "group_id" => connect["group_id"],
      "connect_id" => connect["connect_id"],
      "chat_id" => connect["managed_peer_id"]
    }

    with {:ok, %{"has_topics_enabled" => true}} <- Telegram.topic_request(connect, "getMe", %{}),
         {:ok, _} <- CasRecord.create(key, binding),
         {:ok, %{"message_thread_id" => topic}} when is_integer(topic) and topic > 0 <-
           Telegram.topic_request(connect, "createForumTopic", %{
             "chat_id" => binding["chat_id"],
             "name" => topic_name(task)
           }),
         {:ok, saved} <-
           CasRecord.update(
             key,
             fn current -> Map.put(current, "message_thread_id", to_string(topic)) end,
             create: false
           ) do
      {:ok, saved}
    else
      {:ok, _} -> {:error, "Enable private chat topics for the bot in BotFather first"}
      {:error, :exists} -> ensure_topic(connect, task, task_id)
      error -> error
    end
  end

  defp attach(connect, binding) do
    target = %{
      "provider" => "telegram",
      "connect_id" => connect["connect_id"],
      "chat_id" => binding["chat_id"],
      "chat_type" => "private",
      "message_thread_id" => binding["message_thread_id"]
    }

    route =
      Keys.ctl_im_telegram_topic_route(
        connect["bot_user_id"],
        binding["chat_id"],
        binding["message_thread_id"]
      )

    # Persist the route before membership. A callback can finish attachment
    # after a crash. The address never moves to another Task.
    with {:ok, ^binding} <- CasRecord.ensure(route, fn -> binding end),
         {:ok, participant} <-
           ConversationServer.ensure_group_conversation_provider_participant(
             binding["group_id"],
             binding["conversation_id"],
             ProviderConversationInput.provider_participant(target, %{
               "role_label" => "telegram_topic",
               "notification_filter" => %{"messages" => "all", "statuses" => "none"}
             })
           ) do
      {:ok, participant}
    else
      {:ok, _} -> {:error, :telegram_topic_conflict}
      error -> error
    end
  end

  defp append_bound(connect, binding, content, metadata, source_id, opts) do
    with {:ok, connect} <- active_connect(connect),
         true <-
           binding["connect_id"] == connect["connect_id"] and
             binding["group_id"] == connect["group_id"],
         true <-
           metadata["chat_type"] == "private" and
             metadata["from_user_id"] == connect["managed_peer_id"] and
             metadata["chat_id"] == binding["chat_id"],
         {:ok, task} <-
           Conversations.get_group_conversation_record(
             binding["group_id"],
             binding["conversation_id"]
           ),
         true <- task["kind"] == "agent_task",
         {:ok, participant} <- attach(connect, binding),
         {:ok, attachments, failed} <-
           ProviderConversationInput.stage_worker_attachments(
             task["task_worker_agent_id"],
             Keyword.get(opts, :attachments, [])
           ),
         {:ok, _} <-
           ConversationServer.append_group_conversation_message(
             binding["group_id"],
             binding["conversation_id"],
             ProviderRecipientIdentity.mark_trusted_provider_message(%{
               "kind" => "message",
               "participant_id" => participant["participant_id"],
               "actor_type" => "provider_user",
               "provider" => "telegram",
               "user_id" => metadata["from_user_id"],
               "user_name" => metadata["from_username"],
               "content" =>
                 ProviderConversationInput.content_with_attachments(attachments, content, failed),
               "metadata" => metadata,
               "source_message_id" => source_id
             })
           ) do
      {:ok, :queued}
    else
      false -> {:error, :telegram_topic_forbidden}
      error -> error
    end
  end

  defp topic_name(task) do
    name = String.trim(task["title"] || "")

    if name == "",
      do: "Comma Task",
      else: name |> String.codepoints() |> Enum.take(128) |> Enum.join()
  end

  defp active_connect(connect) do
    with {:ok, current} <-
           ProviderConnects.get_active_connect_by_id(
             connect["group_id"],
             connect["connect_id"],
             "telegram"
           ),
         true <-
           current["managed_by"] == "comma_product" and
             current["managed_peer_id"] not in [nil, ""] do
      {:ok, current}
    else
      false -> {:error, :telegram_topic_forbidden}
      error -> error
    end
  end
end
