defmodule BridgeForTeams.ReportsTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.Reports

  doctest BridgeForTeams.Reports

  @user_id "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"

  describe "user_suffix/1" do
    test "strips dashes and truncates to 8 characters" do
      assert Reports.user_suffix(@user_id) == "a1b2c3d4"
    end

    test "ids shorter than 8 characters are kept whole" do
      assert Reports.user_suffix("ab-cd") == "abcd"
    end

    test "accepts non-string ids" do
      assert Reports.user_suffix(123_456_789) == "12345678"
    end
  end

  describe "series_slug/2" do
    test "slugifies the base name and appends the user suffix" do
      assert Reports.series_slug("Daily Briefing", @user_id) == "daily-briefing-a1b2c3d4"

      assert Reports.series_slug("Weekly  Portfolio Report!", @user_id) ==
               "weekly-portfolio-report-a1b2c3d4"
    end

    test "already-slugged base names pass through" do
      assert Reports.series_slug("daily-briefing", @user_id) == "daily-briefing-a1b2c3d4"
    end

    test "a base name with no usable characters falls back to \"report\"" do
      assert Reports.series_slug("!!!", @user_id) == "report-a1b2c3d4"
      assert Reports.series_slug("", @user_id) == "report-a1b2c3d4"
    end

    test "matches the dashboard's report site naming for the seeded offers" do
      # `report_site_name/2` in new_home_live.ex produces
      # "daily-briefing-<suffix>" / "weekly-portfolio-<suffix>"; series slugs
      # for the same base names must namespace identically.
      suffix = @user_id |> String.replace("-", "") |> String.slice(0, 8)
      assert Reports.series_slug("daily-briefing", @user_id) == "daily-briefing-#{suffix}"
      assert Reports.series_slug("weekly-portfolio", @user_id) == "weekly-portfolio-#{suffix}"
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

    test "rejects paths outside the reports root" do
      assert Reports.parse_run_path("/.salix/websites/foo/index.html") == :error
      assert Reports.parse_run_path("/reports/foo/2026-07-06.md") == :error
      assert Reports.parse_run_path("/.salix/reports/2026-07-06.md") == :error
    end

    test "rejects extra path segments and directories" do
      assert Reports.parse_run_path("/.salix/reports/a/b/2026-07-06.md") == :error
      assert Reports.parse_run_path("/.salix/reports/daily-briefing-a1b2c3d4") == :error
      assert Reports.parse_run_path("/.salix/reports/daily-briefing-a1b2c3d4/") == :error
    end

    test "rejects malformed filenames" do
      for filename <- [
            "notes.md",
            "2026-07-06.html",
            "2026-07-06.md.bak",
            "2026-7-6.md",
            "2026-07-06-08.md",
            "2026-07-06-080000.md"
          ] do
        assert Reports.parse_run_path("/.salix/reports/s-a1b2c3d4/" <> filename) == :error
      end
    end

    test "rejects calendar-invalid dates and times" do
      assert Reports.parse_run_path("/.salix/reports/s-a1b2c3d4/2026-13-01.md") == :error
      assert Reports.parse_run_path("/.salix/reports/s-a1b2c3d4/2026-02-30.md") == :error
      assert Reports.parse_run_path("/.salix/reports/s-a1b2c3d4/2026-07-06-2460.md") == :error
    end

    test "rejects the empty string and non-path garbage" do
      assert Reports.parse_run_path("") == :error
      assert Reports.parse_run_path("2026-07-06.md") == :error
    end
  end
end
