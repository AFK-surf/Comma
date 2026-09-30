import type { CommaApiClient, CommaConversation } from "../../api";

// Modeled by tla/salix/TaskReferenceCache.tla (no recovery liveness claim).
// One bounded, session-owned summary cache and one request lane per API client.
// Only server responses populate facts; notifications merely invalidate them.
type Entry = {
  value?: CommaConversation;
  pending?: boolean;
  failed?: boolean;
  stale?: boolean;
};
type Store = {
  entries: Map<string, Entry>;
  queued: Set<string>;
  listeners: Set<() => void>;
  revision: number;
  generation: number;
  running: boolean;
};
const stores = new WeakMap<CommaApiClient, Store>();
const observedProjections = new WeakMap<CommaApiClient, object>();
// Existing owner snapshots are invalidation hints for references outside its
// loaded page too. Multiple mounted cards share this single invalidation.
export function observeTaskProjection(api: CommaApiClient, projection: object) {
  if (observedProjections.get(api) === projection) return;
  const previous = observedProjections.get(api);
  observedProjections.set(api, projection);
  if (previous) invalidateTaskSummaries(api);
}
const keyFor = (group: string, id: string) => `${group}\u0000${id}`;
function storeFor(api: CommaApiClient): Store {
  let store = stores.get(api);
  if (!store) {
    store = {
      entries: new Map(),
      queued: new Set(),
      listeners: new Set(),
      revision: 0,
      generation: 0,
      running: false,
    };
    stores.set(api, store);
  }
  return store;
}
function publish(store: Store) {
  store.revision++;
  for (const listener of store.listeners) listener();
}
export function subscribeTaskSummaries(api: CommaApiClient, listener: () => void) {
  const store = storeFor(api);
  store.listeners.add(listener);
  return () => {
    store.listeners.delete(listener);
  };
}
export function taskSummaryRevision(api: CommaApiClient) {
  return storeFor(api).revision;
}
// Every change replaces an entry, so a read returns the same object until the
// entry changes and readers can compare what they got by identity.
const unconfirmedViews = new WeakMap<Entry, CommaConversation>();
export function readTaskSummary(api: CommaApiClient, group: string, id: string) {
  const entry = storeFor(api).entries.get(keyFor(group, id));
  if (!entry?.value) return undefined;
  if (!(entry.stale || entry.pending || entry.failed)) return entry.value;
  let view = unconfirmedViews.get(entry);
  if (!view) {
    view = { ...entry.value, archive_availability: undefined };
    unconfirmedViews.set(entry, view);
  }
  return view;
}
export function invalidateTaskSummaries(api: CommaApiClient) {
  const store = storeFor(api);
  store.generation++;
  for (const [key, entry] of store.entries) {
    if (entry.value) store.entries.set(key, { value: entry.value, stale: true });
    else store.entries.delete(key);
  }
  store.queued.clear();
  publish(store);
}
export function requestTaskSummary(api: CommaApiClient, group: string, id: string) {
  const store = storeFor(api),
    key = keyFor(group, id);
  const previous = store.entries.get(key);
  if ((previous && !previous.stale) || (!previous && store.entries.size >= 1_000))
    return;
  store.entries.set(key, { ...previous, stale: false, pending: true });
  store.queued.add(key);
  queueMicrotask(() => {
    void drain(api, store);
  });
}
async function drain(api: CommaApiClient, store: Store) {
  if (store.running) return;
  store.running = true;
  try {
    while (store.queued.size) {
      const first = store.queued.values().next().value!;
      const group = first.split("\u0000")[0]!;
      const keys = [...store.queued]
        .filter((key) => key.startsWith(`${group}\u0000`))
        .slice(0, 50);
      for (const key of keys) store.queued.delete(key);
      const generation = store.generation;
      try {
        const summaries = await api.getTaskSummaries(
          group,
          keys.map((key) => key.split("\u0000")[1]!)
        );
        if (generation !== store.generation) continue;
        for (const key of keys)
          store.entries.set(key, {
            ...store.entries.get(key),
            pending: false,
            failed: true,
          });
        for (const value of summaries)
          if (keys.includes(keyFor(group, value.id))) {
            const key = keyFor(group, value.id);
            const previous = store.entries.get(key)?.value;
            if (!previous || (value.updated_at ?? 0) >= (previous.updated_at ?? 0))
              store.entries.set(key, { value });
          }
      } catch {
        if (generation !== store.generation) continue;
        for (const key of keys)
          store.entries.set(key, {
            ...store.entries.get(key),
            pending: false,
            failed: true,
          });
      }
      // At most 1,000 session references; unknown overflow keeps its message
      // fallback. Known archived facts survive failed refreshes and invalidation.
      publish(store);
    }
  } finally {
    store.running = false;
  }
}

/** Preserve committed facts before an owner refresh can fail or invalidate. */
export function recordTaskSummary(api: CommaApiClient, value: CommaConversation) {
  const store = storeFor(api),
    key = keyFor(value.group_id, value.id);
  const previous = store.entries.get(key)?.value;
  if (previous && (previous.updated_at ?? 0) >= (value.updated_at ?? 0)) return;
  if (!previous && store.entries.size >= 1_000) return;
  store.entries.set(key, { value });
  publish(store);
}
