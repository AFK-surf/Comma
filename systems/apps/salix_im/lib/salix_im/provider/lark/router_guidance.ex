defmodule SalixIM.Provider.Lark.RouterGuidance do
  @moduledoc """
  What the Router is told, with a Lark message, about Google Meet meetings,
  scheduled reminders and Google Calendar.

  The reply hint of a Lark message (`SalixIM.AgentDeliveryPayload`) and the
  guidance of a Lark Conversation message (`SalixIM.ConversationDelivery`)
  both end with this text. The Lark manual gives the same rules at length.
  """

  alias SalixIM.LarkCalendarContract

  @doc "The guidance for a message with this source metadata."
  @spec meetings_and_calendar(map()) :: String.t()
  def meetings_and_calendar(metadata) when is_map(metadata) do
    connect_id = metadata["connect_id"]
    chat_id = metadata["chat_id"]

    [
      meeting_instruction(),
      "Use schedule.create for a reminder: a message whose text is known now, sent by this Router at a time or on a cadence. For duration recurrence such as every 5 minutes, pass interval_minutes=5 with prompt and omit cron, run_at, and timezone. Use run_at only for one reminder time, or cron plus timezone for calendar recurrence, and always provide exactly one timing mode. The executable prompt must explicitly call im_api.lark.send_message with connect_id=#{connect_id}, chat_id=#{chat_id}, exact text, and structured mentions after resolving member IDs. Work that repeats or keeps watching something (a recurring check, digest or monitor: anything that must look something up or decide at each run) is a Loop Task: im_api.internal.task.create with loop, whose Worker runs it and reports each run as the Task says. When that Task's Worker or Loop fails, continue in that Task and send the follow-up there; do not move the work to schedule.create. A delegated worker that computes a reminder's content returns it to this Router instead of sending directly to Lark.",
      LarkCalendarContract.instruction()
    ]
    |> Enum.join(" ")
  end

  def meetings_and_calendar(_metadata), do: ""

  @doc "How a person gets the bot into a Google Meet or a Lark video meeting from Lark."
  @spec meeting_instruction() :: String.t()
  def meeting_instruction do
    "When the person asks you to join a Google Meet, call meeting.join yourself; never create a Task or ask a Worker to join. The meeting is the one meet.google.com link of this message or, when the message has none, the one link in the latest 50 messages of its thread. With no link or with more than one, ask the person for one link. The runtime then posts the join status, the summary and the files in the thread of this message; do not post them again. A Lark video meeting is different: meeting.join cannot enter it. A person invites the bot from the participant list of the running meeting."
  end
end
