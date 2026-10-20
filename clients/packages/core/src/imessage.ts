// iMessage in Settings › Channels, over Photon shared lines: the person enters the phone number (or Apple Account
// email) iMessage uses; the server assigns a line and answers a code; the person sends the code to that line from that
// number, and the connection becomes active. The core reads the state, and while an attempt waits on the person it
// reads it again every 3 s until it connects, is cancelled or expires (ten minutes). Kept in memory only.
//
// Bounds, per workspace whose topic is live: one change at a time; one read at a time; a failed read stops the reads
// until the person refreshes.
import { CoreError, type Topic, type Value } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import { imessageIntegrationSchema } from "./comma/schemas.ts";
import type { IMessageIntegration, IMessageValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";

const CHECK_EVERY_MS = 3_000;

const imessagePath = (workspace: string) =>
  route`/v1/comma/workspaces/${workspace}/integrations/imessage`;

const params = {
  string(raw: unknown, name: string, max = 254): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v.trim() === "" || v.length > max)
      throw CoreError.invalid(`${name} is required`);
    return v.trim();
  },
};

type State = { state: IMessageIntegration | null; error: boolean; busy: boolean };

const busy = () => new CoreError("busy", "Another change is under way.");

export class IMessage {
  readonly #ctx: Ctx;
  readonly #live: Live;
  readonly #states = new Map<string, State>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("imessage", {
      start: (topic) => {
        this.#states.set(topic.workspace as string, fresh());
        this.#live.run(topic, this.#keep(topic.workspace as string, true));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#states.delete(topic.workspace as string);
      },
      compute: (topic): Value => ({ ok: this.#value(topic.workspace as string) }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      // Another account (or none): nothing of the one before is shown or read.
      this.#accountKey = key;
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "imessage") continue;
        this.#live.stop(topic);
        this.#states.set(topic.workspace as string, fresh());
        this.#live.run(topic, this.#keep(topic.workspace as string, true));
        kernel.store.invalidate(topic);
      }
    });

    kernel.calls({
      "imessage.refresh": {
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return this.#action(workspace, (w) => this.#read(w));
        },
      },
      "imessage.start": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const handle = params.string(p, "handle");
          return this.#action(workspace, (w) =>
            this.#send("POST", `${imessagePath(w)}/connect`, z.unknown(), {
              handle,
            }).pipe(Effect.andThen(this.#read(w)))
          );
        },
      },
      "imessage.cancel": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return this.#action(workspace, (w) => {
            const code = this.#states.get(w)?.state?.pending_claim?.code;
            if (!code) return Effect.void;
            return this.#send(
              "DELETE",
              `${imessagePath(w)}/connect`,
              z.object({ cancelled: z.boolean() }),
              { code }
            ).pipe(Effect.andThen(this.#read(w)));
          });
        },
      },
      "imessage.disconnect": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return this.#action(workspace, (w) =>
            this.#send(
              "DELETE",
              imessagePath(w),
              z.object({ disconnected: z.boolean() })
            ).pipe(Effect.andThen(this.#read(w)))
          );
        },
      },
    });
  }

  #value(workspace: string): IMessageValue {
    const s = this.#states.get(workspace);
    return {
      state: s?.state ?? null,
      error: s?.error ?? false,
      busy: s?.busy ?? false,
    };
  }

  #invalidate(workspace: string): void {
    this.#ctx.kernel.store.invalidate({ topic: "imessage", workspace } as Topic);
  }

  #read(workspace: string) {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api.request(
          account,
          "GET",
          imessagePath(workspace),
          imessageIntegrationSchema
        )
      ),
      Effect.tap((next) =>
        Effect.sync(() => {
          const s = this.#states.get(workspace);
          if (!s) return;
          s.state = next;
          s.error = false;
          this.#invalidate(workspace);
        })
      )
    );
  }

  #send<S extends z.ZodType>(
    method: "POST" | "DELETE",
    path: string,
    schema: S,
    body?: unknown
  ) {
    const ctx = this.#ctx;
    return ctx.session
      .account()
      .pipe(
        Effect.flatMap((account) =>
          ctx.api.request(account, method, path, schema, body)
        )
      );
  }

  /** One change at a time. A failed change is the caller's to say; the reads start again after it. */
  #action(
    workspace: string,
    work: (workspace: string) => Effect.Effect<unknown, CoreError>
  ): Effect.Effect<null, CoreError> {
    return Effect.suspend(() => {
      const s = this.#states.get(workspace);
      if (!s) return Effect.fail(CoreError.invalid("iMessage is not shown"));
      if (s.busy) return Effect.fail(busy());
      s.busy = true;
      this.#invalidate(workspace);
      return work(workspace).pipe(
        Effect.ensuring(
          Effect.sync(() => {
            if (this.#states.get(workspace) !== s) return;
            s.busy = false;
            this.#invalidate(workspace);
            this.#restart(workspace);
          })
        ),
        Effect.as(null)
      );
    });
  }

  #restart(workspace: string): void {
    const topic = { topic: "imessage", workspace } as Topic;
    if (!this.#live.live(topic)) return;
    this.#live.stop(topic);
    this.#live.run(topic, this.#keep(workspace, false));
  }

  /** Reads the state first (when shown), then every 3 s while an attempt waits and has not expired. */
  #keep(workspace: string, read: boolean): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      if (read && !(yield* this.#readOrStop(workspace))) return;
      for (;;) {
        const s = this.#states.get(workspace);
        const attempt = s?.state?.pending_claim;
        if (!s || s.busy || s.error || !attempt) return;
        if (this.#ctx.now() >= attempt.expires_at * 1000) return;
        yield* Effect.sleep(CHECK_EVERY_MS);
        if (!(yield* this.#readOrStop(workspace))) return;
      }
    });
  }

  #readOrStop(workspace: string): Effect.Effect<boolean> {
    return this.#read(workspace).pipe(
      Effect.as(true),
      Effect.catch(() =>
        Effect.sync(() => {
          const s = this.#states.get(workspace);
          if (s) {
            s.error = true;
            this.#invalidate(workspace);
          }
          return false;
        })
      )
    );
  }
}

const fresh = (): State => ({ state: null, error: false, busy: false });
