import { flush } from "@comma/test-utils/fake-clock";
import { render } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { appPreferencesSchema } from "@comma/native-bridge";
import {
  createNativeStateBridgeMock,
  installNativeBridgeMock,
} from "@comma/test-utils/native-bridge";
import { stubProperty } from "@comma/test-utils/stub-property";
import { act } from "react";
import { expect, it, vi } from "vitest";
import { testProductLease } from "../../../test/productInboxProjectionHarness";
import { ChatSessionProvider } from "../../chat/ChatProvider";
import { useFollowLocationSharing, useLocationSharing } from "../locationSharing";

function Follower() {
  useFollowLocationSharing();
  return null;
}

it("sends each position while sharing is on, and none after the browser takes location away", async () => {
  const browser: { report?: PositionCallback; fail?: PositionErrorCallback } = {};
  stubProperty(navigator, "geolocation", {
    value: {
      watchPosition: (ok: PositionCallback, error: PositionErrorCallback) => {
        browser.report = ok;
        browser.fail = error;
        return 1;
      },
      clearWatch: () => undefined,
    },
  });
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "locationSharing" ? { enabled: true } : undefined,
  });
  render(core.wrap(<Follower />));
  await flush();

  browser.report!({
    coords: { latitude: 35.6812, longitude: 139.7671, accuracy: 40 },
    timestamp: 1_794_000_000_000,
  } as GeolocationPosition);
  browser.fail!({ code: 1, PERMISSION_DENIED: 1 } as GeolocationPositionError);
  await flush();
  expect(core.sentTo("locationSharing.report")).toEqual([
    {
      position: {
        latitude: 35.6812,
        longitude: 139.7671,
        accuracy: 40,
        readAt: 1_794_000_000_000,
      },
    },
    { position: null },
  ]);
});

it("follows nothing and forgets the last position while macOS refuses Comma the location", async () => {
  installNativeBridgeMock({
    appPreferences: {
      state: createNativeStateBridgeMock(() =>
        appPreferencesSchema.parse({
          launchAtLogin: false,
          showInDock: true,
          showInMenuBar: true,
          systemLocationStatus: "denied",
        })
      ),
    },
    os: "macos",
    platform: "electron",
  });
  const watchPosition = vi.fn(() => 1);
  stubProperty(navigator, "geolocation", {
    value: { watchPosition, clearWatch: () => undefined },
  });
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "locationSharing" ? { enabled: true } : undefined,
  });
  render(core.wrap(<Follower />));
  await flush();
  expect(core.sentTo("locationSharing.report")).toContainEqual({ position: null });
  expect(watchPosition).not.toHaveBeenCalled();
});

it("asks the desktop's system first, and stays off without reading when macOS has location off", async () => {
  const requestLocationAuthorization = vi.fn(async () => "denied" as const);
  installNativeBridgeMock({
    appPreferences: { requestLocationAuthorization },
    os: "macos",
    platform: "electron",
  });
  const getCurrentPosition = vi.fn();
  stubProperty(navigator, "geolocation", { value: { getCurrentPosition } });
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "locationSharing" ? { enabled: false } : undefined,
  });
  let sharing: ReturnType<typeof useLocationSharing> | undefined;
  function Switch() {
    sharing = useLocationSharing(true);
    return null;
  }
  render(core.wrap(<Switch />));
  await flush();

  await act(() => sharing!.set(true));
  expect(requestLocationAuthorization).toHaveBeenCalledOnce();
  expect(getCurrentPosition).not.toHaveBeenCalled();
  expect(core.sentTo("locationSharing.set")).toEqual([]);
  expect(sharing!.denied).toBe(true);
  expect(sharing!.pending).toBe(false);
});

function sharingWith(requests: { id: string; group: string; conversation: string }[]) {
  return createScriptedCore({
    values: (topic) =>
      topic.topic === "locationSharing"
        ? { enabled: true }
        : topic.topic === "agentLocationRequests"
          ? { requests }
          : undefined,
  });
}

