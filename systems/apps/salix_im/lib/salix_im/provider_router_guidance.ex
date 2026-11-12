defmodule SalixIM.ProviderRouterGuidance do
  @moduledoc false

  alias SalixIM.FeishuCalendarContract

  @doc false
  def feishu(metadata) when is_map(metadata) do
    connect_id = metadata["connect_id"]
    message_id = metadata["message_id"]
    chat_id = metadata["chat_id"]
    chat_type = metadata["chat_type"]
    thread_id = metadata["message_thread_id"]

    card_message_id =
      if metadata["root_message_id"] in [nil, ""],
        do: message_id,
        else: metadata["root_message_id"]

    thread_instruction =
      cond do
        chat_type == "group" and thread_id in [nil, ""] ->
          "This is a top-level group trigger: pass reply_in_thread=true and chat_id=#{chat_id} so the reply creates a Feishu thread."

        thread_id not in [nil, ""] ->
          "This message is already in thread_id=#{thread_id}; pass that thread_id and continue the same Feishu thread."

        true ->
          "This is not a group-thread trigger; keep reply_in_thread=false."
      end

    [
      "This is a Feishu provider message. For a visible reply, call im_api.feishu.reply_text with connect_id=#{connect_id}, message_id=#{message_id}, and the reply text; do not use im_api.internal.send_message for the external reply.",
      thread_instruction,
      replied_message_instruction("feishu", metadata),
      bare_mention_instruction(),
      "If this human request creates a Task with im_api.internal.task.create, the runtime publishes its live Task card as a reply to this source. Check task_card.status in the result; do not publish again when it is queued. If publication failed, retry only im_api.feishu.post_task_card with connect_id=#{connect_id}, the existing conversation_id, chat_id=#{chat_id}, message_id=#{card_message_id} and chat_type=#{chat_type}; never create another Task to repair the card.",
      "When the user asks about earlier group messages or facts mentioned in the group, read help for im_api.feishu.get_chat_history and call it with connect_id=#{connect_id} and chat_id=#{chat_id}. When the request is specifically about the current or another known Feishu thread, use im_api.feishu.get_thread_replies with its thread_id instead. These APIs return bounded pages, so paginate deliberately only when the requested fact is not in the first page.",
      "An image already staged from this current triggering message is included in the model request as native image input; do not list history or download it again. Any other attachment is staged in the agent workspace and announced with its VFS path only — read it with fs.read_file, or stage it on a connected runner with env.copy and convert it with env.exec. When the user asks about historical group files or attachments, use im_api.feishu.list_chat_files for top-level group-message attachments or im_api.feishu.get_thread_replies for a known thread. If the user needs a historical file inspected, copy the selected attachment's exact resource_ref unchanged into im_api.feishu.fetch_message_resource; never reconstruct or shorten message_id/file_key fields. If it completes asynchronously, wait for completion and call tool_call.get_result without offset or limit. Do not claim that Feishu history or group-message attachments are unavailable until the appropriate current-file input or historical provider operation has actually been attempted and returned that limitation.",
      "Use schedule.create for a reminder: a message whose text is known now, sent by this Router at a time or on a cadence. For duration recurrence such as every 5 minutes, pass interval_minutes=5 with prompt and omit cron, run_at, and timezone. Use run_at only for one reminder time, or cron plus timezone for calendar recurrence, and always provide exactly one timing mode. The executable prompt must explicitly call im_api.feishu.send_message with connect_id=#{connect_id}, chat_id=#{chat_id}, exact text, and structured mentions after resolving member IDs. Work that repeats or keeps watching something (a recurring check, digest or monitor: anything that must look something up or decide at each run) is a Loop Task: im_api.internal.task.create with loop, whose Worker runs it and reports each run as the Task says. When that Task's Worker or Loop fails, continue in that Task and send the follow-up there; do not move the work to schedule.create. A delegated worker that computes a reminder's content returns it to this Router instead of sending directly to Feishu.",
      feishu_meeting_instruction(),
      FeishuCalendarContract.instruction(),
      "Plain assistant text is only a runtime transcript entry and is not visible in Feishu. A requested reply is incomplete until the Feishu tool call succeeds. It is valid to stay silent when no reply is needed."
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  def feishu(_metadata), do: ""

  @doc """
  Names the message a Feishu or Lark message replies to. A person often replies
  to a message with only a mention of the bot, which asks the bot to act on it.
  """
  @spec replied_message_instruction(String.t(), map()) :: String.t()
  def replied_message_instruction(provider, metadata) do
    parent_id = metadata["message_parent_id"]

    if parent_id in [nil, "", metadata["message_id"]] do
      ""
    else
      "This message replies to message_id=#{parent_id}. When the request depends on that message, read it with im_api.#{provider}.get_message and connect_id=#{metadata["connect_id"]} first."
    end
  end

  @doc "What a mention of the bot with no text asks for."
  @spec bare_mention_instruction() :: String.t()
  def bare_mention_instruction do
    "A message that reads [mentioned the bot with no text] asks you to act on the message it replies to, or else on the conversation before it: read that first. If no clear request can be recovered, send a brief clarification. Never silently end a bare mention."
  end

  @doc "How a person gets the bot into a Google Meet or a Feishu video meeting from Feishu."
  @spec feishu_meeting_instruction() :: String.t()
  def feishu_meeting_instruction do
    "When the person asks you to join a Google Meet, call meeting.join yourself; never create a Task or ask a Worker to join. A Feishu video meeting is different: meeting.join cannot enter it. A person invites the bot from the participant list of the running meeting."
  end
end
