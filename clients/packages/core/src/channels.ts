// Messaging channels a workspace connects in Settings › Channels: WeChat (a QR code, sometimes a pairing code) and Signal
// (a one-time code sent from a Signal chat). What the server says is kept in memory only: a QR address or a connection
// code is never written to the device, and a new code's message is answered to the UI that asked for it alone.
//
// Bounds, per workspace whose topic is live: one request at a time (a read, a check or what a person asked); a WeChat
// attempt is checked every 3 s until it connects, stops or expires; Signal is read every 3 s while it has an unused
// code (the server drops a code after ten minutes). A failure stops the checks until the person refreshes.
import { CoreError, type Topic, type Value } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import {
  signalIntegrationSchema,
  signalNumberSchema,
  wechatConnectionSchema,
  wechatIntegrationSchema,
} from "./comma/schemas.ts";
import type {
  SignalCode,
  SignalIntegration,
  SignalNumber,
  SignalValue,
  WeChatConnection,
  WeChatIntegration,
  WeChatValue,
} from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";

const CHECK_EVERY_MS = 3_000;
/** WeChat answers that end an attempt: the person must act (a pairing code, a new QR code). */
const STOPPED = new Set([
  "need_verifycode",
  "expired",
  "verify_code_blocked",
  "binded_redirect",
]);

const wechatPath = (workspace: string) =>
  route`/v1/comma/workspaces/${workspace}/integrations/wechat`;
const signalPath = (workspace: string) =>
  route`/v1/comma/workspaces/${workspace}/integrations/signal`;

const params = {
  string(raw: unknown, name: string): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "")
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
  number(raw: unknown): string {
    const v = (raw as Record<string, unknown> | null)?.number;
    if (typeof v !== "string" || v.length > 32)
      throw CoreError.invalid("number is required");
    return v.trim();
  },
};

type WeChat = { state: WeChatIntegration | null; error: boolean; busy: boolean };
type Signal = {
  integration: SignalIntegration | null;
  number: SignalNumber | null;
  error: boolean;
  busy: boolean;
};

const busy = () => new CoreError("busy", "Another change is under way.");

