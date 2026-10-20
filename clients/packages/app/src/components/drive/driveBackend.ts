import type { CallFn } from "@comma/core-client";
import { getNativeBridge } from "@comma/native-bridge";
import { useEffect } from "react";
import {
  drivePath,
  driveSystemSpaceId,
  type DriveFile,
  type DriveFileVersion,
  type DriveStore,
} from "./driveStore";

/**
 * What a window does with Drive files beyond what the core keeps (`drive`):
 * their bytes, read through the core and kept with the window's store for a
 * preview, and — in the Electron client, where Main runs the Drive node —
 * the things only the device can do with a file on its disk: stream it and
 * open the folder.
 */

/** Only in the Electron client: the bundled node is what the bridge exposes. */
export function driveNodeAvailable() {
  return getNativeBridge().platform === "electron";
}

// One read per file at a time: a preview and a download asking together share it.
const blobReads = new Map<string, Promise<Blob>>();

/** The file's bytes, read through the core on first use and kept with the window's store after. */
export function ensureDriveFileBlob(
  store: DriveStore,
  call: CallFn,
  file: DriveFile
): Promise<Blob> {
  if (file.blob) return Promise.resolve(file.blob);
  const readKey = `${file.id}:${file.contentsHash}`;
  const pending = blobReads.get(readKey);
  if (pending) return pending;
  const read = call("drive.read", { file: file.id })
    .then(({ bytes, mediaType }) => {
      const blob = new Blob([bytes as Uint8Array<ArrayBuffer>], { type: mediaType });
      store.attachBlob(file, blob);
      return blob;
    })
    .finally(() => {
      blobReads.delete(readKey);
    });
  blobReads.set(readKey, read);
  return read;
}

/**
 * Thumbnails come from the whole file, so a folder of large photos takes its
 * turn: this many reads run at once and the rest wait.
 */
const THUMBNAIL_READS_AT_ONCE = 2;
/** Twice the 24px row icon, so it stays crisp on a 2× display. */
const THUMBNAIL_EDGE_PX = 48;
/** An SVG this small is its own thumbnail, drawn as vectors; a larger one is rasterized like the rest. */
const SVG_THUMBNAIL_MAX_BYTES = 256 * 1024;

const thumbnailReads = new Map<string, Promise<void>>();
let thumbnailReadsRunning = 0;
const thumbnailReadsWaiting: (() => void)[] = [];

async function inThumbnailTurn<T>(work: () => Promise<T>): Promise<T> {
  if (thumbnailReadsRunning < THUMBNAIL_READS_AT_ONCE) thumbnailReadsRunning += 1;
  else await new Promise<void>((resolve) => thumbnailReadsWaiting.push(resolve));
  try {
    return await work();
  } finally {
    // A finished read hands its turn straight to the next one waiting.
    const next = thumbnailReadsWaiting.shift();
    if (next) next();
    else thumbnailReadsRunning -= 1;
  }
}

/**
 * A small image of an image file for the list, without keeping the file: the
 * bytes are read through the core, drawn down to the row's size, and only
 * that stays. An SVG small enough is kept as it is. A file already here draws
 * from its own bytes, so nothing is read.
 */
export function ensureDriveFileThumbnail(
  store: DriveStore,
  call: CallFn,
  file: DriveFile
): Promise<void> {
  if (file.thumbnail || file.blob || file.spaceId === driveSystemSpaceId)
    return Promise.resolve();
  const readKey = `${file.id}:${file.contentsHash}`;
  const pending = thumbnailReads.get(readKey);
  if (pending) return pending;
  const read = inThumbnailTurn(async () => {
    const { bytes, mediaType } = await call("drive.read", { file: file.id });
    const thumbnail = await thumbnailOf(
      new Blob([bytes as Uint8Array<ArrayBuffer>], { type: mediaType })
    );
    if (thumbnail) store.attachThumbnail(file, thumbnail);
  }).finally(() => {
    thumbnailReads.delete(readKey);
  });
  thumbnailReads.set(readKey, read);
  return read;
}

async function thumbnailOf(bytes: Blob): Promise<Blob | undefined> {
  if (bytes.type === "image/svg+xml" && bytes.size <= SVG_THUMBNAIL_MAX_BYTES)
    return bytes;
  const bitmap = await createImageBitmap(bytes);
  try {
    const scale = Math.min(
      1,
      THUMBNAIL_EDGE_PX / Math.max(bitmap.width, bitmap.height)
    );
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));
    const canvas = new OffscreenCanvas(width, height);
    const context = canvas.getContext("2d");
    if (!context) return undefined;
    context.drawImage(bitmap, 0, 0, width, height);
    return await canvas.convertToBlob({ type: "image/png" });
  } finally {
    bitmap.close();
  }
}

/** The copies behind a listing's version count, read when the panel that shows them opens. */
export function ensureDriveFileVersions(
  call: CallFn,
  file: DriveFile
): Promise<readonly DriveFileVersion[]> {
  if (file.versions) return Promise.resolve(file.versions);
  if ((file.versionCount ?? 1) < 2) return Promise.resolve([]);
  return call("drive.versions", { file: file.id });
}

/** Drive reads again when a window comes back to the front: the folder changes behind the app. */
export function useDriveRefreshOnFocus(call: CallFn, enabled: boolean) {
  useEffect(() => {
    if (!enabled) return;
    const refresh = () => void call("drive.refresh", {}).catch(() => undefined);
    window.addEventListener("focus", refresh);
    return () => window.removeEventListener("focus", refresh);
  }, [call, enabled]);
}

/** A file's version on the device that published the copy listed. */
const nodeSelect = (file: DriveFile) => ({
  path: drivePath(file),
  policy: `origin=${file.deviceId}`,
  space: file.spaceId,
});

/** A URL that plays an audio or video file in ranges, pinned to its current content (Electron). */
export async function openDriveStream(
  file: DriveFile,
  contentType: string
): Promise<string> {
  const result = await getNativeBridge().synchronicity.openStream({
    contentType,
    ...nodeSelect(file),
  });
  if (result.status !== "opened") throw new Error("Drive streams are unavailable.");
  return result.url;
}

/** Opens the Main-owned local Drive root without accepting a renderer path. */
export async function openDriveLocalRoot(): Promise<boolean> {
  return (await getNativeBridge().synchronicity.openLocalRoot()).status === "opened";
}
