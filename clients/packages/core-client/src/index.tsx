// React on the core: `useTopic` renders a topic's current value, `useCall` makes named calls, `useDoing` says whether
// a call is under way. The UI holds no data of its own and makes no requests: what it shows is what the core says, and
// what a person does is a call. No Effect here (the core's own package is only used for its contract types).
import type {
  CallName,
  Calls,
  TopicName,
  TopicOf,
  TopicValues,
  DoingItem,
} from "@comma/core/contract";
import {
  CoreClient,
  CoreError,
  topicKey,
  type Channel,
  type CoreFailure,
  type Opener,
  type Topic,
} from "@comma/core-kernel/client";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useSyncExternalStore,
  type ReactNode,
} from "react";

export { CoreClient, CoreError, type Channel, type CoreFailure, type Opener };
export type * from "@comma/core/contract";

const CoreContext = createContext<CoreClient | null>(null);

/** The core this part of the UI talks to. */
export function CoreProvider({
  client,
  children,
}: {
  client: CoreClient;
  children: ReactNode;
}) {
  return <CoreContext.Provider value={client}>{children}</CoreContext.Provider>;
}

export function useCore(): CoreClient {
  const client = useContext(CoreContext);
  if (!client) throw new Error("useCore needs a CoreProvider above it.");
  return client;
}

export interface TopicState<T> {
  value: T | undefined;
  error: CoreError | null;
  /** No value and no error yet. */
  loading: boolean;
}

interface Entry {
  state: TopicState<unknown>;
  listeners: Set<() => void>;
  unsubscribe: (() => void) | null;
  drop: ReturnType<typeof setTimeout> | null;
}

// A topic nobody watches is let go after a while: going back to what was just shown finds it current at once.
const LINGER_MS = 30_000;
const IDLE: TopicState<never> = { value: undefined, error: null, loading: false };
const caches = new WeakMap<CoreClient, Map<string, Entry>>();
/** Stands for "no core": nothing is subscribed through it. */
const detached = {} as CoreClient;

function entries(client: CoreClient): Map<string, Entry> {
  let map = caches.get(client);
  if (!map) {
    map = new Map();
    caches.set(client, map);
  }
  return map;
}

function entry(client: CoreClient, key: string): Entry {
  const map = entries(client);
  let found = map.get(key);
  if (!found) {
    found = {
      state: { value: undefined, error: null, loading: true },
      listeners: new Set(),
      unsubscribe: null,
      drop: null,
    };
    map.set(key, found);
    // Created by a render that may never commit: dropped unless someone listens.
    linger(client, key, found);
  }
  return found;
}

function linger(client: CoreClient, key: string, e: Entry, ms = LINGER_MS): void {
  if (e.drop) clearTimeout(e.drop);
  e.drop = setTimeout(() => {
    if (e.listeners.size > 0) return;
    e.unsubscribe?.();
    entries(client).delete(key);
  }, ms);
}

function update(e: Entry, state: TopicState<unknown>): void {
  e.state = state;
  for (const listener of e.listeners) listener();
}

function listen(
  client: CoreClient,
  key: string,
  topic: Topic,
  listener: () => void,
  lingerMs = LINGER_MS
): () => void {
  const e = entry(client, key);
  if (e.drop) clearTimeout(e.drop);
  e.drop = null;
  e.listeners.add(listener);
  e.unsubscribe ??= client.subscribe(
    topic,
    // A value clears an earlier error: the topic is readable again.
    (value) => update(e, { value, error: null, loading: false }),
    // The last value stays on screen next to the error.
    (error) => update(e, { value: e.state.value, error, loading: false })
  );
  return () => {
    e.listeners.delete(listener);
    if (e.listeners.size === 0) linger(client, key, e, lingerMs);
  };
}

