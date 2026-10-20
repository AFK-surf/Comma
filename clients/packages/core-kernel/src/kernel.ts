// A core's front: the UIs connected to it, their messages, the named calls they make and the topics they subscribe
// to. What a core is about (its calls, its topics and where their values come from) it registers here; the kernel
// runs each call as a fiber, lists those that change something in the `doing` topic until they answer, and keeps the
// topics in its Store.
import { Cause, Effect, Exit, type Fiber } from "effect";
import type { Spec } from "./collections.ts";
import { Doing, FAILED_SHOWN_MS } from "./doing.ts";
import { asCoreError, CoreError } from "./error.ts";
import {
  parseClientMessage,
  type ClientId,
  type CoreMessage,
  type RequestId,
  type Topic,
  type TopicSpecs,
} from "./protocol.ts";
import type { Runner } from "./runtime.ts";
import { Store, type Source, type Value } from "./store.ts";

export type CallContext = {
  readonly client: ClientId;
  /// Says how far the call has got (`{id, value}` before its answer).
  progress(value: unknown): void;
};

export type Call = {
  /// Changes something a person asked for: listed in `doing` from when it is asked until it answers.
  readonly doing?: boolean;
  /// Stops when the UI that asked cancels it or goes (a call that holds something open for its page). Any other runs
  /// to its end, whoever waits on it.
  readonly cancellable?: boolean;
  /// The call. Its params are as the UI sent them: it checks them itself (failing with `invalid_params`).
  run(params: unknown, ctx: CallContext): Effect.Effect<unknown, CoreError>;
};

export type KernelOptions = {
  runner: Runner;
  /// Delivers a message to one UI.
  emit(client: ClientId, message: CoreMessage): void;
  /// Milliseconds since the Unix epoch (the doing topic's `since`).
  nowMs(): number;
  /// The params of each topic the core has (besides `doing`, which is the kernel's).
  topics: TopicSpecs;
  /// Where a topic's keyed lists are.
  specOf?(topic: Topic): Spec | null;
  coalesceMs?: number;
  evictAfterMs?: number;
};

export const DOING: Topic = { topic: "doing" };

export class Kernel {
  readonly runner: Runner;
  readonly store: Store;
  readonly doing = new Doing();
  readonly #options: KernelOptions;
  readonly #specs: TopicSpecs;
  readonly #sources = new Map<string, Source>();
  readonly #calls = new Map<string, Call>();
  readonly #running = new Map<string, Fiber.Fiber<unknown, unknown>>();
  readonly #clients = new Set<ClientId>();
  #nextClient = 0;

