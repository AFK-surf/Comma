defmodule SalixIM.QQTaskCard do
  @moduledoc """
  QQ Task status notifications use one provider Participant per Task.

  QQ cannot edit messages. Each meaningful lifecycle or Worker activity change
  sends a new Markdown card. Conversation status and Session Activity remain
  authoritative. Repeated activity hints do not send another card.
  """

  alias SalixIM.{
    Conversations,
    ConversationServer,
    ProviderConversationInput,
    ProviderObservations
  }

  alias SalixIM.Provider.QQ
  import SalixIM.Provider.Util, only: [str: 1]

  @kind "qq_task_card"
  def target_key, do: @kind

  def post(%{agent: %{"role" => "router"}, group_id: group, agent_id: agent}, connect, params) do
    chat = str(params["chat_id"])
    conversation_id = str(params["conversation_id"])

    with true <- String.starts_with?(chat, ["group:", "c2c:"]),
         {:ok, _chat} <- ProviderObservations.get_qq_chat(connect["connect_id"], chat),
         {:ok, conversation} <-
           Conversations.get_group_conversation_record(group, conversation_id),
         true <-
           conversation["kind"] == "agent_task" and conversation["created_by_agent_id"] == agent,
         target = %{
           "provider" => "qq",
           "projection" => @kind,
           "connect_id" => connect["connect_id"],
           "chat_id" => chat
         },
         attrs =
           ProviderConversationInput.provider_participant(target, %{
             "target_key" => @kind,
             "role_label" => "task_card",
             "delivery_cursor_seq" => SalixIM.TaskCardProjection.tail_seq(conversation),
             "notification_filter" => %{"messages" => "none", "statuses" => "all"},
             "payload" => %{"task_id" => conversation_id}
           }),
         {:ok, participant} <-
           ConversationServer.ensure_group_conversation_provider_participant(
             group,
             conversation_id,
             attrs
           ),
         true <- Map.take(participant["payload"], Map.keys(target)) == target,
         {:ok, queued} <-
           ConversationServer.send_provider_participant_message(
             group,
             conversation_id,
             participant["participant_id"],
             %{
               "idempotency_key" => "qq-task-created",
               "content" => conversation_id
             }
           ) do
      {:ok,
       %{
         "conversation_id" => conversation_id,
         "task_id" => conversation_id,
         "delivery_status" => queued["delivery_status"]
       }}
    else
      false -> {:error, "Task card requires the creating Router and its original QQ chat"}
      {:error, _} = error -> error
    end
  end

  def post(_scope, _connect, _params),
    do: {:error, "only the creating Router can publish a Task card"}

  def deliver(connect, %{"participant_payload" => %{"projection" => @kind} = payload} = rec) do
    lifecycle = str(rec["conversation_status"])
    notice = notice(rec, payload, lifecycle)

    if is_nil(notice) or payload["last_notice"] == notice do
      {:ok, :task_card_current}
    else
      desired = payload |> Map.put("last_notice", notice) |> Map.put("last_lifecycle", lifecycle)
      text = render(rec, notice)

      case QQ.call(nil, connect, "qq.send_message", %{
             "chat_id" => payload["chat_id"],
             "text" => text
           }) do
        {:ok, %{"message_id" => id}} when is_binary(id) and id != "" ->
          {:ok,
           %{"participant_receipt" => %{"payload" => Map.put(desired, "card_message_id", id)}}}

        {:error, %{"error_class" => "provider_timeout"} = reason} ->
          {:unknown, %{"status" => "provider_outcome_ambiguous"}, reason}

        {:error, reason} ->
          {:error, reason, false}

        _ ->
          {:unknown, %{"status" => "provider_outcome_ambiguous"}, :qq_receipt_missing}
      end
    end
  end

  def deliver(_connect, _rec), do: {:error, :invalid_qq_task_card, false}

  defp notice(_rec, _payload, lifecycle)
       when lifecycle in ~w(ready_for_review completed failed cancelled escalated),
       do: lifecycle

  defp notice(rec, payload, "active") do
    case get_in(rec, ["message_metadata", "qq_task_activity"]) do
      %{"state" => "active"} ->
        "working"

      %{"state" => "error", "issue" => issue} ->
        "blocked:" <> safe_issue(issue)

      %{"state" => "stopped"} ->
        "paused"

      _ ->
        if is_nil(payload["last_notice"]) or payload["last_lifecycle"] != "active", do: "queued"
    end
  end

  defp notice(_rec, _payload, _lifecycle), do: nil

  defp render(rec, notice) do
    {label, detail} = description(notice)
    title = rec["conversation_title"] |> str() |> String.slice(0, 200) |> escape()
    "## #{label}\n**#{title}**\n\nTask ID：`#{rec["conversation_id"]}`\n\n#{detail}"
  end

  defp description("queued"), do: {"任务已接收", "Task 已创建，等待 Worker 开始执行。"}
  defp description("working"), do: {"任务处理中", "Worker 已开始执行；完成或需要你处理时会再次通知。"}
  defp description("paused"), do: {"任务执行暂停", "Worker 停止后仍未提交结果，已通知 Router 检查。任务尚未完成。"}
  defp description("ready_for_review"), do: {"任务待确认", "工作结果已进入待确认状态，请查看回复并确认下一步。"}
  defp description("completed"), do: {"任务已完成", "Task 已标记完成。"}
  defp description("failed"), do: {"任务失败", "Task 未能完成，请查看 Router 的说明或发送补充指令。"}
  defp description("cancelled"), do: {"任务已取消", "Task 已取消。"}
  defp description("escalated"), do: {"任务需要你处理", "Task 遇到阻塞，需要你提供信息或作出决定。请查看 Router 的说明。"}
  defp description("blocked:" <> issue), do: {"任务执行受阻", issue_hint(issue)}

  defp safe_issue(issue)
       when issue in ~w(authentication_required model_unavailable quota_exhausted provider_quota_exhausted rate_limited insufficient_credits account_inactive missing_account runtime_failed recovery_exhausted),
       do: issue

  defp safe_issue(_issue), do: "runtime_error"
  defp issue_hint("authentication_required"), do: "Worker 需要重新登录或授权，任务尚未完成。"
  defp issue_hint("provider_quota_exhausted"), do: "模型服务的额度不足，需要补充额度或提高限额。"

  defp issue_hint(issue) when issue in ~w(insufficient_credits quota_exhausted),
    do: "执行额度不足，需要检查账户额度。"

  defp issue_hint("rate_limited"), do: "模型服务暂时限流，任务尚未完成。"
  defp issue_hint("model_unavailable"), do: "当前模型不可用，需要检查模型配置。"
  defp issue_hint(_issue), do: "Worker 遇到运行异常，任务尚未完成。请查看 Router 的说明。"
  defp escape(text), do: String.replace(text, ~r/([\\`*_{}\[\]()<>#])/, "\\\\\\1")
end
