// A UI's side of a core: one channel to where the core runs (a worker, a utility process), calls with request ids, and
// subscriptions that survive the channel being replaced. No Effect here: a UI package uses this as it is.
import { applyDelta, type DeltaOp } from "./apply.ts";

export type { DeltaOp } from "./apply.ts";
export { applyDelta } from "./apply.ts";

/// What a UI can subscribe to: `{ topic, …params }`.
export type Topic = { topic: string; [param: string]: unknown };

export interface ErrorBody {
  code: string;
  message: string;
  status?: number;
  detail?: unknown;
}

/// A call or topic that failed; `code` is the core's (a server's codes pass through), `detail` what the server said.
export class CoreError extends Error {
  readonly code: string;
  readonly status: number | undefined;
  readonly detail: unknown;

  constructor(body: ErrorBody) {
    super(body.message);
    this.name = "CoreError";
    this.code = body.code;
    this.status = body.status;
    this.detail = body.detail;
  }
}

/// An error the core caught in its own tasks, sent to a UI to report.
export interface CoreFault {
  name: string;
  message: string;
  stack?: string;
}

/// One open channel to the core.
export interface Channel {
  post(message: unknown): void;
  close(): void;
}

/// Why a channel to the core failed: its worker's script never ran, its worker threw and did not catch, its process
/// went, the core gave up (`fatal`), or the channel could not be opened. `channel` when the opener does not say.
export type CoreFailure =
  | "worker_load"
  | "worker_exception"
  | "process_exit"
  | "core_fatal"
  | "channel_open"
  | "channel";

/// Opens a channel; messages from the core go to `onMessage`, and `onFail` when it is gone or broken (the client then
/// opens a new one).
export type Opener = (
  onMessage: (data: unknown) => void,
  onFail: (reason: string, failure?: CoreFailure) => void
) => Channel;

export interface ClientOptions {
  /// Waits before reopening a failed channel; tests pass their own.
  schedule?: (ms: number, run: () => void) => void;
  /// Errors in the core (it reports them; the UI cannot see them otherwise) and the channel failing.
  onFault?: (error: Error) => void;
  /// A newer build's core took over: this UI is of an older one (a page reloads).
  onRetired?: () => void;
}

interface Pending {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  onProgress?: ((value: unknown) => void) | undefined;
}

interface Subscription {
  topic: Topic;
  onValue: (value: unknown) => void;
  onError: (error: CoreError) => void;
  /// The whole current value, which deltas apply to; unset until the first value and after an error.
  value?: unknown;
}

// A core that keeps failing (a broken build) is retried with growing pauses rather than in a tight loop.
const RETRY_MS = [0, 1000, 2000, 5000, 10_000, 30_000];

export class CoreClient {
  readonly #open: Opener;
  readonly #schedule: (ms: number, run: () => void) => void;
  readonly #onFault: (error: Error) => void;
  readonly #rejoinListeners = new Set<() => void>();
  /// Whether a channel was open before: a later one is to a core that forgot this UI.
  #connected = false;
  readonly #onRetired: () => void;
  #channel: Channel | null = null;
  #nextId = 1;
  readonly #calls = new Map<number, Pending>();
  readonly #subs = new Map<number, Subscription>();
  /// Calls made while the channel is being replaced, sent once it is up.
  #queue: unknown[] = [];
  #failures = 0;
  #closed = false;

  constructor(open: Opener, options: ClientOptions = {}) {
    this.#open = open;
    // A host that passes no scheduler waits on the platform's timer.
    // @effect-diagnostics-next-line globalTimers:off
    this.#schedule = options.schedule ?? ((ms, run) => void setTimeout(run, ms));
    this.#onFault = options.onFault ?? (() => undefined);
    this.#onRetired =
      options.onRetired ??
      (() => (globalThis as { location?: { reload(): void } }).location?.reload());
    this.#connect();
  }

