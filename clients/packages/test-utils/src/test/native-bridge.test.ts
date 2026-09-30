import {
  nativeCapabilityRegistry,
  nativeEventRegistry,
  nativeStateRegistry,
  type NativeStateBridge,
} from "@comma/native-bridge";
import { describe, expect, it, vi } from "vitest";
import { createNativeBridgeMock, createNativeStateBridgeMock } from "../native-bridge";

const TEST_SESSION_PRODUCT_LEASE = {
  audience: "https://api.comma.example",
  authorityInstanceId: "authority-1",
  generation: 3,
  sessionId: "session-1",
} as const;

describe("createNativeBridgeMock", () => {
  it("exposes a default web renderer identity and allows explicit overrides", () => {
    expect(createNativeBridgeMock().self).toEqual({
      role: "unknown",
      windowId: "web",
    });

    expect(
      createNativeBridgeMock({
        self: { role: "main-window", windowId: "win_main" },
      }).self
    ).toEqual({
      role: "main-window",
      windowId: "win_main",
    });
  });

  it("keeps every runtime leaf reachable from the final test bridge", async () => {
    const bridge = createNativeBridgeMock();
    const stateIds = new Set(nativeStateRegistry.map((state) => state.id));

    for (const capability of nativeCapabilityRegistry) {
      const member = getGeneratedBridgeMember(
        bridge,
        capability.bridge.namespace,
        capability.bridge.method
      );

      if (stateIds.has(capability.id)) {
        const stateBridge = member as NativeStateBridge<unknown, unknown>;
        const input =
          capability.sessionAdmission === "required"
            ? { session: TEST_SESSION_PRODUCT_LEASE }
            : undefined;
        expect(stateBridge, capability.id).toEqual(expect.any(Function));
        await expect(stateBridge.get(input)).resolves.toBeDefined();
        continue;
      }

      expect(member, capability.id).toEqual(expect.any(Function));
    }

    for (const event of nativeEventRegistry) {
      if (!event.bridge) {
        continue;
      }

      const unsubscribe = (
        getGeneratedBridgeMember(
          bridge,
          event.bridge.namespace,
          event.bridge.method
        ) as (listener: (payload: unknown) => void) => () => void
      )(vi.fn());

      expect(unsubscribe, event.id).toEqual(expect.any(Function));
      unsubscribe();
    }

    expect(bridge.surfaces.list).toBe(bridge.surfaces.state);
  });

  it("preserves generated namespace and surfaces alias overrides", async () => {
    const nativeInfo = vi.fn(async () => ({
      appVersion: "override",
      os: "macos" as const,
      platform: "electron" as const,
    }));
    const listSurfaces = vi.fn(async () => ({
      notch: { available: true },
      panels: [],
      platform: {
        appVersion: "override",
        os: "macos" as const,
        platform: "electron" as const,
      },
      views: [],
      windows: [],
    }));

    const bridge = createNativeBridgeMock({
      native: { info: nativeInfo },
      surfaces: { list: listSurfaces },
    });

    await expect(bridge.native.info()).resolves.toEqual({
      appVersion: "override",
      os: "macos",
      platform: "electron",
    });
    await expect(bridge.surfaces.list()).resolves.toMatchObject({
      notch: { available: true },
    });
    expect(bridge.native.info).toBe(nativeInfo);
    expect(bridge.surfaces.list).toBe(listSurfaces);
  });

  it("passes generic state get input to direct and replay reads", async () => {
    const getSnapshot = vi.fn(
      (input: { expectedSessionId: string; generation: number }) => ({
        generation: input.generation,
        sessionId: input.expectedSessionId,
      })
    );
    const state = createNativeStateBridgeMock(getSnapshot);
    const input = { expectedSessionId: "session-1", generation: 7 };
    const listener = vi.fn();

    await expect(state.get(input)).resolves.toEqual({
      generation: 7,
      sessionId: "session-1",
    });
    const unsubscribe = state.subscribe(listener, input);
    await vi.waitFor(() =>
      expect(listener).toHaveBeenCalledWith({
        generation: 7,
        sessionId: "session-1",
      })
    );
    unsubscribe();

    expect(getSnapshot).toHaveBeenNthCalledWith(1, input);
    expect(getSnapshot).toHaveBeenNthCalledWith(2, input);
  });
});

function getGeneratedBridgeMember(bridge: unknown, namespace: string, method: string) {
  return (bridge as Record<string, Record<string, unknown>>)[namespace]?.[method];
}
