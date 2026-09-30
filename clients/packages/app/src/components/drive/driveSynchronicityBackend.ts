import { fileDownloadMaxBytes, getNativeBridge } from "@comma/native-bridge";
import type {
  FilesSaveDownloadResult,
  SynchronicityEntry,
  SynchronicityMutationResult,
  SynchronicitySpace,
  SynchronicityState,
  SynchronicityVersion,
} from "@comma/native-bridge";
import type {
  DriveDevice,
  DriveFile,
  DriveFileVersion,
  DriveSpace,
  DriveVersionPolicy,
} from "./driveStore";

/**
 * Drive over the bundled synchronicity node. Main owns the daemon; the
 * renderer sees the unified tree through the `synchronicity` bridge and
 * reads it into the store's own shapes:
 *
 * - a synchronicity *space* is a Drive space, and the one this install
 *   publishes from `~/Drive` is the default folder — its own, so it is
 *   never offered for deletion;
 * - a listing *entry* is a Drive file, with the path's directory as its
 *   `folderPath`, and the origin that published the selected version as
 *   its device;
 * - a path's *versions* are the copies other origins assert, which is what
 *   the versions panel already models;
 * - "synced to this device" is one of two things on the node: a space this
 *   device publishes takes the cluster's files into its own folder
 *   (`adopt tree`), and a space another device publishes is kept as a
 *   replica with a checkout under `~/Comma Spaces`.
 *
 * Bytes are fetched only when a preview or a download asks for them.
 */
export interface DriveBackendSnapshot {
  devices: readonly DriveDevice[];
  files: readonly DriveFile[];
  /** Whether any space besides the install's own is mirrored on this device. */
  localSyncEnabled: boolean;
  /** The install's own folder on disk. */
  localSyncRoot: string;
  originDeviceId: string;
  spaces: readonly DriveSpace[];
}

/** What turning sync on for a space this device publishes did, in paths. */
export interface DriveAdoptionCounts {
  adopt: number;
  current: number;
  differing: number;
  skipped: number;
}

interface DriveSynchronicityImportBridge {
  importFile(input: {
    path: string;
    source: File;
    space: string;
  }): Promise<SynchronicityMutationResult>;
}

export interface DriveBackend {
  /** Everything the store shows: spaces, the files in each, and who published them. */
  load(options: {
    originDeviceId?: string | undefined;
    policy: DriveVersionPolicy;
  }): Promise<DriveBackendSnapshot>;
  /** The whole file, for a preview or a download. */
  readFile(file: DriveFile): Promise<Blob>;
  /** Streams the selected node version directly into Downloads. */
  saveDownload(file: DriveFile): Promise<FilesSaveDownloadResult>;
  /** Opens the Main-owned local Drive root without accepting a renderer path. */
  openLocalRoot(): Promise<boolean>;
  /** Publishes bytes at a path in a space. */
  writeFile(input: {
    blob?: Blob | undefined;
    folderPath?: string | undefined;
    name: string;
    source?: File | undefined;
    spaceId: string;
  }): Promise<void>;
  deleteFile(file: DriveFile): Promise<void>;
  /**
   * The copies of a path, the one on screen first. The inspector names each
   * copy's origin by a prefix, so the origins the listing knows are passed
   * in to complete them.
   */
  versions(
    file: DriveFile,
    knownOrigins: readonly string[]
  ): Promise<readonly DriveFileVersion[]>;
  /** Adopts the origin's version as this node's own, ending the divergence. */
  adopt(file: DriveFile, version: DriveFileVersion): Promise<void>;
  /** Takes the cluster's newest version of a path into this device's folder. */
  adoptNewest(file: DriveFile): Promise<void>;
  /**
   * Lets the user pick a local folder and publishes it as a new space; the
   * space's id is made from the folder's name. Nothing when the dialog is
   * dismissed.
   */
  addSpaceFromFolder(): Promise<{ id: string; name: string; path: string } | undefined>;
  /** Stops publishing or replicating a space here; files on disk stay. */
  removeSpace(space: DriveSpace): Promise<void>;
  /** This install's own name for a space; the node's id stays. */
  renameSpace(space: DriveSpace, name: string): Promise<void>;
  /**
   * Mirrors a space on this device or stops: the cluster's files land in the
   * space's own folder when this device publishes it, or in a checkout under
   * `~/Comma Spaces` when another device does. Answers with what the write
   * did, in paths, for a published space; a checkout reports nothing yet.
   */
  setSpaceSynced(
    space: DriveSpace,
    synced: boolean
  ): Promise<DriveAdoptionCounts | undefined>;
  /** What syncing a published space would do, without writing. */
  planSpaceSync(space: DriveSpace): Promise<DriveAdoptionCounts>;
  /** Keeps a file's bytes on this device regardless of retention, or stops. */
  setKeepOffline(file: DriveFile, keepOffline: boolean): Promise<void>;
  /** Brings a node that could not start down and up again. */
  restart(): Promise<SynchronicityState>;
}

