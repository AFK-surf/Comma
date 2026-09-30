import { useSyncExternalStore } from "react";

/**
 * A native surface — an Electron `WebContentsView`, such as the browser in the
 * right sidebar — composites above the renderer's entire DOM, so no z-index
 * lifts a DOM overlay over one.
 *
 * `toastObstructionRight` solves that for overlays that can step aside: a
 * surface publishes how far in from the window's right edge it reaches and the
 * toast stack anchors clear of it. An overlay that owns the whole window —
 * a media preview, a lightbox — has nowhere to step. Those claim suppression
 * instead, and the surface hides itself for as long as the claim is held.
 *
 * Claims are keyed so overlays that open and close independently can each hold
 * one, and listeners are notified only when the resolved state flips.
 */
const claims = new Set<string>();
const listeners = new Set<() => void>();
let suppressed = false;

const publish = () => {
  const next = claims.size > 0;
  if (next === suppressed) return;
  suppressed = next;
  for (const listener of listeners) listener();
};

/** Reports that `claimId` covers the window and native surfaces must hide. */
export const claimNativeSurfaceSuppression = (claimId: string) => {
  if (claims.has(claimId)) return;
  claims.add(claimId);
  publish();
};

/** Drops `claimId`'s claim. Surfaces return once no claim remains. */
export const releaseNativeSurfaceSuppression = (claimId: string) => {
  if (!claims.delete(claimId)) return;
  publish();
};

export const isNativeSurfaceSuppressed = () => suppressed;

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};

/**
 * Whether any DOM overlay currently needs native surfaces out of the way.
 * Server snapshots read `false`: there is no native surface to hide there.
 */
export const useNativeSurfaceSuppressed = () =>
  useSyncExternalStore(subscribe, isNativeSurfaceSuppressed, () => false);