export class Channels {
  readonly #ctx: Ctx;
  readonly #live: Live;
  readonly #wechat = new Map<string, WeChat>();
  readonly #signal = new Map<string, Signal>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("wechat", {
      start: (topic) => {
        this.#wechat.set(topic.workspace as string, {
          state: null,
          error: false,
          busy: false,
        });
        this.#live.run(topic, this.#keepWeChat(topic.workspace as string, true));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#wechat.delete(topic.workspace as string);
      },
      compute: (topic): Value => ({ ok: this.#wechatValue(topic.workspace as string) }),
    });
    kernel.source("signal", {
      start: (topic) => {
        this.#signal.set(topic.workspace as string, {
          integration: null,
          number: null,
          error: false,
          busy: false,
        });
        this.#live.run(topic, this.#keepSignal(topic.workspace as string, true));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#signal.delete(topic.workspace as string);
      },
      compute: (topic): Value => ({ ok: this.#signalValue(topic.workspace as string) }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      // Another account (or none): nothing of the one before is shown or checked.
      this.#accountKey = key;
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "wechat" && topic.topic !== "signal") continue;
        this.#live.stop(topic);
        const workspace = topic.workspace as string;
        if (topic.topic === "wechat") {
          this.#wechat.set(workspace, { state: null, error: false, busy: false });
          this.#live.run(topic, this.#keepWeChat(workspace, true));
        } else {
          this.#signal.set(workspace, {
            integration: null,
            number: null,
            error: false,
            busy: false,
          });
          this.#live.run(topic, this.#keepSignal(workspace, true));
        }
        kernel.store.invalidate(topic);
      }
    });

    kernel.calls({
      "wechat.refresh": {
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return this.#wechatAction(workspace, (w) =>
            this.#get(w, wechatPath(w), wechatIntegrationSchema).pipe(
              Effect.tap((next) => Effect.sync(() => this.#setWeChat(w, next))),
              Effect.flatMap((next) => {
                // An attempt the server holds as prepared finishes with one more check.
                const repair = [next.pending, next.connection].find(
                  (r) => r?.status === "prepared"
                );
                return repair
                  ? this.#checkWeChat(w, repair.connect_id, undefined)
                  : Effect.void;
              })
            )
          );
        },
      },
      "wechat.start": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return this.#wechatAction(workspace, (w) =>
            this.#send(
              w,
              "POST",
              `${wechatPath(w)}/connect`,
              wechatConnectionSchema,
              {}
            ).pipe(
              Effect.tap((record) => Effect.sync(() => this.#acceptWeChat(w, record)))
            )
          );
        },
      },
      "wechat.verify": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const code = params.string(p, "code").replace(/\D/g, "").slice(0, 16);
          return this.#wechatAction(workspace, (w) => {
            const attempt = this.#wechatAttempt(w);
            if (!attempt) return Effect.fail(CoreError.invalid("no attempt under way"));
            return this.#checkWeChat(w, attempt.connect_id, code);
          });
        },
      },
      "wechat.cancel": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return this.#wechatAction(workspace, (w) => {
            const pending = this.#wechat.get(w)?.state?.pending;
            if (!pending) return Effect.void;
            return this.#send(
              w,
              "DELETE",
              `${wechatPath(w)}/connect`,
              z.object({ cancelled: z.boolean() }),
              { attempt_id: pending.connect_id }
            ).pipe(
              Effect.andThen(this.#get(w, wechatPath(w), wechatIntegrationSchema)),
              Effect.tap((next) => Effect.sync(() => this.#setWeChat(w, next)))
            );
          });
        },
      },
      "wechat.disconnect": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return this.#wechatAction(workspace, (w) =>
            this.#send(
              w,
              "DELETE",
              wechatPath(w),
              z.object({ disconnected: z.boolean() })
            ).pipe(
              Effect.tap(() =>
                Effect.sync(() =>
                  this.#setWeChat(w, { connection: null, pending: null })
                )
              )
            )
          );
        },
      },
      "signal.refresh": {
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return this.#signalAction(workspace, (w) =>
            this.#loadSignal(w).pipe(
              Effect.tapError(() =>
                Effect.sync(() => {
                  const s = this.#signal.get(w);
                  if (s) s.error = true;
                })
              )
            )
          );
        },
      },
      "signal.newCode": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          let code: SignalCode | null = null;
          return this.#signalAction(workspace, (w) =>
            this.#send(
              w,
              "POST",
              `${signalPath(w)}/claims`,
              signalIntegrationSchema,
              {}
            ).pipe(
              Effect.tap((next) =>
                Effect.sync(() => {
                  const { claim, ...integration } = next;
                  // The code's message goes to whoever asked, never into what the core keeps or shows.
                  if (claim)
                    code = {
                      claimId: claim.claim_id,
                      command: claim.command,
                      number: claim.number ?? "",
                    };
                  this.#setSignal(w, { integration });
                })
              )
            )
          ).pipe(Effect.map(() => code));
        },
      },
      "signal.cancelCode": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const claim = params.string(p, "claim");
          return this.#signalAction(workspace, (w) =>
            this.#send(
              w,
              "DELETE",
              `${signalPath(w)}/claims/${encodeURIComponent(claim)}`,
              signalIntegrationSchema
            ).pipe(
              Effect.tap((next) =>
                Effect.sync(() => this.#setSignal(w, { integration: next }))
              )
            )
          );
        },
      },
      "signal.disconnect": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const binding = params.string(p, "binding");
          return this.#signalAction(workspace, (w) =>
            this.#send(
              w,
              "DELETE",
              `${signalPath(w)}/bindings/${encodeURIComponent(binding)}`,
              signalIntegrationSchema
            ).pipe(
              Effect.tap((next) =>
                Effect.sync(() => this.#setSignal(w, { integration: next }))
              )
            )
          );
        },
      },
      "signal.setNumber": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const number = params.number(p);
          return this.#signalAction(workspace, (w) =>
            this.#send(w, "PUT", `${signalPath(w)}/number`, signalNumberSchema, {
              number,
            }).pipe(
              Effect.flatMap((own) =>
                this.#get(w, signalPath(w), signalIntegrationSchema).pipe(
                  Effect.tap((integration) =>
                    Effect.sync(() => this.#setSignal(w, { number: own, integration }))
                  )
                )
              )
            )
          );
        },
      },
    });
  }

  #get<S extends z.ZodType>(_workspace: string, path: string, schema: S) {
    const ctx = this.#ctx;
    return ctx.session
      .account()
      .pipe(Effect.flatMap((account) => ctx.api.request(account, "GET", path, schema)));
  }

  #send<S extends z.ZodType>(
    _workspace: string,
    method: "POST" | "PUT" | "DELETE",
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

  #invalidate(name: "wechat" | "signal", workspace: string): void {
    this.#ctx.kernel.store.invalidate({ topic: name, workspace } as Topic);
  }

  // WeChat

  #wechatValue(workspace: string): WeChatValue {
    const w = this.#wechat.get(workspace);
    return {
      state: w?.state ?? null,
      error: w?.error ?? false,
      busy: w?.busy ?? false,
    };
  }

  #setWeChat(workspace: string, state: WeChatIntegration): void {
    const w = this.#wechat.get(workspace);
    if (!w) return;
    w.state = state;
    this.#invalidate("wechat", workspace);
  }

  /** An attempt's record: connected, it is the connection; otherwise the attempt under way. */
  #acceptWeChat(workspace: string, record: WeChatConnection): void {
    const current = this.#wechat.get(workspace)?.state;
    this.#setWeChat(
      workspace,
      record.connection_active
        ? { connection: record, pending: null }
        : { connection: current?.connection ?? null, pending: record }
    );
  }

  #wechatAttempt(workspace: string): WeChatConnection | undefined {
    const state = this.#wechat.get(workspace)?.state;
    return (
      state?.pending ??
      (state?.connection?.status === "prepared" ? state.connection : undefined)
    );
  }

  #checkWeChat(workspace: string, attempt: string, code: string | undefined) {
    return this.#send(
      workspace,
      "POST",
      `${wechatPath(workspace)}/connect/poll`,
      wechatConnectionSchema,
      {
        attempt_id: attempt,
        ...(code ? { verify_code: code } : {}),
      }
    ).pipe(
      Effect.tap((record) => Effect.sync(() => this.#acceptWeChat(workspace, record)))
    );
  }

  /** One thing a person asked at a time; a failure shows until a refresh or a new attempt; the checks start again after. */
  #wechatAction(
    workspace: string,
    work: (workspace: string) => Effect.Effect<unknown, CoreError>
  ): Effect.Effect<null, CoreError> {
    return Effect.suspend(() => {
      const w = this.#wechat.get(workspace);
      if (!w) return Effect.fail(CoreError.invalid("WeChat is not shown"));
      if (w.busy) return Effect.fail(busy());
      w.busy = true;
      w.error = false;
      this.#invalidate("wechat", workspace);
      return work(workspace).pipe(
        Effect.tapError(() =>
          Effect.sync(() => {
            if (this.#wechat.get(workspace) === w) w.error = true;
          })
        ),
        Effect.ensuring(
          Effect.sync(() => {
            if (this.#wechat.get(workspace) !== w) return;
            w.busy = false;
            this.#invalidate("wechat", workspace);
            this.#restartWeChat(workspace);
          })
        ),
        Effect.as(null)
      );
    });
  }

  #restartWeChat(workspace: string): void {
    const topic = { topic: "wechat", workspace } as Topic;
    if (!this.#live.live(topic)) return;
    this.#live.stop(topic);
    this.#live.run(topic, this.#keepWeChat(workspace, false));
  }

  /** Reads the state first (when shown), then checks an attempt under way every 3 s until it settles or expires. */
  #keepWeChat(workspace: string, read: boolean): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      if (read) {
        const w = this.#wechat.get(workspace);
        if (!w) return;
        const ok = yield* this.#get(
          workspace,
          wechatPath(workspace),
          wechatIntegrationSchema
        ).pipe(
          Effect.tap((next) => Effect.sync(() => this.#setWeChat(workspace, next))),
          Effect.as(true),
          Effect.orElseSucceed(() => false)
        );
        if (!ok) {
          w.error = true;
          this.#invalidate("wechat", workspace);
          return;
        }
      }
      for (;;) {
        const w = this.#wechat.get(workspace);
        const attempt = this.#wechatAttempt(workspace);
        if (!w || w.busy || w.error || !attempt) return;
        if (attempt.status !== "pending" || STOPPED.has(attempt.login_status)) return;
        if (this.#ctx.now() >= attempt.expires_at * 1000) {
          // Past its expiry the QR code is no use: say so without asking.
          if (w.state?.pending?.connect_id === attempt.connect_id)
            this.#setWeChat(workspace, {
              ...w.state,
              pending: { ...w.state.pending, login_status: "expired" },
            });
          return;
        }
        const ok = yield* this.#checkWeChat(
          workspace,
          attempt.connect_id,
          undefined
        ).pipe(
          Effect.as(true),
          Effect.orElseSucceed(() => false)
        );
        if (!ok) {
          w.error = true;
          this.#invalidate("wechat", workspace);
          return;
        }
        yield* Effect.sleep(CHECK_EVERY_MS);
      }
    });
  }

  // Signal

  #signalValue(workspace: string): SignalValue {
    const s = this.#signal.get(workspace);
    return {
      integration: s?.integration ?? null,
      number: s?.number ?? null,
      error: s?.error ?? false,
      busy: s?.busy ?? false,
    };
  }

  #setSignal(
    workspace: string,
    next: { integration?: SignalIntegration; number?: SignalNumber }
  ): void {
    const s = this.#signal.get(workspace);
    if (!s) return;
    if (next.integration) {
      const { claim: _claim, ...integration } =
        next.integration as SignalIntegration & {
          claim?: unknown;
        };
      s.integration = integration;
    }
    if (next.number) s.number = next.number;
    this.#invalidate("signal", workspace);
  }

  #loadSignal(workspace: string) {
    return Effect.all(
      [
        this.#get(workspace, signalPath(workspace), signalIntegrationSchema),
        this.#get(workspace, `${signalPath(workspace)}/number`, signalNumberSchema),
      ],
      { concurrency: "unbounded" }
    ).pipe(
      Effect.tap(([integration, number]) =>
        Effect.sync(() => this.#setSignal(workspace, { integration, number }))
      )
    );
  }

  /** One change at a time. A failed load shows until a refresh; a failed change is the caller's to say. */
  #signalAction(
    workspace: string,
    work: (workspace: string) => Effect.Effect<unknown, CoreError>
  ): Effect.Effect<null, CoreError> {
    return Effect.suspend(() => {
      const s = this.#signal.get(workspace);
      if (!s) return Effect.fail(CoreError.invalid("Signal is not shown"));
      if (s.busy) return Effect.fail(busy());
      s.busy = true;
      this.#invalidate("signal", workspace);
      return work(workspace).pipe(
        Effect.tap(() =>
          Effect.sync(() => {
            if (this.#signal.get(workspace) === s) s.error = false;
          })
        ),
        Effect.ensuring(
          Effect.sync(() => {
            if (this.#signal.get(workspace) !== s) return;
            s.busy = false;
            this.#invalidate("signal", workspace);
            this.#restartSignal(workspace);
          })
        ),
        Effect.as(null)
      );
    });
  }

  #restartSignal(workspace: string): void {
    const topic = { topic: "signal", workspace } as Topic;
    if (!this.#live.live(topic)) return;
    this.#live.stop(topic);
    this.#live.run(topic, this.#keepSignal(workspace, false));
  }

  /** Reads the state first (when shown), then every 3 s while a code is unused. */
  #keepSignal(workspace: string, read: boolean): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      if (read) {
        const s = this.#signal.get(workspace);
        if (!s) return;
        const ok = yield* this.#loadSignal(workspace).pipe(
          Effect.as(true),
          Effect.orElseSucceed(() => false)
        );
        if (!ok) {
          s.error = true;
          this.#invalidate("signal", workspace);
          return;
        }
      }
      for (;;) {
        const s = this.#signal.get(workspace);
        if (!s || s.busy || s.error || !s.integration?.pending_claims.length) return;
        yield* Effect.sleep(CHECK_EVERY_MS);
        const ok = yield* this.#get(
          workspace,
          signalPath(workspace),
          signalIntegrationSchema
        ).pipe(
          Effect.tap((integration) =>
            Effect.sync(() => this.#setSignal(workspace, { integration }))
          ),
          Effect.as(true),
          Effect.orElseSucceed(() => false)
        );
        if (!ok) {
          s.error = true;
          this.#invalidate("signal", workspace);
          return;
        }
      }
    });
  }
}
