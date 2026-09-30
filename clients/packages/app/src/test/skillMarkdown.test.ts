import { describe, expect, it } from "vitest";
import { portableSkillMarkdown } from "../components/plugins/skillMarkdown";

describe("portableSkillMarkdown", () => {
  it("moves front matter into a fenced block under a title", () => {
    expect(
      portableSkillMarkdown(
        "weekly-report",
        "﻿---\r\nname: weekly-report\r\ndescription: Draft a report\r\n---\r\n\r\nCollect tasks.\r\n\r\n"
      )
    ).toBe(
      "# weekly-report\n\n```yaml\nname: weekly-report\ndescription: Draft a report\n```\n\nCollect tasks.\n"
    );
  });

  it("keeps the body's own title and outruns backticks in the metadata", () => {
    expect(
      portableSkillMarkdown(
        "report",
        "---\ndescription: Use ```sh blocks\n---\n# Reporting steps\n\nBody."
      )
    ).toBe(
      "````yaml\ndescription: Use ```sh blocks\n````\n\n# Reporting steps\n\nBody.\n"
    );
  });

  it("titles a file that has no front matter", () => {
    expect(portableSkillMarkdown("notes", "Plain body.")).toBe(
      "# notes\n\nPlain body.\n"
    );
  });
});
