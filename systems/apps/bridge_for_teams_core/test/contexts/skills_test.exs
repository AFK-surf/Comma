defmodule BridgeForTeams.SkillsTest do
  @moduledoc """
  Unit tests for the Skills context's pure pieces: SKILL.md format validation
  (what the Plugins upload gate enforces) and name slugging. The erpc-backed
  reads/writes are exercised through the PluginLive tests.
  """
  use ExUnit.Case, async: true

  alias BridgeForTeams.Skills

  describe "validate_skill_md/1" do
    test "accepts a minimal valid SKILL.md and extracts name + description" do
      body = """
      ---
      name: Weekly recap
      description: Use for weekly summaries.
      ---

      Do the recap.
      """

      assert {:ok, %{"name" => "Weekly recap", "description" => "Use for weekly summaries."}} =
               Skills.validate_skill_md(body)
    end

    test "accepts CRLF line endings and quoted scalars" do
      body = "---\r\nname: \"Recap\"\r\n---\r\nBody\r\n"
      assert {:ok, %{"name" => "Recap"}} = Skills.validate_skill_md(body)
    end

    test "rejects a body that does not open with frontmatter" do
      assert {:error, :missing_frontmatter} =
               Skills.validate_skill_md("just instructions, no frontmatter")

      # An inline `---` later in the file is not an opening delimiter.
      assert {:error, :missing_frontmatter} =
               Skills.validate_skill_md("intro\n---\nname: x\n---\n")
    end

    test "rejects frontmatter that never closes" do
      assert {:error, :missing_frontmatter_close} =
               Skills.validate_skill_md("---\nname: Recap\nno closing delimiter")
    end

    test "rejects a missing or unusable name" do
      assert {:error, :invalid_name} =
               Skills.validate_skill_md("---\ndescription: no name\n---\nBody")

      assert {:error, :invalid_name} = Skills.validate_skill_md("---\nname: 名字\n---\nBody")
    end
  end

  describe "delete_user_skill/3 location guard" do
    alias BridgeForTeams.Schema.{Agent, Organization}

    test "rejects locations outside the runtime skill mount without touching Salix" do
      org = %Organization{salix_tenant_id: "tenant"}
      agent = %Agent{salix_agent_id: "agent_x"}

      for location <- [
            "/etc/passwd",
            "/.salix/skills/custom/recap/SKILL.md",
            "/.runtime/skills/SKILL.md",
            "/.runtime/skills//SKILL.md",
            "/.runtime/skills/../SKILL.md",
            "/.runtime/skills/recap/notes.md",
            "/.runtime/skills/recap/extra/SKILL.md"
          ] do
        assert {:error, :invalid_location} = Skills.delete_user_skill(org, agent, location)
      end
    end
  end

  describe "slugify/1" do
    test "downcases, hyphenates, and trims" do
      assert Skills.slugify("Weekly Portfolio Recap") == "weekly-portfolio-recap"
      assert Skills.slugify("  A  B!! C  ") == "a-b-c"
    end

    test "returns empty string when nothing sluggable remains" do
      assert Skills.slugify("!!!") == ""
      assert Skills.slugify("") == ""
    end
  end
end
