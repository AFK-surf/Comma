import { describe, expect, it } from "vitest";
import { splitDriveFileName } from "../DriveFileName";
import {
  DriveStore,
  driveFileKind,
  driveFileTypeLabel,
  driveUploadMimeType,
  formatDriveFileSize,
  driveVersionCount,
  sortDriveFiles,
  type DriveFile,
  type DriveFileVersion,
  type DriveSeedData,
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

const seed = (): DriveSeedData => ({
  devices: [
    { current: true, id: "this-mac", label: "This Mac" },
    { current: false, id: "nas", label: "NAS" },
  ],
  files: [
    {
      contentsHash: "f00",
      deviceId: "nas",
      id: "file-remote",
      modifiedAt: 1,
      name: "remote.pdf",
      sizeBytes: 10,
      spaceId: "space-a",
      versions: twoVersions("file-remote"),
    },
  ],
  spaces: [
    { id: "space-a", name: "A" },
    { id: "space-b", name: "B" },
  ],
});

describe("DriveStore", () => {
  it("keeps untouched snapshot slices identity-stable across commits", () => {
    const store = new DriveStore(seed());
    const before = store.getSnapshot();

    store.beginTransfer({
      detail: "PDF",
      direction: "download",
      fileId: "file-remote",
      fileName: "remote.pdf",
    });

    const after = store.getSnapshot();
    expect(after).not.toBe(before);
    expect(after.transfers).not.toBe(before.transfers);
    expect(after.files).toBe(before.files);
    expect(after.spaces).toBe(before.spaces);
  });

  it("walks a transfer through failure, retry, and completion keeping its target", () => {
    const store = new DriveStore(seed());
    const transfer = store.beginTransfer({
      detail: "TXT",
      direction: "upload",
      fileName: "notes.txt",
      spaceId: "space-b",
    });

    store.failTransfer(transfer.id, "Could not read the file");
    expect(store.transferById(transfer.id)).toMatchObject({
      errorMessage: "Could not read the file",
      spaceId: "space-b",
      status: "error",
    });

    store.restartTransfer(transfer.id);
    const restarted = store.transferById(transfer.id);
    expect(restarted?.status).toBe("in_progress");
    expect(restarted?.errorMessage).toBeUndefined();
    expect(restarted?.spaceId).toBe("space-b");

    store.completeTransfer(transfer.id, { fileId: "file-new" });
    expect(store.transferById(transfer.id)).toMatchObject({
      fileId: "file-new",
      spaceId: "space-b",
      status: "success",
    });
  });

  it("resolves the freshest saved download handle per file", () => {
    const store = new DriveStore(seed());
    const first = store.beginTransfer({
      detail: "PDF",
      direction: "download",
      fileId: "file-remote",
      fileName: "remote.pdf",
    });
    store.completeTransfer(first.id, { downloadRef: "dnl1_old" });

    const second = store.beginTransfer({
      detail: "PDF",
      direction: "download",
      fileId: "file-remote",
      fileName: "remote.pdf",
    });
    expect(store.latestDownloadRef("file-remote")).toBe("dnl1_old");

    store.completeTransfer(second.id, { downloadRef: "dnl1_new" });
    expect(store.latestDownloadRef("file-remote")).toBe("dnl1_new");
  });

  it("preserves an available device selection across backend refreshes", () => {
    const store = new DriveStore(seed());
    store.setOriginDevice("nas");

    store.load({
      ...seed(),
      originDeviceId: "this-mac",
    });

    expect(store.getSnapshot().originDeviceId).toBe("nas");

    store.load({
      devices: [{ current: true, id: "this-mac", label: "This Mac" }],
      files: [],
      originDeviceId: "this-mac",
      spaces: seed().spaces,
    });
    expect(store.getSnapshot().originDeviceId).toBe("this-mac");
  });

  it("ignores content-derived results fetched for a superseded object", () => {
    const store = new DriveStore(seed());
    const previousHash = store.fileById("file-remote")!.contentsHash;
    const { versions: _versions, ...current } = store.fileById("file-remote")!;
    const replacement = {
      ...current,
      contentsHash: "replacement-root",
    };
    store.load({
      devices: seed().devices,
      files: [replacement],
      originDeviceId: "this-mac",
      spaces: seed().spaces,
    });

    store.attachBlob("file-remote", new Blob(["stale"]), previousHash);
    store.attachThumbnail("file-remote", new Blob(["stale thumbnail"]), previousHash);
    store.setFileVersions("file-remote", twoVersions("file-remote"), previousHash);

    expect(store.fileById("file-remote")).toMatchObject({
      contentsHash: "replacement-root",
    });
    expect(store.fileById("file-remote")?.blob).toBeUndefined();
    expect(store.fileById("file-remote")?.thumbnail).toBeUndefined();
    expect(store.fileById("file-remote")?.versions).toBeUndefined();
  });

  it("adds uploaded bytes as files and removes them with their space", () => {
    const store = new DriveStore(seed());
    const blob = new Blob(["hello"], { type: "text/plain" });
    const file = store.addFile({
      blob,
      deviceId: "this-mac",
      name: "hello.txt",
      spaceId: "space-a",
    });

    expect(store.fileById(file.id)).toMatchObject({
      name: "hello.txt",
      sizeBytes: 5,
      spaceId: "space-a",
    });

    store.selectSpace("space-a");
    store.removeSpace("space-a");
    const snapshot = store.getSnapshot();
    expect(snapshot.spaces.map((space) => space.id)).toEqual(["space-b"]);
    expect(snapshot.selectedSpaceId).toBe("space-b");
    expect(snapshot.files).toHaveLength(0);
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

describe("DriveStore.dismissFinishedTransfers", () => {
  it("drops finished rows and their retry sources but keeps what is still moving", () => {
    const store = new DriveStore(seed());
    const done = store.beginTransfer({
      detail: "PNG",
      direction: "download",
      fileName: "a.png",
    });
    store.completeTransfer(done.id, { downloadRef: "ref-a" });
    const failed = store.beginTransfer({
      detail: "TXT",
      direction: "upload",
      fileName: "b.txt",
      uploadSource: new File(["b"], "b.txt"),
    });
    store.failTransfer(failed.id, "boom");
    const moving = store.beginTransfer({
      detail: "WAV",
      direction: "upload",
      fileName: "c.wav",
      uploadSource: new File(["c"], "c.wav"),
    });

    store.dismissFinishedTransfers();

    expect(store.getSnapshot().transfers.map((transfer) => transfer.id)).toEqual([
      moving.id,
    ]);
    expect(store.uploadSource(failed.id)).toBeUndefined();
    expect(store.uploadSource(moving.id)).toBeDefined();
    // The row that was still moving lands normally afterwards.
    store.completeTransfer(moving.id);
    expect(store.transferById(moving.id)?.status).toBe("success");
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

describe("DriveStore adoption (import from cluster)", () => {
  it("plans a dry run from what this device holds, then writes only what is missing", () => {
    const store = new DriveStore(seed());
    // remote.pdf lives on the NAS only; nothing here is current or differing.
    expect(store.planAdoption({ kind: "space", spaceId: "space-a" })).toMatchObject({
      adopt: 1,
      current: 0,
      differing: 0,
      entries: [{ file: { id: "file-remote" }, status: "adopt" }],
      skipped: 0,
    });

    const written = store.adopt(
      { kind: "space", spaceId: "space-a" },
      { replace: false }
    );
    expect(written.map((file) => file.id)).toEqual(["file-remote"]);
    const adopted = store.fileById("file-remote");
    expect(adopted?.blob).toBeDefined();
    expect(adopted?.deviceId).toBe("this-mac");
    // Additive: the file count never goes down; what was written now holds
    // the selected version, so a second run finds nothing to do.
    expect(store.getSnapshot().files).toHaveLength(1);
    expect(driveVersionCount(adopted!)).toBe(1);
    expect(store.planAdoption({ kind: "space", spaceId: "space-a" })).toMatchObject({
      adopt: 0,
      current: 1,
      differing: 0,
      entries: [{ status: "current" }],
      skipped: 0,
    });
    expect(
      store.adopt({ kind: "space", spaceId: "space-a" }, { replace: false })
    ).toEqual([]);
  });

  it("settles a diverged path on the copy the reader picked", () => {
    const store = new DriveStore(seed());
    const before = store.fileById("file-remote")!;
    expect(driveVersionCount(before)).toBe(2);
    const older = before.versions![1]!;

    const settled = store.resolveFileVersion("file-remote", older.id);
    expect(settled).toMatchObject({
      contentsHash: older.contentsHash,
      deviceId: older.deviceId,
      modifiedAt: older.modifiedAt,
      sizeBytes: older.sizeBytes,
    });
    // One copy left, so the path is the same everywhere and there is nothing
    // more to choose between.
    expect(driveVersionCount(store.fileById("file-remote")!)).toBe(1);
    expect(store.resolveFileVersion("file-remote", older.id)).toBeUndefined();
  });

  it("drops cached bytes and thumbnails before loading the selected version", () => {
    const store = new DriveStore(seed());
    const cached = new Blob(["newest bytes"], { type: "text/plain" });
    const thumbnail = new Blob(["thumbnail"], { type: "image/png" });
    store.attachBlob("file-remote", cached);
    store.attachThumbnail("file-remote", thumbnail);
    const older = store.fileById("file-remote")!.versions![1]!;

    const settled = store.resolveFileVersion("file-remote", older.id);
    expect(settled?.blob).toBeUndefined();
    expect(settled?.thumbnail).toBeUndefined();

    // A node refresh now reports the selected hash. The old cache must not be
    // reattached merely because that hash matches the optimistic settlement.
    store.load({
      devices: seed().devices,
      files: [
        {
          contentsHash: older.contentsHash,
          deviceId: older.deviceId,
          id: "file-remote",
          modifiedAt: older.modifiedAt,
          name: "remote.pdf",
          sizeBytes: older.sizeBytes,
          spaceId: "space-a",
        },
      ],
      originDeviceId: "this-mac",
      spaces: seed().spaces,
    });
    expect(store.fileById("file-remote")?.blob).toBeUndefined();
    expect(store.fileById("file-remote")?.thumbnail).toBeUndefined();
  });

  it("removes a path when the selected version is a tombstone", () => {
    const store = new DriveStore(seed());
    const current = store.fileById("file-remote")!;
    const deleted: DriveFileVersion = {
      contentsHash: "",
      deleted: true,
      deviceId: "nas",
      id: `${current.id}-deleted`,
      modifiedAt: 101,
      sizeBytes: 0,
    };
    store.setFileVersions(current.id, [current.versions![0]!, deleted]);

    const settled = store.resolveFileVersion(current.id, deleted.id);

    expect(settled?.name).toBe("remote.pdf");
    expect(store.fileById(current.id)).toBeUndefined();
  });

  it("leaves differing files alone unless asked to replace them", () => {
    const store = new DriveStore(seed());
    // A local copy that forked from the cluster: bytes here, several versions.
    const forked = store.addFile({
      blob: new Blob(["mine"], { type: "text/plain" }),
      deviceId: "this-mac",
      name: "notes.txt",
      spaceId: "space-b",
    });
    store.getSnapshot().files.find((file) => file.id === forked.id)!.versions =
      versionsOf(forked.id, 3);

    expect(store.planAdoption({ kind: "file", fileId: forked.id })).toMatchObject({
      differing: 1,
    });
    expect(
      store.adopt({ kind: "file", fileId: forked.id }, { replace: false })
    ).toEqual([]);
    const replaced = store.adopt(
      { kind: "file", fileId: forked.id },
      { replace: true }
    );
    expect(replaced.map((file) => driveVersionCount(file))).toEqual([1]);
    expect(store.planAdoption({ kind: "file", fileId: forked.id })).toMatchObject({
      current: 1,
      differing: 0,
    });
  });
});

describe("DriveStore spaces and local sync", () => {
  it("creates a synced space under the local root and renames its folder with it", () => {
    const store = new DriveStore(seed());
    const created = store.addSpace("Photos");
    expect(created).toMatchObject({
      name: "Photos",
      originPath: "~/Drive/Photos",
      synced: true,
    });

    const renamed = store.renameSpace(created.id, "Pictures");
    expect(renamed?.originPath).toBe("~/Drive/Pictures");
    // The app's name wins over the disk's: the rename is a sync event.
    expect(store.getSnapshot().syncHistory[0]).toMatchObject({
      kind: "folder",
      name: "Pictures",
      operation: "updated",
    });

    // An unsynced space renames without touching sync history.
    const before = store.getSnapshot().syncHistory.length;
    store.renameSpace("space-b", "B2");
    expect(store.getSnapshot().syncHistory).toHaveLength(before);
  });

  it("switching a space's sync on copies what the cluster has, off leaves it", () => {
    const store = new DriveStore(seed());
    const on = store.setSpaceSynced("space-a", true);
    expect(on?.space.synced).toBe(true);
    expect(on?.copied).toBe(1);
    expect(store.fileById("file-remote")?.blob).toBeDefined();
    // Newest first, so the files sit above the folder line that brought them.
    expect(store.getSnapshot().syncHistory.slice(0, 2)).toMatchObject([
      { direction: "download", kind: "file", operation: "added", status: "success" },
      { kind: "folder", name: "A", operation: "added", status: "success" },
    ]);

    const off = store.setSpaceSynced("space-a", false);
    expect(off?.space.synced).toBe(false);
    expect(store.getSnapshot().syncHistory[0]).toMatchObject({
      kind: "folder",
      name: "A",
      operation: "removed",
    });
    expect(store.fileById("file-remote")?.blob).toBeDefined();
    expect(store.setSpaceSynced("space-a", false)).toBeUndefined();
  });

  it("records a file the cluster disagrees about as a failure, and settles it on retry", () => {
    const store = new DriveStore(seed());
    // A local copy that forked from the cluster's: sync must not overwrite it.
    const forked = store.addFile({
      blob: new Blob(["mine"], { type: "text/plain" }),
      deviceId: "this-mac",
      name: "notes.txt",
      spaceId: "space-b",
    });
    store.getSnapshot().files.find((file) => file.id === forked.id)!.versions =
      versionsOf(forked.id, 3);

    store.setSpaceSynced("space-b", true);
    const failed = store
      .getSnapshot()
      .syncHistory.find((entry) => entry.status === "failed");
    expect(failed).toMatchObject({
      fileId: forked.id,
      kind: "file",
      name: "notes.txt",
      operation: "updated",
    });
    expect(failed?.resolved).toBeUndefined();

    expect(store.retryFailedSync()).toBe(1);
    expect(driveVersionCount(store.fileById(forked.id)!)).toBe(1);
    const history = store.getSnapshot().syncHistory;
    expect(history[0]).toMatchObject({
      name: "notes.txt",
      operation: "updated",
      status: "success",
    });
    expect(history.find((entry) => entry.id === failed?.id)?.resolved).toBe(true);
    // Nothing is open any more, so a second retry is a no-op.
    expect(store.retryFailedSync()).toBe(0);
  });

  it("the device switch takes the picker's set and remembers it when turned off", () => {
    const store = new DriveStore(seed());
    store.setLocalSyncEnabled(true, new Set(["space-b"]));
    const spaces = store.getSnapshot().spaces;
    expect(spaces.find((space) => space.id === "space-a")?.synced ?? false).toBe(false);
    expect(spaces.find((space) => space.id === "space-b")?.synced).toBe(true);
    expect(store.getSnapshot().localSyncEnabled).toBe(true);

    store.setLocalSyncEnabled(false);
    expect(store.getSnapshot().localSyncEnabled).toBe(false);
    expect(
      store.getSnapshot().spaces.find((space) => space.id === "space-b")?.synced
    ).toBe(true);
    expect(store.spaceSizeBytes("space-a")).toBe(10);
  });

  it("keeps a folder path on files uploaded into a folder", () => {
    const store = new DriveStore(seed());
    const file = store.addFile({
      blob: new Blob(["x"]),
      deviceId: "this-mac",
      folderPath: "photos/2026",
      name: "a.txt",
      spaceId: "space-a",
    });
    expect(file.folderPath).toBe("photos/2026");
  });
});
