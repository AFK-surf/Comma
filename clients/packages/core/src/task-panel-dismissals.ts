// The settled Tasks the reader cleared out of the chat Task panel (`chatTaskDismissed` marks) are the account's: the
// server keeps them (`/v1/comma/me/task-panel-dismissals`), so every device and client hides the same rows. Each one
// records the run the reader acknowledged (when it started, `run_started_at`; 0 for a Task from before the server kept
// it); the panel hides a settled Task only until it runs again, so its next result shows without any device lifting
// the mark. A rename, a label or a review acceptance starts no run. The account
// database keeps a copy, so the panel shows at once and works offline; the server's list replaces that copy when it is
// read.
//
// - Read: when the marks topic of the kind goes live, when the account changes while it is live, and when the reader
//   comes back to the window (`refresh`, at most once per REFRESH_MS). A dismissal made on another device shows then.
// - Write: each dismissal goes to the server in the background. The account keeps it until the server took it, so one
//   that fails is sent again on the next dismissal or read, after a restart too. A dismissal made while a read is out
//   is laid over its answer.
// - Handover: the first read of an account sends the dismissals this device kept before the server kept them. Ones kept
//   before they recorded a run go at no known run (0), never at the device's time (marks.ts). The account remembers
//   the handover only once the server took them, so a handover cut short is sent again.
//
// Bounds: one request at a time, at most 300 dismissals each; at most 300 waiting to be sent; at most one refresh read
// per REFRESH_MS per device.
import { Effect, Option } from "effect";
import { z } from "zod";
import type { Ctx } from "./ctx.ts";

const PATH = "/v1/comma/me/task-panel-dismissals";
const HANDED_OVER = "marks:chatTaskDismissed:handedOver";
/** The dismissals the server has not taken yet, oldest first, as `[id, revision]`. */
const WAITING = "marks:chatTaskDismissed:waiting";
const BATCH = 300;
const MAX_WAITING = 300;
const REFRESH_MS = 30_000;

const answerSchema = z
  .object({
    data: z
      .array(
        z
          .object({
            task_id: z.string().min(1).max(256),
            revision: z.number().int().nonnegative(),
          })
          .strip()
      )
      .max(BATCH),
  })
  .strip();

/** Task id → the Task version the dismissal acknowledged. */
type Marks = Record<string, number>;

export class TaskPanelDismissals {
  readonly #ctx: Ctx;
  readonly #read: () => Marks;
  readonly #write: (next: Marks) => void;
  /** Dismissals not sent yet, oldest first. */
  readonly #waiting = new Map<string, number>();
  /** The ids handed over and not taken by the server yet; null when no handover is under way. */
  #handingOver: Set<string> | null = null;
  /** Dismissals made since the read that is out was sent; null while none is out. */
  #sinceRead: Set<string> | null = null;
  #readWanted = false;
  /** When the last read was asked for (the core's time); a refresh before REFRESH_MS has passed is dropped. */
  #readAskedAt = Number.NEGATIVE_INFINITY;
  #running = false;
  /** Counts up when the account changes: what was under way for the old one is dropped. */
  #generation = 0;
  #accountKey: string | null = null;