  constructor(options: KernelOptions) {
    this.#options = options;
    this.runner = options.runner;
    this.#specs = { ...options.topics, doing: {} };
    const doing = this.doing;
    this.#sources.set("doing", {
      start() {},
      stop() {},
      compute: (): Value => ({ ok: doing.value() }),
    });
    this.store = new Store({
      runner: options.runner,
      emit: (client, message) => {
        if (this.#clients.has(client)) options.emit(client, message);
      },
      specOf: (topic) => options.specOf?.(topic) ?? null,
      sourceOf: (topic) => this.#sources.get(topic.topic),
      ...(options.coalesceMs !== undefined ? { coalesceMs: options.coalesceMs } : {}),
      ...(options.evictAfterMs !== undefined
        ? { evictAfterMs: options.evictAfterMs }
        : {}),
    });
  }

  /// Who produces the topics named `name`.
  source(name: string, source: Source): void {
    if (!(name in this.#specs)) throw new Error(`no topic ${name}`);
    this.#sources.set(name, source);
  }

  /// Calls by name.
  calls(calls: Record<string, Call>): void {
    for (const [name, call] of Object.entries(calls)) this.#calls.set(name, call);
  }

  /// A UI connected: its id, for `receive` and what goes out to it.
  connect(): ClientId {
    const client = ++this.#nextClient;
    this.#clients.add(client);
    return client;
  }

  /// Whether a UI is connected now.
  connected(client: ClientId): boolean {
    return this.#clients.has(client);
  }

  /// A UI went: its subscriptions go, and the calls it can stop.
  disconnect(client: ClientId): void {
    if (!this.#clients.delete(client)) return;
    this.store.dropClient(client);
    const prefix = `${client}/`;
    for (const [key, fiber] of Array.from(this.#running)) {
      if (!key.startsWith(prefix)) continue;
      this.#running.delete(key);
      this.runner.interrupt(fiber);
    }
  }

  /// A message from a UI, as it sent it.
  receive(client: ClientId, raw: unknown): void {
    if (!this.#clients.has(client)) return;
    const message = parseClientMessage(raw, this.#specs);
    if ("invalid" in message) {
      const id = (raw as { id?: unknown } | null)?.id;
      if (typeof id === "number")
        this.#options.emit(client, {
          id,
          error: new CoreError("bad_message", message.invalid).toJSON(),
        });
      return;
    }
    switch (message.kind) {
      case "subscribe":
        return this.store.subscribe(
          client,
          message.id,
          message.subscribe,
          message.keyed === true
        );
      case "unsubscribe":
        return this.store.unsubscribe(client, message.id);
      case "cancel": {
        const key = `${client}/${message.id}`;
        const fiber = this.#running.get(key);
        if (fiber) {
          this.#running.delete(key);
          this.runner.interrupt(fiber);
        }
        return;
      }
      case "call":
        return this.#call(client, message.id, message.call, message.params);
    }
  }

  #emit(client: ClientId, message: CoreMessage): void {
    if (this.#clients.has(client)) this.#options.emit(client, message);
  }

  #call(client: ClientId, id: RequestId, name: string, params: unknown): void {
    const call = this.#calls.get(name);
    if (!call) {
      this.#emit(client, {
        id,
        error: new CoreError("unknown_call", `no call ${name}`).toJSON(),
      });
      return;
    }
    let doing: number | null = null;
    if (call.doing) {
      doing = this.doing.start(name, params, this.#options.nowMs());
      this.store.invalidate(DOING);
    }
    const key = `${client}/${id}`;
    const ctx: CallContext = {
      client,
      progress: (value) => this.#emit(client, { id, value }),
    };
    const run = Effect.suspend(() => call.run(params, ctx)).pipe(
      Effect.mapError(asCoreError),
      Effect.onInterrupt(() =>
        Effect.sync(() => {
          this.#running.delete(key);
          if (doing !== null) {
            this.doing.end(doing);
            this.store.invalidate(DOING);
          }
          this.#emit(client, {
            id,
            error: new CoreError("cancelled", "cancelled").toJSON(),
          });
        })
      ),
      Effect.exit,
      Effect.flatMap((exit) =>
        Effect.gen({ self: this }, function* () {
          this.#running.delete(key);
          const error = Exit.isSuccess(exit)
            ? null
            : asCoreError(Cause.squash(exit.cause));
          if (doing !== null) {
            if (error) this.doing.fail(doing, error.toJSON());
            else this.doing.end(doing);
            this.store.invalidate(DOING);
          }
          this.#emit(
            client,
            error
              ? { id, error: error.toJSON() }
              : { id, ok: Exit.isSuccess(exit) ? (exit.value ?? null) : null }
          );
          if (error && doing !== null) {
            yield* Effect.sleep(FAILED_SHOWN_MS);
            this.doing.end(doing);
            this.store.invalidate(DOING);
          }
        })
      )
    );
    const fiber = this.runner.fork(run);
    if (call.cancellable)
      this.#running.set(key, fiber as Fiber.Fiber<unknown, unknown>);
  }

  /// Lets the core go: its fibers stop.
  close(): void {
    this.runner.shutdown();
  }
}
