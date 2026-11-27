defmodule Salix.Bindings.MemberMeetingStatus do
  @moduledoc """
  Bounded, read-only view of the next 24 hours of meetings on members' own
  calendars (`calendar_scope` `members`) for the dashboard.

  Each member unit has its own projection. A meeting on several members'
  calendars has one `meeting_id` and one MeetingPlan per copy, so it is one
  row. The row takes its plan from the copy the meeting's preparer record
  names (`Salix.Bindings.MeetingCalendar.preparer_ref/3`), else from the
  first copy, and names that plan's `personal_recipients` when it prepares.

  One read is at most 25 projection reads (at most 20 entries each, as
  `SalixMeet.CalendarProjection.status/2`), then at most two reads for each
  of at most 20 rows (the preparer record and one plan; only the plan when
  the Group's reminders are off), 8 reads at a time. It never reads a
  calendar provider and never creates or changes a MeetingPlan. More units
  than the cap, or more meetings than the limit, set `projection.truncated`.
  """

  alias Salix.Bindings.{MeetingCalendar, MeetingCalendarStatus}
  alias SalixMeet.{CalendarAutojoin, CalendarProjection, MeetingPlan}
  alias SalixStore.JSON

  @max_units 25
  @max_events 20
  @concurrency 8
  @timeout 2_000
  @window_ms 24 * 60 * 60 * 1_000

  @doc """
  The members' meetings of one enrolled Group (`CalendarEnrollmentCache`).
  `now:` sets the start of the 24-hour window.
  """
  def get(%{"calendar_scope" => "members"} = enrolled, limit \\ @max_events, opts \\ [])
      when is_integer(limit) and limit in 1..@max_events do
    group_id = enrolled["group_id"]
    units = CalendarAutojoin.scan_units(enrolled)
    now = Keyword.get_lazy(opts, :now, fn -> SystemsClock.system_time(:millisecond) end)

    projections =
      units
      |> Enum.take(@max_units)
      |> bounded(fn unit ->
        CalendarProjection.member_status(group_id, unit["calendar_id"], limit)
      end)

    read = for {:ok, projection} <- projections, do: projection

    meetings =
      read
      |> Enum.flat_map(& &1["entries"])
      |> Enum.filter(&upcoming?(&1["event"], now))
      |> Enum.group_by(& &1["meeting_id"])
      |> Enum.sort_by(fn {meeting_id, [copy | _]} ->
        {copy["event"]["start_ms"], meeting_id}
      end)

    rows = bounded(Enum.take(meetings, limit), &row(enrolled, &1))
    events = for {:ok, event} <- rows, do: event

    {:ok,
     %{
       "health" =>
         cond do
           length(read) < length(projections) or length(events) < length(rows) -> "degraded"
           units != [] and Enum.all?(read, &(&1["state"] == "not_scanned")) -> "pending"
           true -> "members"
         end,
       "member_calendars" => length(units),
       "projection" => %{
         "truncated" =>
           length(units) > @max_units or length(meetings) > limit or
             Enum.any?(read, & &1["truncated"])
       },
       "events" => events
     }}
  end

  # Still to start or under way, and starting within 24 hours.
  defp upcoming?(%{"start_ms" => start_ms} = event, now) when is_integer(start_ms) do
    ends = if is_integer(event["end_ms"]), do: event["end_ms"], else: start_ms
    start_ms <= now + @window_ms and ends > now
  end

  defp upcoming?(_event, _now), do: false

  defp row(enrolled, {meeting_id, [first | _] = copies}) do
    event = (preparer_copy(enrolled, copies) || first)["event"]
    plan = read_plan(enrolled["group_id"], event["meeting_plan_id"])

    {:ok,
     %{
       "meeting_id" => meeting_id,
       "title" => MeetingCalendarStatus.public_title(event["title"]),
       "start_ms" => event["start_ms"],
       "end_ms" => event["end_ms"],
       "meeting_plan_id" => event["meeting_plan_id"],
       "recipients" => recipients(plan),
       "plan" => plan_view(plan)
     }}
  end

  # The copy the meeting's preparer record names, among the copies read. With
  # the Group's reminders off no copy prepares, so the record is not read.
  defp preparer_copy(%{"personal_preparation" => true} = enrolled, [first | _] = copies) do
    event = first["event"]

    case MeetingCalendar.preparer_ref(
           enrolled["group_id"],
           event["meet_url"],
           event["start_ms"]
         ) do
      {:ok, ref} when is_map(ref) ->
        Enum.find(copies, &(JSON.stringify(&1["event"]["occurrence_ref"] || %{}) == ref))

      _no_record_or_unreadable ->
        nil
    end
  end

  defp preparer_copy(_enrolled, _copies), do: nil

  defp read_plan(group_id, plan_id) when is_binary(plan_id) and plan_id != "" do
    case MeetingPlan.get(group_id, plan_id) do
      {:ok, plan} -> {:ok, plan}
      {:error, :not_found} -> {:error, :missing}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp read_plan(_group_id, _plan_id), do: {:error, :missing}

  defp plan_view({:ok, plan}) do
    plan
    |> MeetingCalendarStatus.plan_summary()
    |> Map.put("personal_preparation", plan["personal_preparation"] == true)
    |> put_in(["preparation", "personal_status"], plan["preparation"]["personal_status"])
  end

  defp plan_view({:error, reason}), do: %{"status" => to_string(reason)}

  # The members whose calendars hold the meeting, as the preparer's plan
  # names them, each flagged when Slack has no member with that email
  # (`personal_unmatched`). A Feishu/Lark meeting names its people by open_id
  # and has no named recipients.
  defp recipients({:ok, %{"personal_preparation" => true} = plan}) do
    unmatched =
      if get_in(plan, ["publication_target", "provider"]) == "slack",
        do: List.wrap(get_in(plan, ["preparation", "personal_unmatched"])),
        else: []

    plan["personal_recipients"]
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@max_units)
    |> Enum.map(&%{"email" => &1, "slack_unmatched" => &1 in unmatched})
  end

  defp recipients(_plan), do: []

  defp bounded(items, fun) do
    items
    |> SystemsClock.async_stream(fun,
      max_concurrency: @concurrency,
      timeout: @timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, {:ok, _} = result} -> result
      {:ok, {:error, _} = error} -> error
      {:exit, reason} -> {:error, {:exit, reason}}
    end)
  end
end
