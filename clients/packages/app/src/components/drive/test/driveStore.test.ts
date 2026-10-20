import type { DriveValue } from "@comma/core/contract";
import { describe, expect, it } from "vitest";
import { splitDriveFileName } from "../DriveFileName";
import {
  DriveStore,
  driveFileKind,
  driveFileTypeLabel,
  driveUploadMimeType,
  formatDriveFileSize,
  sortDriveFiles,
  type DriveFile,
  type DriveFileVersion,
} from "../driveStore";

/** Copies of one path, newest first, the way a diverged file carries them. */
const versionsOf = (fileId: string, count: number): DriveFileVersion[] =>
  Array.from({ length: count }, (_unused, index) => ({
    contentsHash: `f0${index}`,
    deviceId: index % 2 === 0 ? "this-mac" : "nas",
    id: `${fileId}-v${index}`,
    modifiedAt: 100 - index,
    sizeBytes: 10 + index,
  }));
const twoVersions = (fileId: string) => versionsOf(fileId, 2);
const fiveVersions = (fileId: string) => versionsOf(fileId, 5);

const remote = {
  contentsHash: "f00",
  deviceId: "nas",
  id: "file-remote",
  modifiedAt: 1,
  name: "remote.pdf",
  sizeBytes: 10,
  spaceId: "space-a",
};

const drive = (files: DriveValue["files"] = [remote]): DriveValue => ({
  node: { status: "ready" },
  devices: [{ current: true, id: "this-mac", label: "This Mac" }],
  files,
  spaces: [
    { id: "comma-system-files", name: "", remote: true },
    { id: "space-a", name: "A" },
  ],
  originDeviceId: "this-mac",
  versionPolicy: "newest",
  localSyncEnabled: false,
  localSyncRoot: "/Users/me/Drive",
  syncHistory: [],
  transfers: [],
});

function storeOf(value = drive()) {
  const store = new DriveStore();
  store.setCore(value);
  return store;
}

describe("DriveStore", () => {
  it("shows a device's space first, and keeps a picked space while the core has it", () => {
    const store = storeOf();
    expect(store.getSnapshot().selectedSpaceId).toBe("space-a");
    // The core leaves System Files unnamed; the reader sees its name.
    expect(store.getSnapshot().spaces[0]!.name).toBe("System Files");
    store.selectSpace("comma-system-files");
    store.setCore(drive([]));
    expect(store.getSnapshot().selectedSpaceId).toBe("comma-system-files");
    store.selectSpace("space-gone");
    expect(store.getSnapshot().selectedSpaceId).toBe("space-a");
  });

  it("keeps untouched snapshot slices identity-stable across commits", () => {
    const store = storeOf();
    const before = store.getSnapshot();

    store.selectSpace("comma-system-files");

    const after = store.getSnapshot();
    expect(after).not.toBe(before);
    expect(after.spaces).toBe(before.spaces);
  });

  it("keeps read bytes with the content they were read for", () => {
    const store = storeOf();
    store.attachBlob(remote, new Blob(["old"]));
    store.attachThumbnail(remote, new Blob(["old thumbnail"]));
    expect(store.fileById("file-remote")?.blob).toBeDefined();

    // The core lists new content: what was read before does not go with it.
    store.setCore(drive([{ ...remote, contentsHash: "replacement-root" }]));
    expect(store.fileById("file-remote")?.blob).toBeUndefined();
    expect(store.fileById("file-remote")?.thumbnail).toBeUndefined();

    // A read of the old content that lands late is not taken for the new one.
    store.attachBlob(remote, new Blob(["stale"]));
    expect(store.fileById("file-remote")?.blob).toBeUndefined();
  });
});

const sortableFile = (overrides: Partial<DriveFile> & { name: string }): DriveFile => ({
  contentsHash: "f00",
  deviceId: "this-mac",
  id: overrides.name,
  modifiedAt: 0,
  sizeBytes: 0,
  spaceId: "space-a",
  ...overrides,
});

const names = (sorted: readonly DriveFile[]) => sorted.map((entry) => entry.name);

