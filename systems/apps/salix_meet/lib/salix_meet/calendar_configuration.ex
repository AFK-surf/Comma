defmodule SalixMeet.CalendarConfiguration do
  @moduledoc "Current meeting enrollment authority: each Group's saved meeting settings."
  import Ecto.Query

  alias SalixStore.MeetingCalendarSettings

  @lark_platforms ~w(feishu lark)

  @doc """
  Whether a Slack team preparation may have no team channel. Its channel
  notice must be off, and each meeting must still reach someone: a joined
  meeting's thread goes to its organizer by direct message, and a meeting
  that is only prepared sends the attendees' personal notices.
  """
  def team_channel_optional?(entry) when is_map(entry) do
    entry["channel_notice"] == false and
      if entry["mode"] == "prepare",
        do: entry["personal_preparation"] == true,
        else: entry["delivery"] == "organizer"
  end

  def entries do
    with {:ok, settings} <- MeetingCalendarSettings.list(100) do
      if fits_budget?(settings),
        do: {:ok, settings},
        else: {:error, :meeting_calendar_capacity_exceeded}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :meeting_calendar_settings_unavailable}
  end

  # Effect authorization must fail closed when current settings cannot be read.
  def authorized_entries do
    case entries() do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  # A preparation read/effect needs only its Group's authority. Do not load
  # every Group setting or resolve unrelated provider connections here.
  def enrollment(plan) do
    connect_id = get_in(plan, ["publication_target", "params", "connect_id"])

    revision =
      if plan["managed_calendar"] == true, do: get_in(plan, ["preparation", "policy_revision"])

    case MeetingCalendarSettings.get(plan["group_id"]) do
      {:ok, settings} ->
        if settings["enabled"] == true and settings["settings_revision"] == revision and
             settings["connect_id"] == connect_id,
           do: {:ok, settings},
           else: {:error, :meeting_preparation_settings_changed}

      {:error, :not_found} ->
        {:error, :meeting_preparation_not_enrolled}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :meeting_calendar_settings_unavailable}
  end

  # A saved Group setting is the authority for a managed plan. Changing the
  # source, destination, or enabled state revokes its old revision before a
  # new effect is admitted. Already accepted provider-outbox work is unchanged.
  def authorize_plan(plan) do
    revision =
      if plan["managed_calendar"] == true, do: get_in(plan, ["preparation", "policy_revision"])

    authorize_revision(plan["group_id"], revision)
  end

  def authorize_group(group),
    do: authorize_revision(group["group_id"], group["settings_revision"])

  defp authorize_revision(group_id, revision) do
    case MeetingCalendarSettings.get(group_id) do
      {:ok, settings} ->
        if settings["enabled"] == true and settings["settings_revision"] == revision,
          do: :ok,
          else: {:error, :meeting_preparation_settings_changed}

      {:error, :not_found} when is_nil(revision) ->
        :ok

      {:error, :not_found} ->
        {:error, :meeting_preparation_settings_changed}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :meeting_calendar_settings_unavailable}
  end

  @doc """
  The Group's connected Slack, Feishu and Lark bots, oldest first: the
  places a meeting setting may send to, and the bots that join a meeting.
  """
  def meeting_bots(group_id) do
    case SalixIM.ProviderConnects.list_group_im_connects(group_id) do
      {:ok, connects} ->
        connects
        |> Enum.filter(&connected?/1)
        |> Enum.sort_by(&{&1["created_at"] || 0, &1["connect_id"]})
        |> Enum.map(fn connect ->
          %{
            "platform" => connect["provider"],
            "connect_id" => connect["connect_id"],
            "name" =>
              Enum.find(
                [connect["app_name"], connect["bot_username"], connect["workspace_name"]],
                connect["connect_id"],
                &(is_binary(&1) and String.trim(&1) != "")
              )
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp connected?(%{"provider" => "slack"} = connect),
    do: is_nil(connect["disabled_at"]) and is_integer(connect["oauth_completed_at"])

  defp connected?(%{"provider" => provider} = connect) when provider in @lark_platforms,
    do: is_nil(connect["disabled_at"]) and connect["status"] == "connected"

  defp connected?(_connect), do: false

  @doc """
  One extra line for a meeting notice sent by `provider`'s bot, once per
  Group: when the Group has a Slack bot and a Feishu/Lark bot and no admin
  chose where meeting notices go, it says they can go to the other platform.
  The first caller records it in the settings (no new revision), so no
  other notice repeats it. Anything unreadable gives no line.
  """
  def destination_hint(group_id, provider) when is_binary(group_id) and group_id != "" do
    with {:ok, settings} <- MeetingCalendarSettings.get(group_id),
         false <-
           is_integer(settings["destination_confirmed_at"]) or
             Map.has_key?(settings, "destination_hint_at"),
         other when other != "" <- other_platform(group_id, provider),
         {1, _} <- record_hint(group_id) do
      if provider == "feishu",
        do: "提醒、入会通知和会议纪要也可以发到 #{other}。管理员可以直接告诉我切换，或在管理后台的「会议」页面修改。",
        else:
          "Reminders, join notices and minutes can also go to #{other}. An admin can tell me to switch, or change it on the dashboard's Meetings page."
    else
      _ -> ""
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> ""
  end

  def destination_hint(_group_id, _provider), do: ""

  defp other_platform(group_id, provider) do
    platforms = group_id |> meeting_bots() |> Enum.map(& &1["platform"]) |> Enum.uniq()

    names =
      if provider in @lark_platforms,
        do: Enum.filter(["slack"], &(&1 in platforms)),
        else: Enum.filter(@lark_platforms, &(&1 in platforms))

    names
    |> Enum.map(&%{"slack" => "Slack", "feishu" => "Feishu", "lark" => "Lark"}[&1])
    |> Enum.join(" / ")
  end

  # Only a Group that has not had the line yet takes it.
  defp record_hint(group_id) do
    now = SystemsClock.system_time(:millisecond)

    SalixStore.Repo.update_all(
      from(r in MeetingCalendarSettings.Row,
        where:
          r.group_id == ^group_id and
            not fragment("jsonb_exists(?, 'destination_hint_at')", r.configuration) and
            not fragment("jsonb_exists(?, 'destination_confirmed_at')", r.configuration),
        update: [
          set: [
            configuration:
              fragment("? || ?", r.configuration, type(^%{"destination_hint_at" => now}, :map))
          ]
        ]
      ),
      []
    )
  end

  defp fits_budget?(entries) do
    opts = SystemsRuntime.get_env(:salix_meet, :calendar_autojoin) || []
    maximum = Keyword.get(opts, :max_groups_per_pass, 25)
    concurrency = Keyword.get(opts, :max_concurrency, 5)
    timeout = Keyword.get(opts, :task_timeout_ms, 30_000)

    length(entries) <= maximum and
      SalixStore.ConfigJson.calendar_autojoin_work_fits_lease?(entries,
        max_concurrency: concurrency,
        task_timeout_ms: timeout
      )
  end
end
