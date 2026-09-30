defmodule BridgeForTeams.ReportsTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.Reports

  doctest BridgeForTeams.Reports

  @user_id "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"

  describe "series_slug/2" do
    test "slugifies the base name and appends the user suffix" do
      assert Reports.series_slug("Daily Briefing", @user_id) == "daily-briefing-a1b2c3d4"

      assert Reports.series_slug("Weekly  Portfolio Report!", @user_id) ==
               "weekly-portfolio-report-a1b2c3d4"
    end

    test "a base name with no usable characters falls back to \"report\"" do
      assert Reports.series_slug("!!!", @user_id) == "report-a1b2c3d4"
      assert Reports.series_slug("", @user_id) == "report-a1b2c3d4"
    end

    test "preserves report series names for the seeded offers" do
      for {base, expected} <- [
            {"daily-briefing", "daily-briefing-a1b2c3d4"},
            {"weekly-portfolio", "weekly-portfolio-a1b2c3d4"}
          ] do
        assert Reports.series_slug(base, @user_id) == expected
      end
    end
  end

  describe "series_dir/1 and run_path/2" do
    test "series_dir nests under the reports root" do
      assert Reports.series_dir("daily-briefing-a1b2c3d4") ==
               "/.salix/reports/daily-briefing-a1b2c3d4"

      assert String.starts_with?(Reports.series_dir("x"), Reports.root() <> "/")
    end

    test "a Date yields the plain daily filename" do
      assert Reports.run_path("daily-briefing-a1b2c3d4", ~D[2026-07-06]) ==
               "/.salix/reports/daily-briefing-a1b2c3d4/2026-07-06.md"
    end

    test "a DateTime appends the zero-padded -HHMM disambiguator" do
      assert Reports.run_path("s-a1b2c3d4", ~U[2026-07-06 08:05:00Z]) ==
               "/.salix/reports/s-a1b2c3d4/2026-07-06-0805.md"

      assert Reports.run_path("s-a1b2c3d4", ~U[2026-12-31 23:59:59Z]) ==
               "/.salix/reports/s-a1b2c3d4/2026-12-31-2359.md"

      assert Reports.run_path("s-a1b2c3d4", ~U[2026-01-02 00:00:00Z]) ==
               "/.salix/reports/s-a1b2c3d4/2026-01-02-0000.md"
    end
  end

  describe "parse_run_path/1" do
    test "extracts series and date from a daily run path" do
      assert Reports.parse_run_path("/.salix/reports/daily-briefing-a1b2c3d4/2026-07-06.md") ==
               {:ok, %{series: "daily-briefing-a1b2c3d4", date: ~D[2026-07-06], time: nil}}
    end

    test "extracts the -HHMM time when present" do
      assert Reports.parse_run_path("/.salix/reports/s-a1b2c3d4/2026-07-06-0805.md") ==
               {:ok, %{series: "s-a1b2c3d4", date: ~D[2026-07-06], time: ~T[08:05:00]}}
    end

    test "round-trips run_path/2 output" do
      for stamp <- [~D[2026-07-06], ~U[2026-07-06 08:05:00Z]] do
        path = Reports.run_path("weekly-portfolio-a1b2c3d4", stamp)

        assert {:ok, %{series: "weekly-portfolio-a1b2c3d4", date: ~D[2026-07-06]}} =
                 Reports.parse_run_path(path)
      end
    end

    for {reason, path} <- [
          {"another VFS root", "/.salix/websites/foo/index.html"},
          {"a path outside /.salix", "/reports/foo/2026-07-06.md"},
          {"a file directly under the root", "/.salix/reports/2026-07-06.md"},
          {"extra path segments", "/.salix/reports/a/b/2026-07-06.md"},
          {"a series directory", "/.salix/reports/daily-briefing-a1b2c3d4"},
          {"a series directory with a trailing slash",
           "/.salix/reports/daily-briefing-a1b2c3d4/"},
          {"a non-date filename", "/.salix/reports/s-a1b2c3d4/notes.md"},
          {"a non-Markdown extension", "/.salix/reports/s-a1b2c3d4/2026-07-06.html"},
          {"a trailing extension", "/.salix/reports/s-a1b2c3d4/2026-07-06.md.bak"},
          {"an unpadded date", "/.salix/reports/s-a1b2c3d4/2026-7-6.md"},
          {"an hour-only disambiguator", "/.salix/reports/s-a1b2c3d4/2026-07-06-08.md"},
          {"a seconds disambiguator", "/.salix/reports/s-a1b2c3d4/2026-07-06-080000.md"},
          {"an invalid month", "/.salix/reports/s-a1b2c3d4/2026-13-01.md"},
          {"an invalid day", "/.salix/reports/s-a1b2c3d4/2026-02-30.md"},
          {"an invalid time", "/.salix/reports/s-a1b2c3d4/2026-07-06-2460.md"},
          {"the empty string", ""},
          {"a bare filename", "2026-07-06.md"}
        ] do
      test "rejects #{reason}: #{inspect(path)}" do
        assert Reports.parse_run_path(unquote(path)) == :error
      end
    end
  end
end
