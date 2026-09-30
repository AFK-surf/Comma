import { useEffect } from "react";
import type { SynchronicityState } from "@comma/native-bridge";
import type { CommaApiClient } from "../../api/client";
import type { DriveFile, DriveFileVersion, DriveStore } from "./driveStore";
import {
  DriveSynchronicityBackend,
  driveInlineReadMaxBytes,
  driveSynchronicityAvailable,
  type DriveBackend,
} from "./driveSynchronicityBackend";

/**
 * The one backend behind Drive in the Electron client, where Main runs the
 * bundled synchronicity node. Elsewhere there is none and the store keeps its
 * demo data, so every caller treats the backend as optional.
 */
let sharedBackend: DriveSynchronicityBackend | undefined;

export function getDriveBackend(): DriveSynchronicityBackend | undefined {
  if (!driveSynchronicityAvailable()) return undefined;
  sharedBackend ??= new DriveSynchronicityBackend();
  return sharedBackend;
}

// One re-read per backend at a time: a focus and a timer landing together
// share it, while a changed device/policy queues one latest follow-up instead
// of letting the stale in-flight result overwrite the new selection.
interface DriveRefreshState {
  generation: number;
  promise?: Promise<void> | undefined;
  store: DriveStore;
}

const refreshStates = new WeakMap<DriveBackend, DriveRefreshState>();

/**
 * Re-reads the whole tree — after publishing or deleting through the node,
 * or because the folder on disk changed behind the app's back. The listing
 * shows the version the store's policy selects, so the policy rides along.
 */
export function refreshDrive(store: DriveStore, backend: DriveBackend): Promise<void> {
  const state = refreshStates.get(backend) ?? { generation: 0, store };
  state.generation += 1;
  state.store = store;
  refreshStates.set(backend, state);
  state.promise ??= (async () => {
    let handled = 0;
    while (handled !== state.generation) {
      handled = state.generation;
      const requestedStore = state.store;
      const snapshot = requestedStore.getSnapshot();
      const selectedDevice = snapshot.devices.find(
        (device) => device.id === snapshot.originDeviceId
      );
      try {
        const loaded = await backend.load({
          ...(selectedDevice && !selectedDevice.current
            ? { originDeviceId: selectedDevice.id }
            : {}),
          policy: snapshot.versionPolicy,
        });
        if (handled === state.generation) requestedStore.load(loaded, snapshot.files);
      } catch (error) {
        // A superseded read cannot fail the newer request; immediately retry
        // with the latest device/policy. The current request still reports its
        // own failure to the caller.
        if (handled === state.generation) throw error;
      }
    }
  })().finally(() => {
    state.promise = undefined;
  });
  return state.promise;
}

// One fetch per file at a time: a preview and a download asking together
// share the read, as do the two mounts of a StrictMode effect.
const blobReads = new Map<string, Promise<Blob>>();

/** The file's bytes, fetched from the node on first use and kept on the file after. */
export function ensureDriveFileBlob(
  store: DriveStore,
  backend: DriveBackend,
  file: DriveFile
): Promise<Blob> {
  if (file.blob) return Promise.resolve(file.blob);
  const readKey = `${file.id}:${file.deviceId}:${file.contentsHash}`;
  const pending = blobReads.get(readKey);
  if (pending) return pending;
  const read = backend
    .readFile(file)
    .then((blob) => {
      store.attachBlob(file.id, blob, file.contentsHash);
      return blob;
    })
    .finally(() => {
      blobReads.delete(readKey);
    });
  blobReads.set(readKey, read);
  return read;
}

/** Thumbnails come from the whole file; past this size the list keeps the glyph until the file is opened. */
const THUMBNAIL_SOURCE_MAX_BYTES = driveInlineReadMaxBytes;
/** Twice the 24px row icon, so it stays crisp on a 2× display. */
const THUMBNAIL_EDGE_PX = 48;
/** An SVG this small is its own thumbnail, drawn as vectors; a larger one is rasterized like the rest. */
const SVG_THUMBNAIL_MAX_BYTES = 256 * 1024;

const thumbnailReads = new Map<string, Promise<void>>();

/**
 * A small image of an image file for the list, without keeping the file:
 * the bytes are read from the node, drawn down to the row's size, and only
 * that stays on the file. An SVG small enough is kept as it is — its
 * content is what the row should show, and vectors draw at any size.
 * A file already here draws from its own bytes, so nothing is fetched.
 */
