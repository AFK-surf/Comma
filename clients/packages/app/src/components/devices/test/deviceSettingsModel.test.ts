import { describe, expect, it } from "vitest";
import { describeAgent, deviceSystem } from "../deviceSettingsModel";

const permissionBlocked = {
  status: "unavailable",
  issue: "permission_required",
  message: "Allow operations in Comma Settings > Devices to use this agent.",
  version: "0.52.0",
};

describe("device settings model", () => {
  it("names the system without inventing facts the API did not send", () => {
    expect(deviceSystem("darwin", "arm64")).toBe("macOS · arm64");
    expect(deviceSystem("linux", undefined)).toBe("Linux");
    expect(deviceSystem("plan9", "riscv64")).toBe("plan9 · riscv64");
    expect(deviceSystem(undefined, undefined)).toBeUndefined();
  });

  it("answers a blocked agent with the switch above it, not the Connector's sentence", () => {
    expect(
      describeAgent(permissionBlocked, { reach: "connected", permits: false })
    ).toEqual({ state: "blocked", detail: "0.52.0" });
  });

  it("blocks every agent on a read-only computer, however the Connector reported it", () => {
    expect(
      describeAgent(
        { status: "ready", version: "2.0.14" },
        {
          reach: "connected",
          permits: false,
        }
      )
    ).toEqual({ state: "blocked", detail: "2.0.14" });
  });

  it("keeps a Connector reason the page cannot restate itself", () => {
    expect(
      describeAgent(
        {
          status: "unavailable",
          issue: "authentication_required",
          message: "Codex reports no authenticated account.",
          version: "0.52.0",
        },
        { reach: "connected", permits: true }
      )
    ).toEqual({
      state: "unavailable",
      detail: "0.52.0 · Codex reports no authenticated account.",
    });
  });

  it("drops the disconnect notice an offline computer already carries", () => {
    expect(
      describeAgent(
        {
          status: "disconnected",
          issue: "connector_disconnected",
          message: "The Connector is disconnected from this device.",
        },
        { reach: "offline", permits: true }
      )
    ).toEqual({ state: "unavailable" });
  });

  it("reports a ready agent once operations are allowed", () => {
    expect(
      describeAgent({ status: "ready" }, { reach: "connected", permits: true })
    ).toEqual({ state: "available" });
    expect(
      describeAgent({ status: "available" }, { reach: "connected", permits: true })
    ).toEqual({ state: "available" });
  });
});
