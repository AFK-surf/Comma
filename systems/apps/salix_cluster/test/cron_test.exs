defmodule SalixCluster.CronTest do
  @moduledoc """
  Pure wall-clock cron math (`SalixCluster.Cron`): parsing, strictly-after
  next-occurrence, latest-at-or-before, IANA timezone conversion, and the two
  DST return shapes. Deterministic — no store, no clock.
  """
  use ExUnit.Case, async: true

  alias SalixCluster.Cron

  # Build a unix-ms instant from a wall-clock time in a zone.
  defp ms(date, time, tz) do
    {:ok, dt} = DateTime.new(date, time, tz)
    DateTime.to_unix(dt, :millisecond)
  end

  # Render a unix-ms instant back as a {date, time} pair in a zone (second
  # precision, so literals like ~T[09:00:00] compare cleanly).
  defp wall(ms, tz) do
    dt =
      ms
      |> DateTime.from_unix!(:millisecond)
      |> DateTime.shift_zone!(tz)
      |> DateTime.truncate(:second)

    {DateTime.to_date(dt), DateTime.to_time(dt)}
  end

  describe "parse/1" do
    test "accepts standard 5-field expressions" do
      assert {:ok, _} = Cron.parse("0 9 * * 1-5")
      assert {:ok, _} = Cron.parse("*/15 * * * *")
      assert {:ok, _} = Cron.parse("0 0 1 1,7 *")
    end

    test "rejects malformed expressions" do
      assert {:error, :invalid_cron} = Cron.parse("not a cron")
      assert {:error, :invalid_cron} = Cron.parse("99 9 * * *")
      assert {:error, :invalid_cron} = Cron.parse("0 9 * * 1-9")
      assert {:error, :invalid_cron} = Cron.parse(123)
    end
  end

  describe "next_after_ms/3 — strictly after the anchor" do
    test "every minute: returns the next whole minute, never the anchor itself" do
      anchor = ms(~D[2026-06-18], ~T[10:30:00], "UTC")
      assert {:ok, next} = Cron.next_after_ms("* * * * *", anchor, "UTC")
      assert wall(next, "UTC") == {~D[2026-06-18], ~T[10:31:00]}
    end

    test "anchor exactly on a boundary skips to the next occurrence" do
      anchor = ms(~D[2026-06-18], ~T[09:00:00], "UTC")
      assert {:ok, next} = Cron.next_after_ms("0 9 * * *", anchor, "UTC")
      assert wall(next, "UTC") == {~D[2026-06-19], ~T[09:00:00]}
    end

    test "ranges + day-of-week: weekdays at 09:00 skips the weekend" do
      # Friday 2026-06-19 10:00 → next weekday 09:00 is Monday.
      anchor = ms(~D[2026-06-19], ~T[10:00:00], "UTC")
      assert {:ok, next} = Cron.next_after_ms("0 9 * * 1-5", anchor, "UTC")
      assert wall(next, "UTC") == {~D[2026-06-22], ~T[09:00:00]}
    end

    test "step values: */15 minutes" do
      anchor = ms(~D[2026-06-18], ~T[10:07:00], "UTC")
      assert {:ok, next} = Cron.next_after_ms("*/15 * * * *", anchor, "UTC")
      assert wall(next, "UTC") == {~D[2026-06-18], ~T[10:15:00]}
    end

    test "lists + month rollover: midnight on the 1st of Jan or Jul" do
      anchor = ms(~D[2026-03-10], ~T[12:00:00], "UTC")
      assert {:ok, next} = Cron.next_after_ms("0 0 1 1,7 *", anchor, "UTC")
      assert wall(next, "UTC") == {~D[2026-07-01], ~T[00:00:00]}
    end

    test "day-of-month AND day-of-week when both restricted (crontab semantics)" do
      # NOTE: the `crontab` library requires BOTH day-of-month and day-of-week to
      # match when both are restricted (AND), unlike Vixie cron's OR rule. So
      # "0 0 13 * 5" (the 13th AND a Friday) next matches 2026-11-13, a Friday
      # the 13th — not the nearer 2026-06-12. Document the actual behavior.
      anchor = ms(~D[2026-06-08], ~T[00:00:00], "UTC")
      assert {:ok, next} = Cron.next_after_ms("0 0 13 * 5", anchor, "UTC")
      assert wall(next, "UTC") == {~D[2026-11-13], ~T[00:00:00]}
    end

    test "computes wall-clock in the schedule's timezone" do
      # 09:00 daily in New York, evaluated from a UTC-expressed instant.
      anchor = ms(~D[2026-06-19], ~T[10:00:00], "America/New_York")
      assert {:ok, next} = Cron.next_after_ms("0 9 * * 1-5", anchor, "America/New_York")
      assert wall(next, "America/New_York") == {~D[2026-06-22], ~T[09:00:00]}
    end

    test "unsatisfiable but parseable spec returns :no_occurrence" do
      anchor = ms(~D[2026-06-18], ~T[00:00:00], "UTC")
      assert {:error, :no_occurrence} = Cron.next_after_ms("0 0 30 2 *", anchor, "UTC")
    end

    test "invalid expression surfaces :invalid_cron" do
      anchor = ms(~D[2026-06-18], ~T[00:00:00], "UTC")
      assert {:error, :invalid_cron} = Cron.next_after_ms("nope", anchor, "UTC")
    end
  end

  describe "next_after_ms/3 — DST transitions (America/New_York)" do
    test "spring-forward gap: 02:30 doesn't exist, fires just after the gap" do
      # 2026-03-08: clocks jump 02:00 EST → 03:00 EDT. "30 2 * * *" has no 02:30.
      anchor = ms(~D[2026-03-07], ~T[12:00:00], "America/New_York")
      assert {:ok, next} = Cron.next_after_ms("30 2 * * *", anchor, "America/New_York")
      {date, time} = wall(next, "America/New_York")
      assert date == ~D[2026-03-08]
      # Just after the gap is 03:00 local (the gap's far edge).
      assert time == ~T[03:00:00]
    end

    test "fall-back ambiguous hour: 01:30 occurs twice, fires the earlier instant" do
      # 2026-11-01: clocks fall 02:00 EDT → 01:00 EST, so 01:30 happens twice.
      anchor = ms(~D[2026-10-31], ~T[12:00:00], "America/New_York")
      assert {:ok, next} = Cron.next_after_ms("30 1 * * *", anchor, "America/New_York")

      dt =
        next
        |> DateTime.from_unix!(:millisecond)
        |> DateTime.shift_zone!("America/New_York")
        |> DateTime.truncate(:second)

      assert DateTime.to_date(dt) == ~D[2026-11-01]
      assert DateTime.to_time(dt) == ~T[01:30:00]
      # Earlier instant ⇒ still in daylight time (EDT, -04:00).
      assert dt.zone_abbr == "EDT"
    end
  end

  describe "latest_at_or_before_ms/3" do
    test "returns the most recent past occurrence at or before now" do
      now = ms(~D[2026-06-19], ~T[10:00:00], "UTC")
      assert {:ok, prev} = Cron.latest_at_or_before_ms("0 9 * * 1-5", now, "UTC")
      assert wall(prev, "UTC") == {~D[2026-06-19], ~T[09:00:00]}
    end

    test "skips weekends backward" do
      # Monday 08:00 → latest weekday 09:00 at/before is the previous Friday.
      now = ms(~D[2026-06-22], ~T[08:00:00], "UTC")
      assert {:ok, prev} = Cron.latest_at_or_before_ms("0 9 * * 1-5", now, "UTC")
      assert wall(prev, "UTC") == {~D[2026-06-19], ~T[09:00:00]}
    end
  end
end
