// What the core knows of each coding Task's pull request (`codingPullRequest`), for every surface of the Task at once:
// the Task panel's line, the prompt above the composer and the Changes tab show the same one.
//
// It is learned from what the server answers: a read of the whole branch's changes (`coding.changes`), a read of the
// pull request's status, and the answer of a request that opens, edits or merges it. Each read takes a ticket before it
// asks; an answer never undoes one learned by a read that started later (a pull request made, edited or merged
// meanwhile). One request that changes the pull request runs at a time per Task (`busy` meanwhile); another is refused.
//
// `codingPullRequestWatch` keeps an open pull request's checks and mergeability current while a surface shows it and
// its window is in front (the UI subscribes to it only then): its status is read every 30 s while its checks still run
// or GitHub has not said whether it merges, and not once it settles.
//
// Bounds: at most 200 Tasks per account, the oldest forgotten first (a forgotten Task shows its pull request again after
// its next read); one status read in flight per Task; while watched and settling, one read per 30 s per Task, whatever
// the number of surfaces showing it. A read is two to five GitHub calls with the Group's token (GitHub allows 5 000 an
// hour).
import { CoreError, type Topic, type Value } from "@comma/core-kernel";
import { Duration, Effect } from "effect";
import type { CodingPullRequest, CodingPullRequestValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";

const MAX_TASKS = 200;
export const WATCH_EVERY_MS = 30_000;

type Entry = {
  ticket: number;
  known: boolean;
  pr: CodingPullRequest | null;
  busy: boolean;
};

const keyOf = (workspace: string, task: string) => `${workspace}\u0000${task}`;

/** Whether an open pull request is still settling: its checks run, or GitHub has not said whether it merges. */
export function settling(pr: CodingPullRequest | null): boolean {
  return (
    !!pr &&
    (pr.state === "open" || pr.state === "draft") &&
    (pr.mergeable === "unknown" ||
      (pr.checks !== null && pr.checks.passed + pr.checks.failed < pr.checks.total))
  );
}

export class CodingPullRequests {
  readonly #ctx: Ctx;
  readonly #live: Live;
  readonly #readStatus: (
    workspace: string,
    task: string
  ) => Effect.Effect<CodingPullRequest | null, CoreError>;
  readonly #entries = new Map<string, Entry>();
  /** The Tasks whose status read is on its way. */
  readonly #reading = new Set<string>();
  /** The watched Tasks, with the topic that keeps them watched, and those whose watch is reading on a timer. */
  readonly #watched = new Map<string, Topic>();
  readonly #polling = new Set<string>();
  #tickets = 0;
  #accountKey: string | null = null;

  constructor(
    ctx: Ctx,
    readStatus: (
      workspace: string,
      task: string
    ) => Effect.Effect<CodingPullRequest | null, CoreError>
  ) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    this.#readStatus = readStatus;
    const { kernel } = ctx;
    const compute = (topic: Topic): Value => ({ ok: this.#value(topic) });
    kernel.source("codingPullRequest", {
      start: () => undefined,
      stop: () => undefined,
      compute,
    });
    kernel.source("codingPullRequestWatch", {
      start: (topic) => {
        const key = keyOf(String(topic.workspace), String(topic.task));
        this.#watched.set(key, topic);
        this.#poll(key);
      },
      stop: (topic) => {
        const key = keyOf(String(topic.workspace), String(topic.task));
        this.#watched.delete(key);
        this.#live.stop(topic);
      },
      compute,
      // A watch ends with the last surface showing it: it reads nothing for a surface gone.
      evictAfterMs: 0,
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      // Nothing one account knew is shown to another.
      this.#live.stopAll();
      this.#entries.clear();
      this.#reading.clear();
      this.#polling.clear();
      this.#changed();
    });
  }

  /** A ticket for a read about to ask: its answer is learned unless a read that started later answered first. */
  ticket(): number {
    return ++this.#tickets;
  }

  /** Records what a read that took `ticket` learned of the Task's pull request (null: the branch has none). */
  learn(
    workspace: string,
    task: string,
    ticket: number,
    pr: CodingPullRequest | null
  ): void {
    const key = keyOf(workspace, task);
    const known = this.#entries.get(key);
    if (known?.known && known.ticket > ticket) return;
    this.#put(key, { ticket, known: true, pr, busy: known?.busy ?? false });
    this.#changed();
    this.#poll(key);
  }

  /** Reads the pull request's status from GitHub and learns it; while one is on its way for the Task, what is known answers. */
  read(
    workspace: string,
    task: string
  ): Effect.Effect<CodingPullRequest | null, CoreError> {
    const key = keyOf(workspace, task);
    return Effect.suspend(() => {
      if (this.#reading.has(key))
        return Effect.succeed(this.#entries.get(key)?.pr ?? null);
      this.#reading.add(key);
      const ticket = this.ticket();
      return this.#readStatus(workspace, task).pipe(
        Effect.tap((pr) => Effect.sync(() => this.learn(workspace, task, ticket, pr))),
        Effect.ensuring(Effect.sync(() => this.#reading.delete(key)))
      );
    });
  }

  /**
   * Runs a request that changes the Task's pull request, one at a time per Task (`busy` meanwhile), and learns what its
   * answer says (`learned`, taken as the newest).
   */
  act<A>(
    workspace: string,
    task: string,
    request: Effect.Effect<A, CoreError>,
    learned: (answer: A) => CodingPullRequest | null
  ): Effect.Effect<A, CoreError> {
    const key = keyOf(workspace, task);
    return Effect.suspend(() => {
      if (this.#entries.get(key)?.busy)
        return Effect.fail(
          new CoreError("busy", "a pull request request is on its way for this Task")
        );
      this.#setBusy(key, true);
      return request.pipe(
        Effect.tap((answer) =>
          Effect.sync(() => this.learn(workspace, task, this.ticket(), learned(answer)))
        ),
        Effect.ensuring(Effect.sync(() => this.#setBusy(key, false)))
      );
    });
  }

  #setBusy(key: string, busy: boolean): void {
    const entry = this.#entries.get(key) ?? { ticket: 0, known: false, pr: null, busy };
    this.#put(key, { ...entry, busy });
    this.#changed();
  }

  #put(key: string, entry: Entry): void {
    this.#entries.delete(key);
    this.#entries.set(key, entry);
    if (this.#entries.size <= MAX_TASKS) return;
    for (const old of this.#entries.keys()) {
      if (old === key || this.#watched.has(old) || this.#entries.get(old)?.busy)
        continue;
      this.#entries.delete(old);
      break;
    }
  }

  /** While the Task is watched and its pull request settles, reads its status every 30 s. */
  #poll(key: string): void {
    const topic = this.#watched.get(key);
    if (
      !topic ||
      this.#polling.has(key) ||
      !settling(this.#entries.get(key)?.pr ?? null)
    )
      return;
    this.#polling.add(key);
    const workspace = String(topic.workspace);
    const task = String(topic.task);
    this.#live.run(
      topic,
      Effect.gen({ self: this }, function* () {
        while (this.#watched.has(key) && settling(this.#entries.get(key)?.pr ?? null)) {
          yield* Effect.sleep(Duration.millis(WATCH_EVERY_MS));
          // A failed read leaves what is known; the next one comes on time.
          yield* this.read(workspace, task).pipe(Effect.ignore);
        }
      }).pipe(Effect.ensuring(Effect.sync(() => this.#polling.delete(key))))
    );
  }

  #changed(): void {
    this.#ctx.kernel.store.invalidateAll(
      (t) => t.topic === "codingPullRequest" || t.topic === "codingPullRequestWatch"
    );
  }

  #value(topic: Topic): CodingPullRequestValue {
    const entry = this.#entries.get(keyOf(String(topic.workspace), String(topic.task)));
    return {
      known: entry?.known ?? false,
      pr: entry?.pr ?? null,
      busy: entry?.busy ?? false,
    };
  }
}
