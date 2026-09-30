defmodule Salix.Bindings.MeetingCalendarPreparation do
  @moduledoc "Calendar effects resolve their account and event from the enrolled meeting plan."
  @behaviour SalixMeet.Ports.CalendarPreparation

  alias Salix.Bindings.GoogleCalendarSource
  alias SalixCalendar.{Occurrences, Server}

  @impl true
  def write(%{"calendar_writeback" => true} = plan) do
    with :ok <- SalixMeet.MeetingPlan.validate_report(plan),
         {:ok, source, item, occurrence} <- resolve(plan),
         :ok <- authorize_writeback(plan, source) do
      GoogleCalendarSource.write_preparation(
        source,
        item,
        occurrence,
        get_in(plan, ["preparation", "report"])
      )
    end
  end

  def write(_plan), do: {:ok, %{"status" => "disabled"}}

  def read_attendees(plan) do
    with {:ok, source, item, occurrence} <- resolve(plan) do
      GoogleCalendarSource.read_attendees(source, item, occurrence)
    end
  end

  defp authorize_writeback(plan, source) do
    with {:ok, %{"calendar_writeback" => true} = entry} <-
           SalixMeet.CalendarConfiguration.enrollment(plan),
         {:ok, %{group: group}} <- SalixMeet.CalendarEnrollmentCache.load(entry),
         true <- group["group_id"] == plan["group_id"] and group["calendar_writeback"] == true,
         true <- Enum.any?(group["calendars"], &(&1["source_id"] == source["source_id"])) do
      :ok
    else
      _ -> {:error, :calendar_writeback_not_authorized}
    end
  end

  defp resolve(plan) do
    ref = plan["occurrence_ref"]
    group_id = plan["group_id"]

    with {:ok, %{"item" => item, "occurrence" => occurrence}} <-
           Occurrences.get(group_id, ref["calendar_id"], plan["calendar_item_id"], ref,
             source_ids: plan["calendar_source_ids"]
           ),
         %{"kind" => "source", "source_id" => source_id} <- item["origin"],
         {:ok, %{"adapter" => "google_calendar"} = source} <-
           Server.get_source(group_id, ref["calendar_id"], source_id) do
      {:ok, source, item, occurrence}
    else
      {:error, _} = error -> error
      _ -> {:error, :meeting_calendar_source_unavailable}
    end
  end
end
