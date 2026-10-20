import { useTopic } from "@comma/core-client";
import { messages } from "@comma/i18n";
import { useCommaLocale } from "@comma/i18n/react";
import type {
  DriveDevice,
  DriveFile as CoreDriveFile,
  DriveFileVersion,
  DriveSpace,
  DriveSyncHistoryEntry,
  DriveSystemRef,
  DriveTransfer,
  DriveValue,
  DriveVersionPolicy,
} from "@comma/core/contract";
import { useEffect, useSyncExternalStore } from "react";

export type {
  DriveDevice,
  DriveFileVersion,
  DriveSpace,
  DriveSyncHistoryEntry,
  DriveSystemRef,
  DriveTransfer,
  DriveVersionPolicy,
};

/**
 * A Drive file as this window shows it: the core's file (`drive`), with the
 * bytes and the small image this window read for its content, when it did.
 */
export type DriveFile = CoreDriveFile & {
  /** The whole file, read for a preview or a download. */
  blob?: Blob;
  /** A small image of it for the list, made from its bytes without keeping them. */
  thumbnail?: Blob;
};

/** The space Comma serves with the workspace's System Files (the core's). */
export const driveSystemSpaceId = "comma-system-files";

export interface DriveSnapshot {
  devices: readonly DriveDevice[];
  files: readonly DriveFile[];
  originDeviceId: string;
  selectedSpaceId: string;
  spaces: readonly DriveSpace[];
  transfers: readonly DriveTransfer[];
  localSyncEnabled: boolean;
  localSyncRoot: string;
  syncHistory: readonly DriveSyncHistoryEntry[];
  node: DriveValue["node"];
  versionPolicy: DriveVersionPolicy;
}

const emptyValue: DriveValue = {
  node: { status: "off" },
  spaces: [],
  files: [],
  devices: [],
  originDeviceId: "",
  versionPolicy: "newest",
  localSyncEnabled: false,
  localSyncRoot: "",
  syncHistory: [],
  transfers: [],
};

/** At most this many files keep the bytes or the small image this window read. */
const KEPT_READS = 64;

const readKey = (file: Pick<CoreDriveFile, "id" | "contentsHash">) =>
  `${file.id}:${file.contentsHash}`;

/** Whether a file can be changed or deleted: its own answer, else its space's. */
export const driveFileWritable = (
  file: CoreDriveFile,
  spaces: readonly DriveSpace[]
): boolean =>
  file.writable ??
  spaces.find((space) => space.id === file.spaceId)?.writable !== false;

/** How many copies of a path the cluster holds; one unless devices disagree. */
export const driveVersionCount = (file: CoreDriveFile) =>
  file.versions?.length ?? file.versionCount ?? 1;

/** `~/Drive` → `~/Comma Spaces`: where spaces other devices publish are checked out here. */
export const driveSpacesRoot = (localRoot: string) =>
  `${localRoot.replace(/[/\\][^/\\]+$/, "")}/Comma Spaces`;

/** The file's path inside its space. */
export const drivePath = (file: Pick<CoreDriveFile, "folderPath" | "name">) =>
  file.folderPath ? `${file.folderPath}/${file.name}` : file.name;

/**
 * What this window holds of Drive beside the core's `drive`: the space it
 * shows and the bytes it read. Everything else — spaces, files, devices,
 * sync, transfers — is the core's, the same on every window.
 */
export class DriveStore {
  #listeners = new Set<() => void>();
  #core: DriveValue = emptyValue;
  #selected = "";
  /** Read bytes and small images by file content, least recently kept first. */
  #blobs = new Map<string, Blob>();
  #thumbnails = new Map<string, Blob>();
  #snapshot: DriveSnapshot | undefined;
  #named: { from: readonly DriveSpace[]; to: readonly DriveSpace[] } | undefined;

  subscribe = (listener: () => void) => {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  };

  getSnapshot = (): DriveSnapshot => {
    this.#snapshot ??= this.#make();
    return this.#snapshot;
  };

