import { driveSynchronicityAvailable } from "./driveSynchronicityBackend";
import { useSyncExternalStore } from "react";

/**
 * Client-side Drive state.
 *
 * The Electron client fills the store from the synchronicity node bundled
 * with the app (`driveSynchronicityBackend`): spaces, files and devices are
 * the node's unified tree, bytes are fetched when a preview or a download
 * asks, and uploads and deletions go through the node before the store
 * reflects them. Everywhere else — the web build, the e2e harness — there is
 * no node, and the store runs on demo data: uploads keep their real bytes
 * (previews and downloads round-trip them through the same `files.*`
 * capability as every other download), while fixture rows model files that
 * other devices in the cluster have published but this Mac has not synced.
 */

export type DriveVersionPolicy = "newest" | "strict";

export interface DriveDevice {
  current: boolean;
  id: string;
  label: string;
}

export interface DriveSpace {
  id: string;
  name: string;
  /** False when this node only retains/replicates the space and has no source. */
  writable?: boolean;
  /**
   * Where this device publishes the space from, when it is the origin. A space
   * this device only replicates has none; stopping sharing then only drops
   * the replica.
   */
  originPath?: string;
  /**
   * Whether this device keeps a local copy of the space in sync (the folder
   * is chosen in the local-sync picker, or switched on from its own menu).
   * An unsynced space is still browsable; it just has no bytes here until
   * something fetches them.
   */
  synced?: boolean;
  /**
   * The install's own published folder: this device is its source, so it is
   * always mirrored here and never offered for deletion. Removing it would
   * be stopping publication, which is a different act than deleting files.
   */
  protected?: boolean;
}

/** The slices a backend fills in; everything else stays the store's own. */
export interface DriveLoadedSnapshot {
  devices: readonly DriveDevice[];
  files: readonly DriveFile[];
  /** Whether any space besides the install's own is mirrored here; absent leaves the switch alone. */
  localSyncEnabled?: boolean;
  /** The install's own folder on disk; absent keeps the store's default. */
  localSyncRoot?: string;
  originDeviceId: string;
  spaces: readonly DriveSpace[];
}

/**
 * The node behind the store, as the list needs to know it: nothing to show
 * while it starts, and a reason (with a way to try again) when it could
 * not. `off` is the demo store, with no node at all.
 */
export interface DriveNodeStatus {
  reason?: string;
  status: "off" | "starting" | "ready" | "error";
}

/**
 * One copy of a path in the cluster. A path has several when two devices
 * changed it before they could reach each other; none of them is wrong, which
 * is why every copy is kept until someone says which one to settle on.
 */
export interface DriveFileVersion {
  contentsHash: string;
  /** This copy is a deletion: the device removed the path and published that. */
  deleted?: boolean;
  deviceId: string;
  id: string;
  modifiedAt: number;
  sizeBytes: number;
}

export interface DriveFile {
  /** Present once the bytes are materialized on this device (e.g. uploaded here). */
  blob?: Blob;
  /**
   * A small image of the file for the list, made from its bytes without
   * keeping them: the whole file is fetched only when a preview or a
   * download asks. An image whose bytes are here draws from those instead.
   */
  thumbnail?: Blob;
  contentsHash: string;
  deviceId: string;
  id: string;
  /**
   * Pinned: this device keeps the bytes regardless of use (Synchronicity's
   * retention pin), so the file opens with no network. Pinning an unsynced
   * file fetches it first.
   */
  keepOffline?: boolean;
  /** Directory inside the space, "a/b" for a file at <space>/a/b/<name>; unset at the root. */
  folderPath?: string;
  modifiedAt: number;
  name: string;
  sizeBytes: number;
  spaceId: string;
  /**
   * Every copy of this path across the cluster, newest first, present only
   * when the copies disagree. The file's own fields mirror the head of the
   * list: the default `newest` policy is what picks the copy shown here.
   */
  versions?: readonly DriveFileVersion[];
  /**
   * How many copies a listing reported before the copies themselves were
   * fetched; `versions` supersedes it once the panel has asked.
   */
  versionCount?: number;
}

/**
 * Settles a path on one of its copies: that copy's bytes, size, device and
 * time become the file's, and the rest are dropped. This is Synchronicity's
 * `--select` made a deliberate act rather than a policy default.
 */
function settleOnVersion(
  file: DriveFile,
  version: DriveFileVersion | undefined
): DriveFile {
  const {
    blob: _blob,
    thumbnail: _thumbnail,
    versionCount: _count,
    versions: _dropped,
    ...rest
  } = file;
  if (!version) return { ...rest, modifiedAt: Date.now() };
  return {
    ...rest,
    contentsHash: version.contentsHash,
    deviceId: version.deviceId,
    modifiedAt: version.modifiedAt,
    sizeBytes: version.sizeBytes,
  };
}

/** How many copies of a path the cluster holds; one unless devices disagree. */
export const driveVersionCount = (file: DriveFile) =>
  file.versions?.length ?? file.versionCount ?? 1;

/** What an adoption is aimed at: a whole space (`adopt tree`) or one file (`adopt path`). */
export type DriveAdoptionTarget =
  | { kind: "space"; spaceId: string }
  | { kind: "file"; fileId: string };

/**
 * What a dry run decided for one path: copy it here (`adopt`), leave it
 * because it already matches (`current`), leave it because it differs here
 * (`differing`, unless replaced), or cannot write it here at all (`skipped`).
 */
export type DriveAdoptionStatus = "adopt" | "current" | "differing" | "skipped";

export interface DriveAdoptionEntry {
  file: DriveFile;
  status: DriveAdoptionStatus;
}

/** A dry run: every path with its verdict, plus the four counters; see `DriveStore.planAdoption`. */
export interface DriveAdoptionPlan {
  adopt: number;
  current: number;
  differing: number;
  entries: DriveAdoptionEntry[];
  skipped: number;
}

/** What local sync did to one path: wrote it, refreshed it, or stopped keeping it. */
export type DriveSyncOperation = "added" | "removed" | "updated";

