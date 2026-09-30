import { useCallback, useEffect, useSyncExternalStore } from "react";
import type { CommaApiClient, CommaTaskLabelCatalog } from "../../../../api";

export type TaskLabelsCatalogState = {
  catalog: CommaTaskLabelCatalog | undefined;
  /** Re-read the catalog; the newest request wins. */
  refresh: () => Promise<void>;
  /** Adopt a catalog a mutation just returned, without another round trip. */
  replace: (catalog: CommaTaskLabelCatalog) => void;
};

/** The catalog together with its read status, for the surface that shows it. */
export type TaskLabelsCatalogStatusState = TaskLabelsCatalogState & {
  error: boolean;
  /**
   * The first read is in flight. A re-read of labels already in hand
   * revalidates them in place and is not reported: its readers keep showing
   * the catalog, and the newest request still wins.
   */
  loading: boolean;
};

type Status = Pick<TaskLabelsCatalogStatusState, "catalog" | "error" | "loading">;

type Entry = {
  catalog: CommaTaskLabelCatalog | undefined;
  /** `catalog` serialized: a read that returns the same labels keeps the object. */
  catalogJson: string | undefined;
  error: boolean;
  // Monotonic request counter: a response only lands if it is still the
  // newest request, so a slow read never overwrites a newer one.
  generation: number;
  listeners: Set<() => void>;
  loading: boolean;
  status: Status;
};

const EMPTY_STATUS: Status = { catalog: undefined, error: false, loading: false };
const stores = new WeakMap<CommaApiClient, Map<string, Entry>>();

/**
 * One catalog per Group, shared by every surface that shows labels — Settings,
 * the Task panel, the chat's confirmation card, card chips and the inline
 * Task's hover card — so a read serves all of them and a mutation's returned
 * catalog updates all of them at once.
 */
function entryFor(api: CommaApiClient, groupId: string): Entry {
  let byGroup = stores.get(api);
  if (!byGroup) {
    byGroup = new Map();
    stores.set(api, byGroup);
  }
  let entry = byGroup.get(groupId);
  if (!entry) {
    entry = {
      catalog: undefined,
      catalogJson: undefined,
      error: false,
      generation: 0,
      listeners: new Set(),
      loading: false,
      status: EMPTY_STATUS,
    };
    byGroup.set(groupId, entry);
  }
  return entry;
}

/**
 * Applies a change and notifies only when a reader could see it. Readers hold
 * these values by identity, and surfaces re-read the catalog whenever they
 * open, so a read that confirms the labels already held keeps the catalog
 * object: otherwise each page switch re-rendered every label reader, hidden
 * Home included.
 */
function update(
  entry: Entry,
  next: {
    catalog?: CommaTaskLabelCatalog | undefined;
    error?: boolean;
    loading?: boolean;
  }
) {
  let { catalog } = entry;
  if (next.catalog !== undefined && next.catalog !== entry.catalog) {
    const catalogJson = JSON.stringify(next.catalog);
    if (catalogJson !== entry.catalogJson) {
      catalog = next.catalog;
      entry.catalogJson = catalogJson;
    }
  }
  const error = next.error ?? entry.error;
  const loading = next.loading ?? entry.loading;
  if (catalog === entry.catalog && error === entry.error && loading === entry.loading) {
    return;
  }
  entry.catalog = catalog;
  entry.error = error;
  entry.loading = loading;
  entry.status = { catalog, error, loading };
  for (const listener of entry.listeners) listener();
}

export async function loadTaskLabelsCatalog(api: CommaApiClient, groupId: string) {
  const entry = entryFor(api, groupId);
  const request = ++entry.generation;
  update(entry, { error: false, loading: entry.catalog === undefined });
  try {
    const next = await api.listTaskLabels(groupId);
    if (request === entry.generation) update(entry, { catalog: next, loading: false });
  } catch {
    if (request === entry.generation) update(entry, { error: true, loading: false });
  }
}

