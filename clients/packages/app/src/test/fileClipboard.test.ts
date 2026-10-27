import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { describe, expect, it } from "vitest";
import { canCopyFile } from "../runtime-files/fileClipboard";

describe("canCopyFile", () => {
  it("copies files in the macOS and Windows desktop apps only", () => {
    const cases = [
      ["electron", "macos", true],
      ["electron", "windows", true],
      ["electron", "linux", false],
      ["web", "unknown", false],
    ] as const;
    for (const [platform, os, expected] of cases) {
      installNativeBridgeMock({ os, platform });
      expect(canCopyFile()).toBe(expected);
    }
  });
});
