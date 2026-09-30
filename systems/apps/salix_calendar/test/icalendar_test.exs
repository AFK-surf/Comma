defmodule SalixCalendar.ICalendarTest do
  use ExUnit.Case, async: true

  alias SalixCalendar.ICalendar

  defp event(uid, title, start, zone) do
    %{
      "object" => %{
        "@type" => "Event",
        "uid" => uid,
        "title" => title,
        "start" => start,
        "timeZone" => zone,
        "duration" => "PT30M",
        "status" => "confirmed"
      },
      "revision" => 1,
      "updated_at" => 1_787_000_000_000
    }
  end

  defp ms(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    DateTime.to_unix(dt, :millisecond)
  end

  test "emits exactly one VTIMEZONE per TZID with DST observances, and folds/escapes correctly" do
    items = [
      event(
        "urn:comma:calendar-item:cit1_a",
        "Plan, review & ship",
        "2026-07-15T10:00:00",
        "America/Los_Angeles"
      ),
      event("urn:comma:calendar-item:cit1_b", "与 XX 开会", "2026-09-01T19:00:00", "Asia/Tokyo")
    ]

    assert {:ok, ics} =
             ICalendar.render(items, ms("2026-01-01T00:00:00Z"), ms("2027-01-01T00:00:00Z"))

    # CRLF endings and one VTIMEZONE per distinct TZID.
    assert String.contains?(ics, "\r\n")
    assert count(ics, "BEGIN:VTIMEZONE") == 2
    assert count(ics, "TZID:America/Los_Angeles") == 1
    assert count(ics, "TZID:Asia/Tokyo") == 1

    # DST zone yields both a DAYLIGHT and a STANDARD observance, from tzdb.
    assert String.contains?(ics, "BEGIN:DAYLIGHT")
    assert String.contains?(ics, "TZOFFSETTO:-0700")
    assert String.contains?(ics, "TZOFFSETTO:-0800")
    # Fixed zone: standard only, +0900.
    assert String.contains?(ics, "TZOFFSETTO:+0900")

    # Local wall time keeps TZID and is not flattened to UTC.
    assert String.contains?(ics, "DTSTART;TZID=America/Los_Angeles:20260715T100000")
    assert String.contains?(ics, "DTSTART;TZID=Asia/Tokyo:20260901T190000")

    # TEXT escaping of comma; private class; stable UID.
    assert String.contains?(ics, "SUMMARY:Plan\\, review & ship")
    assert String.contains?(ics, "CLASS:PRIVATE")
    assert String.contains?(ics, "UID:urn:comma:calendar-item:cit1_b")

    # Every folded physical line is <= 75 octets.
    assert Enum.all?(String.split(ics, "\r\n"), &(byte_size(&1) <= 75))
  end

  test "fails explicitly on a timezone the tzdb cannot resolve" do
    items = [event("urn:comma:calendar-item:cit1_x", "x", "2026-07-15T10:00:00", "Mars/Phobos")]

    assert {:error, :unsupported_timezone} =
             ICalendar.render(items, ms("2026-01-01T00:00:00Z"), ms("2027-01-01T00:00:00Z"))
  end

  defp count(haystack, needle),
    do: haystack |> String.split(needle) |> length() |> Kernel.-(1)
end