export function ensureDriveFileThumbnail(
  store: DriveStore,
  backend: DriveBackend,
  file: DriveFile
): Promise<void> {
  if (file.thumbnail || file.blob) return Promise.resolve();
  if (file.sizeBytes > THUMBNAIL_SOURCE_MAX_BYTES) return Promise.resolve();
  const readKey = `${file.id}:${file.deviceId}:${file.contentsHash}`;
  const pending = thumbnailReads.get(readKey);
  if (pending) return pending;
  const read = backend
    .readFile(file)
    .then(async (bytes) => {
      const thumbnail = await thumbnailOf(bytes);
      if (thumbnail) store.attachThumbnail(file.id, thumbnail, file.contentsHash);
    })
    .finally(() => {
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

const versionReads = new Map<string, Promise<readonly DriveFileVersion[]>>();

/**
 * The copies behind a listing's version count, fetched when the panel that
 * shows them opens. A file with one copy has nothing to fetch.
 */
export function ensureDriveFileVersions(
  store: DriveStore,
  backend: DriveBackend,
  file: DriveFile
): Promise<readonly DriveFileVersion[]> {
  if (file.versions) return Promise.resolve(file.versions);
  if ((file.versionCount ?? 1) < 2) return Promise.resolve([]);
  const readKey = `${file.id}:${file.contentsHash}`;
  const pending = versionReads.get(readKey);
  if (pending) return pending;
  const read = backend
    .versions(
      file,
      store.getSnapshot().devices.map((device) => device.id)
    )
    .then((versions) => {
      store.setFileVersions(file.id, versions, file.contentsHash);
      return versions;
    })
    .finally(() => {
      versionReads.delete(readKey);
    });
  versionReads.set(readKey, read);
  return read;
}

/**
 * Binds a fresh node to the Workspace's network. Comma provisions one network
 * per Workspace; enrolling this node's key answers with the zone that names
 * it, which is how the node finds the Workspace's other devices. A node
 * already named, or a Workspace whose network is not ready yet, is left as
 * it is — the node works on its own until then.
 */
export async function enrollDriveDevice(
  api: CommaApiClient,
  backend: DriveSynchronicityBackend,
  state: SynchronicityState
): Promise<void> {
  if (state.domain || !state.origin.startsWith("key:")) return;
  const status = await api.getSynchronicityStatus();
  if (status.status !== "ready") return;
  const nk = state.origin.slice(4);
  const device = await api.enrollSynchronicityDevice({
    label: enrollmentDeviceLabel(state.deviceName, nk),
    nk,
  });
  await backend.setDomain(device.domain);
}

/**
 * The membership zone uses this value as a DNS label, while an OS device name
 * may contain spaces, punctuation, Unicode, or collide with another laptop in
 * the same Workspace. Keep the readable ASCII stem and add a deterministic
 * public-key suffix; the private node key never crosses this boundary.
 */
function enrollmentDeviceLabel(deviceName: string | undefined, nk: string): string {
  const suffix =
    nk
      .toLowerCase()
      .replace(/[^a-z0-9]/g, "")
      .slice(0, 12) || "node";
  const stem = (deviceName || "comma-desktop")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  const maxStemLength = 63 - suffix.length - 1;
  const boundedStem = (stem || "comma-desktop")
    .slice(0, maxStemLength)
    .replace(/-+$/g, "");
  return `${boundedStem || "comma"}-${suffix}`;
}

/** Brings a node that could not start down and up again, and reads it afresh if it made it. */
export async function restartDrive(
  store: DriveStore,
  backend: DriveSynchronicityBackend
): Promise<SynchronicityState> {
  store.setNodeStatus({ status: "starting" });
  const state = await backend.restart();
  store.setNodeStatus(nodeStatusOf(state));
  if (state.status === "ready") await refreshDrive(store, backend);
  return state;
}

export function nodeStatusOf(state: SynchronicityState) {
  return state.status === "ready"
    ? { status: "ready" as const }
    : state.status === "starting"
      ? { status: "starting" as const }
      : { reason: state.reason ?? "", status: "error" as const };
}

const READY_POLL_MS = 1500;
const REFRESH_MS = 20_000;

/**
 * Loads the tree once the node reports ready, then keeps it current: the
 * folder on disk changes behind the app's back (Finder, another device), so
 * the listing is re-read when the window comes back into focus and on a
 * slow timer in between. The node starts with the app and takes a moment;
 * the store carries what it reports meanwhile, so the list can say so
 * instead of standing empty. A node that cannot start is reported the
 * same way, with its reason.
 */
export function useDriveBackendLoad(
  store: DriveStore,
  backend: DriveSynchronicityBackend | undefined,
  onReady: (state: SynchronicityState) => void
) {
  useEffect(() => {
    if (!backend) return;
    let cancelled = false;
    let polling = false;
    let armed = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let interval: ReturnType<typeof setInterval> | undefined;
    const refresh = () => {
      void refreshDrive(store, backend).catch(() => {});
    };
    const arm = () => {
      if (armed) return;
      armed = true;
      window.addEventListener("focus", refresh);
      interval = setInterval(refresh, REFRESH_MS);
    };
    const poll = async () => {
      polling = true;
      try {
        const state = await backend.state();
        if (cancelled) return;
        store.setNodeStatus(nodeStatusOf(state));
        if (state.status === "ready") {
          await refreshDrive(store, backend);
          if (cancelled) return;
          arm();
          onReady(state);
          return;
        }
        if (state.status === "starting") {
          timer = setTimeout(() => void poll(), READY_POLL_MS);
        }
      } finally {
        polling = false;
      }
    };
    void poll();
    // A restart (`restartDrive`) puts the node back to starting; the poll
    // picks it up from there, and arms the refresh loop once it is ready.
    const unsubscribe = store.subscribe(() => {
      if (!polling && !armed && store.getSnapshot().node.status === "starting") {
        void poll();
      }
    });
    return () => {
      cancelled = true;
      unsubscribe();
      if (timer) clearTimeout(timer);
      if (interval) clearInterval(interval);
      window.removeEventListener("focus", refresh);
    };
    // The ready callback is read once per attempt; re-subscribing on every
    // render of it would restart the poll.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [backend, store]);
}
