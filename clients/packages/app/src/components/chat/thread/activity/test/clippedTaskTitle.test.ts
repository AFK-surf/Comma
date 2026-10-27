import { describe, expect, it } from "vitest";
import { clippedTaskTitle } from "../clippedTaskTitle";

describe("clippedTaskTitle", () => {
  it("keeps a short title with emoji whole", () => {
    expect(clippedTaskTitle("🚀 Launch  checklist")).toBe("🚀 Launch checklist");
  });

  it("never cuts a ZWJ or flag emoji at the clip edge", () => {
    const family = "👨‍👩‍👧‍👦";
    const title = `${"a".repeat(38)}${family}${family}${family}`;
    expect(clippedTaskTitle(title)).toBe(`${"a".repeat(38)}${family}…`);
    const flags = `${"a".repeat(38)}🇯🇵🇯🇵🇯🇵`;
    expect(clippedTaskTitle(flags)).toBe(`${"a".repeat(38)}🇯🇵…`);
  });
});
