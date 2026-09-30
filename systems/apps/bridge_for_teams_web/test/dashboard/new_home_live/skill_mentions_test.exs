defmodule BridgeForTeamsWeb.Dashboard.NewHomeLive.SkillMentionsTest do
  @moduledoc """
  The user → agent skill-tagging path: `chat[skills]` is client-controlled, so
  parse/2 admits only locations present in the server-loaded skill list and
  degrades to [] on anything malformed; instructions/1 renders the activation
  block the agent receives after the protocol marker.
  """
  use ExUnit.Case, async: true

  alias BridgeForTeamsWeb.Dashboard.NewHomeLive.SkillMentions

  @loaded [
    %{
      "name" => "Weekly Report",
      "description" => "Compile weekly performance metrics",
      "location" => "/.runtime/skills/weekly-report/SKILL.md"
    },
    %{
      "name" => "Portfolio Summary",
      "description" => "Generate a portfolio recap",
      "location" => "/.runtime/skills/portfolio-summary/SKILL.md"
    }
  ]

  defp encode(entries), do: Jason.encode!(entries)

  describe "parse/2" do
    test "returns the server-side maps for known locations, in client order" do
      value =
        encode([
          %{
            "name" => "Spoofed Name",
            "location" => "/.runtime/skills/portfolio-summary/SKILL.md"
          },
          %{"name" => "Weekly Report", "location" => "/.runtime/skills/weekly-report/SKILL.md"}
        ])

      assert [%{"name" => "Portfolio Summary"}, %{"name" => "Weekly Report"}] =
               SkillMentions.parse(value, @loaded)
    end

    test "drops unknown locations" do
      value = encode([%{"name" => "Evil", "location" => "/.runtime/skills/evil/SKILL.md"}])
      assert SkillMentions.parse(value, @loaded) == []
    end

    test "dedupes repeated locations" do
      entry = %{"location" => "/.runtime/skills/weekly-report/SKILL.md"}
      assert [%{"name" => "Weekly Report"}] = SkillMentions.parse(encode([entry, entry]), @loaded)
    end

    test "caps the number of mentions" do
      entries =
        for i <- 1..30, do: %{"location" => "/.runtime/skills/skill-#{i}/SKILL.md"}

      loaded =
        for i <- 1..30 do
          %{"name" => "Skill #{i}", "location" => "/.runtime/skills/skill-#{i}/SKILL.md"}
        end

      assert length(SkillMentions.parse(encode(entries), loaded)) == 10
    end

    test "degrades to [] on malformed input" do
      assert SkillMentions.parse("not json", @loaded) == []
      assert SkillMentions.parse(encode(%{"location" => "x"}), @loaded) == []
      assert SkillMentions.parse(encode(["just", "strings"]), @loaded) == []
      assert SkillMentions.parse(encode([%{"location" => 42}]), @loaded) == []
      assert SkillMentions.parse(nil, @loaded) == []
      assert SkillMentions.parse(%{}, @loaded) == []
      assert SkillMentions.parse(encode([]), @loaded) == []
    end
  end

  describe "instructions/1" do
    test "is nil when nothing was tagged" do
      assert SkillMentions.instructions([]) == nil
    end

    test "lists each skill as name — location" do
      text = SkillMentions.instructions(@loaded)

      assert text ==
               "The user tagged these skills for this task. Activate each one now: " <>
                 "read the SKILL.md at the given location and follow it while doing the work:\n" <>
                 "- Weekly Report — /.runtime/skills/weekly-report/SKILL.md\n" <>
                 "- Portfolio Summary — /.runtime/skills/portfolio-summary/SKILL.md"
    end
  end
end
