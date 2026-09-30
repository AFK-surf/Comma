import { describe, expect, it } from "vitest";
import { portableSkillMarkdown } from "../components/plugins/skillMarkdown";

describe("portableSkillMarkdown", () => {
  it.each([
    {
      name: "moves front matter into a fenced block under a title",
      skillName: "weekly-report",
      source:
        "﻿---\r\nname: weekly-report\r\ndescription: Draft a report\r\n---\r\n\r\nCollect tasks.\r\n\r\n",
      expected:
        "# weekly-report\n\n```yaml\nname: weekly-report\ndescription: Draft a report\n```\n\nCollect tasks.\n",
    },
    {
      name: "keeps the body's own title and outruns backticks in the metadata",
      skillName: "report",
      source: "---\ndescription: Use ```sh blocks\n---\n# Reporting steps\n\nBody.",
      expected:
        "````yaml\ndescription: Use ```sh blocks\n````\n\n# Reporting steps\n\nBody.\n",
    },
    {
      name: "titles a file that has no front matter",
      skillName: "notes",
      source: "Plain body.",
      expected: "# notes\n\nPlain body.\n",
    },
  ])("$name", ({ expected, skillName, source }) => {
    expect(portableSkillMarkdown(skillName, source)).toBe(expected);
  });
});
