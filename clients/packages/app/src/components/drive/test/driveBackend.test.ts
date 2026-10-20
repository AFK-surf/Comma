import type { CallFn } from "@comma/core-client";
import type { DriveValue } from "@comma/core/contract";
import { describe, expect, it, vi } from "vitest";
import { ensureDriveFileThumbnail } from "../driveBackend";
import { DriveStore } from "../driveStore";

describe("Drive list thumbnails", () => {
  it("draws large images too, two reads at a time", async () => {
    const releases: (() => void)[] = [];
    const read = vi.fn(
      (_name: string, _params: { file: string }) =>
        new Promise<{ bytes: Uint8Array; mediaType: string }>((resolve) => {
          releases.push(() =>
            resolve({
              bytes: new TextEncoder().encode("<svg/>"),
              mediaType: "image/svg+xml",
            })
          );
        })
    );
    const photos = ["a", "b", "c"].map((name) => ({
      contentsHash: `${name}-root`,
      deviceId: "own",
      id: `synch:space:${name}.svg`,
      modifiedAt: 1,
      name: `${name}.svg`,
      sizeBytes: 40_000_000,
      spaceId: "space",
    }));
    const store = new DriveStore();
    store.setCore({
      node: { status: "ready" },
      devices: [{ current: true, id: "own", label: "Own" }],
      files: photos,
      spaces: [{ id: "space", name: "Space", writable: true }],
      originDeviceId: "own",
      versionPolicy: "newest",
      localSyncEnabled: false,
      localSyncRoot: "/Drive",
      syncHistory: [],
      transfers: [],
    } satisfies DriveValue);

    const drawn = photos.map((photo) =>
      ensureDriveFileThumbnail(store, read as unknown as CallFn, photo)
    );
    expect(read).toHaveBeenCalledTimes(2);
    releases[0]!();
    await drawn[0];
    expect(read).toHaveBeenCalledTimes(3);
    releases[1]!();
    releases[2]!();
    await Promise.all(drawn);

    expect(read.mock.calls.map(([, params]) => params.file)).toEqual(
      photos.map((photo) => photo.id)
    );
    expect(store.getSnapshot().files.every((photo) => photo.thumbnail)).toBe(true);
  });
});
