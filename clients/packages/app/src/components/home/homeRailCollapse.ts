import { useSyncExternalStore } from "react";
import {
  commaHomeRailFoldsOpen,
  type CommaHomeRailFolds,
  type CommaHomeRailName,
} from "../shellGeometry";

/**
 * Which Home rails the reader has shut from their edge handles.
 *
 * Stored in localStorage like the active-workspace scope: shared across this
 * origin's windows, and per device rather than per account — how much room
 * Home should give the chat column is a property of the screen in front of
 * the reader, not of who they are. Safe to lose: a rail merely comes back.
 */
const COLLAPSE_STORAGE_KEY = "comma.homeRailCollapsed";
const COLLAPSE_CHANGED_EVENT = "comma:home-rail-collapse-changed";

let cache: { collapsed: CommaHomeRailFolds; raw: string | null } | undefined;

function readRaw(): string | null {
  try {
    return globalThis.localStorage?.getItem(COLLAPSE_STORAGE_KEY) ?? null;
  } catch {
    return null;
  }
}

/**
 * Identity-stable while the stored payload is unchanged, so the layout's
 * memo boundaries survive every render that does not actually move a rail.
 */
export function readCollapsedHomeRails(): CommaHomeRailFolds {
  const raw = readRaw();
  if (cache && cache.raw === raw) return cache.collapsed;
  let collapsed = commaHomeRailFoldsOpen;
  if (raw !== null) {
    try {
      const parsed: unknown = JSON.parse(raw);
      if (parsed && typeof parsed === "object") {
        const stored = parsed as Partial<Record<CommaHomeRailName, unknown>>;
        const greet = stored.greet === true;
        const tasks = stored.tasks === true;
        if (greet || tasks) collapsed = { greet, tasks };
      }
    } catch {
      // A corrupted payload reads as an open Home and is replaced on the
      // next collapse.
    }
  }
  cache = { collapsed, raw };
  return collapsed;
}

export function toggleCollapsedHomeRail(rail: CommaHomeRailName) {
  const current = readCollapsedHomeRails();
  const next = { ...current, [rail]: !current[rail] };
  const raw = JSON.stringify(next);
  let persisted = false;
  try {
    const storage = globalThis.localStorage;
    if (storage) {
      storage.setItem(COLLAPSE_STORAGE_KEY, raw);
      persisted = true;
    }
  } catch {
    // A blocked write still applies for this session via the cache.
  }
  // A volatile shape must be keyed to what storage still contains. Otherwise
  // the subscriber dispatched below immediately reads the old raw value,
  // misses this cache entry and undoes the user's action. A later genuine
  // storage change still has a different raw value and remains authoritative.
  cache = { collapsed: next, raw: persisted ? raw : readRaw() };
  globalThis.window?.dispatchEvent(new CustomEvent(COLLAPSE_CHANGED_EVENT));
}

export function subscribeCollapsedHomeRails(listener: () => void) {
  if (!globalThis.window) {
    return () => undefined;
  }

  const handleStorage = (event: StorageEvent) => {
    if (event.key === COLLAPSE_STORAGE_KEY) listener();
  };
  window.addEventListener(COLLAPSE_CHANGED_EVENT, listener);
  window.addEventListener("storage", handleStorage);
  return () => {
    window.removeEventListener(COLLAPSE_CHANGED_EVENT, listener);
    window.removeEventListener("storage", handleStorage);
  };
}

export function useCollapsedHomeRails(): CommaHomeRailFolds {
  return useSyncExternalStore(
    subscribeCollapsedHomeRails,
    readCollapsedHomeRails,
    readCollapsedHomeRails
  );
}
