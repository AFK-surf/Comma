defmodule SalixMeet.CalendarConfiguration do
  @moduledoc "Current meeting enrollment authority: Group settings override deployment defaults."
  alias SalixIM.ProviderConnects
  alias SalixStore.MeetingCalendarSettings

  def entries do
    defaults = Application.get_env(:salix_meet, :calendar_autojoin_channels, []) |> List.wrap()
    ids = Enum.map(defaults, & &1["connect_id"])

    with {:ok, connects} <- default_connects(ids),
         groups = connects |> Map.values() |> Enum.map(& &1["group_id"]),
         {:ok, settings} <- MeetingCalendarSettings.list(groups, 100) do
      overrides = MapSet.new(Enum.map(settings, & &1["group_id"]))

      inherited =
        Enum.reject(defaults, fn entry ->
          MapSet.member?(overrides, get_in(connects, [entry["connect_id"], "group_id"]))
        end)

      entries = inherited ++ Enum.filter(settings, & &1["enabled"])

      if fits_budget?(entries),
        do: {:ok, entries},
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

      {:error, :not_found} when is_nil(revision) ->
        defaults =
          Application.get_env(:salix_meet, :calendar_autojoin_channels, []) |> List.wrap()

        case Enum.filter(defaults, &(&1["connect_id"] == connect_id)) do
          [entry] -> {:ok, entry}
          _ -> {:error, :meeting_preparation_not_enrolled}
        end

      {:error, :not_found} ->
        {:error, :meeting_preparation_settings_changed}
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

  defp default_connects([]), do: {:ok, %{}}
  defp default_connects(ids), do: ProviderConnects.find_active_im_connects_by_ids(ids)

  defp fits_budget?(entries) do
    opts = Application.get_env(:salix_meet, :calendar_autojoin) || []
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