export const driveDefaultSpaceLabel = "Drive";

/** Where spaces other devices publish are checked out on this one. */
export const driveSpacesFolderName = "Comma Spaces";

const LIST_PAGE_SIZE = 500;
/** Renderer previews stay bounded; large objects remain available by streamed download. */
export const driveInlineReadMaxBytes = fileDownloadMaxBytes;

/** `key:mk6tw5zohh…` → "mk6tw5zohh"; a zone-named origin keeps its label. */
export function driveDeviceLabel(
  origin: string,
  current: boolean,
  deviceName = ""
): string {
  if (current) return deviceName || "This Mac";
  if (origin.startsWith("key:")) return origin.slice(4, 14);
  return origin.split("@")[0] ?? origin;
}

export function driveFileIdFor(space: string, path: string) {
  return `synch:${space}:${path}`;
}

/** "Field Recordings 2026" → "field-recordings-2026"; a space id is a namespace, not a label. */
export function driveSpaceIdFor(folderName: string, taken: ReadonlySet<string>) {
  const base =
    folderName
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 48) || "space";
  let id = base;
  for (let suffix = 2; taken.has(id); suffix += 1) id = `${base}-${suffix}`;
  return id;
}

/** The last path segment: what a folder is called on disk. */
export function driveFolderName(path: string) {
  return (
    path
      .replace(/[/\\]+$/, "")
      .split(/[/\\]/)
      .pop() ?? path
  );
}

/** `~/Drive` → `~/Comma Spaces`: the checkouts sit beside the install's own folder. */
export function driveSpacesRoot(localRoot: string) {
  const parent = localRoot.replace(/[/\\][^/\\]+$/, "");
  return `${parent}/${driveSpacesFolderName}`;
}

function splitPath(path: string): { folderPath: string | undefined; name: string } {
  const slash = path.lastIndexOf("/");
  if (slash === -1) return { folderPath: undefined, name: path };
  return { folderPath: path.slice(0, slash), name: path.slice(slash + 1) };
}

function entryToFile(
  space: string,
  entry: SynchronicityEntry,
  pinned: boolean
): DriveFile {
  const { folderPath, name } = splitPath(entry.path);
  return {
    contentsHash: entry.contentRoot.slice(0, 19),
    deviceId: entry.origin,
    id: driveFileIdFor(space, entry.path),
    modifiedAt: entry.mtimeMs,
    name,
    sizeBytes: entry.size,
    spaceId: space,
    ...(folderPath === undefined ? {} : { folderPath }),
    ...(pinned ? { keepOffline: true } : {}),
    // The count is what the listing knows; the copies themselves are fetched
    // when the versions panel opens.
    ...(entry.versions > 1 ? { versionCount: entry.versions } : {}),
  };
}

function spaceToDrive(
  space: SynchronicitySpace,
  state: SynchronicityState
): DriveSpace {
  const isDefault = space.id === state.defaultSpace;
  const publishedHere = space.sourcePath !== "";
  return {
    id: space.id,
    name: space.label || (isDefault ? driveDefaultSpaceLabel : space.id),
    // Only a space this device publishes has an origin path; a replica's
    // checkout is a copy, and stopping it is a different sentence.
    ...(publishedHere ? { originPath: space.sourcePath } : {}),
    synced: publishedHere
      ? !space.sourcePaused || space.autoAdopt
      : space.replica && space.checkoutPath !== "",
    writable: space.writable,
    ...(isDefault ? { protected: true } : {}),
  };
}

