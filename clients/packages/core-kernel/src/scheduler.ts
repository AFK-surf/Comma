// The sync scheduler: every request the core makes of its servers is a task here, run by the lane it belongs to (a
// server's, a kind of work's) a few at a time, the most urgent first.
// What exists to be synced is the sync's to say, whatever the UI shows; the UI only makes some of it more urgent
// (`prioritize`: a chat opened, a page shown). A task asked for again while it waits or runs is the same task: its
// priority is raised, and whoever asked waits on its one run.
import { Deferred, Effect } from "effect";
import type { CoreError } from "./error.ts";
import type { Runner, Scoped } from "./runtime.ts";

/// How urgent a task is: higher goes first.
export const Priority = {
  /// Kept current in the background.
  background: 0,
  /// Behind something a UI shows.
  shown: 10,
  /// What a UI has open.
  focused: 20,
  /// A person waits on it (a call answers once it is done).
  asked: 30,
} as const;

type Waiting = {
  key: string;
  priority: number;
  seq: number;
  work: Effect.Effect<void, CoreError>;
  done: Deferred.Deferred<void, CoreError>;
};

/// One lane: its tasks, run `width` at a time.
class Lane {
  readonly waiting: Waiting[] = [];
  readonly running = new Map<string, Waiting>();
  readonly width: number;
  constructor(width: number) {
    this.width = width;
  }
}

export class Scheduler {
  readonly #runner: Runner;
  readonly #scoped: Scoped;
  readonly #lanes = new Map<string, Lane>();
  #seq = 0;
  /// The priority things matching a key's prefix get while a UI makes them urgent (`prioritize`), by who asked.
  readonly #boosts = new Map<string, [string, number]>();

  readonly #width: (lane: string) => number;

  /// `width`: how many tasks of a lane run at once (2 unless it says).
  constructor(
    runner: Runner,
    scoped: Scoped,
    width: (lane: string) => number = () => 2
  ) {
    this.#runner = runner;
    this.#scoped = scoped;
    this.#width = width;
  }

  #lane(name: string): Lane {
    let lane = this.#lanes.get(name);
    if (!lane) {
      lane = new Lane(this.#width(name));
      this.#lanes.set(name, lane);
    }
    return lane;
  }

  #boosted(key: string, priority: number): number {
    let p = priority;
    for (const [prefix, boost] of this.#boosts.values())
      if (key.startsWith(prefix)) p = Math.max(p, boost);
    return p;
  }

  /// Asks for a task: in `lane`, by `key` (one task per key), at `priority`, when the returned effect runs (not when
  /// it is made: an effect built for later asks nothing until then). It ends with what the task's run ends with (a
  /// task asked for while it runs is run again after, for what changed meanwhile).
  ask(
    lane: string,
    key: string,
    priority: number,
    work: Effect.Effect<void, CoreError>
  ): Effect.Effect<void, CoreError> {
    return Effect.suspend(() =>
      Deferred.await(this.enqueue(lane, key, priority, work))
    );
  }

  /// As `ask`, without waiting: the completion to wait on, if one wants to.
  enqueue(
    lane: string,
    key: string,
    priority: number,
    work: Effect.Effect<void, CoreError>
  ): Deferred.Deferred<void, CoreError> {
    const l = this.#lane(lane);
    const p = this.#boosted(key, priority);
    const waiting = l.waiting.find((w) => w.key === key);
    if (waiting) {
      waiting.priority = Math.max(waiting.priority, p);
      return waiting.done;
    }
    const task: Waiting = {
      key,
      priority: p,
      seq: ++this.#seq,
      work,
      done: Deferred.makeUnsafe<void, CoreError>(),
    };
    l.waiting.push(task);
    this.#pump(l);
    return task.done;
  }

  #pump(lane: Lane): void {
    while (lane.running.size < lane.width) {
      // The most urgent, then the oldest; one already running for its key waits for that run.
      let best = -1;
      for (let i = 0; i < lane.waiting.length; i++) {
        const w = lane.waiting[i];
        if (lane.running.has(w.key)) continue;
        if (
          best < 0 ||
          w.priority > lane.waiting[best].priority ||
          (w.priority === lane.waiting[best].priority && w.seq < lane.waiting[best].seq)
        )
          best = i;
      }
      if (best < 0) return;
      const [task] = lane.waiting.splice(best, 1);
      lane.running.set(task.key, task);
      this.#runner.fork(
        task.work.pipe(
          Effect.exit,
          Effect.flatMap((exit) =>
            Effect.sync(() => {
              lane.running.delete(task.key);
              Deferred.doneUnsafe(task.done, exit);
              this.#pump(lane);
            })
          ),
          Effect.onInterrupt(() =>
            Effect.sync(() => {
              lane.running.delete(task.key);
            })
          )
        ),
        this.#scoped
      );
    }
  }

  /// Makes what matches `prefix` at least `priority` while `who` says so (a UI's focus); `null` lets it go.
  prioritize(
    who: string,
    prefix: string | null,
    priority: number = Priority.focused
  ): void {
    if (prefix === null) this.#boosts.delete(who);
    else this.#boosts.set(who, [prefix, priority]);
    if (prefix === null) return;
    for (const lane of this.#lanes.values()) {
      for (const w of lane.waiting)
        if (w.key.startsWith(prefix)) w.priority = Math.max(w.priority, priority);
    }
  }

  /// Drops what waits in a lane (a server no longer reached, a signed-out account): those waiting on it are told.
  drop(lane: string, why: CoreError): void {
    const l = this.#lanes.get(lane);
    if (!l) return;
    for (const w of l.waiting.splice(0)) Deferred.doneUnsafe(w.done, Effect.fail(why));
  }

  /// What waits and runs, for tests: `lane key@priority`.
  pending(): string[] {
    const out: string[] = [];
    for (const [name, lane] of this.#lanes) {
      for (const w of lane.running.values())
        out.push(`${name} ${w.key}@${w.priority} running`);
      for (const w of lane.waiting) out.push(`${name} ${w.key}@${w.priority}`);
    }
    return out;
  }
}
