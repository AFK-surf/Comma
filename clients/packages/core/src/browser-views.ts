// One viewer's session with an agent's browser (the conversation's browser panel): its tabs, the selected tab's frames
// and who controls it, and the person's control and input. The tabs are read when the view is shown and on
// `browserView.reconnect`; the selected tab is streamed while shown: a stream that ends is opened again 250 ms later on
// the core's Clock, one that fails stops (the person reconnects). A stream event older than the last control change
// applied cannot undo it. Input goes to the tab one command at a time, in order, while this viewer controls the same
// tab; a failed one lets go of control.
//
// Bounds: per shown view (one per open panel): one tabs read, one stream, one control command and one input command in
// flight; at most 32 inputs waiting; only the newest frame is kept. Everything stops as soon as no window shows it.
import { CoreError, type Topic, type Value, topicKey } from "@comma/core-kernel";
import { Duration, Effect, Option, Result } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import type {
  BrowserViewError,
  BrowserViewInput,
  BrowserViewTab,
  BrowserViewValue,
} from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import { bindingSchema } from "./session-browsers.ts";
import { readEvents } from "./sse.ts";

export const BROWSER_RECONNECT_MS = 250;
const MAX_QUEUED = 32;

const resultSchema = bindingSchema
  .extend({
    tabs: z
      .array(
        z.object({ tab_id: z.string(), title: z.string(), url: z.string() }).strip()
      )
      .max(32)
      .optional(),
  })
  .strip();
const eventSchema = z
  .object({
    browser: bindingSchema,
    can_control: z.boolean(),
    frame: z
      .object({
        data: z.string().max(1_400_000),
        tab_id: z.string(),
        metadata: z
          .object({ deviceWidth: z.number(), deviceHeight: z.number() })
          .loose(),
      })
      .nullable(),
  })
  .strip();
const inputSchema = z.union([
  z.object({ type: z.literal("text"), text: z.string().max(4096) }).strip(),
  z
    .object({
      type: z.enum(["keyDown", "keyUp"]),
      key: z.string().max(64),
      code: z.string().max(64),
      keyCode: z.number(),
      modifiers: z.number(),
    })
    .strip(),
  z
    .object({
      type: z.enum(["mousePressed", "mouseReleased", "mouseMoved", "mouseWheel"]),
      x: z.number(),
      y: z.number(),
      button: z.enum(["none", "left", "right", "middle"]),
      clickCount: z.number(),
      buttons: z.number().optional(),
      modifiers: z.number(),
      deltaX: z.number().optional(),
      deltaY: z.number().optional(),
    })
    .strip(),
]);
const operationSchema = z.enum([
  "take_control",
  "return_control",
  "close",
  "clear_storage",
]);

type View = BrowserViewValue & {
  readonly topic: Topic;
  /** The newest control change applied (its `updated_at`); an older stream event cannot undo it. */
  controlVersion: string;
  /** Grows when the tab or the stream changes: work for the one before is not applied. */
  target: number;
  queue: BrowserViewInput[];
  draining: boolean;
};

const id = (raw: unknown, name: string): string => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || v === "" || v.length > 256)
    throw CoreError.invalid(`${name} is required`);
  return v;
};
const viewTopic = (p: unknown): Topic => ({
  topic: "browserView",
  workspace: id(p, "workspace"),
  agent: id(p, "agent"),
  session: id(p, "session"),
  viewer: id(p, "viewer"),
});