function versionToDrive(
  version: SynchronicityVersion,
  file: { id: string; modifiedAt: number },
  index: number,
  knownOrigins: readonly string[]
): DriveFileVersion {
  const attestor = version.attestors[0] ?? "";
  return {
    contentsHash: version.root.slice(0, 19),
    ...(version.kind === "tombstone" ? { deleted: true } : {}),
    deviceId: knownOrigins.find((origin) => origin.startsWith(attestor)) ?? attestor,
    id: `${file.id}-v${index}`,
    // The inspector carries seq, not a clock; every copy but the selected one
    // reads as older than it, in seq order.
    modifiedAt: file.modifiedAt - index,
    sizeBytes: version.size,
  };
}

function base64ToBytes(content: string): Uint8Array<ArrayBuffer> {
  const binary = atob(content);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

async function blobToBase64(blob: Blob): Promise<string> {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let binary = "";
  const chunk = 0x8000;
  for (let index = 0; index < bytes.length; index += chunk) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunk));
  }
  return btoa(binary);
}

const mimeByExtension: Record<string, string> = {
  csv: "text/csv",
  gif: "image/gif",
  jpeg: "image/jpeg",
  jpg: "image/jpeg",
  json: "application/json",
  m4a: "audio/mp4",
  md: "text/markdown",
  mov: "video/quicktime",
  mp3: "audio/mpeg",
  mp4: "video/mp4",
  pdf: "application/pdf",
  png: "image/png",
  svg: "image/svg+xml",
  txt: "text/plain",
  wav: "audio/wav",
  webm: "video/webm",
  webp: "image/webp",
};

function mimeFor(name: string) {
  const extension = name.slice(name.lastIndexOf(".") + 1).toLowerCase();
  return mimeByExtension[extension] ?? "application/octet-stream";
}

/** Whether an origin stands behind a version; the inspector names attestors by prefix. */
function attestedBy(version: SynchronicityVersion, origin: string) {
  return version.attestors.some((attestor) => origin.startsWith(attestor));
}

function fullPath(file: DriveFile) {
  return file.folderPath ? `${file.folderPath}/${file.name}` : file.name;
}

function driveWritePath(input: { folderPath?: string | undefined; name: string }) {
  const segments = [
    ...(input.folderPath ? input.folderPath.split("/") : []),
    input.name,
  ];
  if (
    segments.length === 0 ||
    segments.some(
      (segment) =>
        segment.length === 0 ||
        segment === "." ||
        segment === ".." ||
        segment.includes("\\") ||
        segment.includes("\0")
    )
  ) {
    throw new Error("Drive upload path contains an unsafe segment.");
  }
  return segments.join("/");
}

const rejected = () => new Error("The local node is not available.");

/** Only in the Electron client: the bundled node is what the bridge exposes. */
export function driveSynchronicityAvailable() {
  return getNativeBridge().platform === "electron";
}

export class DriveSynchronicityBackend implements DriveBackend {
  #state: SynchronicityState | undefined;

  async state(): Promise<SynchronicityState> {
    this.#state = await getNativeBridge().synchronicity.state();
    return this.#state;
  }

  /** One explicit reveal reads at most one entry, never reloads other spaces. */
  async lookupFile(target: { space: string; path: string }) {
    const state = await this.state();
    if (state.status !== "ready") throw new Error("Drive is unavailable.");
    const space = state.spaces.find((entry) => entry.id === target.space);
    if (!space) throw new Error("The recording's Drive space is unavailable.");
    const result = await getNativeBridge().synchronicity.list({
      limit: 1,
      policy: "newest",
      prefix: target.path,
      space: target.space,
    });
    const entry = result.entries[0];
    if (!entry || entry.path !== target.path || entry.kind !== "file") {
      throw new Error("The recording no longer exists at this Drive location.");
    }
    return {
      device: {
        current: true,
        id: state.origin,
        label: driveDeviceLabel(state.origin, true, state.deviceName),
      },
      file: entryToFile(
        target.space,
        entry,
        state.pins.includes(`${target.space}/${target.path}`)
      ),
      space: spaceToDrive(space, state),
    };
  }