  #make(): DriveSnapshot {
    const core = this.#core;
    // The core leaves System Files unnamed: its name is in the reader's language.
    if (this.#named?.from !== core.spaces)
      this.#named = {
        from: core.spaces,
        to: core.spaces.map((space) =>
          space.id === driveSystemSpaceId && !space.name
            ? { ...space, name: messages.drive_system_files_space() }
            : space
        ),
      };
    const spaces = this.#named.to;
    // The space shown: the one picked while it is there, else the first a device publishes, else System Files.
    const selectedSpaceId = spaces.some((space) => space.id === this.#selected)
      ? this.#selected
      : (spaces.find((space) => space.id !== driveSystemSpaceId)?.id ??
        spaces[0]?.id ??
        "");
    return {
      devices: core.devices,
      files: core.files.map((file) => {
        const key = readKey(file);
        const blob = this.#blobs.get(key);
        const thumbnail = this.#thumbnails.get(key);
        return blob || thumbnail
          ? { ...file, ...(blob ? { blob } : {}), ...(thumbnail ? { thumbnail } : {}) }
          : file;
      }),
      originDeviceId: core.originDeviceId,
      selectedSpaceId,
      spaces,
      transfers: core.transfers,
      localSyncEnabled: core.localSyncEnabled,
      localSyncRoot: core.localSyncRoot,
      syncHistory: core.syncHistory,
      node: core.node,
      versionPolicy: core.versionPolicy,
    };
  }

  /** The core's `drive`, as it changes. */
  setCore(value: DriveValue) {
    if (value === this.#core) return;
    this.#core = value;
    this.#commit();
  }

  /** The reader's language changed: names the store gives are read again. */
  relabel() {
    this.#named = undefined;
    this.#commit();
  }

  fileById(fileId: string): DriveFile | undefined {
    return this.getSnapshot().files.find((file) => file.id === fileId);
  }

  selectSpace(spaceId: string) {
    if (this.#selected === spaceId) return;
    this.#selected = spaceId;
    this.#commit();
  }

  /** Bytes read for a file's content; they go with it while it keeps that content. */
  attachBlob(file: Pick<CoreDriveFile, "id" | "contentsHash">, blob: Blob) {
    keep(this.#blobs, readKey(file), blob);
    this.#commit();
  }

  attachThumbnail(file: Pick<CoreDriveFile, "id" | "contentsHash">, thumbnail: Blob) {
    keep(this.#thumbnails, readKey(file), thumbnail);
    this.#commit();
  }

  #commit() {
    this.#snapshot = undefined;
    for (const listener of this.#listeners) listener();
  }
}

/** Keeps `value` at `key` as the most recent, dropping the oldest past `KEPT_READS`. */
function keep(map: Map<string, Blob>, key: string, value: Blob) {
  map.delete(key);
  map.set(key, value);
  for (const oldest of map.keys()) {
    if (map.size <= KEPT_READS) break;
    map.delete(oldest);
  }
}

let sharedStore: DriveStore | undefined;

/** One store per window, so the space shown and the bytes read survive route changes. */
export function getDriveStore(): DriveStore {
  sharedStore ??= new DriveStore();
  return sharedStore;
}

/** Lets the next `getDriveStore` start over. */
export function resetDriveStoreForTest() {
  sharedStore = undefined;
}

/** The window's Drive while it is shown: the core's `drive` (read while shown), with this window's own state. */
export function useDriveSnapshot(store: DriveStore, shown = true): DriveSnapshot {
  const { value } = useTopic(shown ? { topic: "drive" } : null);
  const locale = useCommaLocale();
  useEffect(() => {
    if (value) store.setCore(value);
  }, [store, value]);
  useEffect(() => store.relabel(), [store, locale]);
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
 * will draw.
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

const mediaTypeByExtension: Record<string, string> = {
  aac: "audio/aac",
  flac: "audio/flac",
  m4a: "audio/mp4",
  m4v: "video/x-m4v",
  mov: "video/quicktime",
  mp3: "audio/mpeg",
  mp4: "video/mp4",
  ogg: "audio/ogg",
  wav: "audio/wav",
  webm: "video/webm",
};

/** The media type an audio or video stream is served with, by the file's name. */
export const driveStreamMediaType = (name: string) =>
  mediaTypeByExtension[driveFileExtension(name)] ?? "application/octet-stream";
