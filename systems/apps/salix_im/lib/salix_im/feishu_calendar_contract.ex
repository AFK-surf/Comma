defmodule SalixIM.FeishuCalendarContract do
  @moduledoc """
  Executable prompt contract for Feishu Google Calendar creation parity.

  These clauses are shared by the provider manual, the live Router guidance,
  and the provider E2E harness. Keeping them as production-owned values makes
  the tests fail when an account-selection or exact-readback guarantee is
  removed from the prompt that the model actually receives.
  """

  @connection_clause "Call composio.list_connections and require an ACTIVE googlecalendar connection. If none exists, guide the user through authorization."
  @account_selection_clause "When more than one googlecalendar connection is ACTIVE and the user has not already selected one, stop before any Calendar mutation and ask which account to use."
  @account_pinning_clause "After an account is selected, pin its connected_account_id on every Calendar execute call."
  @notification_clause "Calendar-notification configuration is not a prerequisite for creation."
  @attendee_clause "Resolve structured_mentions through im_api.feishu.get_user and require email, exact time, and timezone before creating anything."
  @creation_clause "Inspect the Google Calendar Composio create tool and create one event with Google Meet conference data and attendee updates."
  @readback_clause "After creation, read back the exact event and confirm success only when event id, calendar, exact time and timezone, attendees, and Meet URL match."
  @reminder_clause "Calendar start notification is separately configured; do not promise it after creation, and create a schedule.create reminder only when the user explicitly requests a separate reminder."

  @doc "Complete production instruction used in Feishu Router prompts and manuals."
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

  @doc "Clause requiring an explicit choice before mutation when several accounts are active."
  def account_selection_clause, do: @account_selection_clause

  @doc "Clause requiring the chosen account id on every mutation/readback call."
  def account_pinning_clause, do: @account_pinning_clause

  @doc "Clause requiring exact post-create readback before success is claimed."
  def readback_clause, do: @readback_clause

  @doc "Clause keeping creation independent from optional Calendar notifications."
  def notification_clause, do: @notification_clause
end