  constructor(ctx: Ctx, read: () => Marks, write: (next: Marks) => void) {
    this.#ctx = ctx;
    this.#read = read;
    this.#write = write;
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#generation++;
      this.#waiting.clear();
      for (const [id, revision] of ctx.session
        .current()
        ?.meta<[string, number][]>(WAITING) ?? [])
        this.#waiting.set(id, revision);
      this.#handingOver = null;
      this.#sinceRead = null;
      this.#readWanted = false;
      if (this.#live()) this.read();
    });
  }

  /** Reads the account's list from the server (the panel is shown). */
  read(): void {
    this.#readAskedAt = this.#ctx.now();
    this.#readWanted = true;
    this.#pump();
  }

  /** Reads the list again when the reader comes back, unless it was read within REFRESH_MS. */
  refresh(): void {
    if (!this.#live() || this.#ctx.now() - this.#readAskedAt < REFRESH_MS) return;
    this.read();
  }

  /** The reader dismissed these Tasks here, each at the version it shows (`[id, revision]`). */
  dismissed(entries: readonly (readonly [string, number])[]): void {
    for (const [id, revision] of entries) {
      const was = this.#waiting.get(id);
      this.#waiting.delete(id);
      this.#waiting.set(id, Math.max(was ?? revision, revision));
      if (this.#waiting.size > MAX_WAITING)
        this.#waiting.delete(this.#waiting.keys().next().value!);
      this.#sinceRead?.add(id);
    }
    this.#keepWaiting();
    this.#pump();
  }

  #live(): boolean {
    return this.#ctx.kernel.store
      .liveTopics()
      .some((t) => t.topic === "marks" && t.kind === "chatTaskDismissed");
  }

  #pump(): void {
    if (this.#running) return;
    this.#running = true;
    this.#ctx.runner.fork(
      this.#drain().pipe(Effect.ensuring(Effect.sync(() => (this.#running = false))))
    );
  }

  /** Sends what waits, then reads when a read is wanted; stops at the first failure until the next call. */
  #drain(): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      // What the same moment does goes in one request.
      yield* this.#ctx.host.yieldTurn;
      for (;;) {
        const generation = this.#generation;
        if (this.#waiting.size > 0) {
          const sent = [...this.#waiting].slice(0, BATCH);
          const answer = yield* this.#request("POST", {
            dismissals: sent.map(([task_id, revision]) => ({ task_id, revision })),
          });
          if (generation !== this.#generation) continue;
          if (Option.isNone(answer)) return;
          for (const [id, revision] of sent)
            if (this.#waiting.get(id) === revision) this.#waiting.delete(id);
          this.#keepWaiting();
          this.#handedOver(sent.map(([id]) => id));
          continue;
        }
        if (!this.#readWanted) return;
        this.#readWanted = false;
        this.#sinceRead = new Set();
        const answer = yield* this.#request("GET");
        if (generation !== this.#generation) continue;
        const since = this.#sinceRead;
        this.#sinceRead = null;
        if (Option.isNone(answer)) return;
        this.#apply(answer.value, since);
      }
    });
  }

  #request(
    method: "GET" | "POST",
    body?: unknown
  ): Effect.Effect<Option.Option<z.output<typeof answerSchema>>> {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api.request(account, method, PATH, answerSchema, body)
      ),
      Effect.option
    );
  }

  /** The account keeps what waits, so a dismissal the server has not taken outlives a restart. */
  #keepWaiting(): void {
    this.#ctx.session.current()?.setMeta(WAITING, [...this.#waiting]);
  }

  /** The server took `ids`: once it holds every id handed over, the account remembers the handover. */
  #handedOver(ids: readonly string[]): void {
    if (!this.#handingOver) return;
    for (const id of ids) this.#handingOver.delete(id);
    if (this.#handingOver.size > 0) return;
    this.#handingOver = null;
    this.#ctx.session.current()?.setMeta(HANDED_OVER, true);
  }

  /** The server's list becomes the copy, with the dismissals made here since the read laid over it. */
  #apply(answer: z.output<typeof answerSchema>, since: ReadonlySet<string>): void {
    const local = this.#read();
    const next: Marks = {};
    for (const { task_id, revision } of answer.data) next[task_id] = revision;
    const account = this.#ctx.session.current();
    if (account && !account.meta<boolean>(HANDED_OVER)) {
      // Kept here before the server kept them: sent, and shown meanwhile.
      const kept = Object.entries(local).filter(
        ([id]) => !(id in next) && !since.has(id)
      );
      for (const [id, revision] of kept) next[id] = revision;
      this.#handingOver = new Set(kept.map(([id]) => id));
      if (kept.length > 0) this.dismissed(kept);
      else this.#handedOver([]);
    }
    for (const id of since)
      if (local[id] !== undefined) next[id] = Math.max(next[id] ?? 0, local[id]);
    this.#write(next);
  }
}
