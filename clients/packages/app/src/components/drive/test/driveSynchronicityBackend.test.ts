import { afterEach, describe, expect, it, vi } from "vitest";
import type {
  CommaNativeBridge,
  SynchronicityListInput,
  SynchronicityState,
} from "@comma/native-bridge";
import {
  DriveSynchronicityBackend,
  driveFileIdFor,
} from "../driveSynchronicityBackend";
import type { DriveFile } from "../driveStore";

const OWN = "studio@default.example";
const REMOTE = "laptop@default.example";

const readyState = {
  dataDir: "/node",
  defaultSpace: "comma-drive",
  deviceName: "Studio",
  domain: "default.example",
  localRoot: "/Users/test/Drive",
  origin: OWN,
  origins: [OWN, REMOTE],
  pins: [],
  spaces: [
    {
      autoAdopt: false,
      checkoutPath: "",
      heldSize: 0,
      id: "comma-drive",
      label: "",
      replica: false,
      sourcePath: "/Users/test/Drive",
      writable: true,
    },
    {
      autoAdopt: false,
      checkoutPath: "/Users/test/Comma Spaces/notes",
      heldSize: 12,
      id: "notes",
      label: "",
      replica: true,
      sourcePath: "",
      writable: false,
    },
  ],
  status: "ready",
} as unknown as SynchronicityState;

afterEach(() => {
  globalThis.commaNative = undefined;
});

