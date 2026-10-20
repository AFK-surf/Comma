import { describe, expect, it } from "vitest";
import { onboardingKeycaps } from "../onboardingShortcutKeys";

const names = { comma: "Comma", space: "Space" };
const altComma = {
  key: "comma",
  modifiers: { alt: true, control: false, meta: false, shift: false },
} as const;

describe("onboardingKeycaps", () => {
  it("prints the modifiers as the machine's keyboard does", () => {
    expect(
      onboardingKeycaps(altComma, names, "macos").map(({ glyph, name }) => [
        glyph,
        name,
      ])
    ).toEqual([
      ["⌥", "Option"],
      [undefined, "Comma"],
    ]);
    expect(
      onboardingKeycaps(altComma, names, "windows").map(({ glyph, name }) => [
        glyph,
        name,
      ])
    ).toEqual([
      [undefined, "Alt"],
      [undefined, "Comma"],
    ]);
  });
});
