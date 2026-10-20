// The ready browser, if any, that a conversation's participant runs (the conversation's Browser trigger). Read when
// shown, again every 10 s on the core's Clock and at once on `sessionBrowser.refresh`. Each read is given up after 10 s;
// a failed read shows no browser.
//
// Bounds: per shown conversation (one per window that shows it with a participant): one read in flight, one every 10 s.
// Each stops as soon as no window shows it.
import { CoreError, type Topic, type Value, topicKey } from "@comma/core-kernel";
import { Duration, Effect, Option, Queue, Result } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import type { SessionBrowserValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";

export const SESSION_BROWSER_POLL_MS = 10_000;
const TIMEOUT_MS = 10_000;

export const bindingSchema = z
  .object({
    agent_id: z.string(),
    session_id: z.string(),
    status: z.string(),
    control: z.enum(["agent", "handoff_pending", "human", "disconnected"]),
    busy: z.boolean(),
    shared_storage: z.boolean().optional(),
    storage_error: z.string().nullable().optional(),
    updated_at: z.string(),
  })
  .strip();
const browsersSchema = z.object({ browsers: z.array(bindingSchema).max(50) }).strip();

const string = (raw: unknown, name: string): string => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || v === "" || v.length > 256)
    throw CoreError.invalid(`${name} is required`);
  return v;
};

export class SessionBrowsers {
  readonly #ctx: Ctx;
  readonly #live: Live;
  /** What each shown topic read last; none before its first answer. */
  readonly #values = new Map<string, NonNullable<SessionBrowserValue>>();
  /** Each shown topic's `refresh`es: one waiting is enough. */
  readonly #checks = new Map<string, Queue.Queue<void>>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("sessionBrowser", {
      start: (topic) => this.#show(topic),
      stop: (topic) => {
        this.#live.stop(topic);
        this.#checks.delete(topicKey(topic));
        this.#values.delete(topicKey(topic));
      },
      compute: (topic): Value => ({ ok: this.#values.get(topicKey(topic)) ?? null }),
      evictAfterMs: 0,
    });
    kernel.calls({
      "sessionBrowser.refresh": {
        run: (p) =>
          Effect.sync(() => {
            const topic: Topic = {
              topic: "sessionBrowser",
              workspace: string(p, "workspace"),
              conversation: string(p, "conversation"),
              participant: string(p, "participant"),
            };
            const checks = this.#checks.get(topicKey(topic));
            if (checks) Queue.offerUnsafe(checks, undefined);
            return null;
          }),
      },
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      // Nothing one account read is shown to another.
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "sessionBrowser") continue;
        this.#live.stop(topic);
        this.#values.delete(topicKey(topic));
        kernel.store.invalidate(topic);
        this.#show(topic);
      }
    });
  }

  #show(topic: Topic): void {
    const checks = Effect.runSync(Queue.dropping<void>(1));
    this.#checks.set(topicKey(topic), checks);
    this.#live.run(
      topic,
      Effect.forever(
        this.#read(topic).pipe(
          Effect.andThen(
            Effect.raceFirst(
              Effect.sleep(Duration.millis(SESSION_BROWSER_POLL_MS)),
              Queue.take(checks)
            )
          )
        )
      )
    );
  }

  #read(topic: Topic): Effect.Effect<void> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const query = new URLSearchParams({
        conversation_id: String(topic.conversation),
        participant_id: String(topic.participant),
      });
      const answer = yield* ctx.api
        .request(
          account.value,
          "GET",
          `${route`/v1/comma/workspaces/${String(topic.workspace)}/browsers`}?${query}`,
          browsersSchema,
          undefined,
          TIMEOUT_MS
        )
        .pipe(Effect.result);
      const browser = Result.isSuccess(answer)
        ? (answer.success.browsers.find((item) => item.status === "ready") ?? null)
        : null;
      this.#values.set(topicKey(topic), { browser });
      ctx.kernel.store.invalidate(topic);
    });
  }
}
