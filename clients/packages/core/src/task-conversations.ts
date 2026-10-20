// A task's conversation as a read-only preview (the command palette, the share dialog): read when shown, kept in
// memory for this account for the task as it was (`version`: its update time and status) for 20 seconds while it
// runs and 5 minutes once it ended. A newer version or an old one is read again, the one kept shown meanwhile. A
// preview of the last `limit` messages gives up after 10 seconds.
//
// Bounds: one read in flight per preview; at most 24 kept (the least recently shown go first, never one shown now).
import { normalizeTaskStatus } from "@comma/i18n";
import type { Topic, Value } from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import { route } from "./api.ts";
import { normalizeServerMessages } from "./chat/model/conversationChannel.ts";
import { transcriptMessages } from "./chat/model/taskActivity.ts";
import { commaConversationSchema } from "./comma/api-schemas.ts";
import type { ChatMessage } from "@comma/chat-contract";
import type { TaskConversationValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";

const ACTIVE_KEEP_MS = 20_000;
const ENDED_KEEP_MS = 5 * 60_000;
const LIMITED_TIMEOUT_MS = 10_000;
const MAX_KEPT = 24;
/** The statuses a task no longer changes from (as the Inbox polls them). */
const ENDED = new Set([
  "archived",
  "canceled",
  "cancelled",
  "completed",
  "done",
  "escalated",
  "failed",
  "ready_for_review",
  "succeeded",
]);

type Kept = { version: string; expiresAt: number; messages: ChatMessage[] };

const keyOf = (topic: Topic) =>
  `${String(topic.group)} ${String(topic.conversation)} ${String(topic.limit ?? "")}`;

export class TaskConversations {
  readonly #ctx: Ctx;
  readonly #live: Live;
  /** In the order last shown: the first is the next to go. */
  readonly #kept = new Map<string, Kept>();
  /** The previews whose last read failed (shown as such until read again). */
  readonly #failed = new Set<string>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("taskConversation", {
      start: (topic) => {
        const key = keyOf(topic);
        const kept = this.#kept.get(key);
        if (kept) {
          // Shown again: it goes to the back of the line.
          this.#kept.delete(key);
          this.#kept.set(key, kept);
        }
        if (this.#fresh(topic, kept)) return;
        this.#failed.delete(key);
        this.#live.run(topic, this.#read(topic));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#evict();
      },
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#kept.clear();
      this.#failed.clear();
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "taskConversation") continue;
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#read(topic));
      }
    });
  }

  #fresh(topic: Topic, kept: Kept | undefined): boolean {
    return (
      kept !== undefined &&
      kept.version === String(topic.version ?? "") &&
      kept.expiresAt > this.#ctx.now()
    );
  }

  #value(topic: Topic): TaskConversationValue {
    const key = keyOf(topic);
    const kept = this.#kept.get(key);
    const messages = kept ? { messages: kept.messages } : {};
    if (this.#fresh(topic, kept)) return { status: "ready", ...messages };
    if (this.#failed.has(key)) return { status: "failed", ...messages };
    return { status: "loading", ...messages };
  }

  #read(topic: Topic): Effect.Effect<void> {
    const ctx = this.#ctx;
    const key = keyOf(topic);
    const limit = String(topic.limit ?? "");
    const path = route`/v1/comma/groups/${String(topic.group)}/conversations/${String(topic.conversation)}`;
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const answer = yield* (
        limit
          ? ctx.api.request(
              account.value,
              "GET",
              `${path}?message_limit=${encodeURIComponent(limit)}`,
              commaConversationSchema,
              undefined,
              LIMITED_TIMEOUT_MS
            )
          : ctx.api.request(account.value, "GET", path, commaConversationSchema)
      ).pipe(Effect.result);
      if (Result.isSuccess(answer)) {
        const conversation = answer.success;
        const status = normalizeTaskStatus(String(topic.status ?? ""));
        this.#kept.delete(key);
        this.#kept.set(key, {
          version: String(topic.version ?? ""),
          expiresAt: ctx.now() + (ENDED.has(status) ? ENDED_KEEP_MS : ACTIVE_KEEP_MS),
          messages: transcriptMessages(
            normalizeServerMessages(conversation.messages ?? [], [], conversation.kind)
          ),
        });
        this.#failed.delete(key);
      } else {
        this.#failed.add(key);
      }
      this.#evict();
      ctx.kernel.store.invalidate(topic);
    });
  }

  /** Drops the least recently shown beyond 24, but never one shown now. */
  #evict(): void {
    if (this.#kept.size <= MAX_KEPT) return;
    const shown = new Set(
      this.#ctx.kernel.store
        .liveTopics()
        .filter((t) => t.topic === "taskConversation")
        .map(keyOf)
    );
    for (const key of this.#kept.keys()) {
      if (this.#kept.size <= MAX_KEPT) return;
      if (!shown.has(key)) this.#kept.delete(key);
    }
  }
}