/**
 * One line of sync history: a single file or folder, what happened to it,
 * which way it moved, and whether it landed. The history panel is a table of
 * these, so every row is a path a user can recognise rather than a summary.
 */
export interface DriveSyncHistoryEntry {
  at: number;
  /** `download` is cluster → this Mac; `upload` is this Mac → cluster. */
  direction: DriveTransferDirection;
  /** Present on a failed entry: why it could not be written. */
  errorMessage?: string;
  /** What a failed entry points at, so a retry knows which path to redo. */
  fileId?: string;
  id: string;
  kind: "file" | "folder";
  name: string;
  operation: DriveSyncOperation;
  /** A failure the user has since retried; it leaves the failures tab. */
  resolved?: boolean;
  /** Absent for folders, which have no size of their own. */
  sizeBytes?: number;
  status: "failed" | "success";
}

export type DriveTransferDirection = "download" | "upload";
export type DriveTransferStatus = "error" | "in_progress" | "success";

export interface DriveTransfer {
  detail: string;
  direction: DriveTransferDirection;
  downloadRef?: string;
  errorMessage?: string;
  fileId?: string;
  fileName: string;
  id: string;
  /** Upload target, so a retry lands in the space the upload was aimed at. */
  spaceId?: string;
  status: DriveTransferStatus;
}

export interface DriveSnapshot {
  devices: readonly DriveDevice[];
  files: readonly DriveFile[];
  originDeviceId: string;
  selectedSpaceId: string;
  spaces: readonly DriveSpace[];
  transfers: readonly DriveTransfer[];
  /** The device-wide local sync switch; off means no space is mirrored on disk. */
  localSyncEnabled: boolean;
  /** Where synced spaces live on this device. */
  localSyncRoot: string;
  /** What local sync has done here, newest first; the sync history panel reads it. */
  syncHistory: readonly DriveSyncHistoryEntry[];
  node: DriveNodeStatus;
  versionPolicy: DriveVersionPolicy;
}

export interface DriveSeedData {
  devices: readonly DriveDevice[];
  files: readonly DriveFile[];
  spaces: readonly DriveSpace[];
}

export class DriveStore {
  #listeners = new Set<() => void>();
  #snapshot: DriveSnapshot;
  #transferSeq = 0;
  #fileSeq = 0;
  #spaceSeq = 0;
  #syncSeq = 0;
  /** Retry sources live outside the snapshot: a File handle is not render data. */
  #uploadSources = new Map<string, File>();

