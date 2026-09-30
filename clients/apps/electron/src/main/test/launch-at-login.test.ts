import { describe, expect, it } from "vitest";
import { resolveLaunchAtLoginReadback } from "../launch-at-login";

describe("resolveLaunchAtLoginReadback", () => {
  it.each([
    ["enabled", true],
    ["requires-approval", false],
    ["not-registered", false],
    ["not-found", false],
  ] as const)("treats macOS %s as enabled=%s", (status, enabled) => {
    expect(
      resolveLaunchAtLoginReadback("macos", {
        openAtLogin: !enabled,
        status,
      })
    ).toEqual({ enabled, status });
  });

  it("falls back to openAtLogin on pre-macOS 13 read-backs", () => {
    expect(resolveLaunchAtLoginReadback("macos", { openAtLogin: true })).toEqual({
      enabled: true,
    });
  });

  it("requires the Windows startup entry to remain approved", () => {
    expect(
      resolveLaunchAtLoginReadback("windows", {
        executableWillLaunchAtLogin: false,
        openAtLogin: true,
      })
    ).toEqual({ enabled: false });
    expect(
      resolveLaunchAtLoginReadback("windows", {
        executableWillLaunchAtLogin: true,
        openAtLogin: true,
      })
    ).toEqual({ enabled: true });
  });

  it("fails closed on unsupported platforms", () => {
    expect(resolveLaunchAtLoginReadback("linux", { openAtLogin: true })).toEqual({
      enabled: false,
    });
  });
});