describe("DriveSynchronicityBackend", () => {
  it("includes the default source in local sync even when remote adoption is off", async () => {
    const native = installBridge();
    native.state.mockResolvedValue({ ...readyState, spaces: [readyState.spaces[0]!] });
    const backend = new DriveSynchronicityBackend();
    const active = await backend.load({ policy: "newest" });
    expect(active.localSyncEnabled).toBe(true);
    expect(active.spaces[0]).toMatchObject({ synced: true, protected: true });
    native.state.mockResolvedValue({
      ...readyState,
      spaces: [{ ...readyState.spaces[0]!, sourcePaused: true }],
    });
    const paused = await backend.load({ policy: "newest" });
    expect(paused.localSyncEnabled).toBe(false);
    expect(paused.spaces[0]).toMatchObject({ synced: false, protected: true });
  });

  it("looks up only the requested recording path and rejects a prefix neighbor", async () => {
    const entry = {
      contentRoot: "recording-root",
      kind: "file" as const,
      mtimeMs: 20,
      origin: OWN,
      path: "recording/take.wav",
      size: 20_000_000,
      versions: 1,
    };
    const list = vi.fn(async () => ({ entries: [entry], nextCursor: "more" }));
    globalThis.commaNative = {
      synchronicity: { state: vi.fn(async () => readyState), list },
    } as unknown as CommaNativeBridge;
    const backend = new DriveSynchronicityBackend();
    const result = await backend.lookupFile({
      space: "comma-drive",
      path: "recording/take.wav",
    });
    expect(result.file).toMatchObject({
      name: "take.wav",
      folderPath: "recording",
      sizeBytes: 20_000_000,
    });
    expect(result.device).toMatchObject({ current: true, id: OWN });
    expect(list.mock.calls).toEqual([
      [
        {
          limit: 1,
          policy: "newest",
          prefix: "recording/take.wav",
          space: "comma-drive",
        },
      ],
    ]);
    // The recording was removed, but a similarly named path still exists.
    list.mockResolvedValueOnce({
      entries: [{ ...entry, path: "recording/take.wav.old" }],
      nextCursor: "",
    });
    await expect(
      backend.lookupFile({ space: "comma-drive", path: "recording/take.wav" })
    ).rejects.toThrow("no longer exists");
    expect(list).toHaveBeenCalledTimes(2);
  });

  it("loads a losing peer origin from the node instead of filtering newest rows", async () => {
    const list = vi.fn(async (input: SynchronicityListInput) => ({
      entries:
        input.space === "comma-drive" && input.policy === `origin=${REMOTE}`
          ? [
              {
                contentRoot: "remote-root",
                kind: "file" as const,
                mtimeMs: 12,
                origin: REMOTE,
                path: "remote-loser.txt",
                size: 5,
                versions: 2,
              },
            ]
          : [],
      nextCursor: "",
    }));
    installBridge({ list });
    const backend = new DriveSynchronicityBackend();

    const loaded = await backend.load({
      originDeviceId: REMOTE,
      policy: "newest",
    });

    expect(list.mock.calls.map(([input]) => input.policy)).toEqual([
      `origin=${REMOTE}`,
      `origin=${REMOTE}`,
    ]);
    expect(loaded.files).toMatchObject([
      {
        deviceId: REMOTE,
        id: driveFileIdFor("comma-drive", "remote-loser.txt"),
      },
    ]);
    expect(loaded.devices.map((device) => device.id)).toEqual([OWN, REMOTE]);
    expect(loaded.spaces.find((space) => space.id === "comma-drive")?.writable).toBe(
      true
    );
    expect(loaded.spaces.find((space) => space.id === "notes")?.writable).toBe(false);
  });

  it("reads one capped preview range from the file's selected origin", async () => {
    const read = vi.fn(async () => ({
      content: Buffer.from("abcde").toString("base64"),
      contentRoot: "root-one",
      eof: true,
      length: 5,
      offset: 0,
      size: 5,
    }));
    installBridge({ read });
    const backend = new DriveSynchronicityBackend();
    const file = remoteFile();

    const blob = await backend.readFile(file);

    expect(await blob.text()).toBe("abcde");
    expect(read).toHaveBeenCalledWith({
      length: 5,
      offset: 0,
      path: "remote-loser.txt",
      policy: `origin=${REMOTE}`,
      space: "comma-drive",
    });
  });

  it("continues after a filtered empty page when the node supplies a scan cursor", async () => {
    const cursors: Array<string | undefined> = [];
    const list = vi.fn(async (input: SynchronicityListInput) => {
      if (input.space !== "comma-drive") return { entries: [], nextCursor: "" };
      cursors.push(input.cursor);
      if (!input.cursor) return { entries: [], nextCursor: "filtered-through.txt" };
      if (input.cursor === "filtered-through.txt") {
        return {
          entries: [
            {
              contentRoot: "later-root",
              kind: "file" as const,
              mtimeMs: 13,
              origin: OWN,
              path: "later.txt",
              size: 5,
              versions: 1,
            },
          ],
          nextCursor: "",
        };
      }
      return { entries: [], nextCursor: "" };
    });
    installBridge({ list });

    const loaded = await new DriveSynchronicityBackend().load({ policy: "newest" });

    expect(cursors).toEqual([undefined, "filtered-through.txt"]);
    expect(loaded.files.map((file) => file.name)).toEqual(["later.txt"]);
  });

  it("rejects source mutations for a replica-only space before invoking native", async () => {
    const write = vi.fn(async () => ({ status: "done" as const }));
    const deleteFile = vi.fn(async () => ({ status: "done" as const }));
    const adopt = vi.fn(async () => ({ status: "done" as const }));
    installBridge({ adopt, delete: deleteFile, write });
    const backend = new DriveSynchronicityBackend();
    await backend.load({ policy: "newest" });
    const file = { ...remoteFile(), spaceId: "notes" };

    await expect(
      backend.writeFile({
        blob: new Blob(["x"]),
        name: "x.txt",
        spaceId: "notes",
      })
    ).rejects.toThrow("read-only");
    await expect(backend.deleteFile(file)).rejects.toThrow("read-only");
    await expect(
      backend.adopt(file, {
        contentsHash: "other",
        deviceId: REMOTE,
        id: "remote-version",
        modifiedAt: 1,
        sizeBytes: 1,
      })
    ).rejects.toThrow("read-only");
    expect(write).not.toHaveBeenCalled();
    expect(deleteFile).not.toHaveBeenCalled();
    expect(adopt).not.toHaveBeenCalled();
  });

  it("imports picked File handles through the native stream capability", async () => {
    const importFile = vi.fn(async () => ({ status: "done" as const }));
    const write = vi.fn(async () => ({ status: "done" as const }));
    installBridge({ importFile, write });
    const backend = new DriveSynchronicityBackend();
    await backend.load({ policy: "newest" });
    const source = new File(["large"], "clip.mov");

    await backend.writeFile({
      folderPath: "clips/2026",
      name: "clip.mov",
      source,
      spaceId: "comma-drive",
    });

    expect(importFile).toHaveBeenCalledWith({
      path: "clips/2026/clip.mov",
      source,
      space: "comma-drive",
    });
    expect(write).not.toHaveBeenCalled();
  });

  it("rejects unsafe import destination paths before invoking native", async () => {
    const importFile = vi.fn(async () => ({ status: "done" as const }));
    installBridge({ importFile });
    const backend = new DriveSynchronicityBackend();
    await backend.load({ policy: "newest" });

    await expect(
      backend.writeFile({
        folderPath: "clips/../escape",
        name: "clip.mov",
        source: new File(["large"], "clip.mov"),
        spaceId: "comma-drive",
      })
    ).rejects.toThrow("unsafe segment");
    expect(importFile).not.toHaveBeenCalled();
  });

  it("delegates streamed saves and opening the owned root to dedicated capabilities", async () => {
    const saveDownload = vi.fn(async () => ({
      downloadRef: `dnl1_${"A".repeat(43)}`,
      fileName: "remote-loser.txt",
      status: "saved" as const,
    }));
    const openLocalRoot = vi.fn(async () => ({ status: "opened" as const }));
    installBridge({ openLocalRoot, saveDownload });
    const backend = new DriveSynchronicityBackend();
    const file = remoteFile();

    await expect(backend.saveDownload(file)).resolves.toMatchObject({
      status: "saved",
    });
    await expect(backend.openLocalRoot()).resolves.toBe(true);
    expect(saveDownload).toHaveBeenCalledWith({
      fileName: file.name,
      path: file.name,
      policy: `origin=${REMOTE}`,
      space: file.spaceId,
    });
    expect(openLocalRoot).toHaveBeenCalledWith();
  });
});

