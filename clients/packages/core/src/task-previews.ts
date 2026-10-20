// A task's preview where a chat mentions it: read when its hover card first shows, kept in memory for this account
// (20 seconds while the task runs, 5 minutes once it ended). A task the server no longer shows this account (403 or
// 404) is `revoked`; another failure is kept for nothing, so the next card asks again.
//
// Bounds: one read in flight per task; at most 128 tasks kept (the least recently shown go first, never one shown now).
import type { CoreError, Topic, Value } from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import { route } from "./api.ts";
import { commaConversationPreviewSchema } from "./comma/api-schemas.ts";
import type { TaskPreviewValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";

const ACTIVE_KEEP_MS = 20_000;
const ENDED_KEEP_MS = 5 * 60_000;
const MAX_KEPT = 128;
const ENDED = new Set(["completed", "failed", "cancelled", "canceled"]);

type Kept = {
  expiresAt: number;
  value: Exclude<TaskPreviewValue, { status: "loading" }>;
};

const keyOf = (topic: Topic) => `${String(topic.group)} ${String(topic.conversation)}`;

export class TaskPreviews {
  readonly #ctx: Ctx;
  readonly #live: Live;
  /** In the order last shown: the first is the next to go. */
  readonly #kept = new Map<string, Kept>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("taskPreview", {
      start: (topic) => {
        const key = keyOf(topic);
        const kept = this.#kept.get(key);
        if (kept && kept.expiresAt > ctx.now()) {
          // Shown again: it goes to the back of the line.
          this.#kept.delete(key);
          this.#kept.set(key, kept);
          return;
        }
        this.#kept.delete(key);
        this.#live.run(topic, this.#read(topic));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#evict();
      },
      compute: (topic): Value => ({
        ok: this.#kept.get(keyOf(topic))?.value ?? { status: "loading" },
      }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#kept.clear();
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "taskPreview") continue;
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#read(topic));
      }
    });
  }

  #read(topic: Topic): Effect.Effect<void> {
    const ctx = this.#ctx;
    const key = keyOf(topic);
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const answer = yield* ctx.api
        .request(
          account.value,
          "GET",
          `${route`/v1/comma/groups/${String(topic.group)}/conversations/${String(topic.conversation)}`}/preview`,
          commaConversationPreviewSchema
        )
        .pipe(Effect.result);
      const now = ctx.now();
      this.#kept.delete(key);
      if (Result.isSuccess(answer)) {
        const preview = answer.success;
        this.#kept.set(key, {
          expiresAt: now + (ENDED.has(preview.status) ? ENDED_KEEP_MS : ACTIVE_KEEP_MS),
          value: { status: "ready", preview },
        });
      } else {
        const status = (answer.failure as CoreError).status;
        this.#kept.set(key, {
          // Revoked stays as long as an ended task; a failure is shown, and asked again next time.
          expiresAt: status === 403 || status === 404 ? now + ENDED_KEEP_MS : now,
          value: { status: status === 403 || status === 404 ? "revoked" : "failed" },
        });
      }
      this.#evict();
      ctx.kernel.store.invalidate(topic);
    });
  }

  /** Drops the least recently shown beyond 128, but never one shown now. */
  #evict(): void {
    if (this.#kept.size <= MAX_KEPT) return;
    const shown = new Set(
      this.#ctx.kernel.store
        .liveTopics()
        .filter((t) => t.topic === "taskPreview")
        .map(keyOf)
    );
    for (const key of this.#kept.keys()) {
      if (this.#kept.size <= MAX_KEPT) return;
      if (!shown.has(key)) this.#kept.delete(key);
    }
  }
}
