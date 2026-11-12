defmodule SalixMeet.CalendarChanges do
  @moduledoc """
  Change marks for meeting calendars.

  A Google Calendar source that applied changes marks its Comma Calendar. The
  calendar worker scans marked calendars before its rotation and removes a mark
  only if no newer change replaced it during the scan.
  """

  alias SalixStore.{Ids, Keys, S3}

  @doc "Called by `SalixCalendar.SourceActor` after a refresh that applied changes."
  def source_changed(group_id, calendar_id, "google_calendar") do
    if Ids.valid_group_id?(group_id) and Ids.valid_calendar_id?(calendar_id) do
      body = Jason.encode!(%{"at" => SystemsClock.system_time(:millisecond)})
      _ = S3.put(Keys.ctl_meet_calendar_change(group_id, calendar_id), body)
    end

    :ok
  end

  def source_changed(_group_id, _calendar_id, _adapter), do: :ok

  @doc "Read at most `limit` marks as `{group_id, calendar_id} => etag`."
  @spec read(pos_integer()) :: %{optional({String.t(), String.t()}) => String.t()}
  def read(limit) do
    prefix = Keys.ctl_meet_calendar_changes_prefix()

    case S3.list(prefix, max_keys: limit) do
      {:ok, %{objects: objects}} ->
        objects
        |> Enum.take(limit)
        |> Enum.flat_map(fn %{key: key, etag: etag} ->
          case key |> String.replace_prefix(prefix, "") |> String.split("/") do
            [group_id, file] -> [{{group_id, String.replace_suffix(file, ".json", "")}, etag}]
            _ -> []
          end
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  @doc "Remove a mark unless a newer change replaced it."
  def clear({group_id, calendar_id}, etag),
    do: S3.delete(Keys.ctl_meet_calendar_change(group_id, calendar_id), if_match: etag)
end
