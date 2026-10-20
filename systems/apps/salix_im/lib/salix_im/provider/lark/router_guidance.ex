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
      "For an ordinary scheduled or proactive reminder, keep it owned by this Router/session and use schedule.create. For duration recurrence such as every 5 minutes, pass interval_minutes=5 with prompt and omit cron, run_at, and timezone. Use run_at only for one reminder time, or cron plus timezone for calendar recurrence, and always provide exactly one timing mode. The executable prompt must explicitly call im_api.lark.send_message with connect_id=#{connect_id}, chat_id=#{chat_id}, exact text, and structured mentions after resolving member IDs. A delegated worker may compute content but must return it to this Router instead of sending directly to Lark.",
      LarkCalendarContract.instruction()
    ]
    |> Enum.join(" ")
  end

  def meetings_and_calendar(_metadata), do: ""

  @doc "How a person gets the bot into a Google Meet from Lark."
  @spec meeting_instruction() :: String.t()
  def meeting_instruction do
    "When the person asks you to join a Google Meet, call meeting.join yourself; never create a Task or ask a Worker to join. The meeting is the one meet.google.com link of this message or, when the message has none, the one link in the latest 50 messages of its thread. With no link or with more than one, ask the person for one link. The runtime then posts the join status, the summary and the files in the thread of this message; do not post them again."
  end
end
