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

  it.each([
    {
      name: "answers a blocked agent with the switch above it, not the Connector's sentence",
      agent: permissionBlocked,
      device: { reach: "connected", permits: false },
      expected: { state: "blocked", detail: "0.52.0" },
    },
    {
      name: "blocks every agent on a read-only computer, however the Connector reported it",
      agent: { status: "ready", version: "2.0.14" },
      device: { reach: "connected", permits: false },
      expected: { state: "blocked", detail: "2.0.14" },
    },
    {
      name: "keeps a Connector reason the page cannot restate itself",
      agent: {
        status: "unavailable",
        issue: "authentication_required",
        message: "Codex reports no authenticated account.",
        version: "0.52.0",
      },
      device: { reach: "connected", permits: true },
      expected: {
        state: "unavailable",
        detail: "0.52.0 · Codex reports no authenticated account.",
      },
    },
    {
      name: "drops the disconnect notice an offline computer already carries",
      agent: {
        status: "disconnected",
        issue: "connector_disconnected",
        message: "The Connector is disconnected from this device.",
      },
      device: { reach: "offline", permits: true },
      expected: { state: "unavailable" },
    },
    {
      name: "reports a ready agent once operations are allowed",
      agent: { status: "ready" },
      device: { reach: "connected", permits: true },
      expected: { state: "available" },
    },
    {
      name: "reports an available agent once operations are allowed",
      agent: { status: "available" },
      device: { reach: "connected", permits: true },
      expected: { state: "available" },
    },
  ] as const)("$name", ({ agent, device, expected }) => {
    expect(describeAgent(agent, device)).toEqual(expected);
  });
});
