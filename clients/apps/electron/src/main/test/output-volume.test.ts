import { describe, expect, it } from "vitest";
import { readMacOutputVolume } from "../output-volume";

describe("readMacOutputVolume", () => {
  it("reads the volume AppleScript reports, as a share", async () => {
    await expect(readMacOutputVolume(async () => "56\n")).resolves.toBe(0.56);
  });

  it("is unknown for an output without a volume, or when the read fails", async () => {
    await expect(
      readMacOutputVolume(async () => "missing value\n")
    ).resolves.toBeNull();
    await expect(
      readMacOutputVolume(async () => {
        throw new Error("osascript timed out");
      })
    ).resolves.toBeNull();
  });
});