/** A topic's current value, kept up to date by the core. `null` subscribes to nothing. */
export function useTopic<N extends TopicName>(
  topic: TopicOf<N> | null,
  options: {
    /**
     * How long the topic stays subscribed once nothing shows it (default 30 s, so going back finds it current). A
     * topic whose upkeep is costly, such as a live stream, lets go at once.
     */
    lingerMs?: number;
  } = {}
): TopicState<TopicValues[N]> {
  const lingerMs = options.lingerMs ?? LINGER_MS;
  // A surface rendered without a core (an embedded page) sees nothing, as for no topic.
  const client = useContext(CoreContext) ?? detached;
  const key = topic ? topicKey(topic) : null;
  // The topic object is new each render; its key is what counts.
  const subscribe = useCallback(
    (listener: () => void) =>
      topic && key && client !== detached
        ? listen(client, key, topic, listener, lingerMs)
        : () => undefined,
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [client, key, lingerMs]
  );
  const snapshot = useCallback(
    () => (key && client !== detached ? entry(client, key).state : IDLE),
    [client, key]
  );
  return useSyncExternalStore(subscribe, snapshot, snapshot) as TopicState<
    TopicValues[N]
  >;
}

/**
 * Calls `onValue` with a topic's value now and on each change, without rendering the caller (it reacts in an effect,
 * not in what it shows).
 */
