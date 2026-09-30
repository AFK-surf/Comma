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

  defp wall_result({:ok, ms}, tz), do: {:ok, wall(ms, tz)}
  defp wall_result(error, _tz), do: error

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
    # {name, expression, anchor wall-clock, zone, expected result}. `:ok` rows
    # carry the expected next wall-clock in the same zone.
    @next_after_cases [
      {"every minute: returns the next whole minute, never the anchor itself", "* * * * *",
       {~D[2026-06-18], ~T[10:30:00]}, "UTC", {:ok, {~D[2026-06-18], ~T[10:31:00]}}},
      {"anchor exactly on a boundary skips to the next occurrence", "0 9 * * *",
       {~D[2026-06-18], ~T[09:00:00]}, "UTC", {:ok, {~D[2026-06-19], ~T[09:00:00]}}},
      # Friday 2026-06-19 10:00 → next weekday 09:00 is Monday.
      {"ranges + day-of-week: weekdays at 09:00 skips the weekend", "0 9 * * 1-5",
       {~D[2026-06-19], ~T[10:00:00]}, "UTC", {:ok, {~D[2026-06-22], ~T[09:00:00]}}},
      {"step values: */15 minutes", "*/15 * * * *", {~D[2026-06-18], ~T[10:07:00]}, "UTC",
       {:ok, {~D[2026-06-18], ~T[10:15:00]}}},
      {"lists + month rollover: midnight on the 1st of Jan or Jul", "0 0 1 1,7 *",
       {~D[2026-03-10], ~T[12:00:00]}, "UTC", {:ok, {~D[2026-07-01], ~T[00:00:00]}}},
      # NOTE: the `crontab` library requires BOTH day-of-month and day-of-week to
      # match when both are restricted (AND), unlike Vixie cron's OR rule. So
      # "0 0 13 * 5" (the 13th AND a Friday) next matches 2026-11-13, a Friday
      # the 13th — not the nearer 2026-06-12. Document the actual behavior.
      {"day-of-month AND day-of-week when both restricted (crontab semantics)", "0 0 13 * 5",
       {~D[2026-06-08], ~T[00:00:00]}, "UTC", {:ok, {~D[2026-11-13], ~T[00:00:00]}}},
      # 09:00 daily in New York, evaluated from a UTC-expressed instant.
      {"computes wall-clock in the schedule's timezone", "0 9 * * 1-5",
       {~D[2026-06-19], ~T[10:00:00]}, "America/New_York", {:ok, {~D[2026-06-22], ~T[09:00:00]}}},
      {"unsatisfiable but parseable spec returns :no_occurrence", "0 0 30 2 *",
       {~D[2026-06-18], ~T[00:00:00]}, "UTC", {:error, :no_occurrence}},
      {"invalid expression surfaces :invalid_cron", "nope", {~D[2026-06-18], ~T[00:00:00]}, "UTC",
       {:error, :invalid_cron}}
    ]

    for {name, expr, anchor, tz, expected} <- @next_after_cases do
      test name do
        {date, time} = unquote(Macro.escape(anchor))
        tz = unquote(tz)
        result = Cron.next_after_ms(unquote(expr), ms(date, time, tz), tz)
        assert wall_result(result, tz) == unquote(Macro.escape(expected))
      end
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
    @latest_cases [
      {"returns the most recent past occurrence at or before now", {~D[2026-06-19], ~T[10:00:00]},
       {~D[2026-06-19], ~T[09:00:00]}},
      # Monday 08:00 → latest weekday 09:00 at/before is the previous Friday.
      {"skips weekends backward", {~D[2026-06-22], ~T[08:00:00]}, {~D[2026-06-19], ~T[09:00:00]}}
    ]

    for {name, now, expected} <- @latest_cases do
      test name do
        {date, time} = unquote(Macro.escape(now))
        result = Cron.latest_at_or_before_ms("0 9 * * 1-5", ms(date, time, "UTC"), "UTC")
        assert wall_result(result, "UTC") == {:ok, unquote(Macro.escape(expected))}
      end
    end
  end
end