function remoteFile(): DriveFile {
  return {
    contentsHash: "remote-root",
    deviceId: REMOTE,
    id: driveFileIdFor("comma-drive", "remote-loser.txt"),
    modifiedAt: 12,
    name: "remote-loser.txt",
    sizeBytes: 5,
    spaceId: "comma-drive",
  };
}

function installBridge(overrides: Record<string, unknown> = {}) {
  const synchronicity = {
    adopt: vi.fn(async () => ({ status: "done" as const })),
    adoptTree: vi.fn(async () => ({
      adopt: 0,
      current: 0,
      differing: 0,
      skipped: 0,
      status: "done" as const,
    })),
    delete: vi.fn(async () => ({ status: "done" as const })),
    importFile: vi.fn(async () => ({ status: "done" as const })),
    list: vi.fn(async () => ({ entries: [], nextCursor: "" })),
    openLocalRoot: vi.fn(async () => ({ status: "opened" as const })),
    pickFolder: vi.fn(async () => ({ path: "" })),
    pin: vi.fn(async () => ({ status: "done" as const })),
    read: vi.fn(async () => ({
      content: "",
      contentRoot: "empty-root",
      eof: true,
      length: 0,
      offset: 0,
      size: 0,
    })),
    replicaSet: vi.fn(async () => ({ status: "done" as const })),
    restart: vi.fn(async () => readyState),
    saveDownload: vi.fn(async () => ({ status: "unavailable" as const })),
    setDomain: vi.fn(async () => readyState),
    setSpaceSettings: vi.fn(async () => readyState),
    sourceAdd: vi.fn(async () => ({ status: "done" as const })),
    sourceRemove: vi.fn(async () => ({ status: "done" as const })),
    state: vi.fn(async () => readyState),
    versions: vi.fn(async () => ({ versions: [] })),
    write: vi.fn(async () => ({ status: "done" as const })),
    ...overrides,
  };
  globalThis.commaNative = {
    os: "macos",
    platform: "electron",
    synchronicity,
  } as unknown as CommaNativeBridge;
  return synchronicity;
}
