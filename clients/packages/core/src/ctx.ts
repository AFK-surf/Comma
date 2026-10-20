// What the core's modules share: the host, the runner their fibers run on, the kernel's topics, the sync scheduler,
// the session, the API and the time (the core's Clock). And `Live`: work that runs while a topic is live (subscribed, or within its grace after),
// stopped when the topic is.
import {
  type Kernel,
  type Runner,
  type Scheduler,
  type Scoped,
  type Topic,
  topicKey,
} from "@comma/core-kernel";
import type { Effect } from "effect";
import type { Api } from "./api.ts";
import type { Host } from "./host.ts";
import type { CoreLimits } from "./limits.ts";
import type { Session } from "./session.ts";

export interface Ctx {
  readonly host: Host;
  readonly runner: Runner;
  readonly kernel: Kernel;
  readonly scheduler: Scheduler;
  readonly session: Session;
  readonly api: Api;
  /** Milliseconds since the Unix epoch, from the core's Clock (a TestClock in tests): never the wall clock itself. */
  now(): number;
  /** How many times the core reads before it gives up. */
  readonly limits: CoreLimits;
}

/** The lane every request to the Comma API runs in. */
export const API_LANE = "api";

/** Fibers per live topic: `run` forks one in the topic's scope, `stop` interrupts what runs for it. */
export class Live {
  readonly #runner: Runner;
  readonly #scopes = new Map<string, Scoped>();

  constructor(runner: Runner) {
    this.#runner = runner;
  }

  run(topic: Topic, work: Effect.Effect<unknown, unknown>): void {
    const key = topicKey(topic);
    let scoped = this.#scopes.get(key);
    if (!scoped) {
      scoped = this.#runner.child();
      this.#scopes.set(key, scoped);
    }
    this.#runner.fork(work, scoped);
  }

  stop(topic: Topic): void {
    const key = topicKey(topic);
    const scoped = this.#scopes.get(key);
    if (!scoped) return;
    this.#scopes.delete(key);
    this.#runner.close(scoped);
  }

  /** Stops everything (the session changed). */
  stopAll(): void {
    for (const scoped of this.#scopes.values()) this.#runner.close(scoped);
    this.#scopes.clear();
  }

  live(topic: Topic): boolean {
    return this.#scopes.has(topicKey(topic));
  }
}