describe("splitDriveFileName", () => {
  it("keeps the last twelve characters out of the shrinking half", () => {
    // Finder's cut: "Screenshot 20…at 10.47.png" once the row runs out of room.
    expect(splitDriveFileName("Screenshot 2026-08-29 at 10.47.png")).toEqual({
      head: "Screenshot 2026-08-29 ",
      tail: "at 10.47.png",
    });
    expect(splitDriveFileName("launch-cut-v3-final-render.mp4")).toEqual({
      head: "launch-cut-v3-fina",
      tail: "l-render.mp4",
    });
  });

  it("never keeps more than half of a short name, but always its extension", () => {
    expect(splitDriveFileName("session-take-2.wav")).toEqual({
      head: "session-t",
      tail: "ake-2.wav",
    });
    expect(splitDriveFileName("README")).toEqual({ head: "REA", tail: "DME" });
    // A long extension outranks the half rule so the type always survives.
    expect(splitDriveFileName("a.properties")).toEqual({
      head: "a",
      tail: ".properties",
    });
  });

  it("reads a dotfile or a trailing dot as no extension at all", () => {
    expect(splitDriveFileName(".gitignore")).toEqual({ head: ".giti", tail: "gnore" });
    expect(splitDriveFileName("archive.")).toEqual({ head: "arch", tail: "ive." });
  });
});

describe("drive file helpers", () => {
  it("labels and classifies files by extension and mime", () => {
    expect(driveFileTypeLabel("sound.wav")).toBe("WAV");
    expect(driveFileTypeLabel("no-extension")).toBe("File");
    expect(driveFileKind({ name: "clip.mp4" })).toBe("video");
    expect(driveFileKind({ name: "notes.txt" })).toBe("text");
    expect(driveFileKind({ name: "deck.pdf" })).toBe("document");
    expect(
      driveFileKind({
        blob: new Blob([], { type: "audio/wav" }),
        name: "renamed.bin",
      })
    ).toBe("audio");
  });

  it("formats sizes with a spaced unit like the design", () => {
    expect(formatDriveFileSize(2_306_867)).toBe("2.2 MB");
    expect(formatDriveFileSize(23_552)).toBe("23 KB");
    expect(formatDriveFileSize(0)).toBe("0 B");
  });

  it("sorts by each header column and reverses on demand", () => {
    const files = [
      sortableFile({
        name: "take 10.wav",
        modifiedAt: 30,
        sizeBytes: 300,
        versions: twoVersions("s1"),
      }),
      sortableFile({
        name: "take 2.wav",
        modifiedAt: 10,
        sizeBytes: 100,
        versions: fiveVersions("s2"),
      }),
      sortableFile({ name: "Alpha.png", modifiedAt: 20, sizeBytes: 200 }),
    ];

    // Natural ordering keeps "take 2" ahead of "take 10".
    expect(names(sortDriveFiles(files, { column: "name", direction: "asc" }))).toEqual([
      "Alpha.png",
      "take 2.wav",
      "take 10.wav",
    ]);
    expect(
      names(sortDriveFiles(files, { column: "versions", direction: "desc" }))
    ).toEqual(["take 2.wav", "take 10.wav", "Alpha.png"]);
    expect(names(sortDriveFiles(files, { column: "size", direction: "asc" }))).toEqual([
      "take 2.wav",
      "Alpha.png",
      "take 10.wav",
    ]);
    expect(
      names(sortDriveFiles(files, { column: "modified", direction: "desc" }))
    ).toEqual(["take 10.wav", "Alpha.png", "take 2.wav"]);
    expect(files.map((entry) => entry.name)).toEqual([
      "take 10.wav",
      "take 2.wav",
      "Alpha.png",
    ]);
  });
});

describe("driveUploadMimeType", () => {
  it("fills a missing picker type from the extension for the image kinds the preview draws", () => {
    // A blob URL decodes by type alone; an untyped .svg would never render.
    expect(driveUploadMimeType("logo.svg", "")).toBe("image/svg+xml");
    expect(driveUploadMimeType("photo.JPG", "")).toBe("image/jpeg");
    // The picker's own type always wins, and non-image files stay untyped.
    expect(driveUploadMimeType("logo.svg", "text/plain")).toBe("text/plain");
    expect(driveUploadMimeType("notes.txt", "")).toBe("");
  });
});
