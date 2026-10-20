defmodule SalixCalendar.RecurrenceTest do
  use SystemsClock.Case, async: true

  alias SalixCalendar.Recurrence

  test "weekday recurrence excludes weekends and moved overrides keep the original recurrence key" do
    item = weekday_item()

    overrides = %{
      "2026-07-21T10:00:00" => %{"excluded" => true},
      "2026-07-22T10:00:00" => %{"start" => "2026-07-22T11:30:00"}
    }

    item = put_in(item, ["object", "recurrenceOverrides"], overrides)

    assert {:ok, views} =
             Recurrence.expand(
               item,
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-27], ~T[00:00:00])
             )

    assert length(views) == 4

    assert Enum.map(views, &get_in(&1, ["occurrence_ref", "recurrence_key", "value"])) == [
             "2026-07-20T10:00:00",
             "2026-07-22T10:00:00",
             "2026-07-23T10:00:00",
             "2026-07-24T10:00:00"
           ]

    moved = Enum.at(views, 1)
    assert get_in(moved, ["effective", "start"]) == "2026-07-22T11:30:00"

    assert {:ok, ^moved} = Recurrence.resolve(item, moved["occurrence_ref"])

    mismatched_ref =
      moved
      |> put_in(["occurrence_ref", "recurrence_key", "time_zone"], "UTC")
      |> Map.fetch!("occurrence_ref")

    assert {:error, :invalid_occurrence_ref} = Recurrence.resolve(item, mismatched_ref)
  end

  test "interval queries include long recurrences that started before the range" do
    item =
      weekday_item()
      |> put_in(["object", "duration"], "P2D")
      |> put_in(["object", "recurrenceRules", Access.at(0), "byDay"], [
        %{"@type" => "NDay", "day" => "mo"}
      ])

    assert {:ok, [view]} =
             Recurrence.expand(
               item,
               unix_ms(~D[2026-07-21], ~T[12:00:00]),
               unix_ms(~D[2026-07-21], ~T[13:00:00])
             )

    assert get_in(view, ["occurrence_ref", "recurrence_key", "value"]) ==
             "2026-07-20T10:00:00"
  end

  test "DST gaps use the pre-transition offset and all-day duration ends at local midnight" do
    timed = %{
      "calendar_id" => "cal1_1200000000000000001",
      "scheduling_link_id" => "sln1_1200000000000000002",
      "revision" => 1,
      "object" => %{
        "@type" => "Event",
        "start" => "2024-03-10T02:30:00",
        "duration" => "PT30M",
        "timeZone" => "America/Los_Angeles"
      }
    }

    from =
      DateTime.from_iso8601("2024-03-10T00:00:00Z") |> elem(1) |> DateTime.to_unix(:millisecond)

    until =
      DateTime.from_iso8601("2024-03-11T00:00:00Z") |> elem(1) |> DateTime.to_unix(:millisecond)

    expected =
      DateTime.from_iso8601("2024-03-10T10:30:00Z") |> elem(1) |> DateTime.to_unix(:millisecond)

    assert {:ok, [%{"start_ms" => ^expected}]} = Recurrence.expand(timed, from, until)

    all_day =
      timed
      |> put_in(["object", "start"], "2024-03-10")
      |> put_in(["object", "duration"], "P1D")

    assert {:ok, [%{"start_ms" => start_ms, "end_ms" => end_ms}]} =
             Recurrence.expand(all_day, from, until)

    assert end_ms - start_ms == :timer.hours(23)
  end

  defp weekday_item do
    %{
      "calendar_id" => "cal1_1200000000000000001",
      "scheduling_link_id" => "sln1_1200000000000000002",
      "revision" => 7,
      "object" => %{
        "@type" => "Event",
        "start" => "2026-07-20T10:00:00",
        "duration" => "PT30M",
        "timeZone" => "Asia/Shanghai",
        "recurrenceRules" => [
          %{
            "@type" => "RecurrenceRule",
            "frequency" => "weekly",
            "byDay" => Enum.map(~w(mo tu we th fr), &%{"@type" => "NDay", "day" => &1})
          }
        ]
      }
    }
  end

  defp unix_ms(date, time) do
    date
    |> DateTime.new!(time, "Asia/Shanghai")
    |> DateTime.to_unix(:millisecond)
  end
end
