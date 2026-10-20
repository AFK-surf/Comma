// A chat message's generated UI (a widget under its text answer): the JSON attached to the message, read when the
// widget first shows and kept in memory for this account. A failure that time can fix (no answer from the network, a
// read that took too long, or 408, 429, 502, 503, 504) is read once more 2 s later, on the core's Clock; the text
// answer stays in place meanwhile. Another failure, or a second one, is `failed` with kind `load`; an attachment over
// 256 KiB or that is no JSON is `failed` with kind `display`. A failure is not kept: a new `read` (the person's retry)
// reads again.
//
// Bounds: one read in flight per widget, at most one retry each; at most 64 answers kept (the least recently shown go
// first, never one shown now).
import { CoreError, type Topic, type Value } from "@comma/core-kernel";
import { Duration, Effect, Option, Result } from "effect";
import { route } from "./api.ts";
import type { DynamicUiValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";

export const DYNAMIC_UI_RETRY_MS = 2_000;
const MAX_BYTES = 262_144;
const MAX_KEPT = 64;
const TRANSIENT = new Set([408, 429, 502, 503, 504]);

type Ready = Extract<DynamicUiValue, { status: "ready" }>;
type Failed = Extract<DynamicUiValue, { status: "failed" }>;

/** The widget a topic shows, without its `read`. */
const widgetOf = (topic: Topic) =>
  JSON.stringify([topic.group, topic.conversation, topic.message, topic.index]);

function transient(error: CoreError): boolean {
  return error.status === undefined
    ? error.code === "network" || error.code === "timeout"
    : TRANSIENT.has(error.status);
}

export class DynamicUis {
  readonly #ctx: Ctx;
  readonly #live: Live;
  /** Answers by widget, in the order last shown: the first is the next to go. */
  readonly #kept = new Map<string, Ready>();
  /** Failures by topic (its `read` included): a new `read` reads again. */
  readonly #failed = new Map<string, Failed>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("dynamicUi", {
      start: (topic) => {
        const widget = widgetOf(topic);
        const kept = this.#kept.get(widget);
        if (kept) {
          // Shown again: it goes to the back of the line.
          this.#kept.delete(widget);
          this.#kept.set(widget, kept);
          return;
        }
        this.#live.run(topic, this.#read(topic));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#failed.delete(JSON.stringify(topic));
        this.#evict();
      },
      compute: (topic): Value => ({
        ok: this.#kept.get(widgetOf(topic)) ??
          this.#failed.get(JSON.stringify(topic)) ?? { status: "loading" },
      }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      // Nothing one account read is shown to another.
      this.#kept.clear();
      this.#failed.clear();
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "dynamicUi") continue;
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#read(topic));
      }
    });
  }

  #read(topic: Topic): Effect.Effect<void> {
    const ctx = this.#ctx;
    const path = route`/v1/comma/groups/${String(topic.group)}/conversations/${String(topic.conversation)}/messages/${String(topic.message)}/attachments/${String(topic.index)}`;
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const once = ctx.api.raw(account.value, "GET", path);
      let answer = yield* once.pipe(Effect.result);
      if (Result.isFailure(answer) && transient(answer.failure)) {
        yield* Effect.sleep(Duration.millis(DYNAMIC_UI_RETRY_MS));
        answer = yield* once.pipe(Effect.result);
      }
      const settled = Result.isSuccess(answer)
        ? parse(answer.success.body)
        : ({
            status: "failed",
            kind: "load",
            reason: answer.failure.message,
          } satisfies Failed);
      if (settled.status === "ready") {
        this.#kept.delete(widgetOf(topic));
        this.#kept.set(widgetOf(topic), settled);
        this.#evict();
      } else this.#failed.set(JSON.stringify(topic), settled);
      ctx.kernel.store.invalidate(topic);
    });
  }

  /** Drops the least recently shown beyond 64, but never one shown now. */
  #evict(): void {
    if (this.#kept.size <= MAX_KEPT) return;
    const shown = new Set(
      this.#ctx.kernel.store
        .liveTopics()
        .filter((t) => t.topic === "dynamicUi")
        .map(widgetOf)
    );
    for (const widget of this.#kept.keys()) {
      if (this.#kept.size <= MAX_KEPT) return;
      if (!shown.has(widget)) this.#kept.delete(widget);
    }
  }
}

/** The attachment as a widget: its JSON, unless it is too large or no JSON. */
function parse(body: Uint8Array): Ready | Failed {
  if (body.byteLength > MAX_BYTES)
    return { status: "failed", kind: "display", reason: "UI exceeds 256 KiB" };
  try {
    return {
      status: "ready",
      ui: JSON.parse(new TextDecoder().decode(body)) as unknown,
    };
  } catch (error) {
    return {
      status: "failed",
      kind: "display",
      reason: error instanceof Error ? error.message : "UI unavailable",
    };
  }
}