it("answers the Agent's location requests while the person shares, so no card asks", async () => {
  stubProperty(navigator, "permissions", {
    value: { query: async () => ({ state: "granted" }) },
  });
  stubProperty(navigator, "geolocation", {
    value: {
      watchPosition: () => 1,
      clearWatch: () => undefined,
      getCurrentPosition: (ok: PositionCallback) =>
        ok({
          coords: { latitude: 31.23, longitude: 121.47, accuracy: 30 },
          timestamp: 1_794_000_000_000,
        } as GeolocationPosition),
    },
  });
  const core = sharingWith([
    { id: "cap-1", group: "grp-1", conversation: "cnv-1" },
    { id: "cap-2", group: "grp-2", conversation: "cnv-2" },
  ]);
  render(core.wrap(<Follower />));
  await flush();
  // The next message carries this newer reading too.
  expect(core.sentTo("locationSharing.report")).toEqual([
    {
      position: {
        latitude: 31.23,
        longitude: 121.47,
        accuracy: 30,
        readAt: 1_794_000_000_000,
      },
    },
  ]);
  expect(core.sentTo("agentRequests.shareLocation")).toEqual([
    {
      group: "grp-1",
      conversation: "cnv-1",
      request: "cap-1",
      latitude: 31.23,
      longitude: 121.47,
      accuracy: 30,
    },
    {
      group: "grp-2",
      conversation: "cnv-2",
      request: "cap-2",
      latitude: 31.23,
      longitude: 121.47,
      accuracy: 30,
    },
  ]);
});

it("leaves a request on its card when the browser would ask the person first", async () => {
  stubProperty(navigator, "permissions", {
    value: { query: async () => ({ state: "prompt" }) },
  });
  const getCurrentPosition = vi.fn();
  stubProperty(navigator, "geolocation", {
    value: { watchPosition: () => 1, clearWatch: () => undefined, getCurrentPosition },
  });
  const core = sharingWith([{ id: "cap-1", group: "grp-1", conversation: "cnv-1" }]);
  render(core.wrap(<Follower />));
  await flush();
  expect(getCurrentPosition).not.toHaveBeenCalled();
  expect(core.sentTo("agentRequests.shareLocation")).toEqual([]);
});

it("is followed by the chat session the app mounts, so each message carries the position", async () => {
  const watchPosition = vi.fn(() => 1);
  stubProperty(navigator, "geolocation", {
    value: { watchPosition, clearWatch: () => undefined },
  });
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "locationSharing" ? { enabled: true } : undefined,
  });
  render(
    core.wrap(
      <ChatSessionProvider productLease={testProductLease}>{null}</ChatSessionProvider>
    )
  );
  await flush();
  expect(watchPosition).toHaveBeenCalledOnce();
});

it("sends nothing when sharing is turned off while the position is read", async () => {
  stubProperty(navigator, "permissions", {
    value: { query: async () => ({ state: "granted" }) },
  });
  const read: { done?: PositionCallback } = {};
  stubProperty(navigator, "geolocation", {
    value: {
      watchPosition: () => 1,
      clearWatch: () => undefined,
      getCurrentPosition: (ok: PositionCallback) => {
        read.done = ok;
      },
    },
  });
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "locationSharing"
        ? { enabled: true }
        : topic.topic === "agentLocationRequests"
          ? { requests: [{ id: "cap-1", group: "grp-1", conversation: "cnv-1" }] }
          : undefined,
  });
  render(core.wrap(<Follower />));
  await flush();
  expect(read.done).toBeDefined();
  act(() => core.emit("locationSharing", { enabled: false }));
  await flush();
  read.done!({
    coords: { latitude: 31.23, longitude: 121.47, accuracy: 30 },
    timestamp: 1_794_000_000_000,
  } as GeolocationPosition);
  await flush();
  expect(core.sentTo("agentRequests.shareLocation")).toEqual([]);
});
