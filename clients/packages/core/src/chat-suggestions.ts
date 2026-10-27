// Follow-up suggestions for a settled chat turn (`chatSuggestions`): the server writes them with one model call for the
// turn's last assistant message, in the requested locale. Asked once per turn and locale while a chat shows it; the
// answer is kept for this account, so showing the same turn again costs no second model call. A failed or empty
// answer is kept as no suggestions: the composer keeps its default placeholder.
//
// Bounds: one read in flight per turn; at most 32 turns kept (the least recently shown go first, never one shown now).
import type { Topic, Value } from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import { route } from "./api.ts";
import { commaChatSuggestionSchema, commaPageSchema } from "./comma/api-schemas.ts";
import type { ChatSuggestion } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";

const MAX_KEPT = 32;

const keyOf = (topic: Topic) =>
  `${String(topic.group)} ${String(topic.conversation)} ${String(topic.message)} ${String(topic.locale)}`;

export class ChatSuggestions {
  readonly #ctx: Ctx;
  readonly #live: Live;
  /** In the order last shown: the first is the next to go. */
  readonly #kept = new Map<string, ChatSuggestion[]>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("chatSuggestions", {
      start: (topic) => {
        const key = keyOf(topic);
        const kept = this.#kept.get(key);
        if (kept) {
          // Shown again: it goes to the back of the line.
          this.#kept.delete(key);
          this.#kept.set(key, kept);
          return;
        }
        this.#live.run(topic, this.#read(topic));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#evict();
      },
      compute: (topic): Value => ({ ok: this.#kept.get(keyOf(topic)) ?? null }),
      evictAfterMs: 0,
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      // Nothing one account was suggested is shown to another.
      this.#kept.clear();
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
      .filter((t) => t.topic === "chatSuggestions");
  }

  #read(topic: Topic): Effect.Effect<void> {
    const ctx = this.#ctx;
    const key = keyOf(topic);
    const query = new URLSearchParams({ locale: String(topic.locale) });
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const page = yield* ctx.api
        .request(
          account.value,
          "POST",
          `${route`/v1/comma/groups/${String(topic.group)}/conversations/${String(topic.conversation)}/suggestions`}?${query}`,
          commaPageSchema(commaChatSuggestionSchema),
          {}
        )
        .pipe(Effect.result);
      this.#kept.delete(key);
      this.#kept.set(
        key,
        Result.isSuccess(page)
          ? page.success.data.map(({ id, label, prompt }) => ({ id, label, prompt }))
          : []
      );
      this.#evict();
      ctx.kernel.store.invalidate(topic);
    });
  }

  /** Drops the least recently shown beyond 32, but never one shown now. */
  #evict(): void {
    if (this.#kept.size <= MAX_KEPT) return;
    const shown = new Set(this.#shown().map(keyOf));
    for (const key of this.#kept.keys()) {
      if (this.#kept.size <= MAX_KEPT) return;
      if (!shown.has(key)) this.#kept.delete(key);
    }
  }
}
