// Topics: their current values, who subscribes, and when a value goes out.
//
// A topic comes alive with its first subscriber (the store tells its Source to start it) and is stopped a while after
// its last one leaves; its value stays until then. `set` stores a value and schedules its emission; emissions are
// coalesced over `coalesceMs`, one window for all topics, so topics changed together go out together, in the order
// they changed; a topic's first value goes out on the next turn instead. A subscriber's first message is the whole
// value, the next ones only what changed (keyed ops where the topic's spec says, plain ops elsewhere), and an unchanged
// value sends nothing. Code inside the core can `watch` a topic. A topic whose source computes it (from what the core
// keeps) is `invalidate`d and computed when its emission goes out, so many changes cost one computation.
import { Effect } from "effect";
import { type AnyOp, diffKeyed, heavier, type Spec } from "./collections.ts";
import type { CoreError } from "./error.ts";
import { equal } from "./json.ts";
import { noWork, type Meter } from "./meter.ts";
import {
  topicKey,
  type ClientId,
  type CoreMessage,
  type RequestId,
  type Topic,
} from "./protocol.ts";
import type { Runner } from "./runtime.ts";

export const COALESCE_MS = 50;
export const EVICT_AFTER_MS = 60_000;

/// A value or the error a topic shows.
export type Value = { ok: unknown } | { err: CoreError };

export function sameValue(a: Value | undefined, b: Value | undefined): boolean {
  if (a === undefined || b === undefined) return a === b;
  if ("ok" in a) return "ok" in b && equal(a.ok, b.ok);
  return "err" in b && a.err.equals(b.err);
}

/// Whoever produces a kind of topic.
export interface Source {
  /// The topic got its first subscriber (or watcher): keep it current.
  start(topic: Topic): void;
  /// Nobody has subscribed for a while: stop what it started.
  stop(topic: Topic): void;
  /// The topic's value now, from what the core keeps; undefined while it has none. Called when its emission goes out
  /// after it was started or invalidated.
  compute?(topic: Topic): Value | undefined;
  /// How long the topic stays after its last subscriber leaves before `stop` (default the store's, a minute). A source
  /// whose work should end soon after its last view, such as an open stream, sets a short one.
  /// False: each change goes out as soon as the core yields, not gathered with others in the coalescing window. For
  /// a topic whose every step a UI shows (an optimistic message before its server's answer).
  readonly coalesce?: boolean;
  readonly evictAfterMs?: number;
}

/// Keeps a watched topic alive; `drop` lets it go as a UI unsubscribing does.
export class Watch {
  readonly #store: Store;
  readonly #topic: Topic;
  readonly #id: number;
  #dropped = false;
  constructor(store: Store, topic: Topic, id: number) {
    this.#store = store;
    this.#topic = topic;
    this.#id = id;
  }
  drop(): void {
    if (this.#dropped) return;
    this.#dropped = true;
    this.#store.unwatch(this.#topic, this.#id);
  }
}

type Entry = {
  topic: Topic;
  value?: Value;
  /// The value last sent to the subscribers; the next emission is the difference to it.
  sent?: Value;
  /// Who subscribes.
  subscribers: [ClientId, RequestId][];
  watchers: [number, () => void][];
  stale: boolean;
  emitScheduled: boolean;
  idle: number | null;
};

type Out = { value: unknown } | { delta: AnyOp[] } | { error: CoreError };

function whole(v: Value): Out {
  return "ok" in v ? { value: v.ok } : { error: v.err };
}

function to(out: Out, id: RequestId): CoreMessage {
  if ("value" in out) return { id, value: out.value };
  if ("delta" in out) return { id, delta: out.delta };
  return { id, error: out.error.toJSON() };
}

export type StoreOptions = {
  runner: Runner;
  /// Delivers a message to one UI.
  emit(client: ClientId, message: CoreMessage): void;
  /// Where a topic's keyed lists are (collections.ts); null for none.
  specOf?(topic: Topic): Spec | null;
  /// Who produces a topic.
  sourceOf(topic: Topic): Source | undefined;
  /// Counts the work of each emission (a test's core).
  meter?: Meter;
  coalesceMs?: number;
  evictAfterMs?: number;
};

export class Store {
  readonly #options: StoreOptions;
  readonly #coalesceMs: number;
  readonly #evictAfterMs: number;
  readonly #topics = new Map<string, Entry>();
  readonly #subscriptions = new Map<string, Topic>();
  #idleCount = 0;
  #watchCount = 0;
  #pending: Topic[] = [];
  #windowOpen = false;
  #soon = false;

  constructor(options: StoreOptions) {
    this.#options = options;
    this.#coalesceMs = options.coalesceMs ?? COALESCE_MS;
    this.#evictAfterMs = options.evictAfterMs ?? EVICT_AFTER_MS;
  }