  async load({
    originDeviceId,
    policy,
  }: {
    originDeviceId?: string | undefined;
    policy: DriveVersionPolicy;
  }): Promise<DriveBackendSnapshot> {
    const state = await this.state();
    if (state.status !== "ready") {
      return {
        devices: [],
        files: [],
        localSyncEnabled: false,
        localSyncRoot: state.localRoot,
        originDeviceId: state.origin,
        spaces: [],
      };
    }
    // The node lists a space once something is published into it; the
    // install's own folder is a space from the moment it is a source, even
    // while it is still empty.
    const listed = state.spaces.some((space) => space.id === state.defaultSpace)
      ? state.spaces
      : [
          {
            autoAdopt: true,
            checkoutPath: "",
            heldSize: 0,
            id: state.defaultSpace,
            label: "",
            replica: false,
            sourcePath: state.localRoot,
            writable: true,
          },
          ...state.spaces,
        ];
    const spaces = listed.map((space) => spaceToDrive(space, state));
    const pins = new Set(state.pins);
    const files: DriveFile[] = [];
    const selectedOrigin =
      originDeviceId && state.origins.includes(originDeviceId)
        ? originDeviceId
        : state.origin;
    const visiblePolicy =
      selectedOrigin && selectedOrigin !== state.origin
        ? `origin=${selectedOrigin}`
        : policy;
    for (const space of spaces) {
      // A space this device publishes and keeps in sync takes what the
      // cluster has for it as it appears — path by path, never a path this
      // device deleted: the node treats its own tombstone as an empty slot
      // to fill, so a whole-tree adoption would quietly undo a deletion.
      const node = listed.find((entry) => entry.id === space.id);
      if (node?.sourcePath && node.autoAdopt && !node.sourcePaused) {
        const candidates = await this.#listSpace(space.id, "newest", pins);
        await this.#adoptFromCluster(space.id, candidates, state.origin);
      }
      const entries = await this.#listSpace(space.id, visiblePolicy, pins);
      files.push(...entries);
    }
    const origins = new Set<string>([
      state.origin,
      ...state.origins,
      ...files.map((file) => file.deviceId),
    ]);
    const devices: DriveDevice[] = [...origins].filter(Boolean).map((origin) => ({
      current: origin === state.origin,
      id: origin,
      label: driveDeviceLabel(origin, origin === state.origin, state.deviceName),
    }));
    return {
      devices,
      files,
      localSyncEnabled: spaces.some((space) => space.synced === true),
      localSyncRoot: state.localRoot,
      originDeviceId: state.origin,
      spaces,
    };
  }

  async readFile(file: DriveFile): Promise<Blob> {
    if (file.sizeBytes > driveInlineReadMaxBytes) {
      throw new Error("This file is too large to preview; download it instead.");
    }
    const result = await getNativeBridge().synchronicity.read({
      length: Math.max(1, file.sizeBytes),
      offset: 0,
      path: fullPath(file),
      policy: `origin=${file.deviceId}`,
      space: file.spaceId,
    });
    const bytes = base64ToBytes(result.content);
    if (
      bytes.byteLength !== result.length ||
      result.offset !== 0 ||
      result.size > driveInlineReadMaxBytes ||
      !result.eof ||
      result.length !== result.size
    ) {
      throw new Error("The node returned an incomplete Drive file.");
    }
    return new Blob([bytes], { type: mimeFor(file.name) });
  }

  async saveDownload(file: DriveFile): Promise<FilesSaveDownloadResult> {
    return getNativeBridge().synchronicity.saveDownload({
      fileName: file.name,
      path: fullPath(file),
      policy: `origin=${file.deviceId}`,
      space: file.spaceId,
    });
  }

  async openLocalRoot(): Promise<boolean> {
    return (await getNativeBridge().synchronicity.openLocalRoot()).status === "opened";
  }

