// The Tasks a message can mention (the composer's @ menu): a Group's Tasks that are not archived and have a title, newest
// first. Read when the menu's list first shows, kept in memory for this account for a minute. Each new read of the list
// in focus (the inbox) makes them stale, so a Task made meanwhile shows: the shown ones are read again, and keep the
// last answer until the new one comes. A failed read shows no Tasks and is kept for nothing, so the next showing asks
// again.
//
// Bounds: one read in flight per Group; at most 128 Groups kept (the least recently shown go first, never one shown now).
import type { Topic, Value, Watch } from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import { route } from "./api.ts";
import { taskPageSchema, taskSummarySchema } from "./comma/schemas.ts";
import type { MentionTask, ProductInboxListResult } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";

export const MENTION_TASKS_KEEP_MS = 60_000;
const MAX_KEPT = 128;
/** The list in focus: each new read of it makes the kept Tasks stale. */
const FOCUSED: Topic = { topic: "tasks", workspace: "" };

type Kept = { expiresAt: number; tasks: MentionTask[] };

const groupOf = (topic: Topic) => String(topic.group);

export class MentionTasks {
  readonly #ctx: Ctx;
  readonly #live: Live;
  /** In the order last shown: the first is the next to go. */
  readonly #kept = new Map<string, Kept>();
  #accountKey: string | null = null;
  #watch: Watch | null = null;
  /** The read of the list in focus last seen (`lastSyncedAt`); null before the first. */
  #seen: { readAt: number | undefined } | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("mentionTasks", {
      start: (topic) => {
        this.#watch ??= kernel.store.watch(FOCUSED, () => this.#listChanged());
        this.#listChanged();
        const group = groupOf(topic);
        const kept = this.#kept.get(group);
        if (kept && kept.expiresAt > ctx.now()) {
          // Shown again: it goes to the back of the line.
          this.#kept.delete(group);
          this.#kept.set(group, kept);
          return;
        }
        this.#live.run(topic, this.#read(topic));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        if (this.#shown().length === 0) {
          this.#watch?.drop();
          this.#watch = null;
          this.#seen = null;
        }
        this.#evict();
      },
      compute: (topic): Value => ({
        ok: this.#kept.get(groupOf(topic))?.tasks ?? null,
      }),
      // A later showing checks the minute again (the UI lets go at once too).
      evictAfterMs: 0,
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      // Nothing one account knew is shown to another.
      this.#kept.clear();
      this.#seen = null;
      for (const topic of this.#shown()) {
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#read(topic));
      }
    });
  }

  #shown(): Topic[] {
    return this.#ctx.kernel.store
      .liveTopics()
      .filter((t) => t.topic === "mentionTasks");
  }

  /** A new read of the list in focus: every kept Group is stale, and the shown ones are read again. */
  #listChanged(): void {
    const list = this.#ctx.kernel.store.get(FOCUSED) as
      | ProductInboxListResult
      | null
      | undefined;
    if (!list) return;
    // The first read seen is what the kept Tasks started from.
    const read = this.#seen !== null && this.#seen.readAt !== list.lastSyncedAt;
    this.#seen = { readAt: list.lastSyncedAt };
    if (!read) return;
    for (const kept of this.#kept.values()) kept.expiresAt = 0;
    for (const topic of this.#shown()) this.#live.run(topic, this.#read(topic));
  }

  #read(topic: Topic): Effect.Effect<void> {
    const ctx = this.#ctx;
    const group = groupOf(topic);
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const page = yield* ctx.api
        .request(
          account.value,
          "GET",
          route`/v1/comma/groups/${group}/conversations`,
          taskPageSchema(taskSummarySchema)
        )
        .pipe(Effect.result);
      const now = ctx.now();
      this.#kept.delete(group);
      this.#kept.set(
        group,
        Result.isSuccess(page)
          ? {
              expiresAt: now + MENTION_TASKS_KEEP_MS,
              tasks: page.success.data
                .filter(
                  (task) =>
                    task.kind === "agent_task" &&
                    task.status !== "archived" &&
                    task.title.trim().length > 0
                )
                .map((task) => ({
                  id: task.id,
                  status: task.status,
                  title: task.title,
                  updatedAt: task.updated_at ?? 0,
                }))
                .toSorted((a, b) => b.updatedAt - a.updatedAt),
            }
          : // No Tasks to show; the next showing asks again.
            { expiresAt: now, tasks: [] }
      );
      this.#evict();
      ctx.kernel.store.invalidate(topic);
    });
  }

  /** Drops the least recently shown beyond 128, but never one shown now. */
  #evict(): void {
    if (this.#kept.size <= MAX_KEPT) return;
    const shown = new Set(this.#shown().map(groupOf));
    for (const group of this.#kept.keys()) {
      if (this.#kept.size <= MAX_KEPT) return;
      if (!shown.has(group)) this.#kept.delete(group);
    }
  }
}
