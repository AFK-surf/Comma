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

  test "an ending series generates no occurrence after its until" do
    item =
      put_in(
        weekday_item(),
        ["object", "recurrenceRules", Access.at(0), "until"],
        "2026-07-22T10:00:00"
      )

    assert {:ok, views} =
             Recurrence.expand(
               item,
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-27], ~T[00:00:00])
             )

    assert Enum.map(views, &get_in(&1, ["occurrence_ref", "recurrence_key", "value"])) == [
             "2026-07-20T10:00:00",
             "2026-07-21T10:00:00",
             "2026-07-22T10:00:00"
           ]

    after_until = %{
      "calendar_id" => item["calendar_id"],
      "scheduling_link_id" => item["scheduling_link_id"],
      "recurrence_key" => %{
        "kind" => "recurring",
        "value" => "2026-07-23T10:00:00",
        "value_kind" => "local_date_time",
        "time_zone" => "Asia/Shanghai"
      }
    }

    assert {:error, :occurrence_not_found} = Recurrence.resolve(item, after_until)

    assert {:error, :unsupported_recurrence} =
             item
             |> put_in(["object", "recurrenceRules", Access.at(0), "until"], "2026-07-22")
             |> Recurrence.expand(
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-27], ~T[00:00:00])
             )
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

  test "a monthly series on the 31st skips shorter months and keeps its local time across DST" do
    item =
      series_item("2026-01-31T09:00:00", "America/New_York", %{"frequency" => "monthly"})

    assert {:ok, views} =
             Recurrence.expand(
               item,
               utc_ms("2026-01-01T00:00:00Z"),
               utc_ms("2026-08-01T00:00:00Z")
             )

    assert Enum.map(views, &{recurrence_key(&1), &1["start_ms"]}) == [
             {"2026-01-31T09:00:00", utc_ms("2026-01-31T14:00:00Z")},
             {"2026-03-31T09:00:00", utc_ms("2026-03-31T13:00:00Z")},
             {"2026-05-31T09:00:00", utc_ms("2026-05-31T13:00:00Z")},
             {"2026-07-31T09:00:00", utc_ms("2026-07-31T13:00:00Z")}
           ]

    assert {:error, :occurrence_not_found} =
             Recurrence.resolve(item, occurrence_ref(item, "2026-02-28T09:00:00"))
  end

  test "a monthly series on an ordinal weekday follows its position, counted from either end" do
    second_thursday =
      series_item("2026-01-08T10:00:00", "Asia/Shanghai", %{
        "frequency" => "monthly",
        "interval" => 2,
        "byDay" => [%{"@type" => "NDay", "day" => "th", "nthOfPeriod" => 2}]
      })

    last_friday =
      series_item("2026-01-30T10:00:00", "Asia/Shanghai", %{
        "frequency" => "monthly",
        "byDay" => [%{"@type" => "NDay", "day" => "fr", "nthOfPeriod" => -1}]
      })

    from = unix_ms(~D[2026-01-01], ~T[00:00:00])
    to = unix_ms(~D[2026-05-01], ~T[00:00:00])

    assert {:ok, views} =
             Recurrence.expand(second_thursday, from, unix_ms(~D[2026-06-01], ~T[00:00:00]))

    assert Enum.map(views, &recurrence_key/1) == [
             "2026-01-08T10:00:00",
             "2026-03-12T10:00:00",
             "2026-05-14T10:00:00"
           ]

    assert {:ok, views} = Recurrence.expand(last_friday, from, to)

    assert Enum.map(views, &recurrence_key/1) == [
             "2026-01-30T10:00:00",
             "2026-02-27T10:00:00",
             "2026-03-27T10:00:00",
             "2026-04-24T10:00:00"
           ]
  end

  test "a yearly series on February 29 repeats only in leap years" do
    item = series_item("2024-02-29T10:00:00", "Asia/Shanghai", %{"frequency" => "yearly"})

    assert {:ok, views} =
             Recurrence.expand(
               item,
               unix_ms(~D[2024-01-01], ~T[00:00:00]),
               unix_ms(~D[2029-01-01], ~T[00:00:00])
             )

    assert Enum.map(views, &recurrence_key/1) == ["2024-02-29T10:00:00", "2028-02-29T10:00:00"]
  end

  test "a counted series ends at its last counted instance, and an excluded one still counts" do
    weekdays = hd(weekday_item()["object"]["recurrenceRules"])

    assert {:ok, until} = Recurrence.count_until(~N[2026-07-20 10:00:00], weekdays, 3)
    assert until == "2026-07-22T10:00:00"

    item =
      weekday_item()
      |> put_in(["object", "recurrenceRules", Access.at(0), "until"], until)
      |> put_in(["object", "recurrenceOverrides"], %{
        "2026-07-21T10:00:00" => %{"excluded" => true}
      })

    assert {:ok, views} =
             Recurrence.expand(
               item,
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-27], ~T[00:00:00])
             )

    assert Enum.map(views, &recurrence_key/1) == ["2026-07-20T10:00:00", "2026-07-22T10:00:00"]

    assert {:ok, "2026-05-31T09:00:00"} =
             Recurrence.count_until(~N[2026-01-31 09:00:00], %{"frequency" => "monthly"}, 3)
  end

  defp series_item(start, time_zone, rule) do
    %{
      "calendar_id" => "cal1_1200000000000000001",
      "scheduling_link_id" => "sln1_1200000000000000002",
      "revision" => 1,
      "object" => %{
        "@type" => "Event",
        "start" => start,
        "duration" => "PT30M",
        "timeZone" => time_zone,
        "recurrenceRules" => [Map.put(rule, "@type", "RecurrenceRule")]
      }
    }
  end

  defp occurrence_ref(item, value) do
    %{
      "calendar_id" => item["calendar_id"],
      "scheduling_link_id" => item["scheduling_link_id"],
      "recurrence_key" => %{
        "kind" => "recurring",
        "value" => value,
        "value_kind" => "local_date_time",
        "time_zone" => item["object"]["timeZone"]
      }
    }
  end

  defp recurrence_key(view), do: get_in(view, ["occurrence_ref", "recurrence_key", "value"])

  defp utc_ms(value),
    do: value |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_unix(:millisecond)

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
