// Who is in a Slack channel (the composer's @ menu, behind a channel's row), by Slack user id: read while the channel's
// list is open, page by page, shown as they come, and kept in memory for this account for five minutes. A failed read
// keeps what it got for 30 seconds; the next showing after that reads again.
//
// Bounds: one read in flight per channel while it is open, one request per second (`conversations.members` allows about
// 100 a minute); at most 32 channels kept (the least recently shown go first, never one shown now).
import type { Topic, Value } from "@comma/core-kernel";
import { Duration, Effect, Option, Result } from "effect";
import { route } from "./api.ts";
import { commaSlackMemberPageSchema } from "./comma/api-schemas.ts";
import { type Ctx, Live } from "./ctx.ts";

export const SLACK_MEMBERS_KEEP_MS = 5 * 60_000;
export const SLACK_MEMBERS_PACE_MS = 1_000;
const FAILED_KEEP_MS = 30_000;
const MAX_KEPT = 32;

type Kept = { expiresAt: number; members: string[] };

const keyOf = (topic: Topic) => `${String(topic.workspace)} ${String(topic.channel)}`;

export class SlackChannelMembers {
  readonly #ctx: Ctx;
  readonly #live: Live;
  /** In the order last shown: the first is the next to go. */
  readonly #kept = new Map<string, Kept>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("slackChannelMembers", {
      start: (topic) => {
        const key = keyOf(topic);
        const kept = this.#kept.get(key);
        if (kept && kept.expiresAt > ctx.now()) {
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
      compute: (topic): Value => ({
        ok: this.#kept.get(keyOf(topic))?.members ?? null,
      }),
      evictAfterMs: 0,
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      // Nothing one account could see is shown to another.
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
      .filter((t) => t.topic === "slackChannelMembers");
  }

  #read(topic: Topic): Effect.Effect<void> {
    const ctx = this.#ctx;
    const key = keyOf(topic);
    const path = route`/v1/comma/workspaces/${String(topic.workspace)}/plugins/slack/channels/${String(topic.channel)}/members`;
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const members: string[] = [];
      const keep = (expiresAt: number) => {
        this.#kept.delete(key);
        this.#kept.set(key, { expiresAt, members: [...members] });
        this.#evict();
        ctx.kernel.store.invalidate(topic);
      };
      let cursor = "";
      for (;;) {
        const query = cursor ? `?${new URLSearchParams({ cursor })}` : "";
        const page = yield* ctx.api
          .request(account.value, "GET", `${path}${query}`, commaSlackMemberPageSchema)
          .pipe(Effect.result);
        if (Result.isFailure(page)) {
          keep(ctx.now() + FAILED_KEEP_MS);
          return;
        }
        members.push(...page.success.data);
        if (page.success.next_cursor === null) {
          keep(ctx.now() + SLACK_MEMBERS_KEEP_MS);
          return;
        }
        cursor = page.success.next_cursor;
        keep(0);
        yield* Effect.sleep(Duration.millis(SLACK_MEMBERS_PACE_MS));
      }
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
