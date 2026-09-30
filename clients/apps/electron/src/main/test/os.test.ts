import { describe, expect, it } from "vitest";
import { toCommaOperatingSystem } from "../os";

describe("toCommaOperatingSystem", () => {
  it.each([
    ["darwin", "macos"],
    ["win32", "windows"],
    ["linux", "linux"],
    ["freebsd", "unknown"],
  ] as const)("maps %s to %s", (platform, expected) => {
    expect(toCommaOperatingSystem(platform)).toBe(expected);
  });
});