/** Read the current shared snapshot without starting another request. */
export function readTaskLabelsCatalog(api: CommaApiClient, groupId: string) {
  return entryFor(api, groupId).catalog;
}

export function replaceTaskLabelsCatalog(
  api: CommaApiClient,
  groupId: string,
  next: CommaTaskLabelCatalog
) {
  const entry = entryFor(api, groupId);
  entry.generation++;
  update(entry, { catalog: next, error: false, loading: false });
}

const readCatalog = (entry: Entry) => entry.catalog;
const readStatus = (entry: Entry) => entry.status;

/** Subscribes to one value of the Group's entry, re-rendering only when it changes. */
function useEntryValue<T>(
  api: CommaApiClient | undefined,
  groupId: string | undefined,
  read: (entry: Entry) => T,
  empty: T
) {
  const subscribe = useCallback(
    (listener: () => void) => {
      if (!api || !groupId) return () => undefined;
      const entry = entryFor(api, groupId);
      entry.listeners.add(listener);
      return () => {
        entry.listeners.delete(listener);
      };
    },
    [api, groupId]
  );
  return useSyncExternalStore(
    subscribe,
    () => (api && groupId ? read(entryFor(api, groupId)) : empty),
    () => empty
  );
}

function useCatalogActions(
  api: CommaApiClient | undefined,
  groupId: string | undefined
) {
  const refresh = useCallback(
    () => (api && groupId ? loadTaskLabelsCatalog(api, groupId) : Promise.resolve()),
    [api, groupId]
  );
  const replace = useCallback(
    (next: CommaTaskLabelCatalog) => {
      if (api && groupId) replaceTaskLabelsCatalog(api, groupId, next);
    },
    [api, groupId]
  );
  return { refresh, replace };
}

function useReadWhenEnabled(
  api: CommaApiClient | undefined,
  groupId: string | undefined,
  enabled: boolean,
  refreshKey?: string
) {
  useEffect(() => {
    if (!enabled || !api || !groupId) return;
    void loadTaskLabelsCatalog(api, groupId);
  }, [api, enabled, groupId, refreshKey]);
}

/**
 * The Group's label catalog for a surface that wants it current: it reads
 * once each time it is enabled (a Task panel unfolding, the Tasks board
 * opening), and every mutating API call already returns the fresh catalog, so
 * callers hand it back through `replace` instead of re-fetching. Only the
 * catalog is subscribed: a read in flight elsewhere does not render it.
 */
export function useTaskLabelsCatalog(
  api: CommaApiClient | undefined,
  groupId: string | undefined,
  enabled = true,
  refreshKey?: string
): TaskLabelsCatalogState {
  const catalog = useEntryValue(api, groupId, readCatalog, undefined);
  useReadWhenEnabled(api, groupId, enabled, refreshKey);
  return { catalog, ...useCatalogActions(api, groupId) };
}

/**
 * The catalog with its read status, for the surface that shows loading and
 * failure (Settings › Labels). It reads each time it is enabled.
 */
export function useTaskLabelsCatalogStatus(
  api: CommaApiClient | undefined,
  groupId: string | undefined,
  enabled = true
): TaskLabelsCatalogStatusState {
  const status = useEntryValue(api, groupId, readStatus, EMPTY_STATUS);
  useReadWhenEnabled(api, groupId, enabled);
  return { ...status, ...useCatalogActions(api, groupId) };
}

/**
 * The same catalog for the many small readers (an inline Task's hover card):
 * reads only when nothing is known yet, otherwise rides on what the Group's
 * other surfaces already loaded.
 */
export function useTaskLabelsCatalogShared(
  api: CommaApiClient | undefined,
  groupId: string | undefined
): TaskLabelsCatalogState {
  const catalog = useEntryValue(api, groupId, readCatalog, undefined);
  useEffect(() => {
    if (!api || !groupId) return;
    const entry = entryFor(api, groupId);
    if (entry.catalog === undefined && !entry.loading)
      void loadTaskLabelsCatalog(api, groupId);
  }, [api, groupId]);
  return { catalog, ...useCatalogActions(api, groupId) };
}
