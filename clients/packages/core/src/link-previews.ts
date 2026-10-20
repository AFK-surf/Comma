// Rich previews of the links in a briefing or a chat: read each time a hover card opens on one. Every rich link can be
// private, so a preview is dropped as soon as no card shows it and the next card reads again (the server reauthorizes
// each read). Only a 404, which carries no provider content, is kept for this account (1 minute): it spares links the
// server never previews (most Outlook URLs) a provider round-trip on every hover.
//
// Bounds: one read in flight per link; at most 64 links kept (the least recently shown go first, never one shown now).
import { type CoreError, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import { route } from "./api.ts";
import { linkPreviewSchema } from "./comma/schemas.ts";
import type { LinkPreview, LinkPreviewValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";

const MISSING_KEEP_MS = 60_000;
const MAX_KEPT = 64;

type Kept = { expiresAt: number; preview?: LinkPreview; missing?: boolean };

const keyOf = (topic: Topic) =>
  `${String(topic.workspace)} ${String(topic.source ?? "")} ${String(topic.href).trim()}`;

export class LinkPreviews {
  readonly #ctx: Ctx;
  readonly #live: Live;
  /** In the order last shown: the first is the next to go. */
  readonly #kept = new Map<string, Kept>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("linkPreview", {
      evictAfterMs: 0,
      start: (topic) => {
        const key = keyOf(topic);
        const kept = this.#kept.get(key);
        if (kept?.missing && kept.expiresAt > ctx.now()) {
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
        const key = keyOf(topic);
        const kept = this.#kept.get(key);
        if (kept && !(kept.missing && kept.expiresAt > ctx.now()))
          this.#kept.delete(key);
        this.#evict();
      },
      compute: (topic): Value => ({ ok: this.#value(keyOf(topic)) }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#kept.clear();
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "linkPreview") continue;
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#read(topic));
      }
    });
  }

  #value(key: string): LinkPreviewValue {
    const kept = this.#kept.get(key);
    if (kept?.preview) return { status: "ready", preview: kept.preview };
    if (kept?.missing) return { status: "missing" };
    return { status: "loading" };
  }

  #read(topic: Topic): Effect.Effect<void> {
    const ctx = this.#ctx;
    const key = keyOf(topic);
    const query = new URLSearchParams({ href: String(topic.href) });
    if (topic.source) query.set("sourceId", String(topic.source));
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const answer = yield* ctx.api
        .request(
          account.value,
          "GET",
          `${route`/v1/comma/workspaces/${String(topic.workspace)}/recommendations`}/link-preview?${query}`,
          linkPreviewSchema
        )
        .pipe(Effect.result);
      const now = ctx.now();
      this.#kept.delete(key);
      this.#kept.set(
        key,
        Result.isSuccess(answer)
          ? { expiresAt: now, preview: answer.success as LinkPreview }
          : {
              // Other failures (no access, outage) show the generic card now but are asked again next time.
              expiresAt:
                now +
                ((answer.failure as CoreError).status === 404 ? MISSING_KEEP_MS : 0),
              missing: true,
            }
      );
      this.#evict();
      ctx.kernel.store.invalidate(topic);
    });
  }

  /** Drops the least recently shown beyond 64, but never one shown now. */
  #evict(): void {
    if (this.#kept.size <= MAX_KEPT) return;
    const shown = new Set(
      this.#ctx.kernel.store
        .liveTopics()
        .filter((t) => t.topic === "linkPreview")
        .map(keyOf)
    );
    for (const key of this.#kept.keys()) {
      if (this.#kept.size <= MAX_KEPT) return;
      if (!shown.has(key)) this.#kept.delete(key);
    }
  }
}
