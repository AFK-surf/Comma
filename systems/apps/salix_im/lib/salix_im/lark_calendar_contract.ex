defmodule SalixIM.LarkCalendarContract do
  @moduledoc """
  What the Agent is told about making a Google Calendar meeting for a person
  who asked in Lark.

  The Lark manual and the Lark Router guidance both read these clauses, so
  the two cannot drift apart. The clauses are the Feishu ones
  (`SalixIM.FeishuCalendarContract`), with the Lark operation names.
  """

  @connection_clause "Call composio.list_connections and require an ACTIVE googlecalendar connection. If none exists, guide the user through authorization."
  @account_selection_clause "When more than one googlecalendar connection is ACTIVE and the user has not already selected one, stop before any Calendar mutation and ask which account to use."
  @account_pinning_clause "After an account is selected, pin its connected_account_id on every Calendar execute call."
  @notification_clause "Calendar-notification configuration is not a prerequisite for creation."
  @attendee_clause "Resolve structured_mentions through im_api.lark.get_user and require email, exact time, and timezone before creating anything."
  @creation_clause "Inspect the Google Calendar Composio create tool and create one event with Google Meet conference data and attendee updates."
  @readback_clause "After creation, read back the exact event and confirm success only when event id, calendar, exact time and timezone, attendees, and Meet URL match."
  @reminder_clause "Calendar start notification is separately configured; do not promise it after creation, and create a schedule.create reminder only when the user explicitly requests a separate reminder."

  @doc "The whole instruction, as the Lark Router guidance and the Lark manual give it."
  @spec instruction() :: String.t()
  def instruction do
    [
      "For a Google Calendar meeting, use the same group-scoped Composio path as Slack.",
      @connection_clause,
      @account_selection_clause,
      @account_pinning_clause,
      @notification_clause,
      @attendee_clause,
      @creation_clause,
      @readback_clause,
      @reminder_clause
    ]
    |> Enum.join(" ")
  end
end
