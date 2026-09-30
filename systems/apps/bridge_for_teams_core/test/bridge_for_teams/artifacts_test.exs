defmodule BridgeForTeams.ArtifactsTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.Artifacts

  doctest BridgeForTeams.Artifacts

  @user_id "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"

  describe "user_suffix/1" do
    test "strips dashes and truncates to 8 characters" do
      assert Artifacts.user_suffix(@user_id) == "a1b2c3d4"
    end

    test "ids shorter than 8 characters are kept whole" do
      assert Artifacts.user_suffix("ab-cd") == "abcd"
    end

    test "accepts non-string ids" do
      assert Artifacts.user_suffix(123_456_789) == "12345678"
    end
  end

  describe "slug/2,3" do
    test "slugifies the base name and appends the user suffix" do
      assert Artifacts.slug("Competitor Scan", @user_id) == "competitor-scan-a1b2c3d4"

      assert Artifacts.slug("Weekly  Portfolio Report!", @user_id) ==
               "weekly-portfolio-report-a1b2c3d4"
    end

    test "already-slugged base names pass through" do
      assert Artifacts.slug("competitor-scan", @user_id) == "competitor-scan-a1b2c3d4"
    end

    test "a base name with no usable characters falls back to \"artifact\"" do
      assert Artifacts.slug("!!!", @user_id) == "artifact-a1b2c3d4"
      assert Artifacts.slug("", @user_id) == "artifact-a1b2c3d4"
    end

    test "the fallback is overridable (reports pass \"report\")" do
      assert Artifacts.slug("", @user_id, "report") == "report-a1b2c3d4"
    end

    test "reports series slugs are the same implementation" do
      assert BridgeForTeams.Reports.series_slug("Daily Briefing", @user_id) ==
               "daily-briefing-a1b2c3d4"

      assert BridgeForTeams.Reports.series_slug("!!!", @user_id) == "report-a1b2c3d4"
      assert BridgeForTeams.Reports.user_suffix(@user_id) == Artifacts.user_suffix(@user_id)
    end
  end

  describe "dir/1 and path/2" do
    test "dir nests under the artifacts root" do
      assert Artifacts.dir("competitor-scan-a1b2c3d4") ==
               "/.salix/artifacts/competitor-scan-a1b2c3d4"

      assert String.starts_with?(Artifacts.dir("x"), Artifacts.root() <> "/")
    end

    test "the artifacts root is distinct from the reports root" do
      assert Artifacts.root() == "/.salix/artifacts"
      assert BridgeForTeams.Reports.root() == "/.salix/reports"
    end

    test "a Date yields the plain daily filename" do
      assert Artifacts.path("competitor-scan-a1b2c3d4", ~D[2026-07-06]) ==
               "/.salix/artifacts/competitor-scan-a1b2c3d4/2026-07-06.md"
    end

    test "a DateTime appends the zero-padded -HHMM disambiguator" do
      assert Artifacts.path("s-a1b2c3d4", ~U[2026-07-06 08:05:00Z]) ==
               "/.salix/artifacts/s-a1b2c3d4/2026-07-06-0805.md"

      assert Artifacts.path("s-a1b2c3d4", ~U[2026-12-31 23:59:59Z]) ==
               "/.salix/artifacts/s-a1b2c3d4/2026-12-31-2359.md"

      assert Artifacts.path("s-a1b2c3d4", ~U[2026-01-02 00:00:00Z]) ==
               "/.salix/artifacts/s-a1b2c3d4/2026-01-02-0000.md"
    end
  end

  describe "parse_path/1" do
    test "extracts slug and date from a daily path" do
      assert Artifacts.parse_path("/.salix/artifacts/competitor-scan-a1b2c3d4/2026-07-06.md") ==
               {:ok, %{slug: "competitor-scan-a1b2c3d4", date: ~D[2026-07-06], time: nil}}
    end

    test "extracts the -HHMM time when present" do
      assert Artifacts.parse_path("/.salix/artifacts/s-a1b2c3d4/2026-07-06-0805.md") ==
               {:ok, %{slug: "s-a1b2c3d4", date: ~D[2026-07-06], time: ~T[08:05:00]}}
    end

    test "round-trips path/2 output" do
      for stamp <- [~D[2026-07-06], ~U[2026-07-06 08:05:00Z]] do
        path = Artifacts.path("weekly-scan-a1b2c3d4", stamp)

        assert {:ok, %{slug: "weekly-scan-a1b2c3d4", date: ~D[2026-07-06]}} =
                 Artifacts.parse_path(path)
      end
    end

    test "rejects paths outside the artifacts root" do
      assert Artifacts.parse_path("/.salix/reports/s-a1b2c3d4/2026-07-06.md") == :error
      assert Artifacts.parse_path("/artifacts/foo/2026-07-06.md") == :error
      assert Artifacts.parse_path("/.salix/artifacts/2026-07-06.md") == :error
    end

    test "rejects extra path segments and directories" do
      assert Artifacts.parse_path("/.salix/artifacts/a/b/2026-07-06.md") == :error
      assert Artifacts.parse_path("/.salix/artifacts/competitor-scan-a1b2c3d4") == :error
      assert Artifacts.parse_path("/.salix/artifacts/competitor-scan-a1b2c3d4/") == :error
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
        assert Artifacts.parse_path("/.salix/artifacts/s-a1b2c3d4/" <> filename) == :error
      end
    end

    test "rejects calendar-invalid dates and times" do
      assert Artifacts.parse_path("/.salix/artifacts/s-a1b2c3d4/2026-13-01.md") == :error
      assert Artifacts.parse_path("/.salix/artifacts/s-a1b2c3d4/2026-02-30.md") == :error
      assert Artifacts.parse_path("/.salix/artifacts/s-a1b2c3d4/2026-07-06-2460.md") == :error
    end

    test "rejects the empty string and non-path garbage" do
      assert Artifacts.parse_path("") == :error
      assert Artifacts.parse_path("2026-07-06.md") == :error
    end
  end
end
