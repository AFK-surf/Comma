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
      "When the user asks about earlier group messages or facts mentioned in the group, read help for im_api.feishu.get_chat_history and call it with connect_id=#{connect_id} and chat_id=#{chat_id}. When the request is specifically about the current or another known Feishu thread, use im_api.feishu.get_thread_replies with its thread_id instead. These APIs return bounded pages, so paginate deliberately only when the requested fact is not in the first page.",
      "An image already staged from this current triggering message is included in the model request as native image input; do not list history or download it again. Any other attachment is staged in the agent workspace and announced with its VFS path only — read it with fs.read_file, or stage it on a connected runner with env.copy and convert it with env.exec. When the user asks about historical group files or attachments, use im_api.feishu.list_chat_files for top-level group-message attachments or im_api.feishu.get_thread_replies for a known thread. If the user needs a historical file inspected, copy the selected attachment's exact resource_ref unchanged into im_api.feishu.fetch_message_resource; never reconstruct or shorten message_id/file_key fields. If it completes asynchronously, wait for completion and call tool_call.get_result without offset or limit. Do not claim that Feishu history or group-message attachments are unavailable until the appropriate current-file input or historical provider operation has actually been attempted and returned that limitation.",
      "For an ordinary scheduled or proactive reminder, keep it owned by this Router/session and use schedule.create. For duration recurrence such as every 5 minutes, pass interval_minutes=5 with prompt and omit cron, run_at, and timezone. Use run_at only for one reminder time, or cron plus timezone for calendar recurrence, and always provide exactly one timing mode. The executable prompt must explicitly call im_api.feishu.send_text with connect_id=#{connect_id}, receive_id=#{chat_id}, exact text, and structured mentions after resolving member IDs. A delegated worker may compute content but must return it to this Router instead of sending directly to Feishu.",
      FeishuCalendarContract.instruction(),
      "Plain assistant text is only a runtime transcript entry and is not visible in Feishu. A requested reply is incomplete until the Feishu tool call succeeds. It is valid to stay silent when no reply is needed."
    ]
    |> Enum.join(" ")
  end

  def feishu(_metadata), do: ""
end
