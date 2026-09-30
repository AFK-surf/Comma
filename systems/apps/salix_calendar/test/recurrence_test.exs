defmodule SalixCalendar.RecurrenceTest do
  use ExUnit.Case, async: true

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

  test "biweekly recurrence uses its declared first day of week after DTSTART" do
    base_item =
      weekday_item()
      |> put_in(["object", "start"], "2030-02-05T10:00:00")
      |> put_in(["object", "recurrenceRules"], [
        %{
          "@type" => "RecurrenceRule",
          "frequency" => "weekly",
          "interval" => 2,
          "byDay" => Enum.map(~w(tu su), &%{"@type" => "NDay", "day" => &1})
        }
      ])

    occurrences = fn first_day ->
      item =
        put_in(
          base_item,
          ["object", "recurrenceRules", Access.at(0), "firstDayOfWeek"],
          first_day
        )

      {:ok, views} =
        Recurrence.expand(
          item,
          unix_ms(~D[2030-02-05], ~T[00:00:00]),
          unix_ms(~D[2030-02-18], ~T[00:00:00])
        )

      Enum.map(views, &get_in(&1, ["occurrence_ref", "recurrence_key", "value"]))
    end

    assert occurrences.("mo") == ["2030-02-05T10:00:00", "2030-02-10T10:00:00"]
    assert occurrences.("su") == ["2030-02-05T10:00:00", "2030-02-17T10:00:00"]
  end

  test "weekly recurrence never expands before DTSTART across a month boundary" do
    item =
      weekday_item()
      |> put_in(["object", "start"], "2030-02-05T10:00:00")
      |> put_in(["object", "recurrenceRules"], [
        %{
          "@type" => "RecurrenceRule",
          "frequency" => "weekly",
          "interval" => 2,
          "firstDayOfWeek" => "su",
          "byDay" => Enum.map(~w(tu su), &%{"@type" => "NDay", "day" => &1})
        }
      ])

    assert {:ok, []} =
             Recurrence.expand(
               item,
               unix_ms(~D[2030-01-31], ~T[00:00:00]),
               unix_ms(~D[2030-02-04], ~T[00:00:00])
             )

    assert {:ok, [view]} =
             Recurrence.expand(
               item,
               unix_ms(~D[2030-02-05], ~T[00:00:00]),
               unix_ms(~D[2030-02-06], ~T[00:00:00])
             )

    assert get_in(view, ["occurrence_ref", "recurrence_key", "value"]) ==
             "2030-02-05T10:00:00"

    pre_start_ref =
      view
      |> put_in(["occurrence_ref", "recurrence_key", "value"], "2030-02-03T10:00:00")
      |> Map.fetch!("occurrence_ref")

    assert {:error, :occurrence_not_found} = Recurrence.resolve(item, pre_start_ref)

    explicit_item =
      put_in(item, ["object", "recurrenceOverrides"], %{
        "2030-02-03T10:00:00" => %{"start" => "2030-02-03T11:00:00"}
      })

    assert {:ok, [explicit_view]} =
             Recurrence.expand(
               explicit_item,
               unix_ms(~D[2030-02-03], ~T[00:00:00]),
               unix_ms(~D[2030-02-04], ~T[00:00:00])
             )

    assert get_in(explicit_view, ["occurrence_ref", "recurrence_key", "value"]) ==
             "2030-02-03T10:00:00"

    assert get_in(explicit_view, ["effective", "start"]) == "2030-02-03T11:00:00"

    assert {:ok, ^explicit_view} =
             Recurrence.resolve(explicit_item, explicit_view["occurrence_ref"])
  end

  test "interval queries include moved overrides whose original slot is outside the range" do
    item =
      weekday_item()
      |> put_in(["object", "recurrenceOverrides"], %{
        "2026-07-20T10:00:00" => %{"start" => "2026-07-18T11:00:00"}
      })

    assert {:ok, [view]} =
             Recurrence.expand(
               item,
               unix_ms(~D[2026-07-18], ~T[00:00:00]),
               unix_ms(~D[2026-07-19], ~T[00:00:00])
             )

    assert get_in(view, ["occurrence_ref", "recurrence_key", "value"]) ==
             "2026-07-20T10:00:00"

    assert get_in(view, ["effective", "start"]) == "2026-07-18T11:00:00"
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

  test "minutely Schedule projection expands elapsed intervals with a hard result cap" do
    item = %{
      "calendar_id" => "cal1_1200000000000000001",
      "scheduling_link_id" => "sln1_1200000000000000002",
      "revision" => 1,
      "object" => %{
        "@type" => "Task",
        "due" => "2026-07-20T02:00:00Z",
        "timeZone" => "UTC",
        "recurrenceRules" => [
          %{"@type" => "RecurrenceRule", "frequency" => "minutely", "interval" => 30}
        ]
      }
    }

    from = unix_ms(~D[2026-07-20], ~T[10:00:00])
    until = unix_ms(~D[2026-07-20], ~T[11:01:00])

    assert {:ok, views} = Recurrence.expand(item, from, until)

    assert Enum.map(views, &get_in(&1, ["effective", "start"])) == [
             "2026-07-20T02:00:00.000",
             "2026-07-20T02:30:00.000",
             "2026-07-20T03:00:00.000"
           ]

    assert {:error, :occurrence_limit_exceeded} =
             Recurrence.expand(item, from, until, limit: 2)
  end

  test "unsupported recurrence properties and wall-time minutely rules fail explicitly" do
    with_count =
      weekday_item()
      |> put_in(["object", "recurrenceRules", Access.at(0), "count"], 5)

    assert {:error, :unsupported_recurrence} =
             Recurrence.expand(
               with_count,
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-27], ~T[00:00:00])
             )

    local_minutely =
      with_count
      |> put_in(["object", "recurrenceRules"], [
        %{"@type" => "RecurrenceRule", "frequency" => "minutely", "interval" => 30}
      ])

    assert {:error, :unsupported_recurrence} =
             Recurrence.expand(
               local_minutely,
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-21], ~T[00:00:00])
             )

    excluded_rule =
      weekday_item()
      |> put_in(["object", "excludedRecurrenceRules"], [
        %{"@type" => "RecurrenceRule", "frequency" => "weekly", "interval" => 2}
      ])

    assert {:error, :unsupported_recurrence} =
             Recurrence.expand(
               excluded_rule,
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-27], ~T[00:00:00])
             )
  end

  test "expansion rejects unbounded recurrence work" do
    assert {:error, :recurrence_budget_exceeded} =
             Recurrence.expand(
               weekday_item(),
               unix_ms(~D[2026-01-01], ~T[00:00:00]),
               unix_ms(~D[2040-01-01], ~T[00:00:00]),
               day_budget: 30
             )
  end

  test "daily BYDAY excludes days outside the declared set" do
    item =
      weekday_item()
      |> put_in(["object", "recurrenceRules"], [
        %{
          "@type" => "RecurrenceRule",
          "frequency" => "daily",
          "byDay" => Enum.map(~w(mo tu we th fr), &%{"@type" => "NDay", "day" => &1})
        }
      ])

    assert {:ok, views} =
             Recurrence.expand(
               item,
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-27], ~T[00:00:00])
             )

    assert length(views) == 5

    assert {:ok, ^views} =
             Recurrence.expand(
               item,
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-27], ~T[00:00:00]),
               limit: 5
             )

    assert {:error, :occurrence_limit_exceeded} =
             Recurrence.expand(
               item,
               unix_ms(~D[2026-07-20], ~T[00:00:00]),
               unix_ms(~D[2026-07-27], ~T[00:00:00]),
               limit: 4
             )
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