  constructor(seed: DriveSeedData) {
    const currentDevice = seed.devices.find((device) => device.current);
    this.#snapshot = {
      devices: seed.devices,
      files: seed.files,
      originDeviceId: currentDevice?.id ?? seed.devices[0]?.id ?? "",
      selectedSpaceId: seed.spaces[0]?.id ?? "",
      spaces: seed.spaces,
      transfers: [],
      localSyncEnabled: false,
      localSyncRoot: "~/Drive",
      node: { status: "off" },
      syncHistory: [],
      versionPolicy: "newest",
    };
  }

  subscribe = (listener: () => void) => {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  };

  getSnapshot = (): DriveSnapshot => this.#snapshot;

  /**
   * Replaces what a backend owns — spaces, files, devices — and keeps the
   * selection on a space that still exists. Local-only state (transfers,
   * the sync switch, history) is untouched: a reload is not a reset.
   */
  load(loaded: DriveLoadedSnapshot, filesAtStart?: readonly DriveFile[]) {
    const selectedSpaceId = loaded.spaces.some(
      (space) => space.id === this.#snapshot.selectedSpaceId
    )
      ? this.#snapshot.selectedSpaceId
      : (loaded.spaces[0]?.id ?? "");
    // What this device knows about a file beyond the listing — bytes already
    // fetched for a preview, the offline pin — survives a reload of it.
    const known = new Map(this.#snapshot.files.map((file) => [file.id, file] as const));
    // A recording can be committed and revealed while an older list is in
    // flight. Only additions after that read began survive its stale omission;
    // the next authoritative read may delete them normally. This uses the
    // already loaded collection and adds no polling, RPC, or persistent cache.
    const initialIds = new Set(filesAtStart?.map((file) => file.id));
    const loadedIds = new Set(loaded.files.map((file) => file.id));
    const addedDuringLoad = filesAtStart
      ? this.#snapshot.files.filter(
          (file) => !initialIds.has(file.id) && !loadedIds.has(file.id)
        )
      : [];
    this.#commit({
      devices: loaded.devices,
      files: [...loaded.files, ...addedDuringLoad].map((file) => {
        const previous = known.get(file.id);
        // Bytes and thumbnails describe one content; a path another device
        // rewrote since is a different file and reads fresh.
        if (!previous || previous.contentsHash !== file.contentsHash) return file;
        return {
          ...file,
          ...(previous.blob && !file.blob ? { blob: previous.blob } : {}),
          ...(previous.thumbnail ? { thumbnail: previous.thumbnail } : {}),
        };
      }),
      ...(loaded.localSyncEnabled === undefined
        ? {}
        : { localSyncEnabled: loaded.localSyncEnabled }),
      ...(loaded.localSyncRoot === undefined
        ? {}
        : { localSyncRoot: loaded.localSyncRoot }),
      originDeviceId:
        this.#snapshot.devices.some(
          (device) => device.id === this.#snapshot.originDeviceId && !device.current
        ) &&
        loaded.devices.some((device) => device.id === this.#snapshot.originDeviceId)
          ? this.#snapshot.originDeviceId
          : loaded.originDeviceId,
      selectedSpaceId,
      spaces: loaded.spaces,
    });
  }

  /** What the node reports about itself; the list shows it while there is nothing else to show. */
  setNodeStatus(node: DriveNodeStatus) {
    const current = this.#snapshot.node;
    if (current.status === node.status && current.reason === node.reason) return;
    this.#commit({ node });
  }

  /** Lines a backend's sync wrote, newest first, on top of the history. */
  recordSyncHistory(entries: readonly Omit<DriveSyncHistoryEntry, "at" | "id">[]) {
    if (entries.length === 0) return;
    this.#commit({ syncHistory: this.#recordSync(entries) });
  }

  /** Marks failures a retry has settled; they leave the failures tab and stay in the log. */
  markSyncResolved(entryIds: ReadonlySet<string>) {
    if (entryIds.size === 0) return;
    this.#commit({
      syncHistory: this.#snapshot.syncHistory.map((entry) =>
        entryIds.has(entry.id) ? { ...entry, resolved: true } : entry
      ),
    });
  }

  /** The list's small image of a file, made by a backend from its bytes. */
  attachThumbnail(fileId: string, thumbnail: Blob, expectedContentsHash?: string) {
    this.#commit({
      files: this.#snapshot.files.map((file) =>
        file.id === fileId &&
        (expectedContentsHash === undefined ||
          file.contentsHash === expectedContentsHash)
          ? { ...file, thumbnail }
          : file
      ),
    });
  }

  /** Bytes a backend fetched on demand, so the preview and download paths see them. */
  attachBlob(fileId: string, blob: Blob, expectedContentsHash?: string) {
    this.#commit({
      files: this.#snapshot.files.map((file) =>
        file.id === fileId &&
        (expectedContentsHash === undefined ||
          file.contentsHash === expectedContentsHash)
          ? { ...file, blob }
          : file
      ),
    });
  }

  /** The copies a backend reported for a path, once the panel asked for them. */
  setFileVersions(
    fileId: string,
    versions: readonly DriveFileVersion[],
    expectedContentsHash?: string
  ) {
    this.#commit({
      files: this.#snapshot.files.map((file) =>
        file.id === fileId &&
        (expectedContentsHash === undefined ||
          file.contentsHash === expectedContentsHash)
          ? versions.length > 1
            ? { ...file, versions }
            : (({ versionCount: _count, versions: _dropped, ...rest }) => rest)(file)
          : file
      ),
    });
  }

  selectSpace(spaceId: string) {
    if (this.#snapshot.selectedSpaceId === spaceId) return;
    this.#commit({ selectedSpaceId: spaceId });
  }

  /** Incorporates the single file a reveal looked up without reloading the tree. */
  revealFile({
    device,
    file,
    space,
  }: {
    device: DriveDevice;
    file: DriveFile;
    space: DriveSpace;
  }) {
    this.#commit({
      devices: [
        ...this.#snapshot.devices.filter((entry) => entry.id !== device.id),
        device,
      ],
      files: [...this.#snapshot.files.filter((entry) => entry.id !== file.id), file],
      originDeviceId: device.id,
      selectedSpaceId: space.id,
      spaces: this.#snapshot.spaces.some((entry) => entry.id === space.id)
        ? this.#snapshot.spaces.map((entry) => (entry.id === space.id ? space : entry))
        : [...this.#snapshot.spaces, space],
    });
  }

  setVersionPolicy(versionPolicy: DriveVersionPolicy) {
    if (this.#snapshot.versionPolicy === versionPolicy) return;
    this.#commit({ versionPolicy });
  }

  setOriginDevice(originDeviceId: string) {
    if (this.#snapshot.originDeviceId === originDeviceId) return;
    this.#commit({ originDeviceId });
  }

  fileById(fileId: string): DriveFile | undefined {
    return this.#snapshot.files.find((file) => file.id === fileId);
  }

  addFile(input: {
    blob: Blob;
    deviceId: string;
    folderPath?: string;
    name: string;
    spaceId: string;
  }): DriveFile {
    this.#fileSeq += 1;
    const file: DriveFile = {
      blob: input.blob,
      contentsHash: driveContentsHash(input.name, input.blob.size, this.#fileSeq),
      deviceId: input.deviceId,
      id: `drive-file-local-${this.#fileSeq}`,
      modifiedAt: Date.now(),
      name: input.name,
      sizeBytes: input.blob.size,
      spaceId: input.spaceId,
      ...(input.folderPath ? { folderPath: input.folderPath } : {}),
    };
    this.#commit({ files: [file, ...this.#snapshot.files] });
    return file;
  }

  /**
   * A complete dry run of `synch adopt tree` / `synch adopt path` against
   * what this device holds — the engine's own report shape (DESIGN.md §7.2):
   * `adopt` is what a run would write, `current` what already matches,
   * `differing` what has a local copy with other bytes and is left alone
   * unless replaced, `skipped` what cannot be written here at all.
   */
  planAdoption(target: DriveAdoptionTarget): DriveAdoptionPlan {
    const plan: DriveAdoptionPlan = {
      adopt: 0,
      current: 0,
      differing: 0,
      entries: [],
      skipped: 0,
    };
    for (const file of this.#adoptionCandidates(target)) {
      const status: DriveAdoptionStatus =
        file.blob === undefined
          ? "adopt"
          : driveVersionCount(file) > 1
            ? "differing"
            : "current";
      plan[status] += 1;
      plan.entries.push({ file, status });
    }
    return plan;
  }

  /**
   * Runs the adoption the plan described: every file the cluster has for the
   * target lands on this device, files already current are untouched, and
   * differing ones are replaced only when asked. Additive by construction —
   * nothing is ever removed. Returns the files it wrote.
   */
  adopt(target: DriveAdoptionTarget, options: { replace: boolean }): DriveFile[] {
    const currentDeviceId =
      this.#snapshot.devices.find((device) => device.current)?.id ??
      this.#snapshot.originDeviceId;
    const written: DriveFile[] = [];
    const files = this.#snapshot.files.map((file) => {
      if (!this.#adoptionCandidates(target).includes(file)) return file;
      if (file.blob === undefined) {
        // The bytes the cluster would stream; a stand-in until the daemon
        // is wired, sized so the row keeps reading the same. What lands is
        // the selected version, so the path is current from here on: one
        // version, not a fork against the cluster's.
        const { versionCount: _count, versions: _dropped, ...rest } = file;
        const adopted: DriveFile = {
          ...rest,
          blob: new Blob([new Uint8Array(Math.min(file.sizeBytes, 64))]),
          deviceId: currentDeviceId,
          modifiedAt: Date.now(),
        };
        written.push(adopted);
        return adopted;
      }
      if (options.replace && driveVersionCount(file) > 1) {
        // Replacing settles the path on the copy already shown here, which is
        // the newest: the same choice the versions panel offers by hand.
        const replaced = {
          ...settleOnVersion(file, file.versions?.[0]),
          blob: file.blob,
          ...(file.thumbnail ? { thumbnail: file.thumbnail } : {}),
        };
        written.push(replaced);
        return replaced;
      }
      return file;
    });
    if (written.length > 0) this.#commit({ files });
    return written;
  }

  /**
   * Pins or unpins one file on this device. Pinning a file whose bytes are
   * not here yet brings them here (the same stand-in `adopt` writes), since
   * "available offline" means nothing for a file this device has never held.
   * Unpinning only drops the pin; the bytes stay until retention says otherwise.
   */
  setKeepOffline(fileId: string, keepOffline: boolean): DriveFile | undefined {
    let updated: DriveFile | undefined;
    const files = this.#snapshot.files.map((file) => {
      if (file.id !== fileId || (file.keepOffline ?? false) === keepOffline)
        return file;
      // Fetching the bytes here settles the path on what landed, so the
      // copies the cluster was holding for it collapse to this one.
      const fetched = keepOffline && file.blob === undefined;
      const base = fetched ? settleOnVersion(file, file.versions?.[0]) : file;
      updated = {
        ...base,
        keepOffline,
        ...(fetched
          ? {
              blob: new Blob([new Uint8Array(Math.min(file.sizeBytes, 64))]),
              deviceId:
                this.#snapshot.devices.find((device) => device.current)?.id ??
                file.deviceId,
            }
          : {}),
      };
      return updated;
    });
    if (updated) this.#commit({ files });
    return updated;
  }

  /**
   * Pins or unpins a whole selection in one commit, so a multi-file pin is a
   * single render rather than one per file.
   */
  setKeepOfflineMany(fileIds: ReadonlySet<string>, keepOffline: boolean): number {
    let changed = 0;
    const currentDeviceId =
      this.#snapshot.devices.find((device) => device.current)?.id ??
      this.#snapshot.originDeviceId;
    const files = this.#snapshot.files.map((file) => {
      if (!fileIds.has(file.id) || (file.keepOffline ?? false) === keepOffline)
        return file;
      changed += 1;
      const fetched = keepOffline && file.blob === undefined;
      const base = fetched ? settleOnVersion(file, file.versions?.[0]) : file;
      return {
        ...base,
        keepOffline,
        ...(fetched
          ? {
              blob: new Blob([new Uint8Array(Math.min(file.sizeBytes, 64))]),
              deviceId: currentDeviceId,
            }
          : {}),
      };
    });
    if (changed > 0) this.#commit({ files });
    return changed;
  }

  /**
   * Settles a diverged path on the copy the user picked, leaving one version
   * for every device. Returns the file as it now stands.
   */
  resolveFileVersion(fileId: string, versionId: string): DriveFile | undefined {
    let settled: DriveFile | undefined;
    const files = this.#snapshot.files.flatMap((file) => {
      if (file.id !== fileId) return [file];
      const version = file.versions?.find((entry) => entry.id === versionId);
      if (!version) return [file];
      settled = settleOnVersion(file, version);
      return version.deleted ? [] : [settled];
    });
    if (settled) this.#commit({ files });
    return settled;
  }

  #adoptionCandidates(target: DriveAdoptionTarget): DriveFile[] {
    return this.#snapshot.files.filter((file) =>
      target.kind === "space"
        ? file.spaceId === target.spaceId
        : file.id === target.fileId
    );
  }

  /**
   * Paths an additive adoption cannot settle: the cluster holds a different
   * version of a file this device already has, and overwriting it is not
   * something sync decides on its own. These are what the failures tab lists.
   */
  #adoptionConflicts(target: DriveAdoptionTarget): DriveFile[] {
    return this.#adoptionCandidates(target).filter(
      (file) => file.blob !== undefined && driveVersionCount(file) > 1
    );
  }

  removeFile(fileId: string) {
    const files = this.#snapshot.files.filter((file) => file.id !== fileId);
    if (files.length === this.#snapshot.files.length) return;
    this.#commit({ files });
  }

  /** A new, empty space on this device. It is synced from the start: it was made here. */
  addSpace(name: string): DriveSpace {
    this.#spaceSeq += 1;
    const space: DriveSpace = {
      id: `drive-space-local-${this.#spaceSeq}`,
      name,
      originPath: `${this.#snapshot.localSyncRoot}/${name}`,
      synced: true,
    };
    this.#commit({ spaces: [...this.#snapshot.spaces, space] });
    return space;
  }

  /**
   * Renames a space. A synced space's local folder follows the name: the
   * app's name is the one that wins, so a rename here overwrites whatever
   * the folder was called on disk, and the history says so.
   */
  renameSpace(spaceId: string, name: string): DriveSpace | undefined {
    let renamed: DriveSpace | undefined;
    const spaces = this.#snapshot.spaces.map((space) => {
      if (space.id !== spaceId || space.name === name) return space;
      const originPath =
        space.originPath === undefined
          ? undefined
          : `${space.originPath.slice(0, space.originPath.lastIndexOf("/") + 1)}${name}`;
      renamed = { ...space, name, ...(originPath === undefined ? {} : { originPath }) };
      return renamed;
    });
    if (!renamed) return undefined;
    this.#commit({
      spaces,
      ...(renamed.synced
        ? {
            syncHistory: this.#recordSync([
              {
                direction: "download",
                kind: "folder",
                name,
                operation: "updated",
                status: "success",
              },
            ]),
          }
        : {}),
    });
    return renamed;
  }

  /**
   * Switches one space's local copy on or off. Switching on brings every
   * file the cluster has for it onto this device (the same additive write an
   * import does); switching off only stops mirroring, nothing is removed.
   */
  /** Reports how many files landed, which is what the caller tells the user. */
  setSpaceSynced(
    spaceId: string,
    synced: boolean
  ): { copied: number; space: DriveSpace } | undefined {
    const space = this.#snapshot.spaces.find((entry) => entry.id === spaceId);
    if (!space || (space.synced ?? false) === synced) return undefined;
    const target: DriveAdoptionTarget = { kind: "space", spaceId };
    // Read the conflicts before adopting: the write settles the versions.
    const conflicts = synced ? this.#adoptionConflicts(target) : [];
    const written = synced ? this.adopt(target, { replace: false }) : [];
    const updated: DriveSpace = { ...space, synced };
    this.#commit({
      spaces: this.#snapshot.spaces.map((entry) =>
        entry.id === spaceId ? updated : entry
      ),
      syncHistory: this.#recordSync([
        {
          direction: "download",
          kind: "folder",
          name: space.name,
          operation: synced ? "added" : "removed",
          status: "success",
        },
        ...written.map((file) => ({
          direction: "download" as const,
          kind: "file" as const,
          name: file.name,
          operation: "added" as const,
          sizeBytes: file.sizeBytes,
          status: "success" as const,
        })),
        ...conflicts.map((file) => ({
          direction: "download" as const,
          fileId: file.id,
          kind: "file" as const,
          name: file.name,
          operation: "updated" as const,
          sizeBytes: file.sizeBytes,
          status: "failed" as const,
        })),
      ]),
    });
    return { copied: written.length, space: updated };
  }

  /**
   * Takes the cluster's version for every conflict still open — the retry the
   * failures tab offers. The failed lines stay in the history, marked settled,
   * and each path gets a fresh line for the write that finally landed.
   */
  retryFailedSync(): number {
    const open = this.#snapshot.syncHistory.filter(
      (entry) =>
        entry.status === "failed" &&
        entry.resolved !== true &&
        entry.fileId !== undefined
    );
    if (open.length === 0) return 0;

    const written: DriveFile[] = [];
    for (const entry of open) {
      if (entry.fileId === undefined) continue;
      written.push(
        ...this.adopt({ fileId: entry.fileId, kind: "file" }, { replace: true })
      );
    }
    const settled = new Set(open.map((entry) => entry.id));
    const history = this.#snapshot.syncHistory.map((entry) =>
      settled.has(entry.id) ? { ...entry, resolved: true } : entry
    );
    this.#commit({
      syncHistory: this.#recordSync(
        written.map((file) => ({
          direction: "download" as const,
          kind: "file" as const,
          name: file.name,
          operation: "updated" as const,
          sizeBytes: file.sizeBytes,
          status: "success" as const,
        })),
        history
      ),
    });
    return open.length;
  }

  /**
   * The device-wide switch. Turning it on takes the set of spaces to mirror
   * (the picker's choice); turning it off leaves every space's own flag as
   * it was, so switching back on later restores the same set.
   */
  setLocalSyncEnabled(enabled: boolean, syncedSpaceIds?: ReadonlySet<string>) {
    if (this.#snapshot.localSyncEnabled === enabled && syncedSpaceIds === undefined)
      return;
    // The switch itself writes no history line: the table lists paths, and
    // the per-space rows that follow are what actually moved.
    this.#commit({ localSyncEnabled: enabled });
    if (enabled && syncedSpaceIds) {
      for (const space of this.#snapshot.spaces) {
        this.setSpaceSynced(space.id, syncedSpaceIds.has(space.id));
      }
    }
  }

  /** Bytes the cluster holds for a space; what mirroring it would occupy here. */
  spaceSizeBytes(spaceId: string): number {
    return this.#snapshot.files
      .filter((file) => file.spaceId === spaceId)
      .reduce((total, file) => total + file.sizeBytes, 0);
  }

  /** Newest first, so the table reads like a log without sorting it again. */
  #recordSync(
    entries: readonly Omit<DriveSyncHistoryEntry, "at" | "id">[],
    base: readonly DriveSyncHistoryEntry[] = this.#snapshot.syncHistory
  ): DriveSyncHistoryEntry[] {
    const at = Date.now();
    const recorded = entries.map((entry) => {
      this.#syncSeq += 1;
      return { ...entry, at, id: `drive-sync-${this.#syncSeq}` };
    });
    return [...recorded.toReversed(), ...base];
  }

  removeSpace(spaceId: string) {
    // The install's own folder cannot be deleted from the list.
    if (this.#snapshot.spaces.some((space) => space.id === spaceId && space.protected))
      return;
    const spaces = this.#snapshot.spaces.filter((space) => space.id !== spaceId);
    if (spaces.length === this.#snapshot.spaces.length) return;
    this.#commit({
      files: this.#snapshot.files.filter((file) => file.spaceId !== spaceId),
      selectedSpaceId:
        this.#snapshot.selectedSpaceId === spaceId
          ? (spaces[0]?.id ?? "")
          : this.#snapshot.selectedSpaceId,
      spaces,
    });
  }

  beginTransfer(input: {
    detail: string;
    direction: DriveTransferDirection;
    fileId?: string;
    fileName: string;
    spaceId?: string;
    uploadSource?: File;
  }): DriveTransfer {
    this.#transferSeq += 1;
    const transfer: DriveTransfer = {
      detail: input.detail,
      direction: input.direction,
      fileName: input.fileName,
      id: `drive-transfer-${this.#transferSeq}`,
      status: "in_progress",
      ...(input.fileId === undefined ? {} : { fileId: input.fileId }),
      ...(input.spaceId === undefined ? {} : { spaceId: input.spaceId }),
    };
    if (input.uploadSource) {
      this.#uploadSources.set(transfer.id, input.uploadSource);
    }
    this.#commit({ transfers: [transfer, ...this.#snapshot.transfers] });
    return transfer;
  }

  completeTransfer(
    transferId: string,
    outcome: { downloadRef?: string; fileId?: string } = {}
  ) {
    this.#uploadSources.delete(transferId);
    this.#updateTransfer(transferId, (transfer) => {
      const fileId = outcome.fileId ?? transfer.fileId;
      return {
        ...baseTransfer(transfer),
        status: "success",
        ...(outcome.downloadRef === undefined
          ? {}
          : { downloadRef: outcome.downloadRef }),
        ...(fileId === undefined ? {} : { fileId }),
      };
    });
  }

  failTransfer(transferId: string, errorMessage: string) {
    this.#updateTransfer(transferId, (transfer) => ({
      ...baseTransfer(transfer),
      errorMessage,
      status: "error",
    }));
  }

  restartTransfer(transferId: string) {
    this.#updateTransfer(transferId, (transfer) => ({
      ...baseTransfer(transfer),
      status: "in_progress",
    }));
  }

  /**
   * Drops every finished row, success or error, and the picked files kept for
   * their retries. Rows still moving stay: their bytes are in flight and they
   * land in the panel whether or not it was cleared meanwhile.
   */
  dismissFinishedTransfers() {
    const transfers = this.#snapshot.transfers.filter(
      (transfer) => transfer.status === "in_progress"
    );
    if (transfers.length === this.#snapshot.transfers.length) return;
    for (const transfer of this.#snapshot.transfers) {
      if (transfer.status !== "in_progress") this.#uploadSources.delete(transfer.id);
    }
    this.#commit({ transfers });
  }

  uploadSource(transferId: string): File | undefined {
    return this.#uploadSources.get(transferId);
  }

  transferById(transferId: string): DriveTransfer | undefined {
    return this.#snapshot.transfers.find((transfer) => transfer.id === transferId);
  }

  /** The freshest saved-download handle for a file, if one exists this session. */
  latestDownloadRef(fileId: string): string | undefined {
    return this.#snapshot.transfers.find(
      (transfer) =>
        transfer.direction === "download" &&
        transfer.status === "success" &&
        transfer.fileId === fileId &&
        transfer.downloadRef !== undefined
    )?.downloadRef;
  }

  #updateTransfer(
    transferId: string,
    update: (transfer: DriveTransfer) => DriveTransfer
  ) {
    let changed = false;
    const transfers = this.#snapshot.transfers.map((transfer) => {
      if (transfer.id !== transferId) return transfer;
      changed = true;
      return update(transfer);
    });
    if (!changed) return;
    this.#commit({ transfers });
  }

  #commit(partial: Partial<DriveSnapshot>) {
    this.#snapshot = { ...this.#snapshot, ...partial };
    for (const listener of this.#listeners) listener();
  }
}