  #entry(topic: Topic): [Entry, boolean] {
    const key = topicKey(topic);
    let entry = this.#topics.get(key);
    const started = entry === undefined;
    if (!entry) {
      entry = {
        topic,
        subscribers: [],
        watchers: [],
        stale: false,
        emitScheduled: false,
        idle: null,
      };
      this.#topics.set(key, entry);
    }
    entry.idle = null;
    return [entry, started];
  }

  #start(topic: Topic): void {
    const source = this.#options.sourceOf(topic);
    source?.start(topic);
    if (source?.compute) this.invalidate(topic);
  }

  /// Adds a subscriber; sends the value last sent at once if there is one, and starts the topic if it was not live.
  subscribe(client: ClientId, id: RequestId, topic: Topic): void {
    this.unsubscribe(client, id);
    this.#subscriptions.set(`${client}/${id}`, topic);
    const [entry, started] = this.#entry(topic);
    entry.subscribers.push([client, id]);
    if (entry.sent !== undefined) this.#options.emit(client, to(whole(entry.sent), id));
    else if (!started && entry.value !== undefined && !entry.emitScheduled) {
      // Kept for a watcher but never sent: it goes out now.
      entry.emitScheduled = true;
      this.#scheduleEmit(topic);
    }
    if (started) this.#start(topic);
  }

  unsubscribe(client: ClientId, id: RequestId): void {
    const at = `${client}/${id}`;
    const topic = this.#subscriptions.get(at);
    if (!topic) return;
    this.#subscriptions.delete(at);
    const entry = this.#topics.get(topicKey(topic));
    if (!entry) return;
    entry.subscribers = entry.subscribers.filter(
      ([c, i]) => !(c === client && i === id)
    );
    // What was sent last is held by no one now: the next subscriber is sent the value as it is then, not that.
    if (entry.subscribers.length === 0) entry.sent = undefined;
    this.#release(topic);
  }

  /// Subscribes from inside the core: starts the topic if it was not live and calls `onChange` after each change of
  /// it, until the watch is dropped.
  watch(topic: Topic, onChange: () => void): Watch {
    const id = ++this.#watchCount;
    const [entry, started] = this.#entry(topic);
    entry.watchers.push([id, onChange]);
    if (started) this.#start(topic);
    return new Watch(this, topic, id);
  }

  unwatch(topic: Topic, id: number): void {
    const entry = this.#topics.get(topicKey(topic));
    if (!entry) return;
    entry.watchers = entry.watchers.filter(([w]) => w !== id);
    this.#release(topic);
  }

  /// Starts the eviction grace if nobody subscribes to or watches the topic any more.
  #release(topic: Topic): void {
    const idle = ++this.#idleCount;
    const entry = this.#topics.get(topicKey(topic));
    if (!entry || entry.subscribers.length > 0 || entry.watchers.length > 0) return;
    entry.idle = idle;
    const after = this.#options.sourceOf(topic)?.evictAfterMs ?? this.#evictAfterMs;
    this.#options.runner.fork(
      Effect.sleep(after).pipe(
        Effect.andThen(Effect.sync(() => this.#evict(topic, idle)))
      )
    );
  }

  /// A UI went away: drops all its subscriptions.
  dropClient(client: ClientId): void {
    const prefix = `${client}/`;
    const ids = [...this.#subscriptions.keys()]
      .filter((k) => k.startsWith(prefix))
      .map((k) => Number(k.slice(prefix.length)));
    for (const id of ids) this.unsubscribe(client, id);
  }

  /// Stores a topic's new value (or its error) and schedules sending it. A topic that is not live is ignored.
  set(topic: Topic, value: Value): void {
    const entry = this.#topics.get(topicKey(topic));
    if (!entry) return;
    this.#remade(entry, value);
    entry.value = value;
    entry.stale = false;
    this.#changed(entry);
  }

  /// Changes a topic's value, then schedules sending it. Does nothing if the topic has no value yet.
  update(topic: Topic, change: (value: unknown) => unknown): void {
    const entry = this.#topics.get(topicKey(topic));
    if (!entry || !entry.value || !("ok" in entry.value)) return;
    const next = { ok: change(entry.value.ok) };
    this.#remade(entry, next);
    entry.value = next;
    this.#changed(entry);
  }

  #changed(entry: Entry): void {
    const schedule = !entry.emitScheduled;
    entry.emitScheduled = true;
    const watchers = entry.watchers.map(([, w]) => w);
    if (schedule) this.#scheduleEmit(entry.topic);
    for (const w of watchers) w();
  }

  /// Marks a live topic's value out of date: its source computes it when its emission goes out.
  invalidate(topic: Topic): void {
    const entry = this.#topics.get(topicKey(topic));
    if (!entry) return;
    entry.stale = true;
    const schedule = !entry.emitScheduled;
    entry.emitScheduled = true;
    if (schedule) this.#scheduleEmit(topic);
  }

  /// Invalidates every live topic `pick` chooses.
  invalidateAll(pick: (topic: Topic) => boolean): void {
    for (const topic of this.liveTopics().filter(pick)) this.invalidate(topic);
  }

  /// The topic's value or error; undefined while it has neither. A stale one is computed now.
  value(topic: Topic): Value | undefined {
    const entry = this.#topics.get(topicKey(topic));
    if (!entry) return undefined;
    if (entry.stale) this.#compute(entry);
    return entry.value;
  }

  get(topic: Topic): unknown {
    const v = this.value(topic);
    return v && "ok" in v ? v.ok : undefined;
  }

  /// Whether a UI subscribes to the topic now.
  subscribed(topic: Topic): boolean {
    return (this.#topics.get(topicKey(topic))?.subscribers.length ?? 0) > 0;
  }

  /// Evicts now every topic within its eviction grace (no subscriber, no watcher): its source stops, and the next
  /// subscriber starts it again. What the topics showed is no longer true for anyone (the account changed), so none is
  /// kept for a subscriber who may come back, nor followed meanwhile.
  evictIdle(): void {
    for (const entry of this.#topics.values())
      if (entry.idle !== null) this.#evict(entry.topic, entry.idle);
  }

  /// Topics live now (subscribed, watched, or within their eviction grace).
  liveTopics(): Topic[] {
    return [...this.#topics.values()].map((e) => e.topic);
  }

  #compute(entry: Entry): boolean {
    entry.stale = false;
    const meter = this.#options.meter;
    meter?.computing(entry.topic);
    let computed: Value | undefined;
    try {
      computed = this.#options.sourceOf(entry.topic)?.compute?.(entry.topic);
    } finally {
      meter?.computing(null);
    }
    if (computed === undefined) return false;
    this.#remade(entry, computed);
    if (sameValue(entry.value, computed)) return false;
    entry.value = computed;
    return true;
  }

  /// With a meter: what the topic's new value made again of its last one (each item of a list equal to the one it
  /// replaces), whatever went out meanwhile.
  #remade(entry: Entry, next: Value): void {
    const meter = this.#options.meter;
    if (!meter || !entry.value || !("ok" in entry.value) || !("ok" in next)) return;
    const work = noWork();
    diffKeyed(
      entry.value.ok,
      next.ok,
      this.#options.specOf?.(entry.topic) ?? null,
      work
    );
    meter.remade(entry.topic, work);
  }

  #scheduleEmit(topic: Topic): void {
    this.#pending.push(topic);
    const entry = this.#topics.get(topicKey(topic));
    // A first value, and every change of a source that is not coalesced, goes out as soon as the core yields.
    const first =
      (entry !== undefined &&
        entry.sent === undefined &&
        entry.subscribers.length > 0) ||
      this.#options.sourceOf(topic)?.coalesce === false;
    if (first) {
      if (this.#soon) return;
      this.#soon = true;
    } else {
      if (this.#windowOpen) return;
      this.#windowOpen = true;
    }
    this.#options.runner.fork(
      (first ? Effect.yieldNow : Effect.sleep(this.#coalesceMs)).pipe(
        Effect.andThen(Effect.sync(() => this.#flushPending()))
      )
    );
  }

  #flushPending(): void {
    this.#windowOpen = false;
    this.#soon = false;
    const pending = this.#pending;
    this.#pending = [];
    for (const topic of pending) this.#flush(topic);
  }

  #flush(topic: Topic): void {
    const entry = this.#topics.get(topicKey(topic));
    if (!entry || !entry.emitScheduled) return;
    entry.emitScheduled = false;
    if (entry.stale && this.#compute(entry))
      for (const [, w] of entry.watchers.slice()) w();
    const value = entry.value;
    if (value === undefined || entry.subscribers.length === 0) return;
    // What goes out: the lists its spec keys changed item by item, the rest by the plain ops; the whole value when
    // that is lighter.
    const sent = entry.sent;
    const meter = this.#options.meter;
    const work = meter ? noWork() : undefined;
    let out: Out | null;
    if (sent !== undefined && "ok" in sent && "ok" in value) {
      const next = value.ok;
      const ops = diffKeyed(sent.ok, next, this.#options.specOf?.(topic) ?? null, work);
      out =
        ops.length === 0
          ? null
          : heavier(ops, next, work)
            ? { value: next }
            : { delta: ops };
    } else if (sent !== undefined && sameValue(sent, value)) out = null;
    else out = whole(value);
    entry.sent = value;
    if (meter && work)
      meter.emitted(topic, work, out ? JSON.stringify(to(out, 0)).length : 0);
    if (!out) return;
    for (const [client, id] of entry.subscribers)
      this.#options.emit(client, to(out, id));
  }

  #evict(topic: Topic, idle: number): void {
    const entry = this.#topics.get(topicKey(topic));
    if (!entry || entry.idle !== idle) return;
    this.#topics.delete(topicKey(topic));
    this.#options.sourceOf(topic)?.stop(topic);
  }
}
