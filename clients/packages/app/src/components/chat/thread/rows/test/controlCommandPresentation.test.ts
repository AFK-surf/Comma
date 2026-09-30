import { describe, expect, it } from "vitest";
import { controlCommandDisplayText } from "../controlCommandPresentation";

describe("control command display text", () => {
  it("shows standalone commands like skill slash text, preserving path case", () => {
    expect(controlCommandDisplayText("<salix-command>compact</salix-command>")).toBe(
      "/compact"
    );
    expect(
      controlCommandDisplayText("<salix-command>cat /Notes/Q3 Plan.md</salix-command>")
    ).toBe("/cat /Notes/Q3 Plan.md");
    expect(
      controlCommandDisplayText(" <salix-command>\n status \n</salix-command> ")
    ).toBe("/status");
  });

  it("does not rewrite prose, code examples, malformed blocks, or skill mentions", () => {
    for (const text of [
      "Use <salix-command>help</salix-command>",
      "`<salix-command>help</salix-command>`",
      "<salix-command>status",
      "/code-review",
      "<salix-command><nested></salix-command>",
    ]) {
      expect(controlCommandDisplayText(text)).toBe(text);
    }
  });
});