/** Identity fields every status rewrite keeps; outcome fields start clean. */
const baseTransfer = (
  transfer: DriveTransfer
): Omit<DriveTransfer, "downloadRef" | "errorMessage" | "status"> => ({
  detail: transfer.detail,
  direction: transfer.direction,
  fileName: transfer.fileName,
  id: transfer.id,
  ...(transfer.fileId === undefined ? {} : { fileId: transfer.fileId }),
  ...(transfer.spaceId === undefined ? {} : { spaceId: transfer.spaceId }),
});

export function useDriveSnapshot(store: DriveStore): DriveSnapshot {
  return useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
}

const driveFileExtension = (name: string) => {
  const dotIndex = name.lastIndexOf(".");
  if (dotIndex <= 0 || dotIndex === name.length - 1) return "";
  return name.slice(dotIndex + 1).toLowerCase();
};

/** Uppercased extension, the Figma transfer rows' file detail ("PDF", "WAV"). */
export const driveFileTypeLabel = (name: string) => {
  const extension = driveFileExtension(name);
  return extension === "" ? "File" : extension.toUpperCase();
};

export type DriveSortColumn = "modified" | "name" | "size" | "versions";
export type DriveSortDirection = "asc" | "desc";
export interface DriveSort {
  column: DriveSortColumn;
  direction: DriveSortDirection;
}

