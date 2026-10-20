import { afterEach, describe, expect, it, vi } from "vitest";
import {
  buildWorkbenchTabs,
  loadRuntimeSnapshot,
  type WorkbenchSnapshot,
} from "../domain-adapters";

const readySnapshot: WorkbenchSnapshot = {
  transport: {
    available: true,
    capabilities: {
      byTransport: {
        "file-handle": 0,
        "ipc-rpc": 17,
        "message-port": 0,
        "native-stream": 0,
      },
      payloadClasses: [{ count: 17, payloadClass: "control" }],
      total: 17,
    },
    events: {
      channels: ["comma:surfaces:changed", "comma:notch:event"],
      total: 2,
    },
    messagePort: {
      active: false,
      reason: "Peer-channel runtime is not registered yet.",
      runtime: "not-started",
    },
    observability: {
      jsonlEnabled: true,
      location: "userData/agent-observability/native-events.jsonl",
      redacted: true,
      status: "ready",
    },
  },
};

afterEach(() => {
  globalThis.commaNative = undefined;
});

describe("loadRuntimeSnapshot", () => {
  it("uses the callable state snapshot that survives Electron context isolation", async () => {
    const surfaceState = vi.fn(async () => ({
      notch: { available: true },
      panels: [],
      platform: { appVersion: "0.0.1", os: "macos", platform: "electron" },
      views: [],
      windows: [],
    }));

    globalThis.commaNative = {
      native: { info: vi.fn(async () => ({ platform: "electron" })) },
      surfaces: { state: surfaceState },
      session: { state: vi.fn(async () => ({ signedIn: true })) },
      transport: { status: vi.fn(async () => readySnapshot.transport) },
    } as unknown as NonNullable<typeof globalThis.commaNative>;

    const snapshot = await loadRuntimeSnapshot();

    expect(surfaceState).toHaveBeenCalledOnce();
    expect(snapshot.surfaces?.windows).toEqual([]);
  });
});

describe("buildWorkbenchTabs", () => {
  it("exposes only the generated Session projection without renderer token controls", () => {
    const tabs = buildWorkbenchTabs(readySnapshot);
    const session = tabs.find((tab) => tab.id === "session");

    expect(session).toEqual(
      expect.objectContaining({
        label: "Session",
        status: "ready",
      })
    );
    expect(session?.controls.map((control) => control.id)).toEqual(["session-state"]);
    expect(session?.flows.map((flow) => flow.id)).toEqual(["session-state-flow"]);
  });

  it("wires notch command actions and marks the tab PARTIAL (update needs a payload)", () => {
    const tabs = buildWorkbenchTabs(readySnapshot);
    const notch = tabs.find((tab) => tab.id === "notch");

    // notch.update is needs-capability (no scene editor), so by the workbench's
    // own vocabulary the tab is PARTIAL, not LIVE.
    expect(notch?.status).toBe("partial");

    const statusControl = notch?.controls.find(
      (control) => control.id === "notch-status"
    );
    expect(statusControl).toEqual(
      expect.objectContaining({ kind: "button", status: "ready" })
    );
    expect(
      statusControl && "action" in statusControl && typeof statusControl.action
    ).toBe("function");

    const updateControl = notch?.controls.find(
      (control) => control.id === "notch-update"
    );
    expect(updateControl?.status).toBe("needs-capability");
    expect(updateControl && "action" in updateControl).toBe(false);
  });

  it("guarantees every ready button control has a callable action (no dead LIVE controls)", () => {
    const tabs = buildWorkbenchTabs(readySnapshot);
    const readyButtons = tabs.flatMap((tab) =>
      tab.controls
        .filter((control) => control.kind === "button" && control.status === "ready")
        .map((control) => ({ control, tab: tab.id }))
    );

    // Sanity: the workbench must actually expose ready buttons to check.
    expect(readyButtons.length).toBeGreaterThan(0);

    for (const { control, tab } of readyButtons) {
      const hasAction = "action" in control && typeof control.action === "function";
      expect(
        hasAction,
        `${tab}/${control.id} is marked ready but has no callable action`
      ).toBe(true);
    }
  });

  it("exposes observed flow data for Transport without route rendering", () => {
    const tabs = buildWorkbenchTabs(readySnapshot);
    const transport = tabs.find((tab) => tab.id === "transport");

    expect(transport?.flows).toContainEqual(
      expect.objectContaining({
        evidenceLabel: "transport.status",
        id: "transport-observability",
        label: "Transport Observability",
        status: "partial",
        traceIdSource: "NativeObservationEvent.trace.id for transport.status",
      })
    );
    expect(transport?.flows[0]?.steps).toEqual([
      expect.objectContaining({
        id: "capability-rpc",
        label: "Capability RPC",
        observes: "17 leaves · ipc-rpc 17",
        traceIdSource: "transport.status.capabilities",
      }),
      expect.objectContaining({
        id: "native-event-bus",
        label: "NativeEventBus",
        observes: "2 channels · comma:surfaces:changed, comma:notch:event",
        traceIdSource: "transport.status.events",
      }),
      expect.objectContaining({
        id: "observability-sink",
        label: "Observability sink",
        observes: "ready · redacted · userData/agent-observability/native-events.jsonl",
        traceIdSource: "transport.status.observability",
      }),
      expect.objectContaining({
        id: "peer-channel-runtime",
        label: "Peer channel runtime",
        observes: "not-started · active no",
        traceIdSource: "transport.status.messagePort",
      }),
    ]);
  });
});
