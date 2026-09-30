import { describe, expect, it, vi } from "vitest";
import type { SynchronicityState } from "@comma/native-bridge";
import type { CommaApiClient } from "../../../api/client";
import { enrollDriveDevice, refreshDrive } from "../driveBackend";
import type {
  DriveBackend,
  DriveBackendSnapshot,
  DriveSynchronicityBackend,
} from "../driveSynchronicityBackend";
import { DriveStore, type DriveDevice, type DriveFile } from "../driveStore";

const devices: DriveDevice[] = [
  { current: true, id: "own", label: "Own" },
  { current: false, id: "remote", label: "Remote" },
];
const space = { id: "space", name: "Space", writable: true };

describe("Drive backend refresh", () => {
  it("keeps a recording revealed after an old list started, then accepts a later deletion", async () => {
    let release!: (value: DriveBackendSnapshot) => void;
    const oldList = new Promise<DriveBackendSnapshot>((resolve) => {
      release = resolve;
    });
    const older = file("remote");
    const recording = { ...file("own"), name: "take.wav", folderPath: "recording" };
    const load = vi
      .fn()
      .mockReturnValueOnce(oldList)
      .mockResolvedValueOnce(snapshot(older));
    const backend = { load } as unknown as DriveBackend;
    const store = new DriveStore({ devices, files: [older], spaces: [space] });
    const refresh = refreshDrive(store, backend);
    store.revealFile({ device: devices[0]!, file: recording, space });
    release(snapshot(older));
    await refresh;
    expect(store.getSnapshot().files).toEqual([older, recording]);
    expect(load).toHaveBeenCalledTimes(1);
    // The next request begins after the reveal; its absence is authoritative.
    await refreshDrive(store, backend);
    expect(store.getSnapshot().files).toEqual([older]);
    expect(load).toHaveBeenCalledTimes(2);
  });

  it("queues a selected-origin refresh instead of committing stale rows", async () => {
    let releaseFirst: ((snapshot: DriveBackendSnapshot) => void) | undefined;
    const firstLoad = new Promise<DriveBackendSnapshot>((resolve) => {
      releaseFirst = resolve;
    });
    const own = file("own");
    const remote = file("remote");
    const load = vi
      .fn()
      .mockImplementationOnce(() => firstLoad)
      .mockResolvedValueOnce(snapshot(remote));
    const backend = { load } as unknown as DriveBackend;
    const store = new DriveStore({ devices, files: [], spaces: [space] });

    const initial = refreshDrive(store, backend);
    store.setOriginDevice("remote");
    const selected = refreshDrive(store, backend);
    releaseFirst!(snapshot(own));
    await Promise.all([initial, selected]);

    expect(load.mock.calls).toEqual([
      [{ policy: "newest" }],
      [{ originDeviceId: "remote", policy: "newest" }],
    ]);
    expect(store.getSnapshot().files).toEqual([remote]);
    expect(store.getSnapshot().originDeviceId).toBe("remote");
  });
});

describe("Drive device enrollment", () => {
  it("sends a valid stable label with a node-key suffix before binding the domain", async () => {
    const nk = "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u";
    const getSynchronicityStatus = vi.fn(async () => ({
      configured: true,
      network_id: "net-1",
      provisioned: true,
      status: "ready" as const,
    }));
    const enrollSynchronicityDevice = vi.fn(async () => ({
      created: true,
      device_id: "dev-1",
      domain: "default.workspace.sync.test",
      network: "net-1",
    }));
    const setDomain = vi.fn(async () =>
      state({ domain: "default.workspace.sync.test" })
    );

    await enrollDriveDevice(
      {
        getSynchronicityStatus,
        enrollSynchronicityDevice,
      } as unknown as CommaApiClient,
      { setDomain } as unknown as DriveSynchronicityBackend,
      state({ deviceName: "Zanwei's MacBook Pro.local", origin: `key:${nk}` })
    );

    expect(enrollSynchronicityDevice).toHaveBeenCalledWith({
      label: "zanwei-s-macbook-pro-local-ybndrfg8ejkm",
      nk,
    });
    expect(setDomain).toHaveBeenCalledWith("default.workspace.sync.test");
  });

  it("uses a valid fallback for a device name with no ASCII label characters", async () => {
    const nk = "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u";
    const api = {
      getSynchronicityStatus: vi.fn(async () => ({
        configured: true,
        network_id: "net-1",
        provisioned: true,
        status: "ready" as const,
      })),
      enrollSynchronicityDevice: vi.fn(async () => ({
        created: false,
        device_id: "dev-1",
        domain: "default.workspace.sync.test",
        network: "net-1",
      })),
    };

    await enrollDriveDevice(
      api as unknown as CommaApiClient,
      { setDomain: vi.fn(async () => state()) } as unknown as DriveSynchronicityBackend,
      state({ deviceName: "工作电脑", origin: `key:${nk}` })
    );

    expect(api.enrollSynchronicityDevice).toHaveBeenCalledWith({
      label: "comma-desktop-ybndrfg8ejkm",
      nk,
    });
  });

  it("does not enroll a node that is already named", async () => {
    const api = {
      getSynchronicityStatus: vi.fn(),
      enrollSynchronicityDevice: vi.fn(),
    };

    await enrollDriveDevice(
      api as unknown as CommaApiClient,
      { setDomain: vi.fn() } as unknown as DriveSynchronicityBackend,
      state({
        domain: "default.workspace.sync.test",
        origin: "studio@default.workspace.sync.test",
      })
    );

    expect(api.getSynchronicityStatus).not.toHaveBeenCalled();
    expect(api.enrollSynchronicityDevice).not.toHaveBeenCalled();
  });
});

function file(deviceId: string): DriveFile {
  return {
    contentsHash: `${deviceId}-root`,
    deviceId,
    id: `synch:space:${deviceId}.txt`,
    modifiedAt: 1,
    name: `${deviceId}.txt`,
    sizeBytes: 1,
    spaceId: "space",
  };
}

function snapshot(driveFile: DriveFile): DriveBackendSnapshot {
  return {
    devices,
    files: [driveFile],
    localSyncEnabled: false,
    localSyncRoot: "/Drive",
    originDeviceId: "own",
    spaces: [space],
  };
}

function state(overrides: Partial<SynchronicityState> = {}): SynchronicityState {
  return {
    dataDir: "/node",
    defaultSpace: "comma-drive",
    deviceName: "Studio",
    domain: "",
    localRoot: "/Drive",
    origin: "key:ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u",
    origins: [],
    pins: [],
    spaces: [],
    status: "ready",
    ...overrides,
  };
}