export const defaultDriveSort: DriveSort = { column: "name", direction: "asc" };

const nameCollator = new Intl.Collator(undefined, {
  numeric: true,
  sensitivity: "base",
});

const compareDriveFiles = (column: DriveSortColumn, a: DriveFile, b: DriveFile) => {
  switch (column) {
    case "name":
      return nameCollator.compare(a.name, b.name);
    case "versions":
      return driveVersionCount(a) - driveVersionCount(b);
    case "size":
      return a.sizeBytes - b.sizeBytes;
    case "modified":
      return a.modifiedAt - b.modifiedAt;
  }
};

/** Stable sort; ties fall back to name so a column of equal values keeps a readable order. */
export function sortDriveFiles(
  files: readonly DriveFile[],
  sort: DriveSort
): DriveFile[] {
  const sign = sort.direction === "asc" ? 1 : -1;
  return files.toSorted((a, b) => {
    const primary = compareDriveFiles(sort.column, a, b) * sign;
    return primary !== 0 ? primary : nameCollator.compare(a.name, b.name);
  });
}

/** "2.2 MB" — the Figma list rows put a space before the unit. */
export const formatDriveFileSize = (sizeBytes: number) => {
  if (!Number.isFinite(sizeBytes) || sizeBytes < 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"] as const;
  let value = sizeBytes;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  const rounded =
    value >= 10 || Number.isInteger(value) ? value.toFixed(0) : value.toFixed(1);
  return `${rounded} ${units[unitIndex]}`;
};

export type DriveFileKind = "audio" | "document" | "image" | "text" | "video";

const imageExtensions = new Set(["avif", "gif", "jpeg", "jpg", "png", "svg", "webp"]);
const audioExtensions = new Set(["aac", "flac", "m4a", "mp3", "ogg", "wav"]);
const videoExtensions = new Set(["m4v", "mov", "mp4", "webm"]);
/** Read as text in the preview; anything else without a media type is a document. */
const textExtensions = new Set([
  "csv",
  "json",
  "log",
  "markdown",
  "md",
  "toml",
  "txt",
  "xml",
  "yaml",
  "yml",
]);

/**
 * The mime a picked file should carry once its bytes are copied into a Blob.
 * A blob URL is decoded by its type alone, and a picker can hand over a File
 * with an empty type, so an `.svg` would otherwise arrive as bytes no `<img>`
 * will draw. Only the image types the preview renders are named; anything
 * else keeps whatever the picker said.
 */
const imageMimeByExtension: Record<string, string> = {
  avif: "image/avif",
  gif: "image/gif",
  jpeg: "image/jpeg",
  jpg: "image/jpeg",
  png: "image/png",
  svg: "image/svg+xml",
  webp: "image/webp",
};

export const driveUploadMimeType = (name: string, pickedType: string) =>
  pickedType || (imageMimeByExtension[driveFileExtension(name)] ?? "");

export const driveFileKind = (
  file: Pick<DriveFile, "blob" | "name">
): DriveFileKind => {
  const mime = file.blob?.type ?? "";
  if (mime.startsWith("image/")) return "image";
  if (mime.startsWith("audio/")) return "audio";
  if (mime.startsWith("video/")) return "video";
  const extension = driveFileExtension(file.name);
  if (imageExtensions.has(extension)) return "image";
  if (audioExtensions.has(extension)) return "audio";
  if (videoExtensions.has(extension)) return "video";
  if (mime.startsWith("text/") || textExtensions.has(extension)) return "text";
  return "document";
};

/**
 * A stable per-file token in the shape Synchronicity's content addresses
 * take. Demo data only — real hashes arrive with the backend integration.
 */
const driveContentsHash = (name: string, sizeBytes: number, seq: number) => {
  let hash = 0x811c9dc5 ^ seq;
  const input = `${name}:${sizeBytes}`;
  for (let index = 0; index < input.length; index += 1) {
    hash = Math.imul(hash ^ input.charCodeAt(index), 0x01000193);
  }
  return `f${(hash >>> 0).toString(16).padStart(8, "0")}${((hash * 31) >>> 0)
    .toString(16)
    .padStart(8, "0")}`;
};

let sharedStore: DriveStore | undefined;

/** One store per window, so transfers survive route changes like chat state does. */
export function getDriveStore(): DriveStore {
  // The Electron client reads the real tree from the bundled node once it is
  // up (`useDriveBackendLoad`); the demo data is for everywhere else.
  sharedStore ??= new DriveStore(
    driveSynchronicityAvailable()
      ? { devices: [], files: [], spaces: [] }
      : createDriveDemoData()
  );
  return sharedStore;
}

const demoModifiedAt = Date.UTC(2026, 8, 2, 12, 26);

/**
 * A short mono 16-bit PCM sine sweep. Real playable bytes so the audio
 * preview and the download path exercise the production controls.
 */
function createDemoWavBlob(): Blob {
  const sampleRate = 8000;
  const seconds = 1.2;
  const sampleCount = Math.floor(sampleRate * seconds);
  const buffer = new ArrayBuffer(44 + sampleCount * 2);
  const view = new DataView(buffer);
  const writeAscii = (offset: number, text: string) => {
    for (let index = 0; index < text.length; index += 1) {
      view.setUint8(offset + index, text.charCodeAt(index));
    }
  };
  writeAscii(0, "RIFF");
  view.setUint32(4, 36 + sampleCount * 2, true);
  writeAscii(8, "WAVE");
  writeAscii(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeAscii(36, "data");
  view.setUint32(40, sampleCount * 2, true);
  for (let index = 0; index < sampleCount; index += 1) {
    const progress = index / sampleCount;
    const frequency = 220 + 440 * progress;
    const amplitude = Math.sin((index / sampleRate) * frequency * 2 * Math.PI);
    const envelope = Math.sin(progress * Math.PI);
    view.setInt16(44 + index * 2, Math.round(amplitude * envelope * 0x5fff), true);
  }
  return new Blob([buffer], { type: "audio/wav" });
}

const crc32Table = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

const crc32 = (bytes: Uint8Array) => {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = crc32Table[(crc ^ byte) & 0xff]! ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
};

const adler32 = (bytes: Uint8Array) => {
  let a = 1;
  let b = 0;
  for (const byte of bytes) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return ((b << 16) | a) >>> 0;
};

const u32 = (value: number) =>
  new Uint8Array([
    value >>> 24,
    (value >>> 16) & 0xff,
    (value >>> 8) & 0xff,
    value & 0xff,
  ]);

const pngChunk = (type: string, data: Uint8Array) => {
  const typeBytes = new TextEncoder().encode(type);
  const body = new Uint8Array(typeBytes.length + data.length);
  body.set(typeBytes);
  body.set(data, typeBytes.length);
  return [u32(data.length), body, u32(crc32(body))];
};

/**
 * Encodes RGBA pixels as a PNG with a stored (uncompressed) deflate stream:
 * the demo needs a picture that actually decodes, and a hand-pasted base64
 * blob once shipped with a corrupt IDAT — the header parsed, so `<img>`
 * reported 48×32 and painted nothing. Stored blocks need no compressor.
 */
function encodePng(width: number, height: number, rgba: Uint8Array): Blob {
  const stride = width * 4;
  const raw = new Uint8Array((stride + 1) * height);
  for (let y = 0; y < height; y += 1) {
    raw[y * (stride + 1)] = 0; // filter: none
    raw.set(rgba.subarray(y * stride, (y + 1) * stride), y * (stride + 1) + 1);
  }
  const blocks: Uint8Array[] = [new Uint8Array([0x78, 0x01])];
  for (let offset = 0; offset < raw.length; offset += 65535) {
    const slice = raw.subarray(offset, Math.min(offset + 65535, raw.length));
    const final = offset + 65535 >= raw.length ? 1 : 0;
    blocks.push(
      new Uint8Array([
        final,
        slice.length & 0xff,
        slice.length >>> 8,
        ~slice.length & 0xff,
        (~slice.length >>> 8) & 0xff,
      ]),
      slice
    );
  }
  blocks.push(u32(adler32(raw)));
  const idat = new Uint8Array(blocks.reduce((sum, block) => sum + block.length, 0));
  let cursor = 0;
  for (const block of blocks) {
    idat.set(block, cursor);
    cursor += block.length;
  }
  const ihdr = new Uint8Array(13);
  ihdr.set(u32(width), 0);
  ihdr.set(u32(height), 4);
  ihdr.set([8, 6, 0, 0, 0], 8); // 8-bit RGBA, no interlace
  return new Blob(
    [
      new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      ...pngChunk("IHDR", ihdr),
      ...pngChunk("IDAT", idat),
      ...pngChunk("IEND", new Uint8Array(0)),
    ],
    { type: "image/png" }
  );
}

/** 48×32 PNG of brand-blue and white blocks, enough for the preview to draw. */
function createDemoPngBlob(): Blob {
  const width = 48;
  const height = 32;
  const rgba = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const blue = (Math.floor(x / 8) + Math.floor(y / 8)) % 2 === 0;
      rgba.set(
        blue ? [0x20, 0x5b, 0xff, 0xff] : [0xff, 0xff, 0xff, 0xff],
        (y * width + x) * 4
      );
    }
  }
  return encodePng(width, height, rgba);
}

