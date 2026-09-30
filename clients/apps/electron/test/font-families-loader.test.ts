import { describe, expect, it } from "vitest";
import {
  fontFamiliesCandidateBinaryPaths,
  loadFontFamiliesAddon,
} from "../native/macos/FontFamilies";

describe("font families native adapter", () => {
  it("uses only the shipped addon in packaged applications", () => {
    expect(
      fontFamiliesCandidateBinaryPaths({
        cwd: "/untrusted/check-out",
        environmentPath: "/untrusted/addon.node",
        isPackaged: true,
        resourcesPath: "/Applications/Comma.app/Contents/Resources",
      })
    ).toEqual([
      "/Applications/Comma.app/Contents/Resources/native/macos/comma-font-families.node",
    ]);
  });

  it("reports no list off macOS instead of an empty one", async () => {
    const addon = loadFontFamiliesAddon({ platform: "linux" });
    expect(addon.loaded).toBe(false);
    await expect(addon.familyNames()).resolves.toBeNull();
  });
});