  async writeFile(input: {
    blob?: Blob | undefined;
    folderPath?: string | undefined;
    name: string;
    source?: File | undefined;
    spaceId: string;
  }) {
    await this.#requireWritable(input.spaceId);
    const path = driveWritePath(input);
    const bridge = getNativeBridge();
    const importFile = (
      bridge.synchronicity as typeof bridge.synchronicity &
        DriveSynchronicityImportBridge
    ).importFile;
    if (
      input.source &&
      bridge.platform === "electron" &&
      typeof importFile === "function"
    ) {
      const result = await importFile({
        path,
        source: input.source,
        space: input.spaceId,
      });
      if (result.status !== "done") throw rejected();
      return;
    }
    if (!input.blob) {
      throw new Error(
        "This runtime cannot import Drive files from local file handles."
      );
    }
    if (input.blob.size > fileDownloadMaxBytes) {
      throw new Error("This file is too large for an in-app Drive upload.");
    }
    const result = await bridge.synchronicity.write({
      content: await blobToBase64(input.blob),
      path,
      space: input.spaceId,
    });
    if (result.status !== "done") throw rejected();
  }

  async deleteFile(file: DriveFile) {
    await this.#requireWritable(file.spaceId);
    const result = await getNativeBridge().synchronicity.delete({
      path: fullPath(file),
      space: file.spaceId,
    });
    if (result.status !== "done") throw rejected();
  }

  async versions(
    file: DriveFile,
    knownOrigins: readonly string[]
  ): Promise<readonly DriveFileVersion[]> {
    const result = await getNativeBridge().synchronicity.versions({
      path: fullPath(file),
      space: file.spaceId,
    });
    const origins = [
      ...new Set([this.#state?.origin ?? "", ...knownOrigins, file.deviceId]),
    ];
    // The selected version first, so the panel's "showing now" is the head.
    const ordered = result.versions.toSorted((a, b) => {
      const aSelected = attestedBy(a, file.deviceId) ? 0 : 1;
      const bSelected = attestedBy(b, file.deviceId) ? 0 : 1;
      return aSelected - bSelected || b.seq - a.seq;
    });
    return ordered.map((version, index) =>
      versionToDrive(version, file, index, origins)
    );
  }

  async adopt(file: DriveFile, version: DriveFileVersion) {
    await this.#requireWritable(file.spaceId);
    await this.#adoptPath(file, `origin=${version.deviceId}`);
  }

  async adoptNewest(file: DriveFile) {
    await this.#requireWritable(file.spaceId);
    await this.#adoptPath(file, "newest");
  }

  async addSpaceFromFolder() {
    const bridge = getNativeBridge().synchronicity;
    const picked = await bridge.pickFolder();
    if (!picked.path) return undefined;
    const state = this.#state ?? (await this.state());
    const name = driveFolderName(picked.path);
    const id = driveSpaceIdFor(name, new Set(state.spaces.map((space) => space.id)));
    const result = await bridge.sourceAdd({ path: picked.path, space: id });
    if (result.status !== "done") throw rejected();
    return { id, name, path: picked.path };
  }

  async removeSpace(space: DriveSpace) {
    const bridge = getNativeBridge().synchronicity;
    const known = this.#state?.spaces.find((entry) => entry.id === space.id);
    if (known?.replica) {
      const dropped = await bridge.replicaSet({ checkoutPath: "", space: space.id });
      if (dropped.status !== "done") throw rejected();
    }
    if (known?.writable) {
      const removed = await bridge.sourceRemove({ space: space.id });
      if (removed.status !== "done") throw rejected();
    }
  }

  async renameSpace(space: DriveSpace, name: string) {
    this.#state = await getNativeBridge().synchronicity.setSpaceSettings({
      label: name,
      space: space.id,
    });
  }