export class BrowserViews {
  readonly #ctx: Ctx;
  /** The tabs read and the stream, per shown view. */
  readonly #live: Live;
  /** The input being sent, per shown view. */
  readonly #drains: Live;
  readonly #views = new Map<string, View>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    this.#drains = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("browserView", {
      // Each frame goes out as it comes: a person controlling the browser sees their input land without a wait.
      coalesce: false,
      start: (topic) => this.#show(topic),
      stop: (topic) => {
        this.#live.stop(topic);
        this.#drains.stop(topic);
        this.#views.delete(topicKey(topic));
      },
      compute: (topic): Value => {
        const view = this.#views.get(topicKey(topic));
        return { ok: view ? valueOf(view) : null };
      },
      evictAfterMs: 0,
    });
    // Each call names its view as the topic does; a view no window shows any more is left alone.
    const viewOf = (p: unknown) => this.#views.get(topicKey(viewTopic(p)));
    kernel.calls({
      "browserView.selectTab": {
        run: (p: unknown) => {
          const view = viewOf(p);
          const tab = id(p, "tab");
          return Effect.sync(() => {
            if (!view) return null;
            view.controlling = false;
            view.tab = tab;
            this.#restart(view, this.#stream(view));
            return null;
          });
        },
      },
      "browserView.reconnect": {
        run: (p: unknown) => {
          const view = viewOf(p);
          return Effect.sync(() => {
            if (!view) return null;
            view.controlling = false;
            this.#restart(view, this.#open(view));
            return null;
          });
        },
      },
      "browserView.input": {
        run: (p: unknown) => {
          const view = viewOf(p);
          const input = inputSchema.safeParse((p as { input?: unknown }).input);
          if (!input.success) throw CoreError.invalid("input is not a browser input");
          return Effect.sync(() => {
            if (!view?.controlling) return null;
            if (view.queue.length >= MAX_QUEUED) {
              this.#set(view, { error: "queueFull" });
              return null;
            }
            view.queue.push(input.data as BrowserViewInput);
            if (!view.draining) {
              view.draining = true;
              this.#drains.run(view.topic, this.#drain(view));
            }
            return null;
          });
        },
      },
      "browserView.command": {
        run: (p: unknown) => {
          const view = viewOf(p);
          const operation = operationSchema.safeParse(
            (p as { operation?: unknown }).operation
          );
          if (!operation.success) throw CoreError.invalid("operation is unknown");
          return (
            view ? this.#command(view, operation.data) : Effect.succeed(false)
          ).pipe(Effect.map((closed) => ({ closed })));
        },
      },
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      // Nothing one account streamed is shown to another.
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "browserView") continue;
        this.#live.stop(topic);
        this.#drains.stop(topic);
        this.#views.delete(topicKey(topic));
        kernel.store.invalidate(topic);
        this.#show(topic);
      }
    });
  }

  #show(topic: Topic): void {
    const view: View = {
      topic,
      tabs: [],
      tab: "",
      status: "loading",
      controlling: false,
      error: null,
      pending: false,
      frame: null,
      controlVersion: "",
      target: 0,
      queue: [],
      draining: false,
    };
    this.#views.set(topicKey(topic), view);
    this.#live.run(topic, this.#open(view));
  }

  /** Stops the view's tabs read, stream and input, then runs `work` for it. */
  #restart(view: View, work: Effect.Effect<void>): void {
    view.target++;
    view.queue = [];
    this.#live.stop(view.topic);
    this.#drains.stop(view.topic);
    view.draining = false;
    this.#ctx.kernel.store.invalidate(view.topic);
    this.#live.run(view.topic, work);
  }

  #set(view: View, change: Partial<BrowserViewValue>): void {
    Object.assign(view, change);
    this.#ctx.kernel.store.invalidate(view.topic);
  }

  #path(view: View): string {
    const t = view.topic;
    return route`/v1/comma/workspaces/${String(t.workspace)}/browsers/${String(t.agent)}/${String(t.session)}`;
  }

  #post(
    view: View,
    operation: string,
    args: Record<string, unknown>
  ): Effect.Effect<z.output<typeof resultSchema>, CoreError> {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api.request(account, "POST", this.#path(view), resultSchema, {
          viewer_id: String(view.topic.viewer),
          operation,
          args,
        })
      )
    );
  }

  /** Reads the tabs (the first is shown), then streams it. */
  #open(view: View): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      view.controlVersion = "";
      view.queue = [];
      this.#set(view, { tab: "", tabs: [], controlling: false });
      const answer = yield* this.#post(view, "tabs", {}).pipe(Effect.result);
      if (Result.isFailure(answer)) {
        this.#set(view, { error: "tabs" });
        return;
      }
      const tabs: BrowserViewTab[] = answer.success.tabs ?? [];
      this.#set(view, { tabs, tab: tabs[0]?.tab_id ?? "" });
      yield* this.#stream(view);
    });
  }

  /** Streams the selected tab: a stream that ends is opened again 250 ms later; one that fails stops. */
  #stream(view: View): Effect.Effect<void> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const tab = view.tab;
      if (!tab) return;
      this.#set(view, { error: null, status: "connecting" });
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const query = new URLSearchParams({
        tab_id: tab,
        viewer_id: String(view.topic.viewer),
      });
      const once = Effect.scoped(
        ctx.api
          .stream(account.value, `${this.#path(view)}/events?${query}`)
          .pipe(
            Effect.flatMap((body) =>
              readEvents(body, (raw) => Effect.sync(() => this.#event(view, raw)))
            )
          )
      );
      for (;;) {
        const ended = yield* Effect.result(once);
        if (Result.isFailure(ended)) {
          this.#set(view, {
            status: "disconnected",
            controlling: false,
            error: "stream",
          });
          return;
        }
        yield* Effect.sleep(Duration.millis(BROWSER_RECONNECT_MS));
      }
    });
  }

  #event(view: View, raw: unknown): void {
    const parsed = eventSchema.safeParse(raw);
    if (!parsed.success) return;
    const event = parsed.data;
    const change: Partial<View> = {
      status:
        event.browser.control === "human"
          ? "human"
          : event.browser.control === "handoff_pending"
            ? "waiting"
            : "agent",
    };
    if (event.browser.updated_at >= view.controlVersion) {
      view.controlVersion = event.browser.updated_at;
      change.storageError = event.browser.storage_error ?? null;
      change.controlling = event.can_control;
    }
    if (event.frame)
      change.frame = {
        seq: (view.frame?.seq ?? 0) + 1,
        data: event.frame.data,
        width: event.frame.metadata.deviceWidth,
        height: event.frame.metadata.deviceHeight,
      };
    this.#set(view, change);
  }

  /** A control command on the selected tab; its result applies only while the same tab is shown. */
  #command(
    view: View,
    operation: z.output<typeof operationSchema>
  ): Effect.Effect<boolean> {
    return Effect.gen({ self: this }, function* () {
      if (view.pending) return false;
      const target = view.target;
      this.#set(view, { pending: true, error: null });
      const answer = yield* this.#post(view, operation, { tab_id: view.tab }).pipe(
        Effect.result
      );
      if (this.#views.get(topicKey(view.topic)) !== view) return false;
      if (Result.isFailure(answer)) {
        this.#set(view, { pending: false, error: "control" });
        return false;
      }
      if (view.target !== target) {
        this.#set(view, { pending: false });
        return false;
      }
      view.controlVersion = answer.success.updated_at;
      this.#set(view, {
        pending: false,
        controlling: operation === "take_control",
        storageError: answer.success.storage_error ?? null,
      });
      return answer.success.status === "closed";
    });
  }

  /** Sends the waiting input in order while this viewer controls the same tab; a failure lets go of control. */
  #drain(view: View): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const target = view.target;
      const tab = view.tab;
      while (view.controlling && view.target === target && view.queue.length > 0) {
        const next = view.queue.shift()!;
        const sent = yield* this.#post(view, "input", {
          tab_id: tab,
          input: next,
        }).pipe(Effect.result);
        if (Result.isFailure(sent)) {
          this.#set(view, {
            controlling: false,
            error: "input" satisfies BrowserViewError,
          });
          break;
        }
      }
    }).pipe(
      Effect.ensuring(
        Effect.sync(() => {
          view.queue = [];
          view.draining = false;
        })
      )
    );
  }
}

function valueOf(view: View): BrowserViewValue {
  return {
    tabs: view.tabs,
    tab: view.tab,
    status: view.status,
    controlling: view.controlling,
    ...(view.storageError === undefined ? {} : { storageError: view.storageError }),
    error: view.error,
    pending: view.pending,
    frame: view.frame,
  };
}
