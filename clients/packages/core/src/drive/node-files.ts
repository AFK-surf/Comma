// How Drive reads a Synchronicity node: a node's space is a Drive space (the one this install publishes from its local
// root is its own and never offered for removal), a listing entry is a file with its path's directory as its folder
// and the origin that published the selected version as its device, and a path's versions are the copies other
// origins assert.
import type {
  DriveDevice,
  DriveEntry,
  DriveFile,
  DriveFileVersion,
  DriveSpace,
} from "../contract.ts";
import type { LocalDriveSpace, LocalDriveState, LocalDriveVersion } from "../host.ts";

export const DRIVE_DEFAULT_SPACE_LABEL = "Drive";
/** Where spaces other devices publish are checked out on this one, beside the install's own folder. */
export const DRIVE_SPACES_FOLDER = "Comma Spaces";

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

export const driveFileIdFor = (space: string, path: string) => `synch:${space}:${path}`;

/** "Field Recordings 2026" → "field-recordings-2026"; a space id is a namespace, not a label. */
export function driveSpaceIdFor(
  folderName: string,
  taken: ReadonlySet<string>
): string {
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
export const driveFolderName = (path: string) =>
  path
    .replace(/[/\\]+$/, "")
    .split(/[/\\]/)
    .pop() ?? path;

/** `~/Drive` → `~/Comma Spaces`. */
export const driveSpacesRoot = (localRoot: string) =>
  `${localRoot.replace(/[/\\][^/\\]+$/, "")}/${DRIVE_SPACES_FOLDER}`;

export const fullPath = (file: Pick<DriveFile, "folderPath" | "name">) =>
  file.folderPath ? `${file.folderPath}/${file.name}` : file.name;

/** A path inside a space with no empty, `.`, `..`, backslash or NUL segment. */
export function driveWritePath(
  folderPath: string | undefined,
  name: string
): string | null {
  const segments = [...(folderPath ? folderPath.split("/") : []), name];
  if (
    segments.some(
      (s) => s === "" || s === "." || s === ".." || s.includes("\\") || s.includes("\0")
    )
  )
    return null;
  return segments.join("/");
}

function splitPath(path: string): { folderPath: string | undefined; name: string } {
  const slash = path.lastIndexOf("/");
  return slash === -1
    ? { folderPath: undefined, name: path }
    : { folderPath: path.slice(0, slash), name: path.slice(slash + 1) };
}

export function entryToFile(
  space: string,
  entry: DriveEntry,
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
    // The count is what the listing knows; the copies themselves are read when the versions panel asks.
    ...(entry.versions > 1 ? { versionCount: entry.versions } : {}),
  };
}

/** The spaces a ready node lists, its own default one first even while it has published nothing. */
export function listedSpaces(state: LocalDriveState): LocalDriveSpace[] {
  if (state.spaces.some((space) => space.id === state.defaultSpace))
    return state.spaces;
  return [
    {
      id: state.defaultSpace,
      label: "",
      autoAdopt: true,
      checkoutPath: "",
      sourcePath: state.localRoot,
      replica: false,
      writable: true,
    },
    ...state.spaces,
  ];
}

export function spaceToDrive(
  space: LocalDriveSpace,
  state: LocalDriveState
): DriveSpace {
  const isDefault = space.id === state.defaultSpace;
  const publishedHere = space.sourcePath !== "";
  return {
    id: space.id,
    name: space.label || (isDefault ? DRIVE_DEFAULT_SPACE_LABEL : space.id),
    // Only a space this device publishes has an origin path; a replica's checkout is a copy.
    ...(publishedHere ? { originPath: space.sourcePath } : {}),
    synced: publishedHere
      ? !space.sourcePaused || space.autoAdopt
      : space.replica && space.checkoutPath !== "",
    writable: space.writable,
    ...(isDefault ? { protected: true } : {}),
  };
}

/** Whether an origin stands behind a version; versions name attestors by prefix. */
export const attestedBy = (version: LocalDriveVersion, origin: string) =>
  version.attestors.some((attestor) => origin.startsWith(attestor));

/** The copies of a path, the listed one first, then the others newest first. */
export function versionsToDrive(
  versions: readonly LocalDriveVersion[],
  file: Pick<DriveFile, "id" | "deviceId" | "modifiedAt">,
  knownOrigins: readonly string[]
): DriveFileVersion[] {
  const ordered = versions.toSorted(
    (a, b) =>
      (attestedBy(a, file.deviceId) ? 0 : 1) - (attestedBy(b, file.deviceId) ? 0 : 1) ||
      b.seq - a.seq
  );
  return ordered.map((version, index) => {
    const attestor = version.attestors[0] ?? "";
    return {
      contentsHash: version.root.slice(0, 19),
      ...(version.kind === "tombstone" ? { deleted: true } : {}),
      deviceId: knownOrigins.find((origin) => origin.startsWith(attestor)) ?? attestor,
      id: `${file.id}-v${index}`,
      // The node orders copies by seq, not a clock: every copy but the listed one reads as older.
      modifiedAt: file.modifiedAt - index,
      sizeBytes: version.size,
    };
  });
}

export function devicesOf(
  state: LocalDriveState,
  files: readonly DriveFile[]
): DriveDevice[] {
  const origins = new Set([
    state.origin,
    ...state.origins,
    ...files.map((file) => file.deviceId),
  ]);
  return [...origins].filter(Boolean).map((origin) => ({
    current: origin === state.origin,
    id: origin,
    label: driveDeviceLabel(origin, origin === state.origin, state.deviceName),
  }));
}

const mimeByExtension: Record<string, string> = {
  aac: "audio/aac",
  csv: "text/csv",
  flac: "audio/flac",
  gif: "image/gif",
  jpeg: "image/jpeg",
  jpg: "image/jpeg",
  json: "application/json",
  m4a: "audio/mp4",
  m4v: "video/x-m4v",
  md: "text/markdown",
  mov: "video/quicktime",
  mp3: "audio/mpeg",
  mp4: "video/mp4",
  ogg: "audio/ogg",
  pdf: "application/pdf",
  png: "image/png",
  svg: "image/svg+xml",
  txt: "text/plain",
  wav: "audio/wav",
  webm: "video/webm",
  webp: "image/webp",
};

/** The media type a file's name says. */
export function driveMediaType(name: string): string {
  const extension = name.slice(name.lastIndexOf(".") + 1).toLowerCase();
  return mimeByExtension[extension] ?? "application/octet-stream";
}