/** A vector mark, so the SVG preview and thumbnail have real content to draw. */
function createDemoSvgBlob(): Blob {
  const markup =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">' +
    '<rect width="96" height="96" rx="20" fill="#205bff"/>' +
    '<circle cx="48" cy="48" r="22" fill="none" stroke="#fff" stroke-width="8"/>' +
    '<circle cx="48" cy="48" r="7" fill="#fff"/>' +
    "</svg>";
  return new Blob([markup], { type: "image/svg+xml" });
}

/**
 * Attaches the copies a diverged path holds. The head is the file itself — the
 * newest, which is the one the default policy shows — and each older entry
 * names the device that still has it. One copy per device: a device holds a
 * single state for a path, so a path can never have more versions than the
 * cluster has machines.
 */
function withVersions(
  file: DriveFile,
  older: readonly { deviceId: string; hoursBack: number; sizeBytes: number }[]
): DriveFile {
  const hour = 60 * 60 * 1000;
  return {
    ...file,
    versions: [
      {
        contentsHash: file.contentsHash,
        deviceId: file.deviceId,
        id: `${file.id}-v0`,
        modifiedAt: file.modifiedAt,
        sizeBytes: file.sizeBytes,
      },
      ...older.map((copy, index) => ({
        contentsHash: driveContentsHash(file.name, copy.sizeBytes, index + 1),
        deviceId: copy.deviceId,
        id: `${file.id}-v${index + 1}`,
        modifiedAt: file.modifiedAt - copy.hoursBack * hour,
        sizeBytes: copy.sizeBytes,
      })),
    ],
  };
}

