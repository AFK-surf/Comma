import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type SetStateAction,
} from "react";
import { createBftApi, type BftApi } from "./api";

export const ApiContext = createContext<BftApi>(createBftApi());

export const useApi = () => useContext(ApiContext);

export type Resource<T> =
  | { state: "loading" }
  | { state: "ready"; data: T }
  | { state: "error"; error: unknown };

/**
 * The last data of recently read resources, so a page opened again shows it at
 * once while it is read again. Least recently used entries go first. `clear()`
 * also drops reads that started before it, so a write is never undone by a read
 * that raced it.
 */
export class ResourceCache {
  private readonly entries = new Map<string, unknown>();
  private generation = 0;

  constructor(private readonly limit = 50) {}

  /** The cached data for `key`, marked as just used. */
  get(key: string): { data: unknown } | undefined {
    if (!this.entries.has(key)) return undefined;
    const data = this.entries.get(key);
    this.entries.delete(key);
    this.entries.set(key, data);
    return { data };
  }

  /** Like `get`, without changing the eviction order (safe during render). */
  peek(key: string): { data: unknown } | undefined {
    return this.entries.has(key) ? { data: this.entries.get(key) } : undefined;
  }

  /** The generation a read started in; pass it back to `set`. */
  get version() {
    return this.generation;
  }

  /**
   * Stores `data` read during `version` and returns what callers should show:
   * the cached object itself when the new read is equal to it, so pages keep
   * their state (loaded pages, open forms) across a refresh that changed nothing.
   */
  set<T>(key: string, data: T, version = this.generation): T {
    if (version !== this.generation) return data;
    const previous = this.entries.get(key);
    const kept =
      this.entries.has(key) && sameData(previous, data) ? (previous as T) : data;
    this.entries.delete(key);
    this.entries.set(key, kept);
    while (this.entries.size > this.limit) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
    }
    return kept;
  }

  delete(key: string) {
    this.entries.delete(key);
  }

  clear() {
    this.entries.clear();
    this.generation += 1;
  }

  get size() {
    return this.entries.size;
  }
}

const sameData = (a: unknown, b: unknown) =>
  a === b || JSON.stringify(a) === JSON.stringify(b);

const dataIds = new WeakMap<object, number>();
let lastDataId = 0;

/**
 * One number per data object, as a React key: a form that starts from its data
 * starts over when a read brings changed data, and keeps its edits otherwise.
 */
export function dataKey(data: unknown) {
  if (typeof data !== "object" || data === null) return 0;
  let id = dataIds.get(data);
  if (id === undefined) {
    lastDataId += 1;
    id = lastDataId;
    dataIds.set(data, id);
  }
  return id;
}

/** The cache of the organization being shown; none outside one (no caching). */
export const ResourceCacheContext = createContext<ResourceCache | null>(null);

const cachedOrLoading = <T>(cache: ResourceCache | null, key: string): Resource<T> => {
  const hit = cache?.peek(key);
  return hit ? { state: "ready", data: hit.data as T } : { state: "loading" };
};

/**
 * Loads `key` with `load`. Inside a `ResourceCacheContext` a key read before
 * shows its last data at once and is read again in the background.
 *
 * - `retry()` drops the cached data and starts over from `loading`.
 * - `refresh()` reads again while the current data stays on screen; if that
 *   read fails, the data shown stays (only a first read or `retry()` shows
 *   an error).
 */
export function useResource<T>(
  key: string,
  load: (signal: AbortSignal) => Promise<T>
): [Resource<T>, () => void, () => void] {
  const cache = useContext(ResourceCacheContext);
  const [attempt, setAttempt] = useState({ count: 0, keep: false });
  const [resource, setResource] = useState<Resource<T> & { key: string }>(() => ({
    key,
    ...cachedOrLoading<T>(cache, key),
  }));

  useEffect(() => {
    const controller = new AbortController();
    const version = cache?.version;
    cache?.get(key);
    setResource((previous) => {
      if (previous.key === key && previous.state === "ready" && attempt.keep) {
        return previous;
      }
      const next = cachedOrLoading<T>(cache, key);
      return previous.key === key &&
        previous.state === "ready" &&
        next.state === "ready" &&
        previous.data === next.data
        ? previous
        : { key, ...next };
    });
    load(controller.signal).then(
      (loaded) => {
        if (controller.signal.aborted) return;
        const data = cache ? cache.set(key, loaded, version) : loaded;
        // Data equal to what is shown keeps its identity, so a refresh that
        // changed nothing leaves the page as it is.
        setResource((previous) =>
          previous.key === key &&
          previous.state === "ready" &&
          sameData(previous.data, data)
            ? previous
            : { key, state: "ready", data }
        );
      },
      (error: unknown) => {
        if (controller.signal.aborted) return;
        if (!attempt.keep) cache?.delete(key);
        // A failed background re-read keeps the page (its dialogs and input)
        // as it is; the next read or `retry()` tries again.
        setResource((previous) =>
          attempt.keep && previous.key === key && previous.state === "ready"
            ? previous
            : { key, state: "error", error }
        );
      }
    );
    return () => controller.abort();
    // `load` is keyed by `key`; callers pass inline closures.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, attempt, cache]);

  const retry = useCallback(() => {
    cache?.delete(key);
    setAttempt(({ count }) => ({ count: count + 1, keep: false }));
  }, [cache, key]);
  const refresh = useCallback(
    () => setAttempt(({ count }) => ({ count: count + 1, keep: true })),
    []
  );
  return [
    resource.key === key ? resource : cachedOrLoading<T>(cache, key),
    retry,
    refresh,
  ];
}

/**
 * State that belongs to one `basis` object, such as pages appended to a first
 * page: it starts over from `initial` when `basis` changes (a fresh read
 * replaced cached data, or a retry), and updates made for an earlier basis are
 * dropped.
 */
export function useStateFor<S>(
  basis: unknown,
  initial: S
): [S, (action: SetStateAction<S>) => void] {
  const [state, setState] = useState({ basis, value: initial });
  const latest = useRef(basis);
  latest.current = basis;
  const value = state.basis === basis ? state.value : initial;
  const update = useCallback(
    (action: SetStateAction<S>) => {
      if (latest.current !== basis) return;
      setState((previous) => {
        const current = previous.basis === basis ? previous.value : initial;
        return {
          basis,
          value:
            typeof action === "function"
              ? (action as (previous: S) => S)(current)
              : action,
        };
      });
    },
    // `initial` is a fresh literal each render; the first one is the one kept.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [basis]
  );
  return [value, update];
}

/**
 * Keeps the last data read for `key` shown while it is read again, so a
 * write's reload does not blank the page. Another `key` (another plugin)
 * starts empty. `stale` says that reload failed and the data may be old.
 */
export function useLastReady<T>(
  first: Resource<T>,
  key = ""
): { data: T | undefined; resource: Resource<T>; stale: boolean } {
  const last = useRef<{ key: string; data: T } | undefined>(undefined);
  if (first.state === "ready") last.current = { key, data: first.data };
  const data =
    first.state === "ready"
      ? first.data
      : last.current?.key === key
        ? last.current.data
        : undefined;
  return {
    data,
    resource: data === undefined ? first : { state: "ready", data },
    stale: first.state === "error" && data !== undefined,
  };
}
