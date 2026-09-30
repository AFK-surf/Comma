import type {
  ConnectorBridge,
  CommaNativeBridge,
  GeneratedNativeBridge,
  GeneratedNativeBridgeOverrides,
  NativePeerConnection,
  NativePeersBridge,
  NativeStateBridge,
  NativeRendererIdentity,
  SurfacesBridge,
  UpdateBridge,
} from "@comma/native-bridge";
import {
  createGeneratedNativeBridgeMock,
  mergeGeneratedNativeBridgeOverrides,
} from "@comma/native-bridge";
import { vi } from "vitest";

type CommaNativeBridgeMockOverrides = Omit<
  Partial<CommaNativeBridge>,
  keyof GeneratedNativeBridge | "connector" | "updates"
> & {
  connector?: Partial<ConnectorBridge>;
  peers?: Partial<NativePeersBridge>;
  updates?: Partial<UpdateBridge>;
} & Omit<GeneratedNativeBridgeOverrides, "peers" | "surfaces"> & {
    surfaces?: Partial<SurfacesBridge>;
  };

export function createNativeBridgeMock(
  overrides: CommaNativeBridgeMockOverrides = {}
): CommaNativeBridge {
  const generatedBridge = mergeGeneratedNativeBridgeOverrides(
    createGeneratedNativeBridgeMock({
      command: (implementation) => vi.fn(implementation) as typeof implementation,
      event: (implementation) => vi.fn(implementation) as typeof implementation,
      state: (getSnapshot) => createNativeStateBridgeMock(getSnapshot),
    }),
    overrides
  );
  const updates: UpdateBridge = {
    status: vi.fn(async () => ({
      configured: false,
      currentVersion: "test",
      error: "Updates are unavailable in this test runtime.",
    })),
    check: vi.fn(async () => null),
    download: vi.fn(async () => false),
    apply: vi.fn(async () => false),
    ...overrides.updates,
  };
  const connector: ConnectorBridge = {
    status: vi.fn(async () => ({
      available: false,
      configured: false,
      installed: false,
      running: false,
      reason: "Connector is unavailable in this test runtime.",
    })),
    configure: vi.fn(async () => ({
      available: false,
      configured: false,
      installed: false,
      running: false,
      reason: "Connector is unavailable in this test runtime.",
    })),
    start: vi.fn(async () => ({
      available: false,
      configured: false,
      installed: false,
      running: false,
      reason: "Connector is unavailable in this test runtime.",
    })),
    stop: vi.fn(async () => ({
      available: false,
      configured: false,
      installed: false,
      running: false,
      reason: "Connector is unavailable in this test runtime.",
    })),
    restart: vi.fn(async () => ({
      available: false,
      configured: false,
      installed: false,
      running: false,
      reason: "Connector is unavailable in this test runtime.",
    })),
    uninstall: vi.fn(async () => ({
      available: false,
      configured: false,
      installed: false,
      running: false,
      reason: "Connector is unavailable in this test runtime.",
    })),
    ...overrides.connector,
  };
  const surfaces: SurfacesBridge = {
    ...generatedBridge.surfaces,
    list: generatedBridge.surfaces.state,
    ...overrides.surfaces,
  };
  const self: NativeRendererIdentity = {
    role: "unknown",
    windowId: "web",
    ...overrides.self,
  };
  const peers: NativePeersBridge = {
    connect: vi.fn(async () =>
      createMockPeerConnection(self)
    ) as NativePeersBridge["connect"],
    onConnection: vi.fn(() => () => {}),
    ...overrides.peers,
  };

  return {
    platform: "web",
    os: "unknown",
    ...overrides,
    ...generatedBridge,
    self,
    surfaces,
    peers,
    connector,
    updates,
  };
}

function createMockPeerConnection(peer: NativeRendererIdentity): NativePeerConnection {
  return {
    channelId: "peer_mock",
    close: vi.fn(),
    notify: {},
    onClose: vi.fn(() => () => {}),
    peer,
    remote: {},
    side: "initiator",
  };
}

export function installNativeBridgeMock(
  overrides: CommaNativeBridgeMockOverrides = {}
) {
  const bridge = createNativeBridgeMock(overrides);
  globalThis.commaNative = bridge;
  return bridge;
}

export function createNativeStateBridgeMock<Snapshot, GetInput = void>(
  getSnapshot: (input: GetInput) => Promise<Snapshot> | Snapshot
): NativeStateBridge<Snapshot, GetInput> {
  const get = vi.fn(async (input: GetInput) => getSnapshot(input));
  const bridge = Object.assign(get, {
    get,
    subscribe: vi.fn(
      (listener: (snapshot: Snapshot) => void, replayInput: GetInput) => {
        void get(replayInput).then(listener);
        return () => {};
      }
    ),
  });

  return bridge as unknown as NativeStateBridge<Snapshot, GetInput>;
}