  /// A named call; `signal` stops it while under way (it then fails with `cancelled`, if the call can be stopped).
  call(
    name: string,
    params: unknown = {},
    onProgress?: (value: unknown) => void,
    signal?: AbortSignal
  ): Promise<unknown> {
    if (this.#closed)
      return Promise.reject(
        new CoreError({ code: "closed", message: "The core is closed." })
      );
    if (signal?.aborted)
      return Promise.reject(new CoreError({ code: "cancelled", message: "cancelled" }));
    const id = this.#nextId++;
    return new Promise<unknown>((resolve, reject) => {
      this.#calls.set(id, { resolve, reject, onProgress });
      this.#send({ id, call: name, params });
      signal?.addEventListener(
        "abort",
        () => {
          if (!this.#calls.has(id)) return;
          if (this.#channel) {
            this.#post({ id, cancel: true });
          } else {
            this.#calls.delete(id);
            this.#queue = this.#queue.filter((m) => (m as { id?: number }).id !== id);
            reject(new CoreError({ code: "cancelled", message: "cancelled" }));
          }
        },
        { once: true }
      );
    });
  }

  /// Values arrive on `onValue` (the whole current value each time, deltas applied); returns the unsubscribe.
  subscribe(
    topic: Topic,
    onValue: (value: unknown) => void,
    onError: (error: CoreError) => void
  ): () => void {
    const id = this.#nextId++;
    this.#subs.set(id, { topic, onValue, onError });
    if (this.#channel) this.#post({ id, subscribe: topic, keyed: true });
    return () => {
      if (this.#subs.delete(id) && this.#channel) this.#post({ id, unsubscribe: true });
    };
  }

  /// The UI is going away (a page into the back/forward cache): the core drops this client.
  suspend(): void {
    if (this.#channel) this.#post({ bye: true });
  }

  /// The core forgot this UI (it runs elsewhere now, a page back from the cache): subscribe again. Calls in flight
  /// were lost with the old client.
  resume(): void {
    this.#rejectCalls("core_restarted", "The core started again.");
    if (this.#channel)
      for (const [id, sub] of this.#subs)
        this.#post({ id, subscribe: sub.topic, keyed: true });
    this.#rejoined();
  }

  /// Calls `listener` each time the core this UI talks to forgot it (it started again, or runs in another tab now):
  /// what the UI holds there by calls (not subscriptions, which come back by themselves) it asks for again.
  onRejoin(listener: () => void): () => void {
    this.#rejoinListeners.add(listener);
    return () => void this.#rejoinListeners.delete(listener);
  }

  #rejoined(): void {
    for (const listener of Array.from(this.#rejoinListeners)) {
      try {
        listener();
      } catch (error) {
        this.#onFault(error instanceof Error ? error : new Error(String(error)));
      }
    }
  }

  close(): void {
    this.#closed = true;
    this.#rejectCalls("closed", "The core is closed.");
    this.#subs.clear();
    this.#channel?.close();
    this.#channel = null;
  }

  #connect(): void {
    if (this.#closed) return;
    let channel: Channel | null = null;
    // Late news from a channel already replaced is ignored.
    const current = () => channel !== null && channel === this.#channel;
    try {
      channel = this.#open(
        (data) => {
          if (current()) this.#receive(data);
        },
        (reason, failure) => {
          if (current()) this.#restart(reason, failure);
        }
      );
    } catch (error) {
      this.#channel = null;
      this.#onFault(error instanceof Error ? error : new Error(String(error)));
      this.#retry();
      return;
    }
    this.#channel = channel;
    for (const [id, sub] of this.#subs)
      this.#post({ id, subscribe: sub.topic, keyed: true });
    // A core that forgot this UI hears first what the UI held there (the rejoin listeners ask for it again), then
    // what was asked while it was away: a command queued during a restart then finds the lease it acts on.
    const rejoin = this.#connected;
    this.#connected = true;
    if (rejoin) this.#rejoined();
    const queued = this.#queue;
    this.#queue = [];
    for (const message of queued) this.#post(message);
  }

  #restart(reason: string, failure: CoreFailure = "channel"): void {
    this.#onFault(Object.assign(new Error(reason), { name: "CoreFailed", failure }));
    this.#channel?.close();
    this.#channel = null;
    // Whether they ran is unknown: the caller decides whether to try again.
    this.#rejectCalls("core_restarted", "The core started again.");
    this.#retry();
  }

  #retry(): void {
    const ms = RETRY_MS[Math.min(this.#failures, RETRY_MS.length - 1)] ?? 0;
    this.#failures++;
    this.#schedule(ms, () => this.#connect());
  }

  #rejectCalls(code: string, message: string): void {
    const calls = [...this.#calls.values()];
    this.#calls.clear();
    this.#queue = [];
    for (const call of calls) call.reject(new CoreError({ code, message }));
  }

  #send(message: unknown): void {
    if (this.#channel) this.#post(message);
    else this.#queue.push(message);
  }

  #post(message: unknown): void {
    try {
      this.#channel?.post(message);
    } catch (error) {
      // Not cloneable (a caller's mistake): fail that call only.
      const id = (message as { id?: number }).id;
      const call = id === undefined ? undefined : this.#calls.get(id);
      if (id === undefined || !call) throw error;
      this.#calls.delete(id);
      call.reject(error instanceof Error ? error : new Error(String(error)));
    }
  }

  #receive(data: unknown): void {
    if (typeof data !== "object" || data === null) return;
    const message = data as {
      id?: number;
      ok?: unknown;
      value?: unknown;
      delta?: DeltaOp[];
      error?: ErrorBody;
      fatal?: string;
      fault?: CoreFault;
      retired?: boolean;
      rejoin?: boolean;
    };
    if (message.retired) {
      this.#onRetired();
      return;
    }
    // The core this UI talked to went (with its tab); it runs elsewhere now: ask it again.
    if (message.rejoin) {
      this.resume();
      return;
    }
    if (message.fatal !== undefined) {
      this.#restart(message.fatal, "core_fatal");
      return;
    }
    if (message.fault) {
      const { name, message: text, stack } = message.fault;
      this.#onFault(
        Object.assign(new Error(text), { name, ...(stack ? { stack } : {}) })
      );
      return;
    }
    this.#failures = 0;
    if (message.id === undefined) return;
    const call = this.#calls.get(message.id);
    if (call) {
      // Values under a call's id tell how far it has got; its answer comes after them.
      if ("value" in message && !message.error) {
        call.onProgress?.(message.value);
        return;
      }
      this.#calls.delete(message.id);
      if (message.error) call.reject(new CoreError(message.error));
      else call.resolve(message.ok);
      return;
    }
    const sub = this.#subs.get(message.id);
    if (!sub) return; // unsubscribed while a value was on its way
    if (message.error) {
      delete sub.value;
      sub.onError(new CoreError(message.error));
    } else if ("value" in message) {
      sub.value = message.value;
      sub.onValue(sub.value);
    } else if (message.delta && "value" in sub) {
      sub.value = applyDelta(sub.value, message.delta);
      sub.onValue(sub.value);
    }
  }
}

/// A topic by its params: one key per topic, whatever order its params came in.
export function topicKey(topic: Topic): string {
  return JSON.stringify(
    Object.entries(topic).toSorted(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
  );
}
