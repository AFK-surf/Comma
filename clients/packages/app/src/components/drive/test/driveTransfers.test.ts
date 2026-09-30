import { describe, expect, it, vi } from "vitest";

vi.mock("@comma/ui", () => {
  const toast = Object.assign(vi.fn(), {
    dismiss: vi.fn(),
    error: vi.fn(),
    success: vi.fn(),
    warning: vi.fn(),
  });
  return { toast };
});

import { fileDownloadMaxBytes, type CommaNativeBridge } from "@comma/native-bridge";
import type { DriveBackend } from "../driveSynchronicityBackend";
import { DriveStore, type DriveFile } from "../driveStore";
import { downloadDriveFile, uploadDriveFiles } from "../driveTransfers";

const seed = () => ({
  devices: [{ current: true, id: "this-mac", label: "This Mac" }],
  files: [] as DriveFile[],
  spaces: [{ id: "space", name: "Space", writable: true }],
});

describe("Drive transfers", () => {
  it("streams a large Electron node upload without reading renderer bytes", async () => {
    const store = new DriveStore(seed());
    const source = new File([new Uint8Array(1)], "large.bin");
    Object.defineProperty(source, "size", { value: fileDownloadMaxBytes + 1 });
    const read = vi.spyOn(source, "arrayBuffer");
    const backend = backendStub();

    await uploadDriveFiles(
      store,
      [source],
      { deviceId: "this-mac", folderPath: "clips", spaceId: "space" },
      { backend, bridge: electronBridge(), locale: "en" }
    );

    expect(read).not.toHaveBeenCalled();
    expect(backend.writeFile).toHaveBeenCalledWith({
      folderPath: "clips",
      name: "large.bin",
      source,
      spaceId: "space",
    });
    expect(store.getSnapshot().transfers[0]).toMatchObject({ status: "success" });
  });

  it("keeps non-native fallback uploads capped before reading bytes", async () => {
    const store = new DriveStore(seed());
    const source = new File([new Uint8Array(1)], "too-large.bin");
    Object.defineProperty(source, "size", { value: fileDownloadMaxBytes + 1 });
    const read = vi.spyOn(source, "arrayBuffer");

    await uploadDriveFiles(
      store,
      [source],
      { deviceId: "this-mac", spaceId: "space" },
      { locale: "en" }
    );

    expect(read).not.toHaveBeenCalled();
    expect(store.getSnapshot().transfers[0]).toMatchObject({ status: "error" });
  });

  it("runs a batch with fixed transfer concurrency", async () => {
    const store = new DriveStore(seed());
    let active = 0;
    let maximum = 0;
    const backend = backendStub({
      writeFile: vi.fn(async () => {
        active += 1;
        maximum = Math.max(maximum, active);
        await new Promise((resolve) => setTimeout(resolve, 5));
        active -= 1;
      }),
    });
    const sources = Array.from(
      { length: 6 },
      (_unused, index) => new File([String(index)], `${index}.txt`)
    );

    await uploadDriveFiles(
      store,
      sources,
      { deviceId: "this-mac", spaceId: "space" },
      { backend, locale: "en" }
    );

    expect(maximum).toBeLessThanOrEqual(2);
    expect(
      store.getSnapshot().transfers.every(({ status }) => status === "success")
    ).toBe(true);
  });

  it("uses the node's streamed save path for a large Electron download", async () => {
    const file: DriveFile = {
      contentsHash: "root",
      deviceId: "other",
      id: "large",
      modifiedAt: 1,
      name: "large.bin",
      sizeBytes: 32 * 1024 * 1024,
      spaceId: "space",
    };
    const store = new DriveStore({ ...seed(), files: [file] });
    const backend = backendStub({
      saveDownload: vi.fn(async () => ({
        downloadRef: `dnl1_${"A".repeat(43)}`,
        fileName: file.name,
        status: "saved" as const,
      })),
    });
    const bridge = {
      files: {
        openDownload: vi.fn(),
        revealDownload: vi.fn(),
        saveDownload: vi.fn(),
      },
      os: "macos",
      platform: "electron",
    } as unknown as Pick<CommaNativeBridge, "files" | "os" | "platform">;

    await expect(
      downloadDriveFile(store, file, { backend, bridge, locale: "en" })
    ).resolves.toBe(true);
    expect(backend.saveDownload).toHaveBeenCalledWith(file);
    expect(backend.readFile).not.toHaveBeenCalled();
    expect(bridge.files.saveDownload).not.toHaveBeenCalled();
    expect(store.getSnapshot().transfers[0]).toMatchObject({
      downloadRef: `dnl1_${"A".repeat(43)}`,
      status: "success",
    });
  });

  it("never falls back to renderer bytes for an Electron node download", async () => {
    const file: DriveFile = {
      contentsHash: "root",
      deviceId: "other",
      id: "small",
      modifiedAt: 1,
      name: "small.txt",
      sizeBytes: 5,
      spaceId: "space",
    };
    const store = new DriveStore({ ...seed(), files: [file] });
    const backend = backendStub();
    const bridge = {
      files: {
        openDownload: vi.fn(),
        revealDownload: vi.fn(),
        saveDownload: vi.fn(),
      },
      os: "macos",
      platform: "electron",
    } as unknown as Pick<CommaNativeBridge, "files" | "os" | "platform">;

    await expect(
      downloadDriveFile(store, file, { backend, bridge, locale: "en" })
    ).resolves.toBe(false);
    expect(backend.saveDownload).toHaveBeenCalledWith(file);
    expect(backend.readFile).not.toHaveBeenCalled();
    expect(bridge.files.saveDownload).not.toHaveBeenCalled();
    expect(store.getSnapshot().transfers[0]).toMatchObject({ status: "error" });
  });
});

function electronBridge() {
  return {
    files: {
      openDownload: vi.fn(),
      revealDownload: vi.fn(),
      saveDownload: vi.fn(),
    },
    os: "macos",
    platform: "electron",
  } as unknown as Pick<CommaNativeBridge, "files" | "os" | "platform">;
}

function backendStub(overrides: Record<string, unknown> = {}) {
  return {
    adopt: vi.fn(),
    adoptNewest: vi.fn(),
    addSpaceFromFolder: vi.fn(),
    deleteFile: vi.fn(),
    load: vi.fn(async () => ({
      ...seed(),
      localSyncEnabled: false,
      localSyncRoot: "/Drive",
      originDeviceId: "this-mac",
    })),
    openLocalRoot: vi.fn(),
    planSpaceSync: vi.fn(),
    readFile: vi.fn(),
    removeSpace: vi.fn(),
    renameSpace: vi.fn(),
    restart: vi.fn(),
    saveDownload: vi.fn(async () => ({ status: "unavailable" as const })),
    setKeepOffline: vi.fn(),
    setSpaceSynced: vi.fn(),
    versions: vi.fn(),
    writeFile: vi.fn(),
    ...overrides,
  } as unknown as DriveBackend & Record<string, ReturnType<typeof vi.fn>>;
}