  async setSpaceSynced(space: DriveSpace, synced: boolean) {
    const bridge = getNativeBridge().synchronicity;
    const state = this.#state ?? (await this.state());
    const known = state.spaces.find((entry) => entry.id === space.id);
    if (known?.sourcePath) {
      this.#state = await bridge.setSpaceSettings({
        syncEnabled: synced,
        space: space.id,
      });
      if (!synced) return undefined;
      const entries = await this.#listSpace(space.id, "newest", new Set(state.pins));
      return this.#adoptFromCluster(space.id, entries, state.origin);
    }
    // The checkout is named by the space's id, which every device shares;
    // a label is this install's own and may change.
    const result = await bridge.replicaSet({
      checkoutPath: synced ? `${driveSpacesRoot(state.localRoot)}/${space.id}` : "",
      space: space.id,
    });
    if (result.status !== "done") throw rejected();
    return undefined;
  }

  async planSpaceSync(space: DriveSpace): Promise<DriveAdoptionCounts> {
    const result = await getNativeBridge().synchronicity.adoptTree({
      dryRun: true,
      replace: false,
      space: space.id,
    });
    if (result.status !== "done") throw rejected();
    return result;
  }

  async setKeepOffline(file: DriveFile, keepOffline: boolean) {
    const result = await getNativeBridge().synchronicity.pin({
      action: keepOffline ? "add" : "rm",
      path: fullPath(file),
      space: file.spaceId,
    });
    if (result.status !== "done") throw rejected();
  }

  async restart() {
    this.#state = await getNativeBridge().synchronicity.restart();
    return this.#state;
  }

  /** Names the node by the Workspace's zone; the node restarts under it. */
  async setDomain(domain: string): Promise<SynchronicityState> {
    this.#state = await getNativeBridge().synchronicity.setDomain({ domain });
    return this.#state;
  }

  async #requireWritable(spaceId: string) {
    const state = this.#state ?? (await this.state());
    const space = state.spaces.find((entry) => entry.id === spaceId);
    const defaultSource =
      spaceId === state.defaultSpace && state.localRoot !== "" && !space;
    if (!space?.writable && !defaultSource) {
      throw new Error("This Drive space is read-only on this device.");
    }
  }

  /**
   * Takes into this device's folder every path only other devices hold,
   * one path at a time, and reports the space's shape in the four counts
   * the sync history reads. A path this device deleted keeps its tombstone
   * — the other device's copy is left where it is — and a path the devices
   * disagree about is left for the versions panel.
   */
  async #adoptFromCluster(
    spaceId: string,
    entries: readonly DriveFile[],
    origin: string
  ): Promise<DriveAdoptionCounts> {
    const bridge = getNativeBridge().synchronicity;
    const counts: DriveAdoptionCounts = {
      adopt: 0,
      current: 0,
      differing: 0,
      skipped: 0,
    };
    for (const file of entries) {
      if ((file.versionCount ?? 1) > 1) {
        counts.differing += 1;
        continue;
      }
      if (file.deviceId === origin) {
        counts.current += 1;
        continue;
      }
      const path = fullPath(file);
      const { versions } = await bridge.versions({ path, space: spaceId });
      const deletedHere = versions.some(
        (version) => version.kind === "tombstone" && attestedBy(version, origin)
      );
      if (deletedHere) {
        counts.skipped += 1;
        continue;
      }
      const result = await bridge.adopt({
        automatic: true,
        path,
        select: `origin=${file.deviceId}`,
        space: spaceId,
      });
      if (result.status !== "done") throw rejected();
      if (result.skipped) counts.skipped += 1;
      else counts.adopt += 1;
    }
    return counts;
  }

  async #adoptPath(file: DriveFile, select: string) {
    const result = await getNativeBridge().synchronicity.adopt({
      path: fullPath(file),
      select,
      space: file.spaceId,
    });
    if (result.status !== "done") throw rejected();
  }

  async #listSpace(
    space: string,
    policy: string,
    pins: ReadonlySet<string>
  ): Promise<DriveFile[]> {
    const files: DriveFile[] = [];
    let cursor = "";
    for (;;) {
      const page = await getNativeBridge().synchronicity.list({
        limit: LIST_PAGE_SIZE,
        policy,
        space,
        ...(cursor ? { cursor } : {}),
      });
      for (const entry of page.entries) {
        if (entry.kind !== "file") continue;
        files.push(entryToFile(space, entry, pins.has(`${space}/${entry.path}`)));
      }
      // The listing ends with an empty page and no cursor; a short page may
      // still have more behind it, so only the cursor says when to stop.
      if (!page.nextCursor) break;
      if (page.nextCursor === cursor) {
        throw new Error("The node returned a repeated Drive listing cursor.");
      }
      cursor = page.nextCursor;
    }
    return files;
  }
}