export function useTopicListener<N extends TopicName>(
  topic: TopicOf<N> | null,
  onValue: (value: TopicValues[N]) => void
): void {
  const client = useContext(CoreContext) ?? detached;
  const key = topic ? topicKey(topic) : null;
  const latest = useRef(onValue);
  latest.current = onValue;
  useEffect(() => {
    if (!topic || !key || client === detached) return undefined;
    const e = entry(client, key);
    const fire = () => {
      if (e.state.value !== undefined) latest.current(e.state.value as TopicValues[N]);
    };
    const off = listen(client, key, topic, fire);
    fire();
    return off;
    // The topic object is new each render; its key is what counts.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client, key]);
}

/**
 * A part of a topic's value: the caller renders again only when `select` gives another object (the delta applier keeps
 * each unchanged item, so a selected item stays the same object while it does not change).
 */
export function useTopicSelect<N extends TopicName, T>(
  topic: TopicOf<N> | null,
  select: (value: TopicValues[N] | undefined) => T
): T {
  const client = useContext(CoreContext) ?? detached;
  const key = topic ? topicKey(topic) : null;
  const subscribe = useCallback(
    (listener: () => void) =>
      topic && key && client !== detached
        ? listen(client, key, topic, listener)
        : () => undefined,
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [client, key]
  );
  const latest = useRef(select);
  latest.current = select;
  const snapshot = () =>
    latest.current(
      (key && client !== detached ? entry(client, key).state : IDLE).value as
        | TopicValues[N]
        | undefined
    );
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}

export type CallFn = <N extends CallName>(
  name: N,
  params: Calls[N]["params"],
  signal?: AbortSignal
) => Promise<Calls[N]["result"]>;

/** Makes named calls on the core. */
export function useCall(): CallFn {
  const client = useContext(CoreContext);
  return useCallback<CallFn>(
    (name, params, signal) =>
      client
        ? (client.call(name, params, undefined, signal) as never)
        : Promise.reject(
            new CoreError({ code: "no_core", message: "No core is connected here." })
          ),
    [client]
  );
}

/**
 * Whether a call that changes something is under way (or failed a moment ago) for these params: the control it acts
 * on spins, and says so where it is. Params not given match any.
 */
export function useDoing<N extends CallName>(
  name: N,
  params: Partial<Record<keyof Calls[N]["params"], string>> = {}
): DoingItem | undefined {
  const { value } = useTopic({ topic: "doing" });
  const wanted = JSON.stringify(params);
  return useMemo(() => {
    const want = JSON.parse(wanted) as Record<string, string>;
    return value?.doing.find(
      (item) =>
        item.call === name &&
        Object.entries(want).every(([k, v]) => item.params[k] === v)
    );
  }, [value, name, wanted]);
}

/** Messages to and from the core over a port: a dedicated Worker, or a MessagePort Electron's Main handed over. */
function portChannel(
  port: { postMessage(message: unknown): void },
  early: unknown[]
): Channel {
  // oxlint-disable-next-line unicorn/require-post-message-target-origin -- a port has no target origin
  const post = (message: unknown) => port.postMessage(message);
  for (const message of early.splice(0)) post(message);
  return { post, close: () => undefined };
}

/**
 * Electron: Main hands this window one end of a channel to the core (`core.open`); the preload passes the port on as
 * a window message `{commaCorePort}`, and `{commaCoreClosed}` says the core's process went (the client opens again).
 */
export function electronCoreOpener(open: () => Promise<{ channelId: string }>): Opener {
  const arrived = new Map<string, MessagePort>();
  const waiting = new Map<string, (port: MessagePort) => void>();
  const failures = new Map<string, (reason: string, failure?: CoreFailure) => void>();
  window.addEventListener("message", (event: MessageEvent) => {
    if (event.source !== window) return;
    const data = event.data as {
      commaCorePort?: unknown;
      commaCoreClosed?: unknown;
    } | null;
    if (typeof data?.commaCorePort === "string" && event.ports[0]) {
      const wake = waiting.get(data.commaCorePort);
      if (wake) {
        waiting.delete(data.commaCorePort);
        wake(event.ports[0]);
      } else arrived.set(data.commaCorePort, event.ports[0]);
    } else if (typeof data?.commaCoreClosed === "string") {
      failures.get(data.commaCoreClosed)?.("The core's process went.", "process_exit");
    }
  });
  return (onMessage, onFail) => {
    let channel: Channel | null = null;
    let port: MessagePort | null = null;
    let closed = false;
    let id: string | null = null;
    const early: unknown[] = [];
    open().then(
      async ({ channelId }) => {
        id = channelId;
        failures.set(channelId, onFail);
        const delivered =
          arrived.get(channelId) ??
          (await new Promise<MessagePort>((resolve) =>
            waiting.set(channelId, resolve)
          ));
        arrived.delete(channelId);
        port = delivered;
        if (closed) return delivered.close();
        delivered.addEventListener("message", (event) => onMessage(event.data));
        delivered.start();
        channel = portChannel(delivered, early);
      },
      (error: unknown) =>
        onFail(error instanceof Error ? error.message : String(error), "channel_open")
    );
    return {
      post(message) {
        if (channel) channel.post(message);
        else early.push(structuredClone(message));
      },
      close() {
        closed = true;
        if (id) failures.delete(id);
        port?.close();
      },
    };
  };
}

/**
 * The web: this tab's dedicated worker, which runs the core or relays to the tab's worker that does. `build` is the
 * page's script that names the worker's: a page of a build replaced since (a tab the browser restored from its cache,
 * or one open across a release) asks for a worker script the release no longer serves, and is retired (it loads
 * again).
 */
export function workerCoreOpener(start: () => Worker, build?: string): Opener {
  // The core is the only copy of what was done offline: the browser is asked to keep its storage.
  void navigator.storage?.persist?.().catch(() => false);
  return (onMessage, onFail) => {
    const worker = start();
    worker.addEventListener("message", (event) => onMessage(event.data));
    // A worker whose script did not load or parse gets a plain `error` Event; one that threw and did not catch gets
    // an ErrorEvent.
    worker.addEventListener("error", (event: Event) => {
      if (event instanceof ErrorEvent) {
        onFail(event.message || "The core's worker failed.", "worker_exception");
        return;
      }
      const failed = () => onFail("The core's worker did not load.", "worker_load");
      if (build === undefined) return failed();
      // As a newer build's core tells a page of an older one. Unknown (offline): tried again, as any failure.
      served(build).then(
        (yes) => (yes ? failed() : onMessage({ retired: true })),
        failed
      );
    });
    return {
      // oxlint-disable-next-line unicorn/require-post-message-target-origin -- a worker has no target origin
      post: (message) => worker.postMessage(message),
      close: () => worker.terminate(),
    };
  };
}

/**
 * Whether `script` is still served as one: a release serves its own files, and its page (or a 404) for any other path.
 * Any other answer (the server failing, a limit) says nothing of the build: it counts as served, and is tried again.
 */
async function served(script: string): Promise<boolean> {
  const response = await fetch(script, { method: "HEAD", cache: "no-store" });
  if (response.status === 404) return false;
  if (!response.ok) return true;
  return /javascript/i.test(response.headers.get("content-type") ?? "");
}