export function createDriveDemoData(): DriveSeedData {
  const devices: DriveDevice[] = [
    { current: true, id: "this-mac", label: "This Mac" },
    { current: false, id: "macbook-pro-16", label: "MacBook Pro 16" },
    { current: false, id: "studio-nas", label: "Studio NAS" },
  ];
  const spaces: DriveSpace[] = [
    { id: "space-folder-a", name: "Folder A", originPath: "~/Drive/Folder A" },
    { id: "space-recordings", name: "Recordings", originPath: "~/Music/Recordings" },
    { id: "space-shared", name: "Shared" },
  ];
  const wavBlob = createDemoWavBlob();
  const pngBlob = createDemoPngBlob();
  const svgBlob = createDemoSvgBlob();
  const files: DriveFile[] = [
    {
      blob: pngBlob,
      contentsHash: "f59b4bb5624bc321321",
      deviceId: "this-mac",
      id: "drive-file-screenshot",
      modifiedAt: demoModifiedAt,
      name: "Screenshot 2026-08-29 at 10.47.png",
      sizeBytes: pngBlob.size,
      spaceId: "space-folder-a",
    },
    {
      blob: svgBlob,
      contentsHash: "f2d7a41e08c95b6e3f1",
      deviceId: "this-mac",
      id: "drive-file-logo-svg",
      modifiedAt: demoModifiedAt,
      name: "logo-mark.svg",
      sizeBytes: svgBlob.size,
      spaceId: "space-folder-a",
    },
    withVersions(
      {
        contentsHash: "f4c1d2aa90cbe771205",
        deviceId: "macbook-pro-16",
        id: "drive-file-openai-pdf",
        modifiedAt: demoModifiedAt,
        name: "Openai.pdf",
        sizeBytes: 2_306_867,
        spaceId: "space-folder-a",
      },
      [
        { deviceId: "this-mac", hoursBack: 6, sizeBytes: 2_118_224 },
        { deviceId: "studio-nas", hoursBack: 20, sizeBytes: 1_984_512 },
      ]
    ),
    withVersions(
      {
        blob: wavBlob,
        contentsHash: "f0aa719c2745bd90113",
        deviceId: "this-mac",
        id: "drive-file-sound",
        modifiedAt: demoModifiedAt,
        name: "sound.wav",
        sizeBytes: wavBlob.size,
        spaceId: "space-recordings",
      },
      [
        { deviceId: "studio-nas", hoursBack: 3, sizeBytes: wavBlob.size - 6_144 },
        { deviceId: "macbook-pro-16", hoursBack: 9, sizeBytes: wavBlob.size - 9_216 },
      ]
    ),
    withVersions(
      {
        contentsHash: "f77e3c05512df188aa0",
        deviceId: "studio-nas",
        id: "drive-file-session-take",
        modifiedAt: demoModifiedAt,
        name: "session-take-2.wav",
        sizeBytes: 2_306_867,
        spaceId: "space-recordings",
      },
      [{ deviceId: "macbook-pro-16", hoursBack: 14, sizeBytes: 2_050_048 }]
    ),
    withVersions(
      {
        contentsHash: "f19cd0e8b7f4362cc57",
        deviceId: "macbook-pro-16",
        id: "drive-file-launch-cut",
        modifiedAt: demoModifiedAt,
        name: "launch-cut.mp4",
        sizeBytes: 48_234_496,
        spaceId: "space-shared",
      },
      [
        { deviceId: "this-mac", hoursBack: 8, sizeBytes: 46_137_344 },
        { deviceId: "studio-nas", hoursBack: 36, sizeBytes: 44_040_192 },
      ]
    ),
  ];
  return { devices, files, spaces };
}
