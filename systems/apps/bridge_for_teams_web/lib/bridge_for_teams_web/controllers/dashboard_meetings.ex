defmodule BridgeForTeamsWeb.DashboardMeetings do
  @moduledoc """
  Meetings pages for `DashboardAPIController`: the upcoming meetings, the past
  meeting records and the team preparation settings of one Agent Swarm.

  Salix owns the settings and the calendar projection
  (`Salix.Bindings.MeetingPreparationDashboard`), so every read or write is one
  `MeetingPreparation.run/5` call and a fixed number of queries. The controller
  admits owners and admins only. Every list is bounded: upcoming meetings are
  the next 24 hours, at most 20; history, channels and calendar series are
  cursor pages.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.MeetingPreparation

  @personal_scopes ~w(users:read.email im:write chat:write)
  @settings_keys ~w(enabled mode connect_id channel channel_id calendar_selections preparation_lead_minutes research_enabled calendar_writeback series personal_preparation)
  @save_keys ~w(enabled connect_id channel_id calendar_selections preparation_lead_minutes research_enabled calendar_writeback autojoin personal_preparation series)
  @invalid ~w(meeting_personal_scopes_missing meeting_personal_scopes_unknown calendar_enrollment_no_active_account meeting_calendar_connect_unavailable invalid_meeting_preparation_settings invalid_meeting_preparation_request meeting_calendar_capacity_exceeded meeting_preparation_not_configured invalid)a

  @doc "Saved settings, Slack bots and the next 24 hours of meetings."
  def overview(org, user, project_id) do
    with {:ok, overview} <- run(org, user, project_id, "overview", %{}) do
      settings = overview["settings"] || %{}
      calendar = overview["calendar"] || %{}

      {:ok,
       %{
         "settings" => Map.take(settings, @settings_keys),
         "connects" => Enum.map(overview["connects"] || [], &public_connect(&1, settings)),
         "events" => Enum.map(calendar["events"] || [], &public_event(&1, settings)),
         "calendar_health" => calendar["health"],
         "truncated" => get_in(calendar, ["projection", "truncated"]) == true,
         "runtime_enabled" => overview["runtime_enabled"] == true
       }}
    end
  end

  @doc "One bounded read: `history`, `catalog`, `channels`, `series` or `detail`."
  def read(org, user, project_id, "history", params) do
    case run(org, user, project_id, "history", %{"cursor" => params["cursor"]}) do
      {:ok, page} ->
        meetings =
          for meeting <- page["meetings"] || [], do: Map.update(meeting, "title", nil, &title/1)

        {:ok, Map.put(page, "meetings", meetings)}

      # An empty page would read as "no meetings"; say that it is not.
      {:error, 503, _code, _message, details} ->
        {:error, 503, "history_unavailable",
         gettext(
           "Meeting history is unavailable. Refresh to try again. This does not mean there are no meeting records."
         ), details}

      error ->
        error
    end
  end

  def read(org, user, project_id, "catalog", params) do
    with {:ok, catalog} <- run(org, user, project_id, "catalog", Map.take(params, ["connect_id"])) do
      {:ok,
       %{
         "calendars" =>
           Enum.map(
             catalog["calendars"] || [],
             &Map.take(&1, ~w(account_id calendar_id name account_name))
           ),
         "channels" => catalog["channels"] || [],
         "next_cursor" => catalog["next_cursor"]
       }}
    end
  end

  def read(org, user, project_id, "channels", params),
    do: run(org, user, project_id, "channels", Map.take(params, ~w(connect_id cursor)))

  def read(org, user, project_id, "series", params) do
    attrs = Map.take(params, ~w(account_id calendar_id cursor))

    with {:ok, page} <- run(org, user, project_id, "series", attrs) do
      {:ok,
       %{
         "meetings" =>
           for meeting <- page["meetings"] || [] do
             meeting
             |> Map.take(~w(event_id title recurring start))
             |> Map.merge(Map.take(attrs, ~w(account_id calendar_id)))
           end,
         "next_cursor" => page["next_cursor"]
       }}
    end
  end

  def read(org, user, project_id, "detail", params) do
    case MeetingPreparation.run(org, user, project_id, "detail", %{
           "meeting_plan_id" => params["plan"]
         }) do
      {:ok, detail} when is_map(detail) ->
        {:ok, %{"report" => detail["report"]}}

      # The plan is gone, or no longer belongs to the saved settings.
      {:error, reason}
      when reason in [:meeting_not_found, :not_found, :meeting_preparation_settings_changed] ->
        {:error, 404, "meeting_not_found",
         gettext("This meeting changed or its report is unavailable. Refresh the meeting list."),
         %{}}

      {:error, reason} ->
        error(reason)

      _other ->
        error(:unavailable)
    end
  end

  def read(_org, _user, _project_id, _read, _params), do: error(:invalid)

  @doc """
  Save and enable the team preparation, or pause it with `enabled: false`.
  Salix validates every field against the live calendar and Slack catalogs.
  """
  def save(org, user, project_id, params) do
    attrs =
      if params["enabled"] == false,
        do: %{"enabled" => false},
        else: Map.take(params, @save_keys)

    with {:ok, settings} <- run(org, user, project_id, "save", attrs) do
      {:ok, %{"settings" => Map.take(settings, @settings_keys)}}
    end
  end

  defp run(org, user, project_id, action, attrs) do
    case MeetingPreparation.run(org, user, project_id, action, attrs) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, reason} -> error(reason)
      _other -> error(:unavailable)
    end
  end

  defp public_connect(connect, settings) do
    connect
    |> Map.take(~w(connect_id app_name bot_username workspace_name))
    |> Map.merge(%{
      "state" => connect_state(connect),
      "preparation" =>
        cond do
          settings["connect_id"] != connect["connect_id"] -> "not_configured"
          settings["enabled"] == true -> "enabled"
          true -> "paused"
        end,
      "missing_scopes" => missing_scopes(connect["oauth_bot_scopes"])
    })
  end

  defp connect_state(connect) do
    cond do
      connect["disabled_at"] != nil or connect["oauth_completed_at"] == nil -> "unconnected"
      not (is_binary(connect["workspace_id"]) and connect["workspace_id"] != "") -> "unavailable"
      true -> "connected"
    end
  end

  # Attendee DMs need three Slack scopes; `nil` means the grant is unknown.
  defp missing_scopes(%{"status" => "known", "scopes" => scopes}) when is_list(scopes),
    do: Enum.reject(@personal_scopes, &(&1 in scopes))

  defp missing_scopes(_unknown), do: nil

  defp public_event(event, settings) do
    event
    |> Map.take(~w(meeting_plan_id title start_ms))
    |> Map.put("status", event_status(event["plan"] || %{}, settings))
  end

  defp event_status(plan, settings) do
    preparation = plan["preparation"] || %{}

    cond do
      plan["settings_revision"] != settings["settings_revision"] -> "updating"
      plan["status"] != "planned" -> "failed"
      preparation["card_status"] == "sent" -> "queued"
      preparation["card_status"] == "abandoned" -> "not_sent"
      preparation["report_available"] -> "ready"
      preparation["deadline_status"] == "diagnostic_only" -> "timed_out"
      preparation["research_started"] -> "preparing"
      true -> "scheduled"
    end
  end

  # Older records can carry the Slack trigger message as their title. The
  # record stays untouched; the page shows a recognized title or first line.
  defp title(raw) do
    raw = String.trim(raw || "")

    candidate =
      cond do
        match = Regex.run(~r/\*Meeting prep:\s*([^*\n]+)\*/, raw) ->
          Enum.at(match, 1)

        match = Regex.run(~r/^(?::date:\s*)?Meeting prep:\s*(.+?)\s+Time:\s*\d{4}-/, raw) ->
          Enum.at(match, 1)

        match = Regex.run(~r/Calendar event:\s*`([^`]+)`/, raw) ->
          Enum.at(match, 1)

        match = Regex.run(~r/^\*([^*\n]+)\*\s+https?:\/\//, raw) ->
          Enum.at(match, 1)

        Regex.match?(~r/^(?:join\s+)?To join the video meeting,/i, raw) ->
          ""

        true ->
          raw |> String.split(~r/\r?\n/, parts: 2) |> List.first()
      end
      |> String.trim()

    cond do
      candidate == "" -> nil
      String.length(candidate) > 160 -> String.slice(candidate, 0, 159) <> "…"
      true -> candidate
    end
  end

  defp error(:project_not_found),
    do: {:error, 404, "project_not_found", gettext("Agent Swarm not found."), %{}}

  defp error(:meeting_history_scope_unavailable),
    do:
      {:error, 409, "history_scope_unavailable",
       gettext(
         "History needs a configured public team channel. Private channels are not shown because Dashboard logins do not verify Slack membership."
       ), %{}}

  defp error(:meeting_channel_invalid),
    do:
      {:error, 422, "invalid_meeting_settings", gettext("Choose a channel the bot has joined."),
       %{"fields" => %{"channel_id" => [gettext("Choose a channel the bot has joined.")]}}}

  defp error(reason) when reason in @invalid,
    do: {:error, 422, "invalid_meeting_settings", invalid_message(reason), %{}}

  defp error(_reason),
    do:
      {:error, 503, "runtime_unavailable",
       gettext(
         "Meeting preparation is temporarily unavailable. Your saved settings have not been replaced by this page."
       ), %{}}

  defp invalid_message(:meeting_personal_scopes_missing),
    do:
      gettext(
        "This bot is missing Slack permissions for attendee DMs. Reconnect it, then try again."
      )

  defp invalid_message(:meeting_personal_scopes_unknown),
    do:
      gettext(
        "This bot's Slack permissions are unknown. Reconnect it before enabling attendee DMs."
      )

  defp invalid_message(:calendar_enrollment_no_active_account),
    do: gettext("Connect a Google Calendar account for this Agent Swarm first.")

  defp invalid_message(:meeting_calendar_connect_unavailable),
    do: gettext("Reconnect Slack, then try again.")

  defp invalid_message(:meeting_calendar_capacity_exceeded),
    do:
      gettext(
        "The meeting service has reached its configured capacity. Contact your administrator."
      )

  defp invalid_message(_reason),
    do: gettext("Check the selected calendars, meeting and channel, then save again.")
end
